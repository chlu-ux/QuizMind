import 'package:drift/native.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/models.dart';

AppDatabase memoryDb() => AppDatabase(NativeDatabase.memory());

QuestionDto question(String id, {int seq = 1, String bank = 'b1', int answer = 0, String type = 'single'}) => QuestionDto(
      id: id,
      bankId: bank,
      type: type,
      stem: '题干 $id',
      options: type == 'judge' ? ['正确', '错误'] : ['A', 'B', 'C', 'D'],
      answer: [answer],
      explanation: '解析',
      difficulty: 2,
      tags: const ['t'],
      sourceQuote: '原文',
      syncSeq: seq,
    );

/// An in-memory stand-in for the server that records uploads.
class FakeApi implements QuizApi {
  List<BankDto> bankList = [BankDto(id: 'b1', title: '题库', description: '', questionCount: 0)];
  final List<QuestionDto> published = [];
  final List<String> withdrawnAfter = [];
  final List<StateDto> remoteStates = [];
  final List<AttemptDto> uploadedAttempts = [];
  final List<StateDto> uploadedStates = [];
  final List<String> flagged = [];
  int pageSize = 1000;
  Object? failWith;

  @override
  Future<void> health() async {}

  @override
  Future<List<BankDto>> banks() async {
    _maybeFail();
    return bankList;
  }

  @override
  Future<QuestionsPage> syncQuestions({required int since, int limit = 500}) async {
    _maybeFail();
    final rows = published.where((q) => q.syncSeq > since).toList()..sort((a, b) => a.syncSeq.compareTo(b.syncSeq));
    final take = rows.take(pageSize).toList();
    return QuestionsPage(
      items: take,
      deleted: take.isEmpty ? [] : withdrawnAfter,
      nextSeq: take.isEmpty ? since : take.last.syncSeq,
      hasMore: rows.length > take.length,
    );
  }

  @override
  Future<StatesPage> syncStates({required int since, int limit = 500}) async {
    _maybeFail();
    return StatesPage(items: remoteStates, nextSeq: remoteStates.isEmpty ? since : 99, hasMore: false);
  }

  @override
  Future<void> uploadAttempts(List<AttemptDto> attempts) async {
    _maybeFail();
    uploadedAttempts.addAll(attempts);
  }

  @override
  Future<void> uploadStates(List<StateDto> states) async {
    _maybeFail();
    uploadedStates.addAll(states);
  }

  @override
  Future<void> flagQuestion(String id) async {
    _maybeFail();
    flagged.add(id);
  }

  void _maybeFail() {
    if (failWith != null) throw failWith!;
  }
}
