import 'chip.dart';
import 'compile_error.dart';
import 'function_item.dart';
import 'item_ref.dart';
import 'library_kind.dart';
import 'manifest.dart';
import 'peripheral.dart';
import 'pin.dart';
import 'symbol_item.dart';

/// 全部静态数据的聚合对象，加载一次后常驻内存。
///
/// 需求要求"JSON 一次性加载进内存，不要每次进页面都重新读文件"，
/// 因此所有查询接口都走这里的 Map 索引，页面只做 O(1) 查找。
///
/// v2 起同一外设可同时有 spl/hal/ll/reg 四份函数与符号，所以索引里
/// 多了一层「库」维度。为了不破坏 v1 时代的大量单参调用，
/// [functionsOf] / [symbolsOf] 的单参版本仍然保留（返回该外设全部库，按库序）。
class SplData {
  /// 数据版本信息
  final DataManifest manifest;

  /// 当前芯片能力描述
  final ChipSpec chip;

  /// 全部外设（已按 orderIndex 排序）
  final List<Peripheral> peripherals;

  /// 全部函数（跨外设跨库合并）
  final List<FunctionItem> functions;

  /// 全部符号（SPL 的 symbols.json）
  final List<SymbolItem> symbols;

  /// HAL/LL 符号（symbols_hal.json，按需加载；默认空）
  ///
  /// 首屏不读它（文件独立、绝大多数用户首屏只看 SPL），
  /// 由 [SplData.withHalSymbols] 在需要时换出一个带 HAL 符号的新实例，
  /// 这样索引重建是一次性的、可预测的。
  final List<SymbolItem> halSymbols;

  /// 引脚数据
  final PinoutData pinout;

  /// 编译错误数据
  final CompileErrorBundle compileErrors;

  // ---- 以下为内存索引，构造时建立 ----

  /// 外设 id → 外设
  final Map<String, Peripheral> peripheralById;

  /// 函数 id → 函数（跨库；id 全局唯一，HAL_/LL_/REG_ 前缀天然不冲突）
  final Map<String, FunctionItem> functionById;

  /// 符号 id → 符号（SPL 符号 + HAL 符号）
  final Map<String, SymbolItem> symbolById;

  /// 「名字@库」→ 符号（v2.0.1 新增）。
  ///
  /// HAL/LL 与 SPL 各有一套同名但成员布局不同的结构体
  /// （`GPIO_InitTypeDef`：HAL 是 Pin/Mode/Pull/Speed，SPL 是
  /// GPIO_Pin/GPIO_Speed/GPIO_Mode）。数据层把它们存成
  /// `GPIO_InitTypeDef@hal` 与 `GPIO_InitTypeDef`，靠这个索引区分，
  /// 跳转时按当前阅读的库选对应那份。
  final Map<String, SymbolItem> _symbolByQualified;

  /// 外设 id → 该外设的函数列表（跨库，按库顺序）
  final Map<String, List<FunctionItem>> functionsByPeripheral;

  /// 外设 id → 库 → 该库的函数列表（顺序与头文件一致）
  final Map<String, Map<LibraryKind, List<FunctionItem>>>
      _functionsByPeripheralLib;

  /// 外设 id → 该外设的符号列表（跨库）
  final Map<String, List<SymbolItem>> symbolsByPeripheral;

  /// 符号 id → 会用到它的函数 id 列表（由 symbols 的 usedBy 反向补齐）
  final Map<String, List<String>> functionsUsingSymbol;

  /// 编译错误 id → 错误条目
  final Map<String, CompileError> compileErrorById;

  /// 全部函数 id（含未加载详情的），由外设的 sections 汇总而来。
  ///
  /// 首屏时 peripherals.json 已加载，所以这个集合是完整的；
  /// 而 [functionById] 只包含已按需加载的外设的函数。
  /// 跳转判断必须用这个集合，否则首屏点函数名会被误判为"未收录"。
  ///
  /// v2 里 sections 已覆盖四个库（HAL/LL/reg 的函数 id 都在里面），
  /// 所以这一个集合就够判断所有库的函数。
  final Set<String> _allFunctionIds;

  /// 函数 id → 所属外设 id，用于按需加载时定位文件。
  final Map<String, String> _functionToPeripheral;

  /// 函数 id → 所属库，用于详情页直接读对应库的文件、少试几个库。
  final Map<String, LibraryKind> _functionToLibrary;

  SplData({
    required this.manifest,
    required this.chip,
    required this.peripherals,
    required this.functions,
    required this.symbols,
    required this.pinout,
    required this.compileErrors,
    this.halSymbols = const <SymbolItem>[],
  })  : peripheralById = {for (final p in peripherals) p.id: p},
        functionById = {for (final f in functions) f.id: f},
        symbolById = {for (final s in [...symbols, ...halSymbols]) s.id: s},
        _symbolByQualified = _indexQualifiedSymbols([...symbols, ...halSymbols]),
        functionsByPeripheral = _groupFunctions(functions),
        _functionsByPeripheralLib = _groupFunctionsByLib(functions),
        symbolsByPeripheral = _groupSymbols([...symbols, ...halSymbols]),
        functionsUsingSymbol = _invertUsedBy([...symbols, ...halSymbols]),
        compileErrorById = {for (final e in compileErrors.errors) e.id: e},
        _allFunctionIds = _collectFunctionIds(peripherals),
        _functionToPeripheral = _mapFunctionToPeripheral(peripherals),
        _functionToLibrary = _mapFunctionToLibrary(peripherals);

  /// 建立「名字@库」索引。
  ///
  /// 数据里库限定符号的 id 形如 `GPIO_InitTypeDef@hal`，而函数正文里
  /// 引用它的写法是 `GPIO_InitTypeDef`。为了让「在 HAL 页点它 → 打开 HAL 那份」
  /// 成立，这里登记两种键：精确 id 本身，以及 `name@library`（同一符号两者相同，
  /// 但 name 与 id 分离后仍能命中，防止将来改 id 规则时跳转失效）。
  /// 只为 id 带 `@` 的符号建键，普通符号不重复占内存。
  static Map<String, SymbolItem> _indexQualifiedSymbols(
    List<SymbolItem> all,
  ) {
    final map = <String, SymbolItem>{};
    for (final s in all) {
      if (!s.id.contains('@')) continue;
      map[s.id] = s;
      map.putIfAbsent('${s.name}@${s.library.raw}', () => s);
    }
    return map;
  }

  /// 换出一个带 HAL/LL 符号的新实例（索引随之重建）。
  ///
  /// 为什么返回新实例而不是原地 setter：SplData 被 provider 缓存在
  /// Riverpod 里，原地改会让监听者收不到变更通知；换实例则天然触发重建。
  SplData withHalSymbols(List<SymbolItem> extra) => SplData(
        manifest: manifest,
        chip: chip,
        peripherals: peripherals,
        functions: functions,
        symbols: symbols,
        pinout: pinout,
        compileErrors: compileErrors,
        halSymbols: extra,
      );

  /// 换出一个带已加载函数的新实例（进过外设页后，首页搜索能拿到中文简述）。
  ///
  /// [mergeDuplicates] 为 true 时，同 id 的新函数覆盖旧的；
  /// 否则只补不覆盖（保持"先加载的优先"）。
  SplData withFunctions(
    List<FunctionItem> extra, {
    bool mergeDuplicates = true,
  }) {
    final merged = <String, FunctionItem>{
      for (final f in functions) f.id: f,
    };
    for (final f in extra) {
      if (mergeDuplicates) {
        merged[f.id] = f;
      } else {
        merged.putIfAbsent(f.id, () => f);
      }
    }
    return SplData(
      manifest: manifest,
      chip: chip,
      peripherals: peripherals,
      functions: merged.values.toList(growable: false),
      symbols: symbols,
      pinout: pinout,
      compileErrors: compileErrors,
      halSymbols: halSymbols,
    );
  }

  /// 汇总所有外设的函数 id（首屏即可用，不依赖函数详情是否加载）。
  static Set<String> _collectFunctionIds(List<Peripheral> peripherals) {
    final set = <String>{};
    for (final p in peripherals) {
      set.addAll(p.allFunctionIds);
    }
    return set;
  }

  /// 建立 函数 id → 外设 id 的反查表。
  static Map<String, String> _mapFunctionToPeripheral(
    List<Peripheral> peripherals,
  ) {
    final map = <String, String>{};
    for (final p in peripherals) {
      for (final fid in p.allFunctionIds) {
        map.putIfAbsent(fid, () => p.id);
      }
    }
    return map;
  }

  /// 建立 函数 id → 库 的反查表。
  ///
  /// 来源是外设的 sections（首屏就有），不依赖函数详情是否加载。
  static Map<String, LibraryKind> _mapFunctionToLibrary(
    List<Peripheral> peripherals,
  ) {
    final map = <String, LibraryKind>{};
    for (final p in peripherals) {
      for (final sec in p.sections) {
        for (final fid in sec.functionIds) {
          map.putIfAbsent(fid, () => sec.library);
        }
      }
    }
    return map;
  }

  /// 按外设分组函数，组内保持原始顺序（解析时已按头文件顺序写入）。
  static Map<String, List<FunctionItem>> _groupFunctions(
    List<FunctionItem> functions,
  ) {
    final map = <String, List<FunctionItem>>{};
    for (final f in functions) {
      map.putIfAbsent(f.peripheral, () => <FunctionItem>[]).add(f);
    }
    return map;
  }

  /// 按「外设 → 库」二级分组函数。
  static Map<String, Map<LibraryKind, List<FunctionItem>>>
      _groupFunctionsByLib(List<FunctionItem> functions) {
    final map = <String, Map<LibraryKind, List<FunctionItem>>>{};
    for (final f in functions) {
      final byLib =
          map.putIfAbsent(f.peripheral, () => <LibraryKind, List<FunctionItem>>{});
      byLib.putIfAbsent(f.library, () => <FunctionItem>[]).add(f);
    }
    return map;
  }

  /// 按外设分组符号。
  static Map<String, List<SymbolItem>> _groupSymbols(List<SymbolItem> symbols) {
    final map = <String, List<SymbolItem>>{};
    for (final s in symbols) {
      map.putIfAbsent(s.peripheral, () => <SymbolItem>[]).add(s);
    }
    return map;
  }

  /// 把每个符号的 usedBy 反过来存一份，供"哪些函数用了这个符号"快速查询。
  static Map<String, List<String>> _invertUsedBy(List<SymbolItem> symbols) {
    final map = <String, List<String>>{};
    for (final s in symbols) {
      for (final fnId in s.usedBy) {
        map.putIfAbsent(fnId, () => <String>[]).add(s.id);
      }
    }
    return map;
  }

  // ---- 查询接口 ----

  /// 取外设；不存在返回 null。
  Peripheral? peripheral(String id) => peripheralById[id];

  /// 取函数；不存在返回 null。
  FunctionItem? function(String id) => functionById[id];

  /// 取符号；不存在返回 null。
  SymbolItem? symbol(String id) => symbolById[id];

  /// 取某外设的函数。
  ///
  /// - 单参 [functionsOf]('GPIO')：返回该外设**全部库**的函数，按
  ///   [LibraryKind.ordered] 分组、组内保持头文件顺序。
  ///   保留这个签名是因为 v1 时代大量调用方（搜索、统计、外设页）都用它；
  ///   只有一个库时行为与以前完全一致。
  /// - 双参 [functionsOf]('GPIO', LibraryKind.hal)：只取该库。
  ///
  /// 用可选位置参数而不是两个重载（Dart 不支持重载），
  /// 这样老的 `functionsOf(pid)` 一行都不用改。
  List<FunctionItem> functionsOf(
    String peripheralId, [
    LibraryKind? lib,
  ]) {
    if (lib != null) {
      return _functionsByPeripheralLib[peripheralId]?[lib] ??
          const <FunctionItem>[];
    }

    final list = functionsByPeripheral[peripheralId];
    if (list == null || list.isEmpty) return const <FunctionItem>[];
    // 单库（绝大多数外设）不必排序，直接返回，省一次分配
    final firstLib = list.first.library;
    if (list.every((f) => f.library == firstLib)) return list;
    final sorted = List<FunctionItem>.from(list);
    // List.sort 不保证稳定，所以用"库序 + 原下标"双键排序保序
    final index = <String, int>{
      for (var i = 0; i < list.length; i++) list[i].id: i,
    };
    sorted.sort((a, b) {
      final byLib = a.library.orderIndex.compareTo(b.library.orderIndex);
      if (byLib != 0) return byLib;
      return (index[a.id] ?? 0).compareTo(index[b.id] ?? 0);
    });
    return sorted;
  }

  /// 取某外设的符号。
  ///
  /// 单参返回跨库全部符号；双参只取该库。
  /// v1 数据没有 library 字段，解析时统一按 spl 处理，
  /// 所以 `symbolsOf(pid, LibraryKind.spl)` 拿到的就是以前的全量。
  List<SymbolItem> symbolsOf(String peripheralId, [LibraryKind? lib]) {
    final all = symbolsByPeripheral[peripheralId];
    if (all == null || all.isEmpty) return const <SymbolItem>[];
    if (lib == null) return all;
    return all.where((s) => s.library == lib).toList(growable: false);
  }


  /// 判断一个名字是否是库内符号（关键词跳转的白名单判断）。
  ///
  /// 接受两种写法：
  ///   - 普通名字 `GPIO_InitTypeDef`；
  ///   - 库限定 id `GPIO_InitTypeDef@hal`（HAL/SPL 同名不同类型时用）。
  bool isKnownSymbol(String name) =>
      symbolById.containsKey(name) || _symbolByQualified.containsKey(name);

  /// 「名字@库」→ 符号 的索引（v2.0.1 新增）。
  ///
  /// HAL 与 SPL 都定义了 `GPIO_InitTypeDef`，但成员完全不同
  /// （HAL: Pin/Mode/Pull/Speed；SPL: GPIO_Pin/GPIO_Speed/GPIO_Mode）。
  /// 数据层把 HAL 那份存成 `GPIO_InitTypeDef@hal`，两者因此能在同一个
  /// 全局索引里共存。这个映射用于：
  ///   1. 详情页按 `name@lib` 精确打开某一库的版本；
  ///   2. 跳转时优先选**与当前阅读上下文同库**的那份。
  Map<String, SymbolItem> get symbolByQualifiedName => _symbolByQualified;

  /// 去掉 `@lib` 后缀，返回基础名字（无后缀时原样返回）。
  static String stripLibSuffix(String name) {
    final at = name.lastIndexOf('@');
    return at <= 0 ? name : name.substring(0, at);
  }

  /// 在给定库上下文中解析一个符号名（v2.0.1 新增，跳转链路的核心）。
  ///
  /// 优先级：
  ///   1. 精确 id（`GPIO_InitTypeDef@hal` 这种）——调用方明确指定了库；
  ///   2. `name@preferredLib`——当前正在读 HAL 函数，就优先给 HAL 那份定义；
  ///   3. 无后缀的同名符号——SPL 那份（老行为，向后兼容）；
  ///   4. `name@hal`——最后的兜底。
  ///
  /// [preferredLib] 传 null 时退化为老行为（只查无后缀 id）。
  SymbolItem? symbolOf(String name, {LibraryKind? preferredLib}) {
    final direct = symbolById[name];
    if (direct != null && name.contains('@')) return direct;
    if (preferredLib != null) {
      final qualified = _symbolByQualified['$name@${preferredLib.raw}'];
      if (qualified != null) return qualified;
    }
    if (direct != null) return direct;
    return _symbolByQualified['$name@hal'];
  }

  /// 取同名符号的**全部版本**（v2.0.1 新增）。
  ///
  /// 用于详情页的「这个类型在其它库里也有定义」切换入口：
  /// `GPIO_InitTypeDef` 会同时返回 SPL 那份与 `GPIO_InitTypeDef@hal`。
  /// 按库顺序（spl→hal→ll→reg）排列，保证切换入口的呈现顺序稳定。
  List<SymbolItem> symbolVariantsOf(String name) {
    final base = stripLibSuffix(name);
    final out = <SymbolItem>[];
    final seen = <String>{};
    final plain = symbolById[base];
    if (plain != null && seen.add(plain.id)) out.add(plain);
    for (final lib in LibraryKind.ordered) {
      final q = _symbolByQualified['$base@${lib.raw}'];
      if (q != null && seen.add(q.id)) out.add(q);
    }
    out.sort((a, b) => a.library.orderIndex.compareTo(b.library.orderIndex));
    return out;
  }


  /// 判断一个名字是否是库内函数。
  ///
  /// 注意：函数详情是按需加载的，[functionById] 里只有已加载外设的函数，
  /// 首屏时可能是空的。所以这里回退查外设的 functionIds——
  /// 那些 id 来自 peripherals.json，首屏必然可用。
  ///
  /// v2 的 sections 已覆盖 HAL/LL/reg 的函数 id，所以同一套逻辑
  /// 天然覆盖四个库；[functionById] 里已加载的 HAL 函数也会命中。
  bool isKnownFunction(String name) {
    if (functionById.containsKey(name)) return true;
    return _allFunctionIds.contains(name);
  }

  /// 判断一个名字是否是已知的库内名字（函数或符号）。
  bool isKnownName(String name) =>
      isKnownFunction(name) || isKnownSymbol(name);

  /// 取函数所属的外设 id（按需加载时用来定位文件）。
  String? peripheralIdOfFunction(String functionId) {
    final f = functionById[functionId];
    if (f != null) return f.peripheral;
    return _functionToPeripheral[functionId];
  }

  /// 取函数所属的库。
  ///
  /// 已加载的函数直接读字段；未加载时查 sections 建的反查表，
  /// 所以详情页首屏就能知道该去 `functions/hal/` 还是 `functions/` 读文件。
  /// 查不到返回 null（数据不一致，调用方可回退到逐库探测）。
  LibraryKind? libraryOfFunction(String functionId) {
    final f = functionById[functionId];
    if (f != null) return f.library;
    return _functionToLibrary[functionId];
  }

  /// 该外设是否被当前芯片支持。
  bool isPeripheralSupported(String peripheralId) =>
      chip.supportsPeripheral(peripheralId);

  /// 按 [ItemRef] 取标题，用于最近查看/收藏里补全显示。
  String titleOf(ItemRef ref) {
    switch (ref.type) {
      case ItemType.function:
        return function(ref.id)?.name ?? ref.title;
      case ItemType.symbol:
        return symbol(ref.id)?.name ?? ref.title;
      case ItemType.peripheral:
        return peripheral(ref.id)?.nameZh ?? ref.title;
      case ItemType.pin:
        return pinout.pinByNumber(int.tryParse(ref.id) ?? -1)?.name ?? ref.title;
      case ItemType.compileError:
        return compileErrorById[ref.id]?.titleZh ?? ref.title;
    }
  }

  /// 按 [ItemRef] 取副标题（一般是所属外设中文名）。
  String subtitleOf(ItemRef ref) {
    switch (ref.type) {
      case ItemType.function:
        final f = function(ref.id);
        return f == null ? ref.subtitle : (peripheral(f.peripheral)?.nameZh ?? f.peripheral);
      case ItemType.symbol:
        final s = symbol(ref.id);
        return s == null ? ref.subtitle : (peripheral(s.peripheral)?.nameZh ?? s.peripheral);
      case ItemType.peripheral:
        return '外设';
      case ItemType.pin:
        final p = pinout.pinByNumber(int.tryParse(ref.id) ?? -1);
        return p == null ? ref.subtitle : 'LQFP48 第 ${p.number} 脚';
      case ItemType.compileError:
        final e = compileErrorById[ref.id];
        return e == null ? ref.subtitle : e.toolchain;
    }
  }

  /// 把 [ItemRef] 补全成带标题与副标题的快照（写库前调用）。
  ItemRef enrich(ItemRef ref) => ItemRef(
        type: ref.type,
        id: ref.id,
        title: titleOf(ref),
        subtitle: subtitleOf(ref),
      );
}
