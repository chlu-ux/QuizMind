import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/features/exam/exam_session.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/home/topics_page.dart';
import 'package:quizmind_app/features/quiz/topics.dart';
import 'package:quizmind_app/features/stats/stats_page.dart';

import 'support.dart';

Question q(String id, List<String> tags) => Question(
      id: id,
      bankId: 'b',
      type: 'single',
      stem: id,
      optionsJson: '["甲","乙","丙","丁"]',
      answerJson: '[0]',
      explanation: '',
      difficulty: 2,
      tagsJson: jsonEncode(tags),
      sourceQuote: '',
      documentId: '',
      documentTitle: '',
      documentOrder: 0,
      syncSeq: 1,
      hidden: false,
    );

var _n = 0;
Attempt at(String questionId, bool ok) => Attempt(
      id: 'a${++_n}',
      questionId: questionId,
      deviceId: 'd',
      answerJson: '[0]',
      isCorrect: ok,
      durationMs: 1000,
      answeredAt: _n,
      synced: true,
    );

List<String> ids(List<Question> qs) => [for (final x in qs) x.id];

final bank = Bank(id: 'b1', title: '题库', description: '', questionCount: 0);

void main() {
  group('topicQuestions', () {
    final qs = [
      q('1', ['UML']),
      q('2', ['UML 辨析']),
      q('3', ['uml', '设计模式']),
      q('4', ['设计模式']),
      q('5', []),
      q('6', ['UML']), // makes "UML" the commonest spelling, so it is the label
    ];

    test('merges related tags when asked, and only case/width/spacing otherwise', () {
      expect(ids(topicQuestions(qs, 'UML', merged: true)), ['1', '2', '3', '6']);
      expect(ids(topicQuestions(qs, 'UML', merged: false)), ['1', '3', '6']); // "UML 辨析" stays apart
      expect(ids(topicQuestions(qs, 'UML 辨析', merged: false)), ['2']);
    });

    test('lists a question with several tags once, and never an untagged one', () {
      final multi = [q('x', ['缓存', 'Cache', '缓存 ']), q('y', [])];
      final label = topicSummary(multi, [], merged: false).first.label;
      expect(ids(topicQuestions(multi, label, merged: false)), ['x']);
      expect(topicQuestions(qs, '', merged: true), isEmpty);
      expect(topicQuestions(qs, '不存在', merged: true), isEmpty);
    });

    test('folds full-width and upper-case spellings together', () {
      final list = [q('1', ['ＵＭＬ']), q('2', ['uml']), q('3', ['UML'])];
      final t = topicSummary(list, [], merged: true).single;
      expect(ids(topicQuestions(list, t.label, merged: true)), ['1', '2', '3']);
    });

    test('names the same questions as the exam paper does for the same label', () {
      for (final label in ['UML', '设计模式']) {
        expect(ids(topicQuestions(qs, label, merged: true)), ids(paperPool(qs, [label])));
      }
    });
  });

  group('topicSummary', () {
    final qs = [q('1', ['锁']), q('2', ['锁', '线程']), q('3', ['线程']), q('4', ['范式'])];
    final attempts = [at('1', false), at('1', true), at('2', true), at('4', true), at('zzz', false)];

    test('counts questions, answered questions and accuracy per topic, biggest first', () {
      final rows = topicSummary(qs, attempts, merged: true);
      expect([for (final r in rows) r.label].take(2).toSet(), {'锁', '线程'});
      expect(rows.last.label, '范式');
      final by = {for (final r in rows) r.label: r};
      expect((by['锁']!.count, by['锁']!.answered, by['锁']!.missed, by['锁']!.attempts, by['锁']!.correct, by['锁']!.accuracy), (2, 2, 1, 3, 2, 67));
      expect((by['线程']!.count, by['线程']!.answered, by['线程']!.missed, by['线程']!.accuracy), (2, 1, 0, 100));
      expect((by['范式']!.count, by['范式']!.answered, by['范式']!.accuracy), (1, 1, 100));
    });

    test('has no accuracy for a topic nobody answered, and ignores attempts of unknown questions', () {
      final r = topicSummary([q('1', ['锁'])], [at('other', false)], merged: true).single;
      expect((r.label, r.count, r.answered, r.missed, r.attempts, r.accuracy), ('锁', 1, 0, 0, 0, null));
    });

    test('breaks ties on count by label and is empty without tags', () {
      expect([for (final r in topicSummary([q('1', ['乙']), q('2', ['甲'])], [], merged: true)) r.label], ['乙', '甲']..sort());
      expect(topicSummary([q('1', [])], [], merged: true), isEmpty);
    });

    test('counts a multi-tag question under each of its topics', () {
      final rows = topicSummary([q('1', ['A类', 'B类'])], [at('1', true)], merged: false);
      expect([for (final r in rows) (r.label, r.count, r.answered)], [('A类', 1, 1), ('B类', 1, 1)]);
    });
  });

  group('filters', () {
    final qs = [q('1', ['锁']), q('2', ['锁']), q('3', ['锁'])];
    final attempts = [at('1', false), at('1', true), at('2', true)];

    test('keeps only unanswered, or only once-wrong, questions', () {
      expect(ids(applyTopicFilter(qs, attempts, TopicFilter.all)), ['1', '2', '3']);
      expect(ids(applyTopicFilter(qs, attempts, TopicFilter.unanswered)), ['3']);
      expect(ids(applyTopicFilter(qs, attempts, TopicFilter.missed)), ['1'], reason: 'wrong once, right since: still "missed"');
    });

    test('topicAvailable agrees with the filtered list', () {
      final t = topicSummary(qs, attempts, merged: true).single;
      for (final f in TopicFilter.values) {
        expect(topicAvailable(t, f), applyTopicFilter(topicQuestions(qs, t.label, merged: true), attempts, f).length);
      }
    });
  });

  group('TopicsPage', () {
    /// 锁 ×3, 范式 ×2, UML ×1; q1 answered right, q2 answered wrong.
    Future<AppDatabase> seeded(WidgetTester tester, {List<String> Function(int)? tags}) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        final qs = await seedQs(db, n: 6, tags: tags ?? (i) => i <= 3 ? ['锁'] : i <= 5 ? ['范式'] : ['UML']);
        final repo = Repository(db, deviceId: 'd');
        await repo.recordAnswer(question: qs[0], selected: [1], durationMs: 1);
        await repo.recordAnswer(question: qs[1], selected: [0], durationMs: 1);
      });
      return db;
    }

    testWidgets('lists knowledge points biggest first with counts and accuracy, and starts the topic', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, TopicsPage(bank: bank));
      await settleUi(tester);

      final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(rows, hasLength(3));
      expect((rows[0].title as Text).data, '锁');
      expect((rows[0].subtitle as Text).data, '3 题 · 做过 2');
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('未做'), findsNWidgets(2));

      await tester.tap(find.text('锁'));
      await tester.pumpAndSettle();
      expect(find.text('知识点 · 锁'), findsOneWidget);
      expect(find.textContaining('/3'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('"only unanswered" and "only missed" narrow the draw, exclude each other and toggle off', (tester) async {
      final db = await seeded(tester, tags: (_) => ['锁']);
      await pumpWith(tester, db, TopicsPage(bank: bank));
      await settleUi(tester);
      Future<String> draw() async {
        await tester.tap(find.text('锁'));
        await tester.pumpAndSettle();
        final n = tester.widget<Text>(find.textContaining(RegExp(r'^\d+/\d+$'))).data!;
        await tester.pageBack();
        await tester.pumpAndSettle();
        return n;
      }

      await tester.tap(find.text('只刷没做过的'));
      await tester.pump();
      expect(find.textContaining('可刷 4'), findsOneWidget);
      expect(await draw(), endsWith('/4'));

      await tester.tap(find.text('只刷做错过的'));
      await tester.pump();
      expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, '只刷没做过的')).selected, isFalse);
      expect(find.textContaining('可刷 1'), findsOneWidget);
      expect(await draw(), endsWith('/1'));

      await tester.tap(find.text('只刷做错过的')); // off again
      await tester.pump();
      expect(find.textContaining('可刷'), findsNothing);
      expect(await draw(), endsWith('/6'));
      await tearDownUi(tester, db);
    });

    testWidgets('says so instead of starting an empty quiz', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        final qs = await seedQs(db, n: 2);
        final repo = Repository(db, deviceId: 'd');
        for (final x in qs) {
          await repo.recordAnswer(question: x, selected: [1], durationMs: 1); // all right, none wrong
        }
      });
      await pumpWith(tester, db, TopicsPage(bank: bank));
      await settleUi(tester);
      await tester.tap(find.text('只刷做错过的'));
      await tester.pump();
      await tester.tap(find.text('锁'));
      await tester.pump();
      expect(find.text('这个知识点还没有做错过的题'), findsOneWidget);
      expect(find.textContaining('/'), findsNothing, reason: 'no quiz was opened');
      await tearDownUi(tester, db);
    });

    testWidgets('merges related tags by default and shows them apart in the detailed view', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        await seedQs(db, n: 2, tags: (i) => i == 1 ? ['UML'] : ['UML 辨析']);
      });
      await pumpWith(tester, db, TopicsPage(bank: bank));
      await settleUi(tester);
      expect(find.byType(ListTile), findsOneWidget);
      await tester.tap(find.text('细分'));
      await tester.pump();
      expect(find.byType(ListTile), findsNWidgets(2));
      await tearDownUi(tester, db);
    });

    testWidgets('tells when there are no tags, and is reachable from the bank page', (tester) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        await seedQs(db, n: 2, tags: (_) => const []);
      });
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank)));
      await settleUi(tester);
      final entry = find.text('按知识点刷题');
      await tester.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('按知识点刷题 · 题库'), findsOneWidget);
      expect(find.textContaining('还没有知识点标签'), findsOneWidget);
      await tearDownUi(tester, db);
    });
  });

  group('StatsPage topics', () {
    testWidgets('a tag row starts practice on that knowledge point, following the merged / detailed switch', (tester) async {
      final db = memoryDb();
      late List<Question> qs;
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        qs = await seedQs(db, n: 4, tags: (i) => i == 1 ? ['UML'] : i == 2 ? ['UML 辨析'] : i == 3 ? ['UML'] : ['范式']);
        final repo = Repository(db, deviceId: 'd');
        for (final x in qs) {
          await repo.recordAnswer(question: x, selected: [1], durationMs: 1000);
        }
      });
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpWith(tester, db, StatsPage(bank: bank));
      await settleUi(tester);

      await tester.tap(find.text('UML').first);
      await tester.pumpAndSettle();
      expect(find.text('知识点 · UML'), findsOneWidget);
      expect(find.textContaining('/3'), findsOneWidget, reason: '"UML 辨析" is folded into UML');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('细分'));
      await tester.pump();
      await tester.tap(find.text('UML').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('/2'), findsOneWidget, reason: 'the detailed view keeps "UML 辨析" apart');
      await tearDownUi(tester, db);
    });
  });
}
