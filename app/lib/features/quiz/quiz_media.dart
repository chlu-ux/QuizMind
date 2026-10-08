import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/providers.dart';
import '../../data/media_store.dart';
import '../../data/media_text.dart';

/// An `<svg>` element (group 1), with the fence around it if it has one: models leave the fence off, or
/// open it and forget to close it. Or else any other fenced block, matched only to be skipped. A diagram
/// that is still being written has no `</svg>` yet and stays ordinary text until it is complete.
final _svgPiece = RegExp(
  r'(?:```[ \t]*(?:svg|xml|html)?[ \t]*\r?\n\s*)?(<svg[\s>][\s\S]*?</svg>)(?:\s*```[ \t]*(?=\r?\n|$))?|```[^\n]*\n[\s\S]*?```',
);

/// Where to cut [text] to draw its complete SVG diagrams as pictures: alternating Markdown and SVG
/// source (the SVG pieces are the ones for which the second value is true). Other code blocks are left
/// alone, so SVG source shown as an example in them stays code.
List<(String, bool)> splitSvg(String text) {
  final out = <(String, bool)>[];
  var last = 0;
  for (final m in _svgPiece.allMatches(text)) {
    final svg = m[1];
    if (svg == null) continue;
    if (m.start > last) out.add((text.substring(last, m.start), false));
    out.add((svg, true));
    last = m.end;
  }
  if (last < text.length) out.add((text.substring(last), false));
  return out;
}

/// Markdown of a question (stem or explanation) or of an AI answer. `media:<id>` pictures come from the
/// device's picture store, downloading on demand, and complete ```svg blocks are drawn.
class QuizMarkdown extends ConsumerWidget {
  const QuizMarkdown(this.data, {super.key, this.selectable = true, this.styleSheet, this.onTapLink});

  final String data;
  final bool selectable;
  final MarkdownStyleSheet? styleSheet;

  /// Called with the target of a tapped link; without it links are not tappable.
  final void Function(String? href)? onTapLink;

  Widget _markdown(String text) => MarkdownBody(
    data: text,
    selectable: selectable,
    styleSheet: styleSheet,
    onTapLink: onTapLink == null ? null : (text, href, title) => onTapLink!(href),
    imageBuilder: (uri, title, alt) {
      if (uri.scheme == 'media') {
        return QuizImage(id: uri.path, alt: alt ?? '');
      }
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        return Image.network(uri.toString(), errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined));
      }
      return const SizedBox.shrink();
    },
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = splitSvg(data);
    if (parts.every((p) => !p.$2)) return _markdown(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (text, isSvg) in parts)
          if (isSvg) SvgFigure(text) else if (text.trim().isNotEmpty) _markdown(text),
      ],
    );
  }
}

/// A diagram the model drew as SVG. Anything that is not a plain, reasonably small SVG is shown as code
/// instead: scripts never run in an image, but there is no reason to feed them to the renderer.
class SvgFigure extends StatelessWidget {
  const SvgFigure(this.source, {super.key});

  final String source;

  static const _maxChars = 60000;

  bool get _drawable {
    final s = source.trim();
    return s.startsWith('<svg') &&
        s.endsWith('</svg>') &&
        s.length <= _maxChars &&
        !RegExp(r'<(script|foreignObject|image)\b', caseSensitive: false).hasMatch(s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget code() => Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(source, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
    if (!_drawable) return code();
    return Semantics(
      image: true,
      label: 'AI 绘制的示意图',
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: SvgPicture.string(
          source.trim(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => code(),
          placeholderBuilder: (_) => const SizedBox(height: 40, child: Center(child: Text('正在绘图…'))),
        ),
      ),
    );
  }
}

/// An option's text, with any pictures in it drawn in place.
class OptionText extends StatelessWidget {
  const OptionText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = splitPictures(text);
    if (parts.every((p) => p is PlainPart)) return Text(text, style: style);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in parts)
          switch (p) {
            PlainPart(:final text) => Text(text, style: style),
            PicturePart(:final id, :final alt) => QuizImage(id: id, alt: alt),
          },
      ],
    );
  }
}

/// One picture of a question: shows a spinner while it downloads, a retry button if it cannot,
/// and opens full size (pinch to zoom) when tapped.
class QuizImage extends ConsumerStatefulWidget {
  const QuizImage({super.key, required this.id, this.alt = ''});

  final String id;
  final String alt;

  @override
  ConsumerState<QuizImage> createState() => _QuizImageState();
}

class _QuizImageState extends ConsumerState<QuizImage> {
  late Future<File> _file;

  @override
  void initState() {
    super.initState();
    _file = ref.read(mediaStoreProvider).fetch(widget.id);
  }

  @override
  void didUpdateWidget(QuizImage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _retry();
  }

  void _retry() {
    final file = ref.read(mediaStoreProvider).fetch(widget.id);
    setState(() {
      _file = file;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _file,
      builder: (context, snap) {
        if (snap.hasError) {
          final message = snap.error is MediaException ? (snap.error! as MediaException).message : '图片加载失败';
          return _frame(
            context,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined),
                const SizedBox(width: 8),
                Flexible(child: Text(message)),
                TextButton(onPressed: _retry, child: const Text('重试')),
              ],
            ),
          );
        }
        final file = snap.data;
        if (file == null) {
          return _frame(
            context,
            child: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _FullImage(file: file, alt: widget.alt),
            ),
          ),
          child: Semantics(
            image: true,
            label: widget.alt.isEmpty ? '题目配图' : widget.alt,
            // Diagrams are usually transparent line drawings made for a white page.
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: _PictureFile(file),
            ),
          ),
        );
      },
    );
  }

  Widget _frame(BuildContext context, {required Widget child}) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.all(14),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );
}

/// A stored picture: an SVG diagram is drawn by the SVG renderer, anything else by the image decoder.
/// Which one is told by the content, as on the server (a picture's id is a hash, not a file name).
class _PictureFile extends StatefulWidget {
  const _PictureFile(this.file, {this.fit = BoxFit.contain});

  final File file;
  final BoxFit fit;

  @override
  State<_PictureFile> createState() => _PictureFileState();
}

class _PictureFileState extends State<_PictureFile> {
  late Future<bool> _svg = _sniff();

  Future<bool> _sniff() async => isSvg(await widget.file.openRead(0, 2048).expand((c) => c).toList());

  @override
  void didUpdateWidget(_PictureFile old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) _svg = _sniff();
  }

  @override
  Widget build(BuildContext context) {
    const broken = Icon(Icons.broken_image_outlined);
    return FutureBuilder<bool>(
      future: _svg,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 40);
        if (snap.data!) {
          return SvgPicture.file(widget.file, fit: widget.fit, errorBuilder: (_, _, _) => broken);
        }
        return Image.file(widget.file, fit: widget.fit, errorBuilder: (_, _, _) => broken);
      },
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.file, required this.alt});

  final File file;
  final String alt;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(alt)),
      body: Center(
        child: InteractiveViewer(
          maxScale: 8,
          child: Container(color: Colors.white, child: _PictureFile(file, fit: BoxFit.fitWidth)),
        ),
      ),
    );
  }
}
