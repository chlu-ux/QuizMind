import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';
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
      documentId: '',
      documentTitle: '',
      documentOrder: 0,
      syncSeq: 1,
      hidden: false,
    );

// Local noon, so day arithmetic never lands on a boundary.
DateTime noon(int y, int m, int d) => DateTime(y, m, d, 12);
final now = noon(2026, 10, 3);
DateTime day(int back) => noon(2026, 10, 3 - back);

var _n = 0;
Attempt at(String questionId, bool ok, DateTime when, {int? ms = 1000, int? review}) => Attempt(
      id: 'a${_n++}',
      questionId: questionId,
      deviceId: 'd',
      answerJson: '[0]',
      isCorrect: ok,
      durationMs: ms,
      reviewMs: review,
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

  test('splits answering from reading, caps each, and totals both as study time', () {
    final r = buildReport(
      [q('a'), q('b')],
      [
        at('a', true, now, ms: 30000, review: 45000),
        at('b', true, now, ms: 10 * 60000, review: 20 * 60000), // page left open: 2 min + 3 min
        at('a', true, now, ms: 5000), // an older attempt without review time
      ],
      {},
      now,
    );
    expect(r.practiceMs, 30000 + 120000 + 5000);
    expect(r.reviewMs, 45000 + 180000);
    expect(r.studyMs, r.practiceMs + r.reviewMs);
  });

  test('attributes time to the day of the answer', () {
    final r = buildReport(
      [q('a')],
      [at('a', true, now, ms: 10000, review: 5000), at('a', false, day(1), ms: 20000, review: 15000)],
      {},
      now,
    );
    expect([for (final d in r.daily.skip(5)) (d.practiceMs, d.reviewMs)], [(20000, 15000), (10000, 5000)]);
    expect(r.daily30.first.studyMs, 0);
    expect(r.daily30.fold<int>(0, (n, d) => n + d.practiceMs), r.practiceMs);
  });

  test('durationParts and formatMinutes', () {
    expect(durationParts(0), [(v: '0', u: '分钟')]);
    expect(durationParts(20000), [(v: '<1', u: '分钟')]);
    expect(durationParts(12 * 60000), [(v: '12', u: '分钟')]);
    expect(durationParts(65 * 60000), [(v: '1', u: '小时'), (v: '5', u: '分')]);
    expect(durationParts(120 * 60000), [(v: '2', u: '小时')]);
    expect(formatMinutes(0), '');
    expect(formatMinutes(10000), '<1分');
    expect(formatMinutes((12.4 * 60000).round()), '12分');
  });

  test('formatDuration reads naturally', () {
    expect(formatDuration(20000), '不到 1 分钟');
    expect(formatDuration(12 * 60000), '12 分钟');
    expect(formatDuration(65 * 60000), '1 小时 5 分');
    expect(formatDuration(120 * 60000), '2 小时');
  });

  group('longer views and ranking', () {
    test('has a 30-day series whose last 7 entries are the weekly one', () {
      final r = buildReport(
        [q('a')],
        [at('a', true, day(0)), at('a', false, day(12)), at('a', true, day(29)), at('a', true, day(30))],
        {},
        now,
      );
      expect(r.daily30, hasLength(30));
      expect(r.daily30.last.label, '10/3');
      expect(r.daily30.first.label, '9/4');
      expect(r.daily30.first.attempts, 1);
      expect(r.daily30[17].label, '9/21');
      expect([r.daily30[17].attempts, r.daily30[17].correct], [1, 0]);
      expect(r.daily30.fold<int>(0, (n, d) => n + d.attempts), 3, reason: 'day 30 is outside the window');
      expect(r.daily.map((d) => d.label), r.daily30.skip(23).map((d) => d.label));
    });

    test('turns exam records into a trend, oldest first, latest 20', () {
      ExamRecord exam(int i, int percent) => ExamRecord(
            id: 'e$i', bankId: 'b1', title: 't', finishedAt: 1000 + i, total: 10, correct: percent ~/ 10, answered: 10,
            percent: percent, passed: percent >= 60, limitSec: null, usedMs: 1,
          );
      final exams = [for (var i = 24; i >= 0; i--) exam(i, (i % 10) * 10 + 5)]; // newest first, as the repository returns them
      final r = buildReport([q('a')], [], {}, now, exams: exams);
      expect(r.examTrend, hasLength(20));
      expect(r.examTrend.first.finishedAt, 1005);
      expect([r.examTrend.last.finishedAt, r.examTrend.last.percent, r.examTrend.last.passed], [1024, 45, false]);
      expect(buildReport([q('a')], [], {}, now).examTrend, isEmpty);
    });

    test('does not rank a single miss above a question missed 3 times in 5', () {
      final r = buildReport(
        [q('once'), q('often'), q('twice')],
        [
          at('once', false, now.subtract(const Duration(milliseconds: 100))),
          for (final (i, ok) in [false, true, false, true, false].indexed)
            at('often', ok, now.subtract(Duration(milliseconds: 90 - i))),
          at('twice', false, now.subtract(const Duration(milliseconds: 50))),
          at('twice', false, now.subtract(const Duration(milliseconds: 49))),
        ],
        {},
        now,
      );
      expect([for (final w in r.weakest) '${w.question.id} ${w.wrong}/${w.attempts}'], ['twice 2/2', 'often 3/5', 'once 1/1']);
    });

    test('judges weakness by the latest answers only: an old miss that has been fixed drops out', () {
      final fixed = [for (final (i, ok) in [false, false, false, true, true, true, true, true].indexed) at('a', ok, now.subtract(Duration(milliseconds: 1000 - i)))];
      expect(buildReport([q('a')], fixed, {}, now).weakest, isEmpty);
      final mixed = [for (final (i, ok) in [true, true, true, true, true, false].indexed) at('a', ok, now.subtract(Duration(milliseconds: 1000 - i)))];
      final w = buildReport([q('a')], mixed, {}, now).weakest.single;
      expect([w.wrong, w.attempts], [1, 5]);
    });

    test('folds tag spellings, and in merged view joins related tags', () {
      final qs = [
        q('a', tags: ['UML']),
        q('b', tags: ['UML 辨析', 'uml']),
        q('c', tags: ['Cache']),
        q('d', tags: ['cache ']),
        q('e', tags: ['OSI']),
        q('f', tags: ['OS']),
      ];
      final attempts = [for (final (i, x) in qs.indexed) at(x.id, i.isEven, now.subtract(Duration(milliseconds: i)))];
      final r = buildReport(qs, attempts, {}, now);
      List<String> names(List<GroupStat> g) => g.map((x) => x.label.toLowerCase()).toList()..sort();
      expect(names(r.byTag), ['cache', 'os', 'osi', 'uml', 'uml 辨析']);
      expect(names(r.byTagMerged), ['cache', 'os', 'osi', 'uml']);
      expect(r.byTagMerged.firstWhere((g) => g.label.toLowerCase() == 'uml').attempts, 2,
          reason: 'question b has two tags in the UML group but counts once');
    });
  });
}
