import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 资源打包回归测试（v2.0.1 新增）。
///
/// ## 为什么需要这个文件
///
/// v2.0.0 装机后 HAL / LL / 寄存器三个库**每个分组都是 0 个函数**。
/// 根因不是解析错、也不是 UI 错，而是 `pubspec.yaml` 里只声明了
/// `assets/data/functions/`——Flutter 的 assets 目录声明**不递归子目录**，
/// 于是 `functions/hal/`、`functions/ll/`、`functions/reg/` 根本没进 APK。
///
/// 这个 bug 之所以能一路过掉 473 个测试，是因为所有数据层测试都用
/// `File('assets/data/...')` 直接读**文件系统**，绕过了资源打包这一层；
/// 而 APK 里根本没有这些文件，运行时 `rootBundle.loadString` 直接抛异常，
/// 被 `loadFunctionsOf` 的容错逻辑吞成了「空 bundle」——界面上就是一片 0。
///
/// 所以这里的断言刻意**不读文件系统**，而是解析 `pubspec.yaml` 的 assets 声明，
/// 逐条比对「数据目录下真实存在的文件」是否都被覆盖。
/// 它能在 `flutter test` 阶段就拦住同类问题，不需要装机。
void main() {
  /// 从 pubspec.yaml 里解析出 assets 声明列表。
  ///
  /// 不引入 yaml 依赖：只认 `flutter:` 块下 `assets:` 后面的 `- xxx` 行，
  /// 对本项目的 pubspec 结构足够，且改动 pubspec 格式时会立刻红灯提醒。
  List<String> declaredAssets() {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final result = <String>[];
    var inAssets = false;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trimLeft().startsWith('- ')) {
        if (inAssets) {
          var v = line.trimLeft().substring(2).trim();
          // 去掉行尾注释
          final hash = v.indexOf(' #');
          if (hash >= 0) v = v.substring(0, hash).trim();
          if (v.isNotEmpty) result.add(v);
        }
        continue;
      }
      final t = line.trimLeft();
      if (t.startsWith('#')) continue; // 整行注释
      if (t == 'assets:') {
        inAssets = true;
        continue;
      }
      // 其它同级键：结束 assets 块
      if (inAssets && line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
        inAssets = false;
      }
    }
    return result;
  }

  group('资源打包：pubspec 声明必须覆盖所有数据文件', () {
    test('functions/hal、ll、reg 三个子目录必须被显式声明', () {
      final assets = declaredAssets();
      // 这三条是硬要求：少一条，对应库在 APK 里就是空的
      expect(
        assets,
        contains('assets/data/functions/hal/'),
        reason: '缺少 HAL 库目录声明，装机后 HAL 分组全是 0 个函数',
      );
      expect(
        assets,
        contains('assets/data/functions/ll/'),
        reason: '缺少 LL 库目录声明，装机后 LL 分组全是 0 个函数',
      );
      expect(
        assets,
        contains('assets/data/functions/reg/'),
        reason: '缺少寄存器目录声明，装机后寄存器分组全是 0 个函数',
      );
    });

    test('数据目录里每个含 JSON 的子目录都在 pubspec 中声明了', () {
      final assets = declaredAssets();
      final declared = assets.map((a) {
        var s = a.replaceAll(r'\', '/');
        if (!s.endsWith('/')) s = '$s/';
        return s;
      }).toSet();

      // 找出 assets/data 下所有「直接包含 .json 文件」的目录
      final dataRoot = Directory('assets/data');
      expect(dataRoot.existsSync(), isTrue, reason: 'assets/data 不存在');

      final dirsWithJson = <String>{};
      for (final e in dataRoot.listSync(recursive: true, followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.json')) {
          final dir = e.parent.path.replaceAll(r'\', '/');
          dirsWithJson.add('$dir/');
        }
      }
      expect(dirsWithJson, isNotEmpty);

      final missing = <String>[];
      for (final dir in dirsWithJson) {
        if (!declared.contains(dir)) missing.add(dir);
      }
      expect(
        missing,
        isEmpty,
        reason: '这些目录含 JSON 但没在 pubspec.yaml 的 assets 里声明，'
            '打出的 APK 会缺数据：$missing',
      );
    });

    test('每个被声明的 assets 目录都真实存在', () {
      final assets = declaredAssets();
      final missing = <String>[];
      for (final a in assets) {
        if (!Directory(a).existsSync() && !File(a).existsSync()) {
          missing.add(a);
        }
      }
      expect(missing, isEmpty, reason: 'pubspec 声明了不存在的路径：$missing');
    });
  });

  group('资源打包：三个新库的文件数量与实际一致', () {
    test('hal / ll / reg 目录非空，且与 manifest 统计相符', () {
      final manifest = jsonDecode(
        File('assets/data/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final counts =
          (manifest['stats'] as Map<String, dynamic>)['libraryFunctionCounts']
              as Map<String, dynamic>;

      for (final lib in <String>['hal', 'll', 'reg']) {
        final dir = Directory('assets/data/functions/$lib');
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList();
        expect(files, isNotEmpty, reason: '$lib 目录下没有 JSON 文件');

        // 目录内函数总数必须等于 manifest 声明的数量
        var total = 0;
        for (final f in files) {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          total += (j['functions'] as List).length;
        }
        expect(
          total,
          counts[lib],
          reason: '$lib 目录实际 $total 个函数，manifest 声明 ${counts[lib]} 个',
        );
        expect(total, greaterThan(0), reason: '$lib 函数数为 0，装机后会是空列表');
      }
    });

    test('每个外设的 libraries 声明与对应函数文件实际内容一致', () {
      final peripherals = jsonDecode(
        File('assets/data/peripherals.json').readAsStringSync(),
      )['peripherals'] as List;

      final problems = <String>[];
      for (final raw in peripherals) {
        final p = raw as Map<String, dynamic>;
        final id = p['id'] as String;
        final libs = p['libraries'] as Map<String, dynamic>? ?? const {};
        for (final lib in <String>['hal', 'll', 'reg']) {
          final info = libs[lib] as Map<String, dynamic>?;
          final declaredCount = (info?['functionCount'] as int?) ?? 0;
          if (declaredCount == 0) continue;

          final file = File('assets/data/functions/$lib/$id.json');
          if (!file.existsSync()) {
            problems.add('$id@$lib 声明 $declaredCount 个函数，但文件不存在');
            continue;
          }
          final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final actual = (j['functions'] as List).length;
          if (actual != declaredCount) {
            problems.add('$id@$lib 声明 $declaredCount，实际 $actual');
          }
          // 文件里的 library 字段必须与所在目录一致
          if (j['library'] != lib) {
            problems.add('$id@$lib 文件内 library=${j['library']}，与目录不符');
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('每个 section 引用的函数 id 都能在对应库文件里找到', () {
      final peripherals = jsonDecode(
        File('assets/data/peripherals.json').readAsStringSync(),
      )['peripherals'] as List;

      // 预先读好各库的函数 id 集合
      final idCache = <String, Set<String>>{};
      Set<String> idsOf(String lib, String peripheralId) {
        final key = '$lib:$peripheralId';
        return idCache.putIfAbsent(key, () {
          final base = lib == 'spl' ? 'assets/data/functions' : 'assets/data/functions/$lib';
          final file = File('$base/$peripheralId.json');
          if (!file.existsSync()) return <String>{};
          final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          return {
            for (final f in j['functions'] as List)
              (f as Map<String, dynamic>)['id'] as String,
          };
        });
      }

      final problems = <String>[];
      for (final raw in peripherals) {
        final p = raw as Map<String, dynamic>;
        final id = p['id'] as String;
        for (final s in p['sections'] as List) {
          final sec = s as Map<String, dynamic>;
          final lib = (sec['library'] as String?) ?? 'spl';
          final ids = idsOf(lib, id);
          for (final fid in (sec['functionIds'] as List).cast<String>()) {
            if (!ids.contains(fid)) problems.add('$id@$lib 的 section 引用了不存在的 $fid');
          }
        }
      }
      expect(problems, isEmpty, reason: problems.take(20).join('\n'));
    });
  });
}
