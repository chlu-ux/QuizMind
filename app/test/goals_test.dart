import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/goals.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/stats.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

int min(int n) => n * 60000;
DateTime at(int h, int m) => DateTime(2026, 10, 5, h, m);
Goals g({int? questions, int? minutes, bool remind = false, String remindAt = '20:00'}) =>
    Goals(questions: questions, minutes: minutes, remind: remind, remindAt: remindAt);

void main() {
  group('goalStatus', () {
    test('has no goal when both are off, and is never "achieved" then', () {
      final s = goalStatus(g(), DayProgress(questions: 50, ms: min(90)));
      expect((s.hasGoal, s.achieved, s.questionsLeft, s.minutesLeft), (false, false, 0, 0));
    });

    test('judges only the questions goal when only that is on', () {
      final goal = g(questions: 20);
      var s = goalStatus(goal, DayProgress(questions: 12, ms: min(500)));
      expect((s.questionsLeft, s.minutesLeft, s.achieved), (8, 0, false));
      expect(goalStatus(goal, const DayProgress(questions: 20)).achieved, isTrue);
      expect(goalStatus(goal, const DayProgress(questions: 35)).questionsLeft, 0);
    });

    test('judges only the minutes goal when only that is on, on whole minutes', () {
      final goal = g(minutes: 30);
      final s = goalStatus(goal, DayProgress(questions: 999, ms: min(29) + 59999));
      expect((s.minutesDone, s.minutesLeft, s.achieved), (29, 1, false));
      expect(goalStatus(goal, DayProgress(ms: min(30))).achieved, isTrue);
    });

    test('needs both when both are on', () {
      final goal = g(questions: 10, minutes: 15);
      var s = goalStatus(goal, DayProgress(questions: 10, ms: min(10)));
      expect((s.achieved, s.questionsLeft, s.minutesLeft), (false, 0, 5));
      s = goalStatus(goal, DayProgress(questions: 4, ms: min(20)));
      expect((s.achieved, s.questionsLeft, s.minutesLeft), (false, 6, 0));
      expect(goalStatus(goal, DayProgress(questions: 10, ms: min(15))).achieved, isTrue);
    });

    test('names what is left, only for the goals still open', () {
      expect(goalStatus(g(questions: 10, minutes: 15), DayProgress(questions: 5, ms: min(3))).remainingText, '还差 5 题、12 分钟');
      expect(goalStatus(g(questions: 10, minutes: 15), DayProgress(questions: 10, ms: min(3))).remainingText, '还差 12 分钟');
      expect(goalStatus(g(questions: 10), const DayProgress(questions: 10)).remainingText, '');
    });
  });

  group('reminderDue', () {
    final goal = g(questions: 10, remind: true);
    final open = goalStatus(goal, const DayProgress(questions: 3));

    test('fires from the set time on, not before', () {
      expect(reminderDue(goal, open, at(19, 59)), isFalse);
      expect(reminderDue(goal, open, at(20, 0)), isTrue);
      expect(reminderDue(goal, open, at(23, 59)), isTrue);
    });

    test('starts over after midnight', () {
      expect(reminderDue(goal, open, at(0, 5)), isFalse);
    });

    test('stays quiet when reminders are off, no goal is set, or the goal is met', () {
      expect(reminderDue(g(questions: 10), open, at(21, 0)), isFalse);
      expect(reminderDue(g(remind: true), goalStatus(g(), const DayProgress()), at(21, 0)), isFalse);
      expect(reminderDue(goal, goalStatus(goal, const DayProgress(questions: 10)), at(21, 0)), isFalse);
    });
  });

  group('Goals.sanitize', () {
    test('keeps valid values and repairs the rest field by field', () {
      expect(Goals.sanitize({'questions': 20, 'minutes': 30, 'remind': true, 'remindAt': '07:30'}), g(questions: 20, minutes: 30, remind: true, remindAt: '07:30'));
      expect(Goals.sanitize({'questions': 0, 'minutes': -5, 'remind': 'yes', 'remindAt': '25:00'}), Goals.off);
      final big = Goals.sanitize({'questions': 12.9, 'minutes': 100000});
      expect((big.questions, big.minutes), (12, 600));
      expect(Goals.sanitize(null), Goals.off);
      expect(Goals.sanitize('junk'), Goals.off);
    });

    test('copyWith switches a goal off only when told to', () {
      final base = g(questions: 20, minutes: 30);
      expect(base.copyWith(remind: true).questions, 20);
      expect(base.copyWith(questions: null).questions, isNull);
      expect(base.copyWith(questions: null).minutes, 30);
      expect(base.copyWith(remindAt: 'bad').remindAt, '20:00');
    });
  });

  group('GoalsNotifier', () {
    test('saves goals on this device and reads them back', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      expect(c.read(goalsProvider), Goals.off);
      await c.read(goalsProvider.notifier).save(g(questions: 30, minutes: 45, remind: true, remindAt: '21:15'));
      expect(c.read(goalsProvider), g(questions: 30, minutes: 45, remind: true, remindAt: '21:15'));
      expect(jsonDecode(prefs.getString('goals')!), {'questions': 30, 'minutes': 45, 'remind': true, 'remindAt': '21:15'});

      final again = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(again.dispose);
      expect(again.read(goalsProvider), g(questions: 30, minutes: 45, remind: true, remindAt: '21:15'));
    });

    test('a damaged stored value reads as no goals', () async {
      SharedPreferences.setMockInitialValues({'goals': '{not json'});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      expect(c.read(goalsProvider), Goals.off);
    });
  });

  group('Repository.watchDayProgress', () {
    test('counts this local day over all banks, with the stats caps, minus withdrawn questions', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final repo = Repository(db, deviceId: 'me');
      await seedQs(db, n: 1, bank: 'a');
      await seedQs(db, n: 2, bank: 'b');
      await (db.update(db.questions)..where((q) => q.id.equals('b-q2'))).write(const QuestionsCompanion(hidden: Value(true)));
      final noon = DateTime(2026, 10, 5, 12).millisecondsSinceEpoch;
      Future<void> put(String id, String question, int answeredAt, {int duration = 30000, int? review}) =>
          db.into(db.attempts).insert(AttemptsCompanion.insert(
                id: id,
                questionId: question,
                deviceId: 'other',
                answerJson: '[0]',
                isCorrect: true,
                durationMs: Value(duration),
                reviewMs: Value(review),
                answeredAt: answeredAt,
              ));
      await put('a1', 'a-q1', noon - 3600000, review: 20000);
      await put('a2', 'b-q1', noon, duration: 10 * 60000, review: 60 * 60000); // another bank and device; capped to 2 + 3 min
      await put('a3', 'a-q1', DateTime(2026, 10, 5).millisecondsSinceEpoch); // midnight today counts
      await put('a4', 'a-q1', DateTime(2026, 10, 4, 23, 59, 59).millisecondsSinceEpoch); // yesterday does not
      await put('a5', 'a-q1', DateTime(2026, 10, 6).millisecondsSinceEpoch); // tomorrow does not
      await put('a6', 'b-q2', noon); // withdrawn
      await put('a7', 'gone', noon); // a question this device never had

      final p = await repo.watchDayProgress(DateTime(2026, 10, 5)).first;
      expect(p, DayProgress(questions: 3, ms: 50000 + (2 + 3) * 60000 + 30000));
      expect((await repo.watchDayProgress(DateTime(2026, 10, 4)).first).questions, 1);
      expect(await repo.watchDayProgress(DateTime(2026, 10, 10)).first, const DayProgress());
    });
  });

  group('GoalCard on the bank list', () {
    final noon = DateTime(2026, 10, 5, 12);

    /// One bank with [n] questions answered on [noon].
    Future<AppDatabase> answered(WidgetTester tester, int n) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库', count: 3);
        final qs = await seedQs(db, n: 3);
        final repo = Repository(db, deviceId: 'd', clock: () => noon);
        for (final q in qs.take(n)) {
          await repo.recordAnswer(question: q, selected: [1], durationMs: 1000);
        }
      });
      return db;
    }

    Future<void> pumpHome(WidgetTester tester, AppDatabase db, Map<String, Object> prefs, DateTime now) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sp),
          databaseProvider.overrideWithValue(db),
          apiProvider.overrideWithValue(FakeApi()),
          clockProvider.overrideWithValue(() => now),
        ],
        child: const MaterialApp(home: BanksPage()),
      ));
      await settleUi(tester);
    }

    String goals({int? q, int? m, bool remind = false, String at = '20:00'}) =>
        jsonEncode({'questions': q, 'minutes': m, 'remind': remind, 'remindAt': at});

    testWidgets('shows no progress card without a goal', (tester) async {
      final db = await answered(tester, 2);
      await pumpHome(tester, db, {}, noon);
      expect(find.byKey(const Key('goal-card')), findsNothing);
      await tearDownUi(tester, db);
    });

    testWidgets('shows how far today is toward each goal', (tester) async {
      final db = await answered(tester, 2);
      await pumpHome(tester, db, {'goals': goals(q: 5, m: 30)}, noon);
      expect(find.text('2 / 5 题'), findsOneWidget);
      expect(find.text('0 / 30 分钟'), findsOneWidget);
      expect(find.text('还差 3 题、30 分钟'), findsOneWidget);
      expect(find.textContaining('目标完成'), findsNothing);
      await tearDownUi(tester, db);
    });

    testWidgets('celebrates when the goal is met, and shows only the goals that are on', (tester) async {
      final db = await answered(tester, 3);
      await pumpHome(tester, db, {'goals': goals(q: 3)}, noon);
      expect(find.textContaining('今天的目标完成了'), findsOneWidget);
      expect(find.textContaining('分钟'), findsNothing);
      await tearDownUi(tester, db);
    });

    testWidgets('turns into a reminder once the set time has passed and the goal is still open', (tester) async {
      final db = await answered(tester, 1);
      await pumpHome(tester, db, {'goals': goals(q: 5, remind: true, at: '11:00')}, noon);
      expect(find.text('⏰ 还差 4 题'), findsOneWidget);
      await tearDownUi(tester, db);

      final early = await answered(tester, 1);
      await pumpHome(tester, early, {'goals': goals(q: 5, remind: true, at: '23:59')}, noon);
      expect(find.text('⏰ 还差 4 题'), findsNothing);
      expect(find.text('还差 4 题'), findsOneWidget);
      await tearDownUi(tester, early);
    });

    testWidgets('does not count yesterday\'s answers', (tester) async {
      final db = await answered(tester, 2);
      await pumpHome(tester, db, {'goals': goals(q: 5)}, noon.add(const Duration(days: 1)));
      expect(find.text('0 / 5 题'), findsOneWidget);
      await tearDownUi(tester, db);
    });
  });

  group('SettingsPage goals', () {
    testWidgets('sets and clears goals, with presets or a custom number, and the reminder time', (tester) async {
      final db = memoryDb();
      final container = await pumpWith(tester, db, const SettingsPage());
      await settleUi(tester);

      await tester.scrollUntilVisible(find.text('每天做题'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.widgetWithText(ChoiceChip, '20'));
      await tester.pump();
      expect(container.read(goalsProvider).questions, 20);

      await tester.scrollUntilVisible(find.text('每天学习'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.widgetWithText(ChoiceChip, '自定义').last);
      await tester.pump();
      expect(container.read(goalsProvider).minutes, 15, reason: 'switched on at the first preset');
      await tester.enterText(find.byType(TextFormField), '45');
      await tester.pump();
      expect(container.read(goalsProvider).minutes, 45);

      expect(find.text('提醒时间'), findsNothing);
      await tester.scrollUntilVisible(find.text('每日提醒'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(container.read(goalsProvider).remind, isTrue);
      expect(find.text('提醒时间'), findsOneWidget);
      expect(find.text('20:00'), findsOneWidget);
      expect(find.textContaining('不会在后台弹通知'), findsOneWidget);

      await tester.ensureVisible(find.text('每天做题'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '关闭').first);
      await tester.pump();
      expect(container.read(goalsProvider).questions, isNull);
      expect(container.read(goalsProvider).minutes, 45, reason: 'the other goal is untouched');
      await tearDownUi(tester, db);
    });
  });
}
