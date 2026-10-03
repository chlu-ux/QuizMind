import 'dart:math';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/exam_store.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/features/exam/exam_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Future<List<Question>> seed(AppDatabase db, int n) async {
  for (var i = 1; i <= n; i++) {
    await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: 'q$i',
          bankId: 'b1',
          type: 'single',
          stem: '题干 q$i',
          optionsJson: '["甲","乙","丙","丁"]',
          answerJson: '[1]',
          explanation: const Value('解析'),
          syncSeq: i,
        ));
  }
  return (db.select(db.questions)..orderBy([(q) => OrderingTerm.asc(q.syncSeq)])).get();
}

class _Clock {
  var t = DateTime(2026, 10, 3, 12);
  DateTime call() => t;
  void tick(int ms) => t = t.add(Duration(milliseconds: ms));
}

Future<({AppDatabase db, Repository repo, ExamSession exam, _Clock clock})> setup(
  int n, {
  int? limitSec,
}) async {
  SharedPreferences.setMockInitialValues({});
  final db = memoryDb();
  addTearDown(db.close);
  final qs = await seed(db, n);
  final clock = _Clock();
  final repo = Repository(db, deviceId: 'd', clock: clock.call);
  final exam = ExamSession(
    bankId: 'b1',
    title: '题库',
    questions: qs,
    repo: repo,
    limitSec: limitSec,
    clock: clock.call,
    seed: 5,
  );
  addTearDown(exam.dispose);
  return (db: db, repo: repo, exam: exam, clock: clock);
}

void main() {
  test('examCountChoices offers presets below the bank size plus "all"', () {
    expect(examCountChoices(5), [5]);
    expect(examCountChoices(10), [10]);
    expect(examCountChoices(35), [10, 20, 35]);
    expect(examCountChoices(500), [10, 20, 50, 100, 500]);
  });

  test('drawExam picks distinct questions and never more than exist', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final qs = await seed(db, 5);
    expect(drawExam(qs, 3, rng: Random(1)).map((q) => q.id).toSet(), hasLength(3));
    expect(drawExam(qs, 99), hasLength(5));
    expect(drawExam(qs, 0), isEmpty);
    expect(qs.map((q) => q.id), ['q1', 'q2', 'q3', 'q4', 'q5'], reason: 'input untouched');
  });

  test('records nothing until the paper is handed in, and lets answers change', () async {
    final s = await setup(4);
    s.exam.select(0);
    s.exam.select(1); // changed their mind
    expect(s.exam.selected, [1]);
    s.exam.next();
    s.exam.select(1);
    expect(s.exam.answeredCount, 2);
    expect(await s.db.select(s.db.attempts).get(), isEmpty);
    expect(await s.repo.exams('b1'), isEmpty);
  });

  test('grades on submit, counts blanks as wrong, writes attempts, states and the exam record', () async {
    final s = await setup(4);
    s.exam.select(1); // q1 right
    s.clock.tick(5000);
    s.exam.go(1);
    s.exam.select(0); // q2 wrong
    s.clock.tick(7000);
    s.exam.go(3); // q3 left blank, q4 right
    s.exam.select(1);
    s.clock.tick(3000);

    final r = await s.exam.submit();
    expect([r.record.total, r.record.correct, r.record.answered, r.record.percent], [4, 2, 3, 50]);
    expect(r.record.passed, isFalse);
    expect(r.record.usedMs, 15000);
    expect(r.entries.map((i) => i.correct), [true, false, false, true]);
    expect(r.entries[2].selected, isEmpty);
    expect(s.exam.submitted, isTrue);

    final attempts = (await s.db.select(s.db.attempts).get())..sort((a, b) => a.questionId.compareTo(b.questionId));
    expect(attempts.map((a) => [a.questionId, a.isCorrect, a.durationMs]), [
      ['q1', true, 5000],
      ['q2', false, 7000],
      ['q4', true, 3000],
    ]);
    expect((await s.repo.watchWrongBook().first).map((q) => q.id), ['q2'], reason: 'exam misses feed the wrong book');
    final saved = (await s.repo.exams('b1')).single;
    expect(saved.percent, 50);
    expect([for (final it in saved.items) '${it.questionId} ${it.selected} ${it.correct}'], [
      'q1 [1] true',
      'q2 [0] false',
      'q3 [] false',
      'q4 [1] true',
    ]);
    expect(saved.deviceId, 'd');
    expect((await s.db.select(s.db.exams).get()).single.synced, isFalse, reason: 'waiting for upload');
  });

  test('passes at the pass line', () async {
    final s = await setup(5);
    for (var i = 0; i < 5; i++) {
      s.exam.go(i);
      s.exam.select(i < 3 ? 1 : 0); // 3 of 5 right = 60%
    }
    final r = await s.exam.submit();
    expect(r.record.percent, passPercent);
    expect(r.record.passed, isTrue);
  });

  test('submitting twice grades once and returns the same result', () async {
    final s = await setup(2);
    s.exam.select(1);
    final results = await Future.wait([s.exam.submit(), s.exam.submit()]);
    expect(results[1], same(results[0]));
    expect(await s.exam.submit(), same(results[0]));
    expect(await s.db.select(s.db.attempts).get(), hasLength(1));
    expect(await s.repo.exams('b1'), hasLength(1));
    s.exam.select(0); // locked after submit
    expect(s.exam.selected, [1]);
  });

  test('counts the time down and floors at zero', () async {
    final s = await setup(1, limitSec: 60);
    expect(s.exam.remainingSec(), 60);
    s.clock.tick(15500);
    expect(s.exam.remainingSec(), 45);
    s.clock.tick(120000);
    expect(s.exam.remainingSec(), 0);
  });

  test('an untimed exam has no clock', () async {
    expect((await setup(1)).exam.remainingSec(), isNull);
  });

  test('grades original indexes whatever order the options are shown in', () async {
    final s = await setup(1);
    final shown = s.exam.displayOptions;
    expect(shown.map((o) => o.text).toList()..sort(), ['丁', '丙', '乙', '甲']);
    final right = shown.indexWhere((o) => o.original == 1);
    s.exam.selectAt(right);
    expect(s.exam.selected, [1]);
    expect(s.exam.labelOf(1), String.fromCharCode(65 + right));
    final r = await s.exam.submit();
    expect(r.entries.single.correct, isTrue);
    expect((await s.db.select(s.db.attempts).get()).single.answerJson, '[1]');
  });

  test('constructor rejects an empty paper', () async {
    final s = await setup(1);
    expect(
      () => ExamSession(bankId: 'b', title: 't', questions: const [], repo: s.repo),
      throwsA(isA<AssertionError>()),
    );
  });

  group('paper building', () {
    Question tq(String id, List<String> tags, {int difficulty = 2}) => Question(
          id: id,
          bankId: 'b1',
          type: 'single',
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
    final bank = [
      tq('a1', ['UML'], difficulty: 1),
      tq('a2', ['UML 辨析'], difficulty: 2),
      tq('a3', ['范式'], difficulty: 3),
      tq('a4', ['范式', 'SQL'], difficulty: 3),
      tq('a5', ['SQL'], difficulty: 4),
      tq('a6', ['SQL'], difficulty: 5),
    ];
    Set<String> ids(Iterable<Question> qs) => qs.map((q) => q.id).toSet();

    test('limits the pool to the chosen knowledge points, merged tags included', () {
      final tags = paperTags(bank);
      expect(tags.first, (label: 'SQL', count: 3));
      expect({for (final t in tags.skip(1)) (t.label, t.count)}, {('UML', 2), ('范式', 2)});
      expect(paperPool(bank).length, 6);
      expect(ids(paperPool(bank, ['UML'])), {'a1', 'a2'});
      expect(ids(paperPool(bank, ['UML', '范式'])), {'a1', 'a2', 'a3', 'a4'});
    });

    test('random draws only from the pool and never repeats', () {
      final got = drawPaper(bank, 10, tags: ['SQL'], rng: Random(1));
      expect(ids(got), {'a4', 'a5', 'a6'});
      expect(got, hasLength(3));
    });

    test('weak mode takes last-wrong and wrong-book questions first, then untried, then the rest', () {
      const history = {
        'a1': QuestionHistory(attempts: 2, lastCorrect: true),
        'a2': QuestionHistory(attempts: 1, lastCorrect: false),
        'a3': QuestionHistory(attempts: 3, lastCorrect: true),
      };
      for (final seed in [1, 2, 3]) {
        List<Question> draw(int n) => drawPaper(
              bank,
              n,
              strategy: PaperStrategy.weak,
              history: history,
              wrongIds: {'a3'},
              rng: Random(seed),
            );
        expect(ids(draw(2)), {'a2', 'a3'});
        final four = ids(draw(4));
        expect(four, containsAll(['a2', 'a3']));
        expect(four, isNot(contains('a1')), reason: 'done and right comes last');
      }
      expect(drawPaper(bank, 6, strategy: PaperStrategy.weak, history: history, rng: Random(1)), hasLength(6));
    });

    test('balanced mode mixes easy, medium and hard about 4:4:2 and tops up from what is left', () {
      final big = [
        for (var i = 0; i < 30; i++) tq('e$i', [], difficulty: 1),
        for (var i = 0; i < 30; i++) tq('m$i', [], difficulty: 3),
        for (var i = 0; i < 30; i++) tq('h$i', [], difficulty: 5),
      ];
      final got = drawPaper(big, 10, strategy: PaperStrategy.balanced, rng: Random(1));
      int by(String p) => got.where((q) => q.id.startsWith(p)).length;
      expect([by('e'), by('m'), by('h')], [4, 4, 2]);

      final few = big.where((q) => !q.id.startsWith('h') || q.id == 'h0').toList();
      final got2 = drawPaper(few, 10, strategy: PaperStrategy.balanced, rng: Random(1));
      expect(got2, hasLength(10));
      expect(ids(got2), hasLength(10));
      expect(got2.where((q) => q.id.startsWith('h')), hasLength(1));
    });
  });

  group('exam in progress', () {
    Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('saves after every change and is gone once handed in', () async {
      final s = await setup(3, limitSec: 600);
      s.exam.save();
      s.exam.select(1);
      s.clock.tick(4000);
      s.exam.go(2);
      s.exam.toggleMark();
      await flush();
      final d = (await s.repo.examDraft('b1'))!;
      expect([d.ids, d.index, d.limitSec], [['q1', 'q2', 'q3'], 2, 600]);
      expect(d.answers, {'q1': [1]});
      expect(d.marked, ['q3']);
      expect(d.spent['q1'], 4000);

      await s.exam.submit();
      expect(await s.repo.examDraft('b1'), isNull);
    });

    test('restores answers, marks, position and the running clock', () async {
      final s = await setup(3, limitSec: 600);
      final qs = s.exam.questions;
      s.exam.select(1);
      s.clock.tick(90000);
      s.exam.go(1);
      s.exam.toggleMark();
      final draft = s.exam.snapshot();

      s.clock.tick(30000); // away for 30 s
      final back = ExamSession.restore(draft, qs, s.repo, clock: s.clock.call)!;
      expect(back.index, 1);
      expect(back.isAnswered(0), isTrue);
      expect(back.isMarked(1), isTrue);
      expect(back.remainingSec(), 600 - 120, reason: '90 s + 30 s since the original start');
      expect(back.seed, s.exam.seed);
      expect(back.displayOptions.map((o) => o.original), s.exam.displayOptions.map((o) => o.original));

      back.go(2);
      back.select(1);
      final r = await back.submit();
      expect([r.record.correct, r.record.answered], [2, 2]);
      expect(r.record.usedMs, 120000, reason: 'timed: wall clock since the start');
      back.dispose();
    });

    test('drops withdrawn questions on restore', () async {
      final s = await setup(3);
      final qs = s.exam.questions;
      s.exam.go(2);
      s.exam.select(1);
      final draft = s.exam.snapshot();
      final some = ExamSession.restore(draft, [qs[0], qs[2]], s.repo)!; // q2 withdrawn
      expect(some.questions.map((q) => q.id), ['q1', 'q3']);
      expect(some.current.id, 'q3');
      expect(some.selected, [1]);
      expect(ExamSession.restore(draft, const [], s.repo), isNull);
      some.dispose();
    });

    test('counts only active time for an untimed exam', () async {
      final s = await setup(2);
      final qs = s.exam.questions;
      s.exam.select(1);
      s.clock.tick(10000);
      final draft = s.exam.snapshot();
      s.clock.tick(3600000); // an hour away
      final back = ExamSession.restore(draft, qs, s.repo, clock: s.clock.call)!;
      s.clock.tick(5000);
      expect((await back.submit()).record.usedMs, 15000);
      back.dispose();
    });

    test('marks toggle and are locked after hand-in', () async {
      final s = await setup(2);
      expect(s.exam.markedCount, 0);
      s.exam.toggleMark();
      expect(s.exam.markedCount, 1);
      s.exam.toggleMark();
      expect(s.exam.isMarked(0), isFalse);
      await s.exam.submit();
      s.exam.toggleMark();
      expect(s.exam.markedCount, 0);
    });

    test('handing in is all or nothing: a failure leaves no attempts, exam or lost draft, and a retry works', () async {
      final s = await setup(3);
      s.exam.select(1);
      s.exam.go(1);
      s.exam.select(0);
      s.exam.save();
      await flush();
      expect(await s.db.select(s.db.examDrafts).get(), hasLength(1));

      // Make the hand-in fail after the answers were written: the exam row collides with an existing id.
      // (The exam id is a fresh ULID, so plant a trigger that rejects any insert instead.)
      await s.db.customStatement('CREATE TRIGGER no_exams BEFORE INSERT ON exams BEGIN SELECT RAISE(ABORT, \'disk full\'); END');
      await expectLater(s.exam.submit(), throwsA(anything));
      expect(await s.db.select(s.db.attempts).get(), isEmpty);
      expect(await s.db.select(s.db.questionStates).get(), isEmpty);
      expect(await s.db.select(s.db.exams).get(), isEmpty);
      expect(await s.db.select(s.db.examDrafts).get(), hasLength(1));
      expect(s.exam.submitted, isFalse);

      await s.db.customStatement('DROP TRIGGER no_exams');
      final r = await s.exam.submit();
      expect(r.record.answered, 2);
      expect(await s.db.select(s.db.attempts).get(), hasLength(2));
      expect(await s.db.select(s.db.exams).get(), hasLength(1));
      expect(await s.db.select(s.db.examDrafts).get(), isEmpty);
    });
  });

  test('exam results left in shared preferences by older versions are moved into the database', () async {
    SharedPreferences.setMockInitialValues({
      'exam.history.b1':
          '[{"id":"E1","bank":"b1","title":"题库","at":100,"total":10,"correct":6,"answered":10,"percent":60,"passed":true,"limit":null,"used":1000}]',
      'exam.history.b2': 'not json',
      'unrelated': 'x',
    });
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    addTearDown(db.close);
    final repo = Repository(db, deviceId: 'd');
    expect(await importLegacyExams(prefs, repo), 1);
    final e = (await repo.exams('b1')).single;
    expect([e.id, e.percent, e.passed, e.items], ['E1', 60, true, isEmpty]);
    expect((await db.select(db.exams).get()).single.synced, isFalse, reason: 'queued for upload');
    expect(prefs.getKeys(), {'unrelated'});
    expect(await importLegacyExams(prefs, repo), 0, reason: 'nothing left to move');
  });
}
