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

  /// The document (module / chapter) the question was generated from; empty for questions
  /// synced before the server sent it. [documentOrder] is when that document was uploaded (ms).
  TextColumn get documentId => text().withDefault(const Constant(''))();
  TextColumn get documentTitle => text().withDefault(const Constant(''))();
  IntColumn get documentOrder => integer().withDefault(const Constant(0))();

  /// The lesson (section of the study text) the question was generated from; empty for questions
  /// synced before the server sent it.
  TextColumn get chunkId => text().withDefault(const Constant(''))();
  IntColumn get syncSeq => integer()();
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  /// A question the assistant wrote on this device while the server was out of reach. '' for every question
  /// the server knows; `pending` waits to be uploaded (it is part of the bank here meanwhile, its [syncSeq]
  /// is 0); `refused` was turned down by the server's checks (hidden, the reason is in [localNote]). The
  /// next sync that brings the question back from the server clears it.
  TextColumn get localState => text().withDefault(const Constant(''))();
  TextColumn get localNote => text().withDefault(const Constant(''))();

  /// The assistant conversation that wrote the question, for the ones written on this device.
  TextColumn get agentConv => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Answer log. Rows never change except [reviewMs], which only grows. [synced] false = still in the outbox.
class Attempts extends Table {
  TextColumn get id => text()(); // client ULID, idempotency key
  TextColumn get questionId => text()();
  TextColumn get deviceId => text()();
  TextColumn get answerJson => text()();
  BoolColumn get isCorrect => boolean()();
  IntColumn get durationMs => integer().nullable()();

  /// Time spent on the question after answering it (explanation, AI). Grows while
  /// the learner stays on it, so an uploaded attempt can be queued again.
  IntColumn get reviewMs => integer().nullable()();
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

  /// A FlagReason wire value; null for reports queued before reasons existed.
  TextColumn get reason => text().nullable()();

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

/// The AI explanation of a question, one per question (a re-generated one replaces
/// the old). [content] is Markdown; [selectedJson] the option indexes the learner had
/// picked when asking. [dirty] true = changed locally, not uploaded.
class AiNotes extends Table {
  TextColumn get questionId => text()();
  TextColumn get content => text()();
  TextColumn get model => text().withDefault(const Constant(''))();
  TextColumn get promptVersion => text().withDefault(const Constant(''))();
  TextColumn get selectedJson => text().withDefault(const Constant('[]'))();
  IntColumn get updatedAt => integer()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {questionId};
}

/// One section of the study text of a bank, mirrored whole from the server (the library is replaced
/// whenever its version changes). A question's [Questions.chunkId] is a lesson id. [documentOrder] is
/// when the chapter (document) was uploaded; [seq] the place within it.
class Lessons extends Table {
  TextColumn get id => text()();
  TextColumn get bankId => text()();
  TextColumn get documentId => text()();
  TextColumn get documentTitle => text()();
  IntColumn get documentOrder => integer()();
  IntColumn get seq => integer()();
  TextColumn get headingPath => text()();
  TextColumn get body => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A lesson the learner marked as read. Kept on this device only.
class LessonReads extends Table {
  TextColumn get lessonId => text()();
  TextColumn get bankId => text()();
  IntColumn get readAt => integer()();

  @override
  Set<Column> get primaryKey => {lessonId};
}

/// A conversation with the assistant that ran on this device (the server could not be reached). The ones
/// on the server are not copied here.
class AgentConversations extends Table {
  TextColumn get id => text()();
  TextColumn get mode => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get bankId => text().withDefault(const Constant(''))();
  TextColumn get lessonId => text().withDefault(const Constant(''))();
  TextColumn get questionId => text().withDefault(const Constant(''))();

  /// What the learner was looking at when the conversation began, written as the model is told it. It goes
  /// in front of the first message of every request, as part of what the learner said.
  TextColumn get briefing => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One message of a local conversation. [toolsJson] is the status lines of the tools an answer used,
/// [draftsJson] the ids of the questions it wrote (the questions themselves are in [Questions]).
class AgentMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get conversationId => text()();
  TextColumn get role => text()(); // user | assistant
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get toolsJson => text().withDefault(const Constant('[]'))();
  TextColumn get draftsJson => text().withDefault(const Constant('[]'))();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get error => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();
}

@DriftDatabase(tables: [Banks, Questions, Attempts, QuestionStates, PendingFlags, SyncMeta, Exams, ExamDrafts, AiNotes, Lessons, LessonReads, AgentConversations, AgentMessages])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'quizmind'));

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Exams used to live in shared preferences (see importLegacyExams).
            await m.createTable(exams);
            await m.createTable(examDrafts);
          }
          if (from < 3) {
            await m.createTable(aiNotes);
          }
          if (from < 4) {
            await m.addColumn(attempts, attempts.reviewMs);
          }
          if (from < 5) {
            await m.addColumn(pendingFlags, pendingFlags.reason);
          }
          if (from < 6) {
            await m.addColumn(questions, questions.documentId);
            await m.addColumn(questions, questions.documentTitle);
            await m.addColumn(questions, questions.documentOrder);
          }
          if (from < 7) {
            await m.addColumn(questions, questions.chunkId);
            await m.createTable(lessons);
            await m.createTable(lessonReads);
          }
          if (from < 8) {
            await m.addColumn(questions, questions.localState);
            await m.addColumn(questions, questions.localNote);
            await m.addColumn(questions, questions.agentConv);
            await m.createTable(agentConversations);
            await m.createTable(agentMessages);
          }
          if (from == 8) {
            // Older databases create the table above, with this column already in it.
            await m.addColumn(agentConversations, agentConversations.briefing);
          }
        },
      );
}
