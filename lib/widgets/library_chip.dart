import 'package:flutter/material.dart';

import '../models/library_kind.dart';
import '../utils/theme.dart';

/// 「函数库」徽标：一眼看出这个函数属于 SPL / HAL / LL / 寄存器哪一种。
///
/// 背景：App 从"只有标准库 488 个函数"扩成四库并行后，同一个外设下会同时
/// 出现 `GPIO_Init`（SPL）和 `HAL_GPIO_Init`（HAL）。光看函数名，新手分不清
/// 哪个是 CubeMX 生成的代码里能用的，所以列表行尾、详情页标题旁都需要一个
/// 稳定的视觉标记。
///
/// 设计约束：
///   - 四种库用**四种色相**（蓝/绿/橙/紫）而不是"深浅变体"，
///     色相差异在扫视时比明度差异可靠得多；
///   - 深色主题下把色相提亮并向 surface 混一点、同时压低填充透明度，
///     否则深底上四块高饱和色会互相打架，压过正文；
///   - 尺寸只有两档（[compact] 或默认），全站不会出现第三种字号。
class LibraryChip extends StatelessWidget {
  /// 所属库
  final LibraryKind library;

  /// 紧凑模式：列表行尾用，字号 9、内边距更窄
  final bool compact;

  /// 选中态：外设详情页顶部库切换条里标记"当前正在看哪个库"
  final bool selected;

  /// 点击回调；为 null 时不可点击（纯展示）
  final VoidCallback? onTap;

  const LibraryChip({
    super.key,
    required this.library,
    this.compact = false,
    this.selected = false,
    this.onTap,
  });

  /// 取某个库在给定主题下的色相。
  ///
  /// 抽成静态方法是为了让页面上的其它元素（如库切换条下划线、
  /// 分组色条）能与徽标取到完全一致的颜色，不用各自再写一份 switch。
  static Color colorOf(LibraryKind library, ColorScheme scheme, bool isDark) {
    final light = switch (library) {
      LibraryKind.spl => const Color(0xFF2C6BED),
      LibraryKind.hal => const Color(0xFF2E9E5B),
      LibraryKind.ll => const Color(0xFFC97A16),
      LibraryKind.reg => const Color(0xFF7A4BD6),
    };
    if (!isDark) return light;
    // 深色底上原色相偏暗、读不清，提亮后再向 surface 混一点降低饱和度
    final lifted = Color.lerp(light, Colors.white, 0.34) ?? light;
    return Color.alphaBlend(lifted.withValues(alpha: 0.92), scheme.surface);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final color = colorOf(library, scheme, isDark);

    // 深色主题下降透明度：色块只是"标记"，不该抢正文的注意力
    final fillAlpha = selected
        ? (isDark ? 0.28 : 0.18)
        : (isDark ? 0.14 : 0.09);
    final borderAlpha = selected ? (isDark ? 0.62 : 0.48) : (isDark ? 0.30 : 0.22);

    final label = library.shortEn;

    Widget chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 7,
        vertical: compact ? 1.5 : 2.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: fillAlpha),
        borderRadius: AppRadius.chip,
        border: Border.all(
          color: color.withValues(alpha: borderAlpha),
          width: selected ? 1.2 : 1,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        // 全大写三字母，等宽字体下宽度稳定，切换选中态时不会左右跳
        style: TextStyle(
          fontFamilyFallback: AppFonts.mono,
          fontSize: compact ? 9 : 10.5,
          height: 1.25,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
          letterSpacing: 0.2,
          color: color,
        ),
      ),
    );

    if (onTap != null) {
      chip = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.chip,
          onTap: onTap,
          child: chip,
        ),
      );
    }

    // 语义标签给读屏用："HAL 库"，而不是只念出 "HAL"
    return Semantics(
      label: '${library.labelZh} ${library.shortEn}',
      selected: selected,
      button: onTap != null,
      child: chip,
    );
  }
}
