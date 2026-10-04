import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Where the AI explanation settings live on this device (shared preferences):
///  - the access token for fetching the server's configuration,
///  - the configuration fetched from the server (so it keeps working offline),
///  - a configuration typed in by hand, for when there is no server.
class AiConfigStore {
  AiConfigStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kToken = 'ai.token';
  static const _kSynced = 'ai.synced';
  static const _kManual = 'ai.manual';

  String get token => _prefs.getString(_kToken) ?? '';
  AiConfig? get synced => _read(_kSynced);
  AiConfig? get manual => _read(_kManual);

  Future<void> setToken(String token) =>
      token.trim().isEmpty ? _prefs.remove(_kToken) : _prefs.setString(_kToken, token.trim());

  Future<void> setSynced(AiConfig? c) => _write(_kSynced, c);
  Future<void> setManual(AiConfig? c) => _write(_kManual, c);

  AiConfig? _read(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return AiConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, AiConfig? c) =>
      c == null ? _prefs.remove(key) : _prefs.setString(key, jsonEncode(c.toJson()));
}
