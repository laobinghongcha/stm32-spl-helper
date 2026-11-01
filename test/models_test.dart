// 关键工具函数的单元测试。
//
// 需求明确"不需要单元测试全覆盖，关键工具函数写测试即可"，
// 所以这里只测真正容易出错、且不依赖 assets 的纯逻辑：
//   1. json_parse 的宽松解析（数据缺字段时不能崩）
//   2. SearchIndex 的匹配与排序策略（前缀优先、大小写不敏感、中文子串）
//   3. ItemRef 的主键编解码
//   4. Pin 的引脚名解析
//   5. v2 四库结构（LibraryKind / PeripheralLibrary / sections 归属）
//      —— 数据由 task-1 并行生成，所以这里用契约文档里的小样本自测，
//      不依赖 assets/data 当前是 v1 还是 v2。

import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/models/chip.dart';
import 'package:stm32_spl_helper/models/compile_error.dart';
import 'package:stm32_spl_helper/models/function_item.dart';
import 'package:stm32_spl_helper/models/item_ref.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/manifest.dart';
import 'package:stm32_spl_helper/models/peripheral.dart';
import 'package:stm32_spl_helper/models/pin.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';
import 'package:stm32_spl_helper/models/symbol_item.dart';
import 'package:stm32_spl_helper/utils/json_parse.dart';

// ---------------------------------------------------------------------------
// 测试夹具
// ---------------------------------------------------------------------------

/// 构造一个最小的 SplData，用于搜索索引测试。
SplData buildFixtureData() {
  final peripherals = <Peripheral>[
    const Peripheral(
      id: 'GPIO',
      name: 'GPIO',
      nameZh: '通用输入输出',
      header: 'stm32f10x_gpio.h',
      source: 'stm32f10x_gpio.c',
      file: 'functions/GPIO.json',
      orderIndex: 1,
      introZh: 'GPIO 是最基础的外设。',
      usageOverviewZh: '先开时钟再配置引脚。',
      functionCount: 18,
      symbolCount: 115,
      tags: ['常用'],
      sections: <PeripheralSection>[],
    ),
    const Peripheral(
      id: 'DAC',
      name: 'DAC',
      nameZh: '数模转换',
      header: 'stm32f10x_dac.h',
      source: 'stm32f10x_dac.c',
      file: 'functions/DAC.json',
      orderIndex: 91,
      introZh: '数模转换器。',
      usageOverviewZh: '',
      functionCount: 17,
      symbolCount: 61,
      tags: <String>[],
      sections: <PeripheralSection>[],
    ),
  ];

  final symbols = <SymbolItem>[
    const SymbolItem(
      id: 'GPIO_Mode_Out_PP',
      name: 'GPIO_Mode_Out_PP',
      kind: SymbolKind.enumValue,
      peripheral: 'GPIO',
      value: '0x10',
      briefZh: '推挽输出。可主动输出高电平和低电平。',
    ),
    const SymbolItem(
      id: 'GPIO_InitTypeDef',
      name: 'GPIO_InitTypeDef',
      kind: SymbolKind.struct,
      peripheral: 'GPIO',
      briefZh: 'GPIO 初始化结构体。',
      members: <SymbolMember>[
        SymbolMember(
          name: 'GPIO_Pin',
          type: 'uint16_t',
          descZh: '要配置的引脚',
        ),
        SymbolMember(
          name: 'GPIO_Mode',
          type: 'GPIOMode_TypeDef',
          descZh: '工作模式',
        ),
      ],
    ),
    // 内部断言宏，默认不应出现在搜索结果里
    const SymbolItem(
      id: 'IS_GPIO_MODE',
      name: 'IS_GPIO_MODE',
      kind: SymbolKind.macro,
      peripheral: 'GPIO',
      visibility: 'internal',
    ),
  ];

  final pins = <Pin>[
    const Pin(
      number: 30,
      name: 'PA9',
      groups: <PinGroup>[PinGroup.gpio],
      defaultFunction: 'PA9',
      defaultFunctionZh: '通用 IO',
      functions: <PinFunction>[
        PinFunction(
          name: 'USART1_TX',
          kind: PinFunctionKind.af,
          peripheralId: 'USART',
        ),
      ],
      fiveVoltTolerant: true,
    ),
    const Pin(
      number: 34,
      name: 'PA13',
      groups: <PinGroup>[PinGroup.debug, PinGroup.gpio],
      defaultFunction: 'JTMS/SWDIO',
      functions: <PinFunction>[],
      jtagSwd: 'JTMS/SWDIO',
    ),
  ];

  final errors = <CompileError>[
    const CompileError(
      id: 'err.undefined_reference',
      titleZh: "undefined reference to 'xxx'",
      categoryId: 'linker',
      toolchain: 'gcc-arm',
      messagePatterns: <String>['undefined reference to'],
      explainZh: '链接器找不到函数实现体。',
      relatedPeripheralIds: <String>['GPIO'],
    ),
  ];

  return SplData(
    manifest: const DataManifest(
      schemaVersion: 1,
      dataVersion: '1.0.0',
      splVersion: 'STM32F10x_StdPeriph_Lib_V3.5.0',
      defaultChipId: 'stm32f103c8t6',
      generatedAt: '',
      generator: 'test',
      stats: DataStats(),
      files: <String, String>{},
    ),
    chip: const ChipSpec(
      id: 'stm32f103c8t6',
      name: 'STM32F103C8T6',
      supportedPeripherals: <String>['GPIO'],
      unsupportedPeripherals: <String>['DAC'],
      unsupportedReasons: <String, String>{'DAC': 'C8T6 无 DAC 外设'},
      peripheralInstances: <String, List<String>>{
        'GPIO': <String>['GPIOA', 'GPIOB', 'GPIOC'],
      },
    ),
    peripherals: peripherals,
    functions: const <FunctionItem>[],
    symbols: symbols,
    pinout: PinoutData(
      schemaVersion: 1,
      chipId: 'stm32f103c8t6',
      package: 'LQFP48',
      source: 'test',
      verified: false,
      verifiedNote: '未核对',
      pins: pins,
    ),
    compileErrors: CompileErrorBundle(
      schemaVersion: 1,
      categories: const <CompileErrorCategory>[
        CompileErrorCategory(id: 'linker', nameZh: '链接错误', orderIndex: 2),
      ],
      errors: errors,
    ),
  );
}

void main() {
  // -------------------------------------------------------------------------
  group('json_parse 宽松解析', () {
    test('缺失字段返回兜底值而不是抛异常', () {
      expect(asString(null), '');
      expect(asString(null, fallback: '默认'), '默认');
      expect(asInt(null), 0);
      expect(asInt(null, fallback: -1), -1);
      expect(asBool(null), false);
      expect(asStringList(null), isEmpty);
      expect(asMapList(null), isEmpty);
      expect(asMap(null), isEmpty);
    });

    test('类型不符时尽力转换', () {
      expect(asInt('42'), 42);
      expect(asInt(42.9), 42);
      expect(asBool('true'), true);
      expect(asBool('false'), false);
      expect(asString(123), '123');
    });

    test('空字符串按 null 处理，便于 UI 判空', () {
      expect(asStringOrNull(''), isNull);
      expect(asStringOrNull('  x  '), '  x  ');
      expect(asStringOrNull(null), isNull);
    });

    test('字符串数组过滤掉 null 与空串', () {
      expect(asStringList(<dynamic>['a', null, '', 'b']), <String>['a', 'b']);
    });
  });

  // -------------------------------------------------------------------------
  group('ItemRef 主键编解码', () {
    test('key 与 fromKey 往返一致', () {
      const ref = ItemRef(
        type: ItemType.function,
        id: 'GPIO_Init',
        title: 'GPIO_Init',
      );
      expect(ref.key, 'function:GPIO_Init');
      final back = ItemRef.fromKey(ref.key);
      expect(back, isNotNull);
      expect(back!.type, ItemType.function);
      expect(back.id, 'GPIO_Init');
    });

    test('非法 key 返回 null 而不是抛异常', () {
      expect(ItemRef.fromKey(''), isNull);
      expect(ItemRef.fromKey('noColon'), isNull);
      expect(ItemRef.fromKey('unknownType:xxx'), isNull);
      expect(ItemRef.fromKey('function:'), isNull);
    });

    test('id 里含冒号时只按第一个冒号切分', () {
      final back = ItemRef.fromKey('pin:30:extra');
      expect(back, isNotNull);
      expect(back!.id, '30:extra');
    });
  });

  // -------------------------------------------------------------------------
  group('Pin 引脚名解析', () {
    test('GPIO 引脚识别端口与位号', () {
      const p = Pin(number: 30, name: 'PA9');
      expect(p.isGpio, isTrue);
      expect(p.portName, 'GPIOA');
      expect(p.bitIndex, 9);
    });

    test('非 GPIO 引脚不误判', () {
      const vbat = Pin(number: 1, name: 'VBAT');
      expect(vbat.isGpio, isFalse);
      expect(vbat.portName, '');
      expect(vbat.bitIndex, -1);
    });

    test('调试口占用判断', () {
      const pa13 = Pin(number: 34, name: 'PA13', jtagSwd: 'JTMS/SWDIO');
      expect(pa13.isDebugOccupied, isTrue);
      const pa9 = Pin(number: 30, name: 'PA9');
      expect(pa9.isDebugOccupied, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('SplData 查询与索引', () {
    test('按 id 查询各类型条目', () {
      final d = buildFixtureData();
      expect(d.peripheral('GPIO')?.nameZh, '通用输入输出');
      expect(d.symbol('GPIO_Mode_Out_PP')?.value, '0x10');
      expect(d.pinout.pinByNumber(30)?.name, 'PA9');
      expect(d.compileErrorById['err.undefined_reference'], isNotNull);
      expect(d.peripheral('NOT_EXIST'), isNull);
    });

    test('芯片能力判断', () {
      final d = buildFixtureData();
      expect(d.isPeripheralSupported('GPIO'), isTrue);
      expect(d.isPeripheralSupported('DAC'), isFalse);
      expect(d.chip.unsupportedReason('DAC'), 'C8T6 无 DAC 外设');
    });

    test('引脚按功能反查', () {
      final d = buildFixtureData();
      final hits = d.pinout.searchByFunction('USART1_TX');
      expect(hits.length, 1);
      expect(hits.first.name, 'PA9');
      // 不区分大小写
      expect(d.pinout.searchByFunction('usart1_tx').length, 1);
      // 引脚名也能查
      expect(d.pinout.searchByFunction('PA13').first.number, 34);
      // 查不到返回空列表
      expect(d.pinout.searchByFunction('NOT_EXIST'), isEmpty);
    });

    test('ItemRef 补全标题与副标题', () {
      final d = buildFixtureData();
      final enriched = d.enrich(
        const ItemRef(
          type: ItemType.symbol,
          id: 'GPIO_Mode_Out_PP',
          title: '',
        ),
      );
      expect(enriched.title, 'GPIO_Mode_Out_PP');
      expect(enriched.subtitle, '通用输入输出');
    });
  });

  // -------------------------------------------------------------------------
  group('函数跳转判定（真机 bug 回归测试）', () {
    // 复现问题：首屏 functions 为空（函数详情按需加载），
    // 早先 isKnownFunction 只查 functionById，导致点函数名报"未收录符号"。
    // 现在应回退查外设的 functionIds。
    SplData dataWithFunctionsNotLoaded() {
      final base = buildFixtureData();
      return SplData(
        manifest: base.manifest,
        chip: base.chip,
        peripherals: <Peripheral>[
          const Peripheral(
            id: 'MISC',
            name: 'MISC',
            nameZh: '内核外设与中断',
            header: 'misc.h',
            source: 'misc.c',
            file: 'functions/MISC.json',
            orderIndex: 5,
            introZh: '',
            usageOverviewZh: '',
            functionCount: 2,
            symbolCount: 1,
            tags: <String>[],
            sections: <PeripheralSection>[
              PeripheralSection(
                id: 'MISC#sec1',
                title: '初始化与配置函数',
                functionIds: <String>['NVIC_Init', 'NVIC_PriorityGroupConfig'],
              ),
            ],
          ),
        ],
        // 关键：函数详情尚未加载
        functions: const <FunctionItem>[],
        symbols: base.symbols,
        pinout: base.pinout,
        compileErrors: base.compileErrors,
      );
    }

    test('函数详情未加载时，函数名仍被判定为可跳转', () {
      final d = dataWithFunctionsNotLoaded();
      expect(
        d.isKnownFunction('NVIC_Init'),
        isTrue,
        reason: '首屏未加载函数详情时，NVIC_Init 仍应可跳转（回归 bug）',
      );
      expect(d.isKnownFunction('NVIC_PriorityGroupConfig'), isTrue);
      expect(d.isKnownFunction('NOT_A_FUNCTION'), isFalse);
    });

    test('peripheralIdOfFunction 在未加载时也能定位外设', () {
      final d = dataWithFunctionsNotLoaded();
      expect(d.peripheralIdOfFunction('NVIC_Init'), 'MISC');
      expect(d.peripheralIdOfFunction('NOT_A_FUNCTION'), isNull);
    });

    test('isKnownName 覆盖函数与符号两类', () {
      final d = buildFixtureData();
      expect(d.isKnownName('GPIO_Mode_Out_PP'), isTrue);
      expect(d.isKnownName('NOT_EXIST'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('列表返回值摘要（真机 bug 回归测试）', () {
    // 复现问题：早先 displayReturn 返回 returnDescZh 全文（最长 40 字），
    // 在 Row 里把函数名挤成一列，出现"函数名竖排"。
    test('displayReturn 只给类型短标签，不返回中文长句', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'GPIO_ReadInputDataBit',
        'name': 'GPIO_ReadInputDataBit',
        'returnType': 'uint8_t',
        'returnDescZh': '返回引脚电平：Bit_SET（1）为高电平，Bit_RESET（0）为低电平。',
      });
      expect(f.displayReturn, 'uint8_t');
      expect(
        f.displayReturn.length,
        lessThan(20),
        reason: '列表右侧是短标签位，放长句会把函数名挤成竖排',
      );
      expect(f.displayReturn, isNot(contains('返回')));
    });

    test('指针返回类型取类型名而非星号', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'returnType': 'GPIO_TypeDef*',
      });
      expect(f.displayReturn, 'GPIO_TypeDef');
    });

    test('void 返回 void 而不是中文', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'returnType': 'void',
        'returnDescZh': '无返回值',
      });
      expect(f.displayReturn, 'void');
    });

    test('shortReturnZh 取首句，供副标题使用', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'returnType': 'uint8_t',
        'returnDescZh': '返回引脚电平：Bit_SET（1）为高电平，Bit_RESET（0）为低电平。',
      });
      expect(f.shortReturnZh, contains('返回引脚电平'));
      expect(f.shortReturnZh, isNot(contains('。')));
    });
  });

  // -------------------------------------------------------------------------
  group('Peripheral 简介截取', () {
    test('oneLineIntro 取第一句', () {
      const p = Peripheral(
        id: 'GPIO',
        name: 'GPIO',
        nameZh: '通用输入输出',
        header: 'h',
        source: 'c',
        file: 'f',
        orderIndex: 1,
        introZh: '',
        usageOverviewZh: '第一句话。第二句话。',
        functionCount: 0,
        symbolCount: 0,
        tags: <String>[],
        sections: <PeripheralSection>[],
      );
      expect(p.oneLineIntro, '第一句话。');
    });

    test('无说明时返回空串而不是崩', () {
      const p = Peripheral(
        id: 'X',
        name: 'X',
        nameZh: 'X',
        header: '',
        source: '',
        file: '',
        orderIndex: 1000,
        introZh: '',
        usageOverviewZh: '',
        functionCount: 0,
        symbolCount: 0,
        tags: <String>[],
        sections: <PeripheralSection>[],
      );
      expect(p.oneLineIntro, '');
    });
  });

  // -------------------------------------------------------------------------
  group('SymbolKind 与容错', () {
    test('未知 kind 解析为 unknown 而不是抛异常', () {
      expect(SymbolKind.fromRaw('macro'), SymbolKind.macro);
      expect(SymbolKind.fromRaw('enum_value'), SymbolKind.enumValue);
      expect(SymbolKind.fromRaw('struct'), SymbolKind.struct);
      expect(SymbolKind.fromRaw('brand_new_kind'), SymbolKind.unknown);
    });

    test('内部符号判断', () {
      const s = SymbolItem(
        id: 'IS_X',
        name: 'IS_X',
        kind: SymbolKind.macro,
        peripheral: 'GPIO',
        visibility: 'internal',
      );
      expect(s.isInternal, isTrue);
    });

    test('fromJson 缺字段时不崩', () {
      final s = SymbolItem.fromJson(<String, dynamic>{'name': 'X'});
      expect(s.name, 'X');
      expect(s.kind, SymbolKind.unknown);
      expect(s.members, isEmpty);
      expect(s.usedBy, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('DataManifest 版本校验', () {
    test('schemaVersion 匹配时兼容', () {
      final m = DataManifest.fromJson(<String, dynamic>{
        'schemaVersion': DataManifest.currentSchemaVersion,
      });
      expect(m.isSchemaCompatible, isTrue);
    });

    test('schemaVersion 不匹配时判定为不兼容', () {
      final m = DataManifest.fromJson(<String, dynamic>{'schemaVersion': 999});
      expect(m.isSchemaCompatible, isFalse);
    });

    test('缺字段时给兜底值', () {
      final m = DataManifest.fromJson(<String, dynamic>{});
      expect(m.schemaVersion, 0);
      expect(m.dataVersion, '未知');
      expect(m.fileOf('symbols', fallback: 'x.json'), 'x.json');
    });
  });

  // -------------------------------------------------------------------------
  group('FunctionItem 显示兜底', () {
    test('中文缺失时退回英文，再退回提示文案', () {
      final withZh = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'briefZh': '中文',
        'briefEn': 'english',
      });
      expect(withZh.displayBrief, '中文');

      final withEn = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'briefEn': 'english',
      });
      expect(withEn.displayBrief, 'english');

      final empty = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
      });
      expect(empty.displayBrief, '暂无中文说明');
    });

    test('void 函数的 displayReturn 是 void（列表短标签）', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'F',
        'name': 'F',
        'returnType': 'void',
      });
      // 列表右侧统一显示类型短标签；中文"无返回值"走 shortReturnZh
      expect(f.displayReturn, 'void');
      expect(f.shortReturnZh, '无返回值');
    });

    test('参数与 symbolRefs 正确解析', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'GPIO_Init',
        'name': 'GPIO_Init',
        'params': <dynamic>[
          <String, dynamic>{
            'name': 'GPIOx',
            'type': 'GPIO_TypeDef*',
            'descZh': '端口',
          },
        ],
        'symbolRefs': <dynamic>['GPIO_InitTypeDef'],
        'headerLine': 351,
        'sourceLine': 173,
      });
      expect(f.params.length, 1);
      expect(f.params.first.name, 'GPIOx');
      expect(f.symbolRefs, <String>['GPIO_InitTypeDef']);
      expect(f.locationIn('stm32f10x_gpio.h'), 'stm32f10x_gpio.h:351');
    });
  });

  // =========================================================================
  // v2 四库结构（契约 docs/contract_v2.md）
  //
  // 这一组全部用「手写小样本」验证，不读 assets/data：
  // 数据由 task-1 并行生成，测试不能假设它已经变成 v2；
  // 而向后兼容（v1 数据照常可读）恰恰是最需要被测住的部分。
  // =========================================================================

  group('LibraryKind：四库标识', () {
    test('ordered 顺序固定为 spl/hal/ll/reg（契约 §1）', () {
      expect(
        LibraryKind.ordered.map((l) => l.raw).toList(),
        <String>['spl', 'hal', 'll', 'reg'],
      );
    });

    test('raw / labelZh / shortEn 与契约一致', () {
      expect(LibraryKind.spl.raw, 'spl');
      expect(LibraryKind.spl.labelZh, '标准库');
      expect(LibraryKind.spl.shortEn, 'SPL');
      expect(LibraryKind.hal.raw, 'hal');
      expect(LibraryKind.hal.labelZh, 'HAL 库');
      expect(LibraryKind.hal.shortEn, 'HAL');
      expect(LibraryKind.ll.labelZh, 'LL 库');
      expect(LibraryKind.ll.shortEn, 'LL');
      expect(LibraryKind.reg.labelZh, '寄存器');
      expect(LibraryKind.reg.shortEn, 'REG');
    });

    test('fromRaw 未知值回退 spl（不能抛）', () {
      expect(LibraryKind.fromRaw('hal'), LibraryKind.hal);
      expect(LibraryKind.fromRaw('ll'), LibraryKind.ll);
      expect(LibraryKind.fromRaw('reg'), LibraryKind.reg);
      // 老数据没有 library 字段 → null → spl
      expect(LibraryKind.fromRaw(null), LibraryKind.spl);
      expect(LibraryKind.fromRaw(''), LibraryKind.spl);
      expect(LibraryKind.fromRaw('brand_new_lib'), LibraryKind.spl);
    });

    test('fromSectionId 能从 id 的 @ 段推断库', () {
      expect(
        LibraryKind.fromSectionId('GPIO@hal#sec1'),
        LibraryKind.hal,
      );
      expect(LibraryKind.fromSectionId('GPIO@ll#sec2'), LibraryKind.ll);
      expect(LibraryKind.fromSectionId('GPIO@reg#sec1'), LibraryKind.reg);
      expect(LibraryKind.fromSectionId('GPIO@spl#sec1'), LibraryKind.spl);
      // v1 的 id 没有 @ 段 → null（由调用方回退）
      expect(LibraryKind.fromSectionId('GPIO#sec1'), isNull);
      expect(LibraryKind.fromSectionId(''), isNull);
    });

    test('orderIndex 反映 ordered 顺序', () {
      expect(LibraryKind.spl.orderIndex, 0);
      expect(LibraryKind.hal.orderIndex, 1);
      expect(LibraryKind.ll.orderIndex, 2);
      expect(LibraryKind.reg.orderIndex, 3);
    });
  });

  group('FunctionItem / SymbolItem：库与 definedIn', () {
    test('v1 数据缺 library/definedIn 时按 spl + 空串兜底', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'GPIO_Init',
        'name': 'GPIO_Init',
      });
      expect(f.library, LibraryKind.spl);
      expect(f.definedIn, '');
      expect(f.libraryLabelZh, '标准库');
    });

    test('v2 数据正确读出 library 与 definedIn（契约 §4）', () {
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'HAL_GPIO_Init',
        'name': 'HAL_GPIO_Init',
        'library': 'hal',
        'definedIn': 'stm32f1xx_hal_gpio.h',
        'sectionId': 'GPIO@hal#sec1',
        'headerLine': 228,
      });
      expect(f.library, LibraryKind.hal);
      expect(f.definedIn, 'stm32f1xx_hal_gpio.h');
      expect(f.libraryLabelZh, 'HAL 库');
      expect(f.locationIn(f.definedIn), 'stm32f1xx_hal_gpio.h:228');
    });

    test('漏写 library 但 sectionId 带 @hal 时按 id 推断', () {
      // 生成器漏字段是常见的数据瑕疵，不能让 HAL 函数被当成 SPL 函数
      final f = FunctionItem.fromJson(<String, dynamic>{
        'id': 'HAL_GPIO_WritePin',
        'name': 'HAL_GPIO_WritePin',
        'sectionId': 'GPIO@hal#sec2',
      });
      expect(f.library, LibraryKind.hal);
    });

    test('toJson 往返保留 library 与 definedIn', () {
      final src = FunctionItem.fromJson(<String, dynamic>{
        'id': 'LL_GPIO_SetPinMode',
        'name': 'LL_GPIO_SetPinMode',
        'library': 'll',
        'definedIn': 'stm32f1xx_ll_gpio.h',
      });
      final back = FunctionItem.fromJson(src.toJson());
      expect(back.library, LibraryKind.ll);
      expect(back.definedIn, 'stm32f1xx_ll_gpio.h');
    });

    test('SymbolItem 的 library 缺省为 spl、可读出 hal（契约 §5）', () {
      final v1 = SymbolItem.fromJson(<String, dynamic>{
        'id': 'GPIO_Mode_Out_PP',
        'name': 'GPIO_Mode_Out_PP',
        'kind': 'enum_value',
      });
      expect(v1.library, LibraryKind.spl);

      final hal = SymbolItem.fromJson(<String, dynamic>{
        'id': 'GPIO_InitTypeDef',
        'name': 'GPIO_InitTypeDef',
        'kind': 'struct',
        'library': 'hal',
      });
      expect(hal.library, LibraryKind.hal);
      expect(SymbolItem.fromJson(hal.toJson()).library, LibraryKind.hal);
    });

    test('FunctionBundle 读 library，缺省 spl；empty 带上外设与库', () {
      final b = FunctionBundle.fromJson(<String, dynamic>{
        'schemaVersion': 2,
        'peripheral': 'GPIO',
        'library': 'hal',
        'functions': <dynamic>[],
      });
      expect(b.library, LibraryKind.hal);

      final legacy = FunctionBundle.fromJson(<String, dynamic>{
        'schemaVersion': 1,
        'peripheral': 'GPIO',
        'functions': <dynamic>[],
      });
      expect(legacy.library, LibraryKind.spl);

      const empty = FunctionBundle.empty(
        peripheral: 'GPIO',
        library: LibraryKind.ll,
      );
      expect(empty.functions, isEmpty);
      expect(empty.peripheral, 'GPIO');
      expect(empty.library, LibraryKind.ll);
    });
  });

  group('Peripheral：v2 libraries 与 v1 向后兼容', () {
    /// 契约 §3 的 v2 样本（只留必要字段）
    Map<String, dynamic> v2Sample() => <String, dynamic>{
          'id': 'GPIO',
          'name': 'GPIO',
          'nameZh': '通用输入输出',
          'orderIndex': 1,
          'tags': <dynamic>['常用', '基础'],
          'libraries': <String, dynamic>{
            'spl': <String, dynamic>{
              'header': 'stm32f10x_gpio.h',
              'source': 'stm32f10x_gpio.c',
              'file': 'functions/GPIO.json',
              'functionCount': 18,
              'symbolCount': 115,
              'introZh': '标准库视角',
              'usageOverviewZh': '标准调用顺序：① 开时钟；② 配置引脚。',
              'usageSteps': <dynamic>['RCC_APB2PeriphClockCmd 使能时钟', '填结构体'],
              'noteZh': '',
            },
            'hal': <String, dynamic>{
              'header': 'stm32f1xx_hal_gpio.h',
              'source': 'stm32f1xx_hal_gpio.c',
              'file': 'functions/hal/GPIO.json',
              'functionCount': 9,
              'symbolCount': 20,
              'introZh': 'HAL 视角',
              'usageOverviewZh': '',
              'usageSteps': <dynamic>[],
              'noteZh': '需先 HAL_Init',
            },
          },
          // 顶层字段是「主库」值
          'header': 'stm32f10x_gpio.h',
          'source': 'stm32f10x_gpio.c',
          'file': 'functions/GPIO.json',
          'introZh': '标准库视角',
          'usageOverviewZh': '标准调用顺序：① 开时钟；② 配置引脚。',
          'functionCount': 18,
          'symbolCount': 115,
          'sections': <dynamic>[
            <String, dynamic>{
              'id': 'GPIO@spl#sec1',
              'title': '初始化与配置函数',
              'titleEn': 'Initialization and Configuration functions',
              'library': 'spl',
              'functionIds': <dynamic>['GPIO_DeInit', 'GPIO_Init'],
            },
            <String, dynamic>{
              'id': 'GPIO@hal#sec1',
              'title': '初始化与配置',
              'titleEn': 'Initialization and Configuration',
              'library': 'hal',
              'functionIds': <dynamic>['HAL_GPIO_Init', 'HAL_GPIO_DeInit'],
            },
          ],
        };

    test('v2：按库读出 header/file/usageSteps/noteZh', () {
      final p = Peripheral.fromJson(v2Sample());
      expect(p.libraries.length, 2);
      expect(p.libraries[LibraryKind.hal]?.header, 'stm32f1xx_hal_gpio.h');
      expect(p.libraries[LibraryKind.hal]?.file, 'functions/hal/GPIO.json');
      expect(p.libraries[LibraryKind.hal]?.noteZh, '需先 HAL_Init');
      expect(
        p.libraries[LibraryKind.spl]?.usageSteps,
        <String>['RCC_APB2PeriphClockCmd 使能时钟', '填结构体'],
      );
    });

    test('v2：availableLibraries 按 ordered 排序', () {
      final p = Peripheral.fromJson(v2Sample());
      expect(
        p.availableLibraries,
        <LibraryKind>[LibraryKind.spl, LibraryKind.hal],
      );
      expect(p.hasLibrary(LibraryKind.hal), isTrue);
      expect(p.hasLibrary(LibraryKind.ll), isFalse);
    });

    test('v2：按库取函数 id 与数量', () {
      final p = Peripheral.fromJson(v2Sample());
      expect(
        p.functionIdsOf(LibraryKind.spl),
        <String>['GPIO_DeInit', 'GPIO_Init'],
      );
      expect(
        p.functionIdsOf(LibraryKind.hal),
        <String>['HAL_GPIO_Init', 'HAL_GPIO_DeInit'],
      );
      expect(p.functionIdsOf(LibraryKind.ll), isEmpty);
      // functionCountOf 优先用数据声明值
      expect(p.functionCountOf(LibraryKind.spl), 18);
      expect(p.functionCountOf(LibraryKind.hal), 9);
      expect(p.functionCountOf(LibraryKind.ll), 0);
    });

    test('v2：sectionsOf 只给该库的分组', () {
      final p = Peripheral.fromJson(v2Sample());
      expect(p.sectionsOf(LibraryKind.hal).length, 1);
      expect(p.sectionsOf(LibraryKind.hal).first.id, 'GPIO@hal#sec1');
      expect(p.sectionsOf(LibraryKind.spl).first.id, 'GPIO@spl#sec1');
      expect(p.sectionsOf(LibraryKind.reg), isEmpty);
    });

    test('v1 向后兼容：没有 libraries 键时自动包成 spl 一项', () {
      final p = Peripheral.fromJson(<String, dynamic>{
        'id': 'GPIO',
        'name': 'GPIO',
        'nameZh': '通用输入输出',
        'header': 'stm32f10x_gpio.h',
        'source': 'stm32f10x_gpio.c',
        'file': 'functions/GPIO.json',
        'orderIndex': 1,
        'introZh': '老数据简介',
        'usageOverviewZh': '老数据总览',
        'functionCount': 18,
        'symbolCount': 115,
        'tags': <dynamic>[],
        'sections': <dynamic>[
          // v1 的 section 没有 library 字段，id 也没有 @ 段
          <String, dynamic>{
            'id': 'GPIO#sec1',
            'title': '初始化与配置函数',
            'functionIds': <dynamic>['GPIO_Init'],
          },
        ],
      });

      // 顶层旧字段原文保留
      expect(p.header, 'stm32f10x_gpio.h');
      expect(p.introZh, '老数据简介');
      expect(p.functionCount, 18);

      // 同时被包装成 spl 一项，UI 走 libraries[spl] 也能拿到
      final spl = p.libraries[LibraryKind.spl];
      expect(spl, isNotNull);
      expect(spl!.header, 'stm32f10x_gpio.h');
      expect(spl.file, 'functions/GPIO.json');
      expect(spl.functionCount, 18);

      // v1 的 section 归到 spl
      expect(p.sections.first.library, LibraryKind.spl);
      expect(p.availableLibraries, <LibraryKind>[LibraryKind.spl]);
      expect(p.functionIdsOf(LibraryKind.spl), <String>['GPIO_Init']);
      expect(p.functionCountOf(LibraryKind.spl), 18);
    });

    test('v1 兼容：section 漏 library 但 id 有 @hal 时按 id 推断', () {
      final sec = PeripheralSection.fromJson(<String, dynamic>{
        'id': 'GPIO@hal#sec2',
        'title': '数据',
        'functionIds': <dynamic>['HAL_GPIO_ReadPin'],
      });
      expect(sec.library, LibraryKind.hal);
    });

    test('分组 id 推断与显式 library 冲突时以显式字段为准', () {
      final sec = PeripheralSection.fromJson(<String, dynamic>{
        'id': 'GPIO@spl#sec1',
        'library': 'hal',
        'title': 'X',
        'functionIds': <dynamic>[],
      });
      expect(sec.library, LibraryKind.hal);
    });

    test('libraries 里出现未知库名时忽略而不是崩', () {
      final p = Peripheral.fromJson(<String, dynamic>{
        'id': 'X',
        'libraries': <String, dynamic>{
          'cmsis': <String, dynamic>{'header': 'x.h'},
          'hal': <String, dynamic>{'header': 'h.h'},
        },
      });
      expect(p.libraries.length, 1);
      expect(p.libraries.containsKey(LibraryKind.hal), isTrue);
    });

    test('全空的 libraries 项不进 availableLibraries', () {
      final p = Peripheral.fromJson(<String, dynamic>{
        'id': 'X',
        'name': 'X',
        'sections': <dynamic>[],
      });
      // v1 兜底项也是全空的（没有任何字段），不该凭空多出一个库页签
      expect(p.availableLibraries, isEmpty);
    });

    test('PeripheralLibrary 的 isEmpty 判定', () {
      expect(const PeripheralLibrary().isEmpty, isTrue);
      expect(
        const PeripheralLibrary(header: 'x.h').isEmpty,
        isFalse,
      );
      expect(
        const PeripheralLibrary(usageSteps: <String>['一步']).isEmpty,
        isFalse,
      );
    });

    test('toJson 往返保留 libraries 与 section 的 library', () {
      final p = Peripheral.fromJson(v2Sample());
      final back = Peripheral.fromJson(p.toJson());
      expect(back.libraries.length, 2);
      expect(back.libraries[LibraryKind.hal]?.noteZh, '需先 HAL_Init');
      expect(back.sectionsOf(LibraryKind.hal).length, 1);
    });
  });

  group('DataManifest：v2 版本与 functionDirs', () {
    test('currentSchemaVersion 是 2', () {
      expect(DataManifest.currentSchemaVersion, 2);
    });

    test('v2 数据读取 halVersion / functionDirs / 分库统计', () {
      final m = DataManifest.fromJson(<String, dynamic>{
        'schemaVersion': 2,
        'dataVersion': '2.0.0',
        'splVersion': 'STM32F10x_StdPeriph_Lib_V3.5.0',
        'halVersion': 'STM32Cube_FW_F1_V1.8.7',
        'functionDirs': <String, dynamic>{
          'spl': 'functions/',
          'hal': 'functions/hal/',
          'll': 'functions/ll/',
          'reg': 'functions/reg/',
        },
        'stats': <String, dynamic>{
          'functionCount': 488,
          'libraryFunctionCounts': <String, dynamic>{
            'spl': 488,
            'hal': 0,
          },
          'librarySymbolCounts': <String, dynamic>{'spl': 7337},
        },
      });

      expect(m.halVersion, 'STM32Cube_FW_F1_V1.8.7');
      expect(m.functionDirOf(LibraryKind.spl), 'functions/');
      expect(m.functionDirOf(LibraryKind.hal), 'functions/hal/');
      expect(m.functionDirOf(LibraryKind.ll), 'functions/ll/');
      expect(m.functionDirOf(LibraryKind.reg), 'functions/reg/');
      expect(m.hasFunctionDirOf(LibraryKind.hal), isTrue);
      expect(m.stats.functionCountOf(LibraryKind.spl), 488);
      expect(m.stats.symbolCountOf(LibraryKind.spl), 7337);
      expect(m.stats.hasLibraryCounts, isTrue);
    });

    test('v1 数据（无 functionDirs/halVersion）照常可读且回退到 functions/', () {
      final m = DataManifest.fromJson(<String, dynamic>{
        'schemaVersion': 1,
        'dataVersion': '1.0.0',
        'splVersion': 'STM32F10x_StdPeriph_Lib_V3.5.0',
        'files': <String, dynamic>{'functions': 'functions/'},
      });

      expect(m.isSchemaCompatible, isTrue, reason: 'v1 老数据必须仍能读');
      expect(m.isLegacy, isTrue);
      expect(m.halVersion, '');
      expect(m.functionDirOf(LibraryKind.spl), 'functions/');
      // hal/ll/reg 在 v1 里不存在，必须回退到契约的固定子目录——
      // 绝不能回退到 functions/，否则会把 SPL 文件当成 HAL 函数读出来
      expect(m.functionDirOf(LibraryKind.hal), 'functions/hal/');
      expect(m.functionDirOf(LibraryKind.ll), 'functions/ll/');
      expect(m.functionDirOf(LibraryKind.reg), 'functions/reg/');
      expect(m.hasFunctionDirOf(LibraryKind.hal), isFalse);
      expect(m.stats.hasLibraryCounts, isFalse);
      expect(m.stats.functionCountOf(LibraryKind.hal), 0);
    });

    test('完全没有 files 时 spl 仍回退到 functions/', () {
      final m = DataManifest.fromJson(<String, dynamic>{'schemaVersion': 1});
      expect(m.functionDirOf(LibraryKind.spl), 'functions/');
      expect(m.functionDirOf(LibraryKind.reg), 'functions/reg/');
    });

    test('functionDirs 缺结尾斜杠时自动补齐', () {
      final m = DataManifest.fromJson(<String, dynamic>{
        'schemaVersion': 2,
        'functionDirs': <String, dynamic>{'hal': 'functions/hal'},
      });
      expect(m.functionDirOf(LibraryKind.hal), 'functions/hal/');
    });

    test('未来版本（v99）判定为不兼容，避免静默解析错', () {
      final m = DataManifest.fromJson(<String, dynamic>{'schemaVersion': 99});
      expect(m.isSchemaCompatible, isFalse);
    });

    test('v2 判定为最新且兼容', () {
      final m = DataManifest.fromJson(<String, dynamic>{'schemaVersion': 2});
      expect(m.isSchemaCompatible, isTrue);
      expect(m.isLatest, isTrue);
      expect(m.isLegacy, isFalse);
    });
  });

  group('SplData：四库索引', () {
    /// 造一个「GPIO 同时有 spl 与 hal」的 SplData，函数详情只加载部分
    SplData buildMultiLibData() {
      const gpio = Peripheral(
        id: 'GPIO',
        name: 'GPIO',
        nameZh: '通用输入输出',
        header: 'stm32f10x_gpio.h',
        source: 'stm32f10x_gpio.c',
        file: 'functions/GPIO.json',
        orderIndex: 1,
        introZh: '',
        usageOverviewZh: '',
        functionCount: 3,
        symbolCount: 0,
        tags: <String>[],
        sections: <PeripheralSection>[
          PeripheralSection(
            id: 'GPIO@spl#sec1',
            title: '初始化',
            functionIds: <String>['GPIO_Init'],
            library: LibraryKind.spl,
          ),
          PeripheralSection(
            id: 'GPIO@hal#sec1',
            title: '初始化',
            functionIds: <String>['HAL_GPIO_Init', 'HAL_GPIO_DeInit'],
            library: LibraryKind.hal,
          ),
        ],
      );

      // 注意：只加载了 spl 的 GPIO_Init，HAL 的两个尚未加载
      final loaded = <FunctionItem>[
        FunctionItem.fromJson(<String, dynamic>{
          'id': 'GPIO_Init',
          'name': 'GPIO_Init',
          'peripheral': 'GPIO',
          'library': 'spl',
        }),
      ];

      return SplData(
        manifest: const DataManifest(
          schemaVersion: 2,
          dataVersion: '2.0.0',
          splVersion: 'x',
          defaultChipId: 'stm32f103c8t6',
          generatedAt: '',
          generator: 'test',
          stats: DataStats(),
          files: <String, String>{},
        ),
        chip: const ChipSpec(
          id: 'stm32f103c8t6',
          name: 'STM32F103C8T6',
          supportedPeripherals: <String>['GPIO'],
        ),
        peripherals: <Peripheral>[gpio],
        functions: loaded,
        symbols: const <SymbolItem>[],
        pinout: PinoutData(
          schemaVersion: 1,
          chipId: 'stm32f103c8t6',
          package: 'LQFP48',
          source: 'test',
          verified: false,
          verifiedNote: '',
          pins: const <Pin>[],
        ),
        compileErrors: const CompileErrorBundle(schemaVersion: 1),
      );
    }

    test('单参 functionsOf 仍可用，返回跨库全部函数', () {
      final d = buildMultiLibData();
      final all = d.functionsOf('GPIO');
      // 只加载了 1 个函数，所以这里是 1 个（按需加载的语义没变）
      expect(all.length, 1);
      expect(all.single.id, 'GPIO_Init');
      expect(d.functionsOf('NOT_EXIST'), isEmpty);
    });

    test('双参 functionsOf 按库过滤', () {
      final d = buildMultiLibData();
      expect(d.functionsOf('GPIO', LibraryKind.spl).single.id, 'GPIO_Init');
      expect(d.functionsOf('GPIO', LibraryKind.hal), isEmpty);
      expect(d.functionsOf('GPIO', LibraryKind.ll), isEmpty);
    });

    test('isKnownFunction 覆盖 HAL/LL/reg 的 id（来自 sections）', () {
      final d = buildMultiLibData();
      // 未加载详情，但 sections 里登记了 → 必须可跳转
      expect(d.isKnownFunction('HAL_GPIO_Init'), isTrue);
      expect(d.isKnownFunction('HAL_GPIO_DeInit'), isTrue);
      expect(d.isKnownFunction('GPIO_Init'), isTrue);
      expect(d.isKnownFunction('NOPE'), isFalse);
    });

    test('peripheralIdOfFunction 对未加载的 HAL 函数也能定位', () {
      final d = buildMultiLibData();
      expect(d.peripheralIdOfFunction('HAL_GPIO_Init'), 'GPIO');
      expect(d.peripheralIdOfFunction('NOPE'), isNull);
    });

    test('libraryOfFunction 未加载时也能看出该去哪个库找', () {
      final d = buildMultiLibData();
      expect(d.libraryOfFunction('GPIO_Init'), LibraryKind.spl);
      expect(d.libraryOfFunction('HAL_GPIO_Init'), LibraryKind.hal);
      expect(d.libraryOfFunction('NOPE'), isNull);
    });

    test('halSymbols 参与 symbolById 索引', () {
      final base = buildMultiLibData();
      final withHal = base.withHalSymbols(const <SymbolItem>[
        SymbolItem(
          id: 'GPIO_InitTypeDef',
          name: 'GPIO_InitTypeDef',
          kind: SymbolKind.struct,
          peripheral: 'GPIO',
          library: LibraryKind.hal,
        ),
      ]);
      expect(withHal.isKnownSymbol('GPIO_InitTypeDef'), isTrue);
      expect(withHal.symbolsOf('GPIO', LibraryKind.hal).length, 1);
      // 原实例不受影响（不可变语义，provider 才能感知变化）
      expect(base.isKnownSymbol('GPIO_InitTypeDef'), isFalse);
    });

    test('withFunctions 合并新加载的函数且不丢 HAL 符号', () {
      final base = buildMultiLibData();
      final merged = base.withFunctions(<FunctionItem>[
        FunctionItem.fromJson(<String, dynamic>{
          'id': 'HAL_GPIO_Init',
          'name': 'HAL_GPIO_Init',
          'peripheral': 'GPIO',
          'library': 'hal',
        }),
      ]);
      expect(merged.functions.length, 2);
      expect(merged.functionsOf('GPIO', LibraryKind.hal).single.id,
          'HAL_GPIO_Init');
    });

    test('多库函数按库顺序排序（spl 在前，hal 在后）', () {
      final d = buildMultiLibData();
      final merged = d.withFunctions(<FunctionItem>[
        FunctionItem.fromJson(<String, dynamic>{
          'id': 'HAL_GPIO_Init',
          'name': 'HAL_GPIO_Init',
          'peripheral': 'GPIO',
          'library': 'hal',
        }),
      ]);
      final all = merged.functionsOf('GPIO');
      expect(
        all.map((f) => f.id).toList(),
        <String>['GPIO_Init', 'HAL_GPIO_Init'],
        reason: 'spl（orderIndex 0）必须排在 hal（1）前面',
      );
    });
  });
}
