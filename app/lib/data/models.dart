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
