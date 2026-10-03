import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

class Banks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get questionCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Published questions mirrored from the server. [hidden] is set when the server
/// withdraws a question: it disappears from quizzes but answer history stays.
class Questions extends Table {
  TextColumn get id => text()();
  TextColumn get bankId => text()();
  TextColumn get type => text()(); // single | judge
  TextColumn get stem => text()();
  TextColumn get optionsJson => text()();
  TextColumn get answerJson => text()();
  TextColumn get explanation => text().withDefault(const Constant(''))();
  IntColumn get difficulty => integer().withDefault(const Constant(3))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  TextColumn get sourceQuote => text().withDefault(const Constant(''))();
  IntColumn get syncSeq => integer()();
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Append-only answer log. [synced] false = still in the outbox.
class Attempts extends Table {
  TextColumn get id => text()(); // client ULID, idempotency key
  TextColumn get questionId => text()();
  TextColumn get deviceId => text()();
  TextColumn get answerJson => text()();
  BoolColumn get isCorrect => boolean()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get answeredAt => integer()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-question learning state. [dirty] true = changed locally, not uploaded.
/// [fsrsJson] is opaque to the server; until FSRS lands it holds the app's own
/// progress record (see ProgressRecord).
class QuestionStates extends Table {
  TextColumn get questionId => text()();
  TextColumn get fsrsJson => text().nullable()();
  IntColumn get dueAt => integer().nullable()();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();
  IntColumn get wrongCount => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {questionId};
}

/// "This question looks wrong" reports waiting to be uploaded.
class PendingFlags extends Table {
  TextColumn get questionId => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {questionId};
}

/// Sync cursors and the last sync time, keyed by name.
class SyncMeta extends Table {
  TextColumn get key => text()();
  IntColumn get value => integer()();

  @override
  Set<Column> get primaryKey => {key};
}

/// A finished mock exam. Append-only. [itemsJson] is the paper in order,
/// `[{"q": id, "s": [picked], "c": correct}]`, so it can be reviewed on any device.
/// [synced] false = still in the outbox.
@DataClassName('ExamRow')
class Exams extends Table {
  TextColumn get id => text()(); // client ULID, idempotency key
  TextColumn get bankId => text()();
  TextColumn get title => text()();
  IntColumn get finishedAt => integer()();
  IntColumn get total => integer()();
  IntColumn get correct => integer()();
  IntColumn get answered => integer()();
  IntColumn get percent => integer()();
  BoolColumn get passed => boolean()();
  IntColumn get limitSec => integer().nullable()();
  IntColumn get usedMs => integer()();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  TextColumn get itemsJson => text().withDefault(const Constant('[]'))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// An exam in progress, kept on this device only so a killed app can resume it.
/// One per bank; [dataJson] is an ExamDraft.
@DataClassName('ExamDraftRow')
class ExamDrafts extends Table {
  TextColumn get bankId => text()();
  TextColumn get dataJson => text()();
  IntColumn get savedAt => integer()();

  @override
  Set<Column> get primaryKey => {bankId};
}

@DriftDatabase(tables: [Banks, Questions, Attempts, QuestionStates, PendingFlags, SyncMeta, Exams, ExamDrafts])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'quizmind'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Exams used to live in shared preferences (see importLegacyExams).
            await m.createTable(exams);
            await m.createTable(examDrafts);
          }
        },
      );
}
