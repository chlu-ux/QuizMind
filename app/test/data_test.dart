import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/ulid.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/progress.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/sync_service.dart';

import 'support.dart';

void main() {
  late AppDatabase db;
  late FakeApi api;
  late Repository repo;
  late SyncService sync;
  var tick = 1000;

  setUp(() async {
    db = memoryDb();
    api = FakeApi();
    tick = 1000;
    DateTime clock() => DateTime.fromMillisecondsSinceEpoch(tick += 10);
    repo = Repository(db, deviceId: 'dev1', clock: clock);
    sync = SyncService(db, api, clock: clock);
  });
  tearDown(() => db.close());

  test('ulid is 26 chars, unique and time ordered', () {
    final a = newUlid(now: DateTime.fromMillisecondsSinceEpoch(1000));
    final b = newUlid(now: DateTime.fromMillisecondsSinceEpoch(2000));
    expect(a, hasLength(26));
    expect(a.compareTo(b), lessThan(0));
    expect({for (var i = 0; i < 200; i++) newUlid()}, hasLength(200));
  });

  test('isCorrect compares answer sets exactly', () {
    expect(isCorrect([1], [1]), isTrue);
    expect(isCorrect([0], [1]), isFalse);
    expect(isCorrect([], [1]), isFalse);
    expect(isCorrect([0, 1], [1]), isFalse);
  });

  group('sync pull', () {
    test('downloads questions in pages and keeps the cursor', () async {
      api.pageSize = 2;
      api.published.addAll([question('q1', seq: 1), question('q2', seq: 2), question('q3', seq: 3)]);
      final r = await sync.run();
      expect(r.questionsUpdated, 3);
      expect((await repo.bankQuestions('b1')).map((q) => q.id), ['q1', 'q2', 'q3']);

      final again = await sync.run();
      expect(again.questionsUpdated, 0, reason: 'cursor persisted, nothing re-downloaded');
      expect(again.summary, '已是最新');
    });

    test('updates a changed question and hides withdrawn ones', () async {
      api.published.addAll([question('q1', seq: 1), question('q2', seq: 2)]);
      await sync.run();

      api.published
        ..clear()
        ..add(question('q1', seq: 3, answer: 2));
      api.withdrawnAfter.add('q2');
      final r = await sync.run();
      expect(r.questionsRemoved, 1);

      final qs = await repo.bankQuestions('b1');
      expect(qs.map((q) => q.id), ['q1']);
      expect(qs.single.answer, [2]);
      // The withdrawn question stays in the table so its history is kept.
      expect(await db.select(db.questions).get(), hasLength(2));
    });

    test('replaces the bank list', () async {
      api.bankList = [BankDto(id: 'b1', title: 'Go', description: 'd', questionCount: 5)];
      await sync.run();
      final banks = await db.select(db.banks).get();
      expect(banks.single.title, 'Go');
      expect(banks.single.questionCount, 5);
      expect(await sync.lastSync(), isNotNull);
    });

    test('a failed call leaves local data and the outbox intact', () async {
      api.published.add(question('q1'));
      await sync.run();
      final q = (await repo.bankQuestions('b1')).single;
      await repo.recordAnswer(question: q, selected: [0], durationMs: 10);

      api.failWith = ApiException('boom');
      await expectLater(sync.run(), throwsA(isA<ApiException>()));
      final pending = await (db.select(db.attempts)..where((a) => a.synced.equals(false))).get();
      expect(pending, hasLength(1));
    });
  });

  group('answering', () {
    late Question q;
    setUp(() async {
      api.published.add(question('q1', answer: 1));
      await sync.run();
      q = (await repo.bankQuestions('b1')).single;
    });

    test('a wrong answer enters the wrong book, two right ones in a row clear it', () async {
      var o = await repo.recordAnswer(question: q, selected: [0], durationMs: 500);
      expect(o.correct, isFalse);
      expect(o.enteredWrongBook, isTrue);
      expect(await repo.watchWrongBook().first, hasLength(1));

      o = await repo.recordAnswer(question: q, selected: [1], durationMs: 500);
      expect(o.correct, isTrue);
      expect(o.state.inWrongBook, isTrue, reason: 'one right answer is not enough');

      o = await repo.recordAnswer(question: q, selected: [1], durationMs: 500);
      expect(o.state.inWrongBook, isFalse);
      expect(await repo.watchWrongBook().first, isEmpty);
      expect(o.state.wrongCount, 1);
    });

    test('a miss after progress puts it back', () async {
      await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
      await repo.recordAnswer(question: q, selected: [1], durationMs: 1);
      await repo.recordAnswer(question: q, selected: [1], durationMs: 1);
      final o = await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
      expect(o.enteredWrongBook, isTrue);
      expect(o.state.wrongCount, 2);
    });

    test('favorites and clearing the wrong book mark the state dirty', () async {
      await repo.setFavorite(q.id, true);
      expect(await repo.watchFavorites().first, hasLength(1));
      await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
      await repo.clearFromWrongBook(q.id);
      expect(await repo.watchWrongBook().first, isEmpty);
      expect((await repo.getState(q.id))!.favorite, isTrue);
      expect((await repo.getState(q.id))!.dirty, isTrue);
    });

    test('bank stats use the latest attempt per question', () async {
      await repo.recordAnswer(question: q, selected: [0], durationMs: 1);
      var s = await repo.bankStats('b1');
      expect((s.total, s.answered, s.correct), (1, 1, 0));
      await repo.recordAnswer(question: q, selected: [1], durationMs: 1);
      s = await repo.bankStats('b1');
      expect((s.total, s.answered, s.correct), (1, 1, 1));
    });
  });

  group('sync push', () {
    late Question q;
    setUp(() async {
      api.published.add(question('q1', answer: 1));
      await sync.run();
      q = (await repo.bankQuestions('b1')).single;
    });

    test('uploads attempts and states once, then the outbox is empty', () async {
      await repo.recordAnswer(question: q, selected: [0], durationMs: 800);
      final r = await sync.run();
      expect(r.attemptsUploaded, 1);
      expect(r.statesUploaded, 1);

      final a = api.uploadedAttempts.single;
      expect(a.deviceId, 'dev1');
      expect(a.answer, [0]);
      expect(a.isCorrect, isFalse);
      expect(a.id, hasLength(26));
      final s = api.uploadedStates.single;
      expect(s.wrongCount, 1);
      expect(s.fsrs!['streak'], 0);

      await sync.run();
      expect(api.uploadedAttempts, hasLength(1));
      expect(api.uploadedStates, hasLength(1));
    });

    test('a pending flag is uploaded then dropped; unknown questions are tolerated', () async {
      await repo.flagQuestion(q.id);
      expect(await repo.bankQuestions('b1'), isEmpty, reason: 'hidden immediately');
      await sync.run();
      expect(api.flagged, ['q1']);
      expect(await db.select(db.pendingFlags).get(), isEmpty);

      await repo.flagQuestion('gone');
      api.failWith = ApiException('not found', status: 404);
      // flag 404 is swallowed; the next call (banks) then fails with the same error
      await expectLater(sync.run(), throwsA(isA<ApiException>()));
      expect(await db.select(db.pendingFlags).get(), isEmpty);
    });
  });

  group('state pull (last writer wins)', () {
    late Question q;
    setUp(() async {
      api.published.add(question('q1'));
      await sync.run();
      q = (await repo.bankQuestions('b1')).single;
    });

    test('takes a newer remote state and keeps a newer local one', () async {
      api.remoteStates.add(StateDto(
          questionId: 'q1', fsrs: {'streak': 0}, favorite: true, wrongCount: 3, updatedAt: 5000000000000));
      await sync.run();
      var s = (await repo.getState(q.id))!;
      expect(s.favorite, isTrue);
      expect(s.wrongCount, 3);
      expect(s.dirty, isFalse, reason: 'pulled data is not re-uploaded');
      expect(s.inWrongBook, isTrue);

      api.remoteStates
        ..clear()
        ..add(StateDto(questionId: 'q1', favorite: false, wrongCount: 0, updatedAt: 1));
      await sync.run();
      s = (await repo.getState(q.id))!;
      expect(s.favorite, isTrue, reason: 'older remote loses');
    });

    test('a state for a question we do not have is still stored', () async {
      api.remoteStates.add(StateDto(questionId: 'other', favorite: true, wrongCount: 0, updatedAt: 42));
      await sync.run();
      expect(await repo.getState('other'), isNotNull);
    });
  });

  group('answer history and exams from other devices', () {
    AttemptDto remote(String id, bool correct, int at) => AttemptDto(
          id: id, questionId: 'q1', deviceId: 'phone', answer: [correct ? 1 : 0], isCorrect: correct, durationMs: 900, answeredAt: at,
        );
    ExamRecord exam(String id, int finished) => ExamRecord(
          id: id, bankId: 'b1', title: '题库', finishedAt: finished, total: 2, correct: 1, answered: 2, percent: 50,
          passed: false, limitSec: null, usedMs: 5000, deviceId: 'phone',
          items: const [
            ExamItemRecord(questionId: 'q1', selected: [1], correct: true),
            ExamItemRecord(questionId: 'q2', selected: [0], correct: false),
          ],
        );

    setUp(() async {
      api.published.add(question('q1', answer: 1));
      await sync.run();
    });

    test("downloads other devices' answers once, as already uploaded, so statistics cover both", () async {
      final q = (await repo.bankQuestions('b1')).single;
      await repo.recordAnswer(question: q, selected: [1], durationMs: 500); // this device
      api.remoteAttempts.addAll([remote('R1', false, 1000), remote('R2', true, 2000)]);
      final r = await sync.run();
      expect(r.attemptsPulled, 2);
      final rows = await db.select(db.attempts).get();
      expect(rows, hasLength(3));
      expect(rows.firstWhere((a) => a.id == 'R1').synced, isTrue);
      expect((await repo.bankReport('b1')).attempts, 3);

      expect((await sync.run()).attemptsPulled, 0, reason: 'cursor moved on');
      expect(api.uploadedAttempts.map((a) => a.id), isNot(contains('R1')), reason: 'never echoed back');
    });

    test('an attempt this device uploaded and then receives back is not duplicated', () async {
      final q = (await repo.bankQuestions('b1')).single;
      await repo.recordAnswer(question: q, selected: [0], durationMs: 500);
      await sync.run();
      api.remoteAttempts.addAll(api.uploadedAttempts); // the server echoes it
      expect((await sync.run()).attemptsPulled, 0);
      expect(await db.select(db.attempts).get(), hasLength(1));
    });

    test('pages through a long history', () async {
      api.remoteAttempts.addAll([for (var i = 0; i < 1200; i++) remote('R$i', true, i + 1)]);
      expect((await sync.run()).attemptsPulled, 1200);
    });

    test("uploads finished exams once and downloads the other devices'", () async {
      final q = (await repo.bankQuestions('b1')).single;
      await repo.submitExam(
        ExamRecord(
          id: 'MINE', bankId: 'b1', title: '题库', finishedAt: 3000, total: 2, correct: 1, answered: 1, percent: 50,
          passed: false, limitSec: null, usedMs: 1, items: const [ExamItemRecord(questionId: 'q1', selected: [1], correct: true)],
        ),
        [ExamAnswer(question: q, selected: const [1], durationMs: 10)],
      );
      expect((await db.select(db.exams).get()).single.synced, isFalse);
      api.remoteExams.add(exam('THEIRS', 4000));
      sync = SyncService(db, api, deviceId: 'dev1');
      final r = await sync.run();
      expect([r.examsUploaded, r.examsPulled], [1, 1]);
      expect(api.uploadedExams.map((e) => e.id), ['MINE']);
      expect(api.uploadedExams.single.deviceId, 'dev1', reason: 'filled in for exams saved without a device');
      expect((await repo.exams('b1')).map((e) => e.id), ['THEIRS', 'MINE']);
      expect((await repo.exam('THEIRS'))!.items, hasLength(2));
      expect((await db.select(db.exams).get()).every((e) => e.synced), isTrue);

      final again = await sync.run();
      expect([again.examsUploaded, again.examsPulled], [0, 0]);
    });

    test('a server without these endpoints (404) does not fail the sync', () async {
      api.historyUnsupported = true;
      final q = (await repo.bankQuestions('b1')).single;
      await repo.submitExam(exam('E', 1000), [ExamAnswer(question: q, selected: const [1], durationMs: 1)]);
      final r = await sync.run();
      expect([r.attemptsPulled, r.examsPulled, r.examsUploaded], [0, 0, 0]);
      expect((await db.select(db.exams).get()).single.synced, isFalse, reason: 'still queued for when the server can take it');
    });
  });

  test('progress record survives garbage', () {
    expect(ProgressRecord.decode('not json').streak, 0);
    expect(ProgressRecord.decode(null).streak, 0);
    expect(ProgressRecord.decode('{"streak":3}').streak, 3);
  });
}
