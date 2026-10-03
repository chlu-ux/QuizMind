import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/database.dart';
import '../data/exam_store.dart';
import '../data/repository.dart';
import '../data/session_store.dart';
import '../data/sync_service.dart';
import 'settings.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = Provider<Repository>((ref) {
  final deviceId = ref.watch(settingsProvider.select((s) => s.deviceId));
  return Repository(ref.watch(databaseProvider), deviceId: deviceId);
});

final examStoreProvider = Provider<ExamStore>((ref) => ExamStore(ref.watch(sharedPrefsProvider)));

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore(ref.watch(sharedPrefsProvider)));

/// Rebuilt whenever the server address changes.
final apiProvider = Provider<QuizApi>((ref) {
  final s = ref.watch(settingsProvider);
  return HttpQuizApi(baseUrl: s.baseUrl);
});

final banksProvider = StreamProvider<List<Bank>>((ref) => ref.watch(repositoryProvider).watchBanks());
final wrongBookProvider = StreamProvider<List<Question>>((ref) => ref.watch(repositoryProvider).watchWrongBook());
final favoritesProvider = StreamProvider<List<Question>>((ref) => ref.watch(repositoryProvider).watchFavorites());
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
      final last = await _service.lastSync();
      if (ref.mounted) state = SyncStatus(message: report.summary, lastSync: last);
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(running: false, message: e.message, isError: true);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(running: false, message: '同步失败：$e', isError: true);
    }
  }
}
