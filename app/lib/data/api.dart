import 'package:dio/dio.dart';

import 'models.dart';

/// Thrown for any failed call; [message] is safe to show to the user.
class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;
  final int? status;


  @override
  String toString() => message;
}

/// The server operations the app needs. An interface so sync can be tested
/// without a network.
abstract class QuizApi {
  Future<void> health();
  Future<List<BankDto>> banks();
  Future<QuestionsPage> syncQuestions({required int since, int limit = 500});
  Future<StatesPage> syncStates({required int since, int limit = 500});
  Future<void> uploadAttempts(List<AttemptDto> attempts);
  Future<void> uploadStates(List<StateDto> states);
  Future<void> flagQuestion(String id);
}

class HttpQuizApi implements QuizApi {
  HttpQuizApi({required String baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final Dio _dio;

  Future<T> _call<T>(Future<Response<dynamic>> Function() send, T Function(dynamic data) parse) async {
    try {
      final res = await send();
      return parse(res.data);
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  ApiException _translate(DioException e) {
    final status = e.response?.statusCode;
    if (status != null) {
      final data = e.response?.data;
      final msg = data is Map && data['error'] is String ? data['error'] as String : '服务器返回 $status';
      return ApiException(msg, status: status);
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError =>
        ApiException('连不上服务器，请确认地址正确，且手机和 Mac 在同一个 Wi-Fi'),
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout => ApiException('服务器响应超时'),
      _ => ApiException('网络错误：${e.message ?? e.type.name}'),
    };
  }

  @override
  Future<void> health() => _call(() => _dio.get('/healthz'), (_) {});

  @override
  Future<List<BankDto>> banks() => _call(
        () => _dio.get('/api/v1/banks'),
        (d) => (d as List).map((e) => BankDto.fromJson(e as Map<String, dynamic>)).toList(),
      );

  @override
  Future<QuestionsPage> syncQuestions({required int since, int limit = 500}) => _call(
        () => _dio.get('/api/v1/sync/questions', queryParameters: {'since': since, 'limit': limit}),
        (d) => QuestionsPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<StatesPage> syncStates({required int since, int limit = 500}) => _call(
        () => _dio.get('/api/v1/sync/states', queryParameters: {'since': since, 'limit': limit}),
        (d) => StatesPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> uploadAttempts(List<AttemptDto> attempts) =>
      _call(() => _dio.post('/api/v1/sync/attempts', data: attempts.map((a) => a.toJson()).toList()), (_) {});

  @override
  Future<void> uploadStates(List<StateDto> states) =>
      _call(() => _dio.post('/api/v1/sync/states', data: states.map((s) => s.toJson()).toList()), (_) {});

  @override
  Future<void> flagQuestion(String id) =>
      _call(() => _dio.post('/api/v1/questions/${Uri.encodeComponent(id)}/flag'), (_) {});
}
