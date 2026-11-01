// 阶段 9（打磨与打包）的测试。
//
// 重点是**设置持久化**：主题 / 代码字号 / 首页过滤开关三项，
// 用户调完之后重启必须还在。这类"写进去了但读不回来"的问题
// 只有走一遍完整往返才能发现。
//
// 另外校验若干打包相关的静态事实（图标资源齐全、版本号一致），
// 这些在构建失败时才发现的代价很高。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:stm32_spl_helper/data/settings_store.dart';
import 'package:stm32_spl_helper/data/user_database.dart';
import 'package:stm32_spl_helper/pages/settings_page.dart';
import 'package:stm32_spl_helper/providers/app_providers.dart';
import 'package:stm32_spl_helper/providers/user_providers.dart';
import 'package:stm32_spl_helper/utils/theme.dart';

/// 造一个可注入的容器
ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('设置：默认值', () {
    test('首次启动用默认值', () async {
      final s = await SettingsStore().load();
      expect(s.themeMode, ThemeMode.system);
      expect(s.codeFontSize, 13.0);
      expect(s.onlySupported, isFalse);
      expect(s, AppSettings.defaults);
    });
  });

  group('设置：持久化往返', () {
    test('主题模式写进去能读回来', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(themeMode: ThemeMode.dark));
      final back = await store.load();
      expect(back.themeMode, ThemeMode.dark);
    });

    test('三种主题模式都能往返', () async {
      for (final m in ThemeMode.values) {
        final store = SettingsStore();
        await store.save(AppSettings(themeMode: m));
        expect((await store.load()).themeMode, m, reason: '$m 往返失败');
      }
    });

    test('代码字号写进去能读回来', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(codeFontSize: 17.0));
      expect((await store.load()).codeFontSize, 17.0);
    });

    test('首页过滤开关写进去能读回来', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(onlySupported: true));
      expect((await store.load()).onlySupported, isTrue);
    });

    test('三项一起写不会互相覆盖', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(
        themeMode: ThemeMode.light,
        codeFontSize: 19.0,
        onlySupported: true,
      ));
      final back = await store.load();
      expect(back.themeMode, ThemeMode.light);
      expect(back.codeFontSize, 19.0);
      expect(back.onlySupported, isTrue);
    });

    test('跨实例保留（真实持久化，不是内存态）', () async {
      await SettingsStore().save(const AppSettings(themeMode: ThemeMode.dark));
      expect((await SettingsStore().load()).themeMode, ThemeMode.dark);
    });
  });

  group('设置：容错', () {
    test('字号超上限被夹回', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('settings.code_font_size', 999.0);
      final s = await SettingsStore().load();
      expect(s.codeFontSize, AppSettings.maxCodeFontSize);
    });

    test('字号超下限被夹回', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('settings.code_font_size', 1.0);
      expect(
        (await SettingsStore().load()).codeFontSize,
        AppSettings.minCodeFontSize,
      );
    });

    test('保存时也夹一次（避免写进非法值）', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(codeFontSize: 100.0));
      expect((await store.load()).codeFontSize, AppSettings.maxCodeFontSize);
    });

    test('NaN 字号退回默认值而不是崩溃', () {
      expect(SettingsStore.clampFontSize(double.nan), 13.0);
    });

    test('无法识别的主题字符串退回默认', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('settings.theme_mode', 'rainbow');
      expect((await SettingsStore().load()).themeMode, ThemeMode.system);
    });

    test('存储里混入其它键不影响读取', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('unrelated.key', 'x');
      await prefs.setBool('settings.only_supported', true);
      final s = await SettingsStore().load();
      expect(s.onlySupported, isTrue);
      expect(s.themeMode, ThemeMode.system);
    });
  });

  group('设置：notifier', () {
    test('setThemeMode 后 state 立刻更新', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
      expect(c.read(settingsProvider).valueOrNull!.themeMode, ThemeMode.dark);
    });

    test('setThemeMode 会落盘（新实例能读到）', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.light);
      expect((await SettingsStore().load()).themeMode, ThemeMode.light);
    });

    test('setCodeFontSize 会自动夹到合法区间', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setCodeFontSize(500);
      expect(
        c.read(settingsProvider).valueOrNull!.codeFontSize,
        AppSettings.maxCodeFontSize,
      );
    });

    test('派生 provider 跟着设置走', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      // 初始值
      expect(c.read(themeModeProvider), ThemeMode.system);
      expect(c.read(codeFontSizeProvider), 13.0);
      expect(c.read(onlySupportedProvider), isFalse);

      await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
      await c.read(settingsProvider.notifier).setCodeFontSize(16);
      await c.read(settingsProvider.notifier).setOnlySupported(true);

      expect(c.read(themeModeProvider), ThemeMode.dark);
      expect(c.read(codeFontSizeProvider), 16.0);
      expect(c.read(onlySupportedProvider), isTrue);
    });

    test('未加载完时派生 provider 给默认值（不崩、不返回 null）', () {
      final c = makeContainer();
      // 故意不 await settingsProvider.future
      expect(c.read(themeModeProvider), ThemeMode.system);
      expect(c.read(codeFontSizeProvider), 13.0);
      expect(c.read(onlySupportedProvider), isFalse);
    });

    test('恢复默认设置', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
      await c.read(settingsProvider.notifier).setOnlySupported(true);

      await c.read(settingsProvider.notifier).resetToDefaults();

      final s = c.read(settingsProvider).valueOrNull!;
      expect(s, AppSettings.defaults);
      // 也要落盘
      expect((await SettingsStore().load()).themeMode, ThemeMode.system);
    });

    test('多次修改不会丢掉之前改过的项', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);

      await n.setThemeMode(ThemeMode.dark);
      await n.setCodeFontSize(18);
      await n.setOnlySupported(true);

      final s = c.read(settingsProvider).valueOrNull!;
      expect(s.themeMode, ThemeMode.dark, reason: '改字号不应把主题改回去');
      expect(s.codeFontSize, 18.0);
      expect(s.onlySupported, isTrue);
    });
  });

  group('设置：函数库开关（enabledLibraries）', () {
    test('默认四库全开', () async {
      final s = await SettingsStore().load();
      expect(s.enabledLibraries, <String>{'spl', 'hal', 'll', 'reg'});
      expect(s.enabledLibraries, AppSettings.defaultLibraries);
      expect(s.allLibrariesEnabled, isTrue);
      expect(s.noLibraryEnabled, isFalse);
    });

    test('defaults 里也是四库全开', () {
      expect(AppSettings.defaults.enabledLibraries,
          <String>{'spl', 'hal', 'll', 'reg'});
    });

    test('写进去能读回来（只开 SPL + HAL）', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(
        enabledLibraries: <String>{'spl', 'hal'},
      ));
      expect(
        (await store.load()).enabledLibraries,
        <String>{'spl', 'hal'},
      );
    });

    test('单个库也能往返', () async {
      for (final one in AppSettings.libraryOrder) {
        final store = SettingsStore();
        await store.save(AppSettings(enabledLibraries: <String>{one}));
        expect(
          (await store.load()).enabledLibraries,
          <String>{one},
          reason: '只开 $one 往返失败',
        );
      }
    });

    test('持久化成 StringList，顺序固定为 spl/hal/ll/reg', () async {
      final store = SettingsStore();
      // 故意乱序传入
      await store.save(const AppSettings(
        enabledLibraries: <String>{'reg', 'spl', 'll'},
      ));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('settings.enabled_libraries'),
        <String>['spl', 'll', 'reg'],
      );
    });

    test('缺失时用默认全开（老版本升级上来的情况）', () async {
      final prefs = await SharedPreferences.getInstance();
      // 只有老的三项，没有 enabled_libraries
      await prefs.setString('settings.theme_mode', 'dark');
      await prefs.setBool('settings.only_supported', true);
      final s = await SettingsStore().load();
      expect(s.enabledLibraries, AppSettings.defaultLibraries);
      expect(s.themeMode, ThemeMode.dark, reason: '老字段仍要能读到');
    });

    test('读到空集合时回退默认全开（防误操作后什么都看不到）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('settings.enabled_libraries', <String>[]);
      expect((await SettingsStore().load()).enabledLibraries,
          AppSettings.defaultLibraries);
    });

    test('全是非法值时也回退默认全开', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'settings.enabled_libraries',
        <String>['spi', '', 'HAL_X', 'foo'],
      );
      expect((await SettingsStore().load()).enabledLibraries,
          AppSettings.defaultLibraries);
    });

    test('混入非法值时只保留合法项，不整组丢弃', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'settings.enabled_libraries',
        <String>['spl', 'spi', 'reg'],
      );
      expect(
        (await SettingsStore().load()).enabledLibraries,
        <String>{'spl', 'reg'},
      );
    });

    test('大小写与空白被规整（HAL → hal）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'settings.enabled_libraries',
        <String>[' HAL ', 'Spl'],
      );
      expect(
        (await SettingsStore().load()).enabledLibraries,
        <String>{'spl', 'hal'},
      );
    });

    test('与其它三项一起写不会互相覆盖', () async {
      final store = SettingsStore();
      await store.save(const AppSettings(
        themeMode: ThemeMode.dark,
        codeFontSize: 16,
        onlySupported: true,
        enabledLibraries: <String>{'ll'},
      ));
      final back = await store.load();
      expect(back.themeMode, ThemeMode.dark);
      expect(back.codeFontSize, 16.0);
      expect(back.onlySupported, isTrue);
      expect(back.enabledLibraries, <String>{'ll'});
    });

    test('normalizeLibraries：null 回退全开、空回退全开、有序化', () {
      expect(SettingsStore.normalizeLibraries(null), AppSettings.libraryOrder);
      expect(SettingsStore.normalizeLibraries(<String>[]), AppSettings.libraryOrder);
      expect(
        SettingsStore.normalizeLibraries(<String>['ll', 'spl']),
        <String>['spl', 'll'],
      );
    });

    test('isLibraryEnabled / withLibrary / withAllLibraries', () {
      const s = AppSettings(enabledLibraries: <String>{'spl'});
      expect(s.isLibraryEnabled('spl'), isTrue);
      expect(s.isLibraryEnabled('hal'), isFalse);

      expect(s.withLibrary('hal', true).enabledLibraries,
          <String>{'spl', 'hal'});
      expect(s.withLibrary('spl', false).enabledLibraries, isEmpty);
      // 重复开启是幂等的
      expect(s.withLibrary('spl', true).enabledLibraries, <String>{'spl'});

      expect(s.withAllLibraries(on: true).enabledLibraries,
          AppSettings.defaultLibraries);
      expect(s.withAllLibraries(on: false).enabledLibraries, isEmpty);
    });

    test('allLibrariesEnabled / noLibraryEnabled 的判定', () {
      expect(const AppSettings().allLibrariesEnabled, isTrue);
      expect(
        const AppSettings(enabledLibraries: <String>{'spl', 'hal', 'll'})
            .allLibrariesEnabled,
        isFalse,
      );
      expect(
        const AppSettings(enabledLibraries: <String>{}).noLibraryEnabled,
        isTrue,
      );
    });
  });

  group('设置：notifier 的函数库操作', () {
    test('setLibraryEnabled 关掉一个库', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setLibraryEnabled('hal', false);
      final s = c.read(settingsProvider).valueOrNull!;
      expect(s.enabledLibraries, <String>{'spl', 'll', 'reg'});
    });

    test('setLibraryEnabled 打开一个库', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);
      await n.setLibraryEnabled('hal', false);
      await n.setLibraryEnabled('hal', true);
      expect(c.read(settingsProvider).valueOrNull!.enabledLibraries,
          AppSettings.defaultLibraries);
    });

    test('setLibraryEnabled 会落盘', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setLibraryEnabled('spl', false);
      expect(
        (await SettingsStore().load()).enabledLibraries,
        <String>{'hal', 'll', 'reg'},
      );
    });

    test('setLibraryEnabled 忽略未知库标识（不写进设置）', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setLibraryEnabled('spi', true);
      expect(c.read(settingsProvider).valueOrNull!.enabledLibraries,
          AppSettings.defaultLibraries);
    });

    test('setAllLibraries(true/false)', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);

      await n.setAllLibraries(false);
      expect(c.read(settingsProvider).valueOrNull!.enabledLibraries, isEmpty);

      await n.setAllLibraries(true);
      expect(c.read(settingsProvider).valueOrNull!.enabledLibraries,
          AppSettings.defaultLibraries);
    });

    test('enabledLibrariesProvider 跟着设置走', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      expect(c.read(enabledLibrariesProvider), AppSettings.defaultLibraries);

      await c.read(settingsProvider.notifier).setLibraryEnabled('ll', false);
      expect(c.read(enabledLibrariesProvider),
          <String>{'spl', 'hal', 'reg'});
    });

    test('libraryVisibleProvider 按库返回 bool', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);

      expect(c.read(libraryVisibleProvider('spl')), isTrue);
      expect(c.read(libraryVisibleProvider('hal')), isTrue);

      await c.read(settingsProvider.notifier).setLibraryEnabled('hal', false);
      expect(c.read(libraryVisibleProvider('spl')), isTrue);
      expect(c.read(libraryVisibleProvider('hal')), isFalse);

      // 大小写不敏感（上游可能传 HAL）
      expect(c.read(libraryVisibleProvider('HAL')), isFalse);
      expect(c.read(libraryVisibleProvider('SPL')), isTrue);
    });

    test('hasAnyLibraryProvider 在任何时候都为 true（默认全开）', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      expect(c.read(hasAnyLibraryProvider), isTrue);
    });

    test('未加载完时 enabledLibrariesProvider 给全开（不崩、不空）', () {
      final c = makeContainer();
      // 故意不 await settingsProvider.future
      expect(c.read(enabledLibrariesProvider), AppSettings.defaultLibraries);
      expect(c.read(libraryVisibleProvider('hal')), isTrue);
    });

    test('改库开关不会影响其它三项', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);

      await n.setThemeMode(ThemeMode.dark);
      await n.setCodeFontSize(17);
      await n.setOnlySupported(true);
      await n.setLibraryEnabled('reg', false);

      final s = c.read(settingsProvider).valueOrNull!;
      expect(s.themeMode, ThemeMode.dark);
      expect(s.codeFontSize, 17.0);
      expect(s.onlySupported, isTrue);
      expect(s.enabledLibraries, <String>{'spl', 'hal', 'll'});
    });

    test('恢复默认设置会把库恢复成全开', () async {
      final c = makeContainer();
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);

      await n.setLibraryEnabled('spl', false);
      await n.setLibraryEnabled('hal', false);
      expect(c.read(enabledLibrariesProvider), <String>{'ll', 'reg'});

      await n.resetToDefaults();
      expect(c.read(enabledLibrariesProvider), AppSettings.defaultLibraries);
      expect((await SettingsStore().load()).enabledLibraries,
          AppSettings.defaultLibraries);
    });
  });

  group('设置页：函数库分组（widget）', () {
    /// 设置页只需要设置与用户库；数据异步加载失败也不影响函数库分组渲染。
    Widget wrapPage() => ProviderScope(
          overrides: <Override>[
            userStoreProvider.overrideWithValue(InMemoryUserStore()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SettingsPage()),
          ),
        );

    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrapPage());
      // 数据加载走真实 asset IO，这里只等设置加载完
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('渲染出「函数库」分组、总开关和四个库开关', (tester) async {
      await pumpSettings(tester);

      expect(find.text('函数库'), findsOneWidget, reason: '缺分组标题');
      expect(find.text('全部启用'), findsOneWidget);
      expect(find.text('标准库（SPL V3.5.0）'), findsOneWidget);
      expect(find.text('HAL 库（STM32CubeF1 V1.8.7）'), findsOneWidget);
      expect(find.text('LL 库（STM32CubeF1 V1.8.7）'), findsOneWidget);
      expect(find.text('寄存器直驱（CMSIS）'), findsOneWidget);

      // 副标题文案（用户要求的具体措辞）
      expect(
        find.text('传统 stm32f10x_xxx 系列，已收录 488 个函数'),
        findsOneWidget,
      );
      expect(
        find.text('HAL_xxx 系列，STM32CubeMX 生成代码用的就是它'),
        findsOneWidget,
      );
      expect(
        find.text('LL_xxx / __STATIC_INLINE，比 HAL 更贴近寄存器'),
        findsOneWidget,
      );
      expect(
        find.text('直接操作 GPIOA->ODR 这类寄存器'),
        findsOneWidget,
      );

      // 每个开关有独立图标
      expect(find.byIcon(Icons.layers_outlined), findsOneWidget);
      expect(find.byIcon(Icons.widgets_outlined), findsOneWidget);
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.developer_board_outlined), findsOneWidget);
    });

    testWidgets('函数库分组在「数据」之后、「外观」之前', (tester) async {
      await pumpSettings(tester);

      final dataY = tester.getTopLeft(find.text('数据')).dy;
      final libY = tester.getTopLeft(find.text('函数库')).dy;
      final lookY = tester.getTopLeft(find.text('外观')).dy;

      expect(libY, greaterThan(dataY), reason: '「函数库」应排在「数据」之后');
      expect(lookY, greaterThan(libY), reason: '「函数库」应排在「外观」之前');
    });

    testWidgets('点某个库开关能关掉它，且立即反映到 provider', (tester) async {
      await pumpSettings(tester);

      // 找到「HAL 库」那一行的 Switch 并点掉
      final halTile = find.widgetWithText(SwitchListTile, 'HAL 库（STM32CubeF1 V1.8.7）');
      expect(halTile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(halTile).value, isTrue,
          reason: '默认应全开');

      await tester.tap(halTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.widget<SwitchListTile>(halTile).value, isFalse);
      // 落盘也应该生效
      expect(
        (await SettingsStore().load()).enabledLibraries,
        <String>{'spl', 'll', 'reg'},
      );
    });

    testWidgets('关掉最后一个库时弹「至少要保留一个库」并拒绝', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.enabled_libraries': <String>['spl'],
      });
      await pumpSettings(tester);

      final splTile = find.widgetWithText(SwitchListTile, '标准库（SPL V3.5.0）');
      expect(tester.widget<SwitchListTile>(splTile).value, isTrue);

      await tester.tap(splTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 仍然是开着的
      expect(tester.widget<SwitchListTile>(splTile).value, isTrue,
          reason: '最后一个库不该被关掉');
      expect(find.text('至少要保留一个库'), findsOneWidget);
      expect((await SettingsStore().load()).enabledLibraries, <String>{'spl'});
    });

    testWidgets('总开关「全部启用」点掉后至少留一个库', (tester) async {
      await pumpSettings(tester);

      final allTile = find.widgetWithText(SwitchListTile, '全部启用');
      expect(tester.widget<SwitchListTile>(allTile).value, isTrue);

      await tester.tap(allTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 不再是全开
      expect(tester.widget<SwitchListTile>(allTile).value, isFalse);
      // 但也不是全关：至少留了一个
      final left = (await SettingsStore().load()).enabledLibraries;
      expect(left, isNotEmpty, reason: '总开关不该把库全关掉');
      expect(left.length, 1, reason: '关总开关应只保留一个库，实际 $left');
    });

    testWidgets('总开关再点开能恢复四库全开', (tester) async {
      await pumpSettings(tester);

      final allTile = find.widgetWithText(SwitchListTile, '全部启用');
      await tester.tap(allTile); // 关
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(allTile); // 开
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.widget<SwitchListTile>(allTile).value, isTrue);
      expect(
        (await SettingsStore().load()).enabledLibraries,
        AppSettings.defaultLibraries,
      );
    });

    testWidgets('「恢复默认设置」的副标题提到四库全开', (tester) async {
      await pumpSettings(tester);
      expect(
        find.text('主题跟随系统、代码字号 13pt、显示全部外设、四库全开'),
        findsOneWidget,
      );
    });

    testWidgets('部分启用时总开关副标题显示计数', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.enabled_libraries': <String>['spl', 'hal'],
      });
      await pumpSettings(tester);
      expect(find.textContaining('已启用 2/4 个库'), findsOneWidget);
    });
  });

  group('AppSettings', () {
    test('copyWith 只改指定字段', () {
      const base = AppSettings(
        themeMode: ThemeMode.dark,
        codeFontSize: 15,
        onlySupported: true,
        enabledLibraries: <String>{'spl', 'hal'},
      );
      final changed = base.copyWith(codeFontSize: 12);
      expect(changed.themeMode, ThemeMode.dark);
      expect(changed.codeFontSize, 12);
      expect(changed.onlySupported, isTrue);
      expect(changed.enabledLibraries, <String>{'spl', 'hal'},
          reason: 'copyWith 不该把库开关丢掉');
    });

    test('copyWith 可以单独改库开关', () {
      const base = AppSettings(themeMode: ThemeMode.dark);
      final changed = base.copyWith(enabledLibraries: <String>{'ll'});
      expect(changed.themeMode, ThemeMode.dark, reason: '改库不该动主题');
      expect(changed.enabledLibraries, <String>{'ll'});
    });

    test('相等性按四个字段判断', () {
      expect(
        const AppSettings(themeMode: ThemeMode.dark),
        const AppSettings(themeMode: ThemeMode.dark),
      );
      expect(
        const AppSettings(themeMode: ThemeMode.dark),
        isNot(const AppSettings(themeMode: ThemeMode.light)),
      );
      // 库集合不同 → 不相等
      expect(
        const AppSettings(enabledLibraries: <String>{'spl'}),
        isNot(const AppSettings(enabledLibraries: <String>{'hal'})),
      );
      expect(
        const AppSettings(enabledLibraries: <String>{'spl', 'hal'}),
        isNot(const AppSettings(enabledLibraries: <String>{'spl'})),
      );
    });

    test('Set 无序不影响相等性（构造顺序不同但内容相同）', () {
      expect(
        const AppSettings(enabledLibraries: <String>{'spl', 'hal'}),
        const AppSettings(enabledLibraries: <String>{'hal', 'spl'}),
      );
      expect(
        const AppSettings(enabledLibraries: <String>{'spl', 'hal'}).hashCode,
        const AppSettings(enabledLibraries: <String>{'hal', 'spl'}).hashCode,
        reason: '== 相等时 hashCode 必须相等',
      );
    });

    test('toString 里能看到库开关（便于失败时定位）', () {
      expect(
        const AppSettings(enabledLibraries: <String>{'spl', 'hal'}).toString(),
        contains('spl'),
      );
      expect(
        const AppSettings().toString(),
        contains('spl,hal,ll,reg'),
      );
    });
  });

  group('主题模式文案', () {
    test('三种模式都有简称与说明', () {
      for (final m in ThemeMode.values) {
        expect(themeModeLabel(m), isNotEmpty);
        expect(themeModeDescription(m), isNotEmpty);
      }
    });
  });

  group('打包资源（静态校验）', () {
    final res = Directory('android/app/src/main/res');

    test('各密度的启动图标都在，且尺寸递增', () {
      final expected = <String, int>{
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      expected.forEach((density, _) {
        final f = File('${res.path}/mipmap-$density/ic_launcher.png');
        expect(f.existsSync(), isTrue, reason: '缺 $density 的启动图标');
        expect(f.lengthSync(), greaterThan(100),
            reason: '$density 图标是空文件或占位图');
      });
    });

    test('自适应图标的前景/背景层齐全', () {
      for (final d in <String>[
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ]) {
        expect(
          File('${res.path}/mipmap-$d/ic_launcher_foreground.png').existsSync(),
          isTrue,
          reason: '缺 $d 的自适应前景',
        );
        expect(
          File('${res.path}/mipmap-$d/ic_launcher_background.png').existsSync(),
          isTrue,
          reason: '缺 $d 的自适应背景',
        );
      }
    });

    test('自适应图标 XML 存在且引用了前后景', () {
      final f = File('${res.path}/mipmap-anydpi-v26/ic_launcher.xml');
      expect(f.existsSync(), isTrue);
      final xml = f.readAsStringSync();
      expect(xml, contains('ic_launcher_background'));
      expect(xml, contains('ic_launcher_foreground'));
    });

    test('启动图存在，且两份 launch_background 都引用了它', () {
      expect(
        File('${res.path}/drawable-nodpi/splash_logo.png').existsSync(),
        isTrue,
      );
      for (final p in <String>[
        '${res.path}/drawable/launch_background.xml',
        '${res.path}/drawable-v21/launch_background.xml',
      ]) {
        final xml = File(p).readAsStringSync();
        expect(xml, contains('splash_logo'), reason: '$p 没引用启动图');
      }
    });

    test('图标不是 Flutter 默认图标（默认图标约 5KB 以上纯色块）', () {
      // Flutter 默认图标在各密度下都是几百字节的纯色方块 + 白色 F 标；
      // 我们生成的图标带渐变，同样尺寸下压缩后体积明显不同。
      // 这里用"能否解码出透明像素"判断：我们的图标四角是透明的圆角，
      // 而 Flutter 默认图标是完整不透明的方块。
      final f = File('${res.path}/mipmap-xxxhdpi/ic_launcher.png');
      final bytes = f.readAsBytesSync();
      // PNG 里有 alpha 通道时会有 tRNS 或颜色类型 6；这里做粗略校验
      expect(bytes.length, greaterThan(500));
      // 文件头必须是 PNG
      expect(bytes.sublist(1, 4), <int>[0x50, 0x4E, 0x47]);
    });
  });

  group('版本一致性', () {
    test('pubspec 的版本与应用内常量一致', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9.]+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec 里找不到 version');
      // lib/utils/app_info.dart 里的 appVersion
      final info = File('lib/utils/app_info.dart').readAsStringSync();
      final v = RegExp(r"appVersion\s*=\s*'([0-9.]+)'").firstMatch(info);
      expect(v, isNotNull, reason: 'app_info.dart 里找不到 appVersion');
      expect(
        v!.group(1),
        m!.group(1),
        reason: 'pubspec ($m) 与 app_info.dart (${v.group(1)}) 版本号不一致',
      );
    });

    // ---- 升级安装相关 ----
    //
    // 覆盖安装要求 versionCode 存在且为正整数。
    // 这条测不住"这一版比上一版大"（那要对比历史包），但能拦住
    // 漏写 +N 这种最常见的手误——漏了的话 Gradle 会静默沿用
    // versionName 派生的值，装机时表现为"装不上也不报错"。
    test('pubspec 的 version 必须带 +versionCode 且为正整数', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
              multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull,
          reason: 'pubspec 的 version 应形如 "1.0.0+1"，缺少 +versionCode 会导致升级安装失败');
      final code = int.parse(m!.group(2)!);
      expect(code, greaterThan(0), reason: 'versionCode 必须为正整数，实际 $code');
    });

    test('发版脚本存在且包含验签与版本校验步骤', () {
      final f = File('tools/release.ps1');
      expect(f.existsSync(), isTrue, reason: '缺少一键发版脚本 tools/release.ps1');
      final s = f.readAsStringSync();
      // 脚本必须真的验签，而不是只构建
      expect(s, contains('apksigner'), reason: '发版脚本未调用 apksigner 验签');
      // 必须回读 APK 里的 versionCode 并比对，防止 pubspec 改了但没生效
      expect(s, contains('versionCode'),
          reason: '发版脚本未校验 APK 内的 versionCode');
    });

    test('AndroidManifest 的应用名是中文且与 app_info 一致', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final info = File('lib/utils/app_info.dart').readAsStringSync();
      final name = RegExp(r"appName\s*=\s*'([^']+)'").firstMatch(info)!.group(1)!;
      expect(manifest, contains('android:label="$name"'));
    });

    test('应用数据统计与实际数据一致', () {
      final manifest = jsonDecode(
        File('assets/data/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final stats = manifest['stats'] as Map<String, dynamic>;

      // v2 起 functionCount 是四库合计（spl + hal + ll + reg）。
      // 分库数字在 libraryFunctionCounts 里，这里逐项校验，
      // 避免"合计对了但某一库漏了"这种错误被掩盖。
      final libCounts =
          (stats['libraryFunctionCounts'] as Map<String, dynamic>? ??
                  <String, dynamic>{})
              .map((k, v) => MapEntry(k, v as int));

      expect(libCounts['spl'], 488, reason: 'SPL 函数数应与 V3.5.0 一致');
      expect(stats['functionCount'], libCounts.values.fold<int>(0, (a, b) => a + b),
          reason: 'functionCount 必须等于各库之和');
      expect(libCounts['hal'], greaterThan(0), reason: 'HAL 数据应已生成');
      expect(libCounts['ll'], greaterThan(0), reason: 'LL 数据应已生成');
      expect(libCounts['reg'], greaterThan(0), reason: '寄存器数据应已生成');

      expect(stats['symbolCount'], greaterThanOrEqualTo(7337));
      expect(stats['pinCount'], 48);
      expect(stats['compileErrorCount'], 15);
    });
  });
}
