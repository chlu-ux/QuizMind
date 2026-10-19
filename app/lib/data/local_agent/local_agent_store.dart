/// What the assistant on this device keeps: its conversations, and the questions it wrote (which are
/// rows of the question bank, marked so a sync knows they still have to reach the server).
library;

import 'dart:convert';
import 'dart:math' show min;

import 'package:drift/drift.dart';

import '../agent_models.dart';
import '../database.dart';

/// [Questions.localState] values.
class LocalState {
  /// Written here, not on the server yet.
  static const pending = 'pending';

  /// The server turned it down; hidden, the reason is in [Questions.localNote].
  static const refused = 'refused';

  /// The server has it; the learner took it back / adopted it again while it could not be told.
  static const discard = 'discard';
  static const adopt = 'adopt';
}

/// How many messages of the history go to the model, and how many characters (the server's limits).
const historyMaxMessages = 30;
const historyMaxChars = 24000;

/// How many of the oldest messages go at once when the history is too long (the server's agentDropStep).
const historyDropStep = 10;

class LocalAgentStore {
  LocalAgentStore(this.db);

  final AppDatabase db;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  // ---- questions ----

  AgentDraft draftOf(Question q) {
    List<T> list<T>(String raw, T Function(Object?) f) {
      try {
        return [for (final x in jsonDecode(raw) as List) f(x)];
      } catch (_) {
        return <T>[];
      }
    }

    final answer = list<int>(q.answerJson, (x) => (x as num).toInt());
    return AgentDraft(
      id: q.id,
      lessonId: q.chunkId,
      type: q.type,
      stem: q.stem,
      options: list<String>(q.optionsJson, (x) => '$x'),
      answerIndex: answer.isEmpty ? 0 : answer.first,
      explanation: q.explanation,
      difficulty: q.difficulty,
      tags: list<String>(q.tagsJson, (x) => '$x'),
      sourceQuote: q.sourceQuote,
      verified: false,
      adopted: !q.hidden,
    );
  }

  Future<Question?> question(String id) =>
      (db.select(db.questions)..where((q) => q.id.equals(id))).getSingleOrNull();

  /// The questions the assistant wrote in a conversation on this device, in the order written.
  Future<List<Question>> conversationQuestions(String conversationId) => (db.select(db.questions)
        ..where((q) => q.agentConv.equals(conversationId))
        ..orderBy([(q) => OrderingTerm.asc(q.id)]))
      .get();

  Future<int> liveQuestionCount(String conversationId) async {
    final rows = await (db.select(db.questions)
          ..where((q) => q.agentConv.equals(conversationId) & q.hidden.equals(false)))
        .get();
    return rows.length;
  }

  Future<void> insertQuestion({
    required String id,
    required String bankId,
    required String lessonId,
    required String documentId,
    required String documentTitle,
    required int documentOrder,
    required String type,
    required String stem,
    required List<String> options,
    required int answerIndex,
    required String explanation,
    required int difficulty,
    required List<String> tags,
    required String sourceQuote,
    required String conversationId,
  }) =>
      db.into(db.questions).insert(QuestionsCompanion.insert(
        id: id,
        bankId: bankId,
        type: type,
        stem: stem,
        optionsJson: jsonEncode(options),
        answerJson: jsonEncode([answerIndex]),
        explanation: Value(explanation),
        difficulty: Value(difficulty),
        tagsJson: Value(jsonEncode(tags)),
        sourceQuote: Value(sourceQuote),
        documentId: Value(documentId),
        documentTitle: Value(documentTitle),
        documentOrder: Value(documentOrder),
        chunkId: Value(lessonId),
        syncSeq: 0,
        localState: const Value(LocalState.pending),
        agentConv: Value(conversationId),
      ));

  /// Takes a question out of the bank on this device ([adopt] false) or puts it back. One the server does
  /// not know yet simply stays here or not; one it knows is told at the next sync. Throws
  /// [AgentException] for a question the server turned down.
  Future<void> decide(String id, {required bool adopt}) async {
    final q = await question(id);
    if (q == null) throw AgentException('这道题已经不存在了', status: 404);
    if (q.localState == LocalState.refused) {
      throw AgentException('服务器没有通过这道题：${q.localNote.isEmpty ? '没有说明原因' : q.localNote}');
    }
    final state = q.localState == LocalState.pending
        ? LocalState.pending
        : (adopt ? LocalState.adopt : LocalState.discard);
    await (db.update(db.questions)..where((x) => x.id.equals(id)))
        .write(QuestionsCompanion(hidden: Value(!adopt), localState: Value(state)));
  }

  /// The server has been told what the learner decided: nothing is waiting any more.
  Future<void> settle(String id, {required bool adopt}) =>
      (db.update(db.questions)..where((q) => q.id.equals(id) & q.localState.isIn([LocalState.adopt, LocalState.discard])))
          .write(QuestionsCompanion(hidden: Value(!adopt), localState: const Value('')));

  // ---- conversations ----

  /// Makes sure the conversation exists, seeding it with [seed] (what was said before on the server) when
  /// it is new here. Returns whether it was new.
  Future<bool> ensureConversation({
    required String id,
    required String mode,
    required String bankId,
    required String lessonId,
    required String questionId,
    String briefing = '',
    required String firstText,
    List<AgentHistoryMessage> seed = const [],
  }) async {
    final have = await (db.select(db.agentConversations)..where((c) => c.id.equals(id))).getSingleOrNull();
    if (have != null) return false;
    final now = _now();
    final titleSource = seed.where((m) => m.role == 'user').map((m) => m.text).firstOrNull ?? firstText;
    await db.transaction(() async {
      await db.into(db.agentConversations).insert(AgentConversationsCompanion.insert(
            id: id,
            mode: Value(mode),
            title: Value(_title(titleSource)),
            bankId: Value(bankId),
            lessonId: Value(lessonId),
            questionId: Value(questionId),
            briefing: Value(briefing),
            createdAt: now,
            updatedAt: now,
          ));
      for (final m in seed) {
        await appendMessage(id, m.role, text: m.text);
      }
    });
    return true;
  }

  /// What the conversation began with, as far as the row says (not what the learner picked); null when it
  /// is not here.
  Future<AgentContext?> contextOf(String id) async {
    final c = await (db.select(db.agentConversations)..where((c) => c.id.equals(id))).getSingleOrNull();
    if (c == null) return null;
    return AgentContext(bankId: c.bankId, lessonId: c.lessonId, questionId: c.questionId);
  }

  /// The brief the conversation began with; empty when there is none (or it is not here).
  Future<String> briefingOf(String id) async {
    final c = await (db.select(db.agentConversations)..where((c) => c.id.equals(id))).getSingleOrNull();
    return c?.briefing ?? '';
  }

  String _title(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final r = t.runes.toList();
    return r.length > 30 ? '${String.fromCharCodes(r.sublist(0, 30))}…' : t;
  }

  Future<int> appendMessage(
    String conversationId,
    String role, {
    String text = '',
    List<StoredTool> tools = const [],
    List<String> draftIds = const [],
    String note = '',
    String error = '',
  }) async {
    final now = _now();
    final id = await db.into(db.agentMessages).insert(AgentMessagesCompanion.insert(
          conversationId: conversationId,
          role: role,
          body: Value(text),
          toolsJson: Value(jsonEncode([for (final t in tools) {'id': t.id, 'label': t.label, 'status': t.status}])),
          draftsJson: Value(jsonEncode(draftIds)),
          note: Value(note),
          error: Value(error),
          createdAt: now,
        ));
    await (db.update(db.agentConversations)..where((c) => c.id.equals(conversationId)))
        .write(AgentConversationsCompanion(updatedAt: Value(now)));
    return id;
  }

  Future<void> updateMessage(
    int id, {
    required String text,
    required List<StoredTool> tools,
    required List<String> draftIds,
    String note = '',
    String error = '',
  }) async {
    await (db.update(db.agentMessages)..where((m) => m.id.equals(id))).write(AgentMessagesCompanion(
      body: Value(text),
      toolsJson: Value(jsonEncode([for (final t in tools) {'id': t.id, 'label': t.label, 'status': t.status}])),
      draftsJson: Value(jsonEncode(draftIds)),
      note: Value(note),
      error: Value(error),
    ));
    final m = await (db.select(db.agentMessages)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (m != null) {
      await (db.update(db.agentConversations)..where((c) => c.id.equals(m.conversationId)))
          .write(AgentConversationsCompanion(updatedAt: Value(_now())));
    }
  }

  /// The text history for the model: the latest messages that fit the limits, starting with a user message.
  /// Messages without text (an answer that failed) are left out.
  Future<List<AgentHistoryMessage>> history(String conversationId) async {
    final rows = await (db.select(db.agentMessages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm.asc(m.id)]))
        .get();
    // Neighbours with the same role (a question whose answer failed, and the next one) are joined, so roles alternate.
    final all = <AgentHistoryMessage>[];
    for (final m in rows) {
      final text = m.body.trim();
      if (text.isEmpty) continue;
      if (all.isNotEmpty && all.last.role == m.role) {
        all.last = AgentHistoryMessage(m.role, '${all.last.text}\n\n$text');
      } else {
        all.add(AgentHistoryMessage(m.role, text));
      }
    }
    var chars = all.fold(0, (n, m) => n + m.text.runes.length);
    var drop = 0;
    while (all.length - drop > historyMaxMessages || (all.length - drop > 1 && chars > historyMaxChars)) {
      chars -= all[drop].text.runes.length;
      drop++;
    }
    // The oldest messages go historyDropStep at a time, not one by one: the history then begins with the
    // same message for several questions, so the cached start of the request stays good.
    if (drop > 0) drop = min((drop + historyDropStep - 1) ~/ historyDropStep * historyDropStep, all.length - 1);
    var kept = all.sublist(drop);
    while (kept.isNotEmpty && kept.first.role != 'user') {
      kept = kept.sublist(1);
    }
    return kept;
  }

  Future<bool> hasConversation(String id) async =>
      await (db.select(db.agentConversations)..where((c) => c.id.equals(id))).getSingleOrNull() != null;

  Future<AgentConversationPage> conversations({int? before, int limit = 30}) async {
    final q = db.select(db.agentConversations)
      ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])
      ..limit(limit + 1);
    if (before != null) q.where((c) => c.updatedAt.isSmallerThanValue(before));
    final rows = await q.get();
    final more = rows.length > limit;
    final shown = more ? rows.sublist(0, limit) : rows;
    final items = <AgentConversationItem>[];
    for (final c in shown) {
      final count = await (db.selectOnly(db.agentMessages)
            ..addColumns([db.agentMessages.id.count()])
            ..where(db.agentMessages.conversationId.equals(c.id)))
          .map((r) => r.read(db.agentMessages.id.count()) ?? 0)
          .getSingle();
      items.add(AgentConversationItem(
        id: c.id,
        mode: c.mode == 'learn' ? 'learn' : 'create',
        title: c.title,
        bankId: c.bankId,
        lessonId: c.lessonId,
        questionId: c.questionId,
        messageCount: count,
        updatedAt: c.updatedAt,
      ));
    }
    return AgentConversationPage(items, hasMore: more);
  }

  Future<AgentConversationDetail?> conversation(String id) async {
    final c = await (db.select(db.agentConversations)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (c == null) return null;
    final rows = await (db.select(db.agentMessages)
          ..where((m) => m.conversationId.equals(id))
          ..orderBy([(m) => OrderingTerm.asc(m.id)]))
        .get();
    final questions = {for (final q in await conversationQuestions(id)) q.id: q};
    final messages = <StoredMessage>[];
    for (final m in rows) {
      final tools = <StoredTool>[];
      try {
        for (final t in jsonDecode(m.toolsJson) as List) {
          t as Map;
          tools.add(StoredTool(id: '${t['id']}', label: '${t['label']}', status: '${t['status']}'));
        }
      } catch (_) {}
      final drafts = <StoredDraft>[];
      try {
        for (final id in jsonDecode(m.draftsJson) as List) {
          final q = questions['$id'];
          if (q != null) {
            drafts.add(StoredDraft(draftOf(q), q.hidden ? StoredDraftPhase.discarded : StoredDraftPhase.accepted));
          }
        }
      } catch (_) {}
      messages.add(StoredMessage(
        id: m.id,
        role: m.role == 'assistant' ? 'assistant' : 'user',
        text: m.body,
        tools: tools,
        drafts: drafts,
        note: m.note,
        error: m.error,
      ));
    }
    return AgentConversationDetail(
      AgentConversationItem(
        id: c.id,
        mode: c.mode == 'learn' ? 'learn' : 'create',
        title: c.title,
        bankId: c.bankId,
        lessonId: c.lessonId,
        questionId: c.questionId,
        messageCount: rows.length,
        updatedAt: c.updatedAt,
      ),
      messages,
    );
  }

  /// Removes the conversation. The questions it wrote stay in the bank.
  Future<void> deleteConversation(String id) => db.transaction(() async {
        await (db.delete(db.agentMessages)..where((m) => m.conversationId.equals(id))).go();
        await (db.delete(db.agentConversations)..where((c) => c.id.equals(id))).go();
      });
}
