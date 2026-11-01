import '../utils/json_parse.dart';
import 'ai_reserved.dart';
import 'library_kind.dart';

/// 符号种类。
///
/// 未知取值解析为 [unknown] 而不是抛异常，保证数据里出现新 kind 时 APP 仍能跑。
enum SymbolKind {
  /// 宏定义，如 RCC_APB2Periph_GPIOA、ENABLE
  macro('macro', '宏'),

  /// 枚举值，如 GPIO_Mode_Out_PP
  enumValue('enum_value', '枚举值'),

  /// 枚举类型，如 GPIOMode_TypeDef
  enumType('enum_type', '枚举类型'),

  /// 结构体，如 GPIO_InitTypeDef
  struct('struct', '结构体'),

  /// typedef 别名
  typedef('typedef', '类型别名'),

  /// 未知种类（数据异常时的兜底）
  unknown('unknown', '符号');

  /// JSON 中的原始字符串
  final String raw;

  /// 中文显示名
  final String labelZh;

  const SymbolKind(this.raw, this.labelZh);

  /// 从 JSON 字符串解析；无法识别时返回 [unknown]。
  static SymbolKind fromRaw(String raw) {
    for (final kind in SymbolKind.values) {
      if (kind.raw == raw) return kind;
    }
    return SymbolKind.unknown;
  }
}

/// 库内符号模型（宏 / 枚举值 / 枚举类型 / 结构体 / typedef）。
///
/// 这是"关键词点击跳转"的目标对象：函数原型、参数表、示例代码里
/// 出现的任何库内名字，最终都会跳到本模型对应的详情页。
class SymbolItem {
  /// 唯一标识，等于符号名，如 "GPIO_Mode_Out_PP"
  final String id;

  /// 符号名
  final String name;

  /// 符号种类
  final SymbolKind kind;

  /// 所属外设 id，如 "GPIO"
  final String peripheral;

  /// 所属库（v2 新增；v1 数据缺字段时按 spl 处理）
  final LibraryKind library;

  /// 值：宏的替换体、枚举值的数值；结构体/typedef 为 null
  final String? value;

  /// 值的形式：hex / dec / expression / string，仅用于展示着色
  final String? valueKind;

  /// 所属枚举类型名（枚举值才有），如 "GPIOMode_TypeDef"
  final String? enumType;

  /// 所属结构体/枚举的符号 id（成员反查用）
  final String? memberOf;

  /// 成员列表：结构体成员或枚举成员
  final List<SymbolMember> members;

  /// `@brief` 英文原文
  final String briefEn;

  /// 中文说明
  final String briefZh;

  /// 中文用法说明
  final String usageZh;

  /// 定义所在文件
  final String definedIn;

  /// 定义所在行号（0 表示未知）
  final int definedLine;

  /// 可见性：public / internal（IS_* 断言宏为 internal）
  final String visibility;

  /// 是否为函数式宏
  final bool functionLike;

  /// 函数式宏的参数名列表
  final List<String> params;

  /// 反向索引：哪些函数会用到它
  final List<String> usedBy;

  /// 同族符号，如 GPIO_Pin_0 关联其它 GPIO_Pin_x
  final List<String> relatedSymbols;

  /// 常见坑中文说明
  final List<String> notesZh;

  /// 预留 AI 字段，本期为空
  final AiReserved ai;

  /// 中文字段来源：base / overlay
  final String zhSource;

  /// 所属寄存器名（仅寄存器位定义宏有值，如 "GPIO_CRL"）。
  ///
  /// 来自 stm32f10x.h 里 `/*  Bit definition for GPIO_CRL register  */`
  /// 这类分节注释，用于函数详情页的"寄存器位域展开"。
  final String? registerName;

  const SymbolItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.peripheral,
    this.library = LibraryKind.spl,
    this.value,
    this.valueKind,
    this.enumType,
    this.memberOf,
    this.members = const <SymbolMember>[],
    this.briefEn = '',
    this.briefZh = '',
    this.usageZh = '',
    this.definedIn = '',
    this.definedLine = 0,
    this.visibility = 'public',
    this.functionLike = false,
    this.params = const <String>[],
    this.usedBy = const <String>[],
    this.relatedSymbols = const <String>[],
    this.notesZh = const <String>[],
    this.ai = AiReserved.empty,
    this.zhSource = 'base',
    this.registerName,
  });

  /// 是否是内部符号（断言宏等），搜索时降权、列表默认折叠
  bool get isInternal => visibility == 'internal';

  /// 详情页副标题，如 "宏 · RCC"、"枚举值 · GPIO_Mode 系列"
  String get kindLabelZh => kind.labelZh;

  /// 值或成员数量的一句话摘要，用于列表项右侧
  String get valueSummary {
    if (value != null && value!.isNotEmpty) return value!;
    if (members.isNotEmpty) return '${members.length} 个成员';
    return kind.labelZh;
  }

  /// 定义位置串，如 "stm32f10x_gpio.h:58"
  String get location =>
      definedLine > 0 ? '$definedIn:$definedLine' : definedIn;

  /// 中文说明的兜底显示
  String get displayBrief {
    if (briefZh.isNotEmpty) return briefZh;
    if (briefEn.isNotEmpty) return briefEn;
    return '暂无中文说明';
  }

  factory SymbolItem.fromJson(Map<String, dynamic> json) => SymbolItem(
        id: asString(json['id']),
        name: asString(json['name']),
        kind: SymbolKind.fromRaw(asString(json['kind'])),
        peripheral: asString(json['peripheral']),
        library: LibraryKind.tryParse(asStringOrNull(json['library'])) ??
            LibraryKind.spl,
        value: asStringOrNull(json['value']),
        valueKind: asStringOrNull(json['valueKind']),
        enumType: asStringOrNull(json['enumType']),
        memberOf: asStringOrNull(json['memberOf']),
        members: asMapList(json['members'])
            .map(SymbolMember.fromJson)
            .toList(growable: false),
        briefEn: asString(json['briefEn']),
        briefZh: asString(json['briefZh']),
        usageZh: asString(json['usageZh']),
        definedIn: asString(json['definedIn']),
        definedLine: asInt(json['definedLine']),
        visibility: asString(json['visibility'], fallback: 'public'),
        functionLike: asBool(json['functionLike']),
        params: asStringList(json['params']),
        usedBy: asStringList(json['usedBy']),
        relatedSymbols: asStringList(json['relatedSymbols']),
        notesZh: asStringList(json['notesZh']),
        ai: json['ai'] == null
            ? AiReserved.empty
            : AiReserved.fromJson(asObject(json['ai'])),
        zhSource: asString(json['zhSource'], fallback: 'base'),
        registerName: asStringOrNull(json['registerName']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.raw,
        'peripheral': peripheral,
        'library': library.raw,
        'value': value,
        'valueKind': valueKind,
        'enumType': enumType,
        'memberOf': memberOf,
        'members': members.map((m) => m.toJson()).toList(),
        'briefEn': briefEn,
        'briefZh': briefZh,
        'usageZh': usageZh,
        'definedIn': definedIn,
        'definedLine': definedLine,
        'visibility': visibility,
        'functionLike': functionLike,
        'params': params,
        'usedBy': usedBy,
        'relatedSymbols': relatedSymbols,
        'notesZh': notesZh,
        'ai': ai.isEmpty ? null : ai.toJson(),
        'zhSource': zhSource,
        'registerName': registerName,
      };
}

/// 结构体成员或枚举成员。
class SymbolMember {
  /// 成员名，如 "GPIO_Pin" 或 "GPIO_Mode_Out_PP"
  final String name;

  /// 成员类型（结构体成员才有），如 "GPIOMode_TypeDef"
  final String? type;

  /// 成员值（枚举成员才有），如 "0x10"
  final String? value;

  /// `@brief` 英文原文
  final String descEn;

  /// 中文说明
  final String descZh;

  /// 定义行号（0 表示未知）
  final int line;

  const SymbolMember({
    required this.name,
    this.type,
    this.value,
    this.descEn = '',
    this.descZh = '',
    this.line = 0,
  });

  /// 显示用说明：中文优先
  String get displayDesc => descZh.isNotEmpty ? descZh : descEn;

  factory SymbolMember.fromJson(Map<String, dynamic> json) => SymbolMember(
        name: asString(json['name']),
        type: asStringOrNull(json['type']),
        value: asStringOrNull(json['value']),
        descEn: asString(json['descEn']),
        descZh: asString(json['descZh']),
        line: asInt(json['line']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type,
        'value': value,
        'descEn': descEn,
        'descZh': descZh,
        'line': line,
      };
}

/// `symbols.json` 顶层结构。
class SymbolBundle {
  final int schemaVersion;
  final List<SymbolItem> symbols;

  const SymbolBundle({required this.schemaVersion, required this.symbols});

  factory SymbolBundle.fromJson(Map<String, dynamic> json) => SymbolBundle(
        schemaVersion: asInt(json['schemaVersion'], fallback: 1),
        symbols: asMapList(json['symbols'])
            .map(SymbolItem.fromJson)
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'symbols': symbols.map((s) => s.toJson()).toList(),
      };
}
