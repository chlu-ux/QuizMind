import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/api.dart';
import 'package:quizmind_app/data/session_store.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// One device: its own database and its own preferences, like a separate phone.
class Device {
  Device._(this.store, this.sync);

  final SessionStore store;
  final SyncService sync;

  static Future<Device> create(String id, FakeApi api, {required int Function() now}) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = memoryDb();
    addTearDown(db.close);
    clock() => DateTime.fromMillisecondsSinceEpoch(now());
    final store = SessionStore(prefs, clock: clock);
    return Device._(store, SyncService(db, api, sessions: store, deviceId: id, clock: clock));
  }
}

void main() {
  // Each simulated device has its own database; that is the point of these tests.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeApi api;
  var t = 0;
  int tick() => t += 1000;

  setUp(() {
    api = FakeApi();
    t = 1_000_000;
  });

  group('SessionStore', () {
    Future<SessionStore> store() async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      return SessionStore(await SharedPreferences.getInstance(), clock: () => DateTime.fromMillisecondsSinceEpoch(tick()));
    }

    test('every change is pending until uploaded, and a later change keeps it pending', () async {
      final s = await store();
      expect(s.pending(), isEmpty);

      await s.start('b1', title: '题库', ids: ['a', 'b'], seed: 5, index: 0);
      final first = s.pending().single;
      expect((first.scope, first.data!['title'], first.data!['index']), ('b1', '题库', 0));

      await s.saveProgress('b1', index: 1, answers: {'a': (selected: [2], correct: false)});
      final second = s.pending().single;
      expect(second.updatedAt, greaterThan(first.updatedAt));
      expect((second.data!['answers'] as Map)['a'], {'s': [2], 'c': false});

      await s.markUploaded('b1', first.updatedAt);
      expect(s.pending(), hasLength(1), reason: 'it changed again while the first upload was in flight');
      await s.markUploaded('b1', second.updatedAt);
      expect(s.pending(), isEmpty);
    });

    test('finishing leaves a tombstone that is uploaded as null data', () async {
      final s = await store();
      await s.start('b1', title: 't', ids: ['a'], seed: 1, index: 0);
      await s.clear('b1');
      expect(s.load('b1'), isNull);
      final p = s.pending().single;
      expect((p.scope, p.data), ('b1', null));
    });

    test('applyRemote: newer wins, older is ignored, null clears, garbage is refused', () async {
      final s = await store();
      Map<String, dynamic> doc(int index) => {
            'title': '远端',
            'ids': ['a', 'b', 'c'],
            'seed': 9,
            'index': index,
            'answers': {'a': {'s': [1], 'c': true}},
          };

      expect(await s.applyRemote('b1', doc(2), 5000), isTrue);
      final loaded = s.load('b1')!;
      expect((loaded.title, loaded.index, loaded.seed, loaded.answered), ('远端', 2, 9, 1));
      expect(s.pending(), isEmpty, reason: 'what came from the server is not uploaded back');

      expect(await s.applyRemote('b1', doc(0), 4000), isFalse, reason: 'older');
      expect(s.load('b1')!.index, 2);
      expect(await s.applyRemote('b1', doc(1), 5000), isFalse, reason: 'same time: keep ours');

      expect(await s.applyRemote('b1', {'title': 1}, 6000), isFalse, reason: 'unreadable document');
      expect(s.load('b1')!.index, 2);

      expect(await s.applyRemote('b1', null, 7000), isTrue);
      expect(s.load('b1'), isNull);
      expect(s.pending(), isEmpty);
    });

    test('a quiz changed here after the server copy wins over a stale pull', () async {
      final s = await store();
      await s.start('b1', title: 'mine', ids: ['a', 'b'], seed: 1, index: 1); // stamped by the test clock
      expect(await s.applyRemote('b1', {'title': 'old', 'ids': ['a'], 'seed': 1, 'index': 0, 'answers': {}}, 1), isFalse);
      expect(s.load('b1')!.title, 'mine');
    });
  });

  group('syncing between devices', () {
    test('a quiz left on one device can be continued on another', () async {
      final phone = await Device.create('phone', api, now: tick);
      await phone.store.start('b1', title: '软件设计师', ids: ['q1', 'q2', 'q3'], seed: 11, index: 0);
      await phone.store.saveProgress('b1', index: 2, answers: {'q1': (selected: [1], correct: true)});
      await phone.sync.run();
      expect(api.sessions['b1']!.session.deviceId, 'phone');
      expect(phone.store.pending(), isEmpty, reason: 'uploaded');

      final tablet = await Device.create('tablet', api, now: tick);
      expect(tablet.store.load('b1'), isNull);
      final report = await tablet.sync.run();
      expect(report.sessionsPulled, 1);
      expect(report.summary, contains('刷题进度'));
      final got = tablet.store.load('b1')!;
      expect((got.title, got.index, got.seed, got.total), ('软件设计师', 2, 11, 3));
      expect(got.answers['q1']!.correct, isTrue);
      expect(tablet.store.pending(), isEmpty);

      // Nothing changed: a second sync neither uploads nor re-applies anything.
      expect((await tablet.sync.run()).sessionsPulled, 0);
    });

    test('finishing on one device clears the others', () async {
      final phone = await Device.create('phone', api, now: tick);
      await phone.store.start('b1', title: 't', ids: ['q1', 'q2'], seed: 1, index: 0);
      await phone.sync.run();
      final tablet = await Device.create('tablet', api, now: tick);
      await tablet.sync.run();
      expect(tablet.store.load('b1'), isNotNull);

      await tablet.store.clear('b1'); // finished the quiz on the tablet
      await tablet.sync.run();
      await phone.sync.run();
      expect(phone.store.load('b1'), isNull, reason: 'the tombstone reached the phone');
      expect(api.sessions['b1']!.session.data, isNull);
    });

    test('the more recent change wins when both devices moved on', () async {
      final phone = await Device.create('phone', api, now: tick);
      await phone.store.start('b1', title: 't', ids: ['q1', 'q2', 'q3'], seed: 1, index: 0);
      await phone.sync.run();
      final tablet = await Device.create('tablet', api, now: tick);
      await tablet.sync.run();

      await phone.store.saveProgress('b1', index: 1, answers: const {});
      await tablet.store.saveProgress('b1', index: 2, answers: const {}); // later
      await phone.sync.run(); // uploads index 1
      await tablet.sync.run(); // uploads index 2 (newer) and keeps it
      await phone.sync.run(); // pulls the tablet's position

      expect(phone.store.load('b1')!.index, 2);
      expect(tablet.store.load('b1')!.index, 2);
    });

    test('a server that does not know sessions yet does not break syncing', () async {
      api.sessionsUnsupported = true;
      final phone = await Device.create('phone', api, now: tick);
      await phone.store.start('b1', title: 't', ids: ['q1'], seed: 1, index: 0);
      final report = await phone.sync.run();
      expect(report.sessionsPulled, 0);
      expect(phone.store.pending(), hasLength(1), reason: 'kept for when the server is upgraded');
      expect(phone.store.load('b1'), isNotNull);

      api.sessionsUnsupported = false;
      await phone.sync.run();
      expect(phone.store.pending(), isEmpty);
      expect(api.sessions['b1'], isNotNull);
    });

    test('other server errors still fail the sync', () async {
      final phone = await Device.create('phone', api, now: tick);
      api.failWith = ApiException('boom', status: 500);
      await expectLater(phone.sync.run(), throwsA(isA<ApiException>()));
    });
  });
}
