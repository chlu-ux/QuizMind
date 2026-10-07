import 'package:flutter/material.dart';

import 'lessons.dart';

/// The colour of a section's state label: grey until it is touched, then blue, amber, green.
Color lessonStateColor(ThemeData theme, LessonState state) => switch (state) {
      LessonState.unread => theme.colorScheme.outline,
      LessonState.read => theme.colorScheme.primary,
      LessonState.practiced => Colors.amber.shade800,
      LessonState.mastered => Colors.green.shade600,
    };

/// A section's state as a small outlined label.
class LessonStateTag extends StatelessWidget {
  const LessonStateTag(this.state, {super.key});

  final LessonState state;

  @override
  Widget build(BuildContext context) {
    final color = lessonStateColor(Theme.of(context), state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(state.label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
