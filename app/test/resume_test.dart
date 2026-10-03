import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/session_store.dart';
import 'package:quizmind_app/features/quiz/quiz_page.dart';
import 'package:quizmind_app/features/quiz/quiz_session.dart';
import 'package:quizmind_app/features/quiz/resume.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// Inserts [n] single-choice questions whose right answer is option 1 (乙), and
/// one judge question when [judge] is set.
Future<List<Question>> seed(AppDatabase db, int n, {bool judge = false}) async {
  for (var i = 1; i <= n; i++) {
    final q = question('q$i', seq: i, answer: 1);
    await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: q.id,
          bankId: q.bankId,
          type: q.type,
          stem: q.stem,
          optionsJson: '["甲","乙","丙","丁"]',
          answerJson: '[1]',
          explanation: Value(q.explanation),
          sourceQuote: Value(q.sourceQuote),
          syncSeq: q.syncSeq,
        ));
  }
  if (judge) {
    final q = question('j1', seq: n + 1, type: 'judge');
    await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: q.id,
          bankId: q.bankId,
          type: 'judge',
          stem: q.stem,
          optionsJson: '["正确","错误"]',
          answerJson: '[0]',
          syncSeq: q.syncSeq,
        ));
  }
  return (db.select(db.questions)..orderBy([(q) => OrderingTerm.asc(q.syncSeq)])).get();
}

Future<SessionStore> newStore() async {
  SharedPreferences.setMockInitialValues({});
  return SessionStore(await SharedPreferences.getInstance());
}

void main() {
  group('option order', () {
    test('is a permutation that depends only on the seed and the question', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final q = (await seed(db, 1)).single;
      final a = optionOrder(q, 7);
      expect([...a]..sort(), [0, 1, 2, 3]);
      expect(optionOrder(q, 7), a, reason: 'same seed, same layout');
      final layouts = {for (var s = 0; s < 30; s++) optionOrder(q, s).join()};
      expect(layouts.length, greaterThan(1), reason: 'different seeds shuffle differently');
    });

    test('judge questions keep their fixed order', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final j = (await seed(db, 0, judge: true)).single;
      for (var s = 0; s < 10; s++) {
        expect(optionOrder(j, s), [0, 1]);
      }
    });

    test('selecting by shown position grades the original option', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final qs = await seed(db, 1);
      final session = QuizSession(title: 't', questions: qs, repo: Repository(db, deviceId: 'd'), seed: 3);
      final shown = session.displayOptions;
      final position = shown.indexWhere((o) => o.original == 1);
      expect(shown[position].text, '乙');
      expect(session.labelOf(1), String.fromCharCode(65 + position));

      session.selectAt(position);
      expect(session.selected, [1], reason: 'stored by original index');
      await session.submit();
      expect(session.outcome!.correct, isTrue);
    });
  });

  group('SessionStore', () {
    test('round-trips a session and clears it', () async {
      final store = await newStore();
      expect(store.load('b1'), isNull);

      await store.start('b1', title: '题库', ids: ['a', 'b', 'c'], seed: 42, index: 1);
      await store.saveProgress('b1', index: 2, answers: {
        'a': (selected: [1], correct: true),
        'b': (selected: [0], correct: false),
      });
      final s = store.load('b1')!;
      expect((s.title, s.seed, s.index), ('题库', 42, 2));
      expect(s.ids, ['a', 'b', 'c']);
      expect(s.answered, 2);
      expect(s.answers['b']!.selected, [0]);
      expect(s.answers['b']!.correct, isFalse);
      expect(s.answers['a']!.correct, isTrue);
      expect(store.load('other'), isNull, reason: 'scoped per bank');

      await store.clear('b1');
      expect(store.load('b1'), isNull);
    });

    test('an unreadable record is dropped instead of crashing', () async {
      SharedPreferences.setMockInitialValues({'quiz.session.b1': 'not json', 'quiz.progress.b1': '{}'});
      final store = SessionStore(await SharedPreferences.getInstance());
      expect(store.load('b1'), isNull);
    });
  });

  group('planResume', () {
    test('drops withdrawn questions and keeps the position on the same question', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final repo = Repository(db, deviceId: 'd');
      final qs = await seed(db, 5);
      final byId = {for (final q in qs) q.id: q};
      await repo.recordAnswer(question: byId['q1']!, selected: [1], durationMs: 1);
      await repo.recordAnswer(question: byId['q2']!, selected: [0], durationMs: 1);

      final store = await newStore();
      await store.start('b1', title: '题库', ids: ['q1', 'q2', 'q3', 'q4', 'q5'], seed: 9, index: 3);
      await store.saveProgress('b1', index: 3, answers: {
        'q1': (selected: [1], correct: true),
        'q2': (selected: [0], correct: false),
      });

      await repo.flagQuestion('q2'); // hidden since the quiz was left
      final plan = (await planResume(store.load('b1')!, repo))!;

      expect(plan.questions.map((q) => q.id), ['q1', 'q3', 'q4', 'q5']);
      expect(plan.questions[plan.index].id, 'q4', reason: 'q4 was the current question');
      expect(plan.restored.keys, ['q1'], reason: 'q2 is gone');
      expect(plan.seed, 9);

      final session = QuizSession(
        title: plan.title,
        questions: plan.questions,
        repo: repo,
        startAt: plan.index,
        seed: plan.seed,
        restored: plan.restored,
      );
      expect((session.answeredCount, session.correctCount), (1, 1));
      session.previous();
      session.previous();
      expect(session.current.id, 'q1');
      expect(session.submitted, isTrue, reason: 'earlier result is shown again');
      expect(session.selected, [1]);
    });

    test('is null when nothing is left', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final repo = Repository(db, deviceId: 'd');
      await seed(db, 1);
      await repo.flagQuestion('q1');
      final store = await newStore();
      await store.start('b1', title: 't', ids: ['q1'], seed: 1, index: 0);
      expect(await planResume(store.load('b1')!, repo), isNull);
    });
  });

  testWidgets('QuizPage saves progress as it goes and resumes where it stopped', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 3)) as List<Question>;
    final store = SessionStore(prefs);

    Widget app(QuizPage page) => ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            apiProvider.overrideWithValue(FakeApi()),
          ],
          child: MaterialApp(home: page),
        );

    await tester.pumpWidget(app(QuizPage(title: '测试', questions: qs, scope: 'b1', shuffleOptions: false)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2); // right
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // next
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

    final saved = store.load('b1')!;
    expect((saved.index, saved.answered, saved.total), (1, 1, 3));

    // Leave and come back through the same path the bank page uses.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    final plan = (await tester.runAsync(() => planResume(store.load('b1')!, Repository(db, deviceId: 'd'))))!;
    await tester.pumpWidget(app(QuizPage(
      title: plan.title,
      questions: plan.questions,
      startAt: plan.index,
      scope: 'b1',
      resume: plan,
      shuffleOptions: false,
    )));
    await tester.pump();

    expect(find.text('2/3'), findsOneWidget, reason: 'back on the second question');
    expect(find.text('题干 q2'), findsOneWidget);
    expect(find.text('回答正确'), findsNothing);

    await tester.tap(find.text('上一题'));
    await tester.pump();
    expect(find.text('题干 q1'), findsOneWidget);
    expect(find.text('回答正确'), findsOneWidget, reason: 'the answer given before leaving is still shown');

    // Finish everything: the saved session goes away.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // q1 -> q2
    await tester.pump();
    for (final _ in [2, 3]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(find.textContaining('答对 3 / 3 题'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(store.load('b1'), isNull, reason: 'finished quizzes are not resumable');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.runAsync(db.close);
  });
}
