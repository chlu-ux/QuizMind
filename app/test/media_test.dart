import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/providers.dart';
import 'package:quizmind_app/data/media_store.dart';
import 'package:quizmind_app/data/media_text.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:quizmind_app/features/quiz/quiz_media.dart';
import 'package:quizmind_app/features/quiz/quiz_page.dart';

import 'support.dart';

const _a = '0123456789abcdef01234567';
const _b = 'fedcba9876543210fedcba98';

/// A 1x1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// Answers `/api/v1/media/<id>` from [pictures], counting the requests.
class FakeMediaServer implements HttpClientAdapter {
  final pictures = <String, Uint8List>{};
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri.toString());
    final id = options.uri.pathSegments.last;
    final bytes = pictures[id];
    if (bytes == null) return ResponseBody.fromString('{"error":"not found"}', 404);
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentTypeHeader: ['image/png'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Pictures load through several steps of real file and network IO, each continuing inside the fake
/// clock; alternate between letting IO finish and pumping (which also runs the fake timers) so every
/// step gets its turn.
Future<void> settleImages(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory dir;
  late FakeMediaServer server;

  MediaStore store({String baseUrl = 'http://srv:8080'}) =>
      MediaStore(baseUrl: baseUrl, directory: () async => dir, dio: Dio()..httpClientAdapter = server);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('media_test');
    server = FakeMediaServer()..pictures[_a] = _png;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('picture references', () {
    test('plainText shows a placeholder in lists', () {
      expect(plainText('如图\n\n![](media:$_a)'), '如图\n\n[图]');
      expect(plainText('![用例图](media:$_a) 与 ![](media:$_b)'), '[图：用例图] 与 [图]');
      expect(plainText('![x](https://other.test/a.png)'), '![x](https://other.test/a.png)');
    });

    test('mediaIds collects the distinct pictures', () {
      expect(mediaIds(['![](media:$_a)', '[“![](media:$_b)”, "![](media:$_a)"]', '没有图']), {_a, _b});
    });

    test('splitPictures leaves other Markdown characters alone', () {
      expect(splitPictures('*p++ 与 <T>'), [const PlainPart('*p++ 与 <T>')]);
      expect(splitPictures('A ![图](media:$_a) B'), [const PlainPart('A '), const PicturePart(_a, '图'), const PlainPart(' B')]);
    });
  });

  group('SVG pictures', () {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20"><rect width="40" height="20" fill="#fff"/></svg>';

    test('isSvg tells a drawing from a bitmap or other XML', () {
      expect(isSvg(utf8.encode(svg)), isTrue);
      expect(isSvg(utf8.encode('<?xml version="1.0"?>\n<!-- c -->\n$svg')), isTrue);
      expect(isSvg(_png), isFalse);
      expect(isSvg(utf8.encode('<html><svg/></html>')), isFalse);
      expect(imageMime(utf8.encode(svg)), 'image/svg+xml');
    });

    testWidgets('a stored SVG is drawn by the SVG renderer, a bitmap by the image decoder', (tester) async {
      server.pictures[_b] = Uint8List.fromList(utf8.encode(svg));
      final media = store();
      await tester.runAsync(() async {
        await media.fetch(_a);
        await media.fetch(_b);
      });
      final db = memoryDb();
      await pumpWith(
        tester,
        db,
        const Scaffold(body: Column(children: [QuizImage(id: _a), QuizImage(id: _b)])),
        overrides: [mediaStoreProvider.overrideWithValue(media)],
      );
      await settleImages(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      await tearDownUi(tester, db);
    });
  });

  group('MediaStore', () {
    test('downloads once and then serves the saved file', () async {
      final s = store();
      expect(await s.cached(_a), isNull);
      final file = await s.fetch(_a);
      expect(await file.readAsBytes(), _png);
      expect(server.requests, ['http://srv:8080/api/v1/media/$_a']);
      await s.fetch(_a);
      expect(server.requests, hasLength(1), reason: 'saved on disk');
      expect(await store().cached(_a), isNotNull, reason: 'still there after a restart');
    });

    test('concurrent requests share one download', () async {
      final s = store();
      await Future.wait([s.fetch(_a), s.fetch(_a), s.fetch(_a)]);
      expect(server.requests, hasLength(1));
    });

    test('a missing picture or server is reported, and leaves no half file', () async {
      await expectLater(store().fetch(_b), throwsA(isA<MediaException>().having((e) => e.message, 'message', contains('没有这张图片'))));
      await expectLater(store(baseUrl: '').fetch(_a), throwsA(isA<MediaException>()));
      expect(await store().cached(_b), isNull);
      expect(Directory('${dir.path}/media').listSync(), isEmpty);
    });

    test('prefetch saves what it can and skips the rest', () async {
      final s = store();
      expect(await s.prefetch([_a, _b]), 1);
      expect(await s.prefetch([_a, _b]), 0, reason: '_a is already saved; _b is still missing');
    });
  });

  testWidgets('a question shows its pictures in the stem and in an option, and opens one full size', (tester) async {
    final media = store();
    await tester.runAsync(() => media.fetch(_a));
    final db = memoryDb();
    final qs = await seedQs(db, n: 1, stem: (_) => '如图所示的类图\n\n![类图](media:$_a)');
    await tester.runAsync(() => db.customStatement(
        'UPDATE questions SET options_json = \'["![](media:$_a)","乙","丙","丁"]\''));
    final withPictures = await tester.runAsync(() => db.select(db.questions).get());

    await pumpWith(tester, db, QuizPage(title: '测试', questions: withPictures!, shuffleOptions: false),
        overrides: [mediaStoreProvider.overrideWithValue(media)]);
    await settleImages(tester);

    expect(qs, hasLength(1));
    expect(find.text('如图所示的类图'), findsOneWidget);
    expect(find.byType(QuizImage), findsNWidgets(2), reason: 'one in the stem, one in option A');
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.textContaining('media:'), findsNothing, reason: 'the reference is never shown as text');

    await tester.tap(find.byType(QuizImage).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tearDownUi(tester, db);
  });

  group('svg blocks in an answer', () {
    const svg = '<svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>';

    test('only a finished block is cut out', () {
      expect(splitSvg('前\n```svg\n$svg\n```\n后'), [('前\n', false), (svg, true), ('\n后', false)]);
      expect(splitSvg('没有图'), [('没有图', false)]);
      expect(splitSvg('写到一半\n```svg\n<svg viewBox="0 0 1 1">'), [('写到一半\n```svg\n<svg viewBox="0 0 1 1">', false)],
          reason: 'still streaming: no closing fence yet');
    });

    test('an svg without a fence, or fenced as xml, is cut out too', () {
      expect(splitSvg('前\n$svg\n后'), [('前\n', false), (svg, true), ('\n后', false)]);
      expect(splitSvg('```xml\n$svg\n```'), [(svg, true)]);
      expect(splitSvg('前\n```svg\n$svg\n\n**后**'), [('前\n', false), (svg, true), ('\n\n**后**', false)],
          reason: 'the model opened the fence and never closed it');
      const code = '```js\nconst s = "<svg></svg>"\n```';
      expect(splitSvg(code), [(code, false)], reason: 'svg shown as an example in another block stays code');
    });

    testWidgets('a plain svg is drawn, anything risky or broken is shown as code', (tester) async {
      Future<void> show(String source) async {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SvgFigure(source)))));
        await tester.pump();
      }

      await show(svg);
      expect(find.byType(SvgPicture), findsOneWidget);
      await show('<svg><script>alert(1)</script></svg>');
      expect(find.byType(SvgPicture), findsNothing);
      expect(find.textContaining('alert(1)'), findsOneWidget);
      await show('<div>hi</div>');
      expect(find.byType(SvgPicture), findsNothing);
    });
  });

  testWidgets('a picture that cannot be loaded offers a retry', (tester) async {
    final media = store();
    server.pictures.remove(_a);
    final db = memoryDb();
    await pumpWith(tester, db, const Scaffold(body: QuizImage(id: _a)), overrides: [mediaStoreProvider.overrideWithValue(media)]);
    await settleImages(tester);
    expect(find.text('服务器上没有这张图片'), findsOneWidget);

    server.pictures[_a] = _png;
    await tester.tap(find.text('重试'));
    await settleImages(tester);
    expect(find.byType(Image), findsOneWidget);
    await tearDownUi(tester, db);
  });

  group('sync', () {
    test('saves the pictures of synced questions for offline use', () async {
      final db = memoryDb();
      addTearDown(db.close);
      final api = FakeApi()
        ..published.add(QuestionDto(
          id: 'q1',
          bankId: 'b1',
          type: 'single',
          stem: '看图\n\n![](media:$_a)',
          options: const ['甲', '乙', '丙', '![](media:$_b)'],
          answer: const [0],
          explanation: '',
          difficulty: 2,
          tags: const [],
          sourceQuote: '',
          syncSeq: 1,
        ));
      server.pictures[_b] = _png;
      final media = store();

      final report = await SyncService(db, api, media: media, deviceId: 'd').run();
      expect(report.picturesDownloaded, 2);
      expect(report.summary, contains('下载了 2 张题目配图'));
      expect(await media.cached(_a), isNotNull);
      expect(await media.cached(_b), isNotNull);

      expect((await SyncService(db, api, media: media, deviceId: 'd').run()).picturesDownloaded, 0, reason: 'nothing new');
    });

    test('a picture that cannot be downloaded does not fail the sync', () async {
      final db = memoryDb();
      addTearDown(db.close);
      server.pictures.clear();
      final api = FakeApi()..published.add(_withPicture());
      final report = await SyncService(db, api, media: store(), deviceId: 'd').run();
      expect(report.questionsUpdated, 1);
      expect(report.picturesDownloaded, 0);
    });
  });
}

QuestionDto _withPicture() => QuestionDto(
      id: 'q1',
      bankId: 'b1',
      type: 'single',
      stem: '![](media:$_a)',
      options: const ['甲', '乙', '丙', '丁'],
      answer: const [0],
      explanation: '',
      difficulty: 2,
      tags: const [],
      sourceQuote: '',
      syncSeq: 1,
    );
