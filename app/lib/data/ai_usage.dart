import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_config_store.dart';
import 'api.dart';
import 'models.dart';

/// A guess at how many tokens [text] is, for endpoints that do not say. Chinese runs about one token per
/// character or a bit less, other text about one per four characters; the real count differs by model.
int estimateTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final r in text.runes) {
    if (r >= 0x2E80) {
      cjk++;
    } else {
      other++;
    }
  }
  return (cjk * 0.8 + other * 0.28).ceil();
}

/// The reports of AI-explanation calls that have not reached the server yet (shared preferences), oldest
/// first. Bounded, so a phone that is never synced does not grow it without limit.
class AiUsageStore {
  AiUsageStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'ai.usage';
  static const maxQueued = 500;

  List<AiUsage> pending() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) AiUsage.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return const []; // unreadable: nothing worth keeping
    }
  }

  Future<void> add(AiUsage usage) async {
    final all = [...pending(), usage];
    await _write(all.length > maxQueued ? all.sublist(all.length - maxQueued) : all);
  }

  Future<void> remove(Iterable<String> ids) async {
    final gone = ids.toSet();
    await _write([for (final u in pending()) if (!gone.contains(u.id)) u]);
  }

  Future<void> _write(List<AiUsage> all) =>
      all.isEmpty ? _prefs.remove(_key) : _prefs.setString(_key, jsonEncode([for (final u in all) u.toJson()]));
}

/// Queues what each AI explanation cost and sends it to the server. Nothing is reported without the
/// server's access token (there is nowhere to report to), and a failed upload just waits for the next try.
class AiUsageReporter {
  AiUsageReporter(this.store, this.config);

  final AiUsageStore store;
  final AiConfigStore config;
  bool _flushing = false;

  static const _batch = 100; // the server's per-request limit

  /// Queues [usage] unless there is no server to tell.
  Future<void> record(AiUsage usage) async {
    if (config.token.isEmpty) return;
    await store.add(usage);
  }

  /// Sends everything queued; returns how many records the server took. Never throws: the usage report is
  /// a convenience and must not fail a sync or an explanation.
  Future<int> flush(QuizApi api) async {
    final token = config.token;
    if (token.isEmpty || _flushing) return 0;
    _flushing = true;
    var sent = 0;
    try {
      while (true) {
        final batch = store.pending().take(_batch).toList();
        if (batch.isEmpty) return sent;
        try {
          await api.uploadAiUsage(batch, token: token);
        } on ApiException catch (e) {
          // 400: the server will never take these; drop them rather than retry forever. Anything else
          // (wrong token, an older server, no connection) leaves them queued for later.
          if (e.status != 400) return sent;
        }
        await store.remove(batch.map((u) => u.id));
        sent += batch.length;
      }
    } finally {
      _flushing = false;
    }
  }
}
