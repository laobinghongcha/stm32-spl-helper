import '../utils/json_parse.dart';
import 'library_kind.dart';

/// `assets/data/manifest.json` 的模型：数据版本与文件清单。
///
/// APP 启动时最先读它，用于：
/// 1. 校验 [schemaVersion]（与代码期望不符时提示用户重新生成数据，而不是崩溃）；
/// 2. 拿到各数据文件的相对路径，做到"路径也是数据驱动"；
/// 3. 设置页展示数据版本与生成时间。
class DataManifest {
  /// 数据结构版本，代码里用 [currentSchemaVersion] 比对
  final int schemaVersion;

  /// 数据内容版本，如 "2.0.0"，每次重新生成数据时由脚本递增
  final String dataVersion;

  /// SPL 数据来源版本，如 "STM32F10x_StdPeriph_Lib_V3.5.0"
  final String splVersion;

  /// HAL/LL 数据来源版本，如 "STM32Cube_FW_F1_V1.8.7"（v2 新增，v1 数据为空）
  final String halVersion;

  /// 默认芯片 id，如 "stm32f103c8t6"
  final String defaultChipId;

  /// 生成时间（ISO8601 字符串，含时区）
  final String generatedAt;

  /// 生成工具名
  final String generator;

  /// 各类数据的条数统计
  final DataStats stats;

  /// 数据文件相对路径表，键为数据种类
  final Map<String, String> files;

  /// 各库的函数目录（v2 新增），如 `{"spl":"functions/", "hal":"functions/hal/"}`。
  ///
  /// v1 数据没有这一段，[functionDirOf] 会回退到 [files] 里的 `functions`
  /// 或默认 `functions/`，所以老数据照常能读。
  final Map<String, String> functionDirs;

  const DataManifest({
    required this.schemaVersion,
    required this.dataVersion,
    required this.splVersion,
    required this.defaultChipId,
    required this.generatedAt,
    required this.generator,
    required this.stats,
    required this.files,
    this.halVersion = '',
    this.functionDirs = const <String, String>{},
  });

  /// 当前代码支持的数据结构版本。数据版本升级时同步改这里。
  ///
  /// v2 起支持四库（spl/hal/ll/reg）。读 v1 数据时 [isSchemaCompatible]
  /// 会返回 false —— 这是有意的：v2 代码把「库」当成一等概念，
  /// 旧的 peripherals.json 里没有 libraries/functionDirs，
  /// 只靠兜底虽然不会崩，但界面上会缺 HAL/LL/reg 三栏。
  static const int currentSchemaVersion = 2;

  /// 代码能兼容读取的最老结构版本。
  ///
  /// v1 数据（纯 SPL）在 v2 代码下**仍可读取**：所有新字段都有兜底，
  /// libraries 会由旧字段包装出 spl 一项，functionDirs 缺失时回退到
  /// `functions/`。所以兼容下限是 1，不是 2。
  static const int minCompatibleSchemaVersion = 1;

  /// 数据结构版本是否可用。
  ///
  /// 口径是「落在 [minCompatibleSchemaVersion, currentSchemaVersion] 之间」，
  /// 而不是「严格等于当前版本」：严格相等会让 v1 老数据直接打不开，
  /// 而用户的旧安装包里 assets 还是 v1——那时应该降级显示（只有标准库），
  /// 不是报"版本不匹配"白屏。
  ///
  /// 也不用「>= 下限」：那样 v99 这种未来结构会被当成可读，
  /// 字段语义一变就会静默解析错。
  bool get isSchemaCompatible =>
      schemaVersion >= minCompatibleSchemaVersion &&
      schemaVersion <= currentSchemaVersion;

  /// 是否是最新的 v2 结构（设置页用来提示"数据待更新"）。
  bool get isLatest => schemaVersion >= currentSchemaVersion;

  /// 是否是老结构（v1，只有标准库）。UI 可据此提示"数据可更新到四库"。
  bool get isLegacy => schemaVersion < currentSchemaVersion;

  /// 取某个数据文件的相对路径，缺失时返回 [fallback]。
  String fileOf(String key, {String fallback = ''}) =>
      files[key] ?? fallback;

  /// 取某个库的函数目录，如 `functions/hal/`（总是带结尾斜杠）。
  ///
  /// 回退规则分两档，**不能一概回退到 `functions/`**：
  ///   - `spl`：v1 数据里 `functions/` 就是标准库目录，所以回退到
  ///     `files['functions']`（再退到 `'functions/'`）；v1 数据因此照常可读。
  ///   - `hal` / `ll` / `reg`：v1 数据里**根本不存在**这些库。若无脑回退到
  ///     `functions/`，读出来的会是 SPL 的函数文件，却被打上 HAL 的标签——
  ///     界面上就会出现"HAL 页签里全是 GPIO_Init"这种错乱。
  ///     所以按契约 §2 的固定布局回退到 `functions/<库>/`，
  ///     目录或文件不存在时仓库层返回空 bundle，正好对应"该外设没有这个库"。
  String functionDirOf(LibraryKind lib) {
    final declared = functionDirs[lib.raw];
    if (declared != null && declared.isNotEmpty) return _withSlash(declared);

    if (lib != LibraryKind.spl) return 'functions/${lib.raw}/';

    final base = files['functions'];
    if (base != null && base.isNotEmpty) return _withSlash(base);
    return 'functions/';
  }

  /// 该库的 functionDirs 是否由数据显式声明（vs 全走回退）。
  bool hasFunctionDirOf(LibraryKind lib) =>
      (functionDirs[lib.raw] ?? '').isNotEmpty;

  static String _withSlash(String dir) =>
      dir.endsWith('/') ? dir : '$dir/';

  factory DataManifest.fromJson(Map<String, dynamic> json) {
    final rawFiles = asObject(json['files']);
    final rawDirs = asObject(json['functionDirs']);
    return DataManifest(
      schemaVersion: asInt(json['schemaVersion'], fallback: 0),
      dataVersion: asString(json['dataVersion'], fallback: '未知'),
      splVersion: asString(json['splVersion'], fallback: '未知'),
      halVersion: asString(json['halVersion']),
      defaultChipId: asString(json['defaultChipId'], fallback: 'stm32f103c8t6'),
      generatedAt: asString(json['generatedAt']),
      generator: asString(json['generator']),
      stats: DataStats.fromJson(asObject(json['stats'])),
      files: rawFiles.map((k, v) => MapEntry(k, asString(v))),
      functionDirs: rawDirs.map((k, v) => MapEntry(k, asString(v))),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'dataVersion': dataVersion,
        'splVersion': splVersion,
        'halVersion': halVersion,
        'defaultChipId': defaultChipId,
        'generatedAt': generatedAt,
        'generator': generator,
        'stats': stats.toJson(),
        'files': files,
        'functionDirs': functionDirs,
      };
}

/// 数据条数统计，用于设置页展示与自检。
class DataStats {
  final int peripheralCount;
  final int functionCount;
  final int symbolCount;
  final int pinCount;
  final int compileErrorCount;

  /// 各库的函数数（v2 新增），如 `{"spl":488,"hal":210,...}`。v1 数据为空。
  final Map<String, int> libraryFunctionCounts;

  /// 各库的符号数（v2 新增）。v1 数据为空。
  final Map<String, int> librarySymbolCounts;

  const DataStats({
    this.peripheralCount = 0,
    this.functionCount = 0,
    this.symbolCount = 0,
    this.pinCount = 0,
    this.compileErrorCount = 0,
    this.libraryFunctionCounts = const <String, int>{},
    this.librarySymbolCounts = const <String, int>{},
  });

  static const DataStats empty = DataStats();

  /// 取某库的函数数；数据里没统计时返回 0。
  int functionCountOf(LibraryKind lib) => libraryFunctionCounts[lib.raw] ?? 0;

  /// 取某库的符号数；数据里没统计时返回 0。
  int symbolCountOf(LibraryKind lib) => librarySymbolCounts[lib.raw] ?? 0;

  /// 是否有按库拆分的统计（v1 数据没有）。
  bool get hasLibraryCounts =>
      libraryFunctionCounts.isNotEmpty || librarySymbolCounts.isNotEmpty;

  factory DataStats.fromJson(Map<String, dynamic> json) {
    final rawFn = asObject(json['libraryFunctionCounts']);
    final rawSym = asObject(json['librarySymbolCounts']);
    return DataStats(
      peripheralCount: asInt(json['peripheralCount']),
      functionCount: asInt(json['functionCount']),
      symbolCount: asInt(json['symbolCount']),
      pinCount: asInt(json['pinCount']),
      compileErrorCount: asInt(json['compileErrorCount']),
      libraryFunctionCounts:
          rawFn.map((k, v) => MapEntry(k, asInt(v))),
      librarySymbolCounts:
          rawSym.map((k, v) => MapEntry(k, asInt(v))),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'peripheralCount': peripheralCount,
        'functionCount': functionCount,
        'symbolCount': symbolCount,
        'pinCount': pinCount,
        'compileErrorCount': compileErrorCount,
        'libraryFunctionCounts': libraryFunctionCounts,
        'librarySymbolCounts': librarySymbolCounts,
      };
}
