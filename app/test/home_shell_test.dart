import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/data/agent_models.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/agent/agent_page.dart';
import 'package:quizmind_app/features/home/home_shell.dart';

import 'agent_test.dart' show FakeAgentApi;
import 'support.dart';

void main() {
  Future<AppDatabase> pumpShell(WidgetTester tester, FakeAgentApi api, {Map<String, Object> prefs = const {}}) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final db = memoryDb();
    await pumpWith(
      tester,
      db,
      const HomeShell(),
      prefsValues: {'base_url': 'http://10.0.0.2:8080', 'ai.token': 'tok', ...prefs},
      overrides: [agentApiProvider.overrideWithValue(api)],
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

    await tester.tap(find.text('错题本'));
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
}
