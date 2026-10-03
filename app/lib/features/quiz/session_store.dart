import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import 'quiz_session.dart';

/// A quiz left part-way, as saved on this device. Questions are kept by id so
/// the list survives sync changes; answers are keyed by id for the same reason.
class SavedSession {
  const SavedSession({
    required this.scope,
    required this.title,
    required this.ids,
    required this.seed,
    required this.index,
    required this.answers,
  });

  final String scope;
  final String title;
  final List<String> ids;
  final int seed;
  final int index;
  final Map<String, ({List<int> selected, bool correct})> answers;

  int get total => ids.length;
  int get answered => answers.length;
}

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore(ref.watch(sharedPrefsProvider)));

/// One resumable session per scope (a bank id). The question list is written
/// once when the quiz starts; only the small progress record is rewritten as
/// the learner answers.
class SessionStore {
  SessionStore(this._prefs);

  final SharedPreferences _prefs;

  static String _metaKey(String scope) => 'quiz.session.$scope';
  static String _progressKey(String scope) => 'quiz.progress.$scope';

  Future<void> start(
    String scope, {
    required String title,
    required List<String> ids,
    required int seed,
    required int index,
  }) async {
    await _prefs.setString(_metaKey(scope), jsonEncode({'v': 1, 'title': title, 'ids': ids, 'seed': seed}));
    await saveProgress(scope, index: index, answers: const {});
  }

  Future<void> saveProgress(
    String scope, {
    required int index,
    required Map<String, ({List<int> selected, bool correct})> answers,
  }) =>
      _prefs.setString(
        _progressKey(scope),
        jsonEncode({
          'index': index,
          'answers': {
            for (final e in answers.entries) e.key: {'s': e.value.selected, 'c': e.value.correct},
          },
        }),
      );

  Future<void> clear(String scope) async {
    await _prefs.remove(_metaKey(scope));
    await _prefs.remove(_progressKey(scope));
  }

  /// The saved session for [scope], or null if there is none or it is unreadable.
  SavedSession? load(String scope) {
    final metaRaw = _prefs.getString(_metaKey(scope));
    final progressRaw = _prefs.getString(_progressKey(scope));
    if (metaRaw == null || progressRaw == null) return null;
    try {
      final meta = jsonDecode(metaRaw) as Map<String, dynamic>;
      final progress = jsonDecode(progressRaw) as Map<String, dynamic>;
      final ids = (meta['ids'] as List).cast<String>();
      if (ids.isEmpty) return null;
      return SavedSession(
        scope: scope,
        title: meta['title'] as String,
        ids: ids,
        seed: (meta['seed'] as num).toInt(),
        index: ((progress['index'] as num).toInt()).clamp(0, ids.length - 1),
        answers: {
          for (final e in (progress['answers'] as Map<String, dynamic>).entries)
            e.key: (
              selected: ((e.value as Map)['s'] as List).map((x) => (x as num).toInt()).toList(),
              correct: (e.value as Map)['c'] as bool,
            ),
        },
      );
    } catch (_) {
      unawaited(clear(scope));
      return null;
    }
  }
}

/// A saved session rebuilt against the questions that still exist.
class ResumePlan {
  const ResumePlan({
    required this.title,
    required this.questions,
    required this.index,
    required this.seed,
    required this.restored,
  });

  final String title;
  final List<Question> questions;
  final int index;
  final int seed;
  final Map<String, RestoredAnswer> restored;
}

/// Reloads [saved] from the database. Questions withdrawn or reported since are
/// dropped, and the position moves back so it still points at the same question
/// (or the one that followed it). Null when nothing is left to practise.
Future<ResumePlan?> planResume(SavedSession saved, Repository repo) async {
  final questions = await repo.questionsByIds(saved.ids);
  if (questions.isEmpty) return null;
  final alive = {for (final q in questions) q.id};
  final index = saved.ids.take(saved.index).where(alive.contains).length.clamp(0, questions.length - 1);
  final restored = <String, RestoredAnswer>{};
  for (final e in saved.answers.entries) {
    if (!alive.contains(e.key)) continue;
    final state = await repo.getState(e.key);
    if (state == null) continue; // the local record is gone; let it be answered again
    restored[e.key] = RestoredAnswer(
      selected: e.value.selected,
      outcome: AnswerOutcome(correct: e.value.correct, enteredWrongBook: false, state: state),
    );
  }
  return ResumePlan(title: saved.title, questions: questions, index: index, seed: saved.seed, restored: restored);
}
