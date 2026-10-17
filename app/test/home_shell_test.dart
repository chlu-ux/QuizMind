import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/data/agent_models.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/agent/agent_controller.dart';
import 'package:quizmind_app/features/agent/agent_page.dart';
import 'package:quizmind_app/features/home/home_shell.dart';

import 'agent_test.dart' show FakeAgentApi;
import 'support.dart';

/// A sync that does nothing by itself; the test finishes it.
class _ManualSync extends SyncController {
  @override
  Future<void> run() async {}

  void finish(String message, {bool isError = false}) {
    state = const SyncStatus(running: true);
    state = SyncStatus(message: message, isError: isError);
  }
}

void main() {
  Future<AppDatabase> pumpShell(
    WidgetTester tester,
    FakeAgentApi api, {
    Map<String, Object> prefs = const {},
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final db = memoryDb();
    await pumpWith(
      tester,
      db,
      const HomeShell(),
      prefsValues: {'base_url': 'http://10.0.0.2:8080', 'ai.token': 'tok', ...prefs},
      overrides: [agentApiProvider.overrideWithValue(api), ...overrides],
    );
    await settleUi(tester);
    return db;
  }

  testWidgets('the assistant is the middle tab of the bottom bar', (tester) async {
    final db = await pumpShell(tester, FakeAgentApi());
    final labels = tester
        .widgetList<NavigationDestination>(find.byType(NavigationDestination))
        .map((d) => d.label)
        .toList();
    expect(labels, ['题库', '错题本', 'AI', '收藏', '设置']);
    await tearDownUi(tester, db);
  });

  testWidgets('the assistant is not started until its tab is opened, and keeps its place afterwards', (tester) async {
    final api = FakeAgentApi();
    final db = await pumpShell(tester, api);
    expect(find.byType(AgentPage), findsNothing, reason: 'nothing asks the server for the assistant at start-up');

    await tester.tap(find.text('AI'));
    await settleUi(tester);
    expect(find.byType(AgentPage), findsOneWidget);
    expect(find.text('AI 助手'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('agent-input')), '半截的问题');

    await tester.tap(find.byKey(const ValueKey('agent-back')));
    await settleUi(tester);
    await tester.tap(find.text('AI'));
    await settleUi(tester);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('agent-input'))).controller!.text,
      '半截的问题',
      reason: 'switching tabs does not lose what was typed',
    );
    await tearDownUi(tester, db);
  });

  testWidgets('"new conversation" in the tab starts over in place', (tester) async {
    final api = FakeAgentApi()..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
    final db = await pumpShell(tester, api);
    await tester.tap(find.text('AI'));
    await settleUi(tester);
    await tester.tap(find.text('我哪里比较薄弱？'));
    await settleUi(tester);
    expect(find.byKey(const ValueKey('agent-new')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-new')));
    await settleUi(tester);
    expect(find.byType(AgentPage), findsOneWidget, reason: 'replaced in place, not pushed on top');
    expect(find.byKey(const ValueKey('agent-new')), findsNothing, reason: 'an empty conversation again');
    expect(find.text('我哪里比较薄弱？'), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('the assistant tab takes the whole height; its back arrow returns to the tab before', (tester) async {
    final db = await pumpShell(tester, FakeAgentApi());
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('错题本'));
    await settleUi(tester);
    await tester.tap(find.text('AI'));
    await settleUi(tester);
    expect(find.byType(NavigationBar), findsNothing, reason: 'no bar over the conversation');
    expect(find.byKey(const ValueKey('agent-input')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-back')));
    await settleUi(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1, reason: 'the wrong-book tab it came from');
    await tearDownUi(tester, db);
  });

  testWidgets('the assistant opened from elsewhere has no bottom menu either', (tester) async {
    final db = await pumpShell(tester, FakeAgentApi());
    Navigator.of(tester.element(find.byType(HomeShell))).push(
      MaterialPageRoute<void>(builder: (_) => const AgentPage(args: AgentArgs(bankId: 'b1'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AgentPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('agent-back')), findsNothing, reason: 'the usual back button is there');
    expect(find.byType(BackButton), findsOneWidget);
    await tearDownUi(tester, db);
  });

  testWidgets('the assistant tab has no notice over its input box', (tester) async {
    final db = await pumpShell(tester, FakeAgentApi());
    // A notice that was up when the learner moved to the assistant goes away.
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(HomeShell)))..clearSnackBars();
    messenger.showSnackBar(const SnackBar(content: Text('已更新')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已更新'), findsOneWidget);
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('已更新'), findsNothing);
    await tearDownUi(tester, db);
  });

  testWidgets('a finished sync is reported on the tab being looked at, and not over the assistant', (tester) async {
    final sync = _ManualSync();
    final db = await pumpShell(tester, FakeAgentApi(), overrides: [syncProvider.overrideWith(() => sync)]);
    sync.finish('已更新');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已更新'), findsOneWidget, reason: 'the first tab is in front');
    ScaffoldMessenger.of(tester.element(find.byType(HomeShell))).clearSnackBars();
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    sync.finish('连不上服务器', isError: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('连不上服务器'), findsNothing, reason: 'it would sit on the input box');
    expect(find.byKey(const ValueKey('agent-input')), findsOneWidget);
    await tearDownUi(tester, db);
  });
}
