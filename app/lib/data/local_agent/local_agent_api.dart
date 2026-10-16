/// The assistant on this device as an [AgentApi], and [HybridAgentApi], which uses the server's
/// assistant and falls back to this one when the server cannot be reached.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../agent_api.dart';
import '../agent_models.dart';
import '../models.dart';
import 'agent_spec.dart';
import 'anthropic_chat.dart';
import 'library.dart';
import 'local_agent.dart';
import 'local_agent_store.dart';

const _noFiles = '连不上服务器，暂时不能传文件，联网后再试';

class LocalAgentApi implements AgentApi {
  LocalAgentApi({
    required this.store,
    required this.library,
    required this.specOf,
    required this.llm,
    this.reportUsage,
  });

  final LocalAgentStore store;
  final AgentLibrary library;

  /// The spec kept on this device, if a sync ever brought one.
  final LocalAgentSpec? Function() specOf;
  final AnthropicChat llm;
  final void Function(AiUsage usage)? reportUsage;

  /// The assistant can run here: there is a model to call and instructions to give it.
  bool get available => specOf() != null;

  @override
  Future<AgentStatus> status() async {
    final spec = specOf();
    if (spec == null) {
      throw AgentException('本机还没有助手的配置：请在能连上服务器时同步一次', status: 404);
    }
    return AgentStatus(available: true, model: spec.model.model, verified: false, local: true);
  }

  @override
  Stream<AgentEvent> chat(AgentChatRequest request, {CancelToken? cancel}) {
    final spec = specOf();
    if (spec == null) {
      return Stream.error(AgentException('本机还没有助手的配置：请在能连上服务器时同步一次', status: 404));
    }
    return LocalAgent(spec: spec, chat: llm, library: library, store: store, reportUsage: reportUsage)
        .run(request, cancel: cancel);
  }

  @override
  Future<AgentConversationPage> conversations({int? before, int limit = 30}) =>
      store.conversations(before: before, limit: limit);

  @override
  Future<AgentConversationDetail> conversation(String id) async {
    final c = await store.conversation(id);
    if (c == null) throw AgentException('这场对话已经不存在了', status: 404);
    return c;
  }

  @override
  Future<void> deleteConversation(String id) => store.deleteConversation(id);

  @override
  Future<AgentAttachment> uploadAttachment(String conversationId, String name, Uint8List bytes) =>
      Future.error(AgentException(_noFiles));

  @override
  Future<void> deleteAttachment(String id) async {}

  @override
  Future<Uint8List> attachmentBytes(String id) => Future.error(AgentException(_noFiles));

  @override
  Future<void> acceptDraft(String id) => store.decide(id, adopt: true);

  @override
  Future<void> discardDraft(String id) => store.decide(id, adopt: false);
}

/// The server's assistant while the server answers, this device's while it does not. A request that finds
/// no server falls back at once; after that the server is not tried again for a minute, so a phone away
/// from home does not wait for a connection that is not coming on every message.
class HybridAgentApi implements AgentApi {
  HybridAgentApi({required this.server, required this.local, DateTime Function()? clock, this.retryAfter = const Duration(minutes: 1)})
      : _clock = clock ?? DateTime.now;

  final AgentApi server;
  final LocalAgentApi local;
  final Duration retryAfter;
  final DateTime Function() _clock;
  DateTime? _downSince;

  bool get _serverDown => _downSince != null && _clock().difference(_downSince!) < retryAfter;

  void _markDown() => _downSince = _clock();

  bool _canFallBack(Object e) => e is AgentException && e.unreachable && local.available;

  @override
  Future<AgentStatus> status() async {
    if (_serverDown && local.available) return local.status();
    try {
      final s = await server.status();
      _downSince = null;
      return s;
    } on AgentException catch (e) {
      if (!_canFallBack(e)) rethrow;
      _markDown();
      return local.status();
    }
  }

  @override
  Stream<AgentEvent> chat(AgentChatRequest request, {CancelToken? cancel}) async* {
    if (!(_serverDown && local.available)) {
      var started = false;
      try {
        await for (final ev in server.chat(request, cancel: cancel)) {
          started = true;
          yield ev;
        }
        _downSince = null;
        return;
      } on AgentException catch (e) {
        // Once the answer has begun the server has it; only a server that could not be reached at all
        // hands the question over.
        if (started || !_canFallBack(e)) rethrow;
        _markDown();
      }
    }
    yield* local.chat(request, cancel: cancel);
  }

  @override
  Future<AgentConversationPage> conversations({int? before, int limit = 30}) async {
    final mine = await local.conversations(before: before, limit: limit);
    try {
      final theirs = await server.conversations(before: before, limit: limit);
      final byId = {for (final c in theirs.items) c.id: c, for (final c in mine.items) c.id: c};
      final all = byId.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return AgentConversationPage(all.take(limit).toList(), hasMore: theirs.hasMore || mine.hasMore || all.length > limit);
    } on AgentException catch (e) {
      // Away from the server the history is what this device holds; with nothing of it, say why.
      if (e.unreachable && mine.items.isNotEmpty) return mine;
      rethrow;
    }
  }

  @override
  Future<AgentConversationDetail> conversation(String id) async {
    if (await local.store.hasConversation(id)) return local.conversation(id);
    return server.conversation(id);
  }

  @override
  Future<void> deleteConversation(String id) async {
    final here = await local.store.hasConversation(id);
    if (here) await local.deleteConversation(id);
    try {
      await server.deleteConversation(id);
    } on AgentException catch (e) {
      // A conversation that only exists here has nothing to delete there.
      if (!here || !(e.unreachable || e.status == 404)) rethrow;
    }
  }

  @override
  Future<AgentAttachment> uploadAttachment(String conversationId, String name, Uint8List bytes) =>
      server.uploadAttachment(conversationId, name, bytes);

  @override
  Future<void> deleteAttachment(String id) => server.deleteAttachment(id);

  @override
  Future<Uint8List> attachmentBytes(String id) => server.attachmentBytes(id);

  /// A question written on this device and not sent yet is decided here; any other goes to the server, and
  /// when that cannot be reached the decision waits here for the next sync.
  Future<void> _decide(String id, {required bool adopt}) async {
    final row = await local.store.question(id);
    if (row != null && row.localState == LocalState.pending) return local.store.decide(id, adopt: adopt);
    try {
      await (adopt ? server.acceptDraft(id) : server.discardDraft(id));
      // A decision that had been waiting for the server is told now.
      if (row != null && (row.localState == LocalState.adopt || row.localState == LocalState.discard)) {
        await local.store.settle(id, adopt: adopt);
      }
    } on AgentException catch (e) {
      if (row != null && e.unreachable) return local.store.decide(id, adopt: adopt);
      rethrow;
    }
  }

  @override
  Future<void> acceptDraft(String id) => _decide(id, adopt: true);

  @override
  Future<void> discardDraft(String id) => _decide(id, adopt: false);
}
