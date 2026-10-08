import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/ai_chat.dart';
import 'package:quizmind_app/data/ai_config_store.dart';
import 'package:quizmind_app/data/ai_prompt.dart';
import 'package:quizmind_app/data/ai_usage.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_test.dart' show StubAdapter, cfg, delta, sse;
import 'support.dart';

AiUsage usage(String id, {int out = 10}) =>
    AiUsage(id: id, model: 'm1', createdAt: 1000, inputTokens: 5, outputTokens: out, questionId: 'q1', deviceId: 'dev');

String usageChunk(Map<String, Object?> u) => 'data: ${jsonEncode({'choices': [], 'usage': u})}\n\n';

ResponseBody okBody(List<String> chunks) =>
    ResponseBody(sse(chunks), 200, headers: {Headers.contentTypeHeader: ['text/event-stream']});

ResponseBody errBody(int status, String message) => ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode({'error': {'message': message}})))),
      status,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );

void main() {
  group('token counts in the stream', () {
    test('are read from the usage chunk, with the cached part taken out of the input', () async {
      final seen = <AiTokenUsage>[];
      final body = '${delta('答')}${usageChunk({'prompt_tokens': 1000, 'completion_tokens': 80, 'prompt_tokens_details': {'cached_tokens': 400}})}data: [DONE]\n\n';
      expect(await parseSseDeltas(sse([body]), onUsage: seen.add).toList(), ['答']);
      expect([seen.single.inputTokens, seen.single.outputTokens, seen.single.cachedTokens], [600, 80, 400]);
    });

    test('also understand the cache field DeepSeek uses, and ignore empty usage objects', () async {
      final seen = <AiTokenUsage>[];
      final body = 'data: ${jsonEncode({'choices': [{'delta': {'content': 'x'}}], 'usage': null})}\n\n'
          '${usageChunk({'prompt_tokens': 0, 'completion_tokens': 0})}'
          '${usageChunk({'prompt_tokens': 50, 'completion_tokens': 7, 'prompt_cache_hit_tokens': 20})}';
      await parseSseDeltas(sse([body]), onUsage: seen.add).toList();
      expect([seen.single.inputTokens, seen.single.outputTokens, seen.single.cachedTokens], [30, 7, 20]);
    });
  });

  group('HttpAiChat asks for the counts', () {
    test('sends stream_options and passes the counts on', () async {
      final adapter = StubAdapter((_) => okBody([delta('好'), usageChunk({'prompt_tokens': 9, 'completion_tokens': 3}), 'data: [DONE]\n\n']));
      final seen = <AiTokenUsage>[];
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      await chat.stream(cfg, const [ChatMessage('user', 'hi')], onUsage: seen.add).toList();
      expect(adapter.last!.data['stream_options'], {'include_usage': true});
      expect(seen.single.outputTokens, 3);
    });

    test('asks again without stream_options when the endpoint rejects it, and remembers', () async {
      var requests = 0;
      final adapter = StubAdapter((o) {
        requests++;
        if ((o.data as Map).containsKey('stream_options')) return errBody(400, 'unknown parameter: stream_options');
        return okBody([delta('好'), 'data: [DONE]\n\n']);
      });
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      expect(await chat.stream(cfg, const [ChatMessage('user', 'hi')]).toList(), ['好']);
      expect(requests, 2);
      expect(await chat.stream(cfg, const [ChatMessage('user', 'hi')]).toList(), ['好']);
      expect(requests, 3, reason: 'the second question goes straight to the form the endpoint accepts');
      expect((adapter.last!.data as Map).containsKey('stream_options'), isFalse);
    });

    test('a real error is not mistaken for that: the second answer is the one reported', () async {
      final adapter = StubAdapter((_) => errBody(401, 'bad key'));
      final chat = HttpAiChat(dio: Dio()..httpClientAdapter = adapter);
      await expectLater(chat.stream(cfg, const [ChatMessage('user', 'hi')]).toList(),
          throwsA(isA<AiException>().having((e) => e.status, 'status', 401)));
    });
  });

  test('estimateTokens counts Chinese heavier than English and is zero for nothing', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('你好世界你好世界你好'), greaterThan(estimateTokens('hello wor')));
    expect(estimateTokens('a' * 400), inInclusiveRange(80, 160));
  });

  group('AiUsageStore', () {
    late SharedPreferences prefs;
    late AiUsageStore store;
    setUp(() async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = AiUsageStore(prefs);
    });

    test('keeps reports in order until they are removed', () async {
      await store.add(usage('a'));
      await store.add(usage('b'));
      expect(store.pending().map((u) => u.id), ['a', 'b']);
      expect(store.pending().first.questionId, 'q1');
      await store.remove(['a']);
      expect(store.pending().map((u) => u.id), ['b']);
      await store.remove(['b']);
      expect(prefs.getString('ai.usage'), isNull);
    });

    test('is bounded: the oldest reports go first', () async {
      for (var i = 0; i < AiUsageStore.maxQueued + 5; i++) {
        await store.add(usage('u$i'));
      }
      final ids = store.pending().map((u) => u.id).toList();
      expect(ids, hasLength(AiUsageStore.maxQueued));
      expect(ids.first, 'u5');
    });

    test('an unreadable queue is empty rather than an error', () async {
      await prefs.setString('ai.usage', 'not json');
      expect(store.pending(), isEmpty);
    });
  });

  group('AiUsageReporter', () {
    late AiConfigStore config;
    late AiUsageStore store;
    late AiUsageReporter reporter;
    late FakeApi api;

    Future<void> setUpWith({String token = 'tok'}) async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      config = AiConfigStore(prefs);
      await config.setToken(token);
      store = AiUsageStore(prefs);
      reporter = AiUsageReporter(store, config);
      api = FakeApi();
    }

    test('without a token there is nowhere to report to, so nothing is kept', () async {
      await setUpWith(token: '');
      await reporter.record(usage('a'));
      expect(store.pending(), isEmpty);
      expect(await reporter.flush(api), 0);
    });

    test('sends the queue in batches of 100 and empties it', () async {
      await setUpWith();
      for (var i = 0; i < 230; i++) {
        await reporter.record(usage('u$i'));
      }
      expect(await reporter.flush(api), 230);
      expect(api.usageBatches.map((b) => b.length), [100, 100, 30]);
      expect(store.pending(), isEmpty);
    });

    test('keeps the reports when the server cannot take them now', () async {
      await setUpWith();
      await reporter.record(usage('a'));
      for (final status in [401, 404, 503]) {
        api.usageStatus = status;
        expect(await reporter.flush(api), 0, reason: '$status');
        expect(store.pending().map((u) => u.id), ['a'], reason: '$status');
      }
      api.usageStatus = null;
      expect(await reporter.flush(api), 1);
      expect(store.pending(), isEmpty);
    });

    test('drops reports the server refuses as invalid, instead of retrying forever', () async {
      await setUpWith();
      await reporter.record(usage('a'));
      api.usageStatus = 400;
      await reporter.flush(api);
      expect(store.pending(), isEmpty);
    });

    test('never throws, even when the connection is down', () async {
      await setUpWith();
      await reporter.record(usage('a'));
      api.failWith = ApiException('连不上服务器');
      expect(await reporter.flush(api), 0);
      expect(store.pending(), hasLength(1));
    });
  });

  test('a sync sends the queued reports', () async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = AiConfigStore(prefs);
    await config.setToken('tok');
    final reporter = AiUsageReporter(AiUsageStore(prefs), config);
    await reporter.record(usage('a'));
    await reporter.record(usage('b'));
    final api = FakeApi();
    final db = memoryDb();
    addTearDown(db.close);

    final report = await SyncService(db, api, aiConfig: config, aiUsage: reporter, deviceId: 'dev').run();
    expect(report.aiUsageUploaded, 2);
    expect(api.uploadedUsage.map((u) => u.id), ['a', 'b']);
    expect(report.summary, '已是最新', reason: 'routine reporting is not worth a line');

    // A server that cannot take the reports does not fail the sync; they wait.
    await reporter.record(usage('c'));
    api.usageStatus = 404;
    final again = await SyncService(db, api, aiConfig: config, aiUsage: reporter, deviceId: 'dev').run();
    expect(again.aiUsageUploaded, 0);
    expect(AiUsageStore(prefs).pending().map((u) => u.id), ['c']);
  });
}
