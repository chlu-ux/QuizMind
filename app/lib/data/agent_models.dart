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
  const AgentStatus({required this.available, required this.model, required this.verified});

  final bool available;
  final String model;

  /// A second model double-checks the questions the assistant writes.
  final bool verified;

  factory AgentStatus.fromJson(Map<String, dynamic> j) => AgentStatus(
        available: j['available'] == true,
        model: (j['model'] as String?) ?? '',
        verified: j['verified'] == true,
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

/// One message of the history sent with a request. The server keeps no history: only the text is
/// sent, and the assistant looks things up again with its tools when it needs them.
class AgentTurn {
  const AgentTurn(this.role, this.content);

  final String role; // user | assistant
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
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
    required this.messages,
    this.context = const AgentContext(),
  });

  final String conversationId;

  /// learn | create
  final String mode;
  final String deviceId;
  final List<AgentTurn> messages;
  final AgentContext context;

  Map<String, dynamic> toJson() => {
        'conversation_id': conversationId,
        'mode': mode,
        'device_id': deviceId,
        'messages': [for (final m in messages) m.toJson()],
        'context': context.toJson(),
      };
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
