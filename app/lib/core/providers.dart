import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/ai_chat.dart';
import '../data/ai_config_store.dart';
import '../data/ai_usage.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../data/database.dart';
import '../data/exam_store.dart';
import '../data/media_store.dart';
import '../data/repository.dart';
import '../data/session_store.dart';
import '../data/stats.dart';
import '../data/sync_service.dart';
import 'settings.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = Provider<Repository>((ref) {
  final deviceId = ref.watch(settingsProvider.select((s) => s.deviceId));
  final repo = Repository(ref.watch(databaseProvider), deviceId: deviceId);
  // Exam results used to be kept in shared preferences; move any left over (once).
  unawaited(importLegacyExams(ref.read(sharedPrefsProvider), repo).then((_) {}, onError: (Object _) {}));
  return repo;
});

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore(ref.watch(sharedPrefsProvider)));

final aiConfigStoreProvider = Provider<AiConfigStore>((ref) => AiConfigStore(ref.watch(sharedPrefsProvider)));

/// What the AI explanation settings look like right now; reload() after anything changes them behind its back (a sync).
class AiSettings {
  const AiSettings({required this.token, required this.synced, required this.manual});

  final String token;
  final AiConfig? synced;
  final AiConfig? manual;

  /// The configuration an explanation request will use, if any.
  AiConfig? get effective {
    final m = manual;
    if (m != null && m.usable) return m;
    final s = synced;
    return s != null && s.usable ? s : null;
  }

  bool get usingManual => manual != null && manual!.usable;
}

final aiSettingsProvider = NotifierProvider<AiSettingsNotifier, AiSettings>(AiSettingsNotifier.new);

class AiSettingsNotifier extends Notifier<AiSettings> {
  AiConfigStore get _store => ref.read(aiConfigStoreProvider);

  @override
  AiSettings build() => _read();

  AiSettings _read() => AiSettings(token: _store.token, synced: _store.synced, manual: _store.manual);

  void reload() => state = _read();

  Future<void> saveToken(String token) async {
    await _store.setToken(token);
    reload();
  }

  Future<void> saveManual(AiConfig? config) async {
    await _store.setManual(config);
    reload();
  }
}

final aiUsageReporterProvider = Provider<AiUsageReporter>(
  (ref) => AiUsageReporter(AiUsageStore(ref.watch(sharedPrefsProvider)), ref.watch(aiConfigStoreProvider)),
);

/// How explanations are fetched from the model; overridden in tests.
final aiChatProvider = Provider<AiChat>((ref) => HttpAiChat());

/// Rebuilt whenever the server address changes.
final apiProvider = Provider<QuizApi>((ref) {
  final s = ref.watch(settingsProvider);
  return HttpQuizApi(baseUrl: s.baseUrl);
});

/// Pictures of questions, saved on this device. Rebuilt when the server address changes; overridden in tests.
final mediaStoreProvider = Provider<MediaStore>((ref) {
  final baseUrl = ref.watch(settingsProvider.select((s) => s.baseUrl));
  return MediaStore(baseUrl: baseUrl, directory: getApplicationSupportDirectory);
});

final banksProvider = StreamProvider<List<Bank>>((ref) => ref.watch(repositoryProvider).watchBanks());
final wrongBookProvider = StreamProvider<List<Question>>((ref) => ref.watch(repositoryProvider).watchWrongBook());

/// The wrong book of one bank (for the "本题库错题本" entry on a bank page).
final bankWrongBookProvider =
    StreamProvider.family<List<Question>, String>((ref, bankId) => ref.watch(repositoryProvider).watchWrongBook(bankId: bankId));
final favoritesProvider = StreamProvider<List<Question>>((ref) => ref.watch(repositoryProvider).watchFavorites());

/// What was done on the local day starting at [day] (a midnight), over all banks, kept up to date.
final dayProgressProvider = StreamProvider.autoDispose.family<DayProgress, DateTime>(
  (ref, day) => ref.watch(repositoryProvider).watchDayProgress(day),
);
final pendingUploadsProvider = StreamProvider<int>((ref) => ref.watch(repositoryProvider).watchPendingUploads());

class SyncStatus {
  const SyncStatus({this.running = false, this.message, this.isError = false, this.lastSync});

  final bool running;
  final String? message;
  final bool isError;
  final DateTime? lastSync;

  SyncStatus copyWith({bool? running, String? message, bool? isError, DateTime? lastSync, bool clearMessage = false}) =>
      SyncStatus(
        running: running ?? this.running,
        message: clearMessage ? null : (message ?? this.message),
        isError: isError ?? this.isError,
        lastSync: lastSync ?? this.lastSync,
      );
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);

class SyncController extends Notifier<SyncStatus> {
  @override
  SyncStatus build() {
    Future.microtask(_loadLast);
    return const SyncStatus();
  }

  SyncService get _service => SyncService(
        ref.read(databaseProvider),
        ref.read(apiProvider),
        sessions: ref.read(sessionStoreProvider),
        aiConfig: ref.read(aiConfigStoreProvider),
        aiUsage: ref.read(aiUsageReporterProvider),
        media: ref.read(mediaStoreProvider),
        deviceId: ref.read(settingsProvider).deviceId,
      );

  Future<void> _loadLast() async {
    final last = await _service.lastSync();
    if (last != null && ref.mounted) state = state.copyWith(lastSync: last);
  }

  /// Runs a full sync. Failures are reported in the state, never thrown, so the
  /// app keeps working offline.
  Future<void> run() async {
    if (!ref.mounted || state.running) return;
    if (!ref.read(settingsProvider).configured) {
      state = state.copyWith(message: '请先在设置里填写服务器地址', isError: true);
      return;
    }
    state = state.copyWith(running: true, clearMessage: true);
    try {
      final report = await _service.run();
      if (!ref.mounted) return;
      ref.read(aiSettingsProvider.notifier).reload();
      final last = await _service.lastSync();
      if (ref.mounted) state = SyncStatus(message: report.summary, lastSync: last);
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(running: false, message: e.message, isError: true);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(running: false, message: '同步失败：$e', isError: true);
    }
  }
}
