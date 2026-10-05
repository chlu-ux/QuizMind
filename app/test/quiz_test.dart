import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/features/quiz/quiz_page.dart';
import 'package:quizmind_app/features/quiz/quiz_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Future<List<Question>> seed(AppDatabase db, int n) async {
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
  return (db.select(db.questions)).get();
}

void main() {
  test('normalizeBaseUrl', () {
    expect(normalizeBaseUrl(' 192.168.1.5:8080/ '), 'http://192.168.1.5:8080');
    expect(normalizeBaseUrl('https://a.example.com//'), 'https://a.example.com');
    expect(normalizeBaseUrl('localhost:8080'), 'http://localhost:8080');
    expect(normalizeBaseUrl('  '), '');
  });

  test('orderQuestions keeps order or shuffles without losing items', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final qs = await seed(db, 6);
    expect(orderQuestions(qs, QuizOrder.sequential).map((q) => q.id), qs.map((q) => q.id));
    final shuffled = orderQuestions(qs, QuizOrder.random, rng: Random(1));
    expect(shuffled.map((q) => q.id).toSet(), qs.map((q) => q.id).toSet());
    expect(qs.map((q) => q.id).toList(), ['q1', 'q2', 'q3', 'q4', 'q5', 'q6'], reason: 'input untouched');
  });

  group('QuizSession timing', () {
    late AppDatabase db;
    late List<Question> qs;
    late QuizSession s;
    var t = DateTime(2026, 10, 3, 12);
    void advance(int ms) => t = t.add(Duration(milliseconds: ms));

    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      qs = await seed(db, 3);
      t = DateTime(2026, 10, 3, 12);
      s = QuizSession(title: 't', questions: qs, repo: Repository(db, deviceId: 'd'), clock: () => t);
    });

    test('times the answer up to submit and the reading after it as review time', () async {
      advance(8000);
      s.select(1);
      await s.submit();
      advance(20000); // reading the explanation
      s.next();
      await s.flush();
      final a = (await db.select(db.attempts).get()).single;
      expect(a.durationMs, 8000);
      expect(a.reviewMs, 20000);
      expect(a.synced, isFalse);
    });

    test('adds up every visit to an answered question, and lets an unanswered one carry its time', () async {
      advance(4000);
      s.next(); // q1 skipped for now: 4s on it
      advance(1000);
      s.previous();
      advance(3000);
      s.select(1);
      await s.submit(); // 4s + 3s before answering q1
      advance(2000);
      s.next();
      advance(5000);
      s.previous(); // back on q1 to read the explanation again
      advance(6000);
      await s.flush();
      final a = (await db.select(db.attempts).get()).single;
      expect(a.durationMs, 7000);
      expect(a.reviewMs, 2000 + 6000);
    });

    test('does not count the time the app was in the background', () async {
      advance(3000);
      s.setVisible(false);
      advance(600000);
      s.setVisible(true);
      advance(1000);
      s.select(1);
      await s.submit();
      advance(500);
      s.setVisible(false);
      advance(600000);
      await s.flush();
      final a = (await db.select(db.attempts).get()).single;
      expect(a.durationMs, 4000);
      expect(a.reviewMs, 500);
    });
  });

  test('QuizSession: answer, review, finish and collect misses', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final qs = await seed(db, 3);
    final s = QuizSession(title: 't', questions: qs, repo: Repository(db, deviceId: 'd'));

    await s.submit();
    expect(s.submitted, isFalse, reason: 'cannot submit without a choice');

    s.select(0);
    await s.submit();
    expect(s.outcome!.correct, isFalse);
    s.select(2);
    expect(s.selected, [0], reason: 'locked after submit');

    s.next();
    s.select(1);
    await s.submit();
    expect(s.outcome!.correct, isTrue);

    s.previous();
    expect(s.index, 0);
    expect(s.submitted, isTrue, reason: 'stepping back shows the earlier result');

    s.next();
    s.next();
    expect(s.isLast, isTrue);
    s.select(1);
    await s.submit();
    s.next();
    expect(s.finished, isTrue);
    expect((s.answeredCount, s.correctCount), (3, 2));
    expect(s.missed.map((q) => q.id), ['q1']);
  });

  testWidgets('QuizPage asks why a question is reported and queues the report with that reason', (tester) async {
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 2)) as List<Question>;
    await pumpWith(tester, db, QuizPage(title: '测试', questions: qs, shuffleOptions: false));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('题目有误，反馈'));
    await tester.pumpAndSettle();
    expect(find.text('这道题哪里有问题？'), findsOneWidget);
    for (final label in ['答案不对', '题干有歧义', '选项或文字有误', '其他']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('题干有歧义'));
    await tester.pumpAndSettle();
    final flags = await tester.runAsync(() => db.select(db.pendingFlags).get()) as List<PendingFlag>;
    expect(flags.map((f) => (f.questionId, f.reason)), [('q1', 'ambiguous')]);
    expect(find.text('题干 q2'), findsOneWidget, reason: 'moves on to the next question');

    await tearDownUi(tester, db);
  });

  testWidgets('sequential QuizPage jumps to a typed question number and reports the new position', (tester) async {
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 5)) as List<Question>;
    final seen = <String?>[];
    await pumpWith(tester, db, QuizPage(title: '测试', questions: qs, shuffleOptions: false, onPosition: (q) => seen.add(q?.id)));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳到第几题…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('题干 q4'), findsOneWidget);
    expect(seen.last, 'q4');

    // A number past the end lands on the last question rather than failing.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳到第几题…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '99');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('题干 q5'), findsOneWidget);

    await tearDownUi(tester, db);
  });

  testWidgets('QuizPage reports nothing when the reason sheet is dismissed', (tester) async {
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 2)) as List<Question>;
    await pumpWith(tester, db, QuizPage(title: '测试', questions: qs, shuffleOptions: false));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('题目有误，反馈'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.select(db.pendingFlags).get()), isEmpty);
    expect(find.text('题干 q1'), findsOneWidget);

    await tearDownUi(tester, db);
  });

  testWidgets('QuizPage works from the keyboard and records the answer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 2)) as List<Question>;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(FakeApi()),
      ],
      child: MaterialApp(home: QuizPage(title: '测试', questions: qs, shuffleOptions: false)),
    ));
    await tester.pump();

    expect(find.text('题干 q1'), findsOneWidget);
    expect(find.text('测试'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1); // wrong: picks 甲
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.textContaining('回答错误，正确答案：B'), findsOneWidget);
    expect(find.text('已加入错题本'), findsOneWidget);
    expect(find.textContaining('原文：原文'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // next
    await tester.pump();
    expect(find.text('题干 q2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2); // right
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('回答正确'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pump();
    expect(find.textContaining('答对 1 / 2 题'), findsOneWidget);
    expect(find.text('重做错题 (1)'), findsOneWidget);

    final attempts = await tester.runAsync(() => db.select(db.attempts).get()) as List<Attempt>;
    expect(attempts, hasLength(2));
    expect(attempts.where((a) => a.isCorrect), hasLength(1));

    // Leave the page so the final sync attempt (against FakeApi) is done before teardown.
    await tester.pumpWidget(const SizedBox());
    // Drift cancels its stream queries on a fake-clock timer; advance it or db.close() waits forever.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.runAsync(db.close);
  });
}
