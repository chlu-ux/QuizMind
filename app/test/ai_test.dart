import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/data/ai_chat.dart';
import 'package:quizmind_app/data/ai_config_store.dart';
import 'package:quizmind_app/data/ai_prompt.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/media_store.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/repository.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:quizmind_app/features/quiz/ai_explain_card.dart';
import 'package:quizmind_app/features/quiz/quiz_media.dart';
import 'package:quizmind_app/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const cfg = AiConfig(baseUrl: 'https://llm.example/v1', apiKey: 'sk-test', model: 'm1');

Stream<Uint8List> sse(List<String> chunks) => Stream.fromIterable([for (final c in chunks) Uint8List.fromList(utf8.encode(c))]);

String delta(String text) => 'data: ${jsonEncode({
      'choices': [
        {'delta': {'content': text}}
      ]
    })}\n\n';

/// A Dio adapter that answers every request with [respond] and records the request.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    last = options;
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

Future<Question> storedQuestion(AppDatabase db, {String id = 'q1', String? stem}) async {
  await db.into(db.questions).insert(QuestionsCompanion.insert(
        id: id,
        bankId: 'b1',
        type: 'single',
        stem: stem ?? '题干 $id',
        optionsJson: '["甲","乙","丙","丁"]',
        answerJson: '[1]',
        explanation: const Value('解析'),
        sourceQuote: const Value('原文'),
        syncSeq: 1,
      ));
  return (db.select(db.questions)..where((q) => q.id.equals(id))).getSingle();
}

/// Replays canned pieces and records what it was asked.
class FakeChat implements AiChat {
  FakeChat(this.pieces, {this.error, this.gate, this.refuseImages = false});

  final List<String> pieces;
  final AiException? error;

  /// When set, the stream waits for it before the last piece, to test stopping mid-way.
  final Completer<void>? gate;
  /// Answers 400 to a request that carries pictures, like a model that cannot look at images.
  final bool refuseImages;
  int calls = 0;
  AiConfig? lastConfig;
  List<ChatMessage>? lastMessages;
  final allMessages = <List<ChatMessage>>[];

  @override
  Stream<String> stream(AiConfig config, List<ChatMessage> messages, {CancelToken? cancel}) async* {
    calls++;
    lastConfig = config;
    lastMessages = messages;
    allMessages.add(messages);
    if (refuseImages && messages.any((m) => m.images.isNotEmpty)) throw AiException('请求被拒绝（400）', status: 400);
    for (var i = 0; i < pieces.length; i++) {
      if (gate != null && i == pieces.length - 1) await gate!.future;
      yield pieces[i];
    }
    if (error != null) throw error!;
  }
}

void main() {
  group('parseSseDeltas', () {
    test('joins the content of every data line, whatever the chunking, and stops at [DONE]', () async {
      final body = '${delta('你')}${delta('好')}data: [DONE]\n\n${delta('不该出现')}';
      // Split in awkward places, including inside a multi-byte character.
      final bytes = utf8.encode(body);
      final chunks = [bytes.sublist(0, 20), bytes.sublist(20, 71), bytes.sublist(71)];
      expect((await parseSseDeltas(Stream.fromIterable(chunks)).toList()).join(), '你好');
    });

    test('skips role markers, empty deltas, comments and non-JSON lines', () async {
      final body = ': keep-alive\n'
          'data: {"choices":[{"delta":{"role":"assistant"}}]}\n'
          'data: {"choices":[{"delta":{"content":""}}]}\n'
          'data: {"choices":[]}\n'
          'data: not json\n'
          'data: {"choices":[{"delta":{"reasoning_content":"想一想"}}]}\n'
          '${delta('答案')}';
      expect(await parseSseDeltas(sse([body])).toList(), ['答案']);
    });
  });

  group('HttpAiChat', () {
    test('posts to {base}/chat/completions with the key and streams the pieces', () async {
      final adapter = StubAdapter((_) => ResponseBody(sse([delta('甲'), delta('乙'), 'data: [DONE]\n\n']), 200,
          headers: {Headers.contentTypeHeader: ['text/event-stream']}));
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      final out = await chat
          .stream(const AiConfig(baseUrl: 'https://llm.example/v1/', apiKey: 'sk-test', model: 'm1', maxTokens: 99),
              const [ChatMessage('user', 'hi')])
          .toList();
      expect(out.join(), '甲乙');
      final req = adapter.last!;
      expect(req.uri.toString(), 'https://llm.example/v1/chat/completions');
      expect(req.headers['Authorization'], 'Bearer sk-test');
      expect(req.data, containsPair('stream', true));
      expect(req.data, containsPair('model', 'm1'));
      expect(req.data, containsPair('max_tokens', 99));
    });

    Future<String> failure(int status, [String body = '']) async {
      final adapter = StubAdapter((_) => ResponseBody.fromString(body, status));
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      try {
        await chat.stream(cfg, const [ChatMessage('user', 'x')]).toList();
      } on AiException catch (e) {
        return e.message;
      }
      fail('expected an AiException');
    }

    test('turns HTTP errors into readable messages, with the provider detail', () async {
      expect(await failure(401, '{"error":{"message":"Incorrect API key"}}'), allOf(contains('API Key'), contains('Incorrect API key')));
      expect(await failure(404), contains('Base URL'));
      expect(await failure(429), contains('额度'));
      expect(await failure(500, 'oops'), contains('500'));
    });

    test('an empty stream is an error, not a blank explanation', () async {
      final adapter = StubAdapter((_) => ResponseBody(sse(['data: [DONE]\n\n']), 200));
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      expect(chat.stream(cfg, const [ChatMessage('user', 'x')]).toList(), throwsA(isA<AiException>()));
    });
  });

  group('buildExplainMessages', () {
    test('lists options without letters, marks the standard answer and the learner\'s pick', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final q = await storedQuestion(db);
      final wrong = buildExplainMessages(q, [2]);
      expect(wrong.first.role, 'system');
      final user = wrong.last.content;
      expect(user, contains('题干 q1'));
      expect(user, contains('- 甲\n- 乙\n- 丙\n- 丁'));
      expect(user, contains('标准答案：乙'));
      expect(user, contains('学员所选：丙（答错了）'));
      expect(user, contains('解析'));
      expect(user, contains('原文'));
      expect(buildExplainMessages(q, [1]).last.content, contains('学员所选：乙（答对了）'));
      expect(buildExplainMessages(q, const []).last.content, isNot(contains('学员所选')));
    });

    test('numbers the pictures of a question and attaches them for a model that can look', () async {
      final db = memoryDb();
      addTearDown(db.close);
      const id = '0123456789abcdef01234567';
      final q = await storedQuestion(db, stem: '如图所示的类图，哪项正确？\n\n![类图](media:$id)');

      final withImage = buildExplainMessages(q, const [], images: {id: 'data:image/png;base64,AAAA'}).last;
      expect(withImage.content, contains('如图所示的类图，哪项正确？\n\n[图1]'));
      expect(withImage.content, contains('题目含 1 张图片'));
      expect(withImage.content, isNot(contains('media:')), reason: 'the reference itself means nothing to a model');
      expect(withImage.images, ['data:image/png;base64,AAAA']);
      expect(withImage.toJson()['content'], [
        {'type': 'text', 'text': withImage.content},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AAAA'},
        },
      ]);

      final without = buildExplainMessages(q, const []).last;
      expect(without.content, contains('图片内容没有提供给你'));
      expect(without.images, isEmpty);
      expect(without.toJson(), {'role': 'user', 'content': without.content}, reason: 'plain text for a plain request');
    });
  });

  group('AiConfigStore', () {
    test('keeps token, synced and manual configurations apart and survives garbage', () async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({'ai.manual': 'not json'});
      final store = AiConfigStore(await SharedPreferences.getInstance());
      expect(store.manual, isNull);
      expect(store.synced, isNull);
      await store.setToken('  abcd ');
      await store.setSynced(cfg);
      expect(store.token, 'abcd');
      expect(store.synced!.model, 'm1');
      await store.setSynced(null);
      await store.setToken('');
      expect(store.synced, isNull);
      expect(store.token, '');
    });
  });

  group('sync', () {
    late FakeApi api;
    late AppDatabase db;
    late AiConfigStore store;

    Future<SyncService> service({String token = 'tok'}) async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      store = AiConfigStore(await SharedPreferences.getInstance());
      await store.setToken(token);
      return SyncService(db, api, aiConfig: store, deviceId: 'dev');
    }

    setUp(() {
      api = FakeApi();
      db = memoryDb();
      addTearDown(db.close);
    });

    test('uploads dirty explanations once and clears the flag', () async {
      final repo = Repository(db, deviceId: 'dev');
      await storedQuestion(db);
      await repo.saveNote(questionId: 'q1', content: '讲解', model: 'm1', selected: [2], promptVersion: 'explain.v1');
      final svc = await service();

      final report = await svc.run();
      expect(report.notesUploaded, 1);
      final up = api.uploadedNotes.single;
      expect([up.questionId, up.content, up.model, up.deviceId], ['q1', '讲解', 'm1', 'dev']);
      expect(up.selected, [2]);
      expect((await db.select(db.aiNotes).getSingle()).dirty, isFalse);

      expect((await svc.run()).notesUploaded, 0, reason: 'nothing left in the outbox');
    });

    test('a regenerated explanation replaces the old one and goes up again', () async {
      final repo = Repository(db, deviceId: 'dev');
      await storedQuestion(db);
      await repo.saveNote(questionId: 'q1', content: '第一版', model: 'm1', selected: []);
      final svc = await service();
      await svc.run();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.saveNote(questionId: 'q1', content: '第二版', model: 'm1', selected: []);

      await svc.run();
      expect(api.uploadedNotes.map((n) => n.content), ['第一版', '第二版']);
      expect((await db.select(db.aiNotes).get()).single.content, '第二版');
    });

    test('pulls explanations from the server, last writer wins', () async {
      final repo = Repository(db, deviceId: 'dev');
      await storedQuestion(db, id: 'q1');
      await storedQuestion(db, id: 'q2');
      await repo.saveNote(questionId: 'q2', content: '本机新的', model: 'm', selected: []);
      final localAt = (await db.select(db.aiNotes).getSingle()).updatedAt;
      api.remoteNotes
        ..add(NoteDto(questionId: 'q1', content: '别处写的', updatedAt: 5, model: 'x', selected: [3]))
        ..add(NoteDto(questionId: 'q2', content: '别处旧的', updatedAt: localAt - 1000));
      final svc = await service();

      final report = await svc.run();
      expect(report.notesPulled, 1);
      final rows = {for (final n in await db.select(db.aiNotes).get()) n.questionId: n};
      expect(rows['q1']!.content, '别处写的');
      expect(rows['q1']!.dirty, isFalse, reason: 'taken from the server, nothing to send back');
      expect(rows['q1']!.selectedJson, '[3]');
      expect(rows['q2']!.content, '本机新的');
    });

    test('a server without the notes endpoint does not fail the sync', () async {
      api.notesUnsupported = true;
      await Repository(db, deviceId: 'dev').saveNote(questionId: 'q1', content: 'x', model: '', selected: []);
      final report = await (await service()).run();
      expect(report.notesUploaded, 0);
      expect((await db.select(db.aiNotes).getSingle()).dirty, isTrue, reason: 'still queued for a server that can take it');
    });

    test('fetches the LLM configuration with the token and keeps it', () async {
      api.aiConfigOnServer = cfg;
      final svc = await service();
      final report = await svc.run();
      expect(api.aiTokensSeen, ['tok']);
      expect(report.aiConfigUpdated, isTrue);
      expect(report.summary, contains('AI 配置'));
      expect(store.synced!.apiKey, 'sk-test');

      expect((await svc.run()).aiConfigUpdated, isFalse, reason: 'unchanged');
    });

    test('no token: the configuration is not asked for; wrong token: warned, old copy kept', () async {
      api.aiConfigOnServer = cfg;
      var svc = await service(token: '');
      await svc.run();
      expect(api.aiTokensSeen, isEmpty);
      expect(store.synced, isNull);

      svc = await service(token: 'bad');
      await store.setSynced(cfg);
      final report = await svc.run();
      expect(report.aiWarning, contains('令牌'));
      expect(report.summary, contains('令牌'));
      expect(store.synced, isNotNull, reason: 'a wrong token must not wipe a working configuration');
    });

    test('the server switching AI off withdraws the local copy', () async {
      api.aiConfigOnServer = null;
      final svc = await service();
      await store.setSynced(cfg);
      await svc.run();
      expect(store.synced, isNull);
    });

    test('a network failure while fetching keeps the sync result and the old configuration', () async {
      api.aiConfigOnServer = cfg;
      final svc = await service();
      await store.setSynced(cfg);
      // banks() fails first when the server is unreachable, so the whole sync reports it.
      api.failWith = ApiException('连不上服务器');
      await expectLater(svc.run(), throwsA(isA<ApiException>()));
      expect(store.synced, isNotNull);
    });
  });

  group('AiExplainCard', () {
    // Drift runs on real async, which a widget test's fake clock does not drive:
    // database work goes through runAsync, and settle() lets it finish.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    late AppDatabase db;

    Future<FakeChat> pump(
      WidgetTester tester,
      FakeChat chat, {
      Map<String, Object> prefs = const {},
      String? stem,
      List<Override> overrides = const [],
    }) async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      db = AppDatabase(NativeDatabase.memory());
      final q = await tester.runAsync(() => storedQuestion(db, stem: stem)) as Question;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sp),
          databaseProvider.overrideWithValue(db),
          aiChatProvider.overrideWithValue(chat),
          ...overrides,
        ],
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AiExplainCard(key: ValueKey(q.id), question: q, selected: const [2]))),
        ),
      ));
      await settle(tester);
      return chat;
    }

    Future<List<AiNote>> notes(WidgetTester tester) async =>
        await tester.runAsync(() => db.select(db.aiNotes).get()) as List<AiNote>;

    Future<void> teardown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.runAsync(db.close);
    }

    final withConfig = {'ai.synced': jsonEncode(cfg.toJson())};

    testWidgets('asks, shows the streamed answer, saves it and offers to regenerate', (tester) async {
      final chat = await pump(tester, FakeChat(['## 结论\n', '选乙。']), prefs: withConfig);

      expect(find.text('让 AI 讲解这道题'), findsOneWidget);
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      await settle(tester);

      expect(chat.calls, 1);
      expect(chat.lastConfig!.model, 'm1');
      expect(chat.lastMessages!.last.content, contains('学员所选：丙'));
      expect(find.textContaining('选乙。'), findsOneWidget);
      expect(find.text('重新解读'), findsOneWidget);
      final saved = (await notes(tester)).single;
      expect(saved.content, '## 结论\n选乙。');
      expect([saved.model, saved.promptVersion, saved.selectedJson], ['m1', aiPromptVersion, '[2]']);
      expect(saved.dirty, isTrue, reason: 'queued for upload');
      await teardown(tester);
    });

    group('a question with a picture', () {
      const id = '0123456789abcdef01234567';
      late Directory dir;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('ai_media');
        Directory('${dir.path}/media').createSync();
        File('${dir.path}/media/$id').writeAsBytesSync(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
      });
      tearDown(() => dir.deleteSync(recursive: true));

      Override store() => mediaStoreProvider.overrideWithValue(MediaStore(baseUrl: '', directory: () async => dir));

      testWidgets('is sent to the model together with its pictures', (tester) async {
        final chat = await pump(tester, FakeChat(['看图讲解']),
            prefs: withConfig, stem: '看图\n\n![](media:$id)', overrides: [store()]);
        await tester.tap(find.text('让 AI 讲解这道题'));
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
        }

        expect(chat.calls, 1);
        final user = chat.lastMessages!.last;
        expect(user.images, hasLength(1));
        expect(user.images.single, startsWith('data:image/png;base64,'));
        expect(user.content, contains('[图1]'));
        expect(find.textContaining('看图讲解'), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('is asked again as text when the model cannot take images', (tester) async {
        final chat = await pump(tester, FakeChat(['只看文字的讲解'], refuseImages: true),
            prefs: withConfig, stem: '看图\n\n![](media:$id)', overrides: [store()]);
        await tester.tap(find.text('让 AI 讲解这道题'));
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
        }

        expect(chat.calls, 2, reason: 'once with the picture, refused, once without');
        expect(chat.allMessages.first.last.images, isNotEmpty);
        expect(chat.allMessages.last.last.images, isEmpty);
        expect(chat.allMessages.last.last.content, contains('图片内容没有提供给你'));
        expect(find.textContaining('只看文字的讲解'), findsOneWidget);
        expect(find.text('当前模型不支持看图，这次只依据文字讲解'), findsOneWidget);
        expect((await notes(tester)).single.content, '只看文字的讲解');
        await teardown(tester);
      });
    });

    testWidgets('draws a diagram the model wrote as an svg block, and shows code while it is unfinished', (tester) async {
      const svg = '<svg viewBox="0 0 100 50"><rect width="100" height="50" fill="#fff"/><text x="10" y="30">开始</text></svg>';
      final gate = Completer<void>();
      final chat = await pump(tester, FakeChat(['流程如下：\n```svg\n', svg, '\n```\n', '这就是全部。'], gate: gate), prefs: withConfig);
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      await settle(tester);
      // Everything but the last piece has arrived and the block is closed: it is drawn.
      expect(find.byType(SvgFigure), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.textContaining('<svg'), findsNothing);
      gate.complete();
      await settle(tester);
      expect(find.textContaining('这就是全部。'), findsOneWidget);
      expect(chat.calls, 1);
      await teardown(tester);
    });

    testWidgets('a saved explanation is shown without any request or configuration', (tester) async {
      final chat = await pump(tester, FakeChat(['新的讲解'])); // no AI configuration at all
      await tester.runAsync(() => db
          .into(db.aiNotes)
          .insert(AiNotesCompanion.insert(questionId: 'q1', content: '旧的讲解', model: const Value('m0'), updatedAt: 1)));
      await settle(tester);

      expect(find.textContaining('旧的讲解'), findsOneWidget);
      expect(find.textContaining('m0'), findsOneWidget);
      expect(chat.calls, 0);
      await teardown(tester);
    });

    testWidgets('regenerating replaces the saved text', (tester) async {
      await pump(tester, FakeChat(['新的讲解']), prefs: withConfig);
      await tester.runAsync(() =>
          db.into(db.aiNotes).insert(AiNotesCompanion.insert(questionId: 'q1', content: '旧的讲解', updatedAt: 1)));
      await settle(tester);

      await tester.tap(find.text('重新解读'));
      await tester.pump();
      await settle(tester);
      expect(find.textContaining('新的讲解'), findsOneWidget);
      expect(find.textContaining('旧的讲解'), findsNothing);
      expect((await notes(tester)).single.content, '新的讲解');
      await teardown(tester);
    });

    testWidgets('without a configuration it points to the settings instead of failing', (tester) async {
      final chat = await pump(tester, FakeChat(['x']));
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      expect(find.textContaining('还没有 AI 配置'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      expect(chat.calls, 0);
      await teardown(tester);
    });

    testWidgets('a failing request shows the reason, saves nothing and can be retried', (tester) async {
      await pump(tester, FakeChat(['半截'], error: AiException('API Key 无效或没有权限（401）')), prefs: withConfig);
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      await settle(tester);

      expect(find.textContaining('API Key 无效'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(await notes(tester), isEmpty, reason: 'a partial answer is not saved');
      await teardown(tester);
    });

    testWidgets('stopping midway discards the partial answer', (tester) async {
      final gate = Completer<void>();
      await pump(tester, FakeChat(['写到一半', '没写完'], gate: gate), prefs: withConfig);
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.textContaining('写到一半'), findsOneWidget);

      await tester.tap(find.text('停止'));
      await tester.pump();
      gate.complete();
      await tester.pump();
      await settle(tester);

      expect(find.textContaining('写到一半'), findsNothing);
      expect(find.text('让 AI 讲解这道题'), findsOneWidget);
      expect(await notes(tester), isEmpty);
      await teardown(tester);
    });

    testWidgets('a hand-typed configuration wins over the synced one', (tester) async {
      final chat = await pump(tester, FakeChat(['好']), prefs: {
        ...withConfig,
        'ai.manual': jsonEncode(const AiConfig(baseUrl: 'http://local/v1', apiKey: 'k', model: 'mine').toJson()),
      });
      await tester.tap(find.text('让 AI 讲解这道题'));
      await tester.pump();
      await settle(tester);
      expect(chat.lastConfig!.model, 'mine');
      await teardown(tester);
    });
  });

  group('AiSettingsSection', () {
    testWidgets('saves the token, saves and clears a hand-typed configuration', (tester) async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({'ai.synced': jsonEncode(cfg.toJson())});
      final sp = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(sp)],
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AiSettingsSection()))),
      ));
      expect(find.textContaining('服务器同步的配置（m1）'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '访问令牌'), ' abcd ');
      await tester.tap(find.text('保存令牌并同步'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(AiConfigStore(sp).token, 'abcd');
      expect(find.textContaining('填好服务器地址'), findsOneWidget, reason: 'no server address yet, so nothing to sync with');

      await tester.tap(find.text('本机自定义配置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Base URL'), 'http://local/v1/');
      await tester.tap(find.text('保存').first);
      await tester.pump(); // the old message leaves, then the new one comes in
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('都要填'), findsOneWidget, reason: 'incomplete configurations are not saved');
      expect(AiConfigStore(sp).manual, isNull);

      await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'k');
      await tester.enterText(find.widgetWithText(TextField, '模型'), 'mine');
      await tester.tap(find.text('保存').first);
      await tester.pumpAndSettle();
      final manual = AiConfigStore(sp).manual!;
      expect((manual.baseUrl, manual.apiKey, manual.model), ('http://local/v1', 'k', 'mine'));
      expect(find.textContaining('本机配置（mine）'), findsOneWidget);

      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(AiConfigStore(sp).manual, isNull);
      expect(find.textContaining('服务器同步的配置（m1）'), findsOneWidget, reason: 'falls back to the synced one');
    });
  });
}
