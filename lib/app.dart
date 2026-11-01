import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/compile_errors_page.dart';
import 'pages/home_page.dart';
import 'pages/my_page.dart';
import 'pages/pinout_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'providers/app_providers.dart';
import 'utils/theme.dart';

/// 应用根组件。
///
/// 只负责主题与首页壳，数据加载在各页面里通过 Provider 拿。
class SplHelperApp extends ConsumerWidget {
  const SplHelperApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'STM32 库函数助手',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const RootShell(),
      // 全局中文文案（只有中文，不做国际化，需求明确）
      locale: const Locale('zh', 'CN'),
    );
  }
}

/// 一个底部 Tab 的定义。
class _TabSpec {
  /// Tab 标题（AppBar 与导航栏共用）
  final String label;

  /// 未选中图标
  final IconData icon;

  /// 选中图标
  final IconData selectedIcon;

  /// 一句话说明（用作 AppBar 副标题，解释这个 Tab 能干什么）
  final String hint;

  const _TabSpec({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.hint,
  });
}

/// 底部导航壳：外设 | 搜索 | 我的 | 工具 | 设置。
///
/// 用 IndexedStack 保持各 Tab 的状态（搜索词、滚动位置），
/// 切回来时不会丢。
///
/// 阶段 10 的改动：
///   - AppBar 从"只有标题"改成"标题 + 一句话说明"，让每个 Tab 一进来
///     就知道这里能做什么（新用户不知道"我的"里有什么）
///   - Tab 切换用 AnimatedSwitcher 交叉淡入，不再是硬切
///   - 导航栏样式在 theme 里统一，这里只管结构与状态
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _index = 0;

  /// 各 Tab 的定义
  static const List<_TabSpec> _tabs = <_TabSpec>[
    _TabSpec(
      label: '外设',
      icon: Icons.memory_outlined,
      selectedIcon: Icons.memory,
      hint: '按外设浏览 488 个标准库函数',
    ),
    _TabSpec(
      label: '搜索',
      icon: Icons.search_outlined,
      selectedIcon: Icons.search,
      hint: '函数、宏、引脚、错误，全局检索',
    ),
    _TabSpec(
      label: '我的',
      icon: Icons.star_border,
      selectedIcon: Icons.star,
      hint: '收藏、最近查看与笔记',
    ),
    _TabSpec(
      label: '工具',
      icon: Icons.build_outlined,
      selectedIcon: Icons.build,
      hint: '引脚速查与编译错误排查',
    ),
    _TabSpec(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      hint: '外观、数据与关于',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = _tabs[_index];

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(current.label),
            const SizedBox(height: 2),
            // 副标题随 Tab 切换淡入，强化"当前在哪个区"
            AnimatedSwitcher(
              duration: AppDuration.fast,
              child: Text(
                current.hint,
                key: ValueKey<int>(_index),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        actions: _index == 0 ? <Widget>[_buildSortMenu(context)] : null,
      ),
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          HomePage(),
          SearchPage(),
          MyPage(),
          ToolsPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        // 导航栏上方一条极细的分隔线，代替阴影——阴影在大面积浅色上
        // 会显得脏，1px 分割线更干净
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: <NavigationDestination>[
            for (final t in _tabs)
              NavigationDestination(
                icon: Icon(t.icon),
                selectedIcon: Icon(t.selectedIcon),
                label: t.label,
              ),
          ],
        ),
      ),
    );
  }

  /// 首页排序菜单。
  Widget _buildSortMenu(BuildContext context) {
    final mode = ref.watch(homeSortModeProvider);
    return PopupMenuButton<HomeSortMode>(
      icon: const Icon(Icons.sort, size: 21),
      tooltip: '排序方式：${mode.labelZh}',
      initialValue: mode,
      onSelected: (m) => ref.read(homeSortModeProvider.notifier).state = m,
      itemBuilder: (context) => HomeSortMode.values
          .map((m) => PopupMenuItem<HomeSortMode>(
                value: m,
                child: Text(m.labelZh),
              ))
          .toList(),
    );
  }
}

/// "工具"Tab：挂引脚速查与编译错误速查。
///
/// 需求 5.5 指定底部导航为五个 Tab，而引脚与编译错误是工具性质，
/// 所以收在这里而不是单独占 Tab。
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        _ToolCard(
          icon: Icons.grid_on,
          title: '引脚速查表',
          subtitle: 'LQFP48 引脚排布、复用功能、按功能反查引脚',
          color: scheme.primary,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PinoutPage()),
          ),
        ),
        _ToolCard(
          icon: Icons.error_outline,
          title: '编译错误速查',
          subtitle: '15 类常见编译、链接、下载错误的排查步骤',
          color: scheme.error,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CompileErrorsPage()),
          ),
        ),
      ],
    );
  }
}

/// 工具入口卡片。
class _ToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(icon, color: color),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
