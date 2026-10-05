import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/features/home/bank_filter.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/home/question_list_page.dart';

import 'support.dart';

Bank bank(String id, String title) => Bank(id: id, title: title, description: '', questionCount: 0);

void main() {
  group('bankOptions', () {
    late AppDatabase db;
    setUp(() => db = memoryDb());
    tearDown(() => db.close());

    test('counts questions per bank in bank order and skips banks with none', () async {
      final a = await seedQs(db, n: 2, bank: 'a');
      final b = await seedQs(db, n: 1, bank: 'b');
      final opts = bankOptions([...b, ...a], [bank('a', '甲'), bank('b', '乙'), bank('c', '丙')]);
      expect(opts, [const BankOption(id: 'a', name: '甲', count: 2), const BankOption(id: 'b', name: '乙', count: 1)]);
    });

    test('keeps questions of a bank the device no longer lists under a stand-in name', () async {
      final gone = await seedQs(db, n: 1, bank: 'gone');
      final a = await seedQs(db, n: 1, bank: 'a');
      expect(bankOptions([...gone, ...a], [bank('a', '甲')]), [
        const BankOption(id: 'a', name: '甲', count: 1),
        const BankOption(id: 'gone', name: unknownBank, count: 1),
      ]);
      expect(bankOptions([], [bank('a', '甲')]), isEmpty);
    });

    test('inBank narrows to one bank, or keeps everything for an empty id', () async {
      final qs = [...await seedQs(db, n: 2, bank: 'a'), ...await seedQs(db, n: 1, bank: 'b')];
      expect(inBank(qs, 'a').map((q) => q.id), ['a-q1', 'a-q2']);
      expect(inBank(qs, ''), qs);
      expect(inBank(qs, 'zzz'), isEmpty);
    });
  });

  group('Repository wrong book by bank', () {
    test('watchWrongBook and watchFavorites can be narrowed to one bank', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final repo = Repository(db, deviceId: 'd');
      final a = await seedQs(db, n: 1, bank: 'a');
      final b = await seedQs(db, n: 2, bank: 'b', firstSeq: 10);
      for (final q in [...a, ...b]) {
        await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
      }
      await repo.setFavorite(b.first.id, true);

      Future<List<String>> ids(Stream<List<Question>> s) async => [for (final q in await s.first) q.id]..sort();
      expect(await ids(repo.watchWrongBook()), ['a-q1', 'b-q1', 'b-q2']);
      expect(await ids(repo.watchWrongBook(bankId: 'b')), ['b-q1', 'b-q2']);
      expect(await ids(repo.watchWrongBook(bankId: 'nope')), isEmpty);
      expect(await ids(repo.watchFavorites(bankId: 'b')), ['b-q1']);
      expect(await ids(repo.watchFavorites(bankId: 'a')), isEmpty);

      // Out of the wrong book, or withdrawn by the server: gone from the bank's list.
      await repo.clearFromWrongBook('b-q1');
      expect(await ids(repo.watchWrongBook(bankId: 'b')), ['b-q2']);
      await (db.update(db.questions)..where((q) => q.id.equals('b-q2'))).write(const QuestionsCompanion(hidden: Value(true)));
      expect(await ids(repo.watchWrongBook(bankId: 'b')), isEmpty);
    });
  });

  group('QuestionListPage', () {
    /// Two banks with wrong answers: 甲 has two, 乙 has one.
    Future<AppDatabase> twoBanks(WidgetTester tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'a', '甲题库');
        await addBank(db, 'b', '乙题库');
        final repo = Repository(db, deviceId: 'd');
        final qs = [...await seedQs(db, n: 2, bank: 'a'), ...await seedQs(db, n: 1, bank: 'b', firstSeq: 10)];
        for (final q in qs) {
          await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
        }
        await repo.setFavorite('a-q1', true);
        await repo.setFavorite('b-q1', true);
      });
      return db;
    }

    testWidgets('shows every bank by default, naming the bank of each question and counting per bank', (tester) async {
      final db = await twoBanks(tester);
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.wrongBook));
      await settleUi(tester);

      expect(find.text('全部 3'), findsOneWidget);
      expect(find.text('甲题库 2'), findsOneWidget);
      expect(find.text('乙题库 1'), findsOneWidget);
      expect(find.text('共 3 题'), findsOneWidget);
      expect(find.textContaining('单选题 · 甲题库'), findsNWidgets(2));
      expect(find.textContaining('单选题 · 乙题库'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('narrows the list and the random practice to the chosen bank', (tester) async {
      final db = await twoBanks(tester);
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.wrongBook));
      await settleUi(tester);

      await tester.tap(find.text('乙题库 1'));
      await tester.pump();
      expect(find.text('共 1 题'), findsOneWidget);
      expect(find.text('题干 b-q1'), findsOneWidget);
      expect(find.text('题干 a-q1'), findsNothing);
      expect(find.text('单选题'), findsOneWidget, reason: 'the bank name is not repeated on every row of a narrowed list');

      await tester.tap(find.text('随机练习'));
      await tester.pumpAndSettle();
      expect(find.text('错题本 · 乙题库'), findsOneWidget);
      expect(find.text('题干 b-q1'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('opens on the bank it is given, and the all chip is not selected', (tester) async {
      final db = await twoBanks(tester);
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.wrongBook, initialBankId: 'a'));
      await settleUi(tester);

      expect(find.text('共 2 题'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部 3')).selected, isFalse);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '甲题库 2')).selected, isTrue);
      await tester.tap(find.text('全部 3'));
      await tester.pump();
      expect(find.text('共 3 题'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('falls back to everything when the chosen bank has no wrong questions', (tester) async {
      final db = await twoBanks(tester);
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.wrongBook, initialBankId: 'nope'));
      await settleUi(tester);
      expect(find.text('共 3 题'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('the favourites list is split by bank too', (tester) async {
      final db = await twoBanks(tester);
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.favorites));
      await settleUi(tester);
      expect(find.text('全部 2'), findsOneWidget);
      await tester.tap(find.text('甲题库 1'));
      await tester.pump();
      expect(find.text('共 1 题'), findsOneWidget);
      expect(find.text('题干 a-q1'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('a bank with one bank only shows no filter bar', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'a', '甲题库');
        final qs = await seedQs(db, n: 1, bank: 'a');
        await Repository(db, deviceId: 'd').recordAnswer(question: qs.first, selected: [0], durationMs: 1);
      });
      await pumpWith(tester, db, const QuestionListPage(kind: QuestionListKind.wrongBook));
      await settleUi(tester);
      expect(find.byKey(const Key('bank-filter')), findsNothing);
      expect(find.text('共 1 题'), findsOneWidget);
      await tearDownUi(tester, db);
    });
  });

  group('BankDetail', () {
    testWidgets('links to the bank\'s own wrong book, greyed out when it has none', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'a', '甲题库');
        await addBank(db, 'b', '乙题库');
        final qs = [...await seedQs(db, n: 2, bank: 'a'), ...await seedQs(db, n: 1, bank: 'b', firstSeq: 10)];
        await Repository(db, deviceId: 'd').recordAnswer(question: qs.first, selected: [0], durationMs: 1);
      });
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank('a', '甲题库'))));
      await settleUi(tester);

      final entry = find.text('错题本');
      await tester.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('共 1 题'), findsOneWidget);
      expect(find.text('错题本'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '甲题库 1')).selected, isTrue);

      // The bank with nothing wrong has the entry greyed out.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank('b', '乙题库'))));
      await settleUi(tester);
      final none = find.text('错题本');
      await tester.scrollUntilVisible(none, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(none);
      await tester.pumpAndSettle();
      expect(find.text('没有错题'), findsOneWidget);
      expect(tester.widget<InkWell>(find.ancestor(of: none, matching: find.byType(InkWell))).onTap, isNull);
      await tearDownUi(tester, db);
    });
  });
}
