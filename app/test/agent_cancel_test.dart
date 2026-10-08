import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/agent_api.dart';
import 'package:quizmind_app/data/agent_models.dart';

/// Cancelling an answer that is being streamed over a real socket. The fake APIs of the other tests
/// cannot show this: it is Dio that reports the cancellation, from inside the response stream.
void main() {
  const request = AgentChatRequest(
    conversationId: 'c',
    mode: 'learn',
    deviceId: 'd',
    message: 'x',
  );

  Future<HttpServer> serve({required bool hang}) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write('event: delta\ndata: {"text":"a"}\n\n');
      await req.response.flush();
      if (hang) await Future<void>.delayed(const Duration(seconds: 10));
      try {
        await req.response.close();
      } catch (_) {}
    });
    return server;
  }

  setUp(() => HttpOverrides.global = null);

  test('stopping in the middle of an answer ends as "stopped", not as a raw Dio error', () async {
    final server = await serve(hang: true);
    final api = HttpAgentApi(baseUrl: 'http://127.0.0.1:${server.port}', token: 't');
    final cancel = CancelToken();
    final events = <AgentEvent>[];
    Object? error;
    final sw = Stopwatch()..start();
    try {
      await for (final e in api.chat(request, cancel: cancel)) {
        events.add(e);
        Timer(const Duration(milliseconds: 100), cancel.cancel);
      }
    } catch (e) {
      error = e;
    }
    expect(events, hasLength(1));
    expect(error, isA<AgentException>().having((e) => e.message, 'message', '已停止'));
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: 'it did not wait for the server');
  });

  test('a connection that drops mid-answer is an AgentException the page can show', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write('event: delta\ndata: {"text":"a"}\n\n');
      await req.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await server.close(force: true); // drops every open connection
    });
    final api = HttpAgentApi(baseUrl: 'http://127.0.0.1:${server.port}', token: 't');
    Object? error;
    try {
      await for (final _ in api.chat(request)) {}
    } catch (e) {
      error = e;
    }
    expect(error, isA<AgentException>().having((e) => e.message, 'message', contains('网络中断')));
  });
}
