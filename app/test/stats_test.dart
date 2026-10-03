import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/stats.dart';

Question q(String id, {String type = 'single', int difficulty = 2, List<String> tags = const []}) => Question(
      id: id,
      bankId: 'b1',
      type: type,
      stem: id,
      optionsJson: '["A","B","C","D"]',
      answerJson: '[1]',
      explanation: '',
      difficulty: difficulty,
      tagsJson: '[${tags.map((t) => '"$t"').join(',')}]',
      sourceQuote: '',
      syncSeq: 1,
      hidden: false,
    );

// Local noon, so day arithmetic never lands on a boundary.
DateTime noon(int y, int m, int d) => DateTime(y, m, d, 12);
final now = noon(2026, 10, 3);
DateTime day(int back) => noon(2026, 10, 3 - back);

var _n = 0;
Attempt at(String questionId, bool ok, DateTime when, {int? ms = 1000}) => Attempt(
      id: 'a${_n++}',
      questionId: questionId,
      deviceId: 'd',
      answerJson: '[0]',
      isCorrect: ok,
      durationMs: ms,
      answeredAt: when.millisecondsSinceEpoch,
      synced: true,
    );

void main() {
  test('is empty and has no accuracy before any attempt', () {
    final r = buildReport([q('a'), q('b')], [], {}, now);
    expect(r.totalQuestions, 2);
    expect(r.attempts, 0);
    expect(r.accuracy, isNull);
    expect(r.answeredQuestions, 0);
    expect(r.streakDays, 0);
    expect(r.weakest, isEmpty);
    expect(r.daily, hasLength(7));
    expect(r.daily.last.label, '10/3');
    expect(r.daily.first.label, '9/27');
  });

  test('separates attempt accuracy from the latest result per question', () {
    final r = buildReport(
      [q('a'), q('b'), q('c')],
      [
        at('a', false, now.subtract(const Duration(seconds: 3))),
        at('a', true, now.subtract(const Duration(seconds: 2))),
        at('b', false, now.subtract(const Duration(seconds: 1))),
      ],
      {'b'},
      now,
    );
    expect([r.attempts, r.correct, r.accuracy], [3, 1, 33]);
    expect(r.answeredQuestions, 2);
    expect(r.latestCorrect, 1); // a: last attempt right; b: wrong
    expect(r.wrongBook, 1);
  });

  test('ignores attempts at questions that are not in the list', () {
    final r = buildReport([q('a')], [at('a', true, now), at('gone', false, now)], {}, now);
    expect(r.attempts, 1);
    expect(r.accuracy, 100);
  });

  test('groups by type, difficulty and knowledge point, weakest point first', () {
    final r = buildReport(
      [
        q('a', difficulty: 1, tags: ['锁', '并发']),
        q('b', difficulty: 3, type: 'judge', tags: ['锁']),
      ],
      [at('a', true, now), at('b', false, now), at('b', false, now)],
      {},
      now,
    );
    expect(r.byType.map((g) => [g.label, g.attempts, g.correct]), [
      ['判断题', 2, 0],
      ['单选题', 1, 1],
    ]);
    expect(r.byDifficulty.map((g) => g.label), ['难度 1', '难度 3']);
    // 锁: 1 of 3 right; 并发: 1 of 1.
    expect(r.byTag.map((g) => [g.label, g.percent]), [
      ['锁', 33],
      ['并发', 100],
    ]);
  });

  test('buckets the last 7 days; older attempts still count overall', () {
    final r = buildReport(
      [q('a')],
      [at('a', true, day(0)), at('a', false, day(0)), at('a', true, day(6)), at('a', true, day(7))],
      {},
      now,
    );
    expect([r.daily.last.label, r.daily.last.attempts, r.daily.last.correct], ['10/3', 2, 1]);
    expect([r.daily.first.label, r.daily.first.attempts, r.daily.first.correct], ['9/27', 1, 1]);
    expect(r.attempts, 4);
  });

  test('counts the study streak, keeping it alive through a day without practice yet', () {
    int run(List<int> backs) => buildReport([q('a')], [for (final b in backs) at('a', true, day(b))], {}, now).streakDays;
    expect(run([0, 1, 2, 4]), 3); // gap at day 3
    expect(run([1, 2]), 2); // nothing yet today
    expect(run([2, 3]), 0); // yesterday missed: streak is over
  });

  test('lists the most-missed questions first and caps long study times', () {
    final r = buildReport(
      [q('a'), q('b'), q('c')],
      [
        at('a', false, now, ms: 1000),
        at('a', true, now, ms: 1000),
        at('b', false, now, ms: 60000),
        at('b', false, now, ms: 10 * 60000), // left open: counts as 2 minutes
        at('c', true, now, ms: null),
      ],
      {},
      now,
    );
    expect(r.weakest.map((w) => [w.question.id, w.wrong, w.attempts]), [
      ['b', 2, 2],
      ['a', 1, 2],
    ]);
    expect(r.studyMs, 1000 + 1000 + 60000 + 120000);
  });

  test('formatDuration reads naturally', () {
    expect(formatDuration(20000), '不到 1 分钟');
    expect(formatDuration(12 * 60000), '12 分钟');
    expect(formatDuration(65 * 60000), '1 小时 5 分');
    expect(formatDuration(120 * 60000), '2 小时');
  });
}
