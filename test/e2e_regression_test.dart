// v2.0.1 端到端验收：模拟用户在真机上的操作路径。
//
// 这些用例对应 v2.0.0 的两个真实故障：
//   1. **HAL 全 0** —— assets 没打进 APK，`loadFunctionsOf` 容错成空 bundle，
//      界面上一堆 "0"。根因在资源打包，不在业务代码。
//   2. **HAL 类型看到 SPL 的定义** —— 同名结构体被错误去重。
//
// 本文件走 `rootBundle`（与 APK 运行时同一条路径），并把「外设页 → 分组 →
// 函数」这一整条链路完整跑一遍，确保不会再出现"分组在、函数 0 个"。
import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/data/asset_repository.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AssetRepository repo;
  late SplData data;

  setUpAll(() async {
    repo = AssetRepository();
    data = (await repo.loadCore())
        .withHalSymbols(await repo.loadHalSymbols());
  });

  group('用户截图场景回归：外设页每个分组都必须有函数', () {
    test('全部外设 × 全部库：section 里的函数全部能加载出来', () async {
      final problems = <String>[];

      for (final p in data.peripherals) {
        for (final lib in p.availableLibraries) {
          final bundle = await repo.loadFunctionsOf(p.id, lib);
          final byId = {for (final f in bundle.functions) f.id: f};

          for (final sec in p.sectionsOf(lib)) {
            if (sec.functionIds.isEmpty) {
              problems.add('${p.id}@${lib.raw} 的空分组 ${sec.id}');
              continue;
            }
            // 分组声明了 N 个，就必须真能解析出 N 个
            final resolved =
                sec.functionIds.where((id) => byId.containsKey(id)).length;
            if (resolved == 0) {
              problems.add(
                '${p.id}@${lib.raw}/${sec.id} 声明 ${sec.functionIds.length} 个，'
                '一个都读不到（就是 v2.0.0 的"全是 0"）',
              );
            } else if (resolved != sec.functionIds.length) {
              problems.add(
                '${p.id}@${lib.raw}/${sec.id} 声明 ${sec.functionIds.length}，'
                '只读到 $resolved',
              );
            }
          }
        }
      }
      expect(problems, isEmpty, reason: problems.take(15).join('\n'));
    });

    test('TIM@HAL 的 17 个分组各自都有函数（逐个数）', () async {
      final tim = data.peripheral('TIM')!;
      final sections = tim.sectionsOf(LibraryKind.hal);
      expect(sections.length, 17);

      final bundle = await repo.loadFunctionsOf('TIM', LibraryKind.hal);
      final byId = {for (final f in bundle.functions) f.id: f};

      final empties = <String>[];
      for (final s in sections) {
        final n = s.functionIds.where((id) => byId.containsKey(id)).length;
        if (n == 0) empties.add('${s.title}(${s.id})');
      }
      expect(empties, isEmpty, reason: '这些分组是 0 个函数：$empties');

      // 抽查几个用户最可能点开的分组
      for (final title in <String>['HAL 时基功能', 'HAL PWM 输出功能', 'HAL 回调']) {
        final s = sections.firstWhere((x) => x.title == title);
        expect(
          s.functionIds.where((id) => byId.containsKey(id)).length,
          greaterThan(0),
          reason: '$title 分组读不到函数',
        );
      }
    });

    test('每个库的「声明函数数」与「实际能读到的函数数」一致', () async {
      final problems = <String>[];
      for (final p in data.peripherals) {
        for (final lib in LibraryKind.ordered) {
          final declared = p.functionCountOf(lib);
          if (declared == 0) continue;
          final bundle = await repo.loadFunctionsOf(p.id, lib);
          if (bundle.functions.length != declared) {
            problems.add(
              '${p.id}@${lib.raw} 声明 $declared，读到 ${bundle.functions.length}',
            );
          }
        }
      }
      expect(problems, isEmpty, reason: problems.take(15).join('\n'));
    });

    test('HAL 基础函数可在数据层被检索到（HAL_Init/HAL_Delay 等）', () {
      // v2.0.1 之前，stm32f1xx_hal.h/.c 这个核心模块整个漏收，
      // HAL_Init / HAL_Delay / HAL_GetTick 搜不到。
      const key = <String>[
        'HAL_Init',
        'HAL_DeInit',
        'HAL_Delay',
        'HAL_GetTick',
        'HAL_IncTick',
        'HAL_GetUIDw0',
        'HAL_GPIO_Init',
        'HAL_GPIO_WritePin',
        'HAL_UART_Transmit',
        'HAL_TIM_Base_Start_IT',
      ];
      final missing = key.where((k) => !data.isKnownFunction(k)).toList();
      expect(missing, isEmpty, reason: '这些常用函数检索不到：$missing');
    });

    test('四库函数总数与 manifest 一致，且都大于 0', () async {
      final counts = data.manifest.stats.libraryFunctionCounts;
      expect(counts['spl'], 488);
      for (final lib in <String>['hal', 'll', 'reg']) {
        expect(counts[lib], greaterThan(0), reason: '$lib 数量为 0');
      }
      var total = 0;
      for (final p in data.peripherals) {
        for (final lib in LibraryKind.ordered) {
          total += p.functionCountOf(lib);
        }
      }
      expect(
        total,
        counts.values.fold<int>(0, (a, b) => a + b),
        reason: '外设分项之和与 manifest 总计不符',
      );
    });

    test('中文说明随数据一起打包（HAL 抽查）', () async {
      final bundle = await repo.loadFunctionsOf('CORTEX', LibraryKind.hal);
      final init = bundle.functions.where((f) => f.id == 'HAL_Init').toList();
      expect(init, isNotEmpty, reason: 'HAL_Init 读不到');
      expect(init.first.briefZh, isNotEmpty, reason: 'HAL_Init 缺中文简述');
      expect(init.first.exampleCode, isNotEmpty, reason: 'HAL_Init 缺示例');
    });
  });
}
