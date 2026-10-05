import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase memoryDb() => AppDatabase(NativeDatabase.memory());

QuestionDto question(String id, {int seq = 1, String bank = 'b1', int answer = 0, String type = 'single'}) => QuestionDto(
      id: id,
      bankId: bank,
      type: type,
      stem: '题干 $id',
      options: type == 'judge' ? ['正确', '错误'] : ['A', 'B', 'C', 'D'],
      answer: [answer],
      explanation: '解析',
      difficulty: 2,
      tags: const ['t'],
      sourceQuote: '原文',
      syncSeq: seq,
    );

/// An in-memory stand-in for the server that records uploads.
class FakeApi implements QuizApi {
  List<BankDto> bankList = [BankDto(id: 'b1', title: '题库', description: '', questionCount: 0)];
  final List<QuestionDto> published = [];
  final List<String> withdrawnAfter = [];
  final List<StateDto> remoteStates = [];
  final List<AttemptDto> uploadedAttempts = [];
  final List<StateDto> uploadedStates = [];

  /// What other devices uploaded; the pull side of attempt and exam sync.
  final List<AttemptDto> remoteAttempts = [];
  final List<ExamRecord> remoteExams = [];
  final List<ExamRecord> uploadedExams = [];

  /// Behave like a server from before attempt/exam download existed (404).
  bool historyUnsupported = false;
  final List<String> flagged = [];
  final List<String?> flagReasons = [];
  int pageSize = 1000;
  Object? failWith;

  /// Runs while an attempt upload is in flight (something the learner does meanwhile).
  Future<void> Function()? duringAttemptUpload;

  /// Saved quizzes by scope, with the server sequence of their last change.
  final Map<String, ({SessionDto session, int seq})> sessions = {};
  int _sessionSeq = 0;

  /// Behave like a server from before progress sync existed (404).
  bool sessionsUnsupported = false;

  @override
  Future<void> health() async {}

  @override
  Future<List<BankDto>> banks() async {
    _maybeFail();
    return bankList;
  }

  @override
  Future<QuestionsPage> syncQuestions({required int since, int limit = 500}) async {
    _maybeFail();
    final rows = published.where((q) => q.syncSeq > since).toList()..sort((a, b) => a.syncSeq.compareTo(b.syncSeq));
    final take = rows.take(pageSize).toList();
    return QuestionsPage(
      items: take,
      deleted: take.isEmpty ? [] : withdrawnAfter,
      nextSeq: take.isEmpty ? since : take.last.syncSeq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<StatesPage> syncStates({required int since, int limit = 500}) async {
    _maybeFail();
    return StatesPage(items: remoteStates, nextSeq: remoteStates.isEmpty ? since : 99, hasMore: false);
  }

  @override
  Future<void> uploadAttempts(List<AttemptDto> attempts) async {
    _maybeFail();
    await duringAttemptUpload?.call();
    uploadedAttempts.addAll(attempts);
  }

  @override
  Future<AttemptsPage> syncAttempts({required int since, int limit = 500}) async {
    _maybeFail();
    if (historyUnsupported) throw ApiException('not found', status: 404);
    // The fake's sequence number is the 1-based position in the list.
    final rows = [for (var i = 0; i < remoteAttempts.length; i++) (a: remoteAttempts[i], seq: i + 1)]
        .where((r) => r.seq > since)
        .toList();
    final take = rows.take(limit).toList();
    return AttemptsPage(
      items: [for (final r in take) r.a],
      nextSeq: take.isEmpty ? since : take.last.seq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<ExamsPage> syncExams({required int since, int limit = 100}) async {
    _maybeFail();
    if (historyUnsupported) throw ApiException('not found', status: 404);
    final rows = [for (var i = 0; i < remoteExams.length; i++) (e: remoteExams[i], seq: i + 1)]
        .where((r) => r.seq > since)
        .toList();
    final take = rows.take(limit).toList();
    return ExamsPage(
      items: [for (final r in take) r.e],
      nextSeq: take.isEmpty ? since : take.last.seq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<void> uploadExams(List<ExamRecord> exams) async {
    _maybeFail();
    if (historyUnsupported) throw ApiException('not found', status: 404);
    uploadedExams.addAll(exams);
  }

  @override
  Future<void> uploadStates(List<StateDto> states) async {
    _maybeFail();
    uploadedStates.addAll(states);
  }

  @override
  Future<SessionsPage> syncSessions({required int since, int limit = 100}) async {
    _maybeFail();
    if (sessionsUnsupported) throw ApiException('not found', status: 404);
    final rows = sessions.values.where((r) => r.seq > since).toList()..sort((a, b) => a.seq.compareTo(b.seq));
    final take = rows.take(limit).toList();
    return SessionsPage(
      items: [for (final r in take) r.session],
      nextSeq: take.isEmpty ? since : take.last.seq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<void> uploadSessions(List<SessionDto> list) async {
    _maybeFail();
    if (sessionsUnsupported) throw ApiException('not found', status: 404);
    for (final s in list) {
      final have = sessions[s.scope];
      if (have != null && have.session.updatedAt >= s.updatedAt) continue; // last writer wins
      sessions[s.scope] = (session: s, seq: ++_sessionSeq);
    }
  }

  /// Explanations other devices uploaded, and those this device uploaded.
  final List<NoteDto> remoteNotes = [];
  final List<NoteDto> uploadedNotes = [];
  bool notesUnsupported = false;

  /// What /ai/config answers: the configuration for [aiToken], else 401; null config = 404.
  AiConfig? aiConfigOnServer;
  String aiToken = 'tok';
  final List<String> aiTokensSeen = [];

  @override
  Future<NotesPage> syncNotes({required int since, int limit = 100}) async {
    _maybeFail();
    if (notesUnsupported) throw ApiException('not found', status: 404);
    final rows = [for (var i = 0; i < remoteNotes.length; i++) (n: remoteNotes[i], seq: i + 1)]
        .where((r) => r.seq > since)
        .toList();
    final take = rows.take(limit).toList();
    return NotesPage(
      items: [for (final r in take) r.n],
      nextSeq: take.isEmpty ? since : take.last.seq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<void> uploadNotes(List<NoteDto> notes) async {
    _maybeFail();
    if (notesUnsupported) throw ApiException('not found', status: 404);
    uploadedNotes.addAll(notes);
  }

  @override
  Future<AiConfig> aiConfig({required String token}) async {
    _maybeFail();
    aiTokensSeen.add(token);
    final c = aiConfigOnServer;
    if (c == null) throw ApiException('not found', status: 404);
    if (token != aiToken) throw ApiException('missing or invalid access token', status: 401);
    return c;
  }

  @override
  Future<void> flagQuestion(String id, {String? reason}) async {
    _maybeFail();
    flagged.add(id);
    flagReasons.add(reason);
  }

  void _maybeFail() {
    if (failWith != null) throw failWith!;
  }
}

/// Puts [n] questions into the database. Question [i] (1-based) gets the stem, tags and bank given by
/// the callbacks; the right answer is always option 1 ("乙") and none of them is hidden.
Future<List<Question>> seedQs(
  AppDatabase db, {
  int n = 3,
  String bank = 'b1',
  String Function(int i)? stem,
  List<String> Function(int i)? tags,
  String Function(int i)? explanation,
  int firstSeq = 1,
}) async {
  final ids = <String>[];
  for (var i = 1; i <= n; i++) {
    final id = '$bank-q$i';
    ids.add(id);
    await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: id,
          bankId: bank,
          type: 'single',
          stem: stem?.call(i) ?? '题干 $id',
          optionsJson: '["甲","乙","丙","丁"]',
          answerJson: '[1]',
          explanation: Value(explanation?.call(i) ?? '解析 $id'),
          tagsJson: Value(_json(tags?.call(i) ?? const ['锁'])),
          syncSeq: firstSeq + i - 1,
        ));
  }
  return (db.select(db.questions)..where((q) => q.id.isIn(ids))).get();
}

String _json(List<String> tags) => '[${tags.map((t) => '"$t"').join(',')}]';

Future<void> addBank(AppDatabase db, String id, String title, {int count = 0}) =>
    db.into(db.banks).insertOnConflictUpdate(BanksCompanion.insert(id: id, title: title, questionCount: Value(count)));

/// Mounts [child] in a MaterialApp over [db] and a fake server.
Future<ProviderContainer> pumpWith(
  WidgetTester tester,
  AppDatabase db,
  Widget child, {
  Map<String, Object> prefsValues = const {},
  DateTime Function()? clock,
}) async {
  SharedPreferences.setMockInitialValues(prefsValues);
  final prefs = await SharedPreferences.getInstance();
  late ProviderContainer container;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      apiProvider.overrideWithValue(FakeApi()),
    ],
    child: Builder(builder: (context) {
      container = ProviderScope.containerOf(context);
      return MaterialApp(home: child);
    }),
  ));
  await tester.pump();
  return container;
}

/// Lets database streams and futures that run outside the fake clock deliver.
Future<void> settleUi(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
  await tester.pump();
}

/// Leaves the page and closes the database; drift cancels its stream queries on a fake-clock timer.
Future<void> tearDownUi(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.runAsync(db.close);
}
