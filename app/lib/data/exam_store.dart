import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A finished mock exam. Kept on this device only; the answers themselves sync as ordinary attempts.
class ExamRecord {
  const ExamRecord({
    required this.id,
    required this.bankId,
    required this.title,
    required this.finishedAt,
    required this.total,
    required this.correct,
    required this.answered,
    required this.percent,
    required this.passed,
    required this.limitSec,
    required this.usedMs,
  });

  final String id;
  final String bankId;
  final String title;
  final int finishedAt;
  final int total;
  final int correct;

  /// Questions that got an answer; the rest were left blank.
  final int answered;

  /// Score 0-100: correct answers over all questions, blanks counting as wrong.
  final int percent;
  final bool passed;

  /// Time limit in seconds, null when the exam was untimed.
  final int? limitSec;
  final int usedMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'bank': bankId,
    'title': title,
    'at': finishedAt,
    'total': total,
    'correct': correct,
    'answered': answered,
    'percent': percent,
    'passed': passed,
    'limit': limitSec,
    'used': usedMs,
  };

  factory ExamRecord.fromJson(Map<String, dynamic> j) => ExamRecord(
    id: j['id'] as String,
    bankId: j['bank'] as String,
    title: j['title'] as String,
    finishedAt: (j['at'] as num).toInt(),
    total: (j['total'] as num).toInt(),
    correct: (j['correct'] as num).toInt(),
    answered: (j['answered'] as num).toInt(),
    percent: (j['percent'] as num).toInt(),
    passed: j['passed'] as bool,
    limitSec: (j['limit'] as num?)?.toInt(),
    usedMs: (j['used'] as num).toInt(),
  );
}

/// Exam history per bank in shared preferences, newest first, capped so it stays small.
class ExamStore {
  ExamStore(this._prefs);

  final SharedPreferences _prefs;

  static const keep = 20;

  static String _key(String bankId) => 'exam.history.$bankId';

  List<ExamRecord> history(String bankId) {
    final raw = _prefs.getString(_key(bankId));
    if (raw == null) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) ExamRecord.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return const []; // unreadable history is not worth failing an exam over
    }
  }

  Future<void> add(ExamRecord record) {
    final list = [record, ...history(record.bankId)].take(keep).toList();
    return _prefs.setString(_key(record.bankId), jsonEncode([for (final r in list) r.toJson()]));
  }
}
