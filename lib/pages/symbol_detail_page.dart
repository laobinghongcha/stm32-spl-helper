import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/item_ref.dart';
import '../models/symbol_item.dart';
import '../providers/app_providers.dart';
import '../utils/theme.dart';
import '../widgets/item_actions.dart';
import '../widgets/keyword_text.dart';
import '../widgets/library_chip.dart';
import '../widgets/recent_view_recorder.dart';
import '../widgets/section_header.dart';

/// 符号详情页（需求 5.3 的跳转目标）。
///
/// 显示符号名、类型（宏/枚举值/枚举类型/结构体/typedef）、值或成员列表、
/// 中文说明、被哪些函数使用（可反查跳转）。
class SymbolDetailPage extends ConsumerStatefulWidget {
  final String symbolId;

  const SymbolDetailPage({super.key, required this.symbolId});

  @override
  ConsumerState<SymbolDetailPage> createState() => _SymbolDetailPageState();
}

class _SymbolDetailPageState extends ConsumerState<SymbolDetailPage> {
  SymbolItem? _item;
  bool _loading = true;
  Object? _error;

  /// 该符号是否是"寄存器位定义宏"（在 registers.json 里）
  bool _fromRegisters = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(splDataProvider.future);
      // 先在 API 符号里找
      var item = data.symbol(widget.symbolId);
      var fromRegisters = false;
      if (item == null) {
        // 再在寄存器位定义里找（按需加载 2.7 MB）
        // 按 id 匹配而不是 name——与 SplData.symbolById 的口径保持一致，
        // 否则会出现"API 符号按 id 查、寄存器符号按 name 查"两套判定标准。
        final regs = await ref.read(registerSymbolsProvider.future);
        item = regs.where((s) => s.id == widget.symbolId).firstOrNull;
        fromRegisters = item != null;
      }
      if (item == null) {
        throw StateError('未收录符号 ${widget.symbolId}');
      }
      if (!mounted) return;
      setState(() {
        _item = item;
        _fromRegisters = fromRegisters;
        _loading = false;
      });
      recordRecentView(
        ref,
        ItemRef(
          type: ItemType.symbol,
          id: item.id,
          title: item.name,
          subtitle: item.kindLabelZh,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.symbolId)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _item == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.symbolId)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.search_off, size: 40, color: scheme.error),
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
    final data = ref.watch(splDataProvider).valueOrNull;
    final peripheral = data?.peripheral(item.peripheral);
    // 该符号涉及的其它符号也允许点击
    final whitelist = <String>{...item.relatedSymbols};
    final library = item.library;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 标题旁挂库徽标：GPIO_InitTypeDef（HAL）与 GPIO_InitTypeDef（SPL）
            // 同名不同源，靠徽标区分是哪份头文件里的
            Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamilyFallback: AppFonts.mono,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                LibraryChip(library: library, compact: true),
              ],
            ),
            Text(
              '${item.kindLabelZh}${peripheral != null ? ' · ${peripheral.nameZh}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制符号名',
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
              type: ItemType.symbol,
              id: item.id,
              title: item.name,
              subtitle: peripheral?.nameZh ?? item.peripheral,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // ---- 概要 ----
          _SymbolSummary(
            item: item,
            fromRegisters: _fromRegisters,
            variants: data?.symbolVariantsOf(item.name) ?? const <SymbolItem>[],
          ),
          // ---- 中文说明 ----
          if (item.briefZh.isNotEmpty) ...<Widget>[
            const SectionHeader(icon: Icons.info_outline, title: '说明'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: KeywordText(
                item.briefZh,
                whitelist: whitelist,
                style: const TextStyle(fontSize: 13.5, height: 1.7),
              ),
            ),
          ],

          // ---- 用法说明 ----
          if (item.usageZh.isNotEmpty) ...<Widget>[
            const SectionHeader(
              icon: Icons.lightbulb_outline,
              title: '怎么用',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: KeywordText(
                item.usageZh,
                whitelist: whitelist,
                style: const TextStyle(fontSize: 13.5, height: 1.7),
              ),
            ),
          ],

          // ---- 成员列表（结构体成员 / 枚举值）----
          if (item.members.isNotEmpty) ...<Widget>[
            SectionHeader(
              icon: Icons.format_list_bulleted,
              title: item.kind == SymbolKind.enumType ? '可选值' : '成员',
              subtitle: '${item.members.length} 项',
            ),
            for (final m in item.members)
              _MemberTile(member: m, whitelist: whitelist),
          ],

          // ---- 常见坑 ----
          if (item.notesZh.isNotEmpty) ...<Widget>[
            const SectionHeader(
              icon: Icons.warning_amber_rounded,
              title: '注意事项',
            ),
            for (final n in item.notesZh)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.report_problem_outlined,
                          size: 15, color: scheme.error),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: KeywordText(
                        n,
                        whitelist: whitelist,
                        style: const TextStyle(fontSize: 13, height: 1.6),
                      ),
                    ),
                  ],
                ),
              ),
          ],

          // ---- 被哪些函数使用（反查）----
          if (item.usedBy.isNotEmpty) ...<Widget>[
            SectionHeader(
              icon: Icons.hub_outlined,
              title: '被哪些函数使用',
              subtitle: '${item.usedBy.length} 个，点击跳转',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final fid in item.usedBy)
                    ActionChip(
                      avatar: const Icon(Icons.functions, size: 15),
                      label: Text(
                        fid,
                        style: const TextStyle(
                          fontFamilyFallback: AppFonts.mono,
                          fontSize: 12,
                        ),
                      ),
                      onPressed: () => openSymbol(context, ref, fid),
                    ),
                ],
              ),
            ),
          ],

          // ---- 同族符号 ----
          if (item.relatedSymbols.isNotEmpty) ...<Widget>[
            const SectionHeader(
              icon: Icons.link,
              title: '相关符号',
              subtitle: '点击跳转',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final sid in item.relatedSymbols)
                    ActionChip(
                      label: Text(
                        sid,
                        style: const TextStyle(
                          fontFamilyFallback: AppFonts.mono,
                          fontSize: 12,
                        ),
                      ),
                      onPressed: () => openSymbol(context, ref, sid),
                    ),
                ],
              ),
            ),
          ],

          // ---- 英文原文 ----
          if (item.briefEn.isNotEmpty) ...<Widget>[
            const SectionHeader(
              icon: Icons.translate,
              title: 'ST 原始注释（英文）',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                item.briefEn,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 概要卡片：值、类型、定义位置。
class _SymbolSummary extends StatelessWidget {
  final SymbolItem item;
  final bool fromRegisters;

  /// 同名但在其它库里也有定义的版本（成员布局不同，需要给切换入口）。
  ///
  /// 由页面在外面算好后传进来：这里是无状态组件，拿不到数据层，
  /// 而且这个列表在页面生命周期内不变，没必要每帧重算。
  final List<SymbolItem> variants;

  const _SymbolSummary({
    required this.item,
    required this.fromRegisters,
    this.variants = const <SymbolItem>[],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];

    // 所属库：SPL/HAL/LL 都有同名符号（如 GPIO_InitTypeDef），
    // 必须先说清这个符号来自哪一份头文件。
    rows.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 78,
              child: Text(
                '所属库',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            LibraryChip(library: item.library),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                item.library.labelZh,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );

    // 值
    if (item.value != null && item.value!.isNotEmpty) {
      rows.add(_kv(context, '值', item.value!, mono: true));
    }
    // 所属枚举
    if (item.enumType != null && item.enumType!.isNotEmpty) {
      rows.add(_kv(context, '所属枚举', item.enumType!, mono: true));
    }
    // 所属寄存器
    if (item.registerName != null && item.registerName!.isNotEmpty) {
      rows.add(_kv(context, '所属寄存器', item.registerName!, mono: true));
    }
    // 函数式宏的参数
    if (item.functionLike && item.params.isNotEmpty) {
      rows.add(_kv(context, '宏参数', item.params.join(', '), mono: true));
    }
    // 定义位置
    if (item.definedIn.isNotEmpty) {
      rows.add(_kv(context, '定义位置', item.location, mono: true));
    }
    // 可见性
    if (item.isInternal) {
      rows.add(_kv(context, '可见性', '内部符号（断言宏）'));
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    // 同名但不同库的版本切换（v2.0.1 新增）。
    //
    // HAL 与 SPL 都定义了 GPIO_InitTypeDef，成员完全不同。用户从 HAL 函数页
    // 点进来看到的是 HAL 那份；如果他还想看 SPL 那份（或在两者间对比），
    // 必须有个入口——否则靠手工搜索很难找回来。
    final others = variants
        .where((s) => s.library != item.library)
        .toList(growable: false);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (fromRegisters)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '寄存器位定义宏',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.tertiary,
                ),
              ),
            ),
          ...rows,
          if (others.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: AppSpace.sm),
            Text(
              '这个类型在其它库里也有定义，成员不一样',
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: <Widget>[
                for (final v in others)
                  ActionChip(
                    avatar: LibraryChip(library: v.library, compact: true),
                    label: Text(
                      '看 ${v.library.labelZh} 的 ${v.name}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => SymbolDetailPage(symbolId: v.id),
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

  Widget _kv(BuildContext context, String key, String value, {bool mono = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              key,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                fontFamilyFallback: mono ? AppFonts.mono : null,
                color: mono ? scheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 成员行（结构体成员或枚举值）。
class _MemberTile extends StatelessWidget {
  final SymbolMember member;
  final Set<String> whitelist;

  const _MemberTile({required this.member, required this.whitelist});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              Text(
                member.name,
                style: TextStyle(
                  fontFamilyFallback: AppFonts.mono,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              if (member.type != null && member.type!.isNotEmpty)
                KeywordText(
                  member.type!,
                  whitelist: whitelist,
                  style: TextStyle(
                    fontFamilyFallback: AppFonts.mono,
                    fontSize: 11.5,
                    color: scheme.tertiary,
                  ),
                ),
              if (member.value != null && member.value!.isNotEmpty)
                Text(
                  member.value!,
                  style: TextStyle(
                    fontFamilyFallback: AppFonts.mono,
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (member.displayDesc.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              member.displayDesc,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
