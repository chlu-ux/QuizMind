import 'dart:convert';

import 'package:drift/drift.dart';

import 'api.dart';
import 'database.dart';
import 'models.dart';

class SyncReport {
  const SyncReport({
    this.questionsUpdated = 0,
    this.questionsRemoved = 0,
    this.attemptsUploaded = 0,
    this.statesUploaded = 0,
    this.statesPulled = 0,
  });

  final int questionsUpdated;
  final int questionsRemoved;
  final int attemptsUploaded;
  final int statesUploaded;
  final int statesPulled;

  String get summary {
    final parts = <String>[
      if (questionsUpdated > 0) '新增/更新 $questionsUpdated 题',
      if (questionsRemoved > 0) '下线 $questionsRemoved 题',
      if (attemptsUploaded > 0) '上传 $attemptsUploaded 条作答',
    ];
    return parts.isEmpty ? '已是最新' : parts.join('，');
  }
}

/// Uploads the outbox, then pulls server changes. Uploading first means a
/// device never loses local progress to a stale pull.
class SyncService {
  SyncService(this.db, this.api, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final QuizApi api;
  final DateTime Function() _clock;

  static const questionCursor = 'question_seq';
  static const stateCursor = 'state_seq';
  static const lastSyncAt = 'last_sync_at';
  static const _batch = 500;

  Future<int> _meta(String key) async =>
      (await (db.select(db.syncMeta)..where((m) => m.key.equals(key))).getSingleOrNull())?.value ?? 0;

  Future<void> _setMeta(String key, int value) =>
      db.into(db.syncMeta).insertOnConflictUpdate(SyncMetaCompanion.insert(key: key, value: value));

  Future<DateTime?> lastSync() async {
    final v = await _meta(lastSyncAt);
    return v == 0 ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<SyncReport> run() async {
    final attempts = await _pushAttempts();
    await _pushFlags();
    final statesUp = await _pushStates();
    final banks = await api.banks();
    final q = await _pullQuestions();
    final statesDown = await _pullStates();
    await _replaceBanks(banks);
    await _setMeta(lastSyncAt, _clock().millisecondsSinceEpoch);
    return SyncReport(
      questionsUpdated: q.$1,
      questionsRemoved: q.$2,
      attemptsUploaded: attempts,
      statesUploaded: statesUp,
      statesPulled: statesDown,
    );
  }

  Future<int> _pushAttempts() async {
    var total = 0;
    while (true) {
      final rows = await (db.select(db.attempts)
            ..where((a) => a.synced.equals(false))
            ..orderBy([(a) => OrderingTerm.asc(a.answeredAt)])
            ..limit(_batch))
          .get();
      if (rows.isEmpty) return total;
      await api.uploadAttempts([
        for (final r in rows)
          AttemptDto(
            id: r.id,
            questionId: r.questionId,
            deviceId: r.deviceId,
            answer: (jsonDecode(r.answerJson) as List).map((e) => (e as num).toInt()).toList(),
            isCorrect: r.isCorrect,
            durationMs: r.durationMs,
            answeredAt: r.answeredAt,
          ),
      ]);
      await (db.update(db.attempts)..where((a) => a.id.isIn(rows.map((r) => r.id))))
          .write(const AttemptsCompanion(synced: Value(true)));
      total += rows.length;
    }
  }

  Future<void> _pushFlags() async {
    final rows = await db.select(db.pendingFlags).get();
    for (final f in rows) {
      try {
        await api.flagQuestion(f.questionId);
      } on ApiException catch (e) {
        // A question the server no longer knows cannot be flagged; drop the report.
        if (e.status != 404) rethrow;
      }
      await (db.delete(db.pendingFlags)..where((x) => x.questionId.equals(f.questionId))).go();
    }
  }

  Future<int> _pushStates() async {
    var total = 0;
    while (true) {
      final rows = await (db.select(db.questionStates)
            ..where((s) => s.dirty.equals(true))
            ..limit(_batch))
          .get();
      if (rows.isEmpty) return total;
      await api.uploadStates([
        for (final r in rows)
          StateDto(
            questionId: r.questionId,
            fsrs: r.fsrsJson == null ? null : jsonDecode(r.fsrsJson!) as Map<String, dynamic>?,
            dueAt: r.dueAt,
            favorite: r.favorite,
            wrongCount: r.wrongCount,
            updatedAt: r.updatedAt,
          ),
      ]);
      // Clear the flag only if the row was not edited while the upload was in flight.
      for (final r in rows) {
        await (db.update(db.questionStates)
              ..where((s) => s.questionId.equals(r.questionId) & s.updatedAt.equals(r.updatedAt)))
            .write(const QuestionStatesCompanion(dirty: Value(false)));
      }
      total += rows.length;
      if (rows.length < _batch) return total;
    }
  }

  /// Returns (updated, removed).
  Future<(int, int)> _pullQuestions() async {
    var updated = 0, removed = 0;
    var cursor = await _meta(questionCursor);
    while (true) {
      final page = await api.syncQuestions(since: cursor, limit: _batch);
      await db.transaction(() async {
        for (final q in page.items) {
          await db.into(db.questions).insertOnConflictUpdate(QuestionsCompanion.insert(
                id: q.id,
                bankId: q.bankId,
                type: q.type,
                stem: q.stem,
                optionsJson: jsonEncode(q.options),
                answerJson: jsonEncode(q.answer),
                explanation: Value(q.explanation),
                difficulty: Value(q.difficulty),
                tagsJson: Value(jsonEncode(q.tags)),
                sourceQuote: Value(q.sourceQuote),
                syncSeq: q.syncSeq,
                hidden: const Value(false),
              ));
        }
        if (page.deleted.isNotEmpty) {
          await (db.update(db.questions)..where((q) => q.id.isIn(page.deleted)))
              .write(const QuestionsCompanion(hidden: Value(true)));
        }
        await _setMeta(questionCursor, page.nextSeq);
      });
      updated += page.items.length;
      removed += page.deleted.length;
      cursor = page.nextSeq;
      if (!page.hasMore) return (updated, removed);
    }
  }

  /// Last-writer-wins on updated_at, so a newer local edit survives the pull.
  Future<int> _pullStates() async {
    var pulled = 0;
    var cursor = await _meta(stateCursor);
    while (true) {
      final page = await api.syncStates(since: cursor, limit: _batch);
      await db.transaction(() async {
        for (final s in page.items) {
          final local = await (db.select(db.questionStates)..where((x) => x.questionId.equals(s.questionId)))
              .getSingleOrNull();
          if (local != null && local.updatedAt >= s.updatedAt) continue;
          await db.into(db.questionStates).insertOnConflictUpdate(QuestionStatesCompanion.insert(
                questionId: s.questionId,
                fsrsJson: Value(s.fsrs == null ? null : jsonEncode(s.fsrs)),
                dueAt: Value(s.dueAt),
                favorite: Value(s.favorite),
                wrongCount: Value(s.wrongCount),
                updatedAt: s.updatedAt,
                dirty: const Value(false),
              ));
          pulled++;
        }
        await _setMeta(stateCursor, page.nextSeq);
      });
      cursor = page.nextSeq;
      if (!page.hasMore) return pulled;
    }
  }

  Future<void> _replaceBanks(List<BankDto> banks) => db.transaction(() async {
        await db.delete(db.banks).go();
        await db.batch((b) => b.insertAll(db.banks, [
              for (final x in banks)
                BanksCompanion.insert(
                    id: x.id, title: x.title, description: Value(x.description), questionCount: Value(x.questionCount)),
            ]));
      });
}
