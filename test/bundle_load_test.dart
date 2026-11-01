// 真实 AssetBundle 端到端测试（v2.0.1 新增）。
//
// 与其它数据层测试的区别：本文件**不读文件系统**，而是走 Flutter 的
// `rootBundle`（测试环境里由 FLUTTER_TEST 资源包提供），也就是与 APK 内
// 运行时完全相同的加载路径。
//
// v2.0.0 的 HAL 全 0 bug 之所以漏掉，就是因为所有测试都绕过这一层。
import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/data/asset_repository.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rootBundle 真实加载：四库数据都能读到', () {
    late AssetRepository repo;
    late SplData data;

    setUpAll(() async {
      repo = AssetRepository();
      data = await repo.loadCore();
    });

    test('核心数据加载成功，manifest 为 v2 且四库统计齐全', () {
      expect(data.manifest.schemaVersion, 2);
      final counts = data.manifest.stats.libraryFunctionCounts;
      expect(counts['spl'], 488);
      expect(counts['hal'], greaterThan(0), reason: 'HAL 函数数不能为 0');
      expect(counts['ll'], greaterThan(0), reason: 'LL 函数数不能为 0');
      expect(counts['reg'], greaterThan(0), reason: '寄存器数不能为 0');
    });

    test('每个声明了 HAL 函数的外设，都能通过 rootBundle 读到函数', () async {
      final problems = <String>[];
      for (final p in data.peripherals) {
        for (final lib in LibraryKind.ordered) {
          final declared = p.functionCountOf(lib);
          if (declared == 0) continue;
          final bundle = await repo.loadFunctionsOf(p.id, lib);
          if (bundle.functions.isEmpty) {
            problems.add('${p.id}@${lib.raw} 声明 $declared 个，实际读到 0 个');
          } else if (bundle.functions.length != declared) {
            problems.add(
              '${p.id}@${lib.raw} 声明 $declared 个，实际读到 ${bundle.functions.length} 个',
            );
          }
        }
      }
      expect(problems, isEmpty, reason: problems.take(20).join('\n'));
    });

    test('TIM 的 HAL 库：17 个分组、134 个函数全部可读', () async {
      final bundle = await repo.loadFunctionsOf('TIM', LibraryKind.hal);
      expect(bundle.functions.length, 134);

      final tim = data.peripheral('TIM')!;
      final sections = tim.sectionsOf(LibraryKind.hal);
      expect(sections.length, 17);

      final byId = {for (final f in bundle.functions) f.id: f};
      // 每个分组的每个函数 id 都必须能解析到实体
      final missing = <String>[];
      for (final s in sections) {
        expect(s.functionIds, isNotEmpty, reason: '分组 ${s.id} 是空的');
        for (final fid in s.functionIds) {
          if (!byId.containsKey(fid)) missing.add('${s.id} → $fid');
        }
      }
      expect(missing, isEmpty, reason: '这些分组里的函数读不到：${missing.take(10)}');
    });

    test('GPIO 的 HAL 库：可读且带中文说明', () async {
      final bundle = await repo.loadFunctionsOf('GPIO', LibraryKind.hal);
      expect(bundle.functions, isNotEmpty);
      final init = bundle.functions.firstWhere((f) => f.id == 'HAL_GPIO_Init');
      expect(init.briefZh, isNotEmpty, reason: 'HAL_GPIO_Init 必须有中文简述');
      expect(init.definedIn, 'stm32f1xx_hal_gpio.h');
      expect(init.library, LibraryKind.hal);
      expect(init.params, isNotEmpty);
    });

    test('寄存器库能读到，且带位域与示例', () async {
      final bundle = await repo.loadFunctionsOf('GPIO', LibraryKind.reg);
      expect(bundle.functions, isNotEmpty);
      final crl = bundle.functions.firstWhere((f) => f.name == 'GPIO_CRL');
      expect(crl.prototype, contains('->'));
      expect(crl.params, isNotEmpty);
      expect(crl.exampleCode, isNotEmpty);
    });

    test('symbols_hal.json 能通过 rootBundle 读到', () async {
      final symbols = await repo.loadHalSymbols();
      expect(symbols, isNotEmpty, reason: 'HAL 符号为空，关键词跳转会失效');
      expect(symbols.any((s) => s.name == 'GPIO_InitTypeDef'), isTrue);
    });

    test('loadCore 必须把 HAL/LL 符号一并带上（v2.0.3 回归）', () {
      // 早先 loadHalSymbols() 写好了但全项目无人调用，
      // 运行时 data.halSymbols 恒为空 → 搜不到 ADC_HandleTypeDef、
      // HAL 函数页里的类型名点不动、GPIO_InitTypeDef 永远只给 SPL 那份。
      // 这条测试锁住「启动即加载」这个契约。
      expect(
        data.halSymbols,
        isNotEmpty,
        reason: 'loadCore 没带 HAL 符号，HAL 相关功能会静默失效',
      );
      expect(
        data.halSymbols.any((s) => s.name == 'GPIO_InitTypeDef'),
        isTrue,
      );
      // 库限定 id 也必须在索引里
      expect(data.symbol('GPIO_InitTypeDef@hal'), isNotNull);
      // 同名两个版本都能解析到
      expect(data.symbolVariantsOf('GPIO_InitTypeDef').length,
          greaterThanOrEqualTo(2));
    });

    test('HAL 函数引用的类型名能在符号表里解析（关键词跳转依赖它）', () async {
      final bundle = await repo.loadFunctionsOf('GPIO', LibraryKind.hal);
      final init = bundle.functions.firstWhere((f) => f.id == 'HAL_GPIO_Init');
      final unresolved = <String>[];
      for (final p in init.params) {
        final t = p.type.replaceAll('*', '').replaceAll('const', '').trim();
        if (t.isEmpty || t == 'void') continue;
        if (data.symbolOf(t, preferredLib: LibraryKind.hal) == null) {
          unresolved.add(t);
        }
      }
      expect(unresolved, isEmpty, reason: '这些参数类型解析不到：$unresolved');
    });

    test('loadFunctionsOf 返回值不是"静默空包"：声明数与实际数必须一致', () async {
      // 这条专门防 v2.0.0 那种「文件没打进包 → 容错吞成空包 → 界面全是 0」
      for (final p in data.peripherals) {
        final halCount = p.functionCountOf(LibraryKind.hal);
        final bundle = await repo.loadFunctionsOf(p.id, LibraryKind.hal);
        expect(
          bundle.functions.length,
          halCount,
          reason: '${p.id} HAL 声明 $halCount 个，实际读到 ${bundle.functions.length} 个',
        );
      }
    });
  });
}
