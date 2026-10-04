import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_prompt.dart';
import 'models.dart';

/// Thrown when the LLM call fails; [message] is safe to show to the user.
class AiException implements Exception {
  AiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Streams a model's answer as text pieces. An interface so the UI can be tested
/// without a network.
abstract class AiChat {
  /// Emits the answer piece by piece. Cancelling the subscription (or [cancel])
  /// aborts the request.
  Stream<String> stream(AiConfig config, List<ChatMessage> messages, {CancelToken? cancel});
}

/// Calls an OpenAI-compatible `{baseUrl}/chat/completions` with `stream: true`.
class HttpAiChat implements AiChat {
  HttpAiChat({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // For a stream this is the longest silence allowed between two chunks.
              receiveTimeout: const Duration(seconds: 90),
            ));

  final Dio _dio;

  @override
  Stream<String> stream(AiConfig config, List<ChatMessage> messages, {CancelToken? cancel}) async* {
    final Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
        data: {
          'model': config.model,
          'messages': [for (final m in messages) m.toJson()],
          'stream': true,
          'max_tokens': config.maxTokens,
          'temperature': config.temperature,
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Authorization': 'Bearer ${config.apiKey}', 'Accept': 'text/event-stream'},
        ),
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      throw await _translate(e);
    }
    var any = false;
    try {
      await for (final piece in parseSseDeltas(res.data!.stream)) {
        any = true;
        yield piece;
      }
    } on DioException catch (e) {
      throw await _translate(e);
    }
    if (!any) throw AiException('模型没有返回内容，请检查模型名称，或稍后重试');
  }

  Future<AiException> _translate(DioException e) async {
    if (CancelToken.isCancel(e)) return AiException('已取消');
    final status = e.response?.statusCode;
    if (status != null) {
      final detail = await _errorDetail(e.response!.data);
      final hint = switch (status) {
        401 || 403 => 'API Key 无效或没有权限',
        404 => '接口地址或模型名不对（Base URL 一般要带 /v1）',
        429 => '请求太频繁或额度用完了',
        _ when status >= 500 => '模型服务出错了',
        _ => '请求被拒绝',
      };
      return AiException('$hint（$status）${detail.isEmpty ? '' : '：$detail'}');
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError =>
        AiException('连不上模型服务，请检查网络和 Base URL'),
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout => AiException('模型响应超时'),
      _ => AiException('网络错误：${e.message ?? e.type.name}'),
    };
  }

  /// The message of an OpenAI-style error body (`{"error": {"message": …}}`), if there is one.
  Future<String> _errorDetail(Object? data) async {
    try {
      final text = data is ResponseBody ? utf8.decode(await data.stream.expand((c) => c).toList()) : '$data';
      final j = jsonDecode(text);
      final err = j is Map ? j['error'] : null;
      final msg = err is Map ? err['message'] : (err ?? (j is Map ? j['message'] : null));
      final s = '${msg ?? ''}'.trim();
      return s.length > 160 ? '${s.substring(0, 160)}…' : s;
    } catch (_) {
      return '';
    }
  }
}

/// Text pieces of a server-sent-events body from a chat completion: the
/// `choices[0].delta.content` of every `data:` line, until `[DONE]`. Lines that
/// are not JSON, and deltas without text (role markers, reasoning, usage), are skipped.
Stream<String> parseSseDeltas(Stream<List<int>> body) async* {
  await for (final raw in utf8.decoder.bind(body).transform(const LineSplitter())) {
    final line = raw.trim();
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trim();
    if (payload == '[DONE]') return;
    try {
      final j = jsonDecode(payload);
      final choices = j is Map ? j['choices'] : null;
      if (choices is! List || choices.isEmpty) continue;
      final delta = (choices.first as Map)['delta'];
      final text = delta is Map ? delta['content'] : null;
      if (text is String && text.isNotEmpty) yield text;
    } catch (_) {
      continue;
    }
  }
}
