import 'database.dart';
import 'progress.dart'; // for Question.tags

/// Attempts that took longer than this (a screen left open) count as this long in the study-time total.
const _maxAttemptMs = 2 * 60 * 1000;

class Tally {
  Tally([this.attempts = 0, this.correct = 0]);

  int attempts;
  int correct;

  void add(bool isCorrect) {
    attempts++;
    if (isCorrect) correct++;
  }

  /// 0-100, or null before the first attempt.
  int? get percent => attempts == 0 ? null : (correct * 100 / attempts).round();
}

class GroupStat extends Tally {
  GroupStat(this.key, this.label);

  final String key;
  final String label;
}

class DayStat extends Tally {
  DayStat(this.start) : label = '${start.month}/${start.day}';

  final DateTime start;

  /// Local calendar day, "M/D".
  final String label;
}

class WeakQuestion {
  const WeakQuestion({required this.question, required this.attempts, required this.wrong});

  final Question question;
  final int attempts;
  final int wrong;
}

class BankReport {
  const BankReport({
    required this.totalQuestions,
    required this.answeredQuestions,
    required this.latestCorrect,
    required this.wrongBook,
    required this.attempts,
    required this.correct,
    required this.accuracy,
    required this.studyMs,
    required this.streakDays,
    required this.daily,
    required this.byType,
    required this.byDifficulty,
    required this.byTag,
    required this.weakest,
  });

  final int totalQuestions;

  /// Distinct questions answered at least once.
  final int answeredQuestions;

  /// Questions whose most recent attempt was right.
  final int latestCorrect;
  final int wrongBook;
  final int attempts;
  final int correct;

  /// Share of all attempts that were right, 0-100; null before the first attempt.
  final int? accuracy;
  final int studyMs;

  /// Consecutive days with at least one attempt, counting back from today
  /// (or yesterday if nothing has been done today yet).
  final int streakDays;

  /// The last 7 days, oldest first.
  final List<DayStat> daily;
  final List<GroupStat> byType;
  final List<GroupStat> byDifficulty;

  /// Knowledge points, weakest first.
  final List<GroupStat> byTag;

  /// Questions missed most, worst first.
  final List<WeakQuestion> weakest;
}

DateTime _dayStart(DateTime t, [int back = 0]) => DateTime(t.year, t.month, t.day - back);

/// Summarises how a bank has been practised. [questions] are the bank's visible
/// questions; attempts for anything else (withdrawn questions, other banks) are
/// ignored. [wrongIds] are the ids currently in the wrong book.
BankReport buildReport(List<Question> questions, List<Attempt> attempts, Set<String> wrongIds, DateTime now) {
  final byId = {for (final q in questions) q.id: q};
  final mine = attempts.where((a) => byId.containsKey(a.questionId)).toList()
    ..sort((a, b) => a.answeredAt.compareTo(b.answeredAt));

  final total = Tally();
  final latest = <String, bool>{};
  final perQuestion = <String, Tally>{};
  final types = <String, GroupStat>{};
  final difficulties = <String, GroupStat>{};
  final tags = <String, GroupStat>{};
  final days = <DateTime>{};
  var studyMs = 0;

  final today = _dayStart(now);
  final daily = [for (var i = 6; i >= 0; i--) DayStat(_dayStart(now, i))];

  void group(Map<String, GroupStat> map, String key, String label, bool ok) =>
      map.putIfAbsent(key, () => GroupStat(key, label)).add(ok);

  for (final a in mine) {
    final q = byId[a.questionId]!;
    total.add(a.isCorrect);
    latest[q.id] = a.isCorrect;
    perQuestion.putIfAbsent(q.id, Tally.new).add(a.isCorrect);
    group(types, q.type, q.type == 'judge' ? '判断题' : '单选题', a.isCorrect);
    group(difficulties, '${q.difficulty}', '难度 ${q.difficulty}', a.isCorrect);
    for (final tag in q.tags) {
      group(tags, tag, tag, a.isCorrect);
    }
    studyMs += (a.durationMs ?? 0).clamp(0, _maxAttemptMs);

    final day = _dayStart(DateTime.fromMillisecondsSinceEpoch(a.answeredAt));
    days.add(day);
    for (final d in daily) {
      if (d.start == day) d.add(a.isCorrect);
    }
  }

  var streak = 0;
  // A streak is still alive if today has no attempt yet but yesterday did.
  var back = days.contains(today) ? 0 : 1;
  while (days.contains(_dayStart(now, back))) {
    streak++;
    back++;
  }

  final weakest =
      [
        for (final e in perQuestion.entries)
          if (e.value.attempts - e.value.correct > 0)
            WeakQuestion(question: byId[e.key]!, attempts: e.value.attempts, wrong: e.value.attempts - e.value.correct),
      ]..sort((a, b) {
        final byRate = (b.wrong / b.attempts).compareTo(a.wrong / a.attempts);
        if (byRate != 0) return byRate;
        final byWrong = b.wrong.compareTo(a.wrong);
        return byWrong != 0 ? byWrong : a.question.id.compareTo(b.question.id);
      });

  double rate(GroupStat g) => g.correct / g.attempts;

  return BankReport(
    totalQuestions: questions.length,
    answeredQuestions: perQuestion.length,
    latestCorrect: latest.values.where((v) => v).length,
    wrongBook: questions.where((q) => wrongIds.contains(q.id)).length,
    attempts: total.attempts,
    correct: total.correct,
    accuracy: total.percent,
    studyMs: studyMs,
    streakDays: streak,
    daily: daily,
    byType: types.values.toList()..sort((a, b) => a.key.compareTo(b.key)),
    byDifficulty: difficulties.values.toList()..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key))),
    byTag: tags.values.toList()
      ..sort((a, b) {
        final byRate = rate(a).compareTo(rate(b));
        if (byRate != 0) return byRate;
        final byCount = b.attempts.compareTo(a.attempts);
        return byCount != 0 ? byCount : a.label.compareTo(b.label);
      }),
    weakest: weakest,
  );
}

/// "1 小时 5 分" / "12 分钟" / "不到 1 分钟".
String formatDuration(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 1) return '不到 1 分钟';
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}
