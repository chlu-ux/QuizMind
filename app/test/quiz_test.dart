import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/api.dart';
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
