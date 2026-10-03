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

Future<({AppDatabase db, Repository repo, ExamStore store, ExamSession exam, _Clock clock})> setup(
  int n, {
  int? limitSec,
}) async {
  SharedPreferences.setMockInitialValues({});
  final db = memoryDb();
  addTearDown(db.close);
  final qs = await seed(db, n);
  final clock = _Clock();
  final repo = Repository(db, deviceId: 'd', clock: clock.call);
  final store = ExamStore(await SharedPreferences.getInstance());
  final exam = ExamSession(
    bankId: 'b1',
    title: '题库',
    questions: qs,
    repo: repo,
    store: store,
    limitSec: limitSec,
    clock: clock.call,
    seed: 5,
  );
  addTearDown(exam.dispose);
  return (db: db, repo: repo, store: store, exam: exam, clock: clock);
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
    expect(s.store.history('b1'), isEmpty);
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
    expect(r.items.map((i) => i.correct), [true, false, false, true]);
    expect(r.items[2].selected, isEmpty);
    expect(s.exam.submitted, isTrue);

    final attempts = (await s.db.select(s.db.attempts).get())..sort((a, b) => a.questionId.compareTo(b.questionId));
    expect(attempts.map((a) => [a.questionId, a.isCorrect, a.durationMs]), [
      ['q1', true, 5000],
      ['q2', false, 7000],
      ['q4', true, 3000],
    ]);
    expect((await s.repo.watchWrongBook().first).map((q) => q.id), ['q2'], reason: 'exam misses feed the wrong book');
    expect(s.store.history('b1').single.percent, 50);
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
    expect(s.store.history('b1'), hasLength(1));
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
    expect(r.items.single.correct, isTrue);
    expect((await s.db.select(s.db.attempts).get()).single.answerJson, '[1]');
  });

  test('ExamStore keeps the newest records per bank and survives unreadable data', () async {
    SharedPreferences.setMockInitialValues({'exam.history.b1': 'not json'});
    final store = ExamStore(await SharedPreferences.getInstance());
    expect(store.history('b1'), isEmpty);
    ExamRecord rec(int i, String bank) => ExamRecord(
          id: 'e$i',
          bankId: bank,
          title: 't',
          finishedAt: i,
          total: 10,
          correct: 5,
          answered: 10,
          percent: 50,
          passed: false,
          limitSec: null,
          usedMs: 1,
        );
    for (var i = 0; i < ExamStore.keep + 5; i++) {
      await store.add(rec(i, 'b1'));
    }
    await store.add(rec(0, 'b2'));
    final h = store.history('b1');
    expect(h, hasLength(ExamStore.keep));
    expect(h.first.id, 'e${ExamStore.keep + 4}');
    expect(store.history('b2'), hasLength(1));
  });

  test('constructor rejects an empty paper', () async {
    final s = await setup(1);
    expect(
      () => ExamSession(bankId: 'b', title: 't', questions: const [], repo: s.repo, store: s.store),
      throwsA(isA<AssertionError>()),
    );
  });
}
