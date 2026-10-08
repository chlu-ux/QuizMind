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
import 'package:quizmind_app/features/agent/agent_files.dart';
import 'package:quizmind_app/features/agent/agent_links.dart';
import 'package:quizmind_app/features/agent/agent_history_page.dart';
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

  /// The conversations the server keeps, by id.
  final history = <String, AgentConversationDetail>{};
  final deleted = <String>[];
  Object? listError;
  var _clock = 0;

  /// Puts a conversation on the "server", as one that was talked in before.
  AgentConversationDetail keep(
    String id, {
    String mode = 'learn',
    String? title,
    String bankId = '',
    String lessonId = '',
    List<StoredMessage> messages = const [],
  }) {
    final pending = messages.fold<int>(0, (n, m) => n + m.drafts.where((d) => d.phase == StoredDraftPhase.pending).length);
    final d = AgentConversationDetail(
      AgentConversationItem(
        id: id, mode: mode, title: title ?? '对话 $id', bankId: bankId, lessonId: lessonId,
        messageCount: messages.length, pendingDrafts: pending, updatedAt: ++_clock,
      ),
      messages,
    );
    history[id] = d;
    return d;
  }
  final accepted = <String>[];
  final discarded = <String>[];
  Object? decideError;

  /// Files "on the server": uploaded and not sent yet.
  final uploads = <({String conversationId, String name, String id})>[];
  final removed = <String>[];

  /// Refuses the next upload with this.
  Object? uploadError;

  /// Holds uploads until completed, to see the state in between.
  Completer<void>? uploadGate;

  @override
  Future<AgentAttachment> uploadAttachment(String conversationId, String name, Uint8List bytes) async {
    await uploadGate?.future;
    final e = uploadError;
    if (e != null) throw e;
    final id = 'F${uploads.length + 1}';
    uploads.add((conversationId: conversationId, name: name, id: id));
    return AgentAttachment(id: id, name: name, mime: 'text/plain', size: bytes.length, chars: bytes.length);
  }

  @override
  Future<void> deleteAttachment(String id) async => removed.add(id);

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
  Future<AgentConversationPage> conversations({int? before, int limit = 30}) async {
    final e = listError;
    if (e != null) throw e;
    final rows = [for (final d in history.values) d.item]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final left = rows.where((c) => before == null || c.updatedAt < before).toList();
    return AgentConversationPage(left.take(limit).toList(), hasMore: left.length > limit);
  }

  @override
  Future<AgentConversationDetail> conversation(String id) async =>
      history[id] ?? (throw AgentException('这场对话已经不存在了，可能被删除了', status: 404));

  @override
  Future<void> deleteConversation(String id) async {
    if (history.remove(id) == null) throw AgentException('not found', status: 404);
    deleted.add(id);
  }

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

  group('AgentController', () {
    const args = AgentArgs(mode: 'learn', bankId: 'b1', lessonId: 'L1');

    test('sends the new question with the context and builds the answer from the events', () async {
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
      expect(req.message, '讲讲读写锁');
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

      // The server has the first exchange: a second question is only that question, in the same conversation.
      api.events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
      await controller.send('再讲讲');
      expect(api.requests.last.message, '再讲讲');
      expect(api.requests.last.conversationId, req.conversationId);
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
      expect(api.requests.last.message, '再问');
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

    group('files', () {
      PickedFile file(String name, {String text = '内容', int? size}) {
        final bytes = Uint8List.fromList(utf8.encode(text));
        return PickedFile(name: name, size: size ?? bytes.length, read: () async => bytes);
      }

      final ok = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];

      test('uploads for this conversation, sends the ids with the question and keeps the files on the message', () async {
        final api = FakeAgentApi()..events = ok;
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.addFiles([file('笔记.md'), file('b.txt')]);
        expect(api.uploads.map((u) => (u.conversationId, u.name)), [(controller.conversationId, '笔记.md'), (controller.conversationId, 'b.txt')]);
        expect(c.read(agentControllerProvider(args)).files.map((f) => f.status), [FileStatus.ready, FileStatus.ready]);

        await controller.send('总结一下');
        expect(api.requests[0].message, '总结一下');
        expect(api.requests[0].attachmentIds, ['F1', 'F2']);
        final s = c.read(agentControllerProvider(args));
        expect(s.messages[0].attachments.map((a) => a.name), ['笔记.md', 'b.txt']);
        expect(s.files, isEmpty);

        await controller.send('再问');
        expect(api.requests[1].attachmentIds, isEmpty);
      });

      test('a file with no question is a question of its own', () async {
        final api = FakeAgentApi()..events = ok;
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.send('  ');
        expect(api.requests, isEmpty);
        await controller.addFiles([file('a.md')]);
        await controller.send('');
        expect(api.requests.single.message, fileOnlyText);
      });

      test('does not send while a file is still going up', () async {
        final api = FakeAgentApi()
          ..events = ok
          ..uploadGate = Completer<void>();
        final c = await container(api);
        c.listen(agentControllerProvider(args), (_, _) {}); // keeps the controller alive across the gap
        final controller = c.read(agentControllerProvider(args).notifier);
        final adding = controller.addFiles([file('a.md')]);
        await Future<void>.delayed(Duration.zero);
        expect(c.read(agentControllerProvider(args)).uploading, isTrue);
        await controller.send('问');
        expect(api.requests, isEmpty);
        api.uploadGate!.complete();
        await adding;
        expect(c.read(agentControllerProvider(args)).uploading, isFalse);
        await controller.send('问');
        expect(api.requests.single.attachmentIds, ['F1']);
      });

      test('turns a wrong kind, an empty or a big file away without asking the server', () async {
        final api = FakeAgentApi();
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.addFiles([file('a.pdf'), file('empty.md', text: ''), file('big.txt', size: 512 * 1024 + 1)]);
        expect(api.uploads, isEmpty);
        final errors = c.read(agentControllerProvider(args)).files.map((f) => f.error).toList();
        expect(errors[0], contains('不支持这种文件'));
        expect(errors[1], '这个文件是空的');
        expect(errors[2], contains('太大了'));
        expect(c.read(agentControllerProvider(args)).canAttach, isTrue);
      });

      test('shows the reason when the server refuses, and the file can be dismissed', () async {
        final api = FakeAgentApi()..uploadError = AgentException('这个文件不是 UTF-8 文本', status: 400);
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.addFiles([file('gbk.txt')]);
        final f = c.read(agentControllerProvider(args)).files.single;
        expect((f.status, f.error), (FileStatus.error, '这个文件不是 UTF-8 文本'));
        await controller.removeFile(f.key);
        expect(c.read(agentControllerProvider(args)).files, isEmpty);
        expect(api.removed, isEmpty, reason: 'it never reached the server');
      });

      test('removing a file that reached the server removes it there', () async {
        final api = FakeAgentApi();
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.addFiles([file('a.md')]);
        await controller.removeFile(c.read(agentControllerProvider(args)).files.single.key);
        expect(api.removed, ['F1']);
        expect(c.read(agentControllerProvider(args)).files, isEmpty);
      });

      test('stops at four files for a message and eight for the conversation', () async {
        final api = FakeAgentApi()..events = ok;
        final c = await container(api);
        final controller = c.read(agentControllerProvider(args).notifier);
        await controller.addFiles([for (var i = 0; i < 5; i++) file('f$i.md')]);
        var s = c.read(agentControllerProvider(args));
        expect(s.readyFiles, hasLength(4));
        expect(s.files[4].error, contains('最多'));
        expect(s.canAttach, isFalse);
        await controller.removeFile(s.files[4].key);
        await controller.send('问');
        await controller.addFiles([for (var i = 0; i < 4; i++) file('g$i.md')]);
        s = c.read(agentControllerProvider(args));
        expect(s.fileCount, 8);
        expect(s.canAttach, isFalse);
        await controller.addFiles([file('last.md')]);
        expect(c.read(agentControllerProvider(args)).files.last.error, contains('最多'));
        expect(api.uploads, hasLength(8));
      });
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

      test('every conversation is new: no id is remembered between them', () async {
        final api = FakeAgentApi();
        final c = await container(api);
        final a = c.read(agentControllerProvider(create).notifier).conversationId;
        final b = c.read(agentControllerProvider(args).notifier).conversationId;
        expect(a, isNot(b));
        // The same starting point asked for as a new conversation is not the one that is open.
        final fresh = AgentArgs(mode: 'create', bankId: 'b1', lessonId: 'L1', fresh: DateTime.now().microsecondsSinceEpoch);
        expect(c.read(agentControllerProvider(fresh).notifier).conversationId, isNot(a));
      });
    });
  });

  group('a stored conversation', () {
    final stored = [
      const StoredMessage(id: 1, role: 'user', text: '出 3 道题'),
      StoredMessage(
        id: 2,
        role: 'assistant',
        text: '出好了',
        note: '已停止',
        tools: const [StoredTool(id: 't', label: '读取讲义', status: 'done')],
        drafts: [
          StoredDraft(draft('D1'), StoredDraftPhase.accepted),
          StoredDraft(draft('D2'), StoredDraftPhase.discarded),
          StoredDraft(draft('D3'), StoredDraftPhase.pending),
        ],
      ),
      const StoredMessage(id: 3, role: 'user', text: '再来'),
      const StoredMessage(id: 4, role: 'assistant', text: '', error: '今日额度用完'),
    ];
    const open = AgentArgs(mode: 'create', bankId: 'b1', lessonId: 'L1', conversationId: 'old-1');

    test('is read back: messages, lookups, notes, and the cards as they stood', () async {
      final api = FakeAgentApi()..keep('old-1', mode: 'create', bankId: 'b1', lessonId: 'L1', messages: stored);
      final c = await container(api);
      c.listen(agentControllerProvider(open), (_, _) {});
      expect(c.read(agentControllerProvider(open)).opening, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final s = c.read(agentControllerProvider(open));
      expect(s.opening, isFalse);
      expect(s.openError, isNull);
      expect(c.read(agentControllerProvider(open).notifier).conversationId, 'old-1');
      expect(s.messages.map((m) => [m.role, m.text]), [['user', '出 3 道题'], ['assistant', '出好了'], ['user', '再来'], ['assistant', '']]);
      expect(s.messages[1].note, '已停止');
      expect(s.messages[1].draftIds, ['D1', 'D2', 'D3']);
      expect(s.messages[1].tools.single.label, '读取讲义');
      expect(s.messages[3].error, '今日额度用完');
      expect(s.messages[0].error, isNull);
      expect({for (final e in s.drafts.entries) e.key: e.value.phase}, {
        'D1': DraftPhase.accepted,
        'D2': DraftPhase.discarded,
        'D3': DraftPhase.pending,
      });
    });

    test('carries on in the same conversation, and a card that waits can still be decided', () async {
      final api = FakeAgentApi()
        ..keep('old-1', mode: 'create', bankId: 'b1', lessonId: 'L1', messages: stored)
        ..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
      final c = await container(api);
      c.listen(agentControllerProvider(open), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final controller = c.read(agentControllerProvider(open).notifier);
      await controller.send('再出两道');
      expect(api.requests.single.conversationId, 'old-1');
      expect(api.requests.single.mode, 'create');
      expect(api.requests.single.message, '再出两道');
      expect(api.requests.single.context.lessonId, 'L1');
      await controller.accept('D3');
      expect(api.accepted, ['D3']);
      expect(c.read(agentControllerProvider(open)).drafts['D3']!.phase, DraftPhase.accepted);
    });

    test('says why it could not be opened, and tries again', () async {
      final api = FakeAgentApi();
      final c = await container(api);
      c.listen(agentControllerProvider(open), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.read(agentControllerProvider(open)).openError, contains('已经不存在'));
      // Asking is refused while it is not open.
      final controller = c.read(agentControllerProvider(open).notifier);
      await controller.send('问');
      expect(api.requests, isEmpty);

      api.keep('old-1', mode: 'create', bankId: 'b1', lessonId: 'L1', messages: stored);
      await controller.open();
      expect(c.read(agentControllerProvider(open)).openError, isNull);
      expect(c.read(agentControllerProvider(open)).messages, hasLength(4));
    });
  });

  group('files in a stored conversation', () {
    test('the messages that carried files show them, and they count towards the limit', () async {
      final api = FakeAgentApi()
        ..keep('c1', messages: const [
          StoredMessage(
            id: 1,
            role: 'user',
            text: '看',
            attachments: [AgentAttachment(id: 'A1', name: 'n.md', mime: 'text/markdown', size: 3, chars: 3)],
          ),
          StoredMessage(id: 2, role: 'assistant', text: '好'),
        ]);
      final c = await container(api);
      const a = AgentArgs(mode: 'learn', conversationId: 'c1');
      c.listen(agentControllerProvider(a), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final s = c.read(agentControllerProvider(a));
      expect(s.messages[0].attachments.map((x) => x.name), ['n.md']);
      expect(s.fileCount, 1);
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

    test('uploads a file as a form with the conversation and the token, and removes one', () async {
      final adapter = StubAdapter(
        (o) => o.method == 'POST'
            ? json({'id': 'F1', 'kind': 'text', 'name': '笔记.md', 'mime': 'text/markdown', 'size': 6, 'chars': 2}, status: 201)
            : ResponseBody.fromString('', 204),
      );
      final api = apiWith(adapter);
      final a = await api.uploadAttachment('c1', '笔记.md', Uint8List.fromList(utf8.encode('# 笔记')));
      expect((a.id, a.name, a.mime, a.size, a.chars), ('F1', '笔记.md', 'text/markdown', 6, 2));
      expect(adapter.last!.path, '/api/v1/agent/attachments');
      expect(adapter.last!.headers['Authorization'], 'Bearer tok');
      final form = adapter.last!.data as FormData;
      expect(Map.fromEntries(form.fields)['conversation_id'], 'c1');
      expect(form.files.single.key, 'file');
      expect(form.files.single.value.filename, '笔记.md');

      await api.deleteAttachment('F/1');
      expect(adapter.last!.method, 'DELETE');
      expect(adapter.last!.path, '/api/v1/agent/attachments/F%2F1');
    });

    test("an upload's refusal is shown as the server worded it; an old server is named", () async {
      final bytes = Uint8List.fromList([120]);
      var api = apiWith(StubAdapter((_) => json({'error': '一场对话最多 8 个文件'}, status: 400)));
      await expectLater(
        api.uploadAttachment('c1', 'a.md', bytes),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', '一场对话最多 8 个文件')),
      );
      api = apiWith(StubAdapter((_) => json({'error': 'not found'}, status: 404)));
      await expectLater(
        api.uploadAttachment('c1', 'a.md', bytes),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', contains('更新服务端'))),
      );
      api = apiWith(StubAdapter((_) => ResponseBody.fromString('', 413)));
      await expectLater(
        api.uploadAttachment('c1', 'a.md', bytes),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', contains('太大'))),
      );
    });

    test('reads the files of a stored conversation', () async {
      final api = apiWith(StubAdapter((_) => json({
            'id': 'c1',
            'mode': 'learn',
            'title': 't',
            'messages': [
              {
                'id': 1,
                'role': 'user',
                'text': '看',
                'attachments': [
                  {'id': 'A1', 'kind': 'text', 'name': 'n.md', 'mime': 'text/markdown', 'size': 3, 'chars': 3},
                ],
              },
              {'id': 2, 'role': 'assistant', 'text': '好'},
            ],
          })));
      final c = await api.conversation('c1');
      expect(c.messages[0].attachments.single.name, 'n.md');
      expect(c.messages[1].attachments, isEmpty);
    });

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
              message: '出题',
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
      expect(body['conversation_id'], 'c');
      expect(body['message'], {'text': '出题', 'attachment_ids': []});
      expect(body.containsKey('messages'), isFalse);
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
                    message: 'q',
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

    test('accept and discard use the right paths', () async {
      final adapter = StubAdapter((_) => json({'id': 'D1', 'status': 'needs_review'}));
      final api = apiWith(adapter);
      await api.acceptDraft('D1');
      expect(adapter.last!.path, '/api/v1/agent/drafts/D1/accept');
      await api.discardDraft('D1');
      expect(adapter.last!.path, '/api/v1/agent/drafts/D1/discard');
    });

    test('lists conversations, reads one back and deletes one', () async {
      final adapter = StubAdapter((o) {
        if (o.method == 'DELETE') return json({});
        if (o.path == '/api/v1/agent/conversations') {
          return json({
            'items': [
              {'id': 'c1', 'mode': 'create', 'title': '出题', 'bank_id': 'b1', 'message_count': 2, 'pending_drafts': 1, 'updated_at': 99},
            ],
            'has_more': true,
          });
        }
        return json({
          'id': 'c 1', 'mode': 'create', 'title': '出题', 'bank_id': 'b1', 'lesson_id': 'L1',
          'messages': [
            {'id': 1, 'role': 'user', 'text': '出一道题'},
            {
              'id': 2, 'role': 'assistant', 'text': '好', 'note': '已停止',
              'tools': [{'id': 't', 'label': '查找', 'status': 'done'}],
              'drafts': [
                {...draftJson, 'phase': 'accepted'},
                {...draftJson, 'draft_id': 'D2', 'phase': 'weird'},
              ],
            },
          ],
        });
      });
      final api = apiWith(adapter);

      final page = await api.conversations(before: 120, limit: 10);
      expect(adapter.last!.uri.queryParameters, {'before': '120', 'limit': '10'});
      expect(page.hasMore, isTrue);
      expect(page.items.single.title, '出题');
      expect(page.items.single.pendingDrafts, 1);
      expect(page.items.single.bankId, 'b1');

      final c = await api.conversation('c 1');
      expect(adapter.last!.path, '/api/v1/agent/conversations/c%201');
      expect(c.item.mode, 'create');
      expect(c.item.lessonId, 'L1');
      expect(c.messages[1].note, '已停止');
      expect(c.messages[1].tools.single.status, 'done');
      expect(c.messages[1].drafts.map((d) => [d.draft.id, d.phase]), [
        ['D1', StoredDraftPhase.accepted],
        ['D2', StoredDraftPhase.pending],
      ]);

      await api.deleteConversation('c 1');
      expect(adapter.last!.method, 'DELETE');
      expect(adapter.last!.path, '/api/v1/agent/conversations/c%201');
    });

    test('a server from before history says so, instead of "the assistant is not enabled"', () async {
      final api = apiWith(StubAdapter((_) => json({'error': 'not found'}, status: 404)));
      for (final call in [() => api.conversations(), () => api.deleteConversation('c')]) {
        final e = await call().then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<AgentException>().having((x) => x.message, 'message', allOf(contains('更新服务端'), isNot(contains('助手')))));
      }
    });

    test('a missing conversation says so, and one that is being answered is a message', () async {
      var status = 404;
      final api = apiWith(StubAdapter((_) => json({'error': 'x'}, status: status)));
      final missing = await api.conversation('c').then<Object?>((_) => null, onError: (Object e) => e);
      expect(missing, isA<AgentException>().having((x) => x.message, 'message', contains('已经不存在')));
      status = 409;
      final busy = await api.deleteConversation('c').then<Object?>((_) => null, onError: (Object e) => e);
      expect(busy, isA<AgentException>().having((x) => x.status, 'status', 409).having((x) => x.message, 'message', contains('还在回答')));
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
        expect(api.requests.single.message, '我哪里比较薄弱？');
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

    group('files', () {
      PickedFile pick(String name, {String text = '# 笔记'}) {
        final bytes = Uint8List.fromList(utf8.encode(text));
        return PickedFile(name: name, size: bytes.length, read: () async => bytes);
      }

      Override picker(List<PickedFile> files) => agentFilePickerProvider.overrideWithValue(() async => files);

      Future<void> attach(WidgetTester tester) async {
        await tester.tap(find.byKey(const ValueKey('agent-attach')));
        await tester.pumpAndSettle();
      }

      testWidgets('a chosen file shows above the box, goes with the question, and shows as a tag on it', (tester) async {
        final api = FakeAgentApi()..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
        await pump(tester, api, overrides: [picker([pick('笔记.md')])]);
        expect(find.byKey(const ValueKey('agent-files')), findsNothing);

        await attach(tester);
        expect(find.byKey(const ValueKey('agent-file')), findsOneWidget);
        expect(find.textContaining('笔记.md'), findsOneWidget);

        await type(tester, '总结一下');
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pumpAndSettle();
        expect(api.requests.single.message, '总结一下');
        expect(api.requests.single.attachmentIds, ['F1']);
        expect(find.byKey(const ValueKey('agent-files')), findsNothing);
        expect(find.byKey(const ValueKey('agent-file-tag')), findsOneWidget);
        expect(find.text('📎 笔记.md'), findsOneWidget);
      });

      testWidgets('a file alone can be sent', (tester) async {
        final api = FakeAgentApi()..events = [const AgentDone(stop: 'end_turn')];
        await pump(tester, api, overrides: [picker([pick('a.md')])]);
        await attach(tester);
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pumpAndSettle();
        expect(api.requests.single.message, fileOnlyText);
      });

      testWidgets('shows why a file was turned away, and lets it be taken off', (tester) async {
        final api = FakeAgentApi();
        await pump(tester, api, overrides: [picker([pick('a.pdf')])]);
        await attach(tester);
        expect(find.textContaining('不支持这种文件'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('agent-file-remove')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('agent-files')), findsNothing);
        expect(api.uploads, isEmpty);
      });

      testWidgets('removing an uploaded file removes it on the server', (tester) async {
        final api = FakeAgentApi();
        await pump(tester, api, overrides: [picker([pick('a.md')])]);
        await attach(tester);
        await tester.tap(find.byKey(const ValueKey('agent-file-remove')));
        await tester.pumpAndSettle();
        expect(api.removed, ['F1']);
      });

      testWidgets('the plus button is off without a connection, and when the files are at their limit', (tester) async {
        final api = FakeAgentApi();
        await pump(tester, api, prefValues: const {});
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('agent-attach'))).onPressed, isNull);
      });

      testWidgets('four files fill a message', (tester) async {
        final api = FakeAgentApi();
        await pump(tester, api, overrides: [picker([for (var i = 1; i <= 4; i++) pick('$i.md')])]);
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('agent-attach'))).onPressed, isNotNull);
        await attach(tester);
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('agent-attach'))).onPressed, isNull);
      });
    });

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

  group('history', () {
    final banks = banksProvider.overrideWith(
      (ref) => Stream.value([const Bank(id: 'b1', title: '软件设计师（中级）', description: '', questionCount: 3)]),
    );

    Future<void> pumpHistory(WidgetTester tester, FakeAgentApi api, {Map<String, Object> prefValues = const {'ai.token': 'tok'}, Widget? home}) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sp = await prefs(prefValues);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(), // a second pump in one test starts a new app, not an update of the first
          overrides: [sharedPrefsProvider.overrideWithValue(sp), agentApiProvider.overrideWithValue(api), banks],
          child: MaterialApp(home: home ?? const AgentHistoryPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    FakeAgentApi withOld() {
      final api = FakeAgentApi()
        ..keep('c-old', title: '死锁的四个条件', bankId: 'b1', messages: const [StoredMessage(id: 1, role: 'user', text: '死锁？')])
        ..keep('c-make', mode: 'create', title: '用这一节出 3 道单选题', bankId: 'b1', lessonId: 'L1', messages: [
          const StoredMessage(id: 1, role: 'user', text: '出 3 道题'),
          StoredMessage(id: 2, role: 'assistant', text: '出好了：', tools: const [StoredTool(id: 't', label: '读取讲义「锁」', status: 'done')], drafts: [
            StoredDraft(draft('D1'), StoredDraftPhase.pending),
            StoredDraft(draft('D2'), StoredDraftPhase.accepted),
            StoredDraft(draft('D3'), StoredDraftPhase.discarded),
          ]),
        ]);
      return api;
    }

    testWidgets('lists the conversations newest first, with their kind, bank and waiting drafts', (tester) async {
      await pumpHistory(tester, withOld());
      final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.title as Text).data).toList();
      expect(titles, ['用这一节出 3 道单选题', '死锁的四个条件']);
      final first = tester.widget<ListTile>(find.byType(ListTile).first);
      final sub = (first.subtitle as Text).data!;
      expect(sub, contains('出题'));
      expect(sub, contains('软件设计师（中级）'));
      expect(sub, contains('1 道草稿待处理'));
      final second = (tester.widget<ListTile>(find.byType(ListTile).last).subtitle as Text).data!;
      expect(second, contains('问 AI'));
      expect(second, isNot(contains('待处理')));
    });

    testWidgets('says so when there is nothing, no token, or the server cannot be reached (and tries again)', (tester) async {
      await pumpHistory(tester, FakeAgentApi());
      expect(find.byKey(const ValueKey('history-empty')), findsOneWidget);

      await pumpHistory(tester, FakeAgentApi(), prefValues: const {});
      expect(find.byKey(const ValueKey('history-no-token')), findsOneWidget);

      final api = FakeAgentApi()
        ..keep('c-1')
        ..listError = AgentException('连不上服务器，请确认地址正确并已联网');
      await pumpHistory(tester, api);
      expect(find.byKey(const ValueKey('history-error')), findsOneWidget);
      expect(find.textContaining('连不上服务器'), findsOneWidget);
      api.listError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
    });

    testWidgets('loads more when there are more than a page', (tester) async {
      final api = FakeAgentApi();
      for (var i = 1; i <= 35; i++) {
        api.keep('c-$i', title: '第 $i 场');
      }
      await pumpHistory(tester, api);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('history-more')), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('history-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history-more')), findsNothing);
      await tester.scrollUntilVisible(find.text('第 1 场'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('第 1 场'), findsOneWidget);
    });

    testWidgets('deletes a conversation after asking, and keeps it when the learner says no', (tester) async {
      final api = withOld();
      await pumpHistory(tester, api);
      await tester.tap(find.byTooltip('删除对话').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 道没处理的草稿也会被丢弃'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty);
      expect(find.byType(ListTile), findsNWidgets(2));

      await tester.tap(find.byTooltip('删除对话').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(api.deleted, ['c-make']);
      expect(find.byType(ListTile), findsOneWidget);
    });

    testWidgets('opens a conversation: its messages, lookups and cards as they stood; it carries on', (tester) async {
      final api = withOld()..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
      await pumpHistory(tester, api);
      await tester.tap(find.text('用这一节出 3 道单选题'));
      await tester.pumpAndSettle();

      expect(find.text('AI 出题'), findsOneWidget);
      expect(find.text('出 3 道题'), findsOneWidget);
      expect(find.text('读取讲义「锁」'), findsOneWidget);
      expect(find.text('采纳'), findsOneWidget, reason: 'only the card that still waits has buttons');
      expect(find.text('已提交审核，通过后会出现在题库里'), findsOneWidget);
      expect(find.text('已丢弃'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('agent-input')), '再出一道');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pumpAndSettle();
      final req = api.requests.single;
      expect(req.conversationId, 'c-make');
      expect(req.mode, 'create');
      expect(req.message, '再出一道');
      expect(req.context.bankId, 'b1');
      expect(req.context.lessonId, 'L1');
    });

    testWidgets('a stored conversation opens at its end, where the last answer is', (tester) async {
      final api = FakeAgentApi()
        ..keep('long', messages: [
          for (var i = 0; i < 12; i++) ...[
            StoredMessage(id: 2 * i + 1, role: 'user', text: '问题 $i'),
            StoredMessage(id: 2 * i + 2, role: 'assistant', text: '回答 $i\n\n${List.filled(60, '很长的一段话。').join()}'),
          ],
        ]);
      await pumpHistory(tester, api, home: const AgentPage(args: AgentArgs(mode: 'learn', conversationId: 'long')));
      await tester.pumpAndSettle();
      expect(find.textContaining('回答 11'), findsOneWidget, reason: 'the last answer is on screen');
      expect(find.text('问题 0'), findsNothing, reason: 'and the start is not');
    });

    testWidgets('says so when the conversation is gone, with a way back', (tester) async {
      final api = FakeAgentApi();
      await pumpHistory(
        tester,
        api,
        home: const AgentPage(args: AgentArgs(mode: 'learn', conversationId: 'nope')),
      );
      expect(find.byKey(const ValueKey('agent-open-error')), findsOneWidget);
      expect(find.textContaining('已经不存在'), findsOneWidget);
      expect(find.text('回到历史'), findsOneWidget);
    });

    testWidgets('the chat page links to the history, and "new conversation" starts over from the same place', (tester) async {
      final api = FakeAgentApi()..events = [const AgentDelta('好'), const AgentDone(stop: 'end_turn')];
      await pumpHistory(
        tester,
        api,
        home: const AgentPage(args: AgentArgs(mode: 'learn', bankId: 'b1', lessonId: 'L1')),
      );
      expect(find.byKey(const ValueKey('agent-new')), findsNothing, reason: 'nothing to leave yet');
      await tester.tap(find.text('讲一下这一节'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-new')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('agent-new')));
      await tester.pumpAndSettle();
      expect(find.text('可以问我讲义里的内容、你的薄弱点，或者让我出题考你。'), findsOneWidget);
      await tester.tap(find.text('讲一下这一节'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(2));
      expect(api.requests[1].conversationId, isNot(api.requests[0].conversationId));
      expect(api.requests[1].context.lessonId, 'L1');

      await tester.tap(find.byKey(const ValueKey('agent-history')));
      await tester.pumpAndSettle();
      expect(find.text('历史对话'), findsOneWidget);
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
