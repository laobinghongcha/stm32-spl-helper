import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/note_export.dart';
import '../data/search_history.dart';
import '../data/settings_store.dart';
import '../data/user_database.dart';
import '../providers/app_providers.dart';
import '../providers/user_providers.dart';
import '../utils/app_info.dart';

/// 设置页（阶段 9 完整实现）。
///
/// 需求 5.8：数据版本与来源、深色模式、代码字号、清除记录、
/// 导出笔记、关于页。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(splDataProvider);
    final themeMode = ref.watch(themeModeProvider);
    final codeSize = ref.watch(codeFontSizeProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      children: <Widget>[
        // ---- 数据信息 ----
        _SectionTitle('数据'),
        dataAsync.when(
          loading: () => const ListTile(title: Text('加载中…')),
          error: (e, _) => ListTile(title: Text('数据加载失败：$e')),
          data: (data) {
            final m = data.manifest;
            final s = m.stats;
            return Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('数据版本'),
                  subtitle: Text(
                    '${m.dataVersion} · 结构版本 v${m.schemaVersion}\n'
                    '来源：${m.splVersion}\n'
                    '生成于 ${m.generatedAt}',
                  ),
                  isThreeLine: true,
                ),
                ListTile(
                  leading: const Icon(Icons.numbers),
                  title: const Text('数据统计'),
                  subtitle: Text(
                    '${s.peripheralCount} 个外设 · ${s.functionCount} 个函数 · '
                    '${s.symbolCount} 个符号\n'
                    '${s.pinCount} 个引脚 · ${s.compileErrorCount} 条编译错误',
                  ),
                  isThreeLine: true,
                ),
                ListTile(
                  leading: const Icon(Icons.memory),
                  title: const Text('当前芯片'),
                  subtitle: Text('${data.chip.name}\n${data.chip.summary}'),
                  isThreeLine: true,
                ),
              ],
            );
          },
        ),

        const Divider(),

        // ---- 函数库（用户要求：在设置页自由勾选显示哪些库的函数） ----
        const _SectionTitle('函数库'),
        const _LibrarySection(),

        const Divider(),

        // ---- 外观 ----
        _SectionTitle('外观'),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('深色模式'),
          subtitle: Text(themeModeDescription(themeMode)),
          trailing: DropdownButton<ThemeMode>(
            value: themeMode,
            underline: const SizedBox.shrink(),
            items: const <DropdownMenuItem<ThemeMode>>[
              DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('强制深色')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('强制浅色')),
            ],
            onChanged: (v) {
              if (v != null) {
                ref.read(settingsProvider.notifier).setThemeMode(v);
              }
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('代码字号'),
          subtitle: Slider(
            value: codeSize,
            min: AppSettings.minCodeFontSize,
            max: AppSettings.maxCodeFontSize,
            divisions:
                (AppSettings.maxCodeFontSize - AppSettings.minCodeFontSize)
                    .round(),
            label: codeSize.toStringAsFixed(0),
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setCodeFontSize(v),
          ),
          trailing: Text('${codeSize.toStringAsFixed(0)} pt'),
        ),
        Consumer(
          builder: (context, ref, _) {
            final onlySupported = ref.watch(onlySupportedProvider);
            return SwitchListTile(
              secondary: const Icon(Icons.filter_alt_outlined),
              title: const Text('首页仅显示本型号支持的外设'),
              subtitle: Text(
                onlySupported
                    ? '已隐藏 DAC / FSMC / SDIO / CEC 等本型号用不了的外设'
                    : '显示全部外设，用不了的会标记出来',
              ),
              value: onlySupported,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setOnlySupported(v),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            return ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('恢复默认设置'),
              subtitle: const Text('主题跟随系统、代码字号 13pt、显示全部外设、四库全开'),
              onTap: () async {
                await ref.read(settingsProvider.notifier).resetToDefaults();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已恢复默认设置')),
                  );
                }
              },
            );
          },
        ),

        const Divider(),

        // ---- 数据管理 ----
        _SectionTitle('数据管理'),
        Consumer(
          builder: (context, ref, _) {
            final recent = ref.watch(recentProvider).valueOrNull ??
                const <UserRecord>[];
            return ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清除最近查看'),
              subtitle: Text(
                recent.isEmpty ? '暂无记录' : '当前 ${recent.length} 条',
              ),
              enabled: recent.isNotEmpty,
              onTap: recent.isEmpty
                  ? null
                  : () async {
                      await ref.read(recentProvider.notifier).clear();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清除最近查看')),
                        );
                      }
                    },
            );
          },
        ),
        // 搜索历史在阶段 5 已实现持久化，这里同步开放清除入口
        Consumer(
          builder: (context, ref, _) {
            final history = ref.watch(searchHistoryProvider).valueOrNull ??
                const <String>[];
            return ListTile(
              leading: const Icon(Icons.history),
              title: const Text('清空搜索历史'),
              subtitle: Text(
                history.isEmpty ? '暂无历史' : '当前 ${history.length} 条',
              ),
              enabled: history.isNotEmpty,
              onTap: history.isEmpty
                  ? null
                  : () async {
                      await ref.read(searchHistoryProvider.notifier).clear();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清空搜索历史')),
                        );
                      }
                    },
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final notes =
                ref.watch(notesProvider).valueOrNull ?? const <UserRecord>[];
            return ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出全部笔记为 Markdown'),
              subtitle: Text(
                notes.isEmpty ? '暂无笔记' : '将导出 ${notes.length} 条笔记',
              ),
              enabled: notes.isNotEmpty,
              onTap: notes.isEmpty
                  ? null
                  : () => _exportNotes(context, ref, notes),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final favorites =
                ref.watch(favoritesProvider).valueOrNull ?? const <UserRecord>[];
            return ListTile(
              leading: const Icon(Icons.delete_forever_outlined),
              title: const Text('清空全部用户数据'),
              subtitle: Text(
                '收藏 ${favorites.length} 条 · 笔记与浏览记录一并清除',
              ),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空全部用户数据？'),
                    content: const Text(
                      '将删除所有收藏、笔记与最近查看记录，且不可恢复。\n'
                      'assets 里的库数据不受影响。',
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('确认清空'),
                      ),
                    ],
                  ),
                );
                if (ok != true) return;
                await ref.read(userStoreProvider).clearAll();
                // 让三个列表重新从库里读（此时都是空的）
                ref.invalidate(favoritesProvider);
                ref.invalidate(notesProvider);
                ref.invalidate(recentProvider);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清空全部用户数据')),
                  );
                }
              },
            );
          },
        ),

        const Divider(),

        // ---- 关于 ----
        _SectionTitle('关于'),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('STM32 库函数助手'),
          subtitle: Text(
            '完全离线的 STM32F103C8T6 函数查阅工具，同时收录四套库：\n'
            '标准库（SPL V3.5.0）、HAL 库与 LL 库（STM32CubeF1 V1.8.7）、'
            '寄存器直驱（CMSIS）。\n'
            'APP 运行时不发起任何网络请求，也未声明 INTERNET 权限。',
          ),
          isThreeLine: true,
        ),
        const ListTile(
          leading: Icon(Icons.numbers),
          title: Text('应用版本'),
          subtitle: Text('$appVersion  ·  包名 $appPackageName'),
        ),
        const ListTile(
          leading: Icon(Icons.copyright_outlined),
          title: Text('数据来源与版权'),
          subtitle: Text(
            '函数原型与英文注释来自 ST 官方 STM32F10x 标准外设库 V3.5.0 '
            '与 STM32CubeF1 V1.8.7，版权归 STMicroelectronics 所有。\n'
            '引脚数据来自《STM32F103C8T6引脚定义.xlsx》（DS5319 Table 5 转录）。\n'
            '中文说明、示例代码与排错经验为本项目整理，仅供个人学习查阅使用。',
          ),
          isThreeLine: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          // 统计数字从数据里取，不写死——写死必然随数据更新而过时
          // （这里曾经写死 2873 / HAL 776，实际早已是 2898 / 801）。
          child: Text(
            _footerStats(ref),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 导出笔记：写临时文件后调起系统分享面板。
  static Future<void> _exportNotes(
    BuildContext context,
    WidgetRef ref,
    List<UserRecord> notes,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await exportNotesToFile(notes);
      messenger.showSnackBar(
        SnackBar(
          content: Text('已生成 ${notes.length} 条笔记的 Markdown：$path'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }
}

/// 设置分组标题。
class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 一个函数库开关的静态描述。
class _LibraryOption {
  final String raw;
  final String title;
  final String subtitle;
  final IconData icon;

  const _LibraryOption(this.raw, this.title, this.subtitle, this.icon);
}

/// 「函数库」分组：一个总开关 + 四个库开关。
///
/// 用户需求是「在设置页能自由勾选显示哪些库的函数」，所以这里只做取值，
/// 真正的过滤在各页面（通过 `libraryVisibleProvider` 读）——
/// 设置页不持有任何过滤逻辑，改一处全站生效。
class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  /// 四个库的展示顺序与文案（顺序同契约 §1：spl, hal, ll, reg）
  static const List<_LibraryOption> _options = <_LibraryOption>[
    _LibraryOption(
      'spl',
      '标准库（SPL V3.5.0）',
      '传统 stm32f10x_xxx 系列，已收录 488 个函数',
      Icons.layers_outlined,
    ),
    _LibraryOption(
      'hal',
      'HAL 库（STM32CubeF1 V1.8.7）',
      'HAL_xxx 系列，STM32CubeMX 生成代码用的就是它',
      Icons.widgets_outlined,
    ),
    _LibraryOption(
      'll',
      'LL 库（STM32CubeF1 V1.8.7）',
      'LL_xxx / __STATIC_INLINE，比 HAL 更贴近寄存器',
      Icons.bolt_outlined,
    ),
    _LibraryOption(
      'reg',
      '寄存器直驱（CMSIS）',
      '直接操作 GPIOA->ODR 这类寄存器',
      Icons.developer_board_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(enabledLibrariesProvider);
    final notifier = ref.read(settingsProvider.notifier);

    final total = _options.length;
    final count = _options.where((o) => enabled.contains(o.raw)).length;
    final allOn = count == total;
    final noneOn = count == 0;

    return Column(
      children: <Widget>[
        // ---- 总开关 ----
        // 三态靠「图标 + 副标题」表达：全开（勾）/ 部分（半选）/ 全关（叉）。
        // Switch 本身只有两种值，全关只是理论状态（下面会拦住），
        // 但仍然把这个分支画出来，免得哪天真的读到空集合时界面自相矛盾。
        SwitchListTile(
          secondary: Icon(
            allOn
                ? Icons.check_circle_outline
                : (noneOn
                    ? Icons.remove_circle_outline
                    : Icons.indeterminate_check_box_outlined),
            color: allOn
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: const Text('全部启用'),
          subtitle: Text(_summaryText(count, total, enabled)),
          value: allOn,
          onChanged: (v) async {
            if (v) {
              await notifier.setAllLibraries(true);
              return;
            }
            // 关总开关 = 只留一个库。
            // 不调 setAllLibraries(false)（那会先落一个空集合，别的页面会闪一下空列表），
            // 而是逐个关掉，全程至少留一个。
            final keep = _options
                .map((o) => o.raw)
                .firstWhere(enabled.contains, orElse: () => _options.first.raw);
            for (final o in _options) {
              if (o.raw == keep) continue;
              if (enabled.contains(o.raw)) {
                await notifier.setLibraryEnabled(o.raw, false);
              }
            }
            if (context.mounted) {
              _toast(context, '至少要保留一个库，已保留「${libraryLabelZh(keep)}」');
            }
          },
        ),
        for (final o in _options)
          SwitchListTile(
            secondary: Icon(
              o.icon,
              color: enabled.contains(o.raw)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(o.title),
            subtitle: Text(o.subtitle),
            value: enabled.contains(o.raw),
            onChanged: (v) async {
              if (!v && enabled.contains(o.raw) && enabled.length <= 1) {
                _toast(context, '至少要保留一个库');
                return;
              }
              await notifier.setLibraryEnabled(o.raw, v);
            },
          ),
      ],
    );
  }

  static String _summaryText(int count, int total, Set<String> enabled) {
    if (count == total) return '四个库全部显示 · 函数、符号与搜索结果都包含';
    if (count == 0) return '当前没有启用任何库（下次启动会回退为全开）';
    final names = _options
        .where((o) => enabled.contains(o.raw))
        .map((o) => o.title.split('（').first)
        .join('、');
    return '已启用 $count/$total 个库：$names';
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

/// 「关于」页底部的数据统计行。
///
/// 从 manifest 与芯片数据里取实际值，**不写死**：写死的数字必然随数据
/// 更新而失真（这里曾经长期写着「2873 个函数 / HAL 776」，实际已是 2898 / 801）。
String _footerStats(WidgetRef ref) {
  final data = ref.watch(splDataProvider).valueOrNull;
  if (data == null) return '';
  final s = data.manifest.stats;
  final counts = s.libraryFunctionCounts;
  final perLib = <String>[
    if (counts['spl'] != null) '标准库 ${counts['spl']}',
    if (counts['hal'] != null) 'HAL ${counts['hal']}',
    if (counts['ll'] != null) 'LL ${counts['ll']}',
    if (counts['reg'] != null) '寄存器 ${counts['reg']}',
  ].join(' · ');
  return '四库合计 ${s.functionCount} 个函数：$perLib\n'
      '${s.pinCount} 个引脚 · ${s.compileErrorCount} 条常见错误';
}
