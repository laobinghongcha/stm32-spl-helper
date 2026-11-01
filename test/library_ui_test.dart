// 多库 UI 的回归测试。
//
// 覆盖这一轮"从单库扩到四库"后最容易回归的三件事：
//   1. 外设详情页的**库切换条**能渲染，切库后函数列表确实换了；
//   2. 「使用总览」**每个序号另起一行、序号顶格**（用户明确抱怨过的点）；
//   3. 设置里关掉某个库后，搜索结果里不再出现该库的条目。
//
// 这里刻意**不**依赖 assets/data 的新格式（HAL/LL 数据由并行任务生成，
// 本测试写的时候可能还没落盘），所以用契约 v2 的结构在内存里造样本数据。
// 这样测试只验证 UI 行为，不验证数据生成——数据由 data 层的测试负责。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:stm32_spl_helper/data/asset_repository.dart';
import 'package:stm32_spl_helper/data/user_database.dart';
import 'package:stm32_spl_helper/models/ai_reserved.dart';
import 'package:stm32_spl_helper/models/chip.dart';
import 'package:stm32_spl_helper/models/compile_error.dart';
import 'package:stm32_spl_helper/models/function_item.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/manifest.dart';
import 'package:stm32_spl_helper/models/peripheral.dart';
import 'package:stm32_spl_helper/models/pin.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';
import 'package:stm32_spl_helper/models/symbol_item.dart';
import 'package:stm32_spl_helper/pages/function_detail_page.dart';
import 'package:stm32_spl_helper/pages/peripheral_detail_page.dart';
import 'package:stm32_spl_helper/pages/search_page.dart';
import 'package:stm32_spl_helper/providers/app_providers.dart';
import 'package:stm32_spl_helper/providers/user_providers.dart';
import 'package:stm32_spl_helper/utils/theme.dart';
import 'package:stm32_spl_helper/utils/usage_steps.dart';
import 'package:stm32_spl_helper/widgets/library_chip.dart';
import 'package:stm32_spl_helper/widgets/usage_steps_view.dart';

// ---------------------------------------------------------------------------
// 样本数据：一个只有 GPIO 的最小 v2 数据集（spl + hal 两个库）
// ---------------------------------------------------------------------------

/// 造一个函数条目，只填 UI 会用到的字段。
FunctionItem _fn(
  String id, {
  required LibraryKind library,
  String brief = '示例说明',
  String sectionId = 'GPIO@spl#sec1',
  String definedIn = '',
  List<FunctionParam> params = const <FunctionParam>[],
}) {
  return FunctionItem(
    id: id,
    name: id,
    peripheral: 'GPIO',
    sectionId: sectionId,
    prototype: 'void $id(void);',
    returnType: 'void',
    params: params,
    returnDescEn: 'None',
    returnDescZh: '',
    briefEn: '',
    briefZh: brief,
    usageZh: '',
    prerequisites: const <String>[],
    registers: const <String>[],
    relatedFunctions: const <String>[],
    remarks: const <String>[],
    notesZh: const <String>[],
    exampleCode: '',
    exampleLanguage: 'c',
    symbolRefs: const <String>[],
    headerLine: 0,
    sourceLine: 0,
    flags: FunctionFlags.none,
    ai: AiReserved.empty,
    zhSource: 'base',
    library: library,
    definedIn: definedIn,
  );
}

/// 构造一个带 spl + hal 的 GPIO 外设。
Peripheral _gpioPeripheral() {
  return Peripheral(
    id: 'GPIO',
    name: 'GPIO',
    nameZh: '通用输入输出',
    header: 'stm32f10x_gpio.h',
    source: 'stm32f10x_gpio.c',
    file: 'functions/GPIO.json',
    orderIndex: 1,
    introZh: '标准库的 GPIO 简介。',
    usageOverviewZh: '标准调用顺序：① 开时钟；② 填结构体；③ 调 GPIO_Init。',
    functionCount: 2,
    symbolCount: 0,
    tags: const <String>['常用'],
    libraries: <LibraryKind, PeripheralLibrary>{
      LibraryKind.spl: const PeripheralLibrary(
        header: 'stm32f10x_gpio.h',
        source: 'stm32f10x_gpio.c',
        file: 'functions/GPIO.json',
        functionCount: 2,
        symbolCount: 0,
        introZh: '标准库的 GPIO 简介。',
        usageOverviewZh: '标准调用顺序：① 开时钟；② 填结构体；③ 调 GPIO_Init。',
        usageSteps: <String>[],
        noteZh: '',
      ),
      LibraryKind.hal: const PeripheralLibrary(
        header: 'stm32f1xx_hal_gpio.h',
        source: 'stm32f1xx_hal_gpio.c',
        file: 'functions/hal/GPIO.json',
        functionCount: 1,
        symbolCount: 0,
        introZh: 'HAL 的 GPIO 简介：用 GPIO_InitTypeDef 配。',
        usageOverviewZh: 'CubeMX 顺序：① HAL_Init；② 开时钟；③ HAL_GPIO_Init。',
        usageSteps: <String>[],
        noteZh: '',
      ),
      LibraryKind.reg: const PeripheralLibrary(
        header: 'stm32f103xb.h',
        source: '',
        file: 'functions/reg/GPIO.json',
        functionCount: 1,
        symbolCount: 0,
        introZh: '直接写寄存器的 GPIO 简介。',
        usageOverviewZh: '',
        // 覆盖「usageSteps 直出」这条来源：它优先于整段切分
        usageSteps: <String>['开 GPIOA 时钟（RCC_APB2ENR 位 2）', '写 GPIOA->CRL 配模式'],
        noteZh: '',
      ),
    },
    sections: const <PeripheralSection>[
      PeripheralSection(
        id: 'GPIO@spl#sec1',
        title: '初始化与配置函数',
        titleEn: 'Initialization',
        library: LibraryKind.spl,
        functionIds: <String>['GPIO_Init', 'GPIO_DeInit'],
      ),
      PeripheralSection(
        id: 'GPIO@hal#sec1',
        title: 'HAL 初始化',
        titleEn: 'HAL Initialization',
        library: LibraryKind.hal,
        functionIds: <String>['HAL_GPIO_Init'],
      ),
      PeripheralSection(
        id: 'GPIO@reg#sec1',
        title: '控制寄存器',
        titleEn: 'Control registers',
        library: LibraryKind.reg,
        functionIds: <String>['REG_GPIO_CRL'],
      ),
    ],
  );
}

SplData _splData() {
  return SplData(
    manifest: const DataManifest(
      schemaVersion: 2,
      dataVersion: '2.0.0',
      splVersion: 'x',
      defaultChipId: 'stm32f103c8t6',
      generatedAt: '',
      generator: 'test',
      stats: DataStats.empty,
      files: <String, String>{},
    ),
    chip: const ChipSpec(
      id: 'stm32f103c8t6',
      name: 'STM32F103C8T6',
      core: 'ARM Cortex-M3',
      package: 'LQFP48',
      flashKb: 64,
      ramKb: 20,
      maxFreqMhz: 72,
    ),
    peripherals: <Peripheral>[_gpioPeripheral()],
    functions: const <FunctionItem>[],
    symbols: const <SymbolItem>[],
    pinout: PinoutData(
      schemaVersion: 1,
      chipId: 'stm32f103c8t6',
      package: 'LQFP48',
      source: '',
      verified: false,
      verifiedNote: '',
      pins: const <Pin>[],
    ),
    compileErrors: const CompileErrorBundle(schemaVersion: 1),
  );
}

/// 假仓库：按「库 + 外设」返回内存里的函数包。
///
/// 真仓库要读 assets/data 下的文件，而 HAL/LL 的数据文件由并行任务生成，
/// 这里按契约 v2 的路径形状直接给内存数据，测试才不依赖数据生成进度。
class _FakeRepo extends AssetRepository {
  final Map<String, FunctionBundle> byKey;

  _FakeRepo(this.byKey);

  @override
  Future<FunctionBundle> loadFunctionsOf(String peripheralId, LibraryKind lib) async {
    return byKey['${lib.raw}:$peripheralId'] ??
        FunctionBundle(
          schemaVersion: 2,
          peripheral: peripheralId,
          functions: const <FunctionItem>[],
        );
  }
}

Map<String, FunctionBundle> _bundles() => <String, FunctionBundle>{
      'spl:GPIO': FunctionBundle(
        schemaVersion: 2,
        peripheral: 'GPIO',
        functions: <FunctionItem>[
          _fn('GPIO_Init', library: LibraryKind.spl, brief: '标准库初始化'),
          _fn('GPIO_DeInit', library: LibraryKind.spl, brief: '标准库复位'),
        ],
      ),
      'hal:GPIO': FunctionBundle(
        schemaVersion: 2,
        peripheral: 'GPIO',
        functions: <FunctionItem>[
          _fn(
            'HAL_GPIO_Init',
            library: LibraryKind.hal,
            brief: 'HAL 初始化',
            sectionId: 'GPIO@hal#sec1',
            definedIn: 'stm32f1xx_hal_gpio.h',
          ),
        ],
      ),
      // reg 库：一个"函数"其实是一条寄存器，params 是它的位域宏
      'reg:GPIO': FunctionBundle(
        schemaVersion: 2,
        peripheral: 'GPIO',
        functions: <FunctionItem>[
          FunctionItem(
            id: 'REG_GPIO_CRL',
            name: 'GPIO_CRL',
            peripheral: 'GPIO',
            sectionId: 'GPIO@reg#sec1',
            // 契约 §4.1：prototype 是直接访问表达式
            prototype: 'GPIOA->CRL',
            returnType: 'uint32_t',
            params: const <FunctionParam>[
              FunctionParam(
                name: 'GPIO_CRL_MODE0',
                type: 'bits[1:0]',
                descEn: 'Port x mode bits',
                descZh: '第 0 号引脚的输出模式',
              ),
              FunctionParam(
                name: 'GPIO_CRL_CNF0',
                type: 'bits[3:2]',
                descEn: 'Port x configuration bits',
                descZh: '第 0 号引脚的输入/输出配置',
              ),
            ],
            returnDescEn: '',
            returnDescZh: '',
            briefEn: 'Port configuration register low',
            briefZh: '端口配置低寄存器',
            usageZh: '',
            prerequisites: const <String>[],
            registers: const <String>[],
            relatedFunctions: const <String>[],
            remarks: const <String>[],
            notesZh: const <String>[],
            exampleCode: 'GPIOA->CRL = 0x44444444;\nGPIOA->ODR |= 1 << 0;',
            exampleLanguage: 'c',
            symbolRefs: const <String>[],
            headerLine: 0,
            sourceLine: 0,
            flags: const FunctionFlags(macroLike: true),
            ai: AiReserved.empty,
            zhSource: 'base',
            library: LibraryKind.reg,
            definedIn: 'stm32f103xb.h',
          ),
        ],
      ),
    };

/// 统一外壳。[enabled] 用来模拟设置页里勾选的库。
Widget _wrap(
  Widget child, {
  Set<String> enabled = const <String>{'spl', 'hal', 'll', 'reg'},
}) {
  return ProviderScope(
    overrides: <Override>[
      splDataProvider.overrideWith((ref) async => _splData()),
      enabledLibrariesProvider.overrideWithValue(enabled),
      userStoreProvider.overrideWithValue(InMemoryUserStore()),
      assetRepositoryProvider.overrideWithValue(_FakeRepo(_bundles())),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void _useViewport(WidgetTester tester, double widthDp) {
  tester.view.physicalSize = Size(widthDp * 3, 900 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 逐帧 pump，不用 pumpAndSettle（页面里有折叠/展开动画链）。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('库徽标 LibraryChip', () {
    testWidgets('四种库渲染出各自的 shortEn 文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              for (final lib in LibraryKind.ordered)
                LibraryChip(library: lib),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      for (final lib in LibraryKind.ordered) {
        expect(find.text(lib.shortEn), findsOneWidget,
            reason: '${lib.raw} 的徽标文字应为 ${lib.shortEn}');
      }
      expect(tester.takeException(), isNull);
    });

    test('四种库的色相两两不同（深色模式也成立）', () {
      final light = AppTheme.light().colorScheme;
      final dark = AppTheme.dark().colorScheme;
      for (final isDark in <bool>[false, true]) {
        final scheme = isDark ? dark : light;
        final colors = <LibraryKind, Color>{
          for (final lib in LibraryKind.ordered)
            lib: LibraryChip.colorOf(lib, scheme, isDark),
        };
        // 色相差异是"一眼分辨"的基础，任意两个库都不能撞色
        final values = colors.values.map((c) => c.toARGB32()).toSet();
        expect(values.length, LibraryKind.ordered.length,
            reason: '四个库的颜色必须两两不同（isDark=$isDark）：$colors');
      }
    });

    test('未知 raw 回退到 spl（容错）', () {
      expect(LibraryKind.fromRaw('hal'), LibraryKind.hal);
      expect(LibraryKind.fromRaw('nope'), LibraryKind.spl);
      expect(LibraryKind.fromRaw(null), LibraryKind.spl);
    });
  });

  group('使用总览分行渲染', () {
    testWidgets('①②③ 切成 3 步，每步一行、序号在行首', (tester) async {
      // 这正是用户抱怨的原始形态：一整段、序号挤在一起
      const raw = '① 使能 GPIOx 时钟；② 填写 GPIO_InitTypeDef；③ 调用 GPIO_Init 写入配置。';
      final steps = splitUsageSteps(raw);

      // 切分层面先对上：三步，序号依次是 ①②③
      final numbered = steps.where((s) => s.hasMarker).toList();
      expect(numbered.length, 3, reason: '应切成 3 步，实际：${steps.map((s) => s.marker).toList()}');
      expect(numbered.map((s) => s.marker).toList(), <String>['①', '②', '③']);

      _useViewport(tester, 360);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          // 左侧零内边距 = 序号顶格
          body: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: UsageStepsView(steps: steps),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 三步的正文各渲染一次
      expect(find.textContaining('使能 GPIOx 时钟'), findsOneWidget);
      expect(find.textContaining('填写 GPIO_InitTypeDef'), findsOneWidget);
      expect(find.textContaining('调用 GPIO_Init 写入配置'), findsOneWidget);

      // 每个序号都是一行，且这一行的左边缘 == 容器左边缘（顶格）。
      // 用"序号文本"的左上角 x 与整个视图的左上角 x 比对——
      // 若哪天有人给行加了左侧 padding，这里会立刻红。
      final viewLeft = tester.getTopLeft(find.byType(UsageStepsView)).dx;
      for (final marker in <String>['①', '②', '③']) {
        final markerFinder = find.text('$marker ');
        expect(markerFinder, findsOneWidget, reason: '序号 $marker 应有独立一行');
        final markerLeft = tester.getTopLeft(markerFinder).dx;
        expect(markerLeft - viewLeft, lessThan(1.0),
            reason: '序号 $marker 必须顶格（左内边距为 0），实际偏移 ${markerLeft - viewLeft}');
      }

      // 三行的 y 坐标必须各不相同 —— 这就是"另起一行"
      final ys = <double>[
        for (final m in <String>['① ', '② ', '③ '])
          tester.getTopLeft(find.text(m)).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
      expect(tester.takeException(), isNull);
    });

    testWidgets('引导语单独成段（字号更小、无序号列）', (tester) async {
      final steps = splitUsageSteps('标准调用顺序：① 开时钟；② 调 GPIO_Init。');
      expect(steps.first.marker, '', reason: '引导语应为无序号项');
      expect(steps.first.text, contains('标准调用顺序'));

      _useViewport(tester, 360);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: UsageStepsView(steps: steps),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('标准调用顺序'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表不渲染任何东西，也不崩', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: UsageStepsView(steps: <UsageStep>[]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(UsageStepsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('外设详情页的库切换', () {
    testWidgets('库切换条渲染出 spl + hal 两个徽标', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const PeripheralDetailPage(peripheralId: 'GPIO'),
      ));
      await _pumpFrames(tester);

      // 切换条上的两个库都有（列表行尾也会有 compact 徽标，
      // 所以只断言"至少出现"，并用 widget 的 selected 属性区分）
      final chips = tester
          .widgetList<LibraryChip>(find.byType(LibraryChip))
          .toList(growable: false);
      expect(chips.any((c) => c.library == LibraryKind.spl), isTrue);
      expect(chips.any((c) => c.library == LibraryKind.hal), isTrue);
      // 默认选中第一个可用库（spl）
      expect(
        chips.any((c) => c.library == LibraryKind.spl && c.selected),
        isTrue,
        reason: '默认应选中第一个可用库',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('切到 HAL 后函数列表变成 HAL 的函数', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const PeripheralDetailPage(peripheralId: 'GPIO'),
      ));
      await _pumpFrames(tester);

      // 初始是 SPL：看得到 GPIO_Init，看不到 HAL_GPIO_Init
      expect(find.text('GPIO_Init'), findsOneWidget);
      expect(find.text('HAL_GPIO_Init'), findsNothing);

      // 点切换条上的 HAL 徽标（选中态为 false 的那个）
      final halChip = find.byWidgetPredicate(
        (w) => w is LibraryChip && w.library == LibraryKind.hal && !w.selected,
      );
      expect(halChip, findsWidgets);
      await tester.tap(halChip.first);
      await _pumpFrames(tester);

      // 切库后列表内容确实换了
      expect(find.text('HAL_GPIO_Init'), findsOneWidget,
          reason: '切到 HAL 后应显示 HAL_GPIO_Init');
      expect(find.text('GPIO_Init'), findsNothing,
          reason: '切到 HAL 后不应再显示 SPL 的 GPIO_Init');
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置里关掉 hal 后，切换条上不再出现 HAL', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const PeripheralDetailPage(peripheralId: 'GPIO'),
        enabled: <String>{'spl'},
      ));
      await _pumpFrames(tester);

      // 切换条里不应有 HAL（列表行尾的徽标也不该有）
      final chips = tester
          .widgetList<LibraryChip>(find.byType(LibraryChip))
          .toList(growable: false);
      expect(chips.any((c) => c.library == LibraryKind.hal), isFalse,
          reason: 'HAL 未启用时不应渲染 HAL 徽标');
      expect(find.text('HAL_GPIO_Init'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('使用总览默认收起，展开后按步渲染且序号顶格', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const PeripheralDetailPage(peripheralId: 'GPIO'),
      ));
      await _pumpFrames(tester);

      // 默认收起：一行摘要代替整段总览。
      // 这是有意的——HAL 的简介 + 5 步总览会占满 360dp 首屏，
      // 切完库看不到任何函数，查询型页面最怕这个。
      expect(find.byType(UsageStepsView), findsNothing,
          reason: '头部默认收起时不该渲染步骤正文');
      expect(find.textContaining('步使用总览'), findsOneWidget,
          reason: '收起态要有"共几步"的摘要，否则用户不知道里面有内容');

      // 点标题行展开
      await tester.tap(find.textContaining('步使用总览'));
      await _pumpFrames(tester);

      expect(find.byType(UsageStepsView), findsOneWidget,
          reason: '展开后外设头部的使用总览应走 UsageStepsView');
      // SPL 的总览是「① 开时钟；② 填结构体；③ 调 GPIO_Init。」
      expect(find.text('① '), findsOneWidget);
      expect(find.text('② '), findsOneWidget);
      expect(find.text('③ '), findsOneWidget);

      // 序号顶格：与 UsageStepsView 容器的左缘对齐
      final viewLeft = tester.getTopLeft(find.byType(UsageStepsView)).dx;
      final markerLeft = tester.getTopLeft(find.text('① ')).dx;
      expect(markerLeft - viewLeft, lessThan(1.0),
          reason: '序号必须顶格（左内边距 0）');

      // 再点一次收起（展开状态下摘要文字已被隐藏，所以点标题里的库计数胶囊）
      await tester.tap(find.textContaining('个函数'));
      await _pumpFrames(tester);
      expect(find.byType(UsageStepsView), findsNothing,
          reason: '再点一次应重新收起');
      expect(find.textContaining('步使用总览'), findsOneWidget,
          reason: '收起后摘要应回来');
      expect(tester.takeException(), isNull);
    });

    testWidgets('切到 HAL 后函数直接可见（头部收起不挡列表）', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const PeripheralDetailPage(peripheralId: 'GPIO'),
      ));
      await _pumpFrames(tester);

      final halChip = find.byWidgetPredicate(
        (w) => w is LibraryChip && w.library == LibraryKind.hal && !w.selected,
      );
      await tester.tap(halChip.first);
      await _pumpFrames(tester);

      // 关键回归：切库后第一个函数必须在首屏内，而不是被头部挤到屏幕外
      expect(find.text('HAL_GPIO_Init'), findsOneWidget,
          reason: '切到 HAL 后函数列表应立即可见（头部默认收起）');
      final fnY = tester.getTopLeft(find.text('HAL_GPIO_Init')).dy;
      final screenH = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;
      expect(fnY, lessThan(screenH),
          reason: '首个函数应落在首屏内，实际 y=$fnY / 屏高 $screenH');
      expect(tester.takeException(), isNull);
    });
  });

  group('搜索页按启用库过滤', () {
    /// 用真实 assets 里的外设 + 一份人工注入的 HAL 命中来测过滤逻辑。
    ///
    /// 这里需要一个"确实含 HAL_ 条目"的索引，而 assets/data 的 HAL 数据
    /// 由并行任务生成，所以用真实核心数据 + 手动构造的 SplData 变体。
    SplData dataWithHalFunction() {
      final base = _splData();
      final gpio = base.peripherals.first;
      // 在 peripherals.json 的 sections 里补一条 HAL 分组，
      // 索引构建时会把它的 functionIds 收进来（索引只认 functionIds）
      final patched = Peripheral(
        id: gpio.id,
        name: gpio.name,
        nameZh: gpio.nameZh,
        header: gpio.header,
        source: gpio.source,
        file: gpio.file,
        orderIndex: gpio.orderIndex,
        introZh: gpio.introZh,
        usageOverviewZh: gpio.usageOverviewZh,
        functionCount: gpio.functionCount,
        symbolCount: gpio.symbolCount,
        tags: gpio.tags,
        libraries: gpio.libraries,
        sections: <PeripheralSection>[
          ...gpio.sections,
          const PeripheralSection(
            id: 'GPIO@hal#sec9',
            title: 'HAL 附加',
            library: LibraryKind.hal,
            functionIds: <String>['HAL_GPIO_ReadPin'],
          ),
        ],
      );
      return SplData(
        manifest: base.manifest,
        chip: base.chip,
        peripherals: <Peripheral>[patched],
        functions: const <FunctionItem>[],
        symbols: const <SymbolItem>[],
        pinout: base.pinout,
        compileErrors: base.compileErrors,
      );
    }

    Future<void> pumpSearch(WidgetTester tester, Set<String> enabled) async {
      await tester.pumpWidget(ProviderScope(
        overrides: <Override>[
          splDataProvider.overrideWith((ref) async => dataWithHalFunction()),
          enabledLibrariesProvider.overrideWithValue(enabled),
          userStoreProvider.overrideWithValue(InMemoryUserStore()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SearchPage()),
        ),
      ));
      await tester.pumpAndSettle();
      // 输入关键词触发搜索
      await tester.enterText(find.byType(TextField), 'GPIO');
      await tester.pumpAndSettle();
    }

    testWidgets('四库全开时 HAL_ 开头的条目会出现', (tester) async {
      _useViewport(tester, 360);
      await pumpSearch(
        tester,
        <String>{'spl', 'hal', 'll', 'reg'},
      );

      expect(find.textContaining('HAL_GPIO_ReadPin'), findsWidgets,
          reason: 'HAL 启用时应能搜到 HAL_ 函数');
      expect(tester.takeException(), isNull);
    });

    testWidgets('关掉 hal 后搜索结果里不再出现 HAL_ 条目', (tester) async {
      _useViewport(tester, 360);
      await pumpSearch(tester, <String>{'spl'});

      expect(find.textContaining('HAL_GPIO_ReadPin'), findsNothing,
          reason: 'HAL 未启用时不应出现 HAL_ 开头的条目');
      // SPL 的结果仍在
      expect(find.text('GPIO_Init'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('函数详情页按库呈现', () {
    testWidgets('HAL 函数：标题有 HAL 徽标，副标题显示 definedIn', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const FunctionDetailPage(functionId: 'HAL_GPIO_Init'),
      ));
      await _pumpFrames(tester);

      // 库徽标
      final chips = tester
          .widgetList<LibraryChip>(find.byType(LibraryChip))
          .toList(growable: false);
      expect(chips.any((c) => c.library == LibraryKind.hal), isTrue,
          reason: 'HAL 函数应显示 HAL 徽标');
      // definedIn 出现在副标题与「所属库」块里
      expect(find.textContaining('stm32f1xx_hal_gpio.h'), findsWidgets,
          reason: '副标题应显示 definedIn 头文件名');
      expect(find.text('所属库'), findsOneWidget);
      // 该库的使用总览也要渲染（HAL 的调用顺序）
      expect(find.byType(UsageStepsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reg 函数：显示寄存器表达式与位域表', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const FunctionDetailPage(functionId: 'REG_GPIO_CRL'),
      ));
      await _pumpFrames(tester);

      // 寄存器访问表达式（prototype）
      expect(find.textContaining('GPIOA->CRL'), findsWidgets,
          reason: 'reg 函数应展示寄存器地址表达式');
      // 位域表三列的表头。
      // "位域"同时是区块标题与列名，所以这里用 findsWidgets；
      // "位域名"与"说明"只属于表头。
      expect(find.text('位域名'), findsOneWidget);
      expect(find.text('位域'), findsWidgets);
      expect(find.text('说明'), findsOneWidget);
      // 位域行内容
      expect(find.text('GPIO_CRL_MODE0'), findsOneWidget);
      expect(find.text('bits[1:0]'), findsOneWidget);
      expect(find.textContaining('输出模式'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPL 函数不渲染位域表', (tester) async {
      _useViewport(tester, 360);
      await tester.pumpWidget(_wrap(
        const FunctionDetailPage(functionId: 'GPIO_Init'),
      ));
      await _pumpFrames(tester);

      expect(find.text('位域名'), findsNothing,
          reason: 'SPL 函数不该渲染位域表');
      expect(tester.takeException(), isNull);
    });
  });
}
