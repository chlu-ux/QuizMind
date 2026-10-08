import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'agent_models.dart';

/// The study assistant on the server. An interface so the UI can be tested without a network.
abstract class AgentApi {
  /// Whether the assistant can be used. 401: no or wrong access token; 404: the server has no model
  /// bound to the assistant (or predates it).
  Future<AgentStatus> status();

  /// Streams the answer. Cancelling [cancel] (or the subscription) stops the model on the server.
  /// Failures before the answer starts throw an [AgentException] with the HTTP status; later ones
  /// arrive as an [AgentErrorEvent].
  Stream<AgentEvent> chat(AgentChatRequest request, {CancelToken? cancel});

  /// The conversation's drafts that still wait for a decision.
  Future<List<AgentDraft>> drafts(String conversationId);

  /// Sends a draft to the review queue (it is not published until a reviewer approves it).
  Future<void> acceptDraft(String id);

  Future<void> discardDraft(String id);
}

class HttpAgentApi implements AgentApi {
  HttpAgentApi({required String baseUrl, required this.token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
              connectTimeout: const Duration(seconds: 8),
              // For the stream this is the longest silence between two chunks; the server pings
              // every 15 seconds, so a live answer never trips it.
              receiveTimeout: const Duration(seconds: 90),
            ));

  final Dio _dio;
  final String token;

  Options _options({ResponseType? type}) => Options(
        responseType: type,
        headers: {'Authorization': 'Bearer $token'},
      );

  Future<T> _call<T>(Future<Response<dynamic>> Function() send, T Function(dynamic data) parse) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      throw await _translate(e);
    }
  }

  @override
  Future<AgentStatus> status() => _call(
        () => _dio.get('/api/v1/agent/status', options: _options()),
        (d) => AgentStatus.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<List<AgentDraft>> drafts(String conversationId) => _call(
        () => _dio.get('/api/v1/agent/drafts', queryParameters: {'conversation_id': conversationId}, options: _options()),
        (d) => [for (final x in ((d as Map)['drafts'] as List? ?? const [])) AgentDraft.fromJson(x as Map<String, dynamic>)],
      );

  @override
  Future<void> acceptDraft(String id) =>
      _call(() => _dio.post('/api/v1/agent/drafts/${Uri.encodeComponent(id)}/accept', options: _options()), (_) {});

  @override
  Future<void> discardDraft(String id) =>
      _call(() => _dio.post('/api/v1/agent/drafts/${Uri.encodeComponent(id)}/discard', options: _options()), (_) {});

  @override
  Stream<AgentEvent> chat(AgentChatRequest request, {CancelToken? cancel}) async* {
    Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        '/api/v1/agent/chat',
        data: request.toJson(),
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Authorization': 'Bearer $token', 'Accept': 'text/event-stream'},
        ),
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      throw await _translate(e);
    }
    try {
      yield* parseAgentSse(res.data!.stream);
    } on DioException catch (e) {
      throw await _translate(e);
    }
  }

  Future<AgentException> _translate(DioException e) async {
    if (CancelToken.isCancel(e)) return AgentException('已停止');
    final status = e.response?.statusCode;
    if (status != null) {
      final detail = await _errorText(e.response!.data);
      final message = switch (status) {
        401 => '访问令牌不对或还没设置。到「设置 → AI 解读」填写和后台一致的访问令牌',
        404 => 'AI 助手还没有启用。请先到后台「AI 与模型」，给「助手」角色绑定一个 Anthropic 协议的模型',
        429 => '同时进行的对话太多了，请等上一个结束',
        _ when status >= 500 => '服务器出错了，请稍后再试',
        _ => detail.isNotEmpty ? detail : '请求被拒绝（$status）',
      };
      return AgentException(message, status: status);
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError =>
        AgentException('连不上服务器，请确认地址正确并已联网'),
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout => AgentException('服务器长时间没有响应，请重试'),
      _ => AgentException('网络错误：${e.message ?? e.type.name}'),
    };
  }

  /// The `{"error": "…"}` message of a failed answer, if there is one.
  Future<String> _errorText(Object? data) async {
    try {
      final text = data is ResponseBody ? utf8.decode(await data.stream.expand((c) => c).toList()) : '$data';
      final j = data is Map ? data : jsonDecode(text);
      final msg = j is Map ? j['error'] : null;
      return msg is String ? msg : '';
    } catch (_) {
      return '';
    }
  }
}
