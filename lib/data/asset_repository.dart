import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/chip.dart';
import '../models/compile_error.dart';
import '../models/function_item.dart';
import '../models/library_kind.dart';
import '../models/manifest.dart';
import '../models/peripheral.dart';
import '../models/pin.dart';
import '../models/spl_data.dart';
import '../models/symbol_item.dart';

/// 数据加载失败时抛出的异常。
///
/// 页面捕获它并显示友好提示，避免白屏（需求：assets 加载失败要有友好提示）。
class AssetLoadException implements Exception {
  /// 出错的资源路径
  final String assetPath;

  /// 底层原因
  final Object? cause;

  const AssetLoadException(this.assetPath, [this.cause]);

  @override
  String toString() {
    final base = '数据文件加载失败：$assetPath';
    return cause == null ? base : '$base\n$cause';
  }
}

/// 数据版本不匹配时抛出。数据是重新生成的，需要用户重装或重新生成数据。
class DataVersionException implements Exception {
  final int found;
  final int expected;

  const DataVersionException(this.found, this.expected);

  @override
  String toString() =>
      '数据结构版本不匹配：数据为 v$found，APP 需要 v$expected。请重新生成 assets/data。';
}

// ---------------------------------------------------------------------------
// 供 compute 使用的顶层解码函数
//
// JSON 解析放在独立 isolate 里做，避免 1.5 MB 的 symbols.json 阻塞 UI 线程。
// compute 要求函数是顶层函数，所以不能写成闭包。
// ---------------------------------------------------------------------------

Map<String, dynamic> _decodeMap(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

/// 静态数据仓库。
///
/// 分层加载策略（需求：JSON 一次性加载进内存，不要每次进页面都重新读文件）：
///   - [loadCore]      启动时调用，读 manifest / peripherals / chip / symbols /
///                     pinout / compile_errors，构建全部内存索引
///   - [loadFunctionsOf] 进外设详情页时按需读「某外设 + 某库」的函数
///   - [loadHalSymbols]  需要 HAL/LL 符号时读 symbols_hal.json
///   - [loadRegisterSymbols] 查看寄存器位域时才读（2.7 MB，不拖慢首屏）
///
/// 所有读过的数据都缓存，重复调用不会重复读文件。
class AssetRepository {
  /// assets 下数据根目录
  static const String dataRoot = 'assets/data';

  /// 超过这个大小就用 compute 在独立 isolate 里解析，避免卡 UI。
  /// 阈值取 200 KB：小文件直接解析更快（省掉 isolate 启动开销）。
  static const int _computeThreshold = 200 * 1024;

  /// 函数文件缓存：键为 `"${lib.raw}:$peripheralId"`（如 "hal:GPIO"）
  final Map<String, FunctionBundle> _functionCache = {};

  /// 寄存器位定义符号缓存（整包读一次）
  List<SymbolItem>? _registerSymbols;

  /// HAL/LL 符号缓存（用 null 表示"没读过"，与"读过但为空"区分开）
  List<SymbolItem>? _halSymbols;

  /// 首屏核心数据缓存
  SplData? _core;

  /// 已加载的核心数据；未加载时为 null。
  SplData? get cachedCore => _core;

  /// 已缓存的函数包数量（调试用）
  int get cachedFunctionBundleCount => _functionCache.length;

  /// 函数缓存键：库 + 外设
  static String _cacheKey(String peripheralId, LibraryKind lib) =>
      '${lib.raw}:$peripheralId';

  // ---- 路径拼接 ----

  /// 拼接 assets 路径，容忍 manifest 里带或不带结尾斜杠。
  String _asset(String relative) {
    final rel = relative.startsWith('/') ? relative.substring(1) : relative;
    return '$dataRoot/$rel';
  }

  /// 把 manifest 里的目录项与文件名拼起来，如 "chips/" + "xxx" + ".json"。
  String _join(String dir, String name, String ext) {
    var d = dir;
    if (d.endsWith('/')) d = d.substring(0, d.length - 1);
    return d.isEmpty ? '$name$ext' : '$d/$name$ext';
  }

  // ---- 底层读取 ----

  /// 读取并解析一个 JSON 对象文件。
  ///
  /// 大文件走 compute 在独立 isolate 解析。失败时抛 [AssetLoadException]。
  Future<Map<String, dynamic>> _loadJson(String relative) async {
    final path = _asset(relative);
    try {
      final source = await rootBundle.loadString(path);
      if (source.length >= _computeThreshold) {
        return await compute(_decodeMap, source);
      }
      return _decodeMap(source);
    } on FlutterError catch (e) {
      // rootBundle 找不到资源时抛 FlutterError
      throw AssetLoadException(path, e);
    } on FormatException catch (e) {
      // JSON 语法错误
      throw AssetLoadException(path, e);
    }
  }

  /// 尝试读取；文件不存在等任何失败都返回 null（不抛）。
  ///
  /// 用于「可能没有」的增强数据（HAL/LL/reg 函数文件、symbols_hal.json）。
  Future<Map<String, dynamic>?> _tryLoadJson(String relative) async {
    try {
      return await _loadJson(relative);
    } on AssetLoadException catch (e) {
      debugPrint('[AssetRepository] 可选数据缺失，跳过：$e');
      return null;
    }
  }

  // ---- 核心数据 ----

  /// 加载首屏所需的全部核心数据并构建内存索引。
  ///
  /// 结果会被缓存，重复调用直接返回同一实例。
  Future<SplData> loadCore({bool forceReload = false}) async {
    if (!forceReload && _core != null) return _core!;

    final manifestJson = await _loadJson('manifest.json');
    final manifest = DataManifest.fromJson(manifestJson);

    // 版本校验：不匹配时明确报错，而不是让页面到处崩
    if (!manifest.isSchemaCompatible) {
      throw DataVersionException(
        manifest.schemaVersion,
        DataManifest.currentSchemaVersion,
      );
    }

    // 外设与函数分组
    final peripheralBundle =
        PeripheralBundle.fromJson(await _loadJson('peripherals.json'));

    // 芯片能力
    final chipDir = manifest.fileOf('chips', fallback: 'chips/');
    final chipPath = _join(chipDir, manifest.defaultChipId, '.json');
    final chip = ChipSpec.fromJson(await _loadJson(chipPath));

    // 符号（API 符号，首屏就要建搜索索引）
    final symbolBundle =
        SymbolBundle.fromJson(await _loadJson('symbols.json'));

    // HAL/LL 符号（3.77 MB）。
    //
    // 必须在这里加载，不能留成"按需"：搜索索引、关键词跳转、函数详情页的
    // 参数类型跳转、同名类型切换全都要用。早先 `loadHalSymbols()` 写好了
    // 但**全项目无人调用**，于是运行时 halSymbols 恒为空——
    // 表现就是搜不到 `ADC_HandleTypeDef`、HAL 函数里的类型名点不动、
    // `GPIO_InitTypeDef` 永远只显示 SPL 那份。
    //
    // 3.77 MB 走 compute 在独立 isolate 解析，不阻塞 UI；
    // 相比"功能静默失效"，这点启动开销是值得的。
    List<SymbolItem> halSymbols = const <SymbolItem>[];
    final halSymbolPath = manifest.fileOf('symbolsHal', fallback: 'symbols_hal.json');
    try {
      final halBundle =
          SymbolBundle.fromJson(await _loadJson(halSymbolPath));
      halSymbols = halBundle.symbols;
    } catch (e) {
      // v1 数据没有这个文件；缺失时降级为空，不影响 SPL 部分可用
      debugPrint('[AssetRepository] HAL 符号加载失败，降级为空：$e');
    }

    // 引脚
    final pinoutPath = manifest.fileOf('pinout', fallback: 'pinout_f103c8t6.json');
    PinoutData pinout;
    try {
      pinout = PinoutData.fromJson(await _loadJson(pinoutPath));
    } catch (e) {
      // 引脚数据缺失不该让整个 APP 起不来，降级为空数据
      debugPrint('[AssetRepository] 引脚数据加载失败，降级为空：$e');
      pinout = PinoutData(
        schemaVersion: 1,
        chipId: manifest.defaultChipId,
        package: chip.package,
        source: '',
        verified: false,
        verifiedNote: '引脚数据缺失',
        pins: const [],
      );
    }

    // 编译错误
    final errorPath =
        manifest.fileOf('compileErrors', fallback: 'compile_errors.json');
    CompileErrorBundle compileErrors;
    try {
      compileErrors = CompileErrorBundle.fromJson(await _loadJson(errorPath));
    } catch (e) {
      debugPrint('[AssetRepository] 编译错误数据加载失败，降级为空：$e');
      compileErrors = const CompileErrorBundle(schemaVersion: 1);
    }

    // 外设按 orderIndex 排序（首页"按使用频率排序"的依据）
    final peripherals = List<Peripheral>.from(peripheralBundle.peripherals)
      ..sort((a, b) {
        final byOrder = a.orderIndex.compareTo(b.orderIndex);
        return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
      });

    // 函数详情不在这里加载（按需读），所以核心数据的 functions 先为空，
    // 索引里放外设、符号（SPL + HAL/LL）、引脚、编译错误。
    final data = SplData(
      manifest: manifest,
      chip: chip,
      peripherals: peripherals,
      functions: const [],
      symbols: symbolBundle.symbols,
      halSymbols: halSymbols,
      pinout: pinout,
      compileErrors: compileErrors,
    );
    _core = data;
    return data;
  }

  // ---- 按需数据 ----

  /// 读取某个外设的 SPL 函数详情，带缓存。
  ///
  /// **这是一个可覆写的接缝（seam）**：SPL 是 v1 时代唯一的库，既有测试替身
  /// 都通过覆写本方法来注入内存数据。所以 [loadFunctionsOf] 遇到 spl 时会
  /// 走这里而不是直接读文件——否则覆写了本方法的替身会失效，
  /// 老测试会去读真实 assets 而挂住。
  Future<FunctionBundle> loadFunctions(String peripheralId) =>
      _readFunctionsOf(peripheralId, LibraryKind.spl);

  /// 读取「某外设 + 某库」的函数详情，带缓存。
  ///
  /// 路径由 manifest.functionDirs 决定（契约 §6）：
  /// `functions/{外设}.json` 或 `functions/{lib}/{外设}.json`。
  ///
  /// spl 走 [loadFunctions]，保证 v1 时代覆写该方法的替身依然生效；
  /// 其余库直接读文件。
  ///
  /// HAL/LL/reg 的文件**可能不存在**（该外设没这个库的实现，这是常态）。
  /// 此时返回 [FunctionBundle.empty] 而不是抛异常：外设详情页切到该库时
  /// 应该显示"该外设暂无 HAL 库函数"，不是弹一个加载失败。
  Future<FunctionBundle> loadFunctionsOf(
    String peripheralId,
    LibraryKind lib,
  ) {
    if (lib == LibraryKind.spl) return loadFunctions(peripheralId);
    return _readFunctionsOf(peripheralId, lib);
  }

  /// 真正的读取实现（含缓存）。
  Future<FunctionBundle> _readFunctionsOf(
    String peripheralId,
    LibraryKind lib,
  ) async {
    final key = _cacheKey(peripheralId, lib);
    final cached = _functionCache[key];
    if (cached != null) return cached;

    final dir = _core?.manifest.functionDirOf(lib) ?? _resolveLegacyDir(lib);
    final path = _join(dir, peripheralId, '.json');

    final json = await _tryLoadJson(path);
    if (json == null) {
      final empty = FunctionBundle.empty(peripheral: peripheralId, library: lib);
      _functionCache[key] = empty;
      return empty;
    }

    final bundle = FunctionBundle.fromJson(json);
    _functionCache[key] = bundle;
    return bundle;
  }

  /// 核心数据还没加载时（例如单测直接调 loadFunctionsOf）猜一下目录。
  ///
  /// spl 与 v1 数据都在 `functions/`；其它库按契约固定为 `functions/<lib>/`。
  static String _resolveLegacyDir(LibraryKind lib) =>
      lib == LibraryKind.spl ? 'functions/' : 'functions/${lib.raw}/';

  /// 某外设某库的函数是否已经读过（避免重复读文件）。
  bool hasFunctionsOf(String peripheralId, LibraryKind lib) =>
      _functionCache.containsKey(_cacheKey(peripheralId, lib));

  /// 读取 SPL 寄存器位定义符号（2.7 MB，只在需要时读一次）。
  Future<List<SymbolItem>> loadRegisterSymbols() async {
    final cached = _registerSymbols;
    if (cached != null) return cached;

    final dir = _core?.manifest.fileOf('registers', fallback: 'registers.json') ??
        'registers.json';
    try {
      final bundle = SymbolBundle.fromJson(await _loadJson(dir));
      _registerSymbols = bundle.symbols;
    } catch (e) {
      // 寄存器位定义是增强功能，缺失时降级为空而不是报错
      debugPrint('[AssetRepository] 寄存器位定义加载失败，降级为空：$e');
      _registerSymbols = const <SymbolItem>[];
    }
    return _registerSymbols!;
  }

  /// 读取 HAL/LL 符号（`symbols_hal.json`），带缓存。
  ///
  /// 文件不存在（v1 数据、或生成器还没产出）时降级为空列表，不抛异常：
  /// 它只是让关键词跳转多认几个名字，缺失不该让页面崩。
  Future<List<SymbolItem>> loadHalSymbols() async {
    final cached = _halSymbols;
    if (cached != null) return cached;

    final path =
        _core?.manifest.fileOf('symbolsHal', fallback: 'symbols_hal.json') ??
            'symbols_hal.json';
    final json = await _tryLoadJson(path);
    if (json == null) {
      _halSymbols = const <SymbolItem>[];
      return _halSymbols!;
    }
    try {
      _halSymbols = SymbolBundle.fromJson(json).symbols;
    } catch (e) {
      debugPrint('[AssetRepository] HAL 符号解析失败，降级为空：$e');
      _halSymbols = const <SymbolItem>[];
    }
    return _halSymbols!;
  }

  /// 清空缓存（设置页"重新加载数据"用）。
  void clearCache() {
    _functionCache.clear();
    _registerSymbols = null;
    _halSymbols = null;
    _core = null;
  }
}
