import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/function_item.dart';
import '../models/item_ref.dart';
import '../models/library_kind.dart';
import '../models/peripheral.dart';
import '../models/spl_data.dart';
import '../providers/app_providers.dart';
import '../utils/theme.dart';
import '../utils/usage_steps.dart';
import '../widgets/code_block.dart';
import '../widgets/item_actions.dart';
import '../widgets/keyword_text.dart';
import '../widgets/library_chip.dart';
import '../widgets/recent_view_recorder.dart';
import '../widgets/section_header.dart';
import '../widgets/section_nav.dart';
import '../widgets/usage_steps_view.dart';

/// 函数详情页（需求 5.3，本项目的核心页面）。
///
/// 从上到下的区块：
///   1. 函数名 + 所属外设 + 收藏 + 复制
///   2. 函数原型（可横向滚动、可复制、符号可点击）
///   3. 参数表（参数类型里的枚举/结构体名可点击）
///   4. 返回值说明
///   5. 中文使用说明
///   6. 前置条件清单
///   7. 涉及的寄存器（可展开位域说明）
///   8. 最小示例代码（高亮 + 可复制 + 符号可点击）
///   9. 注意事项 / 常见坑
///  10. 相关函数（可点击跳转）
class FunctionDetailPage extends ConsumerStatefulWidget {
  final String functionId;

  const FunctionDetailPage({super.key, required this.functionId});

  @override
  ConsumerState<FunctionDetailPage> createState() => _FunctionDetailPageState();
}

class _FunctionDetailPageState extends ConsumerState<FunctionDetailPage> {
  /// 按需加载的函数对象
  FunctionItem? _item;

  /// 加载状态
  bool _loading = true;
  Object? _error;

  /// 该函数所属的库（加载后确定；用于标题徽标与「所属库」区块）
  LibraryKind _library = LibraryKind.spl;

  /// 该函数所属的外设（加载后确定）
  Peripheral? _peripheral;

  /// 内容区滚动控制器（用于目录条高亮）
  final ScrollController _scroll = ScrollController();

  /// 当前高亮的区块下标（对应 [_currentAnchors] 里的位置）
  int? _activeSection;

  /// 本次渲染实际存在的锚点（区块内容为空时该区块不进目录）
  List<SectionAnchor> _currentAnchors = const <SectionAnchor>[];

  /// 区块锚点的 GlobalKey。
  ///
  /// 在 initState 里建好、整个页面生命周期内保持同一批实例：
  /// 如果每次 build 都新建 GlobalKey，ensureVisible 会拿到已失效的 context。
  /// 这里用固定的一组 key（覆盖所有可能出现的区块），
  /// 区块不存在时那个 key 的 currentContext 就是 null，跳转时自然被忽略。
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{
    for (final id in _sectionOrder) id: GlobalKey(),
  };

  /// 区块的展示顺序（决定目录条里的顺序）。
  ///
  /// 顺序按"读函数时的关注顺序"排：先看原型和参数，
  /// 再看怎么用、要注意什么，最后才是来源与相关函数。
  static const List<String> _sectionOrder = <String>[
    'prototype',
    'params',
    'returns',
    'usage',
    'prerequisites',
    'registers',
    'example',
    'notes',
    'related',
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 按滚动位置更新目录条高亮。
  ///
  /// 判定规则：取"顶端已经越过参考线（内容区顶部 + 一个行高）
  /// 的最后一个区块"。用参考线而不是严格 equality，
  /// 是为了让高亮在区块刚进入视野时就切换，而不是等到完全对齐。
  ///
  /// 这里只读已布局区块的偏移，不做任何布局计算，
  /// 所以在滚动回调里调用开销很小（9 个区块最多 9 次查找）。
  void _onScroll() {
    if (_currentAnchors.isEmpty) return;
    final reference = _scroll.hasClients ? _scroll.offset + 80 : 0.0;

    int? best;
    for (var i = 0; i < _currentAnchors.length; i++) {
      final offset = _currentAnchors[i].offsetInViewport();
      if (offset == null) continue;
      if (offset <= reference) best = i;
    }
    // 还没滚过第一个区块时，高亮第一项
    best ??= 0;
    if (best != _activeSection && mounted) {
      setState(() => _activeSection = best);
    }
  }

  /// 首帧布局后算一次高亮。
  ///
  /// 不这么做的话，进页面时控件都还没布局，_onScroll 里所有
  /// offsetInViewport() 都返回 null，activeIndex 就停在 null，
  /// 目录条一个都不亮——用户得先滚一下才看到高亮。
  void _syncActiveAfterLayout() {
    if (!mounted || _currentAnchors.isEmpty) return;
    // 等这一帧布局完成再读偏移
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(splDataProvider.future);
      final peripheral = _peripheralOf(data);
      if (peripheral == null) {
        throw StateError('找不到函数 ${widget.functionId} 所属的外设');
      }

      // v2 起一个外设下有四种库，函数可能在任何一库里。
      // 只读 SPL 文件是不够的：HAL_GPIO_Init 不在 functions/GPIO.json 里。
      // 这里按「该外设实际有的库」逐个探测，直到找到函数为止。
      //
      // 探测顺序有讲究：先按 id 前缀猜（HAL_ → hal、LL_ → ll、REG_ → reg），
      // 猜不中就扫 SPL 再扫其余——绝大多数点击走的是 SPL/HAL 两条快路径。
      final item = await _loadFunction(peripheral);
      if (item == null) {
        throw StateError('外设 ${peripheral.id} 里找不到函数 ${widget.functionId}');
      }
      if (!mounted) return;
      setState(() {
        _item = item;
        _peripheral = peripheral;
        _library = item.library;
        _loading = false;
      });
      // 数据加载成功后才记「最近查看」（加载失败的页不留记录）
      recordRecentView(
        ref,
        ItemRef(
          type: ItemType.function,
          id: item.id,
          title: item.name,
          subtitle: peripheral.nameZh.isEmpty
              ? peripheral.id
              : peripheral.nameZh,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 在「外设 × 库」矩阵里找到目标函数。
  ///
  /// 返回 null 表示所有库都没有这个 id（数据不一致，由调用方报错）。
  Future<FunctionItem?> _loadFunction(Peripheral peripheral) async {
    final repo = ref.read(assetRepositoryProvider);
    final id = widget.functionId;

    final candidates = _probeOrder(id, peripheral);
    for (final lib in candidates) {
      // 先用 peripherals.json 里的 functionIds 做零成本前置判断：
      // 该库根本没登记这个函数时就别去读文件了（HAL 文件不小）。
      final declared = peripheral.functionIdsOf(lib);
      if (declared.isNotEmpty && !declared.contains(id)) continue;

      final bundle = await repo.loadFunctionsOf(peripheral.id, lib);
      final hit = bundle.functions.where((f) => f.id == id).firstOrNull;
      if (hit != null) return hit;
    }

    // 兜底：数据里的 functionIds 可能没覆盖（例如只生成了函数文件、
    // 忘了回填 sections）。此时无视前置判断，把所有库的文件都读一遍。
    for (final lib in LibraryKind.ordered) {
      final bundle = await repo.loadFunctionsOf(peripheral.id, lib);
      final hit = bundle.functions.where((f) => f.id == id).firstOrNull;
      if (hit != null) return hit;
    }
    return null;
  }

  /// 探测顺序：前缀能猜中的库排第一，其余按「外设实际有的库」顺序。
  ///
  /// 用 if 链而不是 switch 表达式：`switch` 的 `_ when` 分支在这里只是
  /// 为了居中匹配，可读性反而比直白的 if 差。
  List<LibraryKind> _probeOrder(String id, Peripheral peripheral) {
    final LibraryKind guessed;
    if (id.startsWith('HAL_')) {
      guessed = LibraryKind.hal;
    } else if (id.startsWith('LL_')) {
      guessed = LibraryKind.ll;
    } else if (id.startsWith('REG_')) {
      guessed = LibraryKind.reg;
    } else {
      guessed = LibraryKind.spl;
    }

    final available = peripheral.availableLibraries;
    return <LibraryKind>[
      guessed,
      ...available.where((l) => l != guessed),
      // 可能 availableLibraries 里没有但文件存在的库也补上
      ...LibraryKind.ordered.where(
        (l) => l != guessed && !available.contains(l),
      ),
    ];
  }

  /// 该库的头文件名，用于定位条。
  ///
  /// HAL/LL 的头文件（stm32f1xx_hal_gpio.h）与 SPL 的（stm32f10x_gpio.h）
  /// 完全不同，所以必须按库取，不能用外设上那个"主库"字段。
  String _headerOf(Peripheral? peripheral, LibraryKind library) {
    if (peripheral == null) return '';
    final fromLib = peripheral.libraries[library]?.header ?? '';
    if (fromLib.isNotEmpty) return fromLib;
    // 老数据（只有 spl 字段）时回退；非 SPL 库没有就是没有
    return library == LibraryKind.spl ? peripheral.header : '';
  }

  /// 取某库「使用总览」的步骤列表。
  ///
  /// 优先用已切好的 usageSteps；否则把整段 usageOverviewZh 交给
  /// splitUsageSteps 切（契约 §8）。
  List<UsageStep> _usageSteps(PeripheralLibrary? info) {
    if (info == null) return const <UsageStep>[];
    final declared = info.usageSteps;
    if (declared.isNotEmpty) {
      return <UsageStep>[
        for (var i = 0; i < declared.length; i++)
          UsageStep(_circled(i + 1), declared[i].trim()),
      ].where((s) => s.text.isNotEmpty).toList(growable: false);
    }
    return splitUsageSteps(info.usageOverviewZh);
  }

  /// 1 → ①，20 → ⑳，超出范围退回 "21."
  static String _circled(int n) {
    const marks = '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳';
    return n >= 1 && n <= marks.length ? marks[n - 1] : '$n.';
  }

  /// 从核心数据里找出该函数所属的外设。
  ///
  /// 函数详情是按需加载的，所以靠 peripherals.json 的 functionIds 定位外设。
  /// 用 SplData.peripheralIdOfFunction 而不是自己遍历，保证与跳转判断
  /// 用同一份数据源（早先两边不一致，导致跳转报"未收录符号"）。
  Peripheral? _peripheralOf(SplData data) {
    final pid = data.peripheralIdOfFunction(widget.functionId);
    return pid == null ? null : data.peripheral(pid);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.functionId)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _item == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.functionId)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.error_outline, size: 40, color: scheme.error),
                const SizedBox(height: 12),
                Text('${_error ?? '加载失败'}', textAlign: TextAlign.center),
                const SizedBox(height: 14),
                FilledButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ),
      );
    }

    final item = _item!;
    final peripheral = _peripheral;
    final library = _library;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 白名单：只把该函数真正涉及的符号变成链接，避免满屏蓝色
    final whitelist = <String>{...item.symbolRefs};

    // 该库的使用总览（HAL 的调用顺序很有价值，SPL 也常有）
    final libInfo = peripheral?.libraries[library];
    final libSteps = _usageSteps(libInfo);

    // 组装本次实际存在的区块锚点（内容为空的区块不进目录）
    final anchors = <SectionAnchor>[
      SectionAnchor(
        title: '原型',
        icon: Icons.data_object,
        key: _sectionKeys['prototype']!,
      ),
      if (item.params.isNotEmpty)
        SectionAnchor(
          title: '参数',
          icon: Icons.list_alt,
          key: _sectionKeys['params']!,
        ),
      SectionAnchor(
        title: '返回值',
        icon: Icons.keyboard_return,
        key: _sectionKeys['returns']!,
      ),
      if (item.usageZh.isNotEmpty)
        SectionAnchor(
          title: '说明',
          icon: Icons.lightbulb_outline,
          key: _sectionKeys['usage']!,
        ),
      if (item.prerequisites.isNotEmpty)
        SectionAnchor(
          title: '前置',
          icon: Icons.checklist,
          key: _sectionKeys['prerequisites']!,
        ),
      if (item.registers.isNotEmpty)
        SectionAnchor(
          title: '寄存器',
          icon: Icons.memory,
          key: _sectionKeys['registers']!,
        ),
      if (item.exampleCode.isNotEmpty)
        SectionAnchor(
          title: '示例',
          icon: Icons.terminal,
          key: _sectionKeys['example']!,
        ),
      if (item.notesZh.isNotEmpty || item.remarks.isNotEmpty)
        SectionAnchor(
          title: '注意',
          icon: Icons.warning_amber_rounded,
          key: _sectionKeys['notes']!,
        ),
      if (item.relatedFunctions.isNotEmpty)
        SectionAnchor(
          title: '相关',
          icon: Icons.hub_outlined,
          key: _sectionKeys['related']!,
        ),
    ];

    // 存下来供滚动回调使用（回调不在 build 里，拿不到局部变量）
    _currentAnchors = anchors;
    // 首帧布局后补算一次高亮，否则进页面时目录条一个都不亮
    _syncActiveAfterLayout();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 标题旁挂库徽标：HAL_GPIO_Init / GPIO_Init / LL_GPIO_... 长得像，
            // 徽标是唯一一眼可辨的标记。
            Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.monoStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                LibraryChip(library: library, compact: true),
              ],
            ),
            // 副标题：所属外设 + 定义位置（如 stm32f1xx_hal_gpio.h）。
            // HAL/LL 的人看头文件名定位，比看"通用输入输出"有用得多。
            Text(
              <String>[
                if (peripheral != null) peripheral.nameZh,
                if (item.definedIn.isNotEmpty) item.definedIn,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
                fontFamilyFallback: AppFonts.mono,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制函数名',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: item.name));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已复制 ${item.name}')),
                );
              }
            },
          ),
          ItemActions(
            item: ItemRef(
              type: ItemType.function,
              id: item.id,
              title: item.name,
              subtitle: peripheral?.nameZh ?? item.peripheral,
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 粘性目录条：10 个区块的长页面靠它快速定位。
          // activeIndex 跟着滚动位置走，用户随时知道自己在哪一块。
          SectionNavBar(anchors: anchors, activeIndex: _activeSection),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: AppSpace.huge),
              children: <Widget>[
                // ---- 1. 定位信息 ----
                _LocationBar(item: item, header: _headerOf(peripheral, library)),

                // ---- 1b. 所属库 ----
                //
                // 放在原型之前：读 HAL 函数时，"这是 HAL 不是 SPL" 比
                // "这个函数收什么参数"更先决——决定它能不能在自己工程里编译。
                _LibraryInfoBlock(
                  library: library,
                  info: libInfo,
                  definedIn: item.definedIn,
                ),

                // ---- 1c. 该库的使用总览 ----
                //
                // HAL 的调用顺序（使能时钟 → 填 InitTypeDef → HAL_Init 族函数）
                // 是新手最容易漏的一环，放在函数正文之前最有用。
                if (libSteps.isNotEmpty) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.md,
                      AppSpace.sm,
                      AppSpace.md,
                      0,
                    ),
                    child: Container(
                      // 与原型块的左边距对齐；左侧竖线与外设页的总览卡同款
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.md,
                        AppSpace.md,
                        AppSpace.lg,
                        AppSpace.md,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer
                            .withValues(alpha: isDark ? 0.16 : 0.3),
                        borderRadius: AppRadius.card,
                        border: Border(
                          left: BorderSide(color: scheme.tertiary, width: 3),
                        ),
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
                                '${library.shortEn} 使用总览',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.tertiary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpace.sm),
                          // 一行一步、序号顶格（用户明确要求）
                          UsageStepsView(steps: libSteps),
                        ],
                      ),
                    ),
                  ),
                ],

                // ---- 2. 函数原型 ----
                SectionHeader(
                  key: _sectionKeys['prototype'],
                  icon: Icons.data_object,
                  title: '函数原型',
                  subtitle: '点击其中的类型名可跳转',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  child: CodeBlock(
                    code: item.prototype,
                    title: '函数原型',
                    horizontalScroll: true,
                    whitelist: whitelist,
                    library: item.library,
                  ),
                ),

                // ---- 3. 参数表 ----
                //
                // reg 库是个例外：它的"函数"其实是一个寄存器，
                // params 里装的是位域宏（name=GPIO_CRL_MODE0、type=bits[1:0]），
                // 按普通"参数"渲染会很怪（"这个函数有 16 个参数？"），
                // 所以换成位域表：位域名 / 位域 / 说明。
                if (library == LibraryKind.reg && item.params.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['params'],
                    icon: Icons.grid_on,
                    title: '位域',
                    subtitle: '${item.params.length} 个位域宏',
                  ),
                  _BitFieldTable(params: item.params, whitelist: whitelist),
                ] else if (item.params.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['params'],
                    icon: Icons.list_alt,
                    title: '参数',
                    subtitle: '${item.params.length} 个参数',
                  ),
                  for (final p in item.params)
                    _ParamTile(
                      param: p,
                      whitelist: whitelist,
                      library: item.library,
                    ),
                ] else ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['params'],
                    icon: Icons.list_alt,
                    title: '参数',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                    ),
                    child: Text(
                      '该函数没有参数。',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],

                // ---- 4. 返回值 ----
                SectionHeader(
                  key: _sectionKeys['returns'],
                  icon: Icons.keyboard_return,
                  title: '返回值',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      KeywordText(
                        item.displayReturn,
                        whitelist: whitelist,
                        library: library,
                        style: const TextStyle(fontSize: 13, height: 1.65),
                      ),
                      if (item.returnDescEn.isNotEmpty &&
                          item.returnDescZh.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            'ST 原文：${item.returnDescEn}',
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.45,
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // ---- 5. 中文使用说明 ----
                if (item.usageZh.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['usage'],
                    icon: Icons.lightbulb_outline,
                    title: '使用说明',
                    subtitle: '什么时候调用、调用顺序、容易踩的坑',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                    ),
                    child: KeywordText(
                      item.usageZh,
                      whitelist: whitelist,
                      library: library,
                      style: const TextStyle(fontSize: 13, height: 1.75),
                    ),
                  ),
                ],

                // ---- 6. 前置条件 ----
                if (item.prerequisites.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['prerequisites'],
                    icon: Icons.checklist,
                    title: '前置条件',
                    subtitle: '调用前必须满足',
                  ),
                  for (final pre in item.prerequisites)
                    _BulletLine(
                      text: pre,
                      whitelist: whitelist,
                      icon: Icons.check_circle_outline,
                      library: item.library,
                      color: const Color(0xFF3E9C5A),
                    ),
                ],

                // ---- 7. 涉及的寄存器 ----
                if (item.registers.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['registers'],
                    icon: Icons.memory,
                    title: '涉及的寄存器',
                    subtitle: '点击展开位域说明',
                  ),
                  for (final reg in item.registers)
                    _RegisterTile(
                      register: reg,
                      peripheralId: item.peripheral,
                    ),
                ],

                // ---- 8. 最小示例代码 ----
                if (item.exampleCode.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['example'],
                    icon: Icons.terminal,
                    title: '最小示例',
                    subtitle: '可直接复制使用',
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpace.md),
                    child: CodeBlock(
                      code: item.exampleCode,
                      title: '示例代码',
                      whitelist: whitelist,
                      library: item.library,
                    ),
                  ),
                ],

                // ---- 9. 注意事项 / 常见坑 ----
                if (item.notesZh.isNotEmpty || item.remarks.isNotEmpty)
                  ...<Widget>[
                    SectionHeader(
                      key: _sectionKeys['notes'],
                      icon: Icons.warning_amber_rounded,
                      title: '注意事项',
                      color: scheme.error,
                    ),
                    for (final n in item.notesZh)
                      _BulletLine(
                        text: n,
                        whitelist: whitelist,
                        icon: Icons.report_problem_outlined,
                        library: item.library,
                        color: scheme.error,
                      ),
                    for (final r in item.remarks)
                      _BulletLine(
                        text: r,
                        whitelist: whitelist,
                        icon: Icons.info_outline,
                        library: item.library,
                      ),
                  ],

                // ---- 10. 相关函数 ----
                if (item.relatedFunctions.isNotEmpty) ...<Widget>[
                  SectionHeader(
                    key: _sectionKeys['related'],
                    icon: Icons.hub_outlined,
                    title: '相关函数',
                    subtitle: '点击跳转',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                    ),
                    child: Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: <Widget>[
                        for (final id in item.relatedFunctions)
                          ActionChip(
                            avatar: const Icon(Icons.functions, size: 14),
                            label: Text(
                              id,
                              style: AppFonts.monoStyle(fontSize: 11.5),
                            ),
                            onPressed: () => openSymbol(context, ref, id),
                          ),
                      ],
                    ),
                  ),
                ],

                // ---- 底部：ST 英文原文（折叠） ----
                if (item.briefEn.isNotEmpty) _EnglishOriginal(item: item),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「所属库」信息块。
///
/// 回答三个问题：这是哪个库的、头文件叫什么、版本是哪一版。
/// 放在原型之前——HAL 与 SPL 的同名函数长得几乎一样，
/// 先确认"我复制这段代码能不能编过"比看参数更要紧。
class _LibraryInfoBlock extends StatelessWidget {
  final LibraryKind library;

  /// 该库在外设上的元信息（可能为空：老数据只有 spl 字段）
  final PeripheralLibrary? info;

  /// 函数自己的 definedIn（来自 functions/<库>/<外设>.json）
  final String definedIn;

  const _LibraryInfoBlock({
    required this.library,
    required this.info,
    required this.definedIn,
  });

  /// 各库的版本说明。这里写死字符串是有意的：
  /// 版本来自数据生成时的 STM32Cube 包，不是运行时读取的配置，
  /// 而且只有四行，没必要为它加一层数据。
  String get _version => switch (library) {
        LibraryKind.spl => 'STM32F10x_StdPeriph_Lib V3.5.0',
        LibraryKind.hal => 'STM32CubeF1 V1.8.7 · HAL',
        LibraryKind.ll => 'STM32CubeF1 V1.8.7 · LL',
        LibraryKind.reg => 'CMSIS 寄存器定义',
      };

  /// 一句话说明这个库的取向，帮用户选对库。
  String get _hint => switch (library) {
        LibraryKind.spl => '传统标准外设库，函数名不带前缀，教程与老工程里最常见。',
        LibraryKind.hal => 'CubeMX 生成的代码用的就是它，函数名以 HAL_ 开头，带状态返回值。',
        LibraryKind.ll => '比 HAL 更贴近寄存器，多为 LL_ 前缀与 __STATIC_INLINE 内联函数。',
        LibraryKind.reg => '直接读写寄存器（如 GPIOA->ODR），不走任何库函数，体积最小。',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = LibraryChip.colorOf(library, scheme, isDark);

    // 头文件：优先用函数自己的 definedIn（最准确），
    // 其次用库条目上的 header（外设级）。
    final header = definedIn.isNotEmpty
        ? definedIn
        : (info?.header ?? '');

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.xs, AppSpace.md, 0),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: isDark ? 0.10 : 0.06),
        borderRadius: AppRadius.card,
        border: Border(
          left: BorderSide(color: tint, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '所属库',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: tint,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              LibraryChip(library: library),
              const Spacer(),
              Flexible(
                child: Text(
                  _version,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamilyFallback: AppFonts.mono,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _hint,
            style: const TextStyle(fontSize: 12.5, height: 1.55),
          ),
          if (header.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Icon(
                  Icons.description_outlined,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamilyFallback: AppFonts.mono,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// reg 库的位域表：位域名 / 位域 / 说明。
///
/// reg 库的"函数"是一条寄存器（`GPIOA->CRL`），`params` 里装的是它的位域宏。
/// 用户真正想知道的是「MODE0 在哪两位、写什么值」，所以按表格铺开，
/// 而不是沿用参数卡（那种卡片适合 2~4 个函数参数，不适合 16 个位域）。
class _BitFieldTable extends StatelessWidget {
  final List<FunctionParam> params;
  final Set<String> whitelist;

  const _BitFieldTable({required this.params, required this.whitelist});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, 0),
      decoration: BoxDecoration(
        borderRadius: AppRadius.card,
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ---- 表头 ----
          Container(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm + 2,
              vertical: 7,
            ),
            child: Row(
              children: <Widget>[
                _headCell('位域名', flex: 5, scheme: scheme),
                _headCell('位域', flex: 3, scheme: scheme),
                _headCell('说明', flex: 6, scheme: scheme),
              ],
            ),
          ),
          for (var i = 0; i < params.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm + 2,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 位域名：等宽 + 主色，方便与代码里的宏名对照
                  Expanded(
                    flex: 5,
                    child: Text(
                      params[i].name,
                      style: TextStyle(
                        fontFamilyFallback: AppFonts.mono,
                        fontSize: 11,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  // 位域（bits[1:0]）
                  Expanded(
                    flex: 3,
                    child: Text(
                      params[i].type,
                      style: TextStyle(
                        fontFamilyFallback: AppFonts.mono,
                        fontSize: 10.5,
                        height: 1.45,
                        color: scheme.tertiary,
                      ),
                    ),
                  ),
                  // 说明：中文优先，退回英文
                  Expanded(
                    flex: 6,
                    child: Text(
                      params[i].descZh.isNotEmpty
                          ? params[i].descZh
                          : (params[i].descEn.isNotEmpty
                              ? params[i].descEn
                              : '—'),
                      style: const TextStyle(fontSize: 11, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _headCell(String text, {required int flex, required ColorScheme scheme}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 定位信息条：文件名:行号。
class _LocationBar extends StatelessWidget {
  final FunctionItem item;
  final String header;

  const _LocationBar({required this.item, required this.header});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[];
    if (header.isNotEmpty && item.headerLine > 0) {
      parts.add('$header:${item.headerLine}');
    }
    if (item.sourceLine > 0) {
      parts.add('实现位于第 ${item.sourceLine} 行');
    }
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.description_outlined,
              size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: TextStyle(
                fontSize: 11.5,
                fontFamilyFallback: AppFonts.mono,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 参数表的一行。
///
/// 参数类型里出现的枚举名/结构体名可点击跳转（需求 5.3）。
class _ParamTile extends ConsumerWidget {
  final FunctionParam param;
  final Set<String> whitelist;

  /// 函数所属库，用于决定参数类型名点开哪一份定义
  final LibraryKind library;

  const _ParamTile({
    required this.param,
    required this.whitelist,
    required this.library,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasZh = param.descZh.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 参数名 + 类型（类型可点击）
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              Text(
                param.name,
                style: TextStyle(
                  fontFamilyFallback: AppFonts.mono,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              // 类型：把其中的类型名渲染成可点击
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: KeywordText(
                  param.type,
                  whitelist: whitelist,
                  library: library,
                  style: TextStyle(
                    fontFamilyFallback: AppFonts.mono,
                    fontSize: 11.5,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          if (hasZh) ...<Widget>[
            const SizedBox(height: 7),
            KeywordText(
              param.descZh,
              whitelist: whitelist,
              library: library,
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
          if (param.descEn.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              param.descEn,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 带图标的要点行。
class _BulletLine extends StatelessWidget {
  final String text;
  final Set<String> whitelist;
  final IconData icon;
  final Color? color;

  /// 当前函数所属库，用于决定文中类型名点开哪一份定义
  final LibraryKind library;

  const _BulletLine({
    required this.text,
    required this.whitelist,
    required this.icon,
    required this.library,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: c),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: KeywordText(
              text,
              whitelist: whitelist,
              library: library,
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 寄存器条目：点击展开位域说明。
///
/// 数据来自 registers.json（2.7 MB，按需加载）。
/// 函数的 registers 字段用的是 `GPIOx_CRL` 这种占位式命名，
/// 而 registers.json 里是按 `GPIO_CRL` 分节的，所以要归一化后再匹配。
class _RegisterTile extends ConsumerStatefulWidget {
  final String register;
  final String peripheralId;

  const _RegisterTile({required this.register, required this.peripheralId});

  @override
  ConsumerState<_RegisterTile> createState() => _RegisterTileState();
}

class _RegisterTileState extends ConsumerState<_RegisterTile> {
  bool _expanded = false;

  /// 把 `GPIOx_CRL` / `TIMx_PSC` 归一化为 `GPIO_CRL` / `TIM_PSC`。
  ///
  /// 规则：去掉小写字母 x 占位符。`TIMx_CCMR1` → `TIM_CCMR1`。
  String get _normalized =>
      widget.register.replaceAll('x_', '_').replaceAll('x', '');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.memory, size: 15, color: scheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.register,
                      style: TextStyle(
                        fontFamilyFallback: AppFonts.mono,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.tertiary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 19,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) _RegisterBits(normalized: _normalized),
        ],
      ),
    );
  }
}

/// 寄存器位域说明（展开后显示）。
class _RegisterBits extends ConsumerWidget {
  final String normalized;

  const _RegisterBits({required this.normalized});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(registerSymbolsProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('正在加载寄存器定义…', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text('寄存器数据加载失败：$e',
            style: const TextStyle(fontSize: 12)),
      ),
      data: (symbols) {
        final bits = symbols
            .where((s) => s.registerName == normalized)
            .toList(growable: false);

        if (bits.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              '未收录 $normalized 的位域定义（可查阅参考手册）',
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$normalized 位域（${bits.length} 项）',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final b in bits)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 150,
                        child: Text(
                          b.name,
                          style: TextStyle(
                            fontFamilyFallback: AppFonts.mono,
                            fontSize: 11.5,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                      if (b.value != null)
                        SizedBox(
                          width: 96,
                          child: Text(
                            b.value!,
                            style: TextStyle(
                              fontFamilyFallback: AppFonts.mono,
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          b.briefZh.isNotEmpty ? b.briefZh : b.briefEn,
                          style: const TextStyle(fontSize: 11.5, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// ST 英文原文（默认折叠）。
class _EnglishOriginal extends StatefulWidget {
  final FunctionItem item;

  const _EnglishOriginal({required this.item});

  @override
  State<_EnglishOriginal> createState() => _EnglishOriginalState();
}

class _EnglishOriginalState extends State<_EnglishOriginal> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.translate, size: 15, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ST 原始注释（英文）',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(_open ? Icons.expand_less : Icons.expand_more,
                        size: 19, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  widget.item.briefEn,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
