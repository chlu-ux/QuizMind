/// The study material the assistant's tools search, read from the copy this device keeps. It is the
/// same material the server's assistant sees (server/internal/agent/library.go).
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../database.dart';

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
  const AgentAttempt(this.questionId, this.correct);
  final String questionId;
  final bool correct;
}

abstract class AgentLibrary {
  Future<List<AgentBank>> banks();

  /// In reading order: by document, then by place in it.
  Future<List<AgentLesson>> lessons();

  Future<List<AgentQuestion>> questions();

  /// Every answer given, from any device, oldest first.
  Future<List<AgentAttempt>> attempts();
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
    return [for (final a in rows) AgentAttempt(a.questionId, a.isCorrect)];
  }
}
