/// JSON shapes of the app API (see api/openapi.yaml).
library;

class BankDto {
  BankDto({required this.id, required this.title, required this.description, required this.questionCount});

  final String id;
  final String title;
  final String description;
  final int questionCount;

  factory BankDto.fromJson(Map<String, dynamic> j) => BankDto(
        id: j['id'] as String,
        title: j['title'] as String,
        description: (j['description'] as String?) ?? '',
        questionCount: (j['question_count'] as num?)?.toInt() ?? 0,
      );
}

class QuestionDto {
  QuestionDto({
    required this.id,
    required this.bankId,
    required this.type,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
    required this.difficulty,
    required this.tags,
    required this.sourceQuote,
    required this.syncSeq,
  });

  final String id;
  final String bankId;
  final String type;
  final String stem;
  final List<String> options;
  final List<int> answer;
  final String explanation;
  final int difficulty;
  final List<String> tags;
  final String sourceQuote;
  final int syncSeq;

  factory QuestionDto.fromJson(Map<String, dynamic> j) => QuestionDto(
        id: j['id'] as String,
        bankId: j['bank_id'] as String,
        type: j['type'] as String,
        stem: j['stem'] as String,
        options: (j['options'] as List).cast<String>(),
        answer: (j['answer'] as List).map((e) => (e as num).toInt()).toList(),
        explanation: (j['explanation'] as String?) ?? '',
        difficulty: (j['difficulty'] as num?)?.toInt() ?? 3,
        tags: ((j['tags'] as List?) ?? const []).cast<String>(),
        sourceQuote: (j['source_quote'] as String?) ?? '',
        syncSeq: (j['sync_seq'] as num).toInt(),
      );
}

class QuestionsPage {
  QuestionsPage({required this.items, required this.deleted, required this.nextSeq, required this.hasMore});

  final List<QuestionDto> items;
  final List<String> deleted;
  final int nextSeq;
  final bool hasMore;

  factory QuestionsPage.fromJson(Map<String, dynamic> j) => QuestionsPage(
        items: (j['items'] as List).map((e) => QuestionDto.fromJson(e as Map<String, dynamic>)).toList(),
        deleted: ((j['deleted'] as List?) ?? const []).cast<String>(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}

class StateDto {
  StateDto({
    required this.questionId,
    this.fsrs,
    this.dueAt,
    required this.favorite,
    required this.wrongCount,
    required this.updatedAt,
  });

  final String questionId;
  final Map<String, dynamic>? fsrs;
  final int? dueAt;
  final bool favorite;
  final int wrongCount;
  final int updatedAt;

  factory StateDto.fromJson(Map<String, dynamic> j) => StateDto(
        questionId: j['question_id'] as String,
        fsrs: j['fsrs'] as Map<String, dynamic>?,
        dueAt: (j['due_at'] as num?)?.toInt(),
        favorite: (j['favorite'] as bool?) ?? false,
        wrongCount: (j['wrong_count'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'question_id': questionId,
        'fsrs': fsrs,
        'due_at': dueAt,
        'favorite': favorite,
        'wrong_count': wrongCount,
        'updated_at': updatedAt,
      };
}

class StatesPage {
  StatesPage({required this.items, required this.nextSeq, required this.hasMore});

  final List<StateDto> items;
  final int nextSeq;
  final bool hasMore;

  factory StatesPage.fromJson(Map<String, dynamic> j) => StatesPage(
        items: (j['items'] as List).map((e) => StateDto.fromJson(e as Map<String, dynamic>)).toList(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}

class AttemptDto {
  AttemptDto({
    required this.id,
    required this.questionId,
    required this.deviceId,
    required this.answer,
    required this.isCorrect,
    this.durationMs,
    required this.answeredAt,
  });

  final String id;
  final String questionId;
  final String deviceId;
  final List<int> answer;
  final bool isCorrect;
  final int? durationMs;
  final int answeredAt;

  factory AttemptDto.fromJson(Map<String, dynamic> j) => AttemptDto(
        id: j['id'] as String,
        questionId: j['question_id'] as String,
        deviceId: (j['device_id'] as String?) ?? '',
        answer: ((j['answer'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
        isCorrect: j['is_correct'] as bool,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        answeredAt: (j['answered_at'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'question_id': questionId,
        'device_id': deviceId,
        'answer': answer,
        'is_correct': isCorrect,
        'duration_ms': durationMs,
        'answered_at': answeredAt,
      };
}

/// One page of the answer log from every device.
class AttemptsPage {
  AttemptsPage({required this.items, required this.nextSeq, required this.hasMore});

  final List<AttemptDto> items;
  final int nextSeq;
  final bool hasMore;

  factory AttemptsPage.fromJson(Map<String, dynamic> j) => AttemptsPage(
        items: (j['items'] as List).map((e) => AttemptDto.fromJson(e as Map<String, dynamic>)).toList(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}

/// One question of a handed-in paper: question id, option indexes picked (empty =
/// left blank), right or not.
class ExamItemRecord {
  const ExamItemRecord({required this.questionId, required this.selected, required this.correct});

  final String questionId;
  final List<int> selected;
  final bool correct;

  Map<String, dynamic> toJson() => {'q': questionId, 's': selected, 'c': correct};

  factory ExamItemRecord.fromJson(Map<String, dynamic> j) => ExamItemRecord(
        questionId: j['q'] as String,
        selected: ((j['s'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
        correct: j['c'] as bool,
      );
}

/// A finished mock exam, synced between devices; it never changes once handed in.
/// [items] lists the paper in order so any device can review it. Records from
/// before per-question detail existed have it empty.
class ExamRecord {
  const ExamRecord({
    required this.id,
    required this.bankId,
    required this.title,
    required this.finishedAt,
    required this.total,
    required this.correct,
    required this.answered,
    required this.percent,
    required this.passed,
    required this.limitSec,
    required this.usedMs,
    this.deviceId = '',
    this.items = const [],
  });

  final String id;
  final String bankId;
  final String title;
  final int finishedAt;
  final int total;
  final int correct;

  /// Questions that got an answer; the rest were left blank.
  final int answered;

  /// Score 0-100: correct answers over all questions, blanks counting as wrong.
  final int percent;
  final bool passed;

  /// Time limit in seconds, null when the exam was untimed.
  final int? limitSec;
  final int usedMs;
  final String deviceId;
  final List<ExamItemRecord> items;

  ExamRecord withDevice(String device) => ExamRecord(
        id: id,
        bankId: bankId,
        title: title,
        finishedAt: finishedAt,
        total: total,
        correct: correct,
        answered: answered,
        percent: percent,
        passed: passed,
        limitSec: limitSec,
        usedMs: usedMs,
        deviceId: device,
        items: items,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bank_id': bankId,
        'title': title,
        'finished_at': finishedAt,
        'total': total,
        'correct': correct,
        'answered': answered,
        'percent': percent,
        'passed': passed,
        'limit_sec': limitSec,
        'used_ms': usedMs,
        'device_id': deviceId,
        'items': [for (final it in items) it.toJson()],
      };

  factory ExamRecord.fromJson(Map<String, dynamic> j) => ExamRecord(
        id: j['id'] as String,
        bankId: j['bank_id'] as String,
        title: (j['title'] as String?) ?? '',
        finishedAt: (j['finished_at'] as num).toInt(),
        total: (j['total'] as num).toInt(),
        correct: (j['correct'] as num).toInt(),
        answered: (j['answered'] as num).toInt(),
        percent: (j['percent'] as num).toInt(),
        passed: j['passed'] as bool,
        limitSec: (j['limit_sec'] as num?)?.toInt(),
        usedMs: (j['used_ms'] as num).toInt(),
        deviceId: (j['device_id'] as String?) ?? '',
        items: ((j['items'] as List?) ?? const [])
            .map((e) => ExamItemRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ExamsPage {
  ExamsPage({required this.items, required this.nextSeq, required this.hasMore});

  final List<ExamRecord> items;
  final int nextSeq;
  final bool hasMore;

  factory ExamsPage.fromJson(Map<String, dynamic> j) => ExamsPage(
        items: (j['items'] as List).map((e) => ExamRecord.fromJson(e as Map<String, dynamic>)).toList(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}

/// A saved quiz as it travels to and from the server. [data] is the progress
/// document (see SessionData in api/openapi.yaml); null means the quiz was
/// finished and the saved copy should disappear everywhere.
class SessionDto {
  SessionDto({required this.scope, required this.data, required this.updatedAt, this.deviceId = ''});

  final String scope;
  final Map<String, dynamic>? data;
  final int updatedAt;
  final String deviceId;

  factory SessionDto.fromJson(Map<String, dynamic> j) => SessionDto(
        scope: j['scope'] as String,
        data: j['data'] as Map<String, dynamic>?,
        updatedAt: (j['updated_at'] as num).toInt(),
        deviceId: (j['device_id'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {'scope': scope, 'data': data, 'updated_at': updatedAt, 'device_id': deviceId};
}

class SessionsPage {
  SessionsPage({required this.items, required this.nextSeq, required this.hasMore});

  final List<SessionDto> items;
  final int nextSeq;
  final bool hasMore;

  factory SessionsPage.fromJson(Map<String, dynamic> j) => SessionsPage(
        items: (j['items'] as List).map((e) => SessionDto.fromJson(e as Map<String, dynamic>)).toList(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}

/// How to reach the LLM for AI explanations: an OpenAI-compatible endpoint. Handed
/// out by the server (see /api/v1/ai/config) or typed in by hand on this device.
class AiConfig {
  const AiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.maxTokens = 1500,
    this.temperature = 0.3,
  });

  /// Including the version segment, e.g. https://api.openai.com/v1.
  final String baseUrl;
  final String apiKey;
  final String model;
  final int maxTokens;
  final double temperature;

  bool get usable => baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  factory AiConfig.fromJson(Map<String, dynamic> j) => AiConfig(
        baseUrl: (j['base_url'] as String?) ?? '',
        apiKey: (j['api_key'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 1500,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.3,
      );

  Map<String, dynamic> toJson() =>
      {'base_url': baseUrl, 'api_key': apiKey, 'model': model, 'max_tokens': maxTokens, 'temperature': temperature};
}

/// An AI explanation as it travels to and from the server.
class NoteDto {
  NoteDto({
    required this.questionId,
    required this.content,
    required this.updatedAt,
    this.model = '',
    this.promptVersion = '',
    this.selected = const [],
    this.deviceId = '',
  });

  final String questionId;
  final String content;
  final int updatedAt;
  final String model;
  final String promptVersion;
  final List<int> selected;
  final String deviceId;

  factory NoteDto.fromJson(Map<String, dynamic> j) => NoteDto(
        questionId: j['question_id'] as String,
        content: j['content'] as String,
        updatedAt: (j['updated_at'] as num).toInt(),
        model: (j['model'] as String?) ?? '',
        promptVersion: (j['prompt_version'] as String?) ?? '',
        selected: ((j['selected'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
        deviceId: (j['device_id'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'question_id': questionId,
        'content': content,
        'model': model,
        'prompt_version': promptVersion,
        'selected': selected,
        'updated_at': updatedAt,
        'device_id': deviceId,
      };
}

class NotesPage {
  NotesPage({required this.items, required this.nextSeq, required this.hasMore});

  final List<NoteDto> items;
  final int nextSeq;
  final bool hasMore;

  factory NotesPage.fromJson(Map<String, dynamic> j) => NotesPage(
        items: (j['items'] as List).map((e) => NoteDto.fromJson(e as Map<String, dynamic>)).toList(),
        nextSeq: (j['next_seq'] as num).toInt(),
        hasMore: j['has_more'] as bool,
      );
}
