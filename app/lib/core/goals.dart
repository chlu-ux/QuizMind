import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/stats.dart';
import 'settings.dart';

/// Daily study goals. They live on this device only (they are not synced), so a phone and a laptop can
/// aim at different numbers. A goal of null is off; with both on, both must be met.
class Goals {
  const Goals({this.questions, this.minutes, this.remind = false, this.remindAt = '20:00'});

  /// Questions to answer per day.
  final int? questions;

  /// Minutes to study per day.
  final int? minutes;

  /// Remind, when the app is open after [remindAt] and the goal is not met yet.
  final bool remind;

  /// Local time of day as "HH:MM".
  final String remindAt;

  static const off = Goals();

  /// Copies with the given fields replaced; pass [questions] / [minutes] as null explicitly to switch one off.
  Goals copyWith({Object? questions = _keep, Object? minutes = _keep, bool? remind, String? remindAt}) => sanitize({
        'questions': identical(questions, _keep) ? this.questions : questions,
        'minutes': identical(minutes, _keep) ? this.minutes : minutes,
        'remind': remind ?? this.remind,
        'remindAt': remindAt ?? this.remindAt,
      });

  static const _keep = Object();

  Map<String, Object?> toJson() => {'questions': questions, 'minutes': minutes, 'remind': remind, 'remindAt': remindAt};

  /// Turns whatever was stored (or typed) into valid goals, falling back to the defaults field by field.
  static Goals sanitize(Object? raw) {
    final m = raw is Map ? raw : const {};
    int? whole(Object? v, int max) => v is num && v.isFinite && v >= 1 ? v.floor().clamp(1, max) : null;
    final at = m['remindAt'];
    return Goals(
      questions: whole(m['questions'], maxGoalQuestions),
      minutes: whole(m['minutes'], maxGoalMinutes),
      remind: m['remind'] == true,
      remindAt: at is String && _time.hasMatch(at) ? at : off.remindAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Goals &&
      other.questions == questions &&
      other.minutes == minutes &&
      other.remind == remind &&
      other.remindAt == remindAt;

  @override
  int get hashCode => Object.hash(questions, minutes, remind, remindAt);
}

const maxGoalQuestions = 999;
const maxGoalMinutes = 600;

final _time = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

class GoalStatus {
  const GoalStatus({
    required this.hasGoal,
    required this.questionsDone,
    required this.minutesDone,
    required this.questionsLeft,
    required this.minutesLeft,
    required this.achieved,
  });

  /// At least one goal is on.
  final bool hasGoal;
  final int questionsDone;

  /// Whole minutes studied.
  final int minutesDone;

  /// Questions still to answer; 0 when that goal is off or met.
  final int questionsLeft;

  /// Minutes still to study; 0 when that goal is off or met.
  final int minutesLeft;

  /// Every goal that is on is met. False when none is on.
  final bool achieved;

  /// "还差 5 题、12 分钟"; empty when nothing is left.
  String get remainingText {
    final parts = [if (questionsLeft > 0) '$questionsLeft 题', if (minutesLeft > 0) '$minutesLeft 分钟'];
    return parts.isEmpty ? '' : '还差 ${parts.join('、')}';
  }
}

GoalStatus goalStatus(Goals g, DayProgress p) {
  final minutesDone = p.ms ~/ 60000;
  final questionsLeft = g.questions == null ? 0 : (g.questions! - p.questions).clamp(0, g.questions!);
  final minutesLeft = g.minutes == null ? 0 : (g.minutes! - minutesDone).clamp(0, g.minutes!);
  final hasGoal = g.questions != null || g.minutes != null;
  return GoalStatus(
    hasGoal: hasGoal,
    questionsDone: p.questions,
    minutesDone: minutesDone,
    questionsLeft: questionsLeft,
    minutesLeft: minutesLeft,
    achieved: hasGoal && questionsLeft == 0 && minutesLeft == 0,
  );
}

/// Is it time to nudge: reminders on, a goal set and not yet met, and the reminder time has passed today.
bool reminderDue(Goals g, GoalStatus status, DateTime now) {
  if (!g.remind || !status.hasGoal || status.achieved || !_time.hasMatch(g.remindAt)) return false;
  final parts = g.remindAt.split(':').map(int.parse).toList();
  return now.hour * 60 + now.minute >= parts[0] * 60 + parts[1];
}

/// The goals as the views see them, saved on this device.
final goalsProvider = NotifierProvider<GoalsNotifier, Goals>(GoalsNotifier.new);

class GoalsNotifier extends Notifier<Goals> {
  static const _key = 'goals';

  @override
  Goals build() {
    final raw = ref.watch(sharedPrefsProvider).getString(_key);
    if (raw == null) return Goals.off;
    try {
      return Goals.sanitize(jsonDecode(raw));
    } catch (_) {
      return Goals.off;
    }
  }

  Future<void> save(Goals goals) async {
    state = Goals.sanitize(goals.toJson());
    await ref.read(sharedPrefsProvider).setString(_key, jsonEncode(state.toJson()));
  }
}

/// The current time; the home page's progress card reads it, and tests replace it.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
