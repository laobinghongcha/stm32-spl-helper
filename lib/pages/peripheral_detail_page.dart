import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/function_item.dart';
import '../models/item_ref.dart';
import '../models/library_kind.dart';
import '../models/peripheral.dart';
import '../providers/app_providers.dart';
import '../utils/theme.dart';
import '../utils/usage_steps.dart';
import '../widgets/item_actions.dart';
import '../widgets/library_chip.dart';
import '../widgets/recent_view_recorder.dart';
import '../widgets/usage_steps_view.dart';
import 'function_detail_page.dart';

/// 外设详情页：按库切换浏览函数列表。
///
/// 需求 5.2（v2 扩展）：
///   - 顶部：「库切换条」+ 外设名称 + 当前库的简介 / 使用总览
///   - 主体：当前库的全部函数，按 section 分组，分组可折叠
///   - 每一项：函数名（等宽）+ 库徽标 + 中文简述 + 返回值
///
/// v2 的核心变化：**同一个外设现在有四种库的函数**。GPIO 下既有 `GPIO_Init`
/// （SPL）也有 `HAL_GPIO_Init`（HAL）还有 `LL_GPIO_SetPinMode`（LL）和
/// `REG_GPIO_CRL`（寄存器）。把 87 个 SPL 函数和 40 个 HAL 函数混在一个列表里
/// 是不可读的，所以改成"先选库、再看该库的函数"——顶部那条库切换条就是导航主轴。
///
/// 另一个显式变化：「使用总览」从一整段 Text 换成 [UsageStepsView]，
/// 每个序号另起一行、序号顶格（用户明确抱怨过旧渲染）。
class PeripheralDetailPage extends ConsumerStatefulWidget {
  final String peripheralId;

  const PeripheralDetailPage({super.key, required this.peripheralId});

  @override
  ConsumerState<PeripheralDetailPage> createState() =>
      _PeripheralDetailPageState();
}

class _PeripheralDetailPageState extends ConsumerState<PeripheralDetailPage> {
  /// 折叠状态：section id → 是否展开。默认全展开。
  final Set<String> _collapsed = <String>{};

  final ScrollController _scroll = ScrollController();

  /// 当前选中的库；null 表示还没初始化，取第一个可用库
  LibraryKind? _selectedLib;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 该外设下「数据里有」且「设置里开启」的库。
  ///
  /// 两个集合都要看：
  ///   - availableLibraries 决定这个外设到底有没有这个库的内容
  ///     （USART 有 SPL/HAL/LL，但 CEC 可能只有 SPL）；
  ///   - enabledLibraries 是用户在设置页的偏好。
  /// 只显示两者交集，避免点进去看到空列表。
  List<LibraryKind> _visibleLibraries(Peripheral peripheral, Set<String> enabled) {
    return peripheral.availableLibraries
        .where((lib) => enabled.contains(lib.raw))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(splDataProvider);

    return dataAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(widget.peripheralId)),
        body: Center(child: Text('加载失败：$e')),
      ),
      data: (data) {
        final peripheral = data.peripheral(widget.peripheralId);
        if (peripheral == null) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.peripheralId)),
            body: const Center(child: Text('找不到该外设')),
          );
        }

        // 外设数据已就绪，记一次「最近查看」。
        // 放在 when 的 data 分支里而不是 initState，是为了避免
        // "外设 id 不存在"时也留下一条点不开的记录。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            recordRecentView(
              ref,
              ItemRef(
                type: ItemType.peripheral,
                id: peripheral.id,
                title: peripheral.name,
                subtitle: peripheral.nameZh,
              ),
            );
          }
        });

        final enabled = ref.watch(enabledLibrariesProvider);
        final visible = _visibleLibraries(peripheral, enabled);

        // 选中的库失效时（首次进入、或用户刚在设置里关掉了它）回退到第一个可用库。
        // 不这么做会出现"切换条上一个都不高亮、列表却是旧库内容"的错位。
        var selected = _selectedLib;
        if (selected == null || !visible.contains(selected)) {
          selected = visible.isEmpty ? null : visible.first;
        }

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  peripheral.name,
                  style: AppFonts.monoStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  peripheral.nameZh,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              ItemActions(
                item: ItemRef(
                  type: ItemType.peripheral,
                  id: peripheral.id,
                  title: peripheral.name,
                  subtitle: peripheral.nameZh,
                ),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              // ---- 库切换条（常驻顶部，长列表滚动时也能切） ----
              if (visible.isNotEmpty)
                _LibrarySwitcherBar(
                  libraries: visible,
                  selected: selected!,
                  counts: <LibraryKind, int>{
                    for (final lib in visible)
                      lib: peripheral.functionCountOf(lib),
                  },
                  onSelect: (lib) {
                    if (lib == selected) return;
                    setState(() {
                      _selectedLib = lib;
                      // 切库重置折叠状态：两个库的 section id 完全不同，
                      // 保留旧集合没有意义，反而会让新库的分组莫名是折叠的。
                      _collapsed.clear();
                      // 回到顶部，否则用户在 SPL 的第 60 个函数处切到 HAL，
                      // 会落在 HAL 列表中部，看起来像"内容没变"
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    });
                  },
                ),
              // 函数详情按需加载：进页面时才读该外设 + 该库的 JSON。
              // key 绑库名 → 切库时整棵子树重建，过滤词自动清空
              // （需求：切换库时重置折叠状态与过滤词）。
              Expanded(
                child: selected == null
                    ? _NoLibraryEnabled(peripheral: peripheral)
                    : _FunctionListBody(
                        key: ValueKey<String>(
                          '${peripheral.id}:${selected.raw}',
                        ),
                        peripheral: peripheral,
                        library: selected,
                        collapsed: _collapsed,
                        scroll: _scroll,
                        onToggleSection: (id) => setState(() {
                          if (_collapsed.contains(id)) {
                            _collapsed.remove(id);
                          } else {
                            _collapsed.add(id);
                          }
                        }),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 库切换条：一行横向滚动的库徽标。
///
/// 用 [LibraryChip] 而不是 SegmentedButton：库的数量会变（1~4 个），
/// 而且每个库有自己的色相，胶囊 + 选中描边比等宽分段更能表达"这是四种不同的东西"。
class _LibrarySwitcherBar extends StatelessWidget {
  final List<LibraryKind> libraries;
  final LibraryKind selected;
  final Map<LibraryKind, int> counts;
  final ValueChanged<LibraryKind> onSelect;

  const _LibrarySwitcherBar({
    required this.libraries,
    required this.selected,
    required this.counts,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          children: <Widget>[
            for (final lib in libraries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      LibraryChip(
                        library: lib,
                        selected: lib == selected,
                        onTap: () => onSelect(lib),
                      ),
                      if (lib == selected) ...<Widget>[
                        const SizedBox(width: 4),
                        Text(
                          '${counts[lib] ?? 0}',
                          style: TextStyle(
                            fontFamilyFallback: AppFonts.mono,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: LibraryChip.colorOf(lib, scheme, isDark),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 该外设一个启用的库都没有时的提示。
///
/// 这种情况是用户自己在设置里关掉的，所以要明确告诉他"去设置里打开"，
/// 而不是显示一个空列表让他以为数据坏了。
class _NoLibraryEnabled extends StatelessWidget {
  final Peripheral peripheral;

  const _NoLibraryEnabled({required this.peripheral});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.layers_clear_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: AppSpace.md),
            Text(
              '${peripheral.nameZh}下没有启用的函数库',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '到「设置 → 函数库」里打开标准库 / HAL / LL / 寄存器之后，这里才会有内容。',
              style: TextStyle(fontSize: 12, height: 1.5, color: scheme.outline),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 函数列表主体：负责按需加载「该外设 + 该库」的函数数据。
class _FunctionListBody extends ConsumerStatefulWidget {
  final Peripheral peripheral;

  /// 当前浏览的库
  final LibraryKind library;
  final Set<String> collapsed;
  final ScrollController scroll;
  final ValueChanged<String> onToggleSection;

  const _FunctionListBody({
    super.key,
    required this.peripheral,
    required this.library,
    required this.collapsed,
    required this.scroll,
    required this.onToggleSection,
  });

  @override
  ConsumerState<_FunctionListBody> createState() => _FunctionListBodyState();
}

class _FunctionListBodyState extends ConsumerState<_FunctionListBody> {
  late Future<FunctionBundle> _future;

  /// 函数过滤关键词（按函数名或中文简述匹配）
  final TextEditingController _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// 按「外设 + 库」加载。
  ///
  /// HAL/LL/reg 的文件可能不存在（该外设没这个库的实现），
  /// 仓库层会返回空 bundle 而不是抛异常，所以这里只处理"真的读坏了"。
  Future<FunctionBundle> _load() {
    return ref
        .read(assetRepositoryProvider)
        .loadFunctionsOf(widget.peripheral.id, widget.library);
  }

  /// 当前库的分组。
  ///
  /// 优先用 peripherals.json 里的 sections（带中文标题、顺序与头文件一致）。
  /// 若数据里这个库没有 sections（例如生成器只给了函数文件），
  /// 就按函数自带的 sectionId 兜底合成，保证不会出现"有函数却没有分组"。
  List<PeripheralSection> _sectionsFor(FunctionBundle bundle) {
    final declared = widget.peripheral.sectionsOf(widget.library);
    if (declared.isNotEmpty) return declared;

    final byId = <String, List<String>>{};
    final order = <String>[];
    for (final f in bundle.functions) {
      final sid = f.sectionId.isEmpty ? '${widget.peripheral.id}@${widget.library.raw}#sec1' : f.sectionId;
      if (!byId.containsKey(sid)) {
        byId[sid] = <String>[];
        order.add(sid);
      }
      byId[sid]!.add(f.id);
    }
    return <PeripheralSection>[
      for (final sid in order)
        PeripheralSection(
          id: sid,
          title: _fallbackSectionTitle(sid),
          library: widget.library,
          functionIds: byId[sid]!,
        ),
    ];
  }

  /// 从 section id 兜底出可读标题，如 `GPIO@hal#sec2` → 「分组 2」。
  String _fallbackSectionTitle(String sectionId) {
    final hash = sectionId.indexOf('#');
    final tail = hash < 0 ? '' : sectionId.substring(hash + 1);
    final digits = RegExp(r'\d+').firstMatch(tail)?.group(0);
    return digits == null ? '函数' : '分组 $digits';
  }

  /// 过滤后的区块列表。关键词为空时原样返回。
  ///
  /// 匹配范围是函数名 + 中文简述 + 英文简述：用户可能记不住全名，
  /// 只记得"那个读引脚的"或"ITConfig"，两种都能命中。
  List<PeripheralSection> _filterSections(
    String keyword,
    Map<String, FunctionItem> byId,
    List<PeripheralSection> sections,
  ) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return sections;

    final result = <PeripheralSection>[];
    for (final sec in sections) {
      final kept = <String>[];
      for (final id in sec.functionIds) {
        final f = byId[id];
        if (f == null) continue;
        final hit = f.name.toLowerCase().contains(k) ||
            f.briefZh.toLowerCase().contains(k) ||
            f.briefEn.toLowerCase().contains(k);
        if (hit) kept.add(id);
      }
      if (kept.isEmpty) continue;
      // 复制一份只保留命中的函数 id，区块标题与数量随之变化
      result.add(PeripheralSection(
        id: sec.id,
        title: sec.title,
        titleEn: sec.titleEn,
        library: sec.library,
        functionIds: kept,
      ));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FunctionBundle>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final scheme = Theme.of(context).colorScheme;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 40, color: scheme.error),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    '函数数据加载失败\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  FilledButton(
                    onPressed: () => setState(() => _future = _load()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        final bundle = snapshot.data!;
        final byId = <String, FunctionItem>{
          for (final f in bundle.functions) f.id: f,
        };

        final allSections = _sectionsFor(bundle);
        final keyword = _filter.text;
        final sections = _filterSections(keyword, byId, allSections);
        final hitCount = sections.fold<int>(
          0,
          (a, s) => a + s.functionIds.length,
        );
        // "当前库 N 个函数"里的 N：优先用数据里的 functionCountOf，
        // 但实际能点开的数量以已加载的函数为准（两者不一致时以实际为准）。
        final libTotal = widget.peripheral.functionCountOf(widget.library);
        final total = libTotal > 0 ? libTotal : byId.length;
        // 有没有真的在过滤
        final filtering = keyword.trim().isNotEmpty;

        return Column(
          children: <Widget>[
            _FunctionFilterBar(
              controller: _filter,
              library: widget.library,
              total: total,
              hit: hitCount,
              filtering: filtering,
              onChanged: (_) => setState(() {}),
              onClear: () {
                _filter.clear();
                setState(() {});
              },
            ),
            // ---- 命中 0 条时的提示 ----
            //
            // 必须挂在**过滤条下面、列表外面**，不能只作为列表里的一个条目：
            // 外设头部的简介卡 + 使用总览加起来可能有好几百 px 高，
            // 在 360dp 屏上首屏放不下，用户搜了个不存在的词就会看到
            // 一片空白（消息被挤到首屏之下），以为页面卡死了。
            if (sections.isEmpty && filtering)
              _NoMatchHint(keyword: keyword.trim(), library: widget.library)
            else
              Expanded(
                child: ListView(
                  controller: widget.scroll,
                  padding: const EdgeInsets.only(bottom: AppSpace.xxl),
                  children: <Widget>[
                    _PeripheralHeader(
                      peripheral: widget.peripheral,
                      library: widget.library,
                      total: total,
                    ),
                    if (sections.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.lg,
                          AppSpace.xxl,
                          AppSpace.lg,
                          AppSpace.xxl,
                        ),
                        child: Center(
                          child: Text(
                            '该外设暂无 ${widget.library.labelZh} 的函数',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    for (final section in sections)
                      _SectionBlock(
                        section: section,
                        byId: byId,
                        library: widget.library,
                        // 过滤时强制展开：用户搜了东西却看到折叠的分组会很困惑
                        collapsed: !filtering &&
                            widget.collapsed.contains(section.id),
                        onToggle: () => widget.onToggleSection(section.id),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 过滤没有命中时的提示（固定在过滤条下方，不随列表滚动）。
class _NoMatchHint extends StatelessWidget {
  final String keyword;

  /// 当前库（提示里要说清"只搜了这个库"，否则用户会以为全部库都没结果）
  final LibraryKind library;

  const _NoMatchHint({required this.keyword, required this.library});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search_off, size: 38, color: scheme.outline),
              const SizedBox(height: AppSpace.md),
              Text(
                '没有匹配「$keyword」的函数',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                '当前只在「${library.labelZh}」里搜索，换个库或试试更短的关键词',
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 函数过滤条。
class _FunctionFilterBar extends StatelessWidget {
  final TextEditingController controller;

  /// 当前库（计数标签上要标出来，避免用户以为是"全库总数"）
  final LibraryKind library;
  final int total;
  final int hit;
  final bool filtering;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _FunctionFilterBar({
    required this.controller,
    required this.library,
    required this.total,
    required this.hit,
    required this.filtering,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = LibraryChip.colorOf(
      library,
      scheme,
      Theme.of(context).brightness == Brightness.dark,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.sm,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: 8,
                  ),
                  hintText: '在本外设内搜索函数名或说明…',
                  prefixIcon: const Icon(Icons.filter_list, size: 18),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 38,
                    minHeight: 38,
                  ),
                  suffixIcon: filtering
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 17),
                          visualDensity: VisualDensity.compact,
                          onPressed: onClear,
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          // 计数让用户知道过滤掉了多少；前面带库名，明确这是"该库的数量"
          Text(
            filtering ? '$hit/$total' : '$total',
            style: AppFonts.monoStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: filtering ? tint : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 外设头部：当前库的简介 + 使用总览。
///
/// 两个区块的内容都随选中的库变化：HAL 的 GPIO 简介和 SPL 的完全不同
/// （前者讲 `HAL_GPIO_Init` 与 `GPIO_InitTypeDef`，后者讲 `GPIO_InitTypeDef`
/// + `RCC_APB2PeriphClockCmd`）。若固定显示 SPL 那段，切到 HAL 后文案就错了。
class _PeripheralHeader extends StatefulWidget {
  final Peripheral peripheral;
  final LibraryKind library;

  /// 当前库的函数总数
  final int total;

  const _PeripheralHeader({
    required this.peripheral,
    required this.library,
    required this.total,
  });

  @override
  State<_PeripheralHeader> createState() => _PeripheralHeaderState();
}

class _PeripheralHeaderState extends State<_PeripheralHeader> {
  /// 头部是否展开。
  ///
  /// **默认收起**是有意为之：用户的核心诉求是「方便查询 HAL 函数」，
  /// 而 HAL 的简介 + noteZh + 5 步使用总览在 360dp 屏上能占掉整整一屏，
  /// 切完库首屏一个函数都看不到——查询型页面最怕这个。
  /// 收起时只留「库名 + N 个函数 + 头文件」一行元信息，函数列表直接顶上来；
  /// 想读总览的人点一下标题就展开，读一次就记住了。
  bool _expanded = false;

  Peripheral get peripheral => widget.peripheral;
  LibraryKind get library => widget.library;
  int get total => widget.total;

  /// 取当前库的元信息；老数据没有 libraries 时回退到外设自身字段。
  PeripheralLibrary? get _info => peripheral.libraries[library];

  String get _header {
    final h = _info?.header ?? '';
    return h.isNotEmpty ? h : (library == LibraryKind.spl ? peripheral.header : '');
  }

  String get _intro {
    final i = _info?.introZh ?? '';
    if (i.isNotEmpty) return i;
    return library == LibraryKind.spl ? peripheral.introZh : '';
  }

  /// 「使用总览」的最终步骤列表。
  ///
  /// 两个来源：
  ///   1. `libraries[lib].usageSteps` —— 已经切好的字符串数组（生成器给的）；
  ///   2. `libraries[lib].usageOverviewZh` —— 一整段，交给 splitUsageSteps 切。
  /// 前者优先：它已经是"一步一条"，不需要再猜分隔符。
  List<UsageStep> get _steps {
    final declared = _info?.usageSteps ?? const <String>[];
    if (declared.isNotEmpty) {
      return <UsageStep>[
        for (var i = 0; i < declared.length; i++)
          UsageStep(_circled(i + 1), declared[i].trim()),
      ].where((s) => s.text.isNotEmpty).toList(growable: false);
    }
    final raw = _info?.usageOverviewZh ?? '';
    final overview =
        raw.isNotEmpty ? raw : (library == LibraryKind.spl ? peripheral.usageOverviewZh : '');
    return splitUsageSteps(overview);
  }

  /// 1 → ①，20 → ⑳，超出范围退回 "21."
  static String _circled(int n) {
    const marks = '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳';
    return n >= 1 && n <= marks.length ? marks[n - 1] : '$n.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = LibraryChip.colorOf(library, scheme, isDark);
    final steps = _steps;
    final intro = _intro;
    final stepCount = steps.where((s) => s.marker.isNotEmpty).length;
    final noteZh = _info?.noteZh ?? '';

    // 收起时也要让人知道"这里面还有东西"，所以标题行常驻一条步数摘要
    final hasMore = intro.isNotEmpty || noteZh.isNotEmpty || steps.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1F24) : Colors.white,
        borderRadius: AppRadius.card,
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ---- 标题行（始终可见，也是展开/收起的开关）----
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap:
                  hasMore ? () => setState(() => _expanded = !_expanded) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.md,
                  AppSpace.md,
                ),
                child: Row(
                  children: <Widget>[
                    _CountPill(
                      text: '${library.labelZh} $total 个函数',
                      color: tint,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    // 收起时用一行摘要点出"总览讲了几步"，代替整段文字
                    if (!_expanded && stepCount > 0)
                      Text(
                        '$stepCount 步使用总览',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    const Spacer(),
                    if (_header.isNotEmpty)
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.description_outlined,
                              size: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                _header,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: AppFonts.monoStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (hasMore)
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: AppDuration.fast,
                        child: Icon(
                          Icons.expand_more,
                          size: 19,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ---- 展开区：简介 + noteZh + 使用总览 ----
          AnimatedSize(
            duration: AppDuration.normal,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      0,
                      AppSpace.lg,
                      AppSpace.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (intro.isNotEmpty) ...<Widget>[
                          Divider(height: 1, color: scheme.outlineVariant),
                          const SizedBox(height: AppSpace.md),
                          Text(
                            intro,
                            style: const TextStyle(fontSize: 13, height: 1.65),
                          ),
                        ],
                        // 该库若有额外提示（noteZh），跟在简介后面
                        if (noteZh.isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpace.sm),
                          Text(
                            noteZh,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.55,
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        // ---- 使用总览 ----
                        //
                        // 这里曾经是一整个 Text，①②③ 全挤在一段里。现在交给
                        // UsageStepsView：一步一行、序号顶格。这是用户明确提过的槽点。
                        if (steps.isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpace.md),
                          Container(
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer.withValues(
                                alpha: isDark ? 0.16 : 0.3,
                              ),
                              borderRadius: AppRadius.card,
                              border: Border(
                                left: BorderSide(
                                  color: scheme.tertiary,
                                  width: 3,
                                ),
                              ),
                            ),
                            // 左右内边距分开写：左侧只留 12 让序号"顶格"，
                            // 右侧留多一点，长句换行时不顶到边框。
                            padding: const EdgeInsets.fromLTRB(
                              AppSpace.md,
                              AppSpace.md,
                              AppSpace.lg,
                              AppSpace.md,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.route_outlined,
                                      size: 14,
                                      color: scheme.tertiary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '使用总览',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.tertiary,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpace.sm),
                                    Text(
                                      '$stepCount 步',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpace.sm),
                                // 左 padding 为 0：序号与「使用总览」文字左缘对齐
                                UsageStepsView(steps: steps),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 计数小胶囊。
class _CountPill extends StatelessWidget {
  final String text;
  final Color color;

  const _CountPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 一个函数分组（可折叠）。
class _SectionBlock extends StatelessWidget {
  final PeripheralSection section;
  final Map<String, FunctionItem> byId;

  /// 当前库（分节色条与条目徽标取色用）
  final LibraryKind library;
  final bool collapsed;
  final VoidCallback onToggle;

  const _SectionBlock({
    required this.section,
    required this.byId,
    required this.library,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = LibraryChip.colorOf(library, scheme, isDark);
    // 按 section.functionIds 的顺序取函数，保证与头文件顺序一致
    final items = section.functionIds
        .map((id) => byId[id])
        .whereType<FunctionItem>()
        .toList(growable: false);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        0,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: AppRadius.card,
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ---- 分节头 ----
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  AppSpace.md,
                  AppSpace.md,
                  AppSpace.md,
                ),
                child: Row(
                  children: <Widget>[
                    // 左侧色块代替图标，扫列表时靠位置与颜色定位；
                    // 颜色跟随当前库，与顶部切换条同一套色相
                    Container(
                      width: 3,
                      height: 26,
                      margin: const EdgeInsets.only(right: AppSpace.md),
                      decoration: BoxDecoration(
                        color: tint.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            section.title,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (section.titleEn != null &&
                              section.titleEn!.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 1),
                            Text(
                              section.titleEn!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Text(
                      '${items.length}',
                      style: AppFonts.monoStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 2),
                    // 折叠箭头带旋转动画
                    AnimatedRotation(
                      turns: collapsed ? 0 : 0.25,
                      duration: AppDuration.fast,
                      child: Icon(
                        Icons.chevron_right,
                        size: 19,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ---- 函数条目（展开时有过渡） ----
          AnimatedSize(
            duration: AppDuration.normal,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: collapsed
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Divider(height: 1, color: scheme.outlineVariant),
                      for (var i = 0; i < items.length; i++) ...<Widget>[
                        _FunctionTile(item: items[i], library: library),
                        if (i != items.length - 1)
                          Divider(
                            height: 1,
                            indent: 30,
                            endIndent: AppSpace.md,
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 单个函数条目：函数名（等宽）+ 库徽标 + 中文简述 + 返回值。
class _FunctionTile extends StatelessWidget {
  final FunctionItem item;

  /// 行尾徽标显示的库
  final LibraryKind library;

  const _FunctionTile({required this.item, required this.library});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FunctionDetailPage(functionId: item.name),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.md,
            AppSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 函数名 + 返回值 + 库徽标同一行。
              //
              // 三部分都需要约束：早先返回值是无约束的 Text 且内容为中文长句
              // （最长 40 字），会把函数名挤到只剩一两个字符宽，表现为
              // "函数名竖向显示"。现在函数名 Expanded、返回值限宽、徽标定宽，
              // 三者都不换行、溢出省略。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      item.name,
                      // 函数名是英文标识符，禁止换行（换行看起来像竖排）
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.monoStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Text(
                      item.displayReturn,
                      textAlign: TextAlign.right,
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.monoStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 徽标固定在行尾：扫列表时同一列的色块比读函数名前缀更快
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: LibraryChip(library: library, compact: true),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                item.displayBrief,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
