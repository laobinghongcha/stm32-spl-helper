import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library_kind.dart';
import '../providers/app_providers.dart';
import '../utils/c_highlighter.dart';
import '../utils/theme.dart';
import 'keyword_text.dart';

/// 代码块：语法高亮 + 关键词可点击 + 一键复制。
///
/// 需求 5.3：
///   - 函数原型代码块可横向滚动、可一键复制
///   - 示例代码带语法高亮、一键复制
///   - 代码里的库内符号可点击跳转
///
/// 需求验收：代码块复制到剪贴板内容正确（缩进不乱）——
/// 复制的是原始字符串，不是渲染后的文本，所以缩进原样保留。
class CodeBlock extends ConsumerWidget {
  /// 代码原文
  final String code;

  /// 语言（目前只支持 c，保留字段便于将来扩展）
  final String language;

  /// 标题（如"函数原型"、"最小示例"）
  final String? title;

  /// 是否横向滚动（原型那种长行用 true，示例代码用 false 让它自动换行）
  final bool horizontalScroll;

  /// 白名单：只把函数相关符号变成链接
  final Set<String>? whitelist;

  /// 当前阅读上下文所属的库（v2.0.1 新增）。
  ///
  /// 传给跳转逻辑，解决 HAL 与 SPL 同名不同类型（如 `GPIO_InitTypeDef`）
  /// 该打开哪一份的歧义。不传则退化为老行为（优先无后缀的那份 = SPL）。
  final LibraryKind? library;

  const CodeBlock({
    super.key,
    required this.code,
    this.language = 'c',
    this.title,
    this.horizontalScroll = false,
    this.whitelist,
    this.library,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final colors = AppTheme.codeColors(brightness);
    final fontSize = ref.watch(codeFontSizeProvider);
    final matcher = ref.watch(symbolMatcherProvider);

    // 词法分析 + 符号标记（只在数据就绪时标记）
    var tokens = CHighlighter.tokenize(code);
    if (matcher != null) {
      tokens = CHighlighter.markSymbols(tokens, matcher, whitelist: whitelist);
    }

    final baseStyle = TextStyle(
      fontFamilyFallback: AppTheme.monoFontFamily,
      fontSize: fontSize,
      height: 1.55,
      color: colors.plain,
    );

    final spans = CHighlighter.toSpans(
      tokens,
      colors,
      baseStyle: baseStyle,
      onSymbolTap: matcher == null
          ? null
          : (name) => openSymbol(context, ref, name, preferredLib: library),
    );

    final content = SelectableText.rich(
      TextSpan(children: spans),
      style: baseStyle,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 标题栏 + 复制按钮
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.code, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title ?? (language == 'c' ? 'C 代码' : language),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_all, size: 17),
                  tooltip: '复制代码',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    // 复制原始字符串，缩进原样保留
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已复制 ${code.length} 个字符',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          duration: const Duration(milliseconds: 1400),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          // 代码正文
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: horizontalScroll
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: content,
                  )
                : content,
          ),
        ],
      ),
    );
  }
}

/// 内联代码片段（用于正文里的 `GPIO_Init` 这种行内代码）。
class InlineCode extends StatelessWidget {
  final String text;

  const InlineCode(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamilyFallback: AppTheme.monoFontFamily,
          fontSize: 12,
          color: scheme.primary,
        ),
      ),
    );
  }
}
