import 'database.dart';
import 'models.dart';
import 'progress.dart'; // for Question.tags
import 'tags.dart';

/// An answer that took longer than this (a screen left open) counts as this long in the practice-time total.
const _maxAttemptMs = 2 * 60 * 1000;

/// Likewise for the time spent reading after an answer (explanations are read for longer than questions).
const _maxReviewMs = 3 * 60 * 1000;

/// What was done on one local calendar day, across every bank.
class DayProgress {
  const DayProgress({this.questions = 0, this.ms = 0});

  /// Answers given.
  final int questions;

  /// Study time in ms: answering plus reading explanations, each capped like on the stats page.
  final int ms;

  @override
  bool operator ==(Object other) => other is DayProgress && other.questions == questions && other.ms == ms;

  @override
  int get hashCode => Object.hash(questions, ms);

  @override
  String toString() => 'DayProgress($questions, ${ms}ms)';
}

/// Time an answer counts for in the study totals: answering and reading afterwards, each capped.
({int practiceMs, int reviewMs}) attemptTimes(Attempt a) => (
      practiceMs: (a.durationMs ?? 0).clamp(0, _maxAttemptMs),
      reviewMs: (a.reviewMs ?? 0).clamp(0, _maxReviewMs),
    );

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

  /// Time from showing a question to answering it, and the time spent on it after answering (explanation).
  int practiceMs = 0;
  int reviewMs = 0;
  int get studyMs => practiceMs + reviewMs;

  /// Local calendar day, "M/D".
  final String label;
}

/// A question that keeps going wrong. [attempts] and [wrong] cover only its most recent answers.
class WeakQuestion {
  const WeakQuestion({required this.question, required this.attempts, required this.wrong});

  final Question question;
  final int attempts;
  final int wrong;
}

class ExamPoint {
  const ExamPoint({required this.finishedAt, required this.percent, required this.passed});

  final int finishedAt;
  final int percent;
  final bool passed;
}

/// How many of a question's latest answers decide whether it is "weak".
const _weakWindow = 5;

/// Weak ranking pulls small samples toward this error rate, with the weight of this many answers.
const _weakPriorRate = 0.25;
const _weakPriorWeight = 4;

class BankReport {
  const BankReport({
    required this.totalQuestions,
    required this.answeredQuestions,
    required this.latestCorrect,
    required this.wrongBook,
    required this.attempts,
    required this.correct,
    required this.accuracy,
    required this.practiceMs,
    required this.reviewMs,
    required this.streakDays,
    required this.daily,
    required this.daily30,
    required this.examTrend,
    required this.byType,
    required this.byDifficulty,
    required this.byTag,
    required this.byTagMerged,
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

  /// Time spent answering questions.
  final int practiceMs;

  /// Time spent reading explanations after answering.
  final int reviewMs;

  /// Practice plus review: everything spent studying.
  int get studyMs => practiceMs + reviewMs;

  /// Consecutive days with at least one attempt, counting back from today
  /// (or yesterday if nothing has been done today yet).
  final int streakDays;

  /// The last 7 days, oldest first.
  final List<DayStat> daily;

  /// The last 30 days, oldest first.
  final List<DayStat> daily30;

  /// Finished exams, oldest first (the latest 20).
  final List<ExamPoint> examTrend;
  final List<GroupStat> byType;
  final List<GroupStat> byDifficulty;

  /// Knowledge points as tagged (spelling variants folded), weakest first.
  final List<GroupStat> byTag;

  /// Knowledge points with related tags merged ("UML 辨析" into "UML"), weakest first.
  final List<GroupStat> byTagMerged;

  /// Questions that went wrong lately, worst first.
  final List<WeakQuestion> weakest;
}

DateTime _dayStart(DateTime t, [int back = 0]) => DateTime(t.year, t.month, t.day - back);

/// Summarises how a bank has been practised. [questions] are the bank's visible
/// questions; attempts for anything else (withdrawn questions, other banks) are
/// ignored. [wrongIds] are the ids currently in the wrong book.
BankReport buildReport(
  List<Question> questions,
  List<Attempt> attempts,
  Set<String> wrongIds,
  DateTime now, {
  List<ExamRecord> exams = const [],
}) {
  final byId = {for (final q in questions) q.id: q};
  final mine = attempts.where((a) => byId.containsKey(a.questionId)).toList()
    ..sort((a, b) => a.answeredAt.compareTo(b.answeredAt));

  final total = Tally();
  final latest = <String, bool>{};
  final perQuestion = <String, Tally>{};
  final types = <String, GroupStat>{};
  final difficulties = <String, GroupStat>{};
  final tags = <String, GroupStat>{};
  final mergedTags = <String, GroupStat>{};
  final allTags = [for (final q in questions) ...q.tags];
  final fold = tagLabeler(allTags, merge: false);
  final merge = tagLabeler(allTags, merge: true);
  final recent = <String, List<bool>>{}; // each question's results, oldest first
  final days = <DateTime>{};
  var practiceMs = 0;
  var reviewMs = 0;

  final today = _dayStart(now);
  final daily = [for (var i = 29; i >= 0; i--) DayStat(_dayStart(now, i))];

  void group(Map<String, GroupStat> map, String key, String label, bool ok) =>
      map.putIfAbsent(key, () => GroupStat(key, label)).add(ok);

  for (final a in mine) {
    final q = byId[a.questionId]!;
    total.add(a.isCorrect);
    latest[q.id] = a.isCorrect;
    perQuestion.putIfAbsent(q.id, Tally.new).add(a.isCorrect);
    group(types, q.type, q.type == 'judge' ? '判断题' : '单选题', a.isCorrect);
    group(difficulties, '${q.difficulty}', '难度 ${q.difficulty}', a.isCorrect);
    for (final tag in {...q.tags.map(fold)}) {
      group(tags, tag.toLowerCase(), tag, a.isCorrect);
    }
    for (final tag in {...q.tags.map(merge)}) {
      group(mergedTags, tag.toLowerCase(), tag, a.isCorrect);
    }
    recent.putIfAbsent(q.id, () => []).add(a.isCorrect);
    final (practiceMs: practice, reviewMs: review) = attemptTimes(a);
    practiceMs += practice;
    reviewMs += review;

    final day = _dayStart(DateTime.fromMillisecondsSinceEpoch(a.answeredAt));
    days.add(day);
    for (final d in daily) {
      if (d.start != day) continue;
      d.add(a.isCorrect);
      d.practiceMs += practice;
      d.reviewMs += review;
    }
  }

  var streak = 0;
  // A streak is still alive if today has no attempt yet but yesterday did.
  var back = days.contains(today) ? 0 : 1;
  while (days.contains(_dayStart(now, back))) {
    streak++;
    back++;
  }

  // Rank by the error rate over the latest answers, pulled toward a prior so that a
  // single miss does not outrank a question missed 3 times in 5.
  final scored = <({WeakQuestion weak, double score})>[];
  for (final e in recent.entries) {
    final last = e.value.length > _weakWindow ? e.value.sublist(e.value.length - _weakWindow) : e.value;
    final wrong = last.where((ok) => !ok).length;
    if (wrong == 0) continue;
    scored.add((
      weak: WeakQuestion(question: byId[e.key]!, attempts: last.length, wrong: wrong),
      score: (wrong + _weakPriorRate * _weakPriorWeight) / (last.length + _weakPriorWeight),
    ));
  }
  scored.sort((a, b) {
    final bySc = b.score.compareTo(a.score);
    if (bySc != 0) return bySc;
    final byWrong = b.weak.wrong.compareTo(a.weak.wrong);
    return byWrong != 0 ? byWrong : a.weak.question.id.compareTo(b.weak.question.id);
  });

  double rate(GroupStat g) => g.correct / g.attempts;
  int byRate(GroupStat a, GroupStat b) {
    final r = rate(a).compareTo(rate(b));
    if (r != 0) return r;
    final byCount = b.attempts.compareTo(a.attempts);
    return byCount != 0 ? byCount : a.label.compareTo(b.label);
  }

  final trend = [...exams]..sort((a, b) => a.finishedAt.compareTo(b.finishedAt));

  return BankReport(
    totalQuestions: questions.length,
    answeredQuestions: perQuestion.length,
    latestCorrect: latest.values.where((v) => v).length,
    wrongBook: questions.where((q) => wrongIds.contains(q.id)).length,
    attempts: total.attempts,
    correct: total.correct,
    accuracy: total.percent,
    practiceMs: practiceMs,
    reviewMs: reviewMs,
    streakDays: streak,
    daily: daily.sublist(23),
    daily30: daily,
    examTrend: [
      for (final e in trend.length > 20 ? trend.sublist(trend.length - 20) : trend)
        ExamPoint(finishedAt: e.finishedAt, percent: e.percent, passed: e.passed),
    ],
    byType: types.values.toList()..sort((a, b) => a.key.compareTo(b.key)),
    byDifficulty: difficulties.values.toList()..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key))),
    byTag: tags.values.toList()..sort(byRate),
    byTagMerged: mergedTags.values.toList()..sort(byRate),
    weakest: [for (final w in scored) w.weak],
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

/// The same as [formatDuration], split into number and unit for a big figure: 1 + 小时, 5 + 分.
List<({String v, String u})> durationParts(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 1) return [(v: ms > 0 ? '<1' : '0', u: '分钟')];
  if (minutes < 60) return [(v: '$minutes', u: '分钟')];
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? [(v: '$h', u: '小时')] : [(v: '$h', u: '小时'), (v: '$m', u: '分')];
}

/// Minutes only, for the label over a day's bar: "12分" / "<1分".
String formatMinutes(int ms) {
  if (ms <= 0) return '';
  final m = (ms / 60000).round();
  return m < 1 ? '<1分' : '$m分';
}
