/// 「使用总览」文本 → 可逐行渲染的步骤列表。
///
/// 背景：`peripherals.json` 里的 `usageOverviewZh` 是整理过的一句话，
/// 常常是「标准调用顺序：① …；② …；③ …」这种**单行长句**。
/// 直接扔进 `Text` 会挤成一大坨（用户原话：「每个序号没有分行」）。
///
/// 这里把长句切成带序号的步骤，交给 UI（`UsageStepsView`）一行一条地排。
/// 切分规则见 `docs/contract_v2.md` §8；本文件是**唯一实现**，
/// 页面与测试都调 [splitUsageSteps]，不要在别处再写一遍正则。
library;

/// 一条使用步骤。
///
/// [marker] 是序号本身（`①` / `1.` / `(1)` / `第1步` …），
/// 引导语这类没有序号的项 [marker] 为空串。
/// [text] 是去掉序号后的正文，已 trim。
class UsageStep {
  /// 序号，如 `①` / `1.` / `第2步`；无序号时为 `''`
  final String marker;

  /// 步骤正文（不含序号，已 trim）
  final String text;

  const UsageStep(this.marker, this.text);

  /// 是否带序号（引导语为 false）
  bool get hasMarker => marker.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is UsageStep && other.marker == marker && other.text == text;

  @override
  int get hashCode => Object.hash(marker, text);

  @override
  String toString() => hasMarker ? '$marker $text' : text;
}

// ---------------------------------------------------------------------------
// 序号识别
// ---------------------------------------------------------------------------

/// 序号候选：
/// - 圈号 `①-⑳`（U+2460..U+2473）与 `⑴-⒇`（U+2474..U+2487）
/// - `1)` `1）` `1、` `1.`（句点后不能紧跟数字，否则是 `1.5` 这种小数）
/// - `(1)` `（1）`
/// - `第1步` / `第 1 步` / `第一步`
///
/// 刻意**不**认「裸数字」——正文里 `72MHz`、`STM32F103`、`USART2/3`
/// 的数字太常见，认了会把句子切碎。
final RegExp _markerPattern = RegExp(
  r'(?:'
  r'[\u2460-\u2473\u2474-\u2487]' // ①-⑳ ⑴-⒇
  r'|\d{1,2}\s*(?:[、）)]|[.．](?![0-9]))' // 1、 1) 1） 1.（非小数）
  r'|[（(]\d{1,2}[）)]' // (1) （1）
  r'|第\s*[0-9一二三四五六七八九十]{1,3}\s*步' // 第1步 / 第一步
  r')',
);

/// 允许出现在序号**前面**的分隔符：只有这些（以及行首 / 空白）才算「新一步开始」。
///
/// 没有这一条的话，`注意：忘了第 ① 步…` 里的 ① 会被当成新步骤，
/// 切出「① 步是新手最常踩的坑…」这种半截句子。
const Set<int> _boundaryPunctuation = <int>{
  0xFF1B, 0x003B, // ； ;
  0x3002, // 。
  0xFF01, 0x0021, // ！ !
  0xFF1F, 0x003F, // ？ ?
  0xFF1A, 0x003A, // ： :
  0xFF0C, 0x002C, // ， ,
  0x3001, // 、
};

/// 序号前若紧挨着这些字，说明它被**引用**（「第 ① 步」），不是新步骤的起点。
const Set<int> _quotePrefixChars = <int>{
  0x7B2C, // 第
};

/// 判断 [text] 里下标 [start] 处的序号是否真的是「一步的开始」。
///
/// 判定顺序：
/// 1. 前面只有空白（行首）→ 是；
/// 2. 跳过空白后，前一个字符是分隔符（`；` `。` `：` `，` 等）→ 是；
/// 3. 恰在「第」之后 → 否（那是「第 ① 步」这种引用）；
/// 4. 前一个字符是普通文字/数字，但序号前**有空白** → 是
///    （`1. 开时钟 2. 填结构体` 这种不带标点的写法）；
/// 5. 其余 → 否。
bool _isStepStart(String text, int start) {
  var i = start - 1;
  var sawSpace = false;
  while (i >= 0) {
    final c = text.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x3000) {
      sawSpace = true;
      i--;
      continue;
    }
    break;
  }

  // 规则 1：行首
  if (i < 0) return true;

  final prev = text.codeUnitAt(i);

  // 规则 2：标点分隔
  if (_boundaryPunctuation.contains(prev)) return true;

  // 规则 3：引用式「第 ① 步」
  if (_quotePrefixChars.contains(prev)) return false;

  // 规则 4：空白分隔
  return sawSpace;
}

/// 找出 [text] 里所有「真的开启新一步」的序号区间。
List<_Span> _stepStarts(String text) {
  final spans = <_Span>[];
  for (final m in _markerPattern.allMatches(text)) {
    if (_isStepStart(text, m.start)) spans.add(_Span(m.start, m.end));
  }
  return spans;
}

/// 内部用：一段文字的下标区间 `[start, end)`。
class _Span {
  final int start;
  final int end;
  const _Span(this.start, this.end);
}

/// 引导语最长多少字。超了就不当引导语（多半是硬换行切出来的半句话）。
const int _maxLeadInLength = 32;

// ---------------------------------------------------------------------------
// 切分
// ---------------------------------------------------------------------------

/// 把 `usageOverviewZh` 切成步骤列表。
///
/// 规则（`docs/contract_v2.md` §8，按优先级）：
/// 1. 含 `\n` 先按行切（`\r\n` / `\r` 一并处理）；
/// 2. 每行若以序号开头、且行内还有其它序号，继续在下一个序号前切；
/// 3. 行首引导语（如「标准调用顺序：」「两类用法：」）单独成 `marker=''` 的一项；
/// 4. 去空行、去首尾空白。
///
/// 永不抛异常：null / 纯空白返回空列表。
List<UsageStep> splitUsageSteps(String? raw) {
  if (raw == null) return const <UsageStep>[];
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const <UsageStep>[];

  final out = <UsageStep>[];
  // 规则 1：先按物理行切
  for (final rawLine in trimmed.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue; // 规则 4：去空行
    out.addAll(_splitOneLine(line));
  }
  return out;
}

/// 切一行。调用方已做去空行与首尾 trim。
///
/// 例：`标准调用顺序：① 开时钟；② 填结构体；③ 调 Init。`
///   → [('', '标准调用顺序：'), ('①', '开时钟；'), ('②', '填结构体；'), ('③', '调 Init。')]
List<UsageStep> _splitOneLine(String line) {
  final starts = _stepStarts(line);

  // 整行没有（有效的）序号：就是一段普通文字
  if (starts.isEmpty) return <UsageStep>[UsageStep('', line)];

  final steps = <UsageStep>[];

  // 规则 3：第一个序号之前的内容
  final lead = line.substring(0, starts.first.start).trim();

  // 规则 2：按序号区间逐段切
  for (var i = 0; i < starts.length; i++) {
    final s = starts[i];
    final bodyEnd = i + 1 < starts.length ? starts[i + 1].start : line.length;
    final marker = line.substring(s.start, s.end).trim();
    var body = line.substring(s.end, bodyEnd).trim();

    // 只有序号没有正文（行尾多打了个 ②）就丢掉，避免渲染出空行
    if (body.isEmpty) continue;

    // 开头的引导语：像「标准调用顺序：」这种以冒号结尾的短句单独成项；
    // 否则说明是上一行硬换行断开的半句话，接回第一步正文，保持原文语序。
    if (i == 0 && lead.isNotEmpty) {
      if (_looksLikeLeadIn(lead)) {
        steps.add(UsageStep('', lead));
      } else {
        body = '$lead $body';
      }
    }
    steps.add(UsageStep(marker, body));
  }

  // 极端情况：全是有序号无正文 → 退回原文，至少别丢内容
  if (steps.isEmpty) return <UsageStep>[UsageStep('', line)];
  return steps;
}

/// 判断「第一个序号之前的那段文字」是不是引导语。
///
/// 引导语的特征：以冒号结尾、或不长且不含句号——「标准调用顺序：」
/// 「两类用法：」「定时中断的典型顺序：」都符合。
bool _looksLikeLeadIn(String lead) {
  if (lead.isEmpty) return false;
  final last = lead.codeUnitAt(lead.length - 1);
  if (last == 0x3A || last == 0xFF1A) return true; // : ：
  if (lead.length > _maxLeadInLength) return false;
  // 不含句末标点的短句也算引导语（「两类用法」这种省略冒号的写法）
  return !lead.contains(RegExp(r'[。！？；!?;]'));
}
