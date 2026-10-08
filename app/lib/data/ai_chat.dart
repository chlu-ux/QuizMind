import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_prompt.dart';
import 'models.dart';

/// Thrown when the LLM call fails; [message] is safe to show to the user.
class AiException implements Exception {
  AiException(this.message, {this.status});

  final String message;

  /// The HTTP status of the model service's answer, if it gave one.
  final int? status;

  @override
  String toString() => message;
}

/// The token counts a chat completion reported about itself.
class AiTokenUsage {
  const AiTokenUsage({required this.inputTokens, required this.outputTokens, this.cachedTokens = 0});

  /// Prompt tokens that were not served from the provider's cache.
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  /// Reads an OpenAI-style `usage` object (also DeepSeek's `prompt_cache_hit_tokens`). Null when it
  /// carries no counts, which is how some endpoints fill the field on every chunk but the last.
  static AiTokenUsage? fromJson(Map<dynamic, dynamic> j) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    final prompt = n(j['prompt_tokens']);
    final output = n(j['completion_tokens']);
    final details = j['prompt_tokens_details'];
    final cached = details is Map && details['cached_tokens'] is num ? n(details['cached_tokens']) : n(j['prompt_cache_hit_tokens']);
    if (prompt + output <= 0) return null;
    return AiTokenUsage(inputTokens: (prompt - cached).clamp(0, prompt), outputTokens: output, cachedTokens: cached);
  }
}

/// Streams a model's answer as text pieces. An interface so the UI can be tested
/// without a network.
abstract class AiChat {
  /// Emits the answer piece by piece. Cancelling the subscription (or [cancel])
  /// aborts the request. [onUsage] is told the token counts if the endpoint reports them, usually
  /// just before the last piece; the last report is the one that counts.
  Stream<String> stream(
    AiConfig config,
    List<ChatMessage> messages, {
    CancelToken? cancel,
    void Function(AiTokenUsage usage)? onUsage,
  });
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

  /// Endpoints that refused `stream_options` (which asks for the token counts); not asked again.
  final _noUsageOption = <String>{};

  @override
  Stream<String> stream(
    AiConfig config,
    List<ChatMessage> messages, {
    CancelToken? cancel,
    void Function(AiTokenUsage usage)? onUsage,
  }) async* {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    var askForUsage = !_noUsageOption.contains(base);
    var droppedOption = false;
    Response<ResponseBody>? opened;
    while (true) {
      try {
        opened = await _dio.post<ResponseBody>(
          '$base/chat/completions',
          data: {
            'model': config.model,
            'messages': [for (final m in messages) m.toJson()],
            'stream': true,
            'max_tokens': config.maxTokens,
            'temperature': config.temperature,
            if (askForUsage) 'stream_options': {'include_usage': true},
          },
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Authorization': 'Bearer ${config.apiKey}', 'Accept': 'text/event-stream'},
          ),
          cancelToken: cancel,
        );
        break;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // A 400 / 422 may be this endpoint not knowing stream_options: ask once more without it. If that
        // is not the reason, the second answer is the real error.
        if (askForUsage && (status == 400 || status == 422)) {
          askForUsage = false;
          droppedOption = true;
          continue;
        }
        throw await _translate(e);
      }
    }
    final res = opened;
    if (droppedOption) _noUsageOption.add(base);
    var any = false;
    try {
      await for (final piece in parseSseDeltas(res.data!.stream, onUsage: onUsage)) {
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
      return AiException('$hint（$status）${detail.isEmpty ? '' : '：$detail'}', status: status);
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
/// are not JSON, and deltas without text (role markers, reasoning), are skipped. A `usage` object, which
/// comes in a chunk of its own or with the last delta, goes to [onUsage].
Stream<String> parseSseDeltas(Stream<List<int>> body, {void Function(AiTokenUsage usage)? onUsage}) async* {
  await for (final raw in utf8.decoder.bind(body).transform(const LineSplitter())) {
    final line = raw.trim();
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trim();
    if (payload == '[DONE]') return;
    try {
      final j = jsonDecode(payload);
      final usage = j is Map ? j['usage'] : null;
      if (usage is Map && onUsage != null) {
        final counted = AiTokenUsage.fromJson(usage);
        if (counted != null) onUsage(counted);
      }
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
