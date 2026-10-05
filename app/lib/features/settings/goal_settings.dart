import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/goals.dart';

/// The "学习目标" block of the settings page: how many questions and minutes a day, and the reminder.
class GoalSettingsSection extends ConsumerWidget {
  const GoalSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    final notifier = ref.read(goalsProvider.notifier);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('学习目标', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('每天做多少题、学多少分钟，两项可以分别开关；都开时要同时做到才算完成。只存在这台设备上，不会同步。', style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      GoalPicker(
        label: '每天做题',
        unit: '题',
        presets: const [10, 20, 30, 50],
        max: maxGoalQuestions,
        value: goals.questions,
        onChanged: (v) => notifier.save(goals.copyWith(questions: v)),
      ),
      const SizedBox(height: 12),
      GoalPicker(
        label: '每天学习',
        unit: '分钟',
        presets: const [15, 30, 60],
        max: maxGoalMinutes,
        value: goals.minutes,
        onChanged: (v) => notifier.save(goals.copyWith(minutes: v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('每日提醒'),
        value: goals.remind,
        onChanged: (v) => notifier.save(goals.copyWith(remind: v)),
      ),
      if (goals.remind)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('提醒时间'),
          trailing: TextButton(
            onPressed: () async {
              final parts = goals.remindAt.split(':').map(int.parse).toList();
              final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: parts[0], minute: parts[1]));
              if (t == null) return;
              final hh = t.hour.toString().padLeft(2, '0');
              final mm = t.minute.toString().padLeft(2, '0');
              await notifier.save(goals.copyWith(remindAt: '$hh:$mm'));
            },
            child: Text(goals.remindAt),
          ),
        ),
      Text('提醒只在打开 App 时出现：过了提醒时间、目标还没完成，首页会提示还差多少。不会在后台弹通知。', style: theme.textTheme.bodySmall),
    ]);
  }
}

/// One goal: off, a preset, or a number of your own.
class GoalPicker extends StatefulWidget {
  const GoalPicker({
    super.key,
    required this.label,
    required this.unit,
    required this.presets,
    required this.max,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String unit;
  final List<int> presets;
  final int max;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  State<GoalPicker> createState() => _GoalPickerState();
}

class _GoalPickerState extends State<GoalPicker> {
  // "自定义" stays selected while the box is being edited, even if what is typed momentarily matches a preset.
  late bool _custom = widget.value != null && !widget.presets.contains(widget.value);

  void _pick(int? v) {
    setState(() => _custom = false);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(label: const Text('关闭'), selected: v == null && !_custom, onSelected: (_) => _pick(null)),
        for (final p in widget.presets)
          ChoiceChip(label: Text('$p'), selected: !_custom && v == p, onSelected: (_) => _pick(p)),
        ChoiceChip(
          label: const Text('自定义'),
          selected: _custom,
          onSelected: (_) {
            setState(() => _custom = true);
            if (v == null) widget.onChanged(widget.presets.first);
          },
        ),
      ]),
      if (_custom)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: 160,
            child: TextFormField(
              key: ValueKey('custom-${widget.label}'),
              initialValue: v?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                suffixText: widget.unit,
                labelText: '${widget.label}（自定义）',
              ),
              onChanged: (t) {
                final n = int.tryParse(t);
                widget.onChanged(n != null && n >= 1 ? n.clamp(1, widget.max) : null);
              },
            ),
          ),
        ),
    ]);
  }
}
