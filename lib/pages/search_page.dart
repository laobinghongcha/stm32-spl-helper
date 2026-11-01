import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/search_history.dart';
import '../data/search_index.dart';
import '../models/item_ref.dart';
import '../models/library_kind.dart';
import '../providers/app_providers.dart';
import '../utils/highlighter.dart';
import '../utils/theme.dart';
import '../widgets/block_label.dart';
import '../widgets/library_chip.dart';
import 'compile_error_detail_page.dart';
import 'function_detail_page.dart';
import 'peripheral_detail_page.dart';
import 'pinout_page.dart';
import 'symbol_detail_page.dart';

/// 全局搜索页。
///
/// 需求 5.4：
///   - 顶部搜索框自动聚焦
///   - 英文不区分大小写、前缀优先；中文子串匹配
///   - 结果按类型分组
///   - 即时响应（不超过 150ms）
///   - 结果高亮
///   - 搜索历史
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<SearchHit> _hits = const <SearchHit>[];
  String _keyword = '';

  /// 当前只看某一类结果；null 表示不筛选
  SearchCategory? _filter;

  @override
  void initState() {
    super.initState();
    // 需求：顶部搜索框自动聚焦
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 即时搜索。索引在内存里，不需要防抖（需求：响应不超过 150ms）。
  void _onChanged(String value, SearchIndex? index) {
    setState(() {
      _keyword = value;
      if (index == null || value.trim().isEmpty) {
        _hits = const <SearchHit>[];
      } else {
        _hits = index.search(
          value,
          includeInternal: ref.read(includeInternalSymbolsProvider),
        );
      }
      // 换了关键词就重置类型筛选，否则会出现"筛选后一直没结果"的困惑
      _filter = null;
    });
  }

  /// 从历史里点一条：填回输入框并立即搜索。
  void _applyKeyword(String keyword, SearchIndex? index) {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    _onChanged(keyword, index);
    _focusNode.requestFocus();
  }

  /// 记录一次搜索历史。
  ///
  /// 只在用户"确认要搜这个词"时记录（提交、点结果、点历史），
  /// 不在每次 onChanged 时记录——否则打 `GPIO_Init` 会存下 9 条前缀垃圾。
  void _recordHistory(String keyword) {
    final k = SearchHistoryStore.normalize(keyword);
    if (k.isEmpty) return;
    ref.read(searchHistoryProvider.notifier).record(k);
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(searchIndexProvider);
    final dataAsync = ref.watch(splDataProvider);
    final includeInternal = ref.watch(includeInternalSymbolsProvider);
    final enabled = ref.watch(enabledLibrariesProvider);
    final scheme = Theme.of(context).colorScheme;

    if (dataAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 按设置里启用的库过滤（用户明确要求：关掉 HAL 后不该再搜出 HAL_ 的函数）。
    //
    // 过滤放在"类型筛选之前"，这样顶部"N 条结果"和各类型角标都是
    // "过滤后还剩多少"，不会出现"显示 88 条、列表里只有 50 条"的错位。
    final byLibrary = _filterByLibrary(_hits, enabled);

    // 类型筛选后的结果
    final visible = _filter == null
        ? byLibrary
        : byLibrary
            .where((h) => h.category == _filter)
            .toList(growable: false);
    final grouped = index == null
        ? const <SearchCategory, List<SearchHit>>{}
        : index.groupByCategory(visible);

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            AppSpace.sm,
            AppSpace.md,
            AppSpace.xs,
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            onChanged: (v) => _onChanged(v, index),
            onSubmitted: (v) => _recordHistory(v),
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              hintText: '搜索函数、宏、枚举、结构体、引脚、错误…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_keyword.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 19),
                      tooltip: '清空',
                      onPressed: () {
                        _controller.clear();
                        _onChanged('', index);
                        _focusNode.requestFocus();
                      },
                    ),
                  // 内部断言宏开关（IS_* 有 350 个，默认不返回）
                  IconButton(
                    icon: Icon(
                      includeInternal
                          ? Icons.visibility
                          : Icons.visibility_off_outlined,
                      size: 19,
                      color: includeInternal
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: includeInternal ? '隐藏内部断言宏' : '包含内部断言宏',
                    onPressed: () {
                      ref
                          .read(includeInternalSymbolsProvider.notifier)
                          .state = !includeInternal;
                      // 开关变了要重搜，否则结果不跟着变
                      _onChanged(_keyword, index);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_keyword.isNotEmpty) ...<Widget>[
          _ResultSummary(
            total: byLibrary.length,
            visible: visible.length,
            filter: _filter,
            onFilterChanged: (c) => setState(() => _filter = c),
            counts: _countsByCategory(byLibrary),
          ),
        ],
        Expanded(
          child: _keyword.isEmpty
              ? _SearchHint(
                  onPick: (k) => _applyKeyword(k, index),
                  onHistoryTap: (k) => _applyKeyword(k, index),
                )
              : visible.isEmpty
                  ? _EmptyResult(
                      keyword: _keyword,
                      hasAnyHit: byLibrary.isNotEmpty,
                      onClearFilter: _filter == null
                          ? null
                          : () => setState(() => _filter = null),
                    )
                  : ListView(
                      children: <Widget>[
                        for (final entry in grouped.entries)
                          ..._buildCategory(entry.key, entry.value, scheme),
                        const SizedBox(height: 24),
                      ],
                    ),
        ),
      ],
    );
  }

  /// 按「设置里启用的库」过滤搜索结果。
  ///
  /// 只对**有库属性的条目**生效：函数（按 id 前缀判断）与符号。
  /// 引脚、编译错误、外设本身不属于任何库，永远显示——否则用户关掉
  /// HAL 后连 PA9 都搜不到了，那是明显不合理的。
  List<SearchHit> _filterByLibrary(List<SearchHit> hits, Set<String> enabled) {
    if (enabled.length >= LibraryKind.ordered.length) return hits;
    return hits.where((h) {
      final lib = _libraryOfHit(h);
      // lib 为 null：这条结果与库无关，照常显示
      return lib == null || enabled.contains(lib.raw);
    }).toList(growable: false);
  }

  /// 判断一条搜索结果属于哪个库；不属于任何库时返回 null。
  ///
  /// v2.0.3 起直接用索引里带的 `library` 字段，不再按 id 前缀猜。
  /// 前缀推断的问题：HAL 里 3313 个符号并不带 `HAL_` 前缀
  /// （`GPIO_InitTypeDef@hal`、`ADC_HandleTypeDef`、各类 Callback typedef…），
  /// 会被一律算成标准库；用户关掉 SPL 想只看 HAL 时这些符号会整片消失。
  static LibraryKind? _libraryOfHit(SearchHit h) => h.library;

  /// 统计每类结果数，用于筛选条上的角标。
  Map<SearchCategory, int> _countsByCategory(List<SearchHit> hits) {
    final map = <SearchCategory, int>{};
    for (final h in hits) {
      map[h.category] = (map[h.category] ?? 0) + 1;
    }
    return map;
  }

  /// 结果按类型分组展示（需求：结果按类型分组）。
  List<Widget> _buildCategory(
    SearchCategory category,
    List<SearchHit> hits,
    ColorScheme scheme,
  ) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.lg,
          AppSpace.lg,
          AppSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 3,
              height: 13,
              margin: const EdgeInsets.only(right: AppSpace.sm),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              category.labelZh,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${hits.length}',
              style: AppFonts.monoStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      for (final h in hits) _buildTile(h, scheme),
    ];
  }

  Widget _buildTile(SearchHit h, ColorScheme scheme) {
    // 结果项做成带图标的行，图标区分类型，扫列表时不用读文字就能定位
    final (IconData icon, Color tint) = switch (h.itemType) {
      ItemType.function => (Icons.functions, scheme.primary),
      ItemType.symbol => (Icons.tag, scheme.tertiary),
      ItemType.peripheral => (Icons.memory, scheme.primary),
      ItemType.pin => (Icons.grid_on, const Color(0xFF3E9C5A)),
      ItemType.compileError => (Icons.error_outline, scheme.error),
    };
    // 该结果属于哪个库（与过滤逻辑用同一个判定，保证"能显示"与"标对了"一致）
    final lib = _libraryOfHit(h);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        0,
        AppSpace.md,
        AppSpace.xs,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.row,
        child: InkWell(
          borderRadius: AppRadius.row,
          onTap: () {
            // 点了结果说明这次搜索是有效的，这时才记历史
            _recordHistory(_keyword);
            _openHit(h);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.sm + 2,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 26,
                  height: 26,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(icon, size: 14, color: tint),
                ),
                const SizedBox(width: AppSpace.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: HighlightedText(
                              h.title,
                              _keyword,
                              // 库里有 41 字符的长函数名
                              // （ADC_GetSoftwareStartInjectedConvCmdStatus），
                              // 不限制的话会被 trailing 挤压成多行。
                              // 标题保持单行省略，完整名字在详情页标题栏里能看全。
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.monoStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          // 库徽标紧贴标题右侧：HAL_GPIO_Init 与 GPIO_Init
                          // 在结果列表里只差三个字母，色块比字母更快
                          if (lib != null) ...<Widget>[
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: LibraryChip(library: lib, compact: true),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      _buildSubtitle(h, scheme),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                // 匹配位置标签很短（名称/名称前缀/名称缩写/说明），
                // 给固定宽度上限
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 56),
                  child: Text(
                    h.matchedField,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 副标题：把命中关键词也高亮出来（不加背景块，避免整行花掉）。
  Widget _buildSubtitle(SearchHit h, ColorScheme scheme) {
    final combined =
        h.subtitle.isEmpty ? h.description : '${h.subtitle} · ${h.description}';
    return HighlightedText(
      combined,
      _keyword,
      maxLines: 1,
      withBackground: false,
      style: const TextStyle(fontSize: 11.5),
    );
  }

  /// 按结果类型跳到对应详情页。
  void _openHit(SearchHit h) {
    switch (h.itemType) {
      case ItemType.function:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FunctionDetailPage(functionId: h.id),
          ),
        );
      case ItemType.symbol:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SymbolDetailPage(symbolId: h.id),
          ),
        );
      case ItemType.peripheral:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PeripheralDetailPage(peripheralId: h.id),
          ),
        );
      case ItemType.pin:
        // 引脚详情在阶段 7 做成弹窗，这里先跳引脚页
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PinoutPage()),
        );
      case ItemType.compileError:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CompileErrorDetailPage(errorId: h.id),
          ),
        );
    }
  }
}

/// 结果摘要 + 类型筛选条。
class _ResultSummary extends StatelessWidget {
  final int total;
  final int visible;
  final SearchCategory? filter;
  final ValueChanged<SearchCategory?> onFilterChanged;
  final Map<SearchCategory, int> counts;

  const _ResultSummary({
    required this.total,
    required this.visible,
    required this.filter,
    required this.onFilterChanged,
    required this.counts,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Text(
            filter == null
                ? '找到 $total 条结果'
                : '${filter!.labelZh} $visible 条 · 共 $total 条',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        // 类型筛选：只在有结果时显示，避免空状态下堆一排灰按钮
        if (total > 0)
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                _FilterChip(
                  label: '全部',
                  count: total,
                  selected: filter == null,
                  onTap: () => onFilterChanged(null),
                ),
                for (final c in SearchCategory.values)
                  if ((counts[c] ?? 0) > 0)
                    _FilterChip(
                      label: c.labelZh,
                      count: counts[c]!,
                      selected: filter == c,
                      // 再点一次取消筛选
                      onTap: () =>
                          onFilterChanged(filter == c ? null : c),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 类型筛选片。
class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text(
          '$label $count',
          style: const TextStyle(fontSize: 11.5),
        ),
        labelStyle: TextStyle(
          color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
      ),
    );
  }
}

/// 有结果但被筛掉了，或干脆没匹配。
class _EmptyResult extends StatelessWidget {
  final String keyword;
  final bool hasAnyHit;
  final VoidCallback? onClearFilter;

  const _EmptyResult({
    required this.keyword,
    required this.hasAnyHit,
    this.onClearFilter,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.search_off, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              hasAnyHit ? '当前类型下没有结果' : '没有匹配「$keyword」的内容',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (onClearFilter != null)
              TextButton(
                onPressed: onClearFilter,
                child: const Text('查看全部类型'),
              )
            else
              Text(
                '试试减少关键词，或检查是否用了中文别名',
                style: TextStyle(fontSize: 12, color: scheme.outline),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

/// 搜索提示 + 历史记录。
class _SearchHint extends ConsumerWidget {
  final ValueChanged<String> onPick;
  final ValueChanged<String> onHistoryTap;

  const _SearchHint({required this.onPick, required this.onHistoryTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final historyAsync = ref.watch(searchHistoryProvider);
    const examples = <String>[
      'GPIO_In',
      'uart',
      'USART_Init',
      'GPIO_Mode_Out_PP',
      'undefined reference',
      'PA9',
      '推挽',
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.lg,
        AppSpace.xl,
        AppSpace.xxl,
      ),
      children: <Widget>[
        // ---- 搜索历史 ----
        historyAsync.maybeWhen(
          data: (history) => history.isEmpty
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    BlockLabel(
                      '最近搜索',
                      icon: Icons.history,
                      topSpace: 0,
                      trailing: TextButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 15),
                        label: const Text(
                          '清空',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        onPressed: () => ref
                            .read(searchHistoryProvider.notifier)
                            .clear(),
                      ),
                    ),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: <Widget>[
                        for (final k in history)
                          InputChip(
                            label: Text(
                              k,
                              style: AppFonts.monoStyle(fontSize: 11.5),
                            ),
                            onPressed: () => onHistoryTap(k),
                            onDeleted: () => ref
                                .read(searchHistoryProvider.notifier)
                                .remove(k),
                            deleteIcon: const Icon(Icons.close, size: 13),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xl),
                  ],
                ),
          orElse: () => const SizedBox.shrink(),
        ),

        // ---- 搜索范围说明 ----
        BlockLabel('搜索范围', icon: Icons.search, topSpace: 0),
        Text(
          '函数名与中文说明、宏名、枚举名与枚举值、结构体名及其成员名、'
          '外设名、引脚名与复用功能、编译错误原文与中文解释。',
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        BlockLabel('试试这些', icon: Icons.touch_app_outlined, topSpace: 0),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: <Widget>[
            for (final e in examples)
              ActionChip(
                // chip 的 label 样式统一由 chipTheme 提供（含颜色），
                // 这里只覆盖字号与等宽字体，不重复写 color——
                // 早先这里写了裸 TextStyle 且没给 color，浅色模式下
                // 变成了白底白字，完全看不见。
                label: Text(
                  e,
                  style: AppFonts.monoStyle(fontSize: 12),
                ),
                onPressed: () => onPick(e),
              ),
          ],
        ),
      ],
    );
  }
}
