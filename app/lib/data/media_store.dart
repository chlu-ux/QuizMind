import 'dart:io';

import 'package:dio/dio.dart';

/// Whether [b] is an SVG document: an optional BOM, XML declaration and comments, then `<svg`.
bool isSvg(List<int> b) {
  final head = String.fromCharCodes(b.length > 2048 ? b.sublist(0, 2048) : b);
  return RegExp(r'^\s*(?:\uFEFF)?\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--[\s\S]*?-->\s*)*<svg[\s>]').hasMatch(head);
}

/// The MIME type of a picture, from its first bytes (PNG when nothing else matches).
String imageMime(List<int> b) {
  if (isSvg(b)) return 'image/svg+xml';
  if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
  if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
  if (b.length > 11 && String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return 'image/png';
}

/// Thrown when a picture cannot be had; [message] is safe to show to the user.
class MediaException implements Exception {
  MediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The pictures of questions, kept on disk so they show offline. A picture's id is a hash of its
/// content, so a file never goes stale and is downloaded once.
class MediaStore {
  MediaStore({required this.baseUrl, required Future<Directory> Function() directory, Dio? dio})
    : _directory = directory,
      _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 30)));

  final String baseUrl;
  final Future<Directory> Function() _directory;
  final Dio _dio;
  final _inflight = <String, Future<File>>{};
  Directory? _dir;

  Future<Directory> _folder() async {
    final cached = _dir;
    if (cached != null) return cached;
    final dir = Directory('${(await _directory()).path}/media');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  /// The downloaded file, or null if this picture has not been fetched yet.
  Future<File?> cached(String id) async {
    final file = File('${(await _folder()).path}/$id');
    return await file.exists() && await file.length() > 0 ? file : null;
  }

  /// The picture's file, downloading it first if needed. Concurrent calls share one download.
  Future<File> fetch(String id) {
    final running = _inflight[id];
    if (running != null) return running;
    final job = _download(id).whenComplete(() {
      // A block body: returning the removed future would make whenComplete wait for itself.
      _inflight.remove(id);
    });
    return _inflight[id] = job;
  }

  Future<File> _download(String id) async {
    final have = await cached(id);
    if (have != null) return have;
    if (baseUrl.isEmpty) throw MediaException('还没有填写服务器地址，无法加载图片');
    final file = File('${(await _folder()).path}/$id');
    final part = File('${file.path}.part');
    try {
      await _dio.download('$baseUrl/api/v1/media/$id', part.path);
      await part.rename(file.path);
    } on DioException catch (e) {
      if (await part.exists()) await part.delete();
      throw MediaException(e.response?.statusCode == 404 ? '服务器上没有这张图片' : '图片下载失败，联网后重试');
    }
    return file;
  }

  /// Downloads whichever of [ids] are missing, a few at a time. Pictures that cannot be fetched
  /// are skipped (they load on demand later). Returns how many were downloaded.
  Future<int> prefetch(Iterable<String> ids, {int concurrency = 3}) async {
    final todo = <String>[];
    for (final id in ids) {
      if (await cached(id) == null) todo.add(id);
    }
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final id = todo[next++];
        try {
          await fetch(id);
          done++;
        } on MediaException {
          // Offline or removed: shown on demand, with a retry.
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    return done;
  }
}
