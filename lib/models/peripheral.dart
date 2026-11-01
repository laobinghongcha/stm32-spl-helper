import '../utils/json_parse.dart';
import 'library_kind.dart';

/// 外设模型（对应 `assets/data/peripherals.json` 里的一项）。
///
/// 一个外设 = 一个模块，如 GPIO、RCC、USART。v2 起同一外设可同时存在
/// 四个库的实现，因此 [libraries] 里按库各存一份元信息；
/// 顶层的 [header] / [source] / [file] / [introZh] 等字段沿用 v1 语义，
/// 取「主库」值（有 spl 就取 spl，否则取 hal），保证旧代码不用改。
///
/// 外设本身不直接持有函数对象，只持有 [PeripheralSection]，
/// section 里存的是函数 id，函数正文在 `functions/<库>/<外设>.json` 里。
/// 这样首页只需加载轻量的 peripherals.json 即可渲染列表。
class Peripheral {
  /// 外设标识，如 "GPIO"
  final String id;

  /// 英文名，如 "GPIO"
  final String name;

  /// 中文名，如 "通用输入输出"
  final String nameZh;

  /// 头文件名（主库），如 "stm32f10x_gpio.h"
  final String header;

  /// 源文件名（主库），如 "stm32f10x_gpio.c"
  final String source;

  /// 函数数据文件相对路径（主库），如 "functions/GPIO.json"
  final String file;

  /// 首页排序权重，越小越靠前（由 overlay 指定，GPIO=1、RCC=2…）
  final int orderIndex;

  /// 总体中文说明（主库）
  final String introZh;

  /// 使用总览：先做什么后做什么（主库）
  final String usageOverviewZh;

  /// 函数数量（主库）
  final int functionCount;

  /// 符号数量（主库）
  final int symbolCount;

  /// 标签，如 ["常用", "基础"]
  final List<String> tags;

  /// 函数分组（跨库混排，每项自带 [PeripheralSection.library]）
  final List<PeripheralSection> sections;

  /// 按库拆分的元信息。
  ///
  /// v2 数据里来自 JSON 的 `libraries` 键；v1 数据没有这个键，
  /// 解析时会把顶层旧字段包成一项 `spl` 放进来，所以**这里永远非空**
  /// （除非外设连 id 都没有）。
  final Map<LibraryKind, PeripheralLibrary> libraries;

  const Peripheral({
    required this.id,
    required this.name,
    required this.nameZh,
    required this.header,
    required this.source,
    required this.file,
    required this.orderIndex,
    required this.introZh,
    required this.usageOverviewZh,
    required this.functionCount,
    required this.symbolCount,
    required this.tags,
    required this.sections,
    this.libraries = const <LibraryKind, PeripheralLibrary>{},
  });

  /// 详情页顶部的一句话简介：优先用总览的第一句，没有就用总体说明。
  String get oneLineIntro {
    final text = usageOverviewZh.isNotEmpty ? usageOverviewZh : introZh;
    if (text.isEmpty) return '';
    // 按中文句号/换行截取第一句，避免卡片上出现整段文字
    final cut = text.split(RegExp(r'[。\n]')).first;
    return cut.isEmpty ? text : '$cut。';
  }

  /// 所有函数 id（跨全部库，按 section 顺序拼接），供索引与统计使用。
  List<String> get allFunctionIds =>
      sections.expand((s) => s.functionIds).toList(growable: false);

  /// 取某个库的元信息；没有该库时返回 null。
  PeripheralLibrary? libraryOf(LibraryKind lib) => libraries[lib];

  /// 该库下登记的全部函数 id（按 section 顺序）。
  ///
  /// 老数据的 section 没有 `library` 字段，解析时已按 id 里的 `@` 段
  /// 或默认值归到 spl，所以这里查 spl 能拿到 v1 的全量。
  List<String> functionIdsOf(LibraryKind lib) {
    final out = <String>[];
    for (final sec in sections) {
      if (sec.library != lib) continue;
      out.addAll(sec.functionIds);
    }
    return out;
  }

  /// 该库的函数数量。
  ///
  /// 优先用数据里声明的 `libraries[lib].functionCount`；缺失时退回
  /// 由 sections 实际数出来的条数，保证不会显示 0 个却有列表。
  int functionCountOf(LibraryKind lib) {
    final declared = libraries[lib]?.functionCount ?? 0;
    if (declared > 0) return declared;
    if (lib == LibraryKind.spl && libraries.isEmpty) return functionCount;
    return functionIdsOf(lib).length;
  }

  /// 该库的分组（保持 peripherals.json 里的原顺序）。
  List<PeripheralSection> sectionsOf(LibraryKind lib) {
    final out = <PeripheralSection>[];
    for (final sec in sections) {
      if (sec.library == lib) out.add(sec);
    }
    return out;
  }

  /// 该外设实际有内容的库，按 [LibraryKind.ordered] 顺序。
  ///
  /// 判定口径：`libraries` 里有条目，或者 sections 里有该库的分组。
  /// 两者取并集——生成器有可能只写了 sections 没写 libraries（反之亦然）。
  List<LibraryKind> get availableLibraries {
    final present = <LibraryKind>{
      ...libraries.keys,
      for (final sec in sections) sec.library,
    };
    return <LibraryKind>[
      for (final lib in LibraryKind.ordered)
        if (present.contains(lib)) lib,
    ];
  }

  /// 该外设是否有某个库的内容。
  bool hasLibrary(LibraryKind lib) =>
      libraries.containsKey(lib) || sections.any((s) => s.library == lib);

  /// "主库"：有 spl 用 spl，否则按 ordered 取第一个可用的库。
  LibraryKind get primaryLibrary {
    final available = availableLibraries;
    if (available.isEmpty) return LibraryKind.spl;
    return available.first;
  }

  factory Peripheral.fromJson(Map<String, dynamic> json) {
    final libraries = _parseLibraries(json);
    final sections = asMapList(json['sections'])
        .map(PeripheralSection.fromJson)
        .toList(growable: false);

    // 顶层字段取「主库」值：v2 数据里生成器已按此规则写好，
    // 但若只给了 libraries 而顶层字段为空，这里再从主库里补一次。
    final primary = _pickPrimary(libraries);
    final primaryInfo = primary == null ? null : libraries[primary];

    String pick(String top, String? fromLib) =>
        top.isNotEmpty ? top : (fromLib ?? '');

    return Peripheral(
      id: asString(json['id']),
      name: asString(json['name']),
      nameZh: asString(json['nameZh'], fallback: asString(json['name'])),
      header: pick(asString(json['header']), primaryInfo?.header),
      source: pick(asString(json['source']), primaryInfo?.source),
      file: pick(asString(json['file']), primaryInfo?.file),
      orderIndex: asInt(json['orderIndex'], fallback: 1000),
      introZh: pick(asString(json['introZh']), primaryInfo?.introZh),
      usageOverviewZh: pick(
        asString(json['usageOverviewZh']),
        primaryInfo?.usageOverviewZh,
      ),
      functionCount: asInt(
        json['functionCount'],
        fallback: primaryInfo?.functionCount ?? 0,
      ),
      symbolCount: asInt(
        json['symbolCount'],
        fallback: primaryInfo?.symbolCount ?? 0,
      ),
      tags: asStringList(json['tags']),
      sections: sections,
      libraries: libraries,
    );
  }

  /// 解析 `libraries`；老数据没有该键时把顶层旧字段包成 spl 一项。
  static Map<LibraryKind, PeripheralLibrary> _parseLibraries(
    Map<String, dynamic> json,
  ) {
    final raw = json['libraries'];
    final out = <LibraryKind, PeripheralLibrary>{};
    if (raw is Map && raw.isNotEmpty) {
      raw.forEach((key, value) {
        final lib = LibraryKind.tryParse(key.toString());
        if (lib == null) return; // 未知库名直接忽略，不污染索引
        if (value is! Map) return;
        out[lib] = PeripheralLibrary.fromJson(asMap(value));
      });
    }
    if (out.isNotEmpty) return out;

    // ---- 向后兼容：v1 数据 ----
    //
    // v1 里 header/source/file/introZh/... 直接挂在外设上，没有 libraries。
    // 把它们包成「spl 库」一项，这样 UI 走 libraries[spl] 也能拿到内容，
    // 不必到处写 `?? peripheral.header` 这种双份兜底。
    final fallback = PeripheralLibrary(
      header: asString(json['header']),
      source: asString(json['source']),
      file: asString(json['file']),
      functionCount: asInt(json['functionCount']),
      symbolCount: asInt(json['symbolCount']),
      introZh: asString(json['introZh']),
      usageOverviewZh: asString(json['usageOverviewZh']),
    );
    // 全空的占位项不进 map：否则 availableLibraries 会给每个外设都
    // 凭空多出一个"标准库"页签，点进去却一个字都没有。
    if (fallback.isNotEmpty) out[LibraryKind.spl] = fallback;
    return out;
  }

  /// 主库：有 spl 就 spl，否则取 ordered 里的第一个。
  static LibraryKind? _pickPrimary(
    Map<LibraryKind, PeripheralLibrary> libraries,
  ) {
    if (libraries.isEmpty) return null;
    if (libraries.containsKey(LibraryKind.spl)) return LibraryKind.spl;
    for (final lib in LibraryKind.ordered) {
      if (libraries.containsKey(lib)) return lib;
    }
    return libraries.keys.first;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'nameZh': nameZh,
        'header': header,
        'source': source,
        'file': file,
        'orderIndex': orderIndex,
        'introZh': introZh,
        'usageOverviewZh': usageOverviewZh,
        'functionCount': functionCount,
        'symbolCount': symbolCount,
        'tags': tags,
        'sections': sections.map((s) => s.toJson()).toList(),
        'libraries': <String, dynamic>{
          for (final e in libraries.entries) e.key.raw: e.value.toJson(),
        },
      };
}

/// 某个库在外设下的元信息（契约 §3 的 `libraries.<lib>` 一项）。
///
/// 每个库有**自己的**头文件、源文件、函数文件与中文简介：HAL 的 GPIO 简介
/// 讲 `HAL_GPIO_Init`，SPL 的讲 `RCC_APB2PeriphClockCmd`，两者不能混用。
class PeripheralLibrary {
  /// 头文件名，如 "stm32f1xx_hal_gpio.h"
  final String header;

  /// 源文件名，如 "stm32f1xx_hal_gpio.c"
  final String source;

  /// 函数数据文件相对路径，如 "functions/hal/GPIO.json"
  final String file;

  /// 该库该外设的函数数量
  final int functionCount;

  /// 该库该外设的符号数量
  final int symbolCount;

  /// 该库视角的中文简介
  final String introZh;

  /// 该库视角的使用总览（整段，可能含 ①②③ 或换行）
  final String usageOverviewZh;

  /// 已经切好的使用步骤（生成器直出；优先于 [usageOverviewZh]）
  final List<String> usageSteps;

  /// 补充提示（可空），如"HAL 需先调用 HAL_Init"
  final String noteZh;

  const PeripheralLibrary({
    this.header = '',
    this.source = '',
    this.file = '',
    this.functionCount = 0,
    this.symbolCount = 0,
    this.introZh = '',
    this.usageOverviewZh = '',
    this.usageSteps = const <String>[],
    this.noteZh = '',
  });

  /// 是否有任何内容（用来过滤掉生成器写出的空占位）。
  bool get isEmpty =>
      header.isEmpty &&
      source.isEmpty &&
      file.isEmpty &&
      functionCount == 0 &&
      symbolCount == 0 &&
      introZh.isEmpty &&
      usageOverviewZh.isEmpty &&
      usageSteps.isEmpty &&
      noteZh.isEmpty;

  bool get isNotEmpty => !isEmpty;

  factory PeripheralLibrary.fromJson(Map<String, dynamic> json) =>
      PeripheralLibrary(
        header: asString(json['header']),
        source: asString(json['source']),
        file: asString(json['file']),
        functionCount: asInt(json['functionCount']),
        symbolCount: asInt(json['symbolCount']),
        introZh: asString(json['introZh']),
        usageOverviewZh: asString(json['usageOverviewZh']),
        usageSteps: asStringList(json['usageSteps']),
        noteZh: asString(json['noteZh']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'header': header,
        'source': source,
        'file': file,
        'functionCount': functionCount,
        'symbolCount': symbolCount,
        'introZh': introZh,
        'usageOverviewZh': usageOverviewZh,
        'usageSteps': usageSteps,
        'noteZh': noteZh,
      };
}

/// 函数分组：对应 ST 头文件里的一行分节注释。
///
/// 例如 `/*  Initialization and Configuration functions ***/`
/// 会被翻译成 title="初始化与配置函数"、titleEn 保留英文原文。
///
/// v2 起每个分组属于某一个库（[library]），id 形如 `GPIO@hal#sec1`；
/// v1 的 id 形如 `GPIO#sec1`、没有 library 字段，解析时归到 spl。
class PeripheralSection {
  /// 分组 id，形如 "GPIO@hal#sec1"，函数通过 sectionId 反查所属分组
  final String id;

  /// 中文标题
  final String title;

  /// 英文原标题（ST 原文，可能为空）
  final String? titleEn;

  /// 该分组下的函数 id 列表（顺序与头文件一致）
  final List<String> functionIds;

  /// 所属库（缺省 spl）
  final LibraryKind library;

  const PeripheralSection({
    required this.id,
    required this.title,
    this.titleEn,
    required this.functionIds,
    this.library = LibraryKind.spl,
  });

  factory PeripheralSection.fromJson(Map<String, dynamic> json) {
    final id = asString(json['id']);
    // library 字段优先；没有就看 id 里的 `@<库>` 段；再没有就是 v1 的 spl。
    final library = LibraryKind.tryParse(asStringOrNull(json['library'])) ??
        LibraryKind.fromSectionId(id) ??
        LibraryKind.spl;
    return PeripheralSection(
      id: id,
      title: asString(json['title']),
      titleEn: asStringOrNull(json['titleEn']),
      functionIds: asStringList(json['functionIds']),
      library: library,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'titleEn': titleEn,
        'functionIds': functionIds,
        'library': library.raw,
      };
}

/// `peripherals.json` 顶层结构。
class PeripheralBundle {
  final int schemaVersion;
  final List<Peripheral> peripherals;

  const PeripheralBundle({
    required this.schemaVersion,
    required this.peripherals,
  });

  factory PeripheralBundle.fromJson(Map<String, dynamic> json) =>
      PeripheralBundle(
        schemaVersion: asInt(json['schemaVersion'], fallback: 1),
        peripherals: asMapList(json['peripherals'])
            .map(Peripheral.fromJson)
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'peripherals': peripherals.map((p) => p.toJson()).toList(),
      };
}
