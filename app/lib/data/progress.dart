import 'dart:convert';

import 'database.dart';

/// The app's own progress record, stored in the opaque `fsrs` field of a question
/// state until real FSRS scheduling replaces it. It travels through the server
/// untouched, so a second device sees the same wrong-book membership.
class ProgressRecord {
  const ProgressRecord({this.streak = 0, this.lastAnsweredAt});

  /// Consecutive correct answers since the last miss.
  final int streak;
  final int? lastAnsweredAt;

  /// A question leaves the wrong book after this many right answers in a row.
  static const clearStreak = 2;

  ProgressRecord afterAnswer({required bool correct, required int at}) =>
      ProgressRecord(streak: correct ? streak + 1 : 0, lastAnsweredAt: at);

  Map<String, dynamic> toJson() => {'v': 1, 'streak': streak, 'last': lastAnsweredAt};

  String encode() => jsonEncode(toJson());

  factory ProgressRecord.fromJson(Map<String, dynamic>? j) => j == null
      ? const ProgressRecord()
      : ProgressRecord(streak: (j['streak'] as num?)?.toInt() ?? 0, lastAnsweredAt: (j['last'] as num?)?.toInt());

  factory ProgressRecord.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const ProgressRecord();
    try {
      return ProgressRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>?);
    } catch (_) {
      return const ProgressRecord();
    }
  }
}

extension QuestionStateX on QuestionState {
  ProgressRecord get progress => ProgressRecord.decode(fsrsJson);

  /// In the wrong book: missed at least once and not yet answered right twice in a row.
  bool get inWrongBook => wrongCount > 0 && progress.streak < ProgressRecord.clearStreak;
}

extension QuestionX on Question {
  List<String> get options => (jsonDecode(optionsJson) as List).cast<String>();
  List<int> get answer => (jsonDecode(answerJson) as List).map((e) => (e as num).toInt()).toList();
  List<String> get tags => (jsonDecode(tagsJson) as List).cast<String>();
}
