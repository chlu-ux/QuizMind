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
}
