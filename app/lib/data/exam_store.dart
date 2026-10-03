import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'repository.dart';

/// An exam in progress, kept on this device only so a killed app can pick it up
/// again. The clock keeps running from [startedAt], so a timed exam's remaining
/// time stays honest. There is at most one per bank.
class ExamDraft {
  const ExamDraft({
    required this.bankId,
    required this.title,
    required this.ids,
    required this.seed,
    required this.startedAt,
    required this.limitSec,
    required this.index,
    required this.answers,
    required this.spent,
    required this.marked,
    required this.savedAt,
  });

  final String bankId;
  final String title;

  /// The paper, in order.
  final List<String> ids;
  final int seed;
  final int startedAt;
  final int? limitSec;
  final int index;

  /// Option indexes picked, by question id; absent = blank.
  final Map<String, List<int>> answers;

  /// Milliseconds spent on each question, by id.
  final Map<String, int> spent;

  /// Question ids flagged "check again".
  final List<String> marked;
  final int savedAt;

  Map<String, dynamic> toJson() => {
        'bank': bankId,
        'title': title,
        'ids': ids,
        'seed': seed,
        'started': startedAt,
        'limit': limitSec,
        'index': index,
        'answers': answers,
        'spent': spent,
        'marked': marked,
        'saved': savedAt,
      };

  factory ExamDraft.fromJson(Map<String, dynamic> j) => ExamDraft(
        bankId: j['bank'] as String,
        title: j['title'] as String,
        ids: (j['ids'] as List).cast<String>(),
        seed: (j['seed'] as num).toInt(),
        startedAt: (j['started'] as num).toInt(),
        limitSec: (j['limit'] as num?)?.toInt(),
        index: (j['index'] as num).toInt(),
        answers: {
          for (final e in (j['answers'] as Map<String, dynamic>).entries)
            e.key: (e.value as List).map((x) => (x as num).toInt()).toList(),
        },
        spent: {for (final e in (j['spent'] as Map<String, dynamic>).entries) e.key: (e.value as num).toInt()},
        marked: (j['marked'] as List).cast<String>(),
        savedAt: (j['saved'] as num).toInt(),
      );
}

/// Exam results used to be kept in shared preferences, per bank, under
/// `exam.history.<bank>`. This moves them into the database (queued for upload,
/// without per-question detail) and removes the old keys. Safe to call on every
/// start: it does nothing once the keys are gone.
Future<int> importLegacyExams(SharedPreferences prefs, Repository repo) async {
  var imported = 0;
  for (final key in prefs.getKeys().where((k) => k.startsWith('exam.history.')).toList()) {
    try {
      for (final j in jsonDecode(prefs.getString(key) ?? '[]') as List) {
        final m = j as Map<String, dynamic>;
        await repo.importExam(ExamRecord(
          id: m['id'] as String,
          bankId: m['bank'] as String,
          title: m['title'] as String,
          finishedAt: (m['at'] as num).toInt(),
          total: (m['total'] as num).toInt(),
          correct: (m['correct'] as num).toInt(),
          answered: (m['answered'] as num).toInt(),
          percent: (m['percent'] as num).toInt(),
          passed: m['passed'] as bool,
          limitSec: (m['limit'] as num?)?.toInt(),
          usedMs: (m['used'] as num).toInt(),
        ));
        imported++;
      }
    } catch (_) {
      // Unreadable history is not worth failing a start over.
    }
    await prefs.remove(key);
  }
  return imported;
}
