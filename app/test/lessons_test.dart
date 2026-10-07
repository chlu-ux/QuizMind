import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:quizmind_app/features/home/banks_page.dart';
import 'package:quizmind_app/features/quiz/learn_page.dart';
import 'package:quizmind_app/features/quiz/lesson_page.dart';
import 'package:quizmind_app/features/quiz/lessons.dart';

import 'support.dart';

final bank = Bank(id: 'b1', title: '题库', description: '', questionCount: 0);

Lesson lesson(String id, {String path = '', String doc = 'd1', String docTitle = '考点精讲', int order = 1, int seq = 0}) => Lesson(
      id: id,
      bankId: 'b1',
      documentId: doc,
      documentTitle: docTitle,
      documentOrder: order,
      seq: seq,
      headingPath: path.isEmpty ? '考点精讲 > $id' : path,
      body: '正文',
    );

Question question(String id, [String chunk = '']) => Question(
      id: id,
      bankId: 'b1',
      type: 'single',
      stem: id,
      optionsJson: '["a","b","c","d"]',
      answerJson: '[0]',
      explanation: '',
      difficulty: 2,
      tagsJson: '[]',
      sourceQuote: '',
      documentId: '',
      documentTitle: '',
      documentOrder: 0,
      chunkId: chunk,
      syncSeq: 1,
      hidden: false,
    );

int _clock = 0;
Attempt attempt(String questionId, bool correct) => Attempt(
      id: 'a${++_clock}',
      questionId: questionId,
      deviceId: 'd',
      answerJson: '[0]',
      isCorrect: correct,
      answeredAt: _clock,
      synced: true,
    );

LessonDto dto(String id, {String title = '', String text = '正文。'}) => LessonDto(
      id: id,
      bankId: 'b1',
      documentId: 'd1',
      documentTitle: '讲义',
      documentOrder: 1,
      seq: 0,
      headingPath: '讲义 > ${title.isEmpty ? id : title}',
      text: text,
    );

void main() {
  group('titles and chapters', () {
    test('a section is named by the last part of its path', () {
      expect(lessonTitle(lesson('x', path: '考点精讲 > 2.1 操作系统概述')), '2.1 操作系统概述');
      expect(lessonTitle(lesson('x', path: '开头')), '开头');
    });

    test('chapters follow the order the documents were added, sections their position, and names drop the shared lead', () {
      final chapters = groupChapters([
        lesson('b2', doc: 'd2', docTitle: '讲义（二）', order: 20, seq: 1),
        lesson('a2', doc: 'd1', docTitle: '讲义（一）', order: 10, seq: 1),
        lesson('b1', doc: 'd2', docTitle: '讲义（二）', order: 20, seq: 0),
        lesson('a1', doc: 'd1', docTitle: '讲义（一）', order: 10, seq: 0),
      ]);
      expect([for (final c in chapters) '${c.title}: ${[for (final l in c.lessons) l.id].join(',')}'], ['一: a1,a2', '二: b1,b2']);
    });
  });

  group('lessonProgress', () {
    final ls = [lesson('L1'), lesson('L2'), lesson('L3'), lesson('L4')];
    final qs = [
      question('q1', 'L2'),
      question('q2', 'L2'),
      for (var i = 1; i <= 6; i++) question('m$i', 'L3'),
      question('old'), // pulled before questions knew their section
    ];
    LessonProgress? of(String id, List<Attempt> attempts, [Set<String> read = const {}]) =>
        lessonProgress(ls, qs, attempts, read)[id];

    test('is unread until read, then read; questions are counted per section', () {
      final p = lessonProgress(ls, qs, [], {'L1'});
      expect((p['L1']!.state, p['L1']!.total, p['L1']!.accuracy), (LessonState.read, 0, null));
      expect((p['L2']!.state, p['L2']!.total), (LessonState.unread, 2));
      expect((p['L3']!.state, p['L3']!.total), (LessonState.unread, 6));
      expect((p['L4']!.state, p['L4']!.total), (LessonState.unread, 0));
    });

    test('practising makes a section practised, even if it was never opened', () {
      final p = of('L2', [attempt('q1', false)])!;
      expect((p.state, p.answered, p.correct, p.accuracy, p.read), (LessonState.practiced, 1, 0, 0, false));
    });

    test('a short section is mastered once all its questions were answered and 80% are right', () {
      expect(of('L2', [attempt('q1', true)])!.state, LessonState.practiced);
      expect(of('L2', [attempt('q1', true), attempt('q2', true)])!.state, LessonState.mastered);
      expect(of('L2', [attempt('q1', true), attempt('q2', false)])!.state, LessonState.practiced);
    });

    test('a long section needs five answered, and judges each question by its latest attempt', () {
      final four = [for (final q in ['m1', 'm2', 'm3', 'm4']) attempt(q, true)];
      expect(of('L3', four)!.state, LessonState.practiced);
      final five = [...four, attempt('m5', true)];
      expect(of('L3', five)!.state, LessonState.mastered);
      // one wrong out of five is exactly 80%
      expect(of('L3', [...four, attempt('m5', false)])!.state, LessonState.mastered);
      // a wrong answer given later overrides the earlier right one: 3 of 5 now
      final later = of('L3', [...five, attempt('m1', false), attempt('m2', false)])!;
      expect((later.state, later.correct, later.accuracy), (LessonState.practiced, 3, 60));
    });

    test('finds the questions of a section', () {
      expect([for (final q in lessonQuestions('L2', qs)) q.id], ['q1', 'q2']);
    });
  });

  group('nextToStudy', () {
    final ls = [lesson('L1'), lesson('L2'), lesson('L3')];
    final qs = [question('q1', 'L1'), question('q2', 'L3')];

    test('goes to the first section not read yet, though practising it does not make it read', () {
      final p = lessonProgress(ls, qs, [attempt('q1', true)], {});
      expect((p['L1']!.read, p['L1']!.state), (false, LessonState.mastered));
      expect(nextToStudy(ls, p)?.id, 'L1');
      expect(nextToStudy(ls, lessonProgress(ls, qs, [], {'L1'}))?.id, 'L2');
    });

    test('then to the first one not mastered, and to nothing when all are read and mastered', () {
      const read = {'L1', 'L2', 'L3'};
      expect(nextToStudy(ls, lessonProgress(ls, qs, [], read))?.id, 'L1');
      expect(nextToStudy(ls, lessonProgress(ls, qs, [attempt('q1', true)], read))?.id, 'L3'); // L2 has no questions to master
      expect(nextToStudy(ls, lessonProgress(ls, qs, [attempt('q1', true), attempt('q2', true)], read)), isNull);
    });
  });

  group('reading layout', () {
    test('cuts a sentence at 。！？ and keeps a closing bracket or quote with it', () {
      expect(splitSentences('甲是乙（见下文）。丙是丁！戊呢？“好。”己'), ['甲是乙（见下文）。', '丙是丁！', '戊呢？', '“好。”', '己']);
    });

    test('joins hard-wrapped lines without a gap, except between two Latin words', () {
      expect(splitSentences('进程是程序\n的一次执行。'), ['进程是程序的一次执行。']);
      expect(splitSentences('use the\nstack。'), ['use the stack。']);
    });

    test('shows a prose paragraph one sentence at a time and leaves lists, code and pictures alone', () {
      final text = ['甲。乙。', '', '- 项一', '- 项二', '', '```', '代码。第二句。', '', '仍是代码。', '```', '', '一句话。', '', '![图](media:x)。再来一句。'];
      final blocks = lessonBlocks(text.join('\n'));
      expect([for (final b in blocks) b.sentences ?? b.source], [
        ['甲。', '乙。'],
        '- 项一\n- 项二',
        '```\n代码。第二句。\n\n仍是代码。\n```',
        '一句话。',
        '![图](media:x)。再来一句。',
      ]);
    });
  });

  group('sync', () {
    test('downloads the study text and the section each question came from', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final api = FakeApi()
        ..lessonList = [dto('L1', title: '第一节'), dto('L2')]
        ..published.add(QuestionDto.fromJson({
          'id': 'q1', 'bank_id': 'b1', 'type': 'single', 'stem': 's', 'options': ['A', 'B'], 'answer': [0],
          'chunk_id': 'L1', 'sync_seq': 1,
        }));
      final report = await SyncService(db, api, deviceId: 'd').run();
      expect(report.lessonsPulled, 2);
      expect(report.summary, contains('更新了讲义（2 节）'));
      expect({for (final l in await db.select(db.lessons).get()) l.id: l.headingPath}, {'L1': '讲义 > 第一节', 'L2': '讲义 > L2'});
      expect((await db.select(db.questions).getSingle()).chunkId, 'L1');
    });

    test('asks with the version it holds and downloads nothing when it is current', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final api = FakeApi()..lessonList = [dto('L1')];
      final sync = SyncService(db, api, deviceId: 'd');
      expect((await sync.run()).lessonsPulled, 1);
      final again = await sync.run();
      expect(again.lessonsPulled, 0);
      expect(api.lessonVersionsAsked, [0, 1]);
      expect(await db.select(db.lessons).get(), hasLength(1));
    });

    test('a changed library replaces the old one whole, and read marks of sections that are gone stop counting', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final api = FakeApi()..lessonList = [dto('L1'), dto('L2')];
      final sync = SyncService(db, api, deviceId: 'd');
      await sync.run();
      final repo = Repository(db, deviceId: 'd');
      await repo.markLessonRead((await repo.lesson('L1'))!);
      await repo.markLessonRead((await repo.lesson('L2'))!);
      api
        ..lessonList = [dto('L2'), dto('L3')]
        ..lessonsVersion = 2;
      expect((await sync.run()).lessonsPulled, 2);
      expect([for (final l in await repo.lessons('b1')) l.id], ['L2', 'L3']);
      expect(await repo.lessonReadIds('b1'), {'L2'});
    });

    test('a server from before lessons just has none, and the rest of the sync goes on', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final api = FakeApi()
        ..lessonsUnsupported = true
        ..published.add(question2('q1'));
      final report = await SyncService(db, api, deviceId: 'd').run();
      expect(report.lessonsPulled, 0);
      expect(report.questionsUpdated, 1);
    });
  });

  group('repository', () {
    test('summarises sections and reads, marks and unmarks, keeping the first date', () async {
      final db = memoryDb();
      addTearDown(db.close);
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final repo = Repository(db, deviceId: 'd', clock: () => now);
      expect(await repo.lessonSummary('b1'), (total: 0, read: 0));
      await addLesson(db, 'L1', seq: 1);
      await addLesson(db, 'L2', seq: 0);
      await addLesson(db, 'X', bank: 'other');
      expect([for (final l in await repo.lessons('b1')) l.id], ['L2', 'L1']);
      await repo.markLessonRead((await repo.lesson('L1'))!);
      now = DateTime.fromMillisecondsSinceEpoch(5000);
      await repo.markLessonRead((await repo.lesson('L1'))!);
      expect((await db.select(db.lessonReads).getSingle()).readAt, 1000);
      expect(await repo.lessonSummary('b1'), (total: 2, read: 1));
      expect(await repo.lessonSummary('other'), (total: 1, read: 0));
      await repo.unmarkLessonRead('L1');
      expect(await repo.lessonSummary('b1'), (total: 2, read: 0));
    });
  });

  test('upgrading a version-6 database adds the section of a question and the study text tables', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE questions (
          id TEXT NOT NULL PRIMARY KEY, bank_id TEXT NOT NULL, type TEXT NOT NULL, stem TEXT NOT NULL,
          options_json TEXT NOT NULL, answer_json TEXT NOT NULL, explanation TEXT NOT NULL DEFAULT '',
          difficulty INTEGER NOT NULL DEFAULT 3, tags_json TEXT NOT NULL DEFAULT '[]',
          source_quote TEXT NOT NULL DEFAULT '', document_id TEXT NOT NULL DEFAULT '',
          document_title TEXT NOT NULL DEFAULT '', document_order INTEGER NOT NULL DEFAULT 0,
          sync_seq INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0
        )''');
      raw.execute("INSERT INTO questions (id, bank_id, type, stem, options_json, answer_json, sync_seq) VALUES ('q', 'b', 'single', 's', '[]', '[0]', 1)");
      raw.execute('PRAGMA user_version = 6');
    }));
    addTearDown(db.close);
    expect((await db.select(db.questions).getSingle()).chunkId, '');
    expect(await db.select(db.lessons).get(), isEmpty);
    expect(await db.select(db.lessonReads).get(), isEmpty);
  });

  group('pages', () {
    Future<AppDatabase> seeded(WidgetTester tester, {bool withLessons = true}) async {
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '题库');
        if (withLessons) {
          await addLesson(db, 'L1', title: '1.1 进程', body: '进程是程序的一次执行。线程是调度的单位。', seq: 0);
          await addLesson(db, 'L2', title: '1.2 内存', body: '内存分页。', seq: 1);
          await addLesson(db, 'L3', title: '2.1 网络', body: '网络分层。', doc: 'd2', docTitle: '讲义（网络）', docOrder: 2);
        }
        await seedQs(db, n: 2, chunk: (i) => 'L1');
      });
      return db;
    }

    testWidgets('the bank page offers 先学后练 only when the bank has study text, with how much was read', (tester) async {
      var db = await seeded(tester, withLessons: false);
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank)));
      await settleUi(tester);
      expect(find.text('先学后练'), findsNothing);
      await tearDownUi(tester, db);

      db = await seeded(tester);
      await tester.runAsync(() => addLesson(db, 'L1', title: '1.1 进程'));
      await pumpWith(tester, db, Scaffold(body: BankDetail(bank: bank)));
      await settleUi(tester);
      expect(find.text('先学后练'), findsOneWidget);
      expect(find.text('讲义 0 / 3 节已读'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('the catalogue shows progress, opens the chapter holding the next section, and says what is next', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, LearnPage(bank: bank));
      await settleUi(tester);
      expect(find.text('已读 0 / 3 节 · 已掌握 0 节'), findsOneWidget);
      expect(find.text('开始学习 · 1.1 进程'), findsOneWidget);
      // the first chapter is open, the second is not
      expect(find.text('1.1 进程'), findsOneWidget);
      expect(find.text('2 题 · 做过 0'), findsOneWidget);
      expect(find.text('没有配套的题'), findsOneWidget); // 1.2
      expect(find.text('2.1 网络'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chapter-d2')));
      await tester.pump();
      expect(find.text('2.1 网络'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('says so when the bank has no study text', (tester) async {
      final db = await seeded(tester, withLessons: false);
      await pumpWith(tester, db, LearnPage(bank: bank));
      await settleUi(tester);
      expect(find.textContaining('还没有讲义'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('reading a section: sentences on their own lines, cover mode hides them, and 下一节 marks it read', (tester) async {
      final db = await seeded(tester);
      final c = await pumpWith(tester, db, LessonPage(bank: bank, lessonId: 'L1'));
      await settleUi(tester);
      expect(find.text('进程是程序的一次执行。'), findsOneWidget);
      expect(find.text('线程是调度的单位。'), findsOneWidget);
      expect(find.text('学完了，做这一节的 2 道题'), findsOneWidget);
      expect(find.byKey(const ValueKey('sentence-0/0')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cover-toggle')));
      await tester.pump();
      expect(find.text('显示全部'), findsOneWidget);
      expect(find.byKey(const ValueKey('sentence-0/0')), findsOneWidget);
      expect(find.text('点一句话显示它，先自己回忆再看'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('next-lesson')));
      await tester.tap(find.byKey(const ValueKey('next-lesson')));
      await tester.pumpAndSettle();
      await settleUi(tester);
      expect(find.text('内存分页。'), findsOneWidget);
      expect(await c.read(repositoryProvider).lessonReadIds('b1'), {'L1'});
      await tearDownUi(tester, db);
    });

    testWidgets('a section without questions is finished with 学完了; the read mark can be taken back', (tester) async {
      final db = await seeded(tester);
      final c = await pumpWith(tester, db, LessonPage(bank: bank, lessonId: 'L2'));
      await settleUi(tester);
      expect(find.text('学完了，下一节'), findsOneWidget);
      expect(find.text('学完了，做这一节的 2 道题'), findsNothing);
      final toggle = find.byKey(const ValueKey('toggle-read'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await settleUi(tester);
      expect(find.text('✓ 已读（点此取消）'), findsOneWidget);
      expect(await c.read(repositoryProvider).lessonReadIds('b1'), {'L2'});
      await tester.tap(toggle);
      await settleUi(tester);
      expect(await c.read(repositoryProvider).lessonReadIds('b1'), isEmpty);
      await tearDownUi(tester, db);
    });

    testWidgets('a section that is gone says so', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, LessonPage(bank: bank, lessonId: 'nope'));
      await settleUi(tester);
      expect(find.textContaining('这一节不存在'), findsOneWidget);
      await tearDownUi(tester, db);
    });

    testWidgets('学完了 marks the section read and opens a quiz over its questions', (tester) async {
      final db = await seeded(tester);
      final c = await pumpWith(tester, db, LessonPage(bank: bank, lessonId: 'L1'));
      await settleUi(tester);
      final go = find.byKey(const ValueKey('practise-lesson'));
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.pumpAndSettle();
      await settleUi(tester);
      expect(find.text('本节 · 1.1 进程'), findsOneWidget);
      expect(find.textContaining('题干 b1-q'), findsOneWidget);
      expect(await c.read(repositoryProvider).lessonReadIds('b1'), {'L1'});
      await tearDownUi(tester, db);
    });

    testWidgets('after answering, 看这一节讲义 opens the section in a sheet without leaving the quiz', (tester) async {
      final db = await seeded(tester);
      await pumpWith(tester, db, LessonPage(bank: bank, lessonId: 'L1'));
      await settleUi(tester);
      final go = find.byKey(const ValueKey('practise-lesson'));
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.pumpAndSettle();
      await settleUi(tester);
      expect(find.byKey(const ValueKey('open-lesson')), findsNothing, reason: 'not before the answer');
      await tester.tap(find.text('丙').first);
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      await settleUi(tester);
      final open = find.byKey(const ValueKey('open-lesson'));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lesson-sheet')), findsOneWidget);
      expect(find.text('线程是调度的单位。'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lesson-sheet')), findsNothing);
      expect(find.text('本节 · 1.1 进程'), findsOneWidget, reason: 'still in the quiz');
      await tearDownUi(tester, db);
    });
  });
}

QuestionDto question2(String id) => QuestionDto(
      id: id,
      bankId: 'b1',
      type: 'single',
      stem: 's',
      options: const ['A', 'B'],
      answer: const [0],
      explanation: '',
      difficulty: 2,
      tags: const [],
      sourceQuote: '',
      syncSeq: 1,
    );
