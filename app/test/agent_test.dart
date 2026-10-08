import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/agent_api.dart';
import 'package:quizmind_app/data/agent_models.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/agent/agent_controller.dart';
import 'package:quizmind_app/features/agent/agent_links.dart';
import 'package:quizmind_app/features/agent/agent_page.dart';
import 'package:quizmind_app/features/quiz/ai_explain_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_test.dart' show StubAdapter, storedQuestion;

Stream<Uint8List> chunks(List<String> parts) => Stream.fromIterable([
  for (final p in parts) Uint8List.fromList(utf8.encode(p)),
]);

String ev(String name, Map<String, dynamic> data) =>
    'event: $name\ndata: ${jsonEncode(data)}\n\n';

const draftJson = {
  'draft_id': 'D1',
  'lesson_id': 'L1',
  'type': 'single',
  'stem': '读写锁的特点是什么？',
  'options': ['多个读者同时持有', '只能一个读者', '写者可并行', '禁止写者'],
  'answer_index': 0,
  'explanation': '读者之间不互斥。',
  'difficulty': 2,
  'tags': ['锁'],
  'source_quote': '读写锁允许多个读者同时持有锁',
  'verified': false,
};

AgentDraft draft([String id = 'D1']) =>
    AgentDraft.fromJson({...draftJson, 'draft_id': id});

/// A scripted assistant that records what it was asked.
class FakeAgentApi implements AgentApi {
  AgentStatus? statusValue = const AgentStatus(
    available: true,
    model: 'm',
    verified: false,
  );
  Object? statusError;
  final requests = <AgentChatRequest>[];

  /// The events of the next answer; [holdOpen] then keeps the stream open until it is cancelled.
  List<AgentEvent> events = const [];
  bool holdOpen = false;
  Object? chatError;

  List<AgentDraft> stored = [];
  final accepted = <String>[];
  final discarded = <String>[];
  Object? decideError;

  @override
  Future<AgentStatus> status() async {
    final e = statusError;
    if (e != null) throw e;
    return statusValue!;
  }

  @override
  Stream<AgentEvent> chat(
    AgentChatRequest request, {
    CancelToken? cancel,
  }) async* {
    requests.add(request);
    final e = chatError;
    if (e != null) throw e;
    for (final x in events) {
      yield x;
    }
    if (holdOpen) {
      await cancel!.whenCancel;
      throw AgentException('已停止');
    }
  }

  @override
  Future<List<AgentDraft>> drafts(String conversationId) async => stored;

  @override
  Future<void> acceptDraft(String id) async {
    final e = decideError;
    if (e != null) throw e;
    accepted.add(id);
  }

  @override
  Future<void> discardDraft(String id) async {
    final e = decideError;
    if (e != null) throw e;
    discarded.add(id);
  }
}

Future<SharedPreferences> prefs([Map<String, Object> values = const {}]) async {
  SharedPreferences.resetStatic();
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Future<ProviderContainer> container(
  FakeAgentApi api, {
  Map<String, Object> prefValues = const {},
}) async {
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(await prefs(prefValues)),
      agentApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('parseAgentSse', () {
    test('reads named events, skips pings and unknown events, and copes with split chunks', () async {
      final body = chunks([
        ': ping\n\n',
        ev('start', {'conversation_id': 'c1'}).substring(0, 20),
        ev('start', {'conversation_id': 'c1'}).substring(20),
        ev('delta', {'text': '你'}),
        'event: future_thing\ndata: {"x":1}\n\n',
        ev('tool', {
          'id': 't1',
          'name': 'search_lessons',
          'label': '在讲义里查找「锁」',
          'status': 'running',
        }),
        ev('drafts', {
          'drafts': [draftJson],
        }),
        ev('done', {
          'stop': 'end_turn',
          'usage': {'input': 10, 'output': 3, 'cached': 0},
        }),
      ]);
      final out = await parseAgentSse(body).toList();
      expect(out.map((e) => e.runtimeType), [
        AgentStarted,
        AgentDelta,
        AgentToolEvent,
        AgentDraftsEvent,
        AgentDone,
      ]);
      expect((out[0] as AgentStarted).conversationId, 'c1');
      expect((out[2] as AgentToolEvent).label, '在讲义里查找「锁」');
      final drafts = (out[3] as AgentDraftsEvent).drafts;
      expect(drafts.single.id, 'D1');
      expect(drafts.single.options, hasLength(4));
      expect(drafts.single.verified, isFalse);
      expect((out[4] as AgentDone).inputTokens, 10);
    });

    test('a multi-byte character cut between chunks survives, and bad data is skipped', () async {
      final bytes = utf8.encode(ev('delta', {'text': '进程调度'}));
      final cut = bytes.indexOf(0xE8) + 1; // inside the first character
      final body = Stream.fromIterable([
        Uint8List.fromList(bytes.sublist(0, cut)),
        Uint8List.fromList(bytes.sublist(cut)),
        Uint8List.fromList(utf8.encode('event: delta\ndata: not json\n\n')),
        Uint8List.fromList(
          utf8.encode(
            ev('error', {'code': 'budget_exceeded', 'message': '今日额度已用完'}),
          ),
        ),
      ]);
      final out = await parseAgentSse(body).toList();
      expect((out[0] as AgentDelta).text, '进程调度');
      expect((out[1] as AgentErrorEvent).code, 'budget_exceeded');
      expect(out, hasLength(2));
    });

    test('an event at the very end of the body, without the blank line, is still delivered', () async {
      final out = await parseAgentSse(
        chunks(['event: delta\ndata: {"text":"尾"}']),
      ).toList();
      expect((out.single as AgentDelta).text, '尾');
    });
  });

  group('buildAgentHistory', () {
    AgentMsg msg(int id, String role, String text) =>
        AgentMsg(id: id, role: role, text: text);

    test(
      'leaves out empty answers and joins neighbours so roles alternate',
      () {
        final h = buildAgentHistory([
          msg(1, 'user', 'a'),
          msg(2, 'assistant', ''),
          msg(3, 'user', 'b'),
          msg(4, 'assistant', 'c'),
          msg(5, 'user', 'd'),
        ]);
        expect(h.map((t) => t.role), ['user', 'assistant', 'user']);
        expect(h.first.content, 'a\n\nb');
      },
    );

    test('drops the oldest messages beyond the count and the length the server takes', () {
      final many = [
        for (var i = 0; i < 40; i++)
          msg(i, i.isEven ? 'user' : 'assistant', 'm$i'),
      ];
      final h = buildAgentHistory(many);
      expect(h.length, lessThanOrEqualTo(agentMaxMessages));
      expect(h.first.role, 'user');
      expect(h.last.content, 'm39'.isEmpty ? '' : h.last.content);

      final long = [
        msg(1, 'user', '长' * 20000),
        msg(2, 'assistant', '答' * 5000),
        msg(3, 'user', '问'),
      ];
      final trimmed = buildAgentHistory(long);
      expect(
        trimmed.fold<int>(0, (n, t) => n + t.content.runes.length),
        lessThanOrEqualTo(agentMaxChars),
      );
      expect(trimmed.first.role, 'user');
      expect(trimmed.last.content, '问');
    });

    test('never starts with the assistant', () {
      final h = buildAgentHistory([
        msg(1, 'assistant', '你好'),
        msg(2, 'user', '问'),
      ]);
      expect(h.map((t) => t.role), ['user']);
    });
  });

  group('AgentController', () {
    const args = AgentArgs(mode: 'learn', bankId: 'b1', lessonId: 'L1');

    test('sends the history with the context and builds the answer from the events', () async {
      final api = FakeAgentApi()
        ..events = [
          const AgentStarted('c'),
          const AgentToolEvent(
            id: 't1',
            name: 'search_lessons',
            label: '在讲义里查找「锁」',
            status: 'running',
          ),
          const AgentToolEvent(
            id: 't1',
            name: 'search_lessons',
            label: '在讲义里查找「锁」',
            status: 'done',
          ),
          const AgentDelta('读写锁'),
          const AgentDelta('允许多个读者。'),
          const AgentDone(stop: 'end_turn'),
        ];
      final c = await container(api);
      final controller = c.read(agentControllerProvider(args).notifier);
      await controller.send('  讲讲读写锁  ');

      final req = api.requests.single;
      expect(req.mode, 'learn');
      expect(req.context.bankId, 'b1');
      expect(req.context.lessonId, 'L1');
      expect(req.conversationId, controller.conversationId);
      expect(req.messages.map((t) => t.content), ['讲讲读写锁']);
      expect(req.deviceId, isNotEmpty);

      final s = c.read(agentControllerProvider(args));
      expect(s.busy, isFalse);
      expect(s.messages.map((m) => m.role), ['user', 'assistant']);
      final bot = s.messages.last;
      expect(bot.text, '读写锁允许多个读者。');
      expect(bot.streaming, isFalse);
      expect(
        bot.tools.single.status,
        'done',
        reason: 'one row per tool call, updated in place',
      );

      // A second question carries the first exchange along as plain text.
      api.events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
      await controller.send('再讲讲');
      expect(api.requests.last.messages.map((t) => '${t.role}:${t.content}'), [
        'user:讲讲读写锁',
        'assistant:读写锁允许多个读者。',
        'user:再讲讲',
      ]);
    });

    test(
      'ignores a send while an answer is being written, and an empty one',
      () async {
        final api = FakeAgentApi()..holdOpen = true;
        final c = await container(api);
        c.listen(agentControllerProvider(args), (_, _) {});
        final controller = c.read(agentControllerProvider(args).notifier);
        final first = controller.send('问');
        await Future<void>.delayed(Duration.zero);
        expect(c.read(agentControllerProvider(args)).busy, isTrue);
        await controller.send('又问');
        await controller.send('   ');
        expect(api.requests, hasLength(1));
        controller.stop();
        await first;
      },
    );

    test('stop keeps what has arrived and says so, without an error', () async {
      final api = FakeAgentApi()
        ..events = [const AgentDelta('写到一半')]
        ..holdOpen = true;
      final c = await container(api);
      c.listen(agentControllerProvider(args), (_, _) {});
      final controller = c.read(agentControllerProvider(args).notifier);
      final sent = controller.send('问');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.stop();
      await sent;
      final bot = c.read(agentControllerProvider(args)).messages.last;
      expect(bot.text, '写到一半');
      expect(bot.note, '已停止');
      expect(bot.error, isNull);
      expect(c.read(agentControllerProvider(args)).busy, isFalse);
    });

    test('failures before and inside the stream end up on the answer, and the next question still works', () async {
      final api = FakeAgentApi()
        ..chatError = AgentException('访问令牌不对', status: 401);
      final c = await container(api);
      final controller = c.read(agentControllerProvider(args).notifier);
      await controller.send('问');
      expect(
        c.read(agentControllerProvider(args)).messages.last.error,
        '访问令牌不对',
      );

      api
        ..chatError = null
        ..events = [
          const AgentDelta('半'),
          const AgentErrorEvent(code: 'budget_exceeded', message: '今日额度已用完'),
        ];
      await controller.send('再问');
      final bot = c.read(agentControllerProvider(args)).messages.last;
      expect(bot.text, '半');
      expect(bot.error, '今日额度已用完');
      expect(c.read(agentControllerProvider(args)).busy, isFalse);
      // The failed answer has no words, so the history stays alternating.
      expect(api.requests.last.messages.map((t) => t.role), ['user']);
      expect(api.requests.last.messages.single.content, '问\n\n再问');
    });

    test('a tool that never reported back is not left spinning', () async {
      final api = FakeAgentApi()
        ..events = [
          const AgentToolEvent(
            id: 't',
            name: 'x',
            label: '查找',
            status: 'running',
          ),
          const AgentErrorEvent(code: 'timeout', message: '超时'),
        ];
      final c = await container(api);
      await c.read(agentControllerProvider(args).notifier).send('问');
      expect(
        c.read(agentControllerProvider(args)).messages.last.tools.single.status,
        'done',
      );
    });

    test('notes how a long answer ended', () async {
      final api = FakeAgentApi()
        ..events = [const AgentDelta('长'), const AgentDone(stop: 'max_tokens')];
      final c = await container(api);
      await c.read(agentControllerProvider(args).notifier).send('问');
      expect(
        c.read(agentControllerProvider(args)).messages.last.note,
        contains('截断'),
      );
    });

    group('drafts', () {
      const create = AgentArgs(mode: 'create', bankId: 'b1', lessonId: 'L1');

      Future<(ProviderContainer, AgentController, FakeAgentApi)>
      withDraft() async {
        final api = FakeAgentApi()
          ..events = [
            AgentDraftsEvent([draft()]),
            const AgentDelta('出了 1 道题。'),
            const AgentDone(stop: 'end_turn'),
          ];
        final c = await container(api);
        final controller = c.read(agentControllerProvider(create).notifier);
        await controller.send('出一道');
        return (c, controller, api);
      }

      test('a drafts event adds a card under the answer', () async {
        final (c, _, api) = await withDraft();
        final s = c.read(agentControllerProvider(create));
        expect(s.messages.last.draftIds, ['D1']);
        expect(s.drafts['D1']!.phase, DraftPhase.pending);
        expect(api.requests.single.mode, 'create');
      });

      test('accept and discard call the server and mark the card', () async {
        final (c, controller, api) = await withDraft();
        await controller.accept('D1');
        expect(api.accepted, ['D1']);
        expect(
          c.read(agentControllerProvider(create)).drafts['D1']!.phase,
          DraftPhase.accepted,
        );

        api.events = [
          AgentDraftsEvent([draft('D2')]),
          const AgentDone(stop: 'end_turn'),
        ];
        await controller.send('再来一道');
        await controller.discard('D2');
        expect(api.discarded, ['D2']);
        expect(
          c.read(agentControllerProvider(create)).drafts['D2']!.phase,
          DraftPhase.discarded,
        );
        expect(
          c.read(agentControllerProvider(create)).drafts['D1']!.phase,
          DraftPhase.accepted,
          reason: 'the other card is untouched',
        );
      });

      test('a refusal puts the card back with the reason, so it can be tried again', () async {
        final (c, controller, api) = await withDraft();
        api.decideError = AgentException('这一节讲义已经更新，这道草稿已过期', status: 400);
        await controller.accept('D1');
        final e = c.read(agentControllerProvider(create)).drafts['D1']!;
        expect(e.phase, DraftPhase.pending);
        expect(e.error, contains('已过期'));
        api.decideError = null;
        await controller.accept('D1');
        expect(
          c.read(agentControllerProvider(create)).drafts['D1']!.phase,
          DraftPhase.accepted,
        );
        expect(
          c.read(agentControllerProvider(create)).drafts['D1']!.error,
          isNull,
        );
      });

      test('a repeated drafts event does not reset a card the learner already decided on', () async {
        final (c, controller, api) = await withDraft();
        await controller.accept('D1');
        api.events = [
          AgentDraftsEvent([draft()]),
          const AgentDone(stop: 'end_turn'),
        ];
        await controller.send('再看看');
        expect(
          c.read(agentControllerProvider(create)).drafts['D1']!.phase,
          DraftPhase.accepted,
        );
      });

      test('the revision prompt names the draft', () async {
        final (_, controller, _) = await withDraft();
        final p = controller.revisionPrompt('D1');
        expect(p, contains('draft_id：D1'));
        expect(p, contains('读写锁的特点是什么？'));
      });

      test('reopening a question-writing chat brings back the drafts that still wait', () async {
        final api = FakeAgentApi()..stored = [draft('D7'), draft('D8')];
        final c = await container(api);
        c.listen(agentControllerProvider(create), (_, _) {});
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final s = c.read(agentControllerProvider(create));
        expect(s.messages.single.draftIds, ['D7', 'D8']);
        expect(s.messages.single.text, contains('2 道草稿'));
        expect(s.drafts.keys, containsAll(['D7', 'D8']));
      });

      test('the question-writing conversation id is remembered; a learning one is new each time', () async {
        final api = FakeAgentApi();
        final p = await prefs();
        final c1 = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(p),
            agentApiProvider.overrideWithValue(api),
          ],
        );
        final id1 = c1
            .read(agentControllerProvider(create).notifier)
            .conversationId;
        final learn1 = c1
            .read(agentControllerProvider(args).notifier)
            .conversationId;
        c1.dispose();
        final c2 = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(p),
            agentApiProvider.overrideWithValue(api),
          ],
        );
        addTearDown(c2.dispose);
        expect(
          c2.read(agentControllerProvider(create).notifier).conversationId,
          id1,
        );
        expect(
          c2.read(agentControllerProvider(args).notifier).conversationId,
          isNot(learn1),
        );
      });
    });
  });

  group('HttpAgentApi', () {
    HttpAgentApi apiWith(StubAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'http://srv'))
        ..httpClientAdapter = adapter;
      return HttpAgentApi(baseUrl: 'http://srv', token: 'tok', dio: dio);
    }

    ResponseBody json(Object body, {int status = 200}) =>
        ResponseBody.fromString(
          jsonEncode(body),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );

    test('status sends the token', () async {
      final adapter = StubAdapter(
        (_) => json({
          'available': true,
          'model': 'deepseek-flash',
          'verified': true,
        }),
      );
      final s = await apiWith(adapter).status();
      expect(s.available, isTrue);
      expect(s.model, 'deepseek-flash');
      expect(s.verified, isTrue);
      expect(adapter.last!.path, '/api/v1/agent/status');
      expect(adapter.last!.headers['Authorization'], 'Bearer tok');
    });

    test('chat posts the request and streams the events', () async {
      final adapter = StubAdapter(
        (_) => ResponseBody(
          chunks([
            ev('start', {'conversation_id': 'c'}),
            ': ping\n\n',
            ev('delta', {'text': '好'}),
            ev('done', {'stop': 'end_turn'}),
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
      );
      final events = await apiWith(adapter)
          .chat(
            AgentChatRequest(
              conversationId: 'c',
              mode: 'create',
              deviceId: 'dev',
              messages: const [AgentTurn('user', '出题')],
              context: const AgentContext(
                bankId: 'b',
                lessonId: 'L',
                questionId: 'q',
                selected: [1],
              ),
            ),
          )
          .toList();
      expect(events.map((e) => e.runtimeType), [
        AgentStarted,
        AgentDelta,
        AgentDone,
      ]);
      final body = adapter.last!.data as Map<String, dynamic>;
      expect(body['mode'], 'create');
      expect(body['device_id'], 'dev');
      expect(body['messages'], [
        {'role': 'user', 'content': '出题'},
      ]);
      expect(body['context'], {
        'bank_id': 'b',
        'lesson_id': 'L',
        'question': {
          'id': 'q',
          'selected': [1],
        },
      });
      expect(adapter.last!.headers['Authorization'], 'Bearer tok');
    });

    test(
      'answers before the stream starts become messages the learner can act on',
      () async {
        Future<AgentException> failing(
          int status, [
          Object body = const {'error': 'x'},
        ]) async {
          final api = apiWith(StubAdapter((_) => json(body, status: status)));
          try {
            await api
                .chat(
                  const AgentChatRequest(
                    conversationId: 'c',
                    mode: 'learn',
                    deviceId: 'd',
                    messages: [AgentTurn('user', 'q')],
                  ),
                )
                .toList();
          } on AgentException catch (e) {
            return e;
          }
          fail('expected an AgentException');
        }

        expect((await failing(401)).message, contains('访问令牌'));
        expect((await failing(404)).message, contains('还没有启用'));
        expect((await failing(429)).message, contains('同时进行的对话'));
        expect(
          (await failing(400, {
            'error': 'messages must hold 1 to 30 messages',
          })).message,
          contains('messages must hold'),
        );
        expect((await failing(500)).status, 500);
      },
    );

    test('drafts, accept and discard use the right paths', () async {
      final adapter = StubAdapter(
        (o) => json(
          o.path.contains('/drafts/')
              ? {'id': 'D1', 'status': 'needs_review'}
              : {
                  'drafts': [draftJson],
                },
        ),
      );
      final api = apiWith(adapter);
      expect((await api.drafts('conv 1')).single.id, 'D1');
      expect(adapter.last!.uri.queryParameters['conversation_id'], 'conv 1');
      await api.acceptDraft('D1');
      expect(adapter.last!.path, '/api/v1/agent/drafts/D1/accept');
      await api.discardDraft('D1');
      expect(adapter.last!.path, '/api/v1/agent/drafts/D1/discard');
    });
  });

  group('links', () {
    test('only lesson: and question: links are ours', () {
      expect(parseAgentLink('lesson:01ABC')!.kind, AgentLinkKind.lesson);
      expect(parseAgentLink('lesson:01ABC')!.id, '01ABC');
      expect(parseAgentLink('question:Q1')!.kind, AgentLinkKind.question);
      expect(parseAgentLink('https://example.com'), isNull);
      expect(parseAgentLink('lesson:'), isNull);
      expect(parseAgentLink(null), isNull);
    });
  });

  group('AgentPage', () {
    Future<void> pump(
      WidgetTester tester,
      FakeAgentApi api, {
      Map<String, Object> prefValues = const {'ai.token': 'tok'},
      AgentArgs args = const AgentArgs(mode: 'learn', bankId: 'b1'),
      String initialText = '',
      List<Override> overrides = const [],
    }) async {
      final sp = await prefs(prefValues);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(sp),
            agentApiProvider.overrideWithValue(api),
            ...overrides,
          ],
          child: MaterialApp(
            home: AgentPage(args: args, initialText: initialText),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('agent-input')), text);
      await tester.pump();
    }

    testWidgets('asks for a token when there is none, and cannot send', (
      tester,
    ) async {
      await pump(tester, FakeAgentApi(), prefValues: const {});
      expect(find.textContaining('还没有填访问令牌'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      await type(tester, '你好');
      final send = tester.widget<IconButton>(
        find.byKey(const ValueKey('agent-send')),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets(
      'says so when the token is wrong, or the server has no assistant',
      (tester) async {
        await pump(
          tester,
          FakeAgentApi()
            ..statusError = AgentException('访问令牌不对或还没设置', status: 401),
        );
        expect(find.text('访问令牌不对或还没设置'), findsOneWidget);
        expect(find.text('去设置'), findsOneWidget);

        await pump(
          tester,
          FakeAgentApi()
            ..statusError = AgentException('AI 助手还没有启用', status: 404),
        );
        expect(find.text('AI 助手还没有启用'), findsOneWidget);
        expect(find.text('去设置'), findsNothing);
      },
    );

    testWidgets('offline: explains and offers a retry, which brings it back', (
      tester,
    ) async {
      final api = FakeAgentApi()
        ..statusError = AgentException('连不上服务器，请确认地址正确并已联网');
      await pump(tester, api);
      expect(find.textContaining('连不上服务器'), findsOneWidget);
      await type(tester, '你好');
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
            .onPressed,
        isNull,
      );
      api.statusError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('连不上服务器'), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
      'a quick prompt asks right away; the answer and its lookups show',
      (tester) async {
        final api = FakeAgentApi()
          ..events = [
            const AgentToolEvent(
              id: 't',
              name: 'search_lessons',
              label: '在讲义里查找「调度」',
              status: 'running',
            ),
            const AgentToolEvent(
              id: 't',
              name: 'search_lessons',
              label: '在讲义里查找「调度」',
              status: 'done',
            ),
            const AgentDelta('常见的有 **时间片轮转**。'),
            const AgentDone(stop: 'end_turn'),
          ];
        await pump(tester, api);
        expect(find.text('我哪里比较薄弱？'), findsOneWidget);
        await tester.tap(find.text('我哪里比较薄弱？'));
        await tester.pumpAndSettle();
        expect(api.requests.single.messages.single.content, '我哪里比较薄弱？');
        expect(
          find.text('我哪里比较薄弱？'),
          findsOneWidget,
          reason: 'now it is a message, not a chip',
        );
        expect(find.text('在讲义里查找「调度」'), findsOneWidget);
        expect(
          find.textContaining('时间片轮转', findRichText: true),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'typing and sending clears the box; stop appears while the answer is written',
      (tester) async {
        final api = FakeAgentApi()
          ..events = [const AgentDelta('正在写')]
          ..holdOpen = true;
        await pump(tester, api);
        await type(tester, '讲讲死锁');
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('agent-input')))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.byKey(const ValueKey('agent-stop')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('agent-stop')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('agent-send')), findsOneWidget);
        expect(find.text('已停止'), findsOneWidget);
        expect(
          find.textContaining('正在写', findRichText: true),
          findsOneWidget,
          reason: 'what arrived is kept',
        );
      },
    );

    testWidgets('the initial text is put in the box, not sent', (tester) async {
      final api = FakeAgentApi();
      await pump(tester, api, initialText: '我还是没懂，');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('agent-input')))
            .controller!
            .text,
        '我还是没懂，',
      );
      expect(api.requests, isEmpty);
    });

    group('question-writing', () {
      const create = AgentArgs(mode: 'create', bankId: 'b1', lessonId: 'L1');

      FakeAgentApi withDraft() => FakeAgentApi()
        ..events = [
          AgentDraftsEvent([draft()]),
          const AgentDelta('出了 1 道题。'),
          const AgentDone(stop: 'end_turn'),
        ];

      testWidgets(
        'a draft shows as a card with the answer marked, and accepting says it went to review',
        (tester) async {
          tester.view.physicalSize = const Size(900, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final api = withDraft();
          await pump(tester, api, args: create);
          expect(find.text('出 5 道单选题'), findsOneWidget);
          await tester.tap(find.text('出 5 道单选题'));
          await tester.pumpAndSettle();

          expect(
            find.textContaining('读写锁的特点是什么？', findRichText: true),
            findsOneWidget,
          );
          expect(find.text('未经独立复核'), findsOneWidget);
          expect(find.text('多个读者同时持有'), findsOneWidget);
          expect(
            find.byIcon(Icons.check_circle),
            findsOneWidget,
            reason: 'only the right option is marked',
          );
          expect(find.text('单选题'), findsOneWidget);

          await tester.tap(find.text('采纳'));
          await tester.pumpAndSettle();
          expect(api.accepted, ['D1']);
          expect(find.text('已提交审核，通过后会出现在题库里'), findsOneWidget);
          expect(find.text('采纳'), findsNothing);
        },
      );

      testWidgets(
        'discarding folds the card away; asking for a rewrite fills the box with the draft id',
        (tester) async {
          tester.view.physicalSize = const Size(900, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final api = withDraft();
          await pump(tester, api, args: create);
          await tester.tap(find.text('出 3 道判断题'));
          await tester.pumpAndSettle();

          await tester.tap(find.text('让它改改'));
          await tester.pump();
          final text = tester
              .widget<TextField>(find.byKey(const ValueKey('agent-input')))
              .controller!
              .text;
          expect(text, startsWith('请修改这道草稿（draft_id：D1'));

          await tester.tap(find.text('丢弃'));
          await tester.pumpAndSettle();
          expect(api.discarded, ['D1']);
          expect(find.text('已丢弃'), findsOneWidget);
        },
      );

      testWidgets(
        'a refused accept shows the reason on the card and keeps the buttons',
        (tester) async {
          tester.view.physicalSize = const Size(900, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final api = withDraft();
          await pump(tester, api, args: create);
          await tester.tap(find.text('出 5 道单选题'));
          await tester.pumpAndSettle();
          api.decideError = AgentException('这一节讲义已经更新，这道草稿已过期', status: 400);
          await tester.tap(find.text('采纳'));
          await tester.pumpAndSettle();
          expect(find.textContaining('已过期'), findsOneWidget);
          expect(find.text('采纳'), findsOneWidget);
        },
      );

      testWidgets(
        'tells the writer when no second model checks the questions',
        (tester) async {
          await pump(tester, FakeAgentApi(), args: create);
          expect(find.textContaining('没有配置复核模型'), findsOneWidget);
          await pump(
            tester,
            FakeAgentApi()
              ..statusValue = const AgentStatus(
                available: true,
                model: 'm',
                verified: true,
              ),
            args: create,
          );
          expect(find.textContaining('没有配置复核模型'), findsNothing);
        },
      );
    });
  });

  group('entry points', () {
    // Leave the tree first and let its database streams end: closing a drift database waits for them.
    Future<void> closeDb(WidgetTester tester, AppDatabase db) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.runAsync(db.close);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    testWidgets(
      '"追问 AI" under the explanation opens the assistant on that question, only with a token',
      (tester) async {
        Future<AppDatabase> pumpCard(
          Map<String, Object> prefValues,
          FakeAgentApi api,
        ) async {
          final sp = await prefs(prefValues);
          final db = AppDatabase(NativeDatabase.memory());
          final q = await tester.runAsync(() => storedQuestion(db)) as Question;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                sharedPrefsProvider.overrideWithValue(sp),
                databaseProvider.overrideWithValue(db),
                agentApiProvider.overrideWithValue(api),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: AiExplainCard(
                      key: ValueKey(q.id),
                      question: q,
                      selected: const [2],
                    ),
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
          return db;
        }

        var db = await pumpCard(const {}, FakeAgentApi());
        expect(find.byKey(const ValueKey('ask-ai-more')), findsNothing);
        await closeDb(tester, db);

        final api = FakeAgentApi()
          ..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
        db = await pumpCard(const {'ai.token': 'tok'}, api);
        await tester.tap(find.byKey(const ValueKey('ask-ai-more')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('agent-input')))
              .controller!
              .text,
          '我还是没懂，',
        );
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pumpAndSettle();
        final req = api.requests.single;
        expect(req.mode, 'learn');
        expect(req.context.questionId, 'q1');
        expect(req.context.selected, [
          2,
        ], reason: 'the assistant is told what the learner picked');
        await closeDb(tester, db);
      },
    );
  });
}
