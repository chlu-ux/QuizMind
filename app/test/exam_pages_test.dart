import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/exam_store.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/features/exam/exam_page.dart';
import 'package:quizmind_app/features/exam/exam_review_page.dart';
import 'package:quizmind_app/features/exam/exam_setup_page.dart';
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
    final exams = await tester.runAsync(() => db.select(db.exams).get()) as List<ExamRow>;
    expect(exams, hasLength(1));
    final drafts = await tester.runAsync(() => db.select(db.examDrafts).get()) as List<ExamDraftRow>;
    expect(drafts, isEmpty, reason: 'handing in clears the saved progress');

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
    expect(find.textContaining('进度会保留'), findsOneWidget); // a timed exam keeps running, so it asks first
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

  testWidgets('ExamPage: mark a question, see it on the sheet and in the hand-in prompt; leaving keeps the progress', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() => seed(db, 3)) as List<Question>;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(FakeApi()),
      ],
      child: MaterialApp(home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ExamPage(bankId: 'b1', title: '题库', questions: qs),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      )),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('乙')); // answer 1
    await tester.pump();
    await tester.tap(find.text('下一题'));
    await tester.pump();
    expect(find.text('标记待检查'), findsOneWidget);
    await tester.tap(find.text('标记待检查'));
    await tester.pump();
    expect(find.text('已标记待检查'), findsOneWidget);

    await tester.tap(find.text('答题卡'));
    await tester.pump();
    expect(find.textContaining('待检查 1'), findsOneWidget);
    expect(find.byIcon(Icons.flag), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '交卷'));
    await tester.pump();
    expect(find.textContaining('1 题标记了待检查'), findsOneWidget);
    expect(find.textContaining('还有 2 题没有作答'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();

    // Untimed: leaving asks nothing, and the progress is there to resume.
    await tester.tap(find.text('继续答题'));
    await tester.pump();
    await tester.tap(find.byTooltip('退出考试'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final draft = await tester.runAsync(() => Repository(db, deviceId: 'd').examDraft('b1'));
    expect(draft, isNotNull);
    expect(draft!.index, 1);
    expect(draft.answers.length, 1);
    expect(draft.marked, ['q2']);

    await teardown(tester, db);
  });

  testWidgets('ExamSetupPage offers to continue an unfinished exam and lists past exams to review', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    await tester.runAsync(() => seed(db, 3));
    tester.view.physicalSize = const Size(800, 2400);
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
      await repo.saveExamDraft(ExamDraft(
        bankId: 'b1',
        title: '题库',
        ids: ['q1', 'q2', 'q3'],
        seed: 1,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        limitSec: null,
        index: 1,
        answers: {'q1': [1]},
        spent: {'q1': 1000},
        marked: [],
        savedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await repo.importExam(const ExamRecord(
        id: 'E1',
        bankId: 'b1',
        title: '题库',
        finishedAt: 1700000000000,
        total: 3,
        correct: 1,
        answered: 2,
        percent: 33,
        passed: false,
        limitSec: null,
        usedMs: 61000,
        items: [
          ExamItemRecord(questionId: 'q1', selected: [1], correct: true),
          ExamItemRecord(questionId: 'q2', selected: [0], correct: false),
          ExamItemRecord(questionId: 'gone', selected: [], correct: false),
        ],
      ));
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ExamSetupPage(bank: const Bank(id: 'b1', title: '题库', description: '', questionCount: 3)),
      ),
    ));
    await settle(tester);

    expect(find.text('有一场没做完的考试'), findsOneWidget);
    expect(find.textContaining('已答 1 / 3 题'), findsOneWidget);
    expect(find.text('出卷方式'), findsOneWidget);
    expect(find.text('查漏补缺'), findsOneWidget);
    expect(find.text('另开一场新考试'), findsOneWidget);

    // Continue: back on question 2 of 3 with the first answer kept.
    await tester.tap(find.text('继续考试'));
    await tester.pumpAndSettle();
    expect(find.text('模拟考试 · 2/3'), findsOneWidget);
    await tester.tap(find.byTooltip('退出考试'));
    await tester.pumpAndSettle();

    // Past exam: tap to review; the withdrawn question shows as such.
    await tester.scrollUntilVisible(find.textContaining('33 分'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.textContaining('33 分'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('考试回顾'), findsOneWidget);
    expect(find.text('重做错题 (1)'), findsOneWidget);
    expect(find.textContaining('（这道题已下线）'), findsOneWidget);

    await teardown(tester, db);
  });

  testWidgets('ExamReviewPage says so when the exam is not on this device', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(FakeApi()),
      ],
      child: const MaterialApp(home: ExamReviewPage(examId: 'nope')),
    ));
    await settle(tester);
    expect(find.textContaining('没有找到这场考试'), findsOneWidget);
    await teardown(tester, db);
  });

  testWidgets('StatsPage switches to 30 days, groups tags, and charts exam scores', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    final qs = await tester.runAsync(() async {
      await seed(db, 2);
      await (db.update(db.questions)..where((q) => q.id.equals('q1'))).write(const QuestionsCompanion(tagsJson: Value('["UML"]')));
      await (db.update(db.questions)..where((q) => q.id.equals('q2'))).write(const QuestionsCompanion(tagsJson: Value('["UML 辨析"]')));
      return db.select(db.questions).get();
    }) as List<Question>;
    tester.view.physicalSize = const Size(800, 3000);
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
      await repo.recordAnswer(question: qs[0], selected: [1], durationMs: 1000);
      await repo.recordAnswer(question: qs[1], selected: [0], durationMs: 1000);
      await repo.importExam(const ExamRecord(
        id: 'E1', bankId: 'b1', title: 't', finishedAt: 1000, total: 2, correct: 1, answered: 2, percent: 50,
        passed: false, limitSec: null, usedMs: 1,
      ));
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: StatsPage(bank: const Bank(id: 'b1', title: '题库', description: '', questionCount: 2)),
      ),
    ));
    await settle(tester);

    expect(find.text('最近 7 天'), findsOneWidget);
    await tester.tap(find.text('30 天'));
    await tester.pump();
    expect(find.text('最近 30 天'), findsOneWidget);
    expect(find.text('共 2 次作答'), findsOneWidget);

    expect(find.text('考试成绩'), findsOneWidget);
    expect(find.byKey(const ValueKey('exam-trend')), findsOneWidget);

    // "UML" and "UML 辨析" are one group by default and two when detailed.
    expect(find.textContaining('共 1 个'), findsOneWidget);
    await tester.tap(find.text('细分'));
    await tester.pump();
    expect(find.textContaining('共 2 个'), findsOneWidget);

    await teardown(tester, db);
  });
}
