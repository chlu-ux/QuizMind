import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/home/modules_page.dart';
import 'package:quizmind_app/features/quiz/modules.dart';

import 'support.dart';

final bank = Bank(id: 'b1', title: '题库', description: '', questionCount: 0);

({String id, String title, int order}) doc(String id, String title, int order) => (id: id, title: title, order: order);

void main() {
  group('moduleLabel', () {
    const titles = [
      '软件设计师（中级）考点精讲',
      '软件设计师（中级）考点精讲（操作系统）',
      '软件设计师（中级）考点精讲（软件工程（上）：过程、需求与设计）',
    ];

    test('drops the lead the titles share, and the brackets around what is left', () {
      expect(moduleLabel(titles[1], titles), '操作系统');
      expect(moduleLabel(titles[2], titles), '软件工程（上）：过程、需求与设计');
    });

    test('keeps the full title when nothing is left of it, or when it is the only one', () {
      expect(moduleLabel(titles[0], titles), titles[0]);
      expect(moduleLabel('单个文档', const ['单个文档']), '单个文档');
    });

    test('also handles a lead that ends inside the opening bracket', () {
      const t = ['强化训练（公式与速算）', '强化训练（高频考点）'];
      expect(moduleLabel(t[0], t), '公式与速算');
      expect(moduleLabel(t[1], t), '高频考点');
    });
  });

  group('moduleSummary', () {
    late AppDatabase db;
    setUp(() => db = memoryDb());
    tearDown(() => db.close());

    test('lists modules in upload order with their counts, skips questions with no document, and judges accuracy', () async {
      final qs = await seedQs(
        db,
        n: 6,
        module: (i) => switch (i) {
          1 || 2 || 3 => doc('d2', '书（二）', 200),
          4 || 5 => doc('d1', '书（一）', 100),
          _ => null,
        },
      );
      final repo = Repository(db, deviceId: 'd');
      await repo.recordAnswer(question: qs[3], selected: [1], durationMs: 1); // right
      await repo.recordAnswer(question: qs[0], selected: [0], durationMs: 1); // wrong
      final attempts = await repo.bankAttempts('b1');

      final rows = moduleSummary(qs, attempts);
      expect(rows.map((m) => (m.label, m.count, m.answered, m.missed)), [('一', 2, 1, 0), ('二', 3, 1, 1)]);
      expect(rows.map((m) => m.accuracy), [100, 0]);
      expect(moduleQuestions(qs, 'd2').map((q) => q.id), ['b1-q1', 'b1-q2', 'b1-q3'], reason: 'bank order is kept');
    });

    test('is empty when no question carries a document', () async {
      final qs = await seedQs(db, n: 2);
      expect(moduleSummary(qs, const []), isEmpty);
    });
  });

  group('ModulesPage', () {
    Future<AppDatabase> seeded(WidgetTester tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        await seedQs(db, n: 5, module: (i) => i <= 3 ? doc('d1', '书（一）', 1) : doc('d2', '书（二）', 2));
      });
      return db;
    }

    testWidgets('lists the modules in order and practises one in the document order', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, ModulesPage(bank: bank));
      await settleUi(tester);

      final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(rows.map((r) => (r.title as Text).data), ['一', '二']);
      expect((rows[0].subtitle as Text).data, '3 题 · 做过 0');

      await tester.tap(find.text('一'));
      await tester.pumpAndSettle();
      expect(find.text('模块 · 一'), findsOneWidget);
      expect(find.textContaining('/3'), findsOneWidget);
      expect(find.text('题干 b1-q1'), findsOneWidget, reason: 'sequential by default');
      await tearDownUi(tester, db);
    });

    testWidgets('says to sync when the questions carry no module', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        await seedQs(db, n: 2);
      });
      await pumpWith(tester, db, ModulesPage(bank: bank));
      await settleUi(tester);
      expect(find.textContaining('还没有模块信息'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('is reachable from the bank page', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank)));
      await settleUi(tester);
      final entry = find.text('按模块刷题');
      await tester.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('按模块刷题 · 题库'), findsOneWidget);
      await tearDownUi(tester, db);
    });
  });

  test('a pulled question keeps the document the server names, and an old server leaves it empty', () async {
    final db = memoryDb();
    addTearDown(db.close);
    final api = FakeApi()
      ..published.addAll([
        QuestionDto.fromJson({
          'id': 'q1', 'bank_id': 'b1', 'type': 'single', 'stem': 's', 'options': ['A', 'B'], 'answer': [0],
          'document_id': 'd1', 'document_title': '书（一）', 'document_created_at': 42, 'sync_seq': 1,
        }),
        QuestionDto.fromJson({
          'id': 'q2', 'bank_id': 'b1', 'type': 'single', 'stem': 's', 'options': ['A', 'B'], 'answer': [0], 'sync_seq': 2,
        }),
      ]);
    await SyncService(db, api, deviceId: 'd').run();
    final rows = {for (final q in await db.select(db.questions).get()) q.id: q};
    expect((rows['q1']!.documentId, rows['q1']!.documentTitle, rows['q1']!.documentOrder), ('d1', '书（一）', 42));
    expect((rows['q2']!.documentId, rows['q2']!.documentTitle), ('', ''));
  });

  test('upgrading a version-5 database adds the module columns and keeps the questions', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE questions (
          id TEXT NOT NULL PRIMARY KEY, bank_id TEXT NOT NULL, type TEXT NOT NULL, stem TEXT NOT NULL,
          options_json TEXT NOT NULL, answer_json TEXT NOT NULL, explanation TEXT NOT NULL DEFAULT '',
          difficulty INTEGER NOT NULL DEFAULT 3, tags_json TEXT NOT NULL DEFAULT '[]',
          source_quote TEXT NOT NULL DEFAULT '', sync_seq INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0
        )''');
      raw.execute("INSERT INTO questions (id, bank_id, type, stem, options_json, answer_json, sync_seq) VALUES ('q', 'b', 'single', 's', '[]', '[0]', 1)");
      raw.execute('PRAGMA user_version = 5');
    }));
    addTearDown(db.close);
    final q = (await db.select(db.questions).get()).single;
    expect((q.id, q.documentId, q.documentTitle, q.documentOrder), ('q', '', '', 0));
  });
}
