import 'package:flutter/material.dart';

import '../utils/theme.dart';
import '../utils/usage_steps.dart';

/// 「使用总览」的分行渲染。
///
/// 这一版存在的唯一理由，是用户对旧渲染的一句明确抱怨：
/// **每个序号要另起一行、序号要顶格**。
///
/// 旧实现把整段 `usageOverviewZh` 丢进一个 `Text`，于是 ① ② ③ 全挤在同一段
/// 里，靠中文句号断句，读起来像一段没有层次的长文；再叠加 `Text` 默认的
/// 行首缩进观感，序号看起来是"缩进去的"。调用顺序本身是有序的步骤，
/// 挤成一段就把"顺序"这个最重要的信息抹掉了。
///
/// 因此这里**不用** `RichText` + `WidgetSpan`（那仍是一段文本，换行时机
/// 由排版决定），而是老老实实一行一个 [Row]：
///   - 序号列单独成列，宽度按 marker 实际文字量取整；
///   - 正文 `Expanded`，多行时自动悬挂缩进对齐到序号右侧；
///   - 整块左侧 padding 为 0，序号与卡片左内边距齐平（"顶格"）。
class UsageStepsView extends StatelessWidget {
  /// 切分好的步骤列表
  final List<UsageStep> steps;

  /// 正文颜色，默认跟随主题
  final Color? textColor;

  /// 正文与序号是否用等宽字体（外设总览不需要，代码式步骤需要）
  final bool mono;

  const UsageStepsView({
    super.key,
    required this.steps,
    this.textColor,
    this.mono = false,
  });

  /// 行的左右间距。
  ///
  /// 这里刻意**没有**左侧 padding：用户要的就是序号顶格。
  static const double rowGap = 6;

  /// 序号列的最小宽度。
  ///
  /// 取 22 是量出来的：14px 字号下一个 `①` 约占 15px，`(1)` 约占 19px，
  /// 再留一点呼吸位。用 ConstrainedBox(minWidth: 22) 而不是固定 width，
  /// 是为了让 `⑫` 这类更宽的序号不会被裁掉。
  static const double markerMinWidth = 22;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = textColor ?? scheme.onSurface;

    if (steps.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < steps.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: rowGap),
          _StepRow(
            step: steps[i],
            base: base,
            scheme: scheme,
            mono: mono,
          ),
        ],
      ],
    );
  }
}

/// 一行步骤：序号列 + 正文。
class _StepRow extends StatelessWidget {
  final UsageStep step;
  final Color base;
  final ColorScheme scheme;
  final bool mono;

  const _StepRow({
    required this.step,
    required this.base,
    required this.scheme,
    required this.mono,
  });

  @override
  Widget build(BuildContext context) {
    // ---- 没有编号的引导语：当作普通段落渲染 ----
    //
    // 例如「标准调用顺序：」「两类用法：」这类行。它们不是步骤，
    // 用正文样式渲染会让人误以为也是可执行的一步；缩小一档字号、
    // 换成次要色，视觉上退成"标题"，与下面的编号行区分开。
    if (step.marker.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: Text(
          step.text,
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // ---- 序号列 ----
        //
        // ConstrainedBox 而不是 SizedBox：`⑳` 与 `(10)` 的宽度不一样，
        // 固定宽度要么裁字要么留出大坑。minWidth 保证单字符序号也占够
        // 一列的宽度，多字符序号则自然撑开。
        ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: UsageStepsView.markerMinWidth,
          ),
          child: Text(
            // 序号后面跟一个空格再进正文 —— 契约要求"正文与序号之间留一个空格"。
            // 用 marker 自身 + 独立空格，而不是靠 Row 的 spacing，
            // 这样序号列宽天然含了那个空格，正文起点才能严格对齐。
            '${step.marker} ',
            style: TextStyle(
              fontFamilyFallback: mono ? AppFonts.mono : null,
              fontSize: 14,
              height: 1.75,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ),
        // ---- 正文 ----
        Expanded(
          child: Text(
            step.text,
            style: TextStyle(
              fontFamilyFallback: mono ? AppFonts.mono : null,
              fontSize: 14,
              height: 1.75,
              color: base,
            ),
          ),
        ),
      ],
    );
  }
}
