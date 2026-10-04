import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

/// A saved quiz waiting to go to the server. [data] is null for a finished quiz.
typedef PendingSession = ({String scope, Map<String, dynamic>? data, int updatedAt});

/// One resumable quiz per scope (a bank id), kept in shared preferences and
/// synced through the server so another device can pick it up.
///
/// The question list is written once when the quiz starts; only the small
/// progress record is rewritten as the learner answers. Every write stamps the
/// record and marks it dirty until a sync uploads it. A finished quiz is not
/// deleted but turned into a tombstone, so finishing on one device clears the
/// others too.
class SessionStore {
  SessionStore(this._prefs, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  static const _cursorKey = 'quiz.sessions.cursor';
  static const _progressPrefix = 'quiz.progress.';

  static String _metaKey(String scope) => 'quiz.session.$scope';
  static String _progressKey(String scope) => '$_progressPrefix$scope';

  int _now() => _clock().millisecondsSinceEpoch;

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
      _writeProgress(scope, {
        'index': index,
        'answers': {
          for (final e in answers.entries) e.key: {'s': e.value.selected, 'c': e.value.correct},
        },
        'at': _now(),
        'dirty': true,
      });

  /// Marks the quiz finished.
  Future<void> clear(String scope) async {
    await _prefs.remove(_metaKey(scope));
    await _writeProgress(scope, {'done': true, 'at': _now(), 'dirty': true});
  }

  Future<void> _writeProgress(String scope, Map<String, dynamic> record) =>
      _prefs.setString(_progressKey(scope), jsonEncode(record));

  Map<String, dynamic>? _progress(String scope) {
    final raw = _prefs.getString(_progressKey(scope));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// The saved quiz for [scope], or null if there is none, it was finished, or
  /// it is unreadable.
  SavedSession? load(String scope) {
    final metaRaw = _prefs.getString(_metaKey(scope));
    final progress = _progress(scope);
    if (metaRaw == null || progress == null || progress['done'] == true) return null;
    try {
      final meta = jsonDecode(metaRaw) as Map<String, dynamic>;
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
      // Unreadable: forget it rather than crash every time the bank page opens.
      _prefs.remove(_metaKey(scope));
      _prefs.remove(_progressKey(scope));
      return null;
    }
  }

  // ---- sync ----

  /// Everything changed here since it was last uploaded.
  List<PendingSession> pending() {
    final out = <PendingSession>[];
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_progressPrefix)) continue;
      final scope = key.substring(_progressPrefix.length);
      final p = _progress(scope);
      if (p == null || p['dirty'] != true) continue;
      final at = (p['at'] as num?)?.toInt() ?? 0;
      if (p['done'] == true) {
        out.add((scope: scope, data: null, updatedAt: at));
        continue;
      }
      final meta = _prefs.getString(_metaKey(scope));
      if (meta == null) continue;
      try {
        final m = jsonDecode(meta) as Map<String, dynamic>;
        out.add((
          scope: scope,
          data: {
            'title': m['title'],
            'ids': m['ids'],
            'seed': m['seed'],
            'index': p['index'],
            'answers': p['answers'],
          },
          updatedAt: at,
        ));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Clears the dirty flag, unless the quiz changed again while it was uploading.
  Future<void> markUploaded(String scope, int updatedAt) async {
    final p = _progress(scope);
    if (p == null || (p['at'] as num?)?.toInt() != updatedAt) return;
    await _writeProgress(scope, {...p, 'dirty': false});
  }

  /// Takes a quiz from the server unless this device changed it more recently.
  /// Returns whether anything was written.
  Future<bool> applyRemote(String scope, Map<String, dynamic>? data, int updatedAt) async {
    final local = _progress(scope);
    if (local != null && ((local['at'] as num?)?.toInt() ?? 0) >= updatedAt) return false;
    if (data == null) {
      await _prefs.remove(_metaKey(scope));
      await _writeProgress(scope, {'done': true, 'at': updatedAt, 'dirty': false});
      return true;
    }
    final Map<String, dynamic> meta;
    final Map<String, dynamic> progress;
    try {
      final ids = (data['ids'] as List).cast<String>();
      if (ids.isEmpty) return false;
      meta = {'v': 1, 'title': data['title'] as String, 'ids': ids, 'seed': (data['seed'] as num).toInt()};
      progress = {
        'index': (data['index'] as num).toInt(),
        'answers': Map<String, dynamic>.from(data['answers'] as Map),
        'at': updatedAt,
        'dirty': false,
      };
    } catch (_) {
      return false; // a document this version cannot read; keep what we have
    }
    await _prefs.setString(_metaKey(scope), jsonEncode(meta));
    await _writeProgress(scope, progress);
    return true;
  }

  // ---- sequential position (this device only) ----

  static String _seqKey(String scope) => 'quiz.seqpos.$scope';

  /// Id of the question the learner was on when they last left "按顺序刷题" in
  /// [scope]; null when they have not started or went through the whole bank.
  String? sequentialPosition(String scope) => _prefs.getString(_seqKey(scope));

  Future<void> setSequentialPosition(String scope, String? questionId) =>
      questionId == null ? _prefs.remove(_seqKey(scope)) : _prefs.setString(_seqKey(scope), questionId);

  int get cursor => _prefs.getInt(_cursorKey) ?? 0;

  Future<void> setCursor(int seq) => _prefs.setInt(_cursorKey, seq);
}
