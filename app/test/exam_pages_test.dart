import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/exam/exam_page.dart';
import 'package:quizmind_app/features/stats/stats_page.dart';
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
          explanation: const Value('解析内容'),
          tagsJson: const Value('["锁"]'),
          syncSeq: i,
        ));
  }
  return db.select(db.questions).get();
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
}

Future<void> teardown(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.runAsync(db.close);
}

void main() {
  testWidgets('ExamPage: answer, review the sheet, hand in, see the score', (tester) async {
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
      child: MaterialApp(home: ExamPage(bankId: 'b1', title: '题库', questions: qs)),
    ));
    await tester.pump();

    expect(find.text('模拟考试 · 1/2'), findsOneWidget);
    expect(find.textContaining('⏱'), findsNothing); // untimed

    await tester.tap(find.text('乙')); // the right answer, wherever it is shown
    await tester.pump();
    expect(find.textContaining('回答'), findsNothing); // no feedback during the exam

    await tester.tap(find.text('答题卡'));
    await tester.pump();
    expect(find.text('已答 1 / 2'), findsOneWidget);
    await tester.tap(find.text('2'));
    await tester.pump();
    expect(find.text('模拟考试 · 2/2'), findsOneWidget);

    await tester.tap(find.text('甲')); // wrong
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '交卷'));
    await tester.pump();
    expect(find.text('确定交卷吗？'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('交卷')));
    await settle(tester);

    expect(find.text('考试结果'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.textContaining('未及格', findRichText: true), findsOneWidget);
    expect(find.text('1 / 2 题'), findsOneWidget);
    expect(find.text('重做错题 (1)'), findsOneWidget);

    final attempts = await tester.runAsync(() => db.select(db.attempts).get()) as List<Attempt>;
    expect(attempts, hasLength(2));
    expect(ExamHistoryProbe.count(prefs), 1);

    await teardown(tester, db);
  });

  testWidgets('ExamPage asks before leaving and a timed exam shows the clock', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 1)) as List<Question>;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(FakeApi()),
      ],
      child: MaterialApp(home: ExamPage(bankId: 'b1', title: '题库', questions: qs, limitSec: 90)),
    ));
    await tester.pump();
    expect(find.text('⏱ 1:30'), findsOneWidget);

    await tester.tap(find.byTooltip('退出考试'));
    await tester.pump();
    expect(find.textContaining('不会保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('模拟考试 · 1/1'), findsOneWidget); // still in the exam

    await teardown(tester, db);
  });

  testWidgets('StatsPage shows accuracy, coverage and the weak spots', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 4)) as List<Question>;
    tester.view.physicalSize = const Size(800, 2400); // tall enough that the lazy list builds every card
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      apiProvider.overrideWithValue(FakeApi()),
    ]);
    addTearDown(container.dispose);
    final repo = container.read(repositoryProvider);
    await tester.runAsync(() async {
      await repo.recordAnswer(question: qs[0], selected: [1], durationMs: 1000); // right
      await repo.recordAnswer(question: qs[1], selected: [0], durationMs: 1000); // wrong
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: StatsPage(bank: const Bank(id: 'b1', title: '题库', description: '', questionCount: 4)),
      ),
    ));
    await settle(tester);

    expect(find.text('题库 · 统计'), findsOneWidget);
    expect(find.text('50%'), findsWidgets); // accuracy
    expect(find.text('答对 1 / 2 次'), findsOneWidget);
    expect(find.text('做过 2 / 4 题'), findsOneWidget);
    expect(find.text('最常做错的题'), findsOneWidget);
    expect(find.text('专攻薄弱题（最多 20 道）'), findsOneWidget);

    await teardown(tester, db);
  });

  testWidgets('StatsPage invites practice when there is nothing yet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(FakeApi()),
      ],
      child: MaterialApp(
        home: StatsPage(bank: const Bank(id: 'b1', title: '题库', description: '', questionCount: 0)),
      ),
    ));
    await settle(tester);
    expect(find.textContaining('还没有答题记录'), findsOneWidget);
    await teardown(tester, db);
  });
}

/// Reads the exam history straight from the preferences the page wrote to.
class ExamHistoryProbe {
  static int count(SharedPreferences prefs) => (prefs.getString('exam.history.b1') ?? '').split('"id"').length - 1;
}
