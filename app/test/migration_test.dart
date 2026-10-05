import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';

void main() {
  test('upgrading a version-1 database adds the exam tables and keeps what was there', () async {
    // What version 1 left behind: user_version 1 and an attempts table with a row in it.
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE attempts (
          id TEXT NOT NULL PRIMARY KEY, question_id TEXT NOT NULL, device_id TEXT NOT NULL,
          answer_json TEXT NOT NULL, is_correct INTEGER NOT NULL, duration_ms INTEGER,
          answered_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0
        )''');
      raw.execute("INSERT INTO attempts (id, question_id, device_id, answer_json, is_correct, answered_at) VALUES ('A', 'q', 'd', '[0]', 1, 5)");
      raw.execute('CREATE TABLE pending_flags (question_id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL)');
      raw.execute('PRAGMA user_version = 1');
    }));
    addTearDown(db.close);

    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.examDrafts).get(), isEmpty);
    await db.into(db.exams).insert(ExamsCompanion.insert(
          id: 'E', bankId: 'b', title: 't', finishedAt: 1, total: 1, correct: 1, answered: 1, percent: 100, passed: true,
          usedMs: 1, limitSec: const Value(null),
        ));
    expect((await db.select(db.exams).get()).single.itemsJson, '[]');
    expect((await db.select(db.attempts).get()).single.id, 'A');
  });

  test('upgrading a version-2 database adds the AI explanation table', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE attempts (
          id TEXT NOT NULL PRIMARY KEY, question_id TEXT NOT NULL, device_id TEXT NOT NULL,
          answer_json TEXT NOT NULL, is_correct INTEGER NOT NULL, duration_ms INTEGER,
          answered_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0
        )''');
      raw.execute("INSERT INTO attempts (id, question_id, device_id, answer_json, is_correct, answered_at) VALUES ('A', 'q', 'd', '[0]', 1, 5)");
      raw.execute('CREATE TABLE pending_flags (question_id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL)');
      raw.execute('PRAGMA user_version = 2');
    }));
    addTearDown(db.close);

    expect(await db.select(db.aiNotes).get(), isEmpty);
    await db.into(db.aiNotes).insert(AiNotesCompanion.insert(questionId: 'q', content: '讲解', updatedAt: 1));
    final row = (await db.select(db.aiNotes).get()).single;
    expect((row.model, row.selectedJson, row.dirty), ('', '[]', false));
    expect((await db.select(db.attempts).get()).single.id, 'A');
  });

  test('upgrading a version-3 database adds review time to attempts and keeps the rows', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE attempts (
          id TEXT NOT NULL PRIMARY KEY, question_id TEXT NOT NULL, device_id TEXT NOT NULL,
          answer_json TEXT NOT NULL, is_correct INTEGER NOT NULL, duration_ms INTEGER,
          answered_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0
        )''');
      raw.execute("INSERT INTO attempts (id, question_id, device_id, answer_json, is_correct, duration_ms, answered_at, synced) VALUES ('A', 'q', 'd', '[0]', 1, 800, 5, 1)");
      raw.execute('CREATE TABLE pending_flags (question_id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL)');
      raw.execute('PRAGMA user_version = 3');
    }));
    addTearDown(db.close);

    final a = (await db.select(db.attempts).get()).single;
    expect((a.id, a.durationMs, a.reviewMs, a.synced), ('A', 800, null, true));
    await (db.update(db.attempts)..where((t) => t.id.equals('A'))).write(const AttemptsCompanion(reviewMs: Value(1200)));
    expect((await db.select(db.attempts).get()).single.reviewMs, 1200);
  });

  test('upgrading a version-4 database adds the report reason and keeps queued reports', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('CREATE TABLE pending_flags (question_id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL)');
      raw.execute("INSERT INTO pending_flags (question_id, created_at) VALUES ('q1', 7)");
      raw.execute('PRAGMA user_version = 4');
    }));
    addTearDown(db.close);

    final old = (await db.select(db.pendingFlags).get()).single;
    expect((old.questionId, old.createdAt, old.reason), ('q1', 7, null), reason: 'a report from before reasons has none');
    await db.into(db.pendingFlags).insert(PendingFlagsCompanion.insert(questionId: 'q2', createdAt: 8, reason: const Value('typo')));
    expect((await (db.select(db.pendingFlags)..where((f) => f.questionId.equals('q2'))).getSingle()).reason, 'typo');
  });
}
