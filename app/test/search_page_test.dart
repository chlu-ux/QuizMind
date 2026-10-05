import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/home/search_page.dart';

import 'support.dart';

final bank = Bank(id: 'b1', title: '题库', description: '', questionCount: 0);

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 260)); // the box is debounced by 200 ms
  await tester.pump();
}

Future<AppDatabase> seeded(WidgetTester tester) async {
  final db = memoryDb();
  await tester.runAsync(() async {
    await addBank(db, 'b1', '题库');
    await seedQs(db, n: 4, stem: (i) => ['读写锁允许多个读者同时持有锁', '互斥锁只允许一个线程持有', '哪个是缓存淘汰算法', '被服务器撤回的题 读写锁'][i - 1], tags: (i) => i == 3 ? ['LRU'] : ['锁'], explanation: (i) => i == 2 ? '和读写锁相比，互斥锁更简单' : '解析');
    await (db.update(db.questions)..where((q) => q.id.equals('b1-q4'))).write(const QuestionsCompanion(hidden: Value(true)));
  });
  return db;
}

void main() {
  testWidgets('finds questions as you type and says where a hidden match is', (tester) async {
    final db = await seeded(tester);
    await pumpWith(tester, db, SearchPage(bank: bank));
    await settleUi(tester);
    expect(find.textContaining('输入关键词开始搜索'), findsOneWidget);

    await type(tester, '读写锁');
    expect(find.text('找到 2 题'), findsOneWidget); // the withdrawn question is not offered
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.textContaining('解析：', findRichText: true), findsOneWidget); // only one matched in the explanation

    await type(tester, 'lru 缓存');
    expect(find.text('找到 1 题'), findsOneWidget);
    await type(tester, 'ＬＲＵ');
    expect(find.text('找到 1 题'), findsOneWidget);
    expect(find.textContaining('知识点：', findRichText: true), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('says so when nothing matches, and shows nothing for a blank box', (tester) async {
    final db = await seeded(tester);
    await pumpWith(tester, db, SearchPage(bank: bank));
    await settleUi(tester);
    await type(tester, '不存在的词');
    expect(find.textContaining('没有找到'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await type(tester, '   ');
    expect(find.textContaining('没有找到'), findsNothing);
    expect(find.textContaining('输入关键词开始搜索'), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('starts the quiz from the tapped result over the whole result list', (tester) async {
    final db = await seeded(tester);
    await pumpWith(tester, db, SearchPage(bank: bank));
    await settleUi(tester);
    await type(tester, '锁');
    await tester.tap(find.byType(ListTile).at(1));
    await tester.pumpAndSettle();
    expect(find.text('搜索：锁'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget, reason: 'started at the second of the two results');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('练习这 2 道'));
    await tester.pumpAndSettle();
    expect(find.text('搜索：锁'), findsOneWidget);
    expect(find.textContaining('/2'), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('draws at most 100 rows and tells how many more there are', (tester) async {
    final db = memoryDb();
    await tester.runAsync(() async {
      await addBank(db, 'b1', '题库');
      await seedQs(db, n: 130, stem: (i) => '共同的词 $i');
    });
    await pumpWith(tester, db, SearchPage(bank: bank));
    await settleUi(tester);
    await type(tester, '共同的词');
    expect(find.text('找到 130 题'), findsOneWidget);
    // The list is lazy; the footer is the 101st row.
    await tester.drag(find.byType(ListView), const Offset(0, -200000));
    await tester.pumpAndSettle();
    expect(find.text('还有 30 条，请缩小范围'), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('is reachable from the bank page', (tester) async {
    final db = await seeded(tester);
    await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank)));
    await settleUi(tester);
    final entry = find.text('搜索题目');
    await tester.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('搜索 · 题库'), findsOneWidget);
    await tearDownUi(tester, db);
  });
}
