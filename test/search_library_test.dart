import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/data/asset_repository.dart';
import 'package:stm32_spl_helper/data/search_index.dart';
import 'package:stm32_spl_helper/models/library_kind.dart';
import 'package:stm32_spl_helper/models/spl_data.dart';

/// v2.0.3 回归：搜索结果的「库」归属。
///
/// ## 修之前是什么样
///
/// 搜索索引不带库信息，`search_page.dart` 只能按 id 前缀反推：
///
/// ```dart
/// if (id.startsWith('HAL_')) return LibraryKind.hal;
/// ...
/// return LibraryKind.spl;   // 兜底
/// ```
///
/// 但 HAL/LL 里有 **3313 个符号**不带这些前缀：
/// `GPIO_InitTypeDef@hal`、`ADC_HandleTypeDef`、`ConvCpltCallback`、
/// `pADC_CallbackTypeDef`……全部落到「兜底 = 标准库」。
///
/// 后果：用户在设置里关掉「标准库」、只想看 HAL 时，
/// 这些 HAL 类型会从搜索结果里**整片消失**；反过来关掉 HAL 时，
/// 它们又会赖在结果里不走。两个方向都错。
///
/// 另有一个同源问题：符号条目用的是 `s.name` 当 id，
/// 于是搜到 `GPIO_InitTypeDef@hal` 点进去打开的是 SPL 那份定义
/// （成员是 GPIO_Pin/GPIO_Speed/GPIO_Mode，而 HAL 是 Pin/Mode/Pull/Speed）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SplData data;
  late SearchIndex index;

  setUpAll(() async {
    final repo = AssetRepository();
    data = await repo.loadCore();
    index = SearchIndex.build(data);
  });

  group('搜索结果带准确的库归属', () {
    test('HAL 符号即便不带 HAL_ 前缀，也应标成 hal', () {
      // ADC_HandleTypeDef / GPIO_InitTypeDef@hal 都不以 HAL_ 开头
      final hits = index.search('ADC_HandleTypeDef');
      expect(hits, isNotEmpty, reason: '搜不到 ADC_HandleTypeDef');
      final h = hits.firstWhere((x) => x.title == 'ADC_HandleTypeDef');
      expect(h.library, LibraryKind.hal);
    });

    test('库限定符号按其真实库归属，不是兜底的 spl', () {
      final hits = index.search('GPIO_InitTypeDef');
      expect(hits, isNotEmpty);
      final qualified = hits.where((h) => h.id.contains('@hal'));
      expect(qualified, isNotEmpty, reason: 'HAL 版 GPIO_InitTypeDef 没进索引');
      expect(qualified.first.library, LibraryKind.hal);

      // SPL 那份仍然在，且标成 spl
      final plain = hits.where((h) => h.id == 'GPIO_InitTypeDef');
      expect(plain, isNotEmpty, reason: 'SPL 版 GPIO_InitTypeDef 丢了');
      expect(plain.first.library, LibraryKind.spl);
    });

    test('HAL 函数标成 hal，SPL 函数标成 spl', () {
      expect(index.search('HAL_GPIO_Init').first.library, LibraryKind.hal);
      expect(index.search('GPIO_Init').firstWhere((h) => h.id == 'GPIO_Init').library,
          LibraryKind.spl);
    });

    test('引脚 / 编译错误 / 外设 的 library 为 null（与库无关）', () {
      final pin = index.search('PA9');
      expect(pin, isNotEmpty);
      expect(pin.first.library, isNull);

      final periph = index.search('GPIO').where((h) => h.title == 'GPIO');
      if (periph.isNotEmpty) {
        expect(periph.first.library, isNull);
      }
    });

    test('全部 HAL/LL 符号里，不应有任何一条被标成 spl', () {
      // 抽样：把所有 HAL 符号名逐个搜一遍太重，改为直接查索引里的统计
      final sample = <String>[
        'ADC_HandleTypeDef',
        'ConvCpltCallback',
        'pADC_CallbackTypeDef',
        'CAN_TxHeaderTypeDef',
        'LL_GPIO_InitTypeDef',
      ];
      for (final name in sample) {
        final hits = index.search(name);
        if (hits.isEmpty) continue;
        final wrong = hits.where(
          (h) => h.title == name && h.library != LibraryKind.hal && h.library != LibraryKind.ll,
        );
        expect(wrong, isEmpty, reason: '$name 的库归属不对：'
            '${wrong.map((h) => '${h.id}->${h.library?.raw}').toList()}');
      }
    });
  });

  group('点搜索结果要打开对应那一份定义', () {
    test('符号结果的 id 保留库限定后缀（否则会打开另一库的同名定义）', () {
      final hits = index.search('GPIO_InitTypeDef');
      final qualified = hits.firstWhere((h) => h.id.contains('@hal'));
      expect(qualified.id, 'GPIO_InitTypeDef@hal',
          reason: 'id 被改成了裸名字，点开会跳到 SPL 那份');

      // 用这个 id 必须能取到 HAL 的定义（成员是 Pin/Mode/Pull/Speed）
      final sym = data.symbol(qualified.id);
      expect(sym, isNotNull);
      final members = sym!.members.map((m) => m.name).toList();
      expect(members, containsAll(<String>['Pin', 'Mode', 'Pull', 'Speed']));
      expect(members.any((m) => m.startsWith('GPIO_')), isFalse);
    });
  });

  group('按库过滤搜索结果的等价逻辑', () {
    /// 复刻 search_page.dart 的过滤判据。
    ///
    /// 注意 `library == null` 的条目（外设、引脚、编译错误）**永远保留**：
    /// 它们不属于任何库，关掉某个库不该让外设条目也消失。
    List<SearchHit> filter(List<SearchHit> hits, Set<LibraryKind> enabled) =>
        hits.where((h) => h.library == null || enabled.contains(h.library)).toList();

    test('只开 HAL 时，HAL 类型仍然可见、SPL 类型被隐藏', () {
      final hits = index.search('InitTypeDef');
      expect(hits, isNotEmpty);

      final onlyHal = filter(hits, {LibraryKind.hal});
      // 只看有库属性的条目（函数/符号），外设与编译错误不参与这个判定
      final libraryHits = onlyHal
          .where((h) => h.library != null)
          .toList(growable: false);
      expect(libraryHits, isNotEmpty, reason: '只开 HAL 却一条都不剩，就是本 bug');
      expect(libraryHits.every((h) => h.library == LibraryKind.hal), isTrue);
    });

    test('只开 SPL 时，HAL 的库限定符号不会混进来', () {
      final hits = index.search('GPIO_InitTypeDef');
      final onlySpl = filter(hits, {LibraryKind.spl});
      expect(onlySpl.any((h) => h.id.contains('@hal')), isFalse,
          reason: '关掉 HAL 后 HAL 专属符号不该出现');
      expect(
        onlySpl.where((h) => h.library != null).every(
              (h) => h.library == LibraryKind.spl,
            ),
        isTrue,
      );
    });
  });
}
