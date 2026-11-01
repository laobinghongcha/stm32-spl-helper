import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/item_ref.dart';
import '../providers/app_providers.dart';
import '../utils/theme.dart';
import '../widgets/item_actions.dart';
import '../widgets/keyword_text.dart';
import '../widgets/recent_view_recorder.dart';
import '../widgets/section_header.dart';

/// 弹出引脚详情。
///
/// 需求 5.6 要求引脚"可点击查看详情"，需求 5.5 要求引脚可收藏。
/// 阶段 7 会把引脚速查表做成可视化排布，但详情本身与排布无关，
/// 所以先在这里实现成底部弹窗，阶段 7 直接复用。
///
/// [onOpenFunction] 用于点复用功能时跳到函数详情页——由调用方传入，
/// 这样弹窗不必知道外面是谁推它起来的。
Future<void> showPinDetail(
  BuildContext context,
  int pinNumber, {
  void Function(String functionId)? onOpenFunction,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _PinDetailSheet(
        pinNumber: pinNumber,
        onOpenFunction: onOpenFunction,
      ),
    ),
  );
}

class _PinDetailSheet extends ConsumerWidget {
  final int pinNumber;
  final void Function(String functionId)? onOpenFunction;

  const _PinDetailSheet({required this.pinNumber, this.onOpenFunction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(splDataProvider).valueOrNull;
    final pin = data?.pinout.pinByNumber(pinNumber);
    if (pin == null) {
      return const Center(child: Text('找不到该引脚'));
    }

    final scheme = Theme.of(context).colorScheme;
    final ref_ = ItemRef(
      type: ItemType.pin,
      id: '${pin.number}',
      title: pin.name,
      subtitle: '第 ${pin.number} 脚',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) recordRecentView(ref, ref_);
    });

    return Column(
      children: <Widget>[
        // ---- 标题栏 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 17,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  '${pin.number}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      pin.name,
                      style: const TextStyle(
                        fontFamilyFallback: AppFonts.mono,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'LQFP48 第 ${pin.number} 脚'
                      '${pin.portName.isEmpty ? '' : ' · ${pin.portName}'}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ItemActions(item: ref_),
            ],
          ),
        ),
        // ---- 标签 ----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              if (pin.fiveVoltTolerant) const _Tag('5V 容忍（FT）'),
              if (pin.jtagSwd != null) _Tag('调试口 ${pin.jtagSwd}'),
              for (final g in pin.groups) _Tag(g.labelZh),
            ],
          ),
        ),
        const Divider(height: 20),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              if (pin.defaultFunction.isNotEmpty) ...<Widget>[
                const SectionHeader(
                  icon: Icons.memory,
                  title: '默认功能',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    pin.defaultFunctionZh.isEmpty
                        ? pin.defaultFunction
                        : '${pin.defaultFunction} — ${pin.defaultFunctionZh}',
                    style: const TextStyle(fontSize: 13.5, height: 1.6),
                  ),
                ),
              ],
              if (pin.functions.isNotEmpty) ...<Widget>[
                const SectionHeader(
                  icon: Icons.alt_route,
                  title: '复用功能',
                  subtitle: '该引脚可配置成的全部功能（点击可跳到对应外设）',
                ),
                for (final f in pin.functions)
                  ListTile(
                    dense: true,
                    title: Text(
                      f.name,
                      style: const TextStyle(
                        fontFamilyFallback: AppFonts.mono,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      <String>[
                        f.kind.labelZh,
                        if (f.remapRequired) '需要重映射',
                        // 外设 id 换成中文名显示；查不到时（例如引脚标注里的
                        // 「USB」在 STM32F103 上只是 USB 的 DM/DP 引脚功能，
                        // 本 APP 没有为它建外设条目）原样显示 id。
                        if (f.peripheralId.isNotEmpty)
                          data?.peripheral(f.peripheralId)?.nameZh ??
                              f.peripheralId,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 12, height: 1.45),
                    ),
                    trailing: pin.relatedFunctionIds.isNotEmpty
                        ? Icon(Icons.chevron_right,
                            size: 18, color: scheme.outline)
                        : null,
                    onTap: (pin.relatedFunctionIds.isEmpty ||
                            onOpenFunction == null)
                        ? null
                        : () {
                            // 跳到该引脚的第一个相关库函数（一般是它的初始化函数）
                            final fid = pin.relatedFunctionIds.first;
                            Navigator.of(context).pop();
                            onOpenFunction!(fid);
                          },
                  ),
                if (pin.relatedFunctionIds.isNotEmpty) ...<Widget>[
                  const SectionHeader(
                    icon: Icons.functions,
                    title: '相关库函数',
                    subtitle: '点击查看用法',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final fid in pin.relatedFunctionIds)
                          ActionChip(
                            label: Text(
                              fid,
                              style: TextStyle(
                                fontFamilyFallback: AppFonts.mono,
                                fontSize: 11.5,
                              ),
                            ),
                            onPressed: onOpenFunction == null
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    onOpenFunction!(fid);
                                  },
                          ),
                      ],
                    ),
                  ),
                ],
              ],
              if (pin.notesZh.isNotEmpty) ...<Widget>[
                const SectionHeader(
                  icon: Icons.tips_and_updates_outlined,
                  title: '注意事项',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: KeywordText(
                    pin.notesZh,
                    style: const TextStyle(fontSize: 13, height: 1.65),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 标签小片。
class _Tag extends StatelessWidget {
  final String text;

  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
