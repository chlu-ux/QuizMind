import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/goals.dart';
import '../../core/providers.dart';

/// Today's progress toward the daily goals, at the top of the bank list. Nothing is shown without a goal.
/// Once the reminder time has passed with the goal still open it turns into a nudge saying what is left;
/// that only happens while the app is open (there is no background notification).
class GoalCard extends ConsumerStatefulWidget {
  const GoalCard({super.key});

  @override
  ConsumerState<GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends ConsumerState<GoalCard> {
  late DateTime _now = ref.read(clockProvider)();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The reminder shows once the clock passes the set time even if the page just sits open, and
    // a page left open past midnight starts the new day from zero.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = ref.read(clockProvider)());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goals = ref.watch(goalsProvider);
    if (goals.questions == null && goals.minutes == null) return const SizedBox.shrink();
    final day = DateTime(_now.year, _now.month, _now.day);
    final progress = ref.watch(dayProgressProvider(day)).value;
    if (progress == null) return const SizedBox.shrink();
    final status = goalStatus(goals, progress);
    final due = reminderDue(goals, status, _now);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget line(String label, String value, int done, int goal, bool met) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Text(label, style: theme.textTheme.bodySmall), const Spacer(), Text(value, style: theme.textTheme.bodySmall)]),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: (done / goal).clamp(0.0, 1.0),
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              color: met ? Colors.green.shade600 : null,
            ),
          ]),
        );

    return Card(
      key: const Key('goal-card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: status.achieved ? Colors.green.withValues(alpha: 0.12) : (due ? scheme.errorContainer : null),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('今日进度', style: theme.textTheme.titleSmall),
            const Spacer(),
            if (status.achieved)
              Text('🎉 今天的目标完成了', style: TextStyle(color: Colors.green.shade700))
            else if (due)
              Text('⏰ ${status.remainingText}', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600))
            else
              Text(status.remainingText, style: theme.textTheme.bodySmall),
          ]),
          if (goals.questions case final g?)
            line('已做题', '${status.questionsDone} / $g 题', status.questionsDone, g, status.questionsLeft == 0),
          if (goals.minutes case final g?)
            line('已学习', '${status.minutesDone} / $g 分钟', status.minutesDone, g, status.minutesLeft == 0),
        ]),
      ),
    );
  }
}
