import 'package:collection/collection.dart';

import '../models/chip.dart';
import '../models/compile_error.dart';
import '../models/function_item.dart';
import '../models/item_ref.dart';
import '../models/library_kind.dart';
import '../models/pin.dart';
import '../models/spl_data.dart';
import '../models/symbol_item.dart';

/// 搜索结果的类别。
enum SearchCategory {
  function('函数'),
  symbol('符号'),
  peripheral('外设'),
  pin('引脚'),
  compileError('编译错误');

  /// 中文显示名
  final String labelZh;

  const SearchCategory(this.labelZh);
}

/// 一条搜索结果。
class SearchHit {
  /// 条目类型（用于跳转与收藏）
  final ItemType itemType;

  /// 条目 id
  final String id;

  /// 主标题（函数名 / 符号名 / 外设名 / 引脚名 / 错误标题）
  final String title;

  /// 副标题（所属外设中文名等）
  final String subtitle;

  /// 一句话说明（中文优先）
  final String description;

  /// 所属外设 id，可为空
  final String peripheralId;

  /// 匹配得分，越大越靠前
  final int score;

  /// 命中的字段名（用于结果项上显示"匹配到哪里"）
  final String matchedField;

  /// 这条结果所属的库（v2.0.3 新增）。
  ///
  /// 为 null 表示"与库无关"（引脚、编译错误、外设本身不属于任何库）。
  ///
  /// 为什么必须有这个字段：设置页可以关掉某个库，搜索结果要跟着过滤。
  /// 早先是靠「id 是否以 HAL_/LL_/REG_ 开头」反推的，但 HAL 里有 3313 个
  /// 符号并不带这些前缀（`GPIO_InitTypeDef@hal`、`ADC_HandleTypeDef`…），
  /// 一律被误判成标准库——关掉 SPL 想只看 HAL 时，这些符号会整片消失。
  /// 现在索引构建时直接从数据里取库属性，不再猜。
  final LibraryKind? library;

  const SearchHit({
    required this.itemType,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.description = '',
    this.peripheralId = '',
    this.score = 0,
    this.matchedField = '',
    this.library,
  });

  /// 转成可收藏/可记录的引用
  ItemRef toRef() => ItemRef(
        type: itemType,
        id: id,
        title: title,
        subtitle: subtitle,
      );

  SearchCategory get category {
    switch (itemType) {
      case ItemType.function:
        return SearchCategory.function;
      case ItemType.symbol:
        return SearchCategory.symbol;
      case ItemType.peripheral:
        return SearchCategory.peripheral;
      case ItemType.pin:
        return SearchCategory.pin;
      case ItemType.compileError:
        return SearchCategory.compileError;
    }
  }
}

/// 索引里的一个可搜索条目。
class _IndexEntry {
  final ItemType itemType;
  final String id;
  final String title;
  final String subtitle;
  final String description;
  final String peripheralId;

  /// 小写化的主键（英文名），用于前缀匹配
  final String keyLower;

  /// 小写化的全部可搜索文本（含中文），用于子串匹配
  final String haystack;

  /// 是否内部符号（IS_* 断言宏），默认搜索时过滤
  final bool internal;

  /// 所属库；null 表示与库无关（引脚/编译错误/外设本身）
  final LibraryKind? library;

  const _IndexEntry({
    required this.itemType,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.peripheralId,
    required this.keyLower,
    required this.haystack,
    this.internal = false,
    this.library,
  });
}

/// 内存搜索索引。
///
/// 设计要点（需求 5.4）：
///   - 启动时一次性建好，搜索是纯内存操作，无需防抖超过 150ms
///   - 英文不区分大小写；前缀匹配优先（搜 GPIO_In 时 GPIO_Init 排第一）
///   - 支持中文子串匹配
///   - 结果按类型分组
///   - 默认不返回内部断言宏（IS_* 有 350 个），可开关
class SearchIndex {
  final List<_IndexEntry> _entries;

  /// 外设 id → 中文名，用于给结果补副标题
  final Map<String, String> _peripheralNames;

  /// 索引条目总数
  int get entryCount => _entries.length;

  SearchIndex._(this._entries, this._peripheralNames);

  /// 用核心数据构建索引。
  ///
  /// [functions] 可为空——函数详情是按需加载的，首屏时可能还没读。
  /// 进过外设页后可以用 [withFunctions] 增量补充。
  factory SearchIndex.build(
    SplData data, {
    List<FunctionItem> functions = const [],
  }) {
    final entries = <_IndexEntry>[];
    final periphNames = <String, String>{};
    for (final p in data.peripherals) {
      periphNames[p.id] = p.nameZh.isEmpty ? p.name : p.nameZh;
    }

    // 外设
    for (final p in data.peripherals) {
      entries.add(_IndexEntry(
        itemType: ItemType.peripheral,
        id: p.id,
        title: p.name,
        subtitle: p.nameZh,
        description: p.oneLineIntro,
        peripheralId: p.id,
        keyLower: p.name.toLowerCase(),
        haystack: [
          p.name,
          p.nameZh,
          p.id,
          p.introZh,
          p.usageOverviewZh,
          ...p.tags,
        ].join(' ').toLowerCase(),
      ));
    }

    // 符号：SPL + HAL/LL 两批都要进索引。
    //
    // `data.symbols` 只是 SPL 那份，HAL/LL 的 5021 个符号在 `data.halSymbols`。
    // 早先这里只遍历了前者，导致 `ADC_HandleTypeDef`、`ConvCpltCallback`、
    // `GPIO_InitTypeDef@hal` 这类 HAL 类型**搜不到**——而它们恰恰是查 HAL 时
    // 最常要找的东西。两批合并后再建条目，`_symbolEntry` 会带上各自库属性。
    for (final s in <SymbolItem>[...data.symbols, ...data.halSymbols]) {
      entries.add(_symbolEntry(s, periphNames));
    }

    // 引脚：标题用引脚名，同时把功能名也纳入搜索
    for (final pin in data.pinout.pins) {
      final fnNames = pin.functions.map((f) => f.name).join(' ');
      entries.add(_IndexEntry(
        itemType: ItemType.pin,
        id: '${pin.number}',
        title: pin.name,
        subtitle: '第 ${pin.number} 脚 · ${pin.defaultFunction}',
        description: pin.defaultFunctionZh,
        peripheralId: pin.portName.isEmpty ? '' : 'GPIO',
        keyLower: pin.name.toLowerCase(),
        haystack: [
          pin.name,
          pin.defaultFunction,
          pin.defaultFunctionZh,
          fnNames,
          pin.notesZh,
          '${pin.number}',
        ].join(' ').toLowerCase(),
      ));
    }

    // 编译错误
    for (final e in data.compileErrors.errors) {
      entries.add(_IndexEntry(
        itemType: ItemType.compileError,
        id: e.id,
        title: e.titleZh,
        subtitle: e.toolchain,
        description: e.explainZh,
        peripheralId: e.relatedPeripheralIds.isNotEmpty
            ? e.relatedPeripheralIds.first
            : '',
        keyLower: e.titleZh.toLowerCase(),
        haystack: e.searchableText.toLowerCase(),
      ));
    }

    // 函数：先按外设的 functionIds 建"仅函数名"的条目。
    //
    // 函数详情是按需加载的，首屏拿不到 briefZh，但**函数名必须能搜到**——
    // 需求 5.4 明确要求搜索范围含"函数名"。所以这里先用 functionIds 建条目
    // （标题=函数名，副标题=所属外设），进过外设页后再用 withFunctions
    // 补充中文简述等详情。
    final detailed = {for (final f in functions) f.id: f};
    final seenFn = <String>{};
    for (final p in data.peripherals) {
      // 按 section 遍历而不是 p.allFunctionIds：
      // 只有 section 带 library，靠它给每个函数结果打上库标签，
      // 设置页关掉某个库时搜索结果才能准确过滤。
      for (final sec in p.sections) {
        for (final fid in sec.functionIds) {
          if (!seenFn.add(fid)) continue;
          final f = detailed[fid];
          if (f != null) {
            entries.add(_functionEntry(f, periphNames));
          } else {
            entries.add(_IndexEntry(
              itemType: ItemType.function,
              id: fid,
              title: fid,
              subtitle: periphNames[p.id] ?? p.id,
              description: '',
              peripheralId: p.id,
              keyLower: fid.toLowerCase(),
              haystack: fid.toLowerCase(),
              library: sec.library,
            ));
          }
        }
      }
    }
    // 已加载但不在 functionIds 里的（理论上没有，保险起见）
    for (final f in functions) {
      if (!seenFn.contains(f.id)) {
        entries.add(_functionEntry(f, periphNames));
      }
    }

    return SearchIndex._(entries, periphNames);
  }

  static _IndexEntry _symbolEntry(SymbolItem s, Map<String, String> periphNames) {
    final members = s.members.map((m) => m.name).join(' ');
    final membersDesc =
        s.members.map((m) => '${m.descEn} ${m.descZh}').join(' ');
    return _IndexEntry(
      itemType: ItemType.symbol,
      // 用 s.id 而不是 s.name：HAL/SPL 同名但定义不同的类型靠库限定 id 区分
      // （`GPIO_InitTypeDef@hal` 与 `GPIO_InitTypeDef`）。早先这里用 name，
      // 结果搜到 HAL 的类型点进去打开的是 SPL 那份，成员完全不同。
      id: s.id,
      title: s.name,
      subtitle: '${s.kindLabelZh} · ${periphNames[s.peripheral] ?? s.peripheral}',
      description: s.displayBrief,
      peripheralId: s.peripheral,
      keyLower: s.name.toLowerCase(),
      // 结构体成员名也要能搜到（需求：结构体名及其成员名）
      haystack: [
        s.name,
        s.briefZh,
        s.briefEn,
        s.usageZh,
        s.value ?? '',
        members,
        membersDesc,
      ].join(' ').toLowerCase(),
      internal: s.isInternal,
      library: s.library,
    );
  }

  static _IndexEntry _functionEntry(
    FunctionItem f,
    Map<String, String> periphNames,
  ) {
    return _IndexEntry(
      itemType: ItemType.function,
      id: f.id,
      title: f.name,
      subtitle: periphNames[f.peripheral] ?? f.peripheral,
      description: f.displayBrief,
      peripheralId: f.peripheral,
      keyLower: f.name.toLowerCase(),
      haystack: [
        f.name,
        f.briefZh,
        f.briefEn,
        f.usageZh,
        ...f.notesZh,
        ...f.prerequisites,
        ...f.params.map((p) => '${p.name} ${p.type} ${p.descZh}'),
      ].join(' ').toLowerCase(),
      library: f.library,
    );
  }

  /// 返回一个补充了函数详情的新索引（进过外设页后调用）。
  ///
  /// 首屏建的函数条目只有函数名（详情按需加载），这里用真实详情**替换**
  /// 那些占位条目，从而让中文简述、参数名、注意事项也进入搜索范围。
  SearchIndex withFunctions(
    List<FunctionItem> functions,
    SplData data,
  ) {
    if (functions.isEmpty) return this;
    final byId = {for (final f in functions) f.id: f};

    final updated = <_IndexEntry>[];
    var replaced = 0;
    for (final e in _entries) {
      final f = (e.itemType == ItemType.function) ? byId[e.id] : null;
      if (f == null) {
        updated.add(e);
      } else {
        updated.add(_functionEntry(f, _peripheralNames));
        replaced++;
      }
    }
    // 已加载但索引里没有的（保险起见）
    final known = _entries
        .where((e) => e.itemType == ItemType.function)
        .map((e) => e.id)
        .toSet();
    for (final f in functions) {
      if (!known.contains(f.id)) {
        updated.add(_functionEntry(f, _peripheralNames));
      }
    }
    if (replaced == 0 && updated.length == _entries.length) return this;
    return SearchIndex._(updated, _peripheralNames);
  }

  /// 执行搜索。
  ///
  /// 评分规则（分数越高越靠前）：
  ///   - 主键完全相等          1000
  ///   - 主键前缀匹配           600（越短越靠前，体现"前缀匹配优先"）
  ///   - 主键子串匹配           400
  ///   - 中文/说明文本子串匹配   100
  ///
  /// [includeInternal] 为 true 时返回 IS_* 断言宏。
  /// [limitPerCategory] 限制每类结果数量，避免一次返回上千条。
  List<SearchHit> search(
    String keyword, {
    bool includeInternal = false,
    int limitPerCategory = 50,
  }) {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) return const <SearchHit>[];

    // 缩写查询（如 "uart" 想找 "USART_Init"）：USART 里并不含子串 "uart"，
    // 但 "uart" 是 "usart" 的**子序列**（跳过 s）。需求验收点明确要求
    // "搜索 uart 能搜到 USART 相关函数"，所以对纯字母查询额外做子序列匹配。
    final allowSubsequence = RegExp(r'^[a-z]+$').hasMatch(q) && q.length >= 3;

    final hits = <SearchHit>[];
    for (final e in _entries) {
      if (e.internal && !includeInternal) continue;

      int score = 0;
      String field = '';
      if (e.keyLower == q) {
        score = 1000;
        field = '名称';
      } else if (e.keyLower.startsWith(q)) {
        // 前缀匹配：主键越短说明越贴近关键词，给更高分
        score = 600 - (e.keyLower.length - q.length).clamp(0, 200);
        field = '名称前缀';
      } else if (e.keyLower.contains(q)) {
        score = 400;
        field = '名称';
      } else if (e.haystack.contains(q)) {
        score = 100;
        field = '说明';
      } else if (allowSubsequence && _isSubsequence(q, e.keyLower)) {
        // 子序列匹配，排在子串匹配之后
        score = 200;
        field = '名称缩写';
      } else {
        continue;
      }

      hits.add(SearchHit(
        itemType: e.itemType,
        id: e.id,
        title: e.title,
        subtitle: e.subtitle,
        description: e.description,
        peripheralId: e.peripheralId,
        score: score,
        matchedField: field,
        library: e.library,
      ));
    }

    // 排序：得分降序，同分时短名字优先（GPIO_Init 排在 GPIO_InitStruct 前）
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byLen = a.title.length.compareTo(b.title.length);
      if (byLen != 0) return byLen;
      return a.title.compareTo(b.title);
    });

    // 每类限量
    final counts = <SearchCategory, int>{};
    final limited = <SearchHit>[];
    for (final h in hits) {
      final c = h.category;
      final n = counts[c] ?? 0;
      if (n >= limitPerCategory) continue;
      counts[c] = n + 1;
      limited.add(h);
    }
    return limited;
  }

  /// 判断 [needle] 是否是 [haystack] 的子序列（按顺序出现但不必连续）。
  ///
  /// 用于缩写查询：uart ⊂ usart、gpi  ⊂ gpio_init。
  static bool _isSubsequence(String needle, String haystack) {
    var i = 0;
    for (var j = 0; j < haystack.length && i < needle.length; j++) {
      if (haystack[j] == needle[i]) i++;
    }
    return i == needle.length;
  }

  /// 按类别分组，供结果页分段展示。
  ///
  /// 组内保持搜索的排序结果；组的顺序按 [SearchCategory] 声明顺序。
  Map<SearchCategory, List<SearchHit>> groupByCategory(List<SearchHit> hits) {
    final map = <SearchCategory, List<SearchHit>>{};
    for (final h in hits) {
      map.putIfAbsent(h.category, () => <SearchHit>[]).add(h);
    }
    return map;
  }

  /// 按功能名反查引脚（引脚页的"按功能找引脚"用）。
  ///
  /// 这里是薄封装，实际逻辑在 [PinoutData.searchByFunction]。
  static List<Pin> pinsByFunction(PinoutData pinout, String keyword) =>
      pinout.searchByFunction(keyword);

  /// 取某外设下的全部命中（收藏页"按外设分组"用）。
  static List<SearchHit> filterByPeripheral(
    List<SearchHit> hits,
    String peripheralId,
  ) =>
      hits.where((h) => h.peripheralId == peripheralId).toList();

  /// 调试用：统计各类条目数。
  Map<ItemType, int> statsByType() {
    final map = <ItemType, int>{};
    for (final e in _entries) {
      map[e.itemType] = (map[e.itemType] ?? 0) + 1;
    }
    return map;
  }

  /// 便捷查询：某外设的函数条目（用于外设详情页的本地过滤）。
  List<SearchHit> functionsOfPeripheral(String peripheralId) => _entries
      .where((e) =>
          e.itemType == ItemType.function && e.peripheralId == peripheralId)
      .map((e) => SearchHit(
            itemType: e.itemType,
            id: e.id,
            title: e.title,
            subtitle: e.subtitle,
            description: e.description,
            peripheralId: e.peripheralId,
            library: e.library,
          ))
      .toList();

  /// 便捷查询：取符号条目（用于 KeywordText 的跳转判断兜底）。
  ///
  /// 同时匹配 id 与显示名：库限定符号的 id 是 `GPIO_InitTypeDef@hal`，
  /// 而调用方手里通常只有源码里的裸名字 `GPIO_InitTypeDef`。
  bool hasSymbol(String name) => _entries.any(
        (e) => e.itemType == ItemType.symbol && (e.id == name || e.title == name),
      );

  /// 便捷查询：取编译错误分类。
  static CompileErrorCategory? categoryOf(
    CompileErrorBundle bundle,
    String categoryId,
  ) =>
      bundle.categories.firstWhereOrNull((c) => c.id == categoryId);

  /// 芯片是否支持该外设（首页开关用）。
  static bool isSupported(ChipSpec chip, String peripheralId) =>
      chip.supportsPeripheral(peripheralId);
}
