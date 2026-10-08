/// What the study assistant's server API sends and receives (docs/agent-design.md §6.7).
library;

import 'dart:async';
import 'dart:convert';

/// Thrown when the assistant cannot be reached or refuses; [message] is safe to show.
class AgentException implements Exception {
  AgentException(this.message, {this.status, this.code});

  final String message;

  /// The HTTP status, for failures before the answer started.
  final int? status;

  /// The server's error code, for failures inside the stream (budget_exceeded, timeout, …).
  final String? code;

  @override
  String toString() => message;
}

/// Whether the assistant can be used, from GET /agent/status.
class AgentStatus {
  const AgentStatus({
    required this.available,
    required this.model,
    required this.verified,
    this.vision = false,
  });

  final bool available;
  final String model;

  /// A second model double-checks the questions the assistant writes.
  final bool verified;

  /// The model can look at pictures, so pictures may be attached to a message.
  final bool vision;

  factory AgentStatus.fromJson(Map<String, dynamic> j) => AgentStatus(
    available: j['available'] == true,
    model: (j['model'] as String?) ?? '',
    verified: j['verified'] == true,
    vision: j['vision'] == true,
  );
}

/// A question the assistant wrote that waits for the learner to accept or discard it.
class AgentDraft {
  const AgentDraft({
    required this.id,
    required this.lessonId,
    required this.type,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.explanation,
    required this.difficulty,
    required this.tags,
    required this.sourceQuote,
    required this.verified,
  });

  final String id;
  final String lessonId;
  final String type;
  final String stem;
  final List<String> options;
  final int answerIndex;
  final String explanation;
  final int difficulty;
  final List<String> tags;
  final String sourceQuote;

  /// A second model answered it independently and agreed.
  final bool verified;

  factory AgentDraft.fromJson(Map<String, dynamic> j) => AgentDraft(
        id: (j['draft_id'] as String?) ?? '',
        lessonId: (j['lesson_id'] as String?) ?? '',
        type: (j['type'] as String?) ?? 'single',
        stem: (j['stem'] as String?) ?? '',
        options: ((j['options'] as List?) ?? const []).map((e) => '$e').toList(),
        answerIndex: (j['answer_index'] as num?)?.toInt() ?? 0,
        explanation: (j['explanation'] as String?) ?? '',
        difficulty: (j['difficulty'] as num?)?.toInt() ?? 3,
        tags: ((j['tags'] as List?) ?? const []).map((e) => '$e').toList(),
        sourceQuote: (j['source_quote'] as String?) ?? '',
        verified: j['verified'] == true,
      );
}

/// What the learner is looking at, which the server puts into the assistant's instructions.
class AgentContext {
  const AgentContext({this.bankId = '', this.lessonId = '', this.questionId = '', this.selected = const []});

  final String bankId;
  final String lessonId;
  final String questionId;

  /// The option indexes the learner picked for [questionId].
  final List<int> selected;

  Map<String, dynamic> toJson() => {
        if (bankId.isNotEmpty) 'bank_id': bankId,
        if (lessonId.isNotEmpty) 'lesson_id': lessonId,
        if (questionId.isNotEmpty) 'question': {'id': questionId, 'selected': selected},
      };
}

class AgentChatRequest {
  const AgentChatRequest({
    required this.conversationId,
    required this.mode,
    required this.deviceId,
    required this.message,
    this.attachmentIds = const [],
    this.context = const AgentContext(),
  });

  /// Chosen by the app; the server keeps the conversation under it and reads the history itself.
  final String conversationId;

  /// learn | create
  final String mode;
  final String deviceId;
  /// The new question; the earlier ones are on the server.
  final String message;
  final List<String> attachmentIds;
  final AgentContext context;

  Map<String, dynamic> toJson() => {
        'conversation_id': conversationId,
        'mode': mode,
        'device_id': deviceId,
        'message': {'text': message, 'attachment_ids': attachmentIds},
        'context': context.toJson(),
      };
}

/// What became of a draft: still waiting, sent to review, or thrown away.
enum StoredDraftPhase { pending, accepted, discarded }

class StoredDraft {
  const StoredDraft(this.draft, this.phase);

  final AgentDraft draft;
  final StoredDraftPhase phase;
}

class StoredTool {
  const StoredTool({required this.id, required this.label, required this.status});

  final String id;
  final String label;

  /// running | done | error
  final String status;
}

/// A file a message carried.
class AgentAttachment {
  const AgentAttachment({
    required this.id,
    required this.name,
    this.kind = 'text',
    this.mime = '',
    this.size = 0,
    this.chars = 0,
    this.width = 0,
    this.height = 0,
  });

  final String id;
  final String name;

  /// text | image
  final String kind;

  bool get isImage => kind == 'image';
  final String mime;

  /// Bytes as uploaded.
  final int size;

  /// Text files: characters of the text.
  final int chars;

  /// Pictures: pixels; 0 when the server could not read them.
  final int width;
  final int height;

  factory AgentAttachment.fromJson(Map<String, dynamic> j) => AgentAttachment(
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    kind: j['kind'] == 'image' ? 'image' : 'text',
    mime: (j['mime'] as String?) ?? '',
    size: (j['size'] as num?)?.toInt() ?? 0,
    chars: (j['chars'] as num?)?.toInt() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
  );
}

/// What the server accepts as a file for the assistant. It checks again; these only spare a round trip.
const agentFileExtensions = [
  '.md',
  '.markdown',
  '.txt',
  '.csv',
  '.json',
  '.log',
];
const agentFileMaxBytes = 512 * 1024;

/// Pictures: the types taken (the server judges by content), the size, and how many a conversation holds.
const agentImageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
const agentImageMaxBytes = 5 * 1024 * 1024;
const agentMaxImages = 4;

/// Files in a conversation, and in one message.
const agentMaxFiles = 8;
const agentMaxFilesPerMessage = 4;

class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.role,
    required this.text,
    this.tools = const [],
    this.drafts = const [],
    this.attachments = const [],
    this.note = '',
    this.error = '',
  });

  final int id;
  final String role; // user | assistant
  final String text;
  final List<StoredTool> tools;
  final List<StoredDraft> drafts;
  final List<AgentAttachment> attachments;
  final String note;
  final String error;
}

/// A conversation as the history list shows it.
class AgentConversationItem {
  const AgentConversationItem({
    required this.id,
    required this.mode,
    required this.title,
    this.bankId = '',
    this.lessonId = '',
    this.questionId = '',
    this.messageCount = 0,
    this.pendingDrafts = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String mode; // learn | create
  final String title;
  final String bankId;
  final String lessonId;
  final String questionId;
  final int messageCount;

  /// Drafts nobody has decided on yet.
  final int pendingDrafts;
  final int updatedAt;

  factory AgentConversationItem.fromJson(Map<String, dynamic> j) => AgentConversationItem(
        id: (j['id'] as String?) ?? '',
        mode: j['mode'] == 'create' ? 'create' : 'learn',
        title: (j['title'] as String?) ?? '',
        bankId: (j['bank_id'] as String?) ?? '',
        lessonId: (j['lesson_id'] as String?) ?? '',
        questionId: (j['question_id'] as String?) ?? '',
        messageCount: (j['message_count'] as num?)?.toInt() ?? 0,
        pendingDrafts: (j['pending_drafts'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
}

class AgentConversationPage {
  const AgentConversationPage(this.items, {this.hasMore = false});

  final List<AgentConversationItem> items;
  final bool hasMore;
}

/// A whole conversation, to show it again and carry on.
class AgentConversationDetail {
  const AgentConversationDetail(this.item, this.messages);

  final AgentConversationItem item;
  final List<StoredMessage> messages;

  factory AgentConversationDetail.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(Object? v) =>
        [for (final x in (v as List? ?? const [])) if (x is Map<String, dynamic>) x];
    StoredDraftPhase phase(Object? v) => switch (v) {
          'accepted' => StoredDraftPhase.accepted,
          'discarded' => StoredDraftPhase.discarded,
          _ => StoredDraftPhase.pending,
        };
    return AgentConversationDetail(AgentConversationItem.fromJson(j), [
      for (final m in maps(j['messages']))
        StoredMessage(
          id: (m['id'] as num?)?.toInt() ?? 0,
          role: m['role'] == 'assistant' ? 'assistant' : 'user',
          text: (m['text'] as String?) ?? '',
          note: (m['note'] as String?) ?? '',
          error: (m['error'] as String?) ?? '',
          tools: [
            for (final t in maps(m['tools']))
              StoredTool(
                id: (t['id'] as String?) ?? '',
                label: (t['label'] as String?) ?? '',
                status: t['status'] == 'error' ? 'error' : t['status'] == 'running' ? 'running' : 'done',
              ),
          ],
          drafts: [for (final d in maps(m['drafts'])) StoredDraft(AgentDraft.fromJson(d), phase(d['phase']))],
          attachments: [for (final a in maps(m['attachments'])) AgentAttachment.fromJson(a)],
        ),
    ]);
  }
}

/// Events of POST /agent/chat, in the order they arrive.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentStarted extends AgentEvent {
  const AgentStarted(this.conversationId);
  final String conversationId;
}

class AgentDelta extends AgentEvent {
  const AgentDelta(this.text);
  final String text;
}

/// A tool call's progress, shown as one status line.
class AgentToolEvent extends AgentEvent {
  const AgentToolEvent({required this.id, required this.name, required this.label, required this.status});
  final String id;
  final String name;
  final String label;

  /// running | done | error
  final String status;
}

class AgentDraftsEvent extends AgentEvent {
  const AgentDraftsEvent(this.drafts);
  final List<AgentDraft> drafts;
}

class AgentDone extends AgentEvent {
  const AgentDone({required this.stop, this.inputTokens = 0, this.outputTokens = 0});

  /// end_turn | max_rounds | max_tokens
  final String stop;
  final int inputTokens;
  final int outputTokens;
}

class AgentErrorEvent extends AgentEvent {
  const AgentErrorEvent({required this.code, required this.message});
  final String code;
  final String message;
}

/// Events of a server-sent-events body. Unlike a chat completion's stream these are named
/// (`event:` then `data:`), and comment lines (`: ping`) only keep the connection alive. Events the
/// app does not know are skipped, so a newer server can add some.
Stream<AgentEvent> parseAgentSse(Stream<List<int>> body) async* {
  String? name;
  final data = StringBuffer();
  var hasData = false;
  AgentEvent? flush() {
    final n = name;
    final raw = data.toString();
    name = null;
    data.clear();
    final had = hasData;
    hasData = false;
    if (n == null || !had) return null;
    try {
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? _eventOf(n, j) : null;
    } catch (_) {
      return null;
    }
  }

  await for (final raw in utf8.decoder.bind(body).transform(const LineSplitter())) {
    if (raw.isEmpty) {
      final e = flush();
      if (e != null) yield e;
      continue;
    }
    if (raw.startsWith(':')) continue;
    if (raw.startsWith('event:')) {
      name = raw.substring(6).trim();
    } else if (raw.startsWith('data:')) {
      if (hasData) data.write('\n');
      data.write(raw.substring(5).trimLeft());
      hasData = true;
    }
  }
  final last = flush();
  if (last != null) yield last;
}

AgentEvent? _eventOf(String name, Map<String, dynamic> j) {
  int n(Object? v) => v is num ? v.toInt() : 0;
  switch (name) {
    case 'start':
      return AgentStarted((j['conversation_id'] as String?) ?? '');
    case 'delta':
      final text = j['text'];
      return text is String && text.isNotEmpty ? AgentDelta(text) : null;
    case 'tool':
      return AgentToolEvent(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'running',
      );
    case 'drafts':
      final list = j['drafts'];
      if (list is! List) return null;
      return AgentDraftsEvent([for (final d in list) if (d is Map<String, dynamic>) AgentDraft.fromJson(d)]);
    case 'done':
      final usage = j['usage'];
      return AgentDone(
        stop: (j['stop'] as String?) ?? 'end_turn',
        inputTokens: usage is Map ? n(usage['input']) : 0,
        outputTokens: usage is Map ? n(usage['output']) : 0,
      );
    case 'error':
      return AgentErrorEvent(code: (j['code'] as String?) ?? 'internal', message: (j['message'] as String?) ?? '助手出错了');
  }
  return null;
}
