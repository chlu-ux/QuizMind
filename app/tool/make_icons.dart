// Renders the QuizMind icon to PNG files. Run from app/:
//
//   flutter test tool/make_icons.dart
//
// It uses Flutter's own rasteriser, so no image tools are needed. The geometry
// is the same as in icon.svg and the Android vector drawables
// (android/app/src/main/res/drawable/ic_launcher_*.xml); keep the three in step.
//
// Writes: the legacy launcher PNGs for Android (pre-8.0 devices), and the web
// app icons in ../h5/public.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// The design lives on a 108 x 108 canvas, the size of an Android adaptive icon
// layer. Only the central 72 x 72 is always visible, so the glyph stays inside it.
const _background = ui.Color(0xFF0E6B58);
const _ring = ui.Color(0xFFFFFFFF);
const _check = ui.Color(0xFFFFC94A);

const _centre = ui.Offset(54, 54);
const _ringRadius = 20.0;
const _ringStroke = 6.5;
// The ring is open between these angles (degrees, clockwise from 3 o'clock) so
// the check mark can leave it.
const _gapStart = -8.0;
const _gapEnd = -72.0;
const _checkStroke = 7.5;

/// Draws the glyph on the 108-unit canvas.
void _drawGlyph(ui.Canvas canvas) {
  double rad(double deg) => deg * math.pi / 180;
  final ring = ui.Paint()
    ..color = _ring
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = _ringStroke
    ..strokeCap = ui.StrokeCap.round
    ..isAntiAlias = true;
  // From the end of the gap round the long way to its start: 360 - 64 degrees.
  canvas.drawArc(
    ui.Rect.fromCircle(center: _centre, radius: _ringRadius),
    rad(_gapStart),
    rad(360 - (_gapStart - _gapEnd)),
    false,
    ring,
  );
  final check = ui.Paint()
    ..color = _check
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = _checkStroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..isAntiAlias = true;
  canvas.drawPath(
    ui.Path()
      ..moveTo(44, 56)
      ..lineTo(52, 64)
      ..lineTo(73, 39),
    check,
  );
}

/// A [size] x [size] PNG: the glyph on the brand colour, showing the central
/// 72 x 72 of the canvas. [corner] is the corner radius as a fraction of the
/// size (0 for a full-bleed square).
Future<List<int>> _render(int size, {required double corner}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final s = size / 72.0;
  canvas.scale(s);
  canvas.translate(-18, -18);
  final bg = ui.Paint()
    ..color = _background
    ..isAntiAlias = true;
  final r = 72 * corner;
  canvas.drawRRect(ui.RRect.fromRectXY(const ui.Rect.fromLTWH(18, 18, 72, 72), r, r), bg);
  _drawGlyph(canvas);
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('render icons', (tester) async {
    final out = <String, ({int size, double corner})>{
      // Android legacy launcher icons (adaptive icons are the vector drawables).
      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': (size: 48, corner: 0.22),
      'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': (size: 72, corner: 0.22),
      'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': (size: 96, corner: 0.22),
      'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': (size: 144, corner: 0.22),
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': (size: 192, corner: 0.22),
      // Web app (H5). Full-bleed so the OS can apply its own mask.
      '../h5/public/icon-192.png': (size: 192, corner: 0),
      '../h5/public/icon-512.png': (size: 512, corner: 0),
      '../h5/public/apple-touch-icon.png': (size: 180, corner: 0),
    };
    await tester.runAsync(() async {
      for (final e in out.entries) {
        final bytes = await _render(e.value.size, corner: e.value.corner);
        await File(e.key).writeAsBytes(bytes);
      }
      // A large preview for looking at the design; not shipped.
      await File('tool/icon-preview.png').writeAsBytes(await _render(1024, corner: 0.22));
    });
  });
}
