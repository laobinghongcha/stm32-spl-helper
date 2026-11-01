import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chip.dart';
import '../models/library_kind.dart';
import '../models/peripheral.dart';
import '../providers/app_providers.dart';
import '../utils/theme.dart';
import '../widgets/block_label.dart';
import '../widgets/library_chip.dart';
import 'peripheral_detail_page.dart';

/// 首页：外设分类浏览。
///
/// 需求 5.1：
///   - 展示所有外设，按使用频率排序（可切字母序）
///   - 每个外设显示中文名 + 英文名 + 函数数量 + 一句话简介
///   - 支持"仅显示 C8T6 实际支持的外设"开关
///   - 不支持的外设（DAC/FSMC/SDIO/CEC）标记"该型号不支持"
///     判断依据是 ChipSpec.supportsPeripheral（来自 chips/*.json 的
///     unsupportedPeripherals），与 peripherals.json 里的 tags 无关——
///     tags 只用于展示，改文案不会影响这里的过滤逻辑。
///
/// 阶段 10 改版要点：
///   - 顶部从"一块灰底信息条"改成**芯片概览卡**：芯片名 + 规格 +
///     四个关键数据（外设/函数/符号/引脚），首屏就能看到数据规模
///   - 外设卡片改成"左侧色条 + 主标题层级"，扫列表时靠色块定位
///   - 卡片用 AnimatedContainer 做按压反馈，不再是默认的墨水扩散
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(splDataProvider);

    return dataAsync.when(
      loading: () => const _LoadingView(),
      error: (error, stack) => _ErrorView(error: error),
      data: (data) {
        final onlySupported = ref.watch(onlySupportedProvider);
        final sortMode = ref.watch(homeSortModeProvider);
        final enabled = ref.watch(enabledLibrariesProvider);
        final chip = data.chip;

        // 过滤与排序都在内存里做，数据量小（25 个外设），无需缓存
        var list = List<Peripheral>.from(data.peripherals);
        if (onlySupported) {
          list = list
              .where((p) => chip.supportsPeripheral(p.id))
              .toList(growable: false);
        }
        if (sortMode == HomeSortMode.alphabetical) {
          list.sort((a, b) => a.name.compareTo(b.name));
        }

        final unsupportedCount = data.peripherals
            .where((p) => !chip.supportsPeripheral(p.id))
            .length;

        return CustomScrollView(
          slivers: <Widget>[
            // ---- 芯片概览卡 ----
            SliverToBoxAdapter(
              child: _ChipOverviewCard(
                chip: chip,
                stats: _OverviewStats(
                  peripherals: data.peripherals.length,
                  // v2：函数总数改成「四库合计」。
                  // 单看 488（只有 SPL）会让用户以为这 App 只认标准库。
                  functions: data.peripherals.fold<int>(
                    0,
                    (a, p) => a + _enabledFunctionCount(p, enabled),
                  ),
                  // 符号数取 manifest 的统计值，与设置页的「数据统计」同一口径。
                  // 不能再用 data.symbols.length：那只是 SPL 的 API 符号（2450），
                  // 不含 HAL/LL 的 5021 个，也不含寄存器位定义。
                  symbols: data.manifest.stats.symbolCount,
                  pins: data.pinout.pins.length,
                  // 各库函数数（只统计启用的库，与上面的合计口径一致）
                  perLibrary: <LibraryKind, int>{
                    for (final lib in LibraryKind.ordered)
                      if (enabled.contains(lib.raw))
                        lib: data.peripherals.fold<int>(
                          0,
                          (a, p) => a + p.functionCountOf(lib),
                        ),
                  },
                ),
              ),
            ),
            // ---- 过滤开关 ----
            SliverToBoxAdapter(
              child: _FilterRow(
                onlySupported: onlySupported,
                unsupported: unsupportedCount,
                onToggle: (v) =>
                    ref.read(settingsProvider.notifier).setOnlySupported(v),
              ),
            ),
            // ---- 分组标题 ----
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: BlockLabel(
                  // 标题里点名四个库：用户第一次打开要立刻知道这四类都能查
                  '外设模块（标准库 / HAL / LL / 寄存器）',
                  icon: Icons.widgets_outlined,
                  count: '${list.length}',
                  topSpace: AppSpace.sm,
                ),
              ),
            ),
            // ---- 外设列表 ----
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md,
                0,
                AppSpace.md,
                AppSpace.xxl,
              ),
              sliver: SliverList.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpace.sm),
                itemBuilder: (context, index) {
                  final p = list[index];
                  final supported = chip.supportsPeripheral(p.id);
                  // 该外设下"有数据 且 用户开启了"的库。
                  // 一个都没有时整张卡片置灰禁点：点进去只能看到空列表。
                  final activeLibs = p.availableLibraries
                      .where((lib) => enabled.contains(lib.raw))
                      .toList(growable: false);
                  return _PeripheralCard(
                    peripheral: p,
                    chip: chip,
                    supported: supported,
                    activeLibraries: activeLibs,
                    functionCount: _enabledFunctionCount(p, enabled),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            PeripheralDetailPage(peripheralId: p.id),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// 该外设在「用户启用的库」下的函数总数。
  static int _enabledFunctionCount(Peripheral p, Set<String> enabled) {
    var sum = 0;
    for (final lib in p.availableLibraries) {
      if (!enabled.contains(lib.raw)) continue;
      sum += p.functionCountOf(lib);
    }
    return sum;
  }
}

/// 概览卡里的四个数字 + 各库明细。
class _OverviewStats {
  final int peripherals;

  /// 四库合计的函数数（只算设置里启用的库）
  final int functions;
  final int symbols;
  final int pins;

  /// 各库函数数（按 LibraryKind.ordered 顺序，只含启用的库）
  final Map<LibraryKind, int> perLibrary;

  const _OverviewStats({
    required this.peripherals,
    required this.functions,
    required this.symbols,
    required this.pins,
    this.perLibrary = const <LibraryKind, int>{},
  });
}

/// 芯片概览卡。
///
/// 放在首屏顶部回答两个问题："我现在查的是哪颗芯片"、
/// "这里面有多少东西可查"。后者能给用户信心——不知道库里有什么的时候，
/// 看到一个具体的数字（488 个函数）比一句"内容很全"有用。
class _ChipOverviewCard extends StatelessWidget {
  final ChipSpec chip;
  final _OverviewStats stats;

  const _ChipOverviewCard({required this.chip, required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.xs,
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        // 渐变底让这块与下面的列表拉开层次；深色模式下降对比度，
        // 否则一进页面就被一块高饱和度色块顶住
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? <Color>[
                  scheme.primary.withValues(alpha: 0.18),
                  scheme.primary.withValues(alpha: 0.06),
                ]
              : <Color>[
                  scheme.primary.withValues(alpha: 0.12),
                  scheme.primary.withValues(alpha: 0.03),
                ],
        ),
        borderRadius: AppRadius.card,
        border: Border.all(
          color: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // 芯片小图标（方框 + 引脚），与 App 图标呼应
              _ChipGlyph(color: scheme.primary),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      chip.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.monoStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${chip.core} · ${chip.package}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          // 规格行：Flash / RAM / 主频
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: <Widget>[
              _SpecPill(
                icon: Icons.save_outlined,
                text: '${chip.flashKb}KB Flash',
              ),
              _SpecPill(
                icon: Icons.memory_outlined,
                text: '${chip.ramKb}KB RAM',
              ),
              _SpecPill(
                icon: Icons.speed_outlined,
                text: '${chip.maxFreqMhz}MHz',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Divider(
            height: 1,
            color: scheme.primary.withValues(alpha: 0.14),
          ),
          const SizedBox(height: AppSpace.md),
          // 四个数字
          Row(
            children: <Widget>[
              _StatItem(value: '${stats.peripherals}', label: '外设'),
              _StatDivider(color: scheme.primary.withValues(alpha: 0.14)),
              _StatItem(value: '${stats.functions}', label: '函数'),
              _StatDivider(color: scheme.primary.withValues(alpha: 0.14)),
              _StatItem(value: '${stats.symbols}', label: '符号'),
              _StatDivider(color: scheme.primary.withValues(alpha: 0.14)),
              _StatItem(value: '${stats.pins}', label: '引脚'),
            ],
          ),
          // 各库函数数：四个数字里的"函数"是合计，这里拆开说明合计从哪来。
          // 不拆开的话用户看到 1200+ 会困惑"我查的不是标准库吗，哪来这么多"。
          if (stats.perLibrary.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final entry in stats.perLibrary.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      LibraryChip(library: entry.key, compact: true),
                      const SizedBox(width: 4),
                      Text(
                        '${entry.value}',
                        style: AppFonts.monoStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 芯片小图标（方框 + 四边引脚 + 中心方块）。
class _ChipGlyph extends StatelessWidget {
  final Color color;

  const _ChipGlyph({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: CustomPaint(painter: _ChipGlyphPainter(color)),
    );
  }
}

class _ChipGlyphPainter extends CustomPainter {
  final Color color;

  _ChipGlyphPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final body = size.width * 0.56;
    final left = (size.width - body) / 2;
    final top = (size.height - body) / 2;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, body, body),
      const Radius.circular(3),
    );

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRRect(rect, stroke);

    // 中心方块
    final inner = body * 0.34;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: inner,
          height: inner,
        ),
        const Radius.circular(1.5),
      ),
      Paint()..color = color,
    );

    // 四边各 3 根引脚
    final pin = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final gap = body * 0.26;
    for (var i = -1; i <= 1; i++) {
      final off = i * gap;
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(
        Offset(cx + off, top - 3),
        Offset(cx + off, top + 1),
        pin,
      );
      canvas.drawLine(
        Offset(cx + off, top + body - 1),
        Offset(cx + off, top + body + 3),
        pin,
      );
      canvas.drawLine(
        Offset(left - 3, cy + off),
        Offset(left + 1, cy + off),
        pin,
      );
      canvas.drawLine(
        Offset(left + body - 1, cy + off),
        Offset(left + body + 3, cy + off),
        pin,
      );
    }
  }

  @override
  bool shouldRepaint(_ChipGlyphPainter old) => old.color != color;
}

/// 规格小胶囊。
class _SpecPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SpecPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.7),
        borderRadius: AppRadius.chip,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个统计数字（数值 + 标签竖排）。
class _StatItem extends StatelessWidget {
  final String value;
  final String label;

  const _StatItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.monoStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  final Color color;

  const _StatDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 24, color: color);
  }
}

/// 过滤开关行。
class _FilterRow extends StatelessWidget {
  final bool onlySupported;
  final int unsupported;
  final ValueChanged<bool> onToggle;

  const _FilterRow({
    required this.onlySupported,
    required this.unsupported,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.xs,
        AppSpace.md,
        0,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.row,
          onTap: () => onToggle(!onlySupported),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: 6,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  onlySupported
                      ? Icons.filter_alt
                      : Icons.filter_alt_outlined,
                  size: 17,
                  color: onlySupported
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '仅显示本型号支持的外设',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (unsupported > 0)
                        Text(
                          '另有 $unsupported 个外设本型号用不了',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                // 用 Switch 但缩小尺寸，与文字行高对齐
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: onlySupported,
                    onChanged: onToggle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 外设卡片。
///
/// 视觉结构：左侧 3px 竖色条（标识可用性）→ 主标题（英文名 + 中文名）
/// → 一行库徽标（这个是哪个库有内容）→ 一句话简介 → 底部横向小标签。
///
/// 三种"不可用"要分清楚，样式也不同：
///   1. 本型号不支持（DAC/FSDC…）—— 降透明度 + 左侧色条转灰，仍可点开看说明；
///   2. 用户把该外设的所有库都关掉了 —— 同样置灰，但**禁点**，
///      因为点进去只有空列表；
///   3. 正常 —— 原样。
class _PeripheralCard extends StatefulWidget {
  final Peripheral peripheral;
  final ChipSpec chip;
  final bool supported;

  /// 该外设下"有数据 且 用户启用"的库（最多 4 个）
  final List<LibraryKind> activeLibraries;

  /// 启用库下的函数总数（各库 functionCount 之和）
  final int functionCount;
  final VoidCallback onTap;

  const _PeripheralCard({
    required this.peripheral,
    required this.chip,
    required this.supported,
    required this.activeLibraries,
    required this.functionCount,
    required this.onTap,
  });

  @override
  State<_PeripheralCard> createState() => _PeripheralCardState();
}

class _PeripheralCardState extends State<_PeripheralCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.peripheral;
    final supported = widget.supported;
    // 一个启用的库都没有 → 点进去是空的，直接禁掉
    final hasAnyLibrary = widget.activeLibraries.isNotEmpty;
    final tappable = supported && hasAnyLibrary;

    final accent = !hasAnyLibrary
        ? scheme.outline
        : (supported ? scheme.primary : scheme.outline);
    final cardColor = Theme.of(context).cardTheme.color;
    final borderColor = _pressed
        ? accent.withValues(alpha: 0.5)
        : scheme.outlineVariant;

    return AnimatedOpacity(
      duration: AppDuration.fast,
      opacity: tappable ? 1.0 : 0.62,
      child: AnimatedContainer(
        duration: AppDuration.fast,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: AppRadius.card,
          border: Border.all(color: borderColor),
          // 按压时轻微放大阴影与位移，给"按下去"的手感
          boxShadow: _pressed
              ? <BoxShadow>[
                  BoxShadow(
                    color: accent.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: AppRadius.card,
          child: InkWell(
            borderRadius: AppRadius.card,
            onTap: tappable ? widget.onTap : null,
            onHighlightChanged: (v) => setState(() => _pressed = v),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md,
                AppSpace.md,
                AppSpace.sm,
                AppSpace.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 左侧色条
                  Container(
                    width: 3,
                    height: 34,
                    margin: const EdgeInsets.only(top: 2, right: AppSpace.md),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: tappable ? 0.85 : 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              p.name,
                              style: AppFonts.monoStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: tappable
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Flexible(
                              child: Text(
                                p.nameZh,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        // ---- 库徽标行 ----
                        //
                        // 这是首页回答"这个外设能用哪几种库写"的地方：
                        // 四个小色块紧挨着，扫一眼就知道 HAL 有没有覆盖到它。
                        if (hasAnyLibrary) ...<Widget>[
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final lib in widget.activeLibraries)
                                LibraryChip(library: lib, compact: true),
                            ],
                          ),
                          const SizedBox(height: 5),
                        ],
                        Text(
                          p.oneLineIntro.isEmpty ? '暂无中文说明' : p.oneLineIntro,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: <Widget>[
                            if (!hasAnyLibrary)
                              _Badge(
                                text: '未启用任何库',
                                color: scheme.outline,
                              )
                            else
                              _Badge(
                                text: '${widget.functionCount} 函数',
                                color: scheme.primary,
                              ),
                            if (!supported)
                              _Badge(
                                text: widget.chip.unsupportedReason(p.id),
                                color: scheme.error,
                              )
                            else
                              for (final tag in p.tags.take(2))
                                _Badge(text: tag, color: scheme.tertiary),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Icon(
                      !hasAnyLibrary
                          ? Icons.block
                          : (supported ? Icons.chevron_right : Icons.block),
                      color: tappable
                          ? scheme.onSurfaceVariant
                          : scheme.error.withValues(alpha: 0.6),
                      size: supported ? (tappable ? 20 : 17) : 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 小标签。
class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

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
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 加载态。首屏加载超过 1 秒要显示 loading（需求）。
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          SizedBox(height: AppSpace.lg),
          Text('正在加载标准库数据…', style: TextStyle(fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// 加载失败态。给出可操作的重试按钮而不是只显示错误。
class _ErrorView extends ConsumerWidget {
  final Object error;

  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 42, color: scheme.error),
            const SizedBox(height: AppSpace.lg),
            const Text(
              '数据加载失败',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              onPressed: () => ref.invalidate(splDataProvider),
            ),
          ],
        ),
      ),
    );
  }
}
