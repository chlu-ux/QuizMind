import 'dart:convert';

import 'package:drift/drift.dart';

import 'ai_config_store.dart';
import 'api.dart';
import 'database.dart';
import 'media_store.dart';
import 'media_text.dart';
import 'models.dart';
import 'session_store.dart';

class SyncReport {
  const SyncReport({
    this.questionsUpdated = 0,
    this.questionsRemoved = 0,
    this.attemptsUploaded = 0,
    this.statesUploaded = 0,
    this.statesPulled = 0,
    this.attemptsPulled = 0,
    this.examsUploaded = 0,
    this.examsPulled = 0,
    this.sessionsPulled = 0,
    this.lessonsPulled = 0,
    this.notesUploaded = 0,
    this.notesPulled = 0,
    this.picturesDownloaded = 0,
    this.aiConfigUpdated = false,
    this.aiWarning,
  });

  final int questionsUpdated;
  final int questionsRemoved;
  final int attemptsUploaded;
  final int statesUploaded;
  final int statesPulled;

  /// Answers other devices gave (they count towards statistics here).
  final int attemptsPulled;
  final int examsUploaded;
  final int examsPulled;

  /// Saved quizzes taken from another device.
  final int sessionsPulled;

  /// Sections of the study text downloaded; 0 when it had not changed.
  final int lessonsPulled;

  /// AI explanations sent to / taken from the server.
  final int notesUploaded;
  final int notesPulled;

  /// Pictures used by questions that were saved on this device for offline use.
  final int picturesDownloaded;

  /// The LLM configuration was fetched from the server (a new or changed one).
  final bool aiConfigUpdated;

  /// Why the AI configuration could not be fetched (wrong token), if that was tried.
  final String? aiWarning;

  String get summary {
    final parts = <String>[
      if (questionsUpdated > 0) '新增/更新 $questionsUpdated 题',
      if (questionsRemoved > 0) '下线 $questionsRemoved 题',
      if (attemptsUploaded > 0) '上传 $attemptsUploaded 条作答',
      if (attemptsPulled > 0) '同步了其他设备的 $attemptsPulled 条作答',
      if (examsPulled > 0) '同步了 $examsPulled 场考试',
      if (sessionsPulled > 0) '同步了 $sessionsPulled 个题库的刷题进度',
      if (lessonsPulled > 0) '更新了讲义（$lessonsPulled 节）',
      if (notesUploaded > 0) '上传 $notesUploaded 条 AI 解读',
      if (notesPulled > 0) '同步了 $notesPulled 条 AI 解读',
      if (picturesDownloaded > 0) '下载了 $picturesDownloaded 张题目配图',
      if (aiConfigUpdated) '已更新 AI 配置',
      ?aiWarning,
    ];
    return parts.isEmpty ? '已是最新' : parts.join('，');
  }
}

/// Uploads the outbox, then pulls server changes. Uploading first means a
/// device never loses local progress to a stale pull.
class SyncService {
  SyncService(this.db, this.api, {this.sessions, this.aiConfig, this.media, this.deviceId = '', DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final QuizApi api;

  /// Where saved quizzes live; null skips progress sync.
  final SessionStore? sessions;

  /// Where the AI explanation settings live; null skips fetching the configuration.
  final AiConfigStore? aiConfig;

  /// Where the pictures of questions are saved; null leaves them to be loaded when shown.
  final MediaStore? media;
  final String deviceId;
  final DateTime Function() _clock;

  static const questionCursor = 'question_seq';
  static const stateCursor = 'state_seq';
  static const attemptCursor = 'attempt_seq';
  static const examCursor = 'exam_seq';
  static const noteCursor = 'note_seq';
  static const lessonsVersion = 'lessons_version';
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
    await _pushSessions();
    final examsUp = await _pushExams();
    final notesUp = await _pushNotes();
    final banks = await api.banks();
    final q = await _pullQuestions();
    final statesDown = await _pullStates();
    // After the states: a restored quiz shows its answers from the local state rows.
    final sessionsDown = await _pullSessions();
    final attemptsDown = await _pullAttempts();
    final examsDown = await _pullExams();
    final lessonsDown = await _pullLessons();
    final notesDown = await _pullNotes();
    final ai = await _fetchAiConfig();
    await _replaceBanks(banks);
    await _setMeta(lastSyncAt, _clock().millisecondsSinceEpoch);
    final pictures = await _downloadPictures();
    return SyncReport(
      questionsUpdated: q.$1,
      questionsRemoved: q.$2,
      attemptsUploaded: attempts,
      statesUploaded: statesUp,
      statesPulled: statesDown,
      attemptsPulled: attemptsDown,
      examsUploaded: examsUp,
      examsPulled: examsDown,
      sessionsPulled: sessionsDown,
      lessonsPulled: lessonsDown,
      notesUploaded: notesUp,
      notesPulled: notesDown,
      picturesDownloaded: pictures,
      aiConfigUpdated: ai.updated,
      aiWarning: ai.warning,
    );
  }

  /// Saves every picture the (visible) questions use, so they show without a connection. Last, and
  /// never fatal: a picture that cannot be fetched now is loaded when it is first shown.
  Future<int> _downloadPictures() async {
    final store = media;
    if (store == null) return 0;
    try {
      final rows = await (db.select(db.questions)
            ..where((q) => q.hidden.equals(false) & (q.stem.like('%(media:%') | q.optionsJson.like('%(media:%') | q.explanation.like('%(media:%'))))
          .get();
      final lessons = await (db.select(db.lessons)..where((l) => l.body.like('%(media:%'))).get();
      final ids = mediaIds([
        for (final q in rows) ...[q.stem, q.optionsJson, q.explanation],
        for (final l in lessons) l.body,
      ]);
      return await store.prefetch(ids);
    } catch (_) {
      return 0;
    }
  }

  Future<int> _pushAttempts() async {
    var total = 0;
    // An attempt that gains reading time mid-upload stays queued; it goes out with the next sync, not in a loop here.
    final sent = <String>{};
    while (true) {
      final rows = await (db.select(db.attempts)
            ..where((a) => a.synced.equals(false) & a.id.isNotIn(sent))
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
            reviewMs: r.reviewMs,
            answeredAt: r.answeredAt,
          ),
      ]);
      sent.addAll(rows.map((r) => r.id));
      // Leave a row queued if reading time was added while the upload was in flight.
      await db.transaction(() async {
        for (final r in rows) {
          final stillSame = r.reviewMs == null ? db.attempts.reviewMs.isNull() : db.attempts.reviewMs.equals(r.reviewMs!);
          await (db.update(db.attempts)..where((a) => a.id.equals(r.id) & stillSame))
              .write(const AttemptsCompanion(synced: Value(true)));
        }
      });
      total += rows.length;
    }
  }

  Future<void> _pushFlags() async {
    final rows = await db.select(db.pendingFlags).get();
    for (final f in rows) {
      try {
        await api.flagQuestion(f.questionId, reason: f.reason);
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

  /// A server without the sessions endpoint answers 404. Progress sync is a
  /// convenience, so that must not fail the rest of the sync.
  static bool _unsupported(ApiException e) => e.status == 404;

  static const _sessionBatch = 50; // the server's per-request limit

  Future<void> _pushSessions() async {
    final store = sessions;
    if (store == null) return;
    final pending = store.pending();
    try {
      for (var i = 0; i < pending.length; i += _sessionBatch) {
        final batch = pending.skip(i).take(_sessionBatch).toList();
        await api.uploadSessions([
          for (final p in batch) SessionDto(scope: p.scope, data: p.data, updatedAt: p.updatedAt, deviceId: deviceId),
        ]);
        for (final p in batch) {
          await store.markUploaded(p.scope, p.updatedAt);
        }
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
    }
  }

  static const _examBatch = 10; // the server's per-request limit

  Future<int> _count(TableInfo<Table, dynamic> table) async {
    final n = countAll();
    return (await (db.selectOnly(table)..addColumns([n])).map((r) => r.read(n)!).getSingle());
  }

  Future<int> _pushExams() async {
    var total = 0;
    try {
      while (true) {
        final rows = await (db.select(db.exams)
              ..where((e) => e.synced.equals(false))
              ..orderBy([(e) => OrderingTerm.asc(e.finishedAt)])
              ..limit(_examBatch))
            .get();
        if (rows.isEmpty) return total;
        await api.uploadExams([
          for (final r in rows)
            ExamRecord(
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
              // Exams imported from older versions carry no device.
              deviceId: r.deviceId.isEmpty ? deviceId : r.deviceId,
              items: [
                for (final j in jsonDecode(r.itemsJson) as List) ExamItemRecord.fromJson(j as Map<String, dynamic>),
              ],
            ),
        ]);
        await (db.update(db.exams)..where((e) => e.id.isIn(rows.map((r) => r.id))))
            .write(const ExamsCompanion(synced: Value(true)));
        total += rows.length;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return total;
    }
  }

  /// Answers of every device, so statistics cover everything. Attempts are an
  /// append-only log: only unknown ids are added. The one thing a known attempt can
  /// still gain is review time.
  Future<int> _pullAttempts() async {
    var pulled = 0;
    var cursor = await _meta(attemptCursor);
    try {
      while (true) {
        final page = await api.syncAttempts(since: cursor, limit: _batch);
        final before = await _count(db.attempts);
        await db.transaction(() async {
          await db.batch((b) => b.insertAll(
                db.attempts,
                [
                  for (final a in page.items)
                    AttemptsCompanion.insert(
                      id: a.id,
                      questionId: a.questionId,
                      deviceId: a.deviceId,
                      answerJson: jsonEncode(a.answer),
                      isCorrect: a.isCorrect,
                      durationMs: Value(a.durationMs),
                      reviewMs: Value(a.reviewMs),
                      answeredAt: a.answeredAt,
                      synced: const Value(true),
                    ),
                ],
                mode: InsertMode.insertOrIgnore,
              ));
          for (final a in page.items) {
            final review = a.reviewMs;
            if (review == null) continue;
            // Already known: only a larger review time is taken (it never shrinks).
            await (db.update(db.attempts)..where((t) => t.id.equals(a.id) & (t.reviewMs.isNull() | t.reviewMs.isSmallerThanValue(review))))
                .write(AttemptsCompanion(reviewMs: Value(review)));
          }
          await _setMeta(attemptCursor, page.nextSeq);
        });
        pulled += await _count(db.attempts) - before;
        cursor = page.nextSeq;
        if (!page.hasMore) return pulled;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return pulled;
    }
  }

  /// Exams are immutable, so a known id is skipped.
  Future<int> _pullExams() async {
    var pulled = 0;
    var cursor = await _meta(examCursor);
    try {
      while (true) {
        final page = await api.syncExams(since: cursor, limit: _examBatch);
        final before = await _count(db.exams);
        await db.transaction(() async {
          await db.batch((b) => b.insertAll(
                db.exams,
                [
                  for (final e in page.items)
                    ExamsCompanion.insert(
                      id: e.id,
                      bankId: e.bankId,
                      title: e.title,
                      finishedAt: e.finishedAt,
                      total: e.total,
                      correct: e.correct,
                      answered: e.answered,
                      percent: e.percent,
                      passed: e.passed,
                      limitSec: Value(e.limitSec),
                      usedMs: e.usedMs,
                      deviceId: Value(e.deviceId),
                      itemsJson: Value(jsonEncode([for (final it in e.items) it.toJson()])),
                      synced: const Value(true),
                    ),
                ],
                mode: InsertMode.insertOrIgnore,
              ));
          await _setMeta(examCursor, page.nextSeq);
        });
        pulled += await _count(db.exams) - before;
        cursor = page.nextSeq;
        if (!page.hasMore) return pulled;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return pulled;
    }
  }

  /// The study text is small and rarely changes, so it is fetched whole whenever the server's version
  /// differs from ours and replaces what we had. Returns how many sections came down. A server from
  /// before lessons (404) simply has nothing to read.
  Future<int> _pullLessons() async {
    try {
      final page = await api.lessons(version: await _meta(lessonsVersion));
      if (page.unchanged) return 0;
      await db.transaction(() async {
        await db.delete(db.lessons).go();
        await db.batch((b) => b.insertAll(db.lessons, [
              for (final l in page.items)
                LessonsCompanion.insert(
                  id: l.id,
                  bankId: l.bankId,
                  documentId: l.documentId,
                  documentTitle: l.documentTitle,
                  documentOrder: l.documentOrder,
                  seq: l.seq,
                  headingPath: l.headingPath,
                  body: l.text,
                ),
            ]));
        await _setMeta(lessonsVersion, page.version);
      });
      return page.items.length;
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return 0;
    }
  }

  /// Last-writer-wins on updated_at, so a newer local quiz survives the pull.
  /// Returns how many saved quizzes were taken from the server.
  Future<int> _pullSessions() async {
    final store = sessions;
    if (store == null) return 0;
    var pulled = 0;
    var cursor = store.cursor;
    try {
      while (true) {
        final page = await api.syncSessions(since: cursor, limit: _sessionBatch);
        for (final s in page.items) {
          if (await store.applyRemote(s.scope, s.data, s.updatedAt)) pulled++;
        }
        await store.setCursor(page.nextSeq);
        cursor = page.nextSeq;
        if (!page.hasMore) return pulled;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return pulled;
    }
  }

  static const _noteBatch = 100; // the server's per-request limit

  Future<int> _pushNotes() async {
    var total = 0;
    try {
      while (true) {
        final rows = await (db.select(db.aiNotes)
              ..where((n) => n.dirty.equals(true))
              ..orderBy([(n) => OrderingTerm.asc(n.updatedAt)])
              ..limit(_noteBatch))
            .get();
        if (rows.isEmpty) return total;
        await api.uploadNotes([
          for (final r in rows)
            NoteDto(
              questionId: r.questionId,
              content: r.content,
              updatedAt: r.updatedAt,
              model: r.model,
              promptVersion: r.promptVersion,
              selected: (jsonDecode(r.selectedJson) as List).map((e) => (e as num).toInt()).toList(),
              deviceId: deviceId,
            ),
        ]);
        // Clear the flag only if the explanation was not regenerated while the upload was in flight.
        for (final r in rows) {
          await (db.update(db.aiNotes)..where((n) => n.questionId.equals(r.questionId) & n.updatedAt.equals(r.updatedAt)))
              .write(const AiNotesCompanion(dirty: Value(false)));
        }
        total += rows.length;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return total;
    }
  }

  /// Last-writer-wins on updated_at, so a newer local explanation survives the pull.
  Future<int> _pullNotes() async {
    var pulled = 0;
    var cursor = await _meta(noteCursor);
    try {
      while (true) {
        final page = await api.syncNotes(since: cursor, limit: _noteBatch);
        await db.transaction(() async {
          for (final n in page.items) {
            final local =
                await (db.select(db.aiNotes)..where((x) => x.questionId.equals(n.questionId))).getSingleOrNull();
            if (local != null && local.updatedAt >= n.updatedAt) continue;
            await db.into(db.aiNotes).insertOnConflictUpdate(AiNotesCompanion.insert(
                  questionId: n.questionId,
                  content: n.content,
                  model: Value(n.model),
                  promptVersion: Value(n.promptVersion),
                  selectedJson: Value(jsonEncode(n.selected)),
                  updatedAt: n.updatedAt,
                  dirty: const Value(false),
                ));
            pulled++;
          }
          await _setMeta(noteCursor, page.nextSeq);
        });
        cursor = page.nextSeq;
        if (!page.hasMore) return pulled;
      }
    } on ApiException catch (e) {
      if (!_unsupported(e)) rethrow;
      return pulled;
    }
  }

  /// Fetches the LLM configuration with the access token, when there is one. A
  /// failure never fails the sync: a wrong token is reported, a server with the
  /// feature off (404) drops the copy we hold, and anything else keeps what we have.
  Future<({bool updated, String? warning})> _fetchAiConfig() async {
    final store = aiConfig;
    if (store == null || store.token.isEmpty) return (updated: false, warning: null);
    try {
      final fresh = await api.aiConfig(token: store.token);
      final old = store.synced;
      await store.setSynced(fresh);
      final changed = old == null || old.toJson().toString() != fresh.toJson().toString();
      return (updated: changed, warning: null);
    } on ApiException catch (e) {
      switch (e.status) {
        case 401:
          return (updated: false, warning: 'AI 访问令牌不对，没能更新 AI 配置');
        case 404:
          await store.setSynced(null);
          return (updated: false, warning: null);
        default:
          return (updated: false, warning: null);
      }
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
                documentId: Value(q.documentId),
                documentTitle: Value(q.documentTitle),
                documentOrder: Value(q.documentOrder),
                chunkId: Value(q.chunkId),
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
