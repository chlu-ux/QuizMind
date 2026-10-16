/// The study material the assistant's tools search, read from the copy this device keeps. It is the
/// same material the server's assistant sees (server/internal/agent/library.go).
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../database.dart';
import '../progress.dart';

class AgentBank {
  const AgentBank(this.id, this.title);
  final String id;
  final String title;
}

/// One section of a document: the unit questions are written from and cited by.
class AgentLesson {
  const AgentLesson({
    required this.id,
    required this.bankId,
    required this.documentId,
    required this.documentTitle,
    required this.headingPath,
    required this.text,
    this.documentOrder = 0,
  });

  final String id;
  final String bankId;
  final String documentId;
  final String documentTitle;

  /// When the document was uploaded (ms); orders the chapters.
  final int documentOrder;
  final String headingPath;
  final String text;
}

/// A question in play (not withdrawn).
class AgentQuestion {
  const AgentQuestion({
    required this.id,
    required this.bankId,
    required this.lessonId,
    required this.type,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
    required this.difficulty,
  });

  final String id;
  final String bankId;
  final String lessonId;
  final String type;
  final String stem;
  final List<String> options;
  final List<int> answer;
  final String explanation;
  final int difficulty;
}

class AgentAttempt {
  const AgentAttempt(this.questionId, this.correct,
      {this.at = 0, this.selected = const [], this.durationMs = 0, this.reviewMs = 0});

  final String questionId;
  final bool correct;

  /// When it was answered (ms).
  final int at;

  /// The options picked.
  final List<int> selected;

  /// Time from showing the question to answering it, and time spent on it afterwards (explanation); 0 when unknown.
  final int durationMs;
  final int reviewMs;
}

/// What the learner keeps per question: the wrong book, favorites and the review schedule. Only questions
/// the learner has touched have one.
class AgentState {
  const AgentState(this.questionId, {this.dueAt = 0, this.favorite = false, this.wrongCount = 0, this.streak = 0});

  final String questionId;

  /// When a scheduled review falls due (ms); 0 when nothing is scheduled. No app schedules reviews yet, so
  /// today the wrong book is what marks a question for review.
  final int dueAt;
  final bool favorite;
  final int wrongCount;

  /// Right answers in a row since the last miss.
  final int streak;

  /// Missed at least once and not yet answered right twice in a row.
  bool get inWrongBook => wrongCount > 0 && streak < ProgressRecord.clearStreak;
}

abstract class AgentLibrary {
  Future<List<AgentBank>> banks();

  /// In reading order: by document, then by place in it.
  Future<List<AgentLesson>> lessons();

  Future<List<AgentQuestion>> questions();

  /// Every answer given, from any device, oldest first.
  Future<List<AgentAttempt>> attempts();

  /// The per-question state of every question the learner has touched.
  Future<List<AgentState>> states();

  /// The AI explanation kept for a question; empty when there is none.
  Future<String> note(String questionId);
}

class DbAgentLibrary implements AgentLibrary {
  DbAgentLibrary(this.db);

  final AppDatabase db;

  @override
  Future<List<AgentBank>> banks() async =>
      [for (final b in await db.select(db.banks).get()) AgentBank(b.id, b.title)];

  @override
  Future<List<AgentLesson>> lessons() async {
    final rows = await (db.select(db.lessons)
          ..orderBy([(l) => OrderingTerm.asc(l.documentOrder), (l) => OrderingTerm.asc(l.seq)]))
        .get();
    return [
      for (final l in rows)
        AgentLesson(
          id: l.id,
          bankId: l.bankId,
          documentId: l.documentId,
          documentTitle: l.documentTitle,
          documentOrder: l.documentOrder,
          headingPath: l.headingPath,
          text: l.body,
        ),
    ];
  }

  @override
  Future<List<AgentQuestion>> questions() async {
    final rows = await (db.select(db.questions)
          ..where((q) => q.hidden.equals(false))
          ..orderBy([(q) => OrderingTerm.asc(q.id)]))
        .get();
    return [
      for (final q in rows)
        AgentQuestion(
          id: q.id,
          bankId: q.bankId,
          lessonId: q.chunkId,
          type: q.type,
          stem: q.stem,
          options: [for (final o in jsonDecode(q.optionsJson) as List) '$o'],
          answer: [for (final a in jsonDecode(q.answerJson) as List) (a as num).toInt()],
          explanation: q.explanation,
          difficulty: q.difficulty,
        ),
    ];
  }

  @override
  Future<List<AgentAttempt>> attempts() async {
    final rows = await (db.select(db.attempts)..orderBy([(a) => OrderingTerm.asc(a.answeredAt)])).get();
    return [
      for (final a in rows)
        AgentAttempt(
          a.questionId,
          a.isCorrect,
          at: a.answeredAt,
          selected: _ints(a.answerJson),
          durationMs: a.durationMs ?? 0,
          reviewMs: a.reviewMs ?? 0,
        ),
    ];
  }

  @override
  Future<List<AgentState>> states() async => [
        for (final s in await db.select(db.questionStates).get())
          AgentState(
            s.questionId,
            dueAt: s.dueAt ?? 0,
            favorite: s.favorite,
            wrongCount: s.wrongCount,
            streak: ProgressRecord.decode(s.fsrsJson).streak,
          ),
      ];

  @override
  Future<String> note(String questionId) async {
    final row = await (db.select(db.aiNotes)..where((n) => n.questionId.equals(questionId))).getSingleOrNull();
    return row?.content ?? '';
  }
}

List<int> _ints(String raw) {
  try {
    return [for (final x in jsonDecode(raw) as List) (x as num).toInt()];
  } catch (_) {
    return const [];
  }
}
