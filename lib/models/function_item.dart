import '../utils/json_parse.dart';
import 'ai_reserved.dart';
import 'library_kind.dart';

/// 库函数模型（对应 `assets/data/functions/<库>/<外设>.json` 里的一项）。
///
/// 英文内容来自源码注释（SPL / CubeF1），中文内容来自 overlay。
/// 详情页从上到下的每个区块，都能在这里找到对应字段。
class FunctionItem {
  /// 唯一标识，等于函数名，如 "GPIO_Init" / "HAL_GPIO_Init" / "REG_GPIO_CRL"
  final String id;

  /// 函数名
  final String name;

  /// 所属外设 id，如 "GPIO"
  final String peripheral;

  /// 所属库（v2 新增；v1 数据缺字段时按 spl 处理）
  final LibraryKind library;

  /// 定义所在文件，如 "stm32f1xx_hal_gpio.h"（v2 新增；v1 为空）
  ///
  /// 与 [headerLine] 组合出详情页的定位条。HAL/LL/reg 的头文件名与 SPL 不同，
  /// 所以不能借用外设上的 header 字段，必须由函数自己带着。
  final String definedIn;

  /// 所属分组 id，如 "GPIO@hal#sec1"
  final String sectionId;

  /// 完整原型字符串（用于代码块展示与复制）
  final String prototype;

  /// 返回类型，如 "void"、"uint8_t"、"FlagStatus"
  final String returnType;

  /// 参数列表
  final List<FunctionParam> params;

  /// `@retval` 英文原文
  final String returnDescEn;

  /// 返回值中文说明
  final String returnDescZh;

  /// ST 原始 `@brief`
  final String briefEn;

  /// 中文简述
  final String briefZh;

  /// 中文使用说明：什么时候调用、调用顺序、常见坑
  final String usageZh;

  /// 前置条件清单
  final List<String> prerequisites;

  /// 涉及的寄存器名，如 ["GPIOx_CRL", "GPIOx_CRH"]
  final List<String> registers;

  /// 相关函数 id（可点击跳转）
  final List<String> relatedFunctions;

  /// ST 原文 `@note` 等注意事项
  final List<String> remarks;

  /// 常见坑中文说明
  final List<String> notesZh;

  /// 最小可运行示例代码
  final String exampleCode;

  /// 示例代码语言，固定 "c"
  final String exampleLanguage;

  /// 该函数正文/注释/示例里出现的库内符号名，关键词跳转的白名单
  final List<String> symbolRefs;

  /// 头文件中的行号（0 表示未知）
  final int headerLine;

  /// 源文件中的行号（0 表示未知）
  final int sourceLine;

  /// 补充标记
  final FunctionFlags flags;

  /// 预留 AI 字段，本期为空
  final AiReserved ai;

  /// 中文字段来源：base（无补充）/ overlay（有补充）
  final String zhSource;

  const FunctionItem({
    required this.id,
    required this.name,
    required this.peripheral,
    required this.sectionId,
    required this.prototype,
    required this.returnType,
    required this.params,
    required this.returnDescEn,
    required this.returnDescZh,
    required this.briefEn,
    required this.briefZh,
    required this.usageZh,
    required this.prerequisites,
    required this.registers,
    required this.relatedFunctions,
    required this.remarks,
    required this.notesZh,
    required this.exampleCode,
    required this.exampleLanguage,
    required this.symbolRefs,
    required this.headerLine,
    required this.sourceLine,
    required this.flags,
    required this.ai,
    required this.zhSource,
    this.library = LibraryKind.spl,
    this.definedIn = '',
  });

  /// 所属库的中文名，如「HAL 库」。列表徽标与详情页副标题用。
  String get libraryLabelZh => library.labelZh;

  /// 列表项显示用的简述：中文优先，其次英文，最后退回"暂无说明"。
  String get displayBrief {
    if (briefZh.isNotEmpty) return briefZh;
    if (briefEn.isNotEmpty) return briefEn;
    return '暂无中文说明';
  }

  /// 列表项右侧显示的返回值摘要：只给"类型级"的短标签。
  ///
  /// 早先这里返回 returnDescZh 全文，有的长达 40 字（如
  /// "返回引脚电平：Bit_SET（1）为高电平，Bit_RESET（0）为低电平。"），
  /// 把左侧函数名挤到只剩一两个字符宽，出现"函数名竖排"的显示问题。
  /// 返回值长句只应出现在函数详情页的「返回值」区块。
  String get displayReturn {
    if (returnType == 'void') return 'void';
    // 类型可能带指针或 const，取最后一段标识符作为摘要
    final cleaned = returnType.replaceAll('*', ' ').trim();
    final parts = cleaned.split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? returnType : parts.last;
  }

  /// 返回值的中文单行摘要。调用方必须限制行数（maxLines 1 + ellipsis）。
  String get shortReturnZh {
    if (returnDescZh.isEmpty) {
      return returnType == 'void' ? '无返回值' : '返回 $returnType';
    }
    // 只取第一个句号/分号前的内容，避免长句
    final cut = returnDescZh.split(RegExp(r'[。；;]')).first;
    return cut.isEmpty ? returnDescZh : cut;
  }

  /// 是否有中文补充（设置页统计"未翻译函数"用）
  bool get hasChinese => briefZh.isNotEmpty || usageZh.isNotEmpty;

  /// 头文件定位串，如 "stm32f10x_gpio.h:168"
  String locationIn(String headerFile) =>
      headerLine > 0 ? '$headerFile:$headerLine' : headerFile;

  factory FunctionItem.fromJson(Map<String, dynamic> json) => FunctionItem(
        id: asString(json['id']),
        name: asString(json['name']),
        peripheral: asString(json['peripheral']),
        // library 缺失（v1 数据）→ spl；已有 sectionId 时优先按 id 推断，
        // 避免生成器漏写 library 字段导致 HAL 函数被当成 SPL 函数。
        library: LibraryKind.tryParse(asStringOrNull(json['library'])) ??
            LibraryKind.fromSectionId(asString(json['sectionId'])) ??
            LibraryKind.spl,
        definedIn: asString(json['definedIn']),
        sectionId: asString(json['sectionId']),
        prototype: asString(json['prototype']),
        returnType: asString(json['returnType'], fallback: 'void'),
        params: asMapList(json['params'])
            .map(FunctionParam.fromJson)
            .toList(growable: false),
        returnDescEn: asString(json['returnDescEn']),
        returnDescZh: asString(json['returnDescZh']),
        briefEn: asString(json['briefEn']),
        briefZh: asString(json['briefZh']),
        usageZh: asString(json['usageZh']),
        prerequisites: asStringList(json['prerequisites']),
        registers: asStringList(json['registers']),
        relatedFunctions: asStringList(json['relatedFunctions']),
        remarks: asStringList(json['remarks']),
        notesZh: asStringList(json['notesZh']),
        exampleCode: asString(json['exampleCode']),
        exampleLanguage: asString(json['exampleLanguage'], fallback: 'c'),
        symbolRefs: asStringList(json['symbolRefs']),
        headerLine: asInt(json['headerLine']),
        sourceLine: asInt(json['sourceLine']),
        flags: FunctionFlags.fromJson(asObject(json['flags'])),
        ai: json['ai'] == null
            ? AiReserved.empty
            : AiReserved.fromJson(asObject(json['ai'])),
        zhSource: asString(json['zhSource'], fallback: 'base'),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'peripheral': peripheral,
        'library': library.raw,
        'definedIn': definedIn,
        'sectionId': sectionId,
        'prototype': prototype,
        'returnType': returnType,
        'params': params.map((p) => p.toJson()).toList(),
        'returnDescEn': returnDescEn,
        'returnDescZh': returnDescZh,
        'briefEn': briefEn,
        'briefZh': briefZh,
        'usageZh': usageZh,
        'prerequisites': prerequisites,
        'registers': registers,
        'relatedFunctions': relatedFunctions,
        'remarks': remarks,
        'notesZh': notesZh,
        'exampleCode': exampleCode,
        'exampleLanguage': exampleLanguage,
        'symbolRefs': symbolRefs,
        'headerLine': headerLine,
        'sourceLine': sourceLine,
        'flags': flags.toJson(),
        'ai': ai.isEmpty ? null : ai.toJson(),
        'zhSource': zhSource,
      };
}

/// 函数参数：名称 + 类型 + 中英文说明。
///
/// [type] 里出现的 `GPIO_InitTypeDef`、`GPIOMode_TypeDef` 等名字
/// 会在参数表里被渲染成可点击链接（需求 5.3）。
class FunctionParam {
  /// 参数名，如 "GPIOx"
  final String name;

  /// 参数类型，如 "GPIO_TypeDef*"
  final String type;

  /// `@param` 英文原文
  final String descEn;

  /// 中文说明
  final String descZh;

  const FunctionParam({
    required this.name,
    required this.type,
    this.descEn = '',
    this.descZh = '',
  });

  factory FunctionParam.fromJson(Map<String, dynamic> json) => FunctionParam(
        name: asString(json['name']),
        type: asString(json['type']),
        descEn: asString(json['descEn']),
        descZh: asString(json['descZh']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type,
        'descEn': descEn,
        'descZh': descZh,
      };
}

/// 函数补充标记。全部由 overlay 手工标注，解析脚本给默认值。
class FunctionFlags {
  /// 是否已废弃
  final bool deprecated;

  /// 是否可在中断服务函数中安全调用
  final bool isrSafe;

  /// 是否为 static inline 函数
  final bool inline;

  /// 是否为宏实现的"函数"
  final bool macroLike;

  const FunctionFlags({
    this.deprecated = false,
    this.isrSafe = false,
    this.inline = false,
    this.macroLike = false,
  });

  static const FunctionFlags none = FunctionFlags();

  factory FunctionFlags.fromJson(Map<String, dynamic> json) => FunctionFlags(
        deprecated: asBool(json['deprecated']),
        isrSafe: asBool(json['isrSafe']),
        inline: asBool(json['inline']),
        macroLike: asBool(json['macroLike']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'deprecated': deprecated,
        'isrSafe': isrSafe,
        'inline': inline,
        'macroLike': macroLike,
      };
}

/// `functions/<库>/<外设>.json` 顶层结构。
class FunctionBundle {
  final int schemaVersion;
  final String peripheral;

  /// 该文件所属库（v1 数据缺字段时按 spl）。
  ///
  /// 文件级 library 用于把整个 bundle 归到某个库；单个函数仍以自己的
  /// [FunctionItem.library] 为准（两者正常一致，异常时以函数为准）。
  final LibraryKind library;

  final List<FunctionItem> functions;

  const FunctionBundle({
    required this.schemaVersion,
    required this.peripheral,
    required this.functions,
    this.library = LibraryKind.spl,
  });

  /// 空 bundle：该外设没有这个库的实现时，仓库层返回它而不是抛异常。
  ///
  /// 带上 [peripheral] 与 [library]，这样调用方拿到空结果时仍知道"这是
  /// GPIO 的 HAL 库没有内容"，而不是一个什么都不知道的空壳。
  const FunctionBundle.empty({
    this.peripheral = '',
    this.library = LibraryKind.spl,
  })  : schemaVersion = 2,
        functions = const <FunctionItem>[];

  bool get isEmpty => functions.isEmpty;

  factory FunctionBundle.fromJson(Map<String, dynamic> json) => FunctionBundle(
        schemaVersion: asInt(json['schemaVersion'], fallback: 1),
        peripheral: asString(json['peripheral']),
        library: LibraryKind.tryParse(asStringOrNull(json['library'])) ??
            LibraryKind.spl,
        functions: asMapList(json['functions'])
            .map(FunctionItem.fromJson)
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'peripheral': peripheral,
        'library': library.raw,
        'functions': functions.map((f) => f.toJson()).toList(),
      };
}
