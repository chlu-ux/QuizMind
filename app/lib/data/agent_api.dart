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

  /// The history of conversations, newest first; [before] is the `updatedAt` of the last one of the previous page.
  Future<AgentConversationPage> conversations({int? before, int limit = 30});

  Future<AgentConversationDetail> conversation(String id);

  /// Also discards the drafts nobody decided on; questions already accepted stay.
  Future<void> deleteConversation(String id);

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
  Future<AgentConversationPage> conversations({int? before, int limit = 30}) => _history(
        () => _call(
          () => _dio.get('/api/v1/agent/conversations',
              queryParameters: {'before': ?before, 'limit': limit}, options: _options()),
          (d) {
            final m = d as Map<String, dynamic>;
            return AgentConversationPage(
              [for (final x in (m['items'] as List? ?? const [])) AgentConversationItem.fromJson(x as Map<String, dynamic>)],
              hasMore: m['has_more'] == true,
            );
          },
        ),
      );

  /// The history calls answer 404 for a server from before they existed; that is not "no assistant".
  Future<T> _history<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AgentException catch (e) {
      if (e.status == 404) throw AgentException('服务器还不支持历史对话，请先更新服务端', status: 404);
      rethrow;
    }
  }

  @override
  Future<AgentConversationDetail> conversation(String id) async {
    try {
      return await _call(
        () => _dio.get('/api/v1/agent/conversations/${Uri.encodeComponent(id)}', options: _options()),
        (d) => AgentConversationDetail.fromJson(d as Map<String, dynamic>),
      );
    } on AgentException catch (e) {
      // Here a 404 is this conversation (or a server too old to keep any), not a missing assistant.
      if (e.status == 404) throw AgentException('这场对话已经不存在了，可能被删除了，或服务器还不支持历史对话', status: 404);
      rethrow;
    }
  }

  @override
  Future<void> deleteConversation(String id) => _history(() => _call(
      () => _dio.delete('/api/v1/agent/conversations/${Uri.encodeComponent(id)}', options: _options()), (_) {}));

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
      // Not `yield*`: that forwards the stream's errors to the caller without passing through this
      // try, so a cancelled or dropped connection would reach the page as a raw DioException.
      await for (final event in parseAgentSse(res.data!.stream)) {
        yield event;
      }
    } on DioException catch (e) {
      throw await _translate(e);
    } on AgentException {
      rethrow;
    } catch (_) {
      // The connection dropped while the answer was coming (a plain HttpException / SocketException).
      throw AgentException('网络中断了，请重试');
    }
  }

  Future<AgentException> _translate(DioException e) async {
    if (CancelToken.isCancel(e)) return AgentException('已停止');
    final status = e.response?.statusCode;
    if (status != null) {
      final detail = await _errorText(e.response!.data);
      final message = switch (status) {
        401 => '访问令牌不对或还没设置。到「设置 → AI 解读」填写和后台一致的访问令牌',
        409 => '这场对话还在回答上一个问题，请等它结束',
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
