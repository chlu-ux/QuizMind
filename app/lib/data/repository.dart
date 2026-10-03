import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/ulid.dart';
import 'database.dart';
import 'exam_store.dart';
import 'models.dart';
import 'progress.dart';
import 'stats.dart';

/// What the quiz screen shows about the question just answered.
class AnswerOutcome {
  const AnswerOutcome({required this.correct, required this.enteredWrongBook, required this.state});

  final bool correct;
  final bool enteredWrongBook;
  final QuestionState state;
}

/// How a question has gone so far; used to pick exam questions.
class QuestionHistory {
  const QuestionHistory({required this.attempts, required this.lastCorrect});

  final int attempts;
  final bool lastCorrect;
}

/// One answered question of an exam paper, to be written to the attempt log.
class ExamAnswer {
  const ExamAnswer({required this.question, required this.selected, required this.durationMs});

  final Question question;
  final List<int> selected;
  final int durationMs;
}

class BankStats {
  const BankStats({required this.total, required this.answered, required this.correct});

  final int total;
  final int answered;

  /// Questions whose most recent attempt was correct.
  final int correct;
}

/// Local data access. All reads exclude questions the server withdrew.
class Repository {
  Repository(this.db, {required this.deviceId, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final String deviceId;
  final DateTime Function() _clock;

  int _now() => _clock().millisecondsSinceEpoch;

  // ---- reads ----

  Stream<List<Bank>> watchBanks() =>
      (db.select(db.banks)..orderBy([(b) => OrderingTerm.asc(b.title)])).watch();

  Future<List<Question>> bankQuestions(String bankId) =>
      (db.select(db.questions)
            ..where((q) => q.bankId.equals(bankId) & q.hidden.equals(false))
            ..orderBy([(q) => OrderingTerm.asc(q.syncSeq), (q) => OrderingTerm.asc(q.id)]))
          .get();

  /// The visible questions among [ids], in the order of [ids]. Ids the server
  /// withdrew or the learner reported are left out.
  Future<List<Question>> questionsByIds(List<String> ids) async {
    final found = <String, Question>{};
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = await (db.select(db.questions)..where((q) => q.id.isIn(chunk) & q.hidden.equals(false))).get();
      for (final q in rows) {
        found[q.id] = q;
      }
    }
    return [for (final id in ids) if (found[id] != null) found[id]!];
  }

  Stream<List<Question>> watchWrongBook() => _watchByState((s) => s.inWrongBook);

  Stream<List<Question>> watchFavorites() => _watchByState((s) => s.favorite);

  Stream<List<Question>> _watchByState(bool Function(QuestionState) keep) {
    final query = db.select(db.questions).join([
      innerJoin(db.questionStates, db.questionStates.questionId.equalsExp(db.questions.id)),
    ])
      ..where(db.questions.hidden.equals(false))
      ..orderBy([OrderingTerm.desc(db.questionStates.updatedAt)]);
    return query.watch().map((rows) => [
          for (final r in rows)
            if (keep(r.readTable(db.questionStates))) r.readTable(db.questions),
        ]);
  }

  Stream<QuestionState?> watchState(String questionId) =>
      (db.select(db.questionStates)..where((s) => s.questionId.equals(questionId))).watchSingleOrNull();

  Future<QuestionState?> getState(String questionId) =>
      (db.select(db.questionStates)..where((s) => s.questionId.equals(questionId))).getSingleOrNull();

  Future<BankStats> bankStats(String bankId) async {
    final qs = await bankQuestions(bankId);
    if (qs.isEmpty) return const BankStats(total: 0, answered: 0, correct: 0);
    final ids = qs.map((q) => q.id).toList();
    final attempts = await (db.select(db.attempts)
          ..where((a) => a.questionId.isIn(ids))
          ..orderBy([(a) => OrderingTerm.asc(a.answeredAt)]))
        .get();
    final last = <String, bool>{};
    for (final a in attempts) {
      last[a.questionId] = a.isCorrect;
    }
    return BankStats(total: qs.length, answered: last.length, correct: last.values.where((v) => v).length);
  }

  /// Practice statistics for a bank, from the attempt log.
  Future<BankReport> bankReport(String bankId) async {
    final qs = await bankQuestions(bankId);
    final ids = qs.map((q) => q.id).toList();
    final attempts = <Attempt>[];
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      attempts.addAll(await (db.select(db.attempts)..where((a) => a.questionId.isIn(chunk))).get());
    }
    final wrong = await watchWrongBook().first;
    return buildReport(qs, attempts, {for (final q in wrong) q.id}, _clock(), exams: await exams(bankId));
  }

  /// How each of [ids] has gone, for those answered at least once.
  Future<Map<String, QuestionHistory>> practiceHistory(Iterable<String> ids) async {
    final list = ids.toList();
    final rows = <Attempt>[];
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      rows.addAll(await (db.select(db.attempts)
            ..where((a) => a.questionId.isIn(chunk))
            ..orderBy([(a) => OrderingTerm.asc(a.answeredAt)]))
          .get());
    }
    final out = <String, QuestionHistory>{};
    for (final a in rows) {
      final h = out[a.questionId];
      out[a.questionId] = QuestionHistory(attempts: (h?.attempts ?? 0) + 1, lastCorrect: a.isCorrect);
    }
    return out;
  }

  // ---- exams ----

  ExamRecord _toRecord(ExamRow r) => ExamRecord(
        id: r.id,
        bankId: r.bankId,
        title: r.title,
        finishedAt: r.finishedAt,
        total: r.total,
        correct: r.correct,
        answered: r.answered,
        percent: r.percent,
        passed: r.passed,
        limitSec: r.limitSec,
        usedMs: r.usedMs,
        deviceId: r.deviceId,
        items: [
          for (final j in jsonDecode(r.itemsJson) as List) ExamItemRecord.fromJson(j as Map<String, dynamic>),
        ],
      );

  ExamsCompanion _toRow(ExamRecord r, {required bool synced}) => ExamsCompanion.insert(
        id: r.id,
        bankId: r.bankId,
        title: r.title,
        finishedAt: r.finishedAt,
        total: r.total,
        correct: r.correct,
        answered: r.answered,
        percent: r.percent,
        passed: r.passed,
        limitSec: Value(r.limitSec),
        usedMs: r.usedMs,
        deviceId: Value(r.deviceId),
        itemsJson: Value(jsonEncode([for (final it in r.items) it.toJson()])),
        synced: Value(synced),
      );

  /// Finished exams of a bank, newest first.
  Future<List<ExamRecord>> exams(String bankId) async {
    final rows = await (db.select(db.exams)
          ..where((e) => e.bankId.equals(bankId))
          ..orderBy([(e) => OrderingTerm.desc(e.finishedAt)]))
        .get();
    return [for (final r in rows) _toRecord(r)];
  }

  Future<ExamRecord?> exam(String id) async {
    final r = await (db.select(db.exams)..where((e) => e.id.equals(id))).getSingleOrNull();
    return r == null ? null : _toRecord(r);
  }

  /// Stores an exam that was made elsewhere (older versions), queued for upload.
  Future<void> importExam(ExamRecord record) =>
      db.into(db.exams).insert(_toRow(record, synced: false), mode: InsertMode.insertOrIgnore);

  /// Hands in an exam: every answered question goes into the attempt log and the
  /// learning state, the result is stored and the unfinished-exam draft is dropped,
  /// all in one transaction. It either all happens or none of it does, so a retry
  /// never double-counts.
  Future<void> submitExam(ExamRecord record, List<ExamAnswer> answers) => db.transaction(() async {
        final now = _now();
        for (final a in answers) {
          await _apply(a.question, a.selected, a.durationMs, now);
        }
        await db.into(db.exams).insert(_toRow(record, synced: false));
        await (db.delete(db.examDrafts)..where((d) => d.bankId.equals(record.bankId))).go();
      });

  // ---- exam in progress (this device only) ----

  Future<void> saveExamDraft(ExamDraft d) => db.into(db.examDrafts).insertOnConflictUpdate(
        ExamDraftsCompanion.insert(bankId: d.bankId, dataJson: jsonEncode(d.toJson()), savedAt: d.savedAt),
      );

  ExamDraft? _draft(ExamDraftRow? r) {
    if (r == null) return null;
    try {
      return ExamDraft.fromJson(jsonDecode(r.dataJson) as Map<String, dynamic>);
    } catch (_) {
      return null; // an unreadable draft is as good as none
    }
  }

  Future<ExamDraft?> examDraft(String bankId) async =>
      _draft(await (db.select(db.examDrafts)..where((d) => d.bankId.equals(bankId))).getSingleOrNull());

  /// The most recently touched unfinished exam of any bank.
  Future<ExamDraft?> latestExamDraft() async {
    final rows = await (db.select(db.examDrafts)
          ..orderBy([(d) => OrderingTerm.desc(d.savedAt)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : _draft(rows.first);
  }

  Future<void> clearExamDraft(String bankId) =>
      (db.delete(db.examDrafts)..where((d) => d.bankId.equals(bankId))).go();

  /// Which of [ids] have been answered at least once.
  Future<Set<String>> answeredIds(Iterable<String> ids) async {
    final q = db.selectOnly(db.attempts, distinct: true)
      ..addColumns([db.attempts.questionId])
      ..where(db.attempts.questionId.isIn(ids));
    return (await q.map((r) => r.read(db.attempts.questionId)!).get()).toSet();
  }

  /// Answers waiting in the outbox.
  Stream<int> watchPendingUploads() {
    final n = db.attempts.id.count();
    final q = db.selectOnly(db.attempts)
      ..addColumns([n])
      ..where(db.attempts.synced.equals(false));
    return q.map((r) => r.read(n) ?? 0).watchSingle();
  }

  // ---- writes ----

  /// Records an answer: appends to the attempt log (outbox) and updates the
  /// question's learning state, all in one transaction.
  Future<AnswerOutcome> recordAnswer({
    required Question question,
    required List<int> selected,
    required int durationMs,
  }) => db.transaction(() => _apply(question, selected, durationMs, _now()));

  Future<AnswerOutcome> _apply(Question question, List<int> selected, int durationMs, int now) async {
    final correct = isCorrect(selected, question.answer);
    await db.into(db.attempts).insert(AttemptsCompanion.insert(
          id: newUlid(now: _clock()),
          questionId: question.id,
          deviceId: deviceId,
          answerJson: jsonEncode(selected),
          isCorrect: correct,
          durationMs: Value(durationMs),
          answeredAt: now,
        ));
    final before = await getState(question.id);
    final wasIn = before?.inWrongBook ?? false;
    final progress = (before?.progress ?? const ProgressRecord()).afterAnswer(correct: correct, at: now);
    await db.into(db.questionStates).insertOnConflictUpdate(QuestionStatesCompanion(
      questionId: Value(question.id),
      fsrsJson: Value(progress.encode()),
      dueAt: Value(before?.dueAt),
      favorite: Value(before?.favorite ?? false),
      wrongCount: Value((before?.wrongCount ?? 0) + (correct ? 0 : 1)),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
    final after = (await getState(question.id))!;
    return AnswerOutcome(correct: correct, enteredWrongBook: !wasIn && after.inWrongBook, state: after);
  }

  Future<void> setFavorite(String questionId, bool favorite) async {
    final before = await getState(questionId);
    await db.into(db.questionStates).insertOnConflictUpdate(QuestionStatesCompanion(
          questionId: Value(questionId),
          fsrsJson: Value(before?.fsrsJson),
          dueAt: Value(before?.dueAt),
          favorite: Value(favorite),
          wrongCount: Value(before?.wrongCount ?? 0),
          updatedAt: Value(_now()),
          dirty: const Value(true),
        ));
  }

  /// Takes the question out of the wrong book without touching its history.
  Future<void> clearFromWrongBook(String questionId) async {
    final before = await getState(questionId);
    if (before == null) return;
    final progress =
        ProgressRecord(streak: ProgressRecord.clearStreak, lastAnsweredAt: before.progress.lastAnsweredAt);
    await (db.update(db.questionStates)..where((s) => s.questionId.equals(questionId))).write(
      QuestionStatesCompanion(
        fsrsJson: Value(progress.encode()),
        updatedAt: Value(_now()),
        dirty: const Value(true),
      ),
    );
  }

  /// Queues a "this question looks wrong" report and hides the question here
  /// right away; the server confirms by withdrawing it on a later sync.
  Future<void> flagQuestion(String questionId) async {
    await db.transaction(() async {
      await db
          .into(db.pendingFlags)
          .insertOnConflictUpdate(PendingFlagsCompanion.insert(questionId: questionId, createdAt: _now()));
      await (db.update(db.questions)..where((q) => q.id.equals(questionId)))
          .write(const QuestionsCompanion(hidden: Value(true)));
    });
  }
}

/// A selection is right only if it matches the answer set exactly.
bool isCorrect(List<int> selected, List<int> answer) {
  final a = selected.toSet();
  final b = answer.toSet();
  return a.length == b.length && a.containsAll(b);
}
