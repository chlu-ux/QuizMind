import 'package:dio/dio.dart';

import 'local_agent/agent_spec.dart';
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

  /// The whole answer log, from every device; and finished mock exams. Servers
  /// older than these answer 404, which callers treat as "not supported".
  Future<AttemptsPage> syncAttempts({required int since, int limit = 500});
  Future<ExamsPage> syncExams({required int since, int limit = 100});
  Future<void> uploadExams(List<ExamRecord> exams);
  Future<void> uploadStates(List<StateDto> states);

  /// Saved quizzes. Servers older than the feature answer 404; callers treat that
  /// as "not supported" and carry on without progress sync.
  Future<SessionsPage> syncSessions({required int since, int limit = 100});
  Future<void> uploadSessions(List<SessionDto> sessions);

  /// The study text of every bank. [version] is the one the app holds: when it is current the answer has
  /// `unchanged` set and no sections. Servers older than lessons answer 404.
  Future<LessonsPage> lessons({required int version});

  /// Reports a question. The reason is optional on the server: one from before reasons existed ignores it.
  Future<void> flagQuestion(String id, {String? reason});

  /// AI explanations. Servers older than the feature answer 404.
  Future<NotesPage> syncNotes({required int since, int limit = 100});
  Future<void> uploadNotes(List<NoteDto> notes);

  /// The LLM endpoint for AI explanations, fetched with the access token set in the
  /// admin UI. 401 = wrong token; 404 = the server has the feature switched off (or
  /// predates it).
  Future<AiConfig> aiConfig({required String token});

  /// Tells the server what AI explanations cost (token counts), with the same access token. Servers older
  /// than the feature answer 404; 400 means a record was refused.
  Future<void> uploadAiUsage(List<AiUsage> usage, {required String token});

  /// What the assistant needs to run on this device when the server is out of reach (instructions, tools,
  /// the model's address and key). 401 = wrong token; 404 = the server has no assistant (or predates it).
  Future<LocalAgentSpec> agentLocalSpec({required String token});

  /// Sends the questions the assistant wrote on this device, one answer per question in order. 404: a server
  /// from before this existed.
  Future<List<AgentUploadResult>> uploadAgentQuestions(List<AgentUpload> questions, {required String token});

  /// Tells the server the learner took a question of the assistant back (or adopted it again).
  Future<void> decideAgentQuestion(String id, {required bool adopt, required String token});
}

/// A question the assistant wrote on this device, as it is sent to the server. The id is the question's
/// id from now on.
class AgentUpload {
  const AgentUpload({
    required this.id,
    required this.lessonId,
    required this.conversationId,
    required this.deviceId,
    required this.model,
    required this.type,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.explanation,
    required this.difficulty,
    required this.tags,
    required this.sourceQuote,
  });

  final String id;
  final String lessonId;
  final String conversationId;
  final String deviceId;
  final String model;
  final String type;
  final String stem;
  final List<String> options;
  final int answerIndex;
  final String explanation;
  final int difficulty;
  final List<String> tags;
  final String sourceQuote;

  Map<String, dynamic> toJson() => {
        'id': id,
        'lesson_id': lessonId,
        'conversation_id': conversationId,
        'device_id': deviceId,
        'model': model,
        'type': type,
        'stem': stem,
        'options': options,
        'answer_index': answerIndex,
        'explanation': explanation,
        'difficulty': difficulty,
        'tags': tags,
        'source_quote': sourceQuote,
      };
}

/// What the server did with one uploaded question: [ok] with the [status] it has there, or refused with a
/// reason for the learner.
class AgentUploadResult {
  const AgentUploadResult({required this.id, required this.ok, this.status = '', this.error = ''});

  final String id;
  final bool ok;

  /// published | needs_review | rejected
  final String status;
  final String error;

  factory AgentUploadResult.fromJson(Map<String, dynamic> j) => AgentUploadResult(
        id: (j['id'] as String?) ?? '',
        ok: j['ok'] == true,
        status: (j['status'] as String?) ?? '',
        error: (j['error'] as String?) ?? '',
      );
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
  Future<AttemptsPage> syncAttempts({required int since, int limit = 500}) => _call(
        () => _dio.get('/api/v1/sync/attempts', queryParameters: {'since': since, 'limit': limit}),
        (d) => AttemptsPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<ExamsPage> syncExams({required int since, int limit = 100}) => _call(
        () => _dio.get('/api/v1/sync/exams', queryParameters: {'since': since, 'limit': limit}),
        (d) => ExamsPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> uploadExams(List<ExamRecord> exams) =>
      _call(() => _dio.post('/api/v1/sync/exams', data: exams.map((e) => e.toJson()).toList()), (_) {});

  @override
  Future<void> uploadStates(List<StateDto> states) =>
      _call(() => _dio.post('/api/v1/sync/states', data: states.map((s) => s.toJson()).toList()), (_) {});

  @override
  Future<SessionsPage> syncSessions({required int since, int limit = 100}) => _call(
        () => _dio.get('/api/v1/sync/sessions', queryParameters: {'since': since, 'limit': limit}),
        (d) => SessionsPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> uploadSessions(List<SessionDto> sessions) =>
      _call(() => _dio.post('/api/v1/sync/sessions', data: sessions.map((s) => s.toJson()).toList()), (_) {});

  @override
  Future<LessonsPage> lessons({required int version}) => _call(
        () => _dio.get('/api/v1/lessons', queryParameters: {'version': version}),
        (d) => LessonsPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> flagQuestion(String id, {String? reason}) => _call(
        () => _dio.post('/api/v1/questions/${Uri.encodeComponent(id)}/flag', data: reason == null ? null : {'reason': reason}),
        (_) {},
      );

  @override
  Future<NotesPage> syncNotes({required int since, int limit = 100}) => _call(
        () => _dio.get('/api/v1/sync/notes', queryParameters: {'since': since, 'limit': limit}),
        (d) => NotesPage.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> uploadNotes(List<NoteDto> notes) =>
      _call(() => _dio.post('/api/v1/sync/notes', data: notes.map((n) => n.toJson()).toList()), (_) {});

  @override
  Future<AiConfig> aiConfig({required String token}) => _call(
        () => _dio.get('/api/v1/ai/config', options: Options(headers: {'Authorization': 'Bearer $token'})),
        (d) => AiConfig.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<void> uploadAiUsage(List<AiUsage> usage, {required String token}) => _call(
        () => _dio.post(
          '/api/v1/ai/usage',
          data: usage.map((u) => u.toJson()).toList(),
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        ),
        (_) {},
      );

  @override
  Future<LocalAgentSpec> agentLocalSpec({required String token}) => _call(
        () => _dio.get('/api/v1/agent/local-spec', options: Options(headers: {'Authorization': 'Bearer $token'})),
        (d) => LocalAgentSpec.fromJson(d as Map<String, dynamic>),
      );

  @override
  Future<List<AgentUploadResult>> uploadAgentQuestions(List<AgentUpload> questions, {required String token}) => _call(
        () => _dio.post(
          '/api/v1/agent/questions',
          data: {'questions': [for (final q in questions) q.toJson()]},
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        ),
        (d) => [
          for (final r in ((d as Map<String, dynamic>)['results'] as List? ?? const []))
            AgentUploadResult.fromJson(r as Map<String, dynamic>),
        ],
      );

  @override
  Future<void> decideAgentQuestion(String id, {required bool adopt, required String token}) => _call(
        () => _dio.post(
          '/api/v1/agent/drafts/${Uri.encodeComponent(id)}/${adopt ? 'accept' : 'discard'}',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        ),
        (_) {},
      );
}
