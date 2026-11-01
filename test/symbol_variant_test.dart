import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/data/asset_repository.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';

/// v2.0.1 专项回归：HAL 与 SPL 同名但定义不同的类型。
///
/// ## 背景
///
/// v2.0.0 里 `GPIO_InitTypeDef` / `ADC_InitTypeDef` / `USART_InitTypeDef` 等
/// **12 个核心结构体**在 HAL 与 SPL 中各有一份、成员布局完全不同：
///
/// ```
/// HAL:  Pin / Mode / Pull / Speed
/// SPL:  GPIO_Pin / GPIO_Speed / GPIO_Mode
/// ```
///
/// 生成器当时为了「全局 id 唯一」，把 HAL 那份整个丢弃，只留 SPL 版。
/// 后果：用户查 `HAL_GPIO_Init` → 点参数 `GPIO_InitTypeDef` →
/// 看到的是 **SPL 的字段名**，照着写 HAL 代码编译不过。
///
/// 修法：数据层用「库限定 id」`GPIO_InitTypeDef@hal` 保存 HAL 版，
/// 两份共存；跳转按当前阅读的库选对应那份。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('同名不同类型的库限定 id', () {
    late AssetRepository repo;
    late SplData data;

    setUpAll(() async {
      repo = AssetRepository();
      // 直接用 loadCore：v2.0.3 起它已经把 HAL/LL 符号一并加载，
      // 这里不再手动 withHalSymbols，否则测的就不是运行时真实路径了。
      data = await repo.loadCore();
    });

    test('HAL 的 GPIO_InitTypeDef 被保留，且成员是 HAL 那套', () {
      final hal = data.symbolOf('GPIO_InitTypeDef', preferredLib: LibraryKind.hal);
      expect(hal, isNotNull, reason: 'HAL 版 GPIO_InitTypeDef 缺失');
      expect(hal!.id, 'GPIO_InitTypeDef@hal');
      expect(hal.library, LibraryKind.hal);
      expect(hal.name, 'GPIO_InitTypeDef', reason: 'name 应保持源码原名');

      final members = hal.members.map((m) => m.name).toList();
      expect(members, containsAll(<String>['Pin', 'Mode', 'Pull', 'Speed']));
      expect(
        members.any((m) => m.startsWith('GPIO_')),
        isFalse,
        reason: 'HAL 版不该出现 SPL 的 GPIO_Pin/GPIO_Mode 字段',
      );
    });

    test('SPL 的 GPIO_InitTypeDef 仍在，且成员是 SPL 那套', () {
      final spl = data.symbolOf('GPIO_InitTypeDef', preferredLib: LibraryKind.spl);
      expect(spl, isNotNull);
      expect(spl!.library, LibraryKind.spl);
      final members = spl.members.map((m) => m.name).toList();
      expect(members, containsAll(<String>['GPIO_Pin', 'GPIO_Speed', 'GPIO_Mode']));
    });

    test('不指定库时退化为老行为：给 SPL 那份', () {
      final plain = data.symbolOf('GPIO_InitTypeDef');
      expect(plain, isNotNull);
      expect(plain!.library, LibraryKind.spl);
      expect(plain.id, 'GPIO_InitTypeDef');
    });

    test('9 个同名结构体在 SPL 与 HAL 各有一份，且 id 可区分', () {
      // 只列**两个库各自重新定义了一份**的类型。以下两个不在列表里：
      //   * `SD_InitTypeDef` —— HAL 里只是
      //       #define SD_InitTypeDef  SDIO_InitTypeDef
      //     一个别名，没有独立定义；
      //   * `SDIO_InitTypeDef` —— 在 HAL 包里由 LL 层
      //     （stm32f1xx_ll_sdmmc.h）定义，归属 ll 库而非 hal，下面单独校验。
      const names = <String>[
        'ADC_InitTypeDef',
        'CAN_InitTypeDef',
        'CEC_InitTypeDef',
        'DMA_InitTypeDef',
        'GPIO_InitTypeDef',
        'I2C_InitTypeDef',
        'I2S_InitTypeDef',
        'SPI_InitTypeDef',
        'USART_InitTypeDef',
      ];
      final missing = <String>[];
      for (final n in names) {
        final variants = data.symbolVariantsOf(n);
        final libs = variants.map((v) => v.library).toSet();
        if (!libs.contains(LibraryKind.spl)) missing.add('$n@SPL');
        if (!libs.contains(LibraryKind.hal)) missing.add('$n@HAL');
        // 两份必须真的能区分（id 不同），否则说明拿到的是同一份
        if (libs.contains(LibraryKind.spl) && libs.contains(LibraryKind.hal)) {
          final s = variants.firstWhere((v) => v.library == LibraryKind.spl);
          final h = variants.firstWhere((v) => v.library == LibraryKind.hal);
          if (s.id == h.id) missing.add('$n: SPL 与 HAL 的 id 相同（应不同）');
        }
      }
      expect(missing, isEmpty, reason: '这些版本缺失：$missing');
    });

    test('SDIO_InitTypeDef：SPL 与 LL 各有一份（LL 在 ll_sdmmc.h 里）', () {
      final variants = data.symbolVariantsOf('SDIO_InitTypeDef');
      final libs = variants.map((v) => v.library).toSet();
      expect(libs, contains(LibraryKind.spl));
      expect(libs, contains(LibraryKind.ll), reason: 'HAL 包把它定义在 LL 层');
    });

    test('symbolVariantsOf 按 spl→hal 顺序返回，供 UI 稳定呈现', () {
      final v = data.symbolVariantsOf('GPIO_InitTypeDef');
      expect(v.length, greaterThanOrEqualTo(2));
      expect(v.first.library, LibraryKind.spl);
      for (var i = 1; i < v.length; i++) {
        expect(
          v[i].library.orderIndex,
          greaterThanOrEqualTo(v[i - 1].library.orderIndex),
        );
      }
    });

    test('库限定 id 能被 isKnownSymbol 与 symbol() 直接命中', () {
      expect(data.isKnownSymbol('GPIO_InitTypeDef'), isTrue);
      expect(data.isKnownSymbol('GPIO_InitTypeDef@hal'), isTrue);
      expect(data.symbol('GPIO_InitTypeDef@hal'), isNotNull);
    });

    test('HAL 函数引用的类型名都能解析出符号（无死链）', () async {
      // 抽几个高频 HAL 函数，逐个数它们 params 里的类型名能否解析
      final bundle = await repo.loadFunctionsOf('GPIO', LibraryKind.hal);
      expect(bundle.functions, isNotEmpty);
      final init = bundle.functions.firstWhere((f) => f.id == 'HAL_GPIO_Init');

      final unresolved = <String>[];
      for (final p in init.params) {
        final typeBase = p.type
            .replaceAll('*', '')
            .replaceAll('const', '')
            .trim();
        if (typeBase.isEmpty) continue;
        if (typeBase == 'void') continue;
        if (data.symbolOf(typeBase, preferredLib: LibraryKind.hal) == null) {
          unresolved.add(typeBase);
        }
      }
      expect(unresolved, isEmpty, reason: '这些参数类型解析不到符号：$unresolved');
    });
  });
}
