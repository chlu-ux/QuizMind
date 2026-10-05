import '../../data/database.dart';
import '../../data/progress.dart'; // Question.tags
import '../../data/tags.dart';

/// The tag a question is filed under, the same way the stats page and the exam paper do it:
/// [merged] folds near-duplicates into their shorter tag ("UML 辨析" into "UML"), otherwise only
/// case, width and spacing are folded. All three places use [tagLabeler] over the bank's questions,
/// so a label seen on one of them names the same set of questions on the others.
Set<String> Function(Question) _labelsOf(List<Question> qs, bool merged) {
  final label = tagLabeler([for (final q in qs) ...q.tags], merge: merged);
  return (q) => {...q.tags.map(label)};
}

/// The questions filed under [label], in the order of [qs]. A question with several tags shows up once.
List<Question> topicQuestions(List<Question> qs, String label, {required bool merged}) {
  final of = _labelsOf(qs, merged);
  return [for (final q in qs) if (of(q).contains(label)) q];
}

class TopicSummary {
  TopicSummary(this.label);

  final String label;
  int count = 0;

  /// Questions of the topic answered at least once.
  int answered = 0;

  /// Questions of the topic answered wrongly at least once, however they went since.
  int missed = 0;
  int attempts = 0;
  int correct = 0;

  /// Share of the topic's attempts that were right, 0-100; null if it was never answered.
  int? get accuracy => attempts == 0 ? null : (correct * 100 / attempts).round();
}

/// Every knowledge point of [qs], biggest first, with how it has gone. Attempts for other questions are ignored.
List<TopicSummary> topicSummary(List<Question> qs, List<Attempt> attempts, {required bool merged}) {
  final of = _labelsOf(qs, merged);
  final byQuestion = <String, ({int attempts, int correct})>{};
  for (final a in attempts) {
    final t = byQuestion[a.questionId] ?? (attempts: 0, correct: 0);
    byQuestion[a.questionId] = (attempts: t.attempts + 1, correct: t.correct + (a.isCorrect ? 1 : 0));
  }
  final rows = <String, TopicSummary>{};
  for (final q in qs) {
    final t = byQuestion[q.id];
    for (final label in of(q)) {
      final r = rows.putIfAbsent(label, () => TopicSummary(label));
      r.count++;
      if (t == null) continue;
      r.answered++;
      if (t.correct < t.attempts) r.missed++;
      r.attempts += t.attempts;
      r.correct += t.correct;
    }
  }
  return rows.values.toList()
    ..sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : a.label.compareTo(b.label));
}

/// Which questions of a topic to practise: all, only those never answered, or only those once answered wrongly.
enum TopicFilter { all, unanswered, missed }

/// How many questions of [t] the [filter] leaves.
int topicAvailable(TopicSummary t, TopicFilter filter) => switch (filter) {
      TopicFilter.all => t.count,
      TopicFilter.unanswered => t.count - t.answered,
      TopicFilter.missed => t.missed,
    };

/// [qs] narrowed by [filter], judged from [attempts].
List<Question> applyTopicFilter(List<Question> qs, List<Attempt> attempts, TopicFilter filter) {
  if (filter == TopicFilter.all) return qs;
  final seen = <String>{};
  final wrong = <String>{};
  for (final a in attempts) {
    seen.add(a.questionId);
    if (!a.isCorrect) wrong.add(a.questionId);
  }
  return [
    for (final q in qs)
      if (filter == TopicFilter.unanswered ? !seen.contains(q.id) : wrong.contains(q.id)) q,
  ];
}
