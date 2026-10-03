import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ulid.dart';

class AppSettings {
  const AppSettings({required this.baseUrl, required this.deviceId});

  final String baseUrl;
  final String deviceId;

  bool get configured => baseUrl.isNotEmpty;

  AppSettings copyWith({String? baseUrl}) => AppSettings(baseUrl: baseUrl ?? this.baseUrl, deviceId: deviceId);
}

/// Accepts "192.168.1.5:8080" as well as a full URL and returns a URL without a
/// trailing slash. Empty input stays empty.
String normalizeBaseUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) s = 'http://$s';
  return s.replaceAll(RegExp(r'/+$'), '');
}

final sharedPrefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('override in main'));

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _kUrl = 'base_url';
  static const _kDevice = 'device_id';

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPrefsProvider);
    var device = prefs.getString(_kDevice);
    if (device == null) {
      device = newUlid();
      prefs.setString(_kDevice, device);
    }
    return AppSettings(
      baseUrl: prefs.getString(_kUrl) ?? '',
      deviceId: device,
    );
  }

  Future<void> save({required String baseUrl}) async {
    final prefs = ref.read(sharedPrefsProvider);
    final url = normalizeBaseUrl(baseUrl);
    await prefs.setString(_kUrl, url);
    state = state.copyWith(baseUrl: url);
  }
}
