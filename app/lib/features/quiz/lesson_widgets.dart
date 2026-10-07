import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import 'lessons.dart';
import 'quiz_media.dart';

/// The text of one section: prose a sentence to a line (a dense paragraph is easier to read that way),
/// lists, tables, code and pictures as they are. With [cover] every sentence is blurred and shows when
/// tapped, to recall it before looking.
class LessonBody extends StatefulWidget {
  const LessonBody({super.key, required this.text, this.cover = false});

  final String text;
  final bool cover;

  @override
  State<LessonBody> createState() => _LessonBodyState();
}

class _LessonBodyState extends State<LessonBody> {
  late List<LessonBlock> _blocks = lessonBlocks(widget.text);

  /// Sentences uncovered so far, as "block/sentence"; reset whenever the text or the mode changes.
  Set<String> _shown = {};

  @override
  void didUpdateWidget(LessonBody old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _blocks = lessonBlocks(widget.text);
    if (old.text != widget.text || old.cover != widget.cover) _shown = {};
  }

  void _toggle(String key) {
    if (!widget.cover) return;
    setState(() => _shown = _shown.contains(key) ? ({..._shown}..remove(key)) : {..._shown, key});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _blocks.length; i++)
          if (_blocks[i].sentences case final sentences?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < sentences.length; j++) _sentence('$i/$j', sentences[j]),
                ],
              ),
            )
          else
            QuizMarkdown(_blocks[i].source, selectable: !widget.cover),
      ],
    );
  }

  Widget _sentence(String key, String text) {
    final covered = widget.cover && !_shown.contains(key);
    final child = ImageFiltered(
      enabled: covered,
      imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6, tileMode: TileMode.decal),
      child: IgnorePointer(ignoring: widget.cover, child: QuizMarkdown(text, selectable: !widget.cover)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: widget.cover
          ? InkWell(
              key: ValueKey('sentence-$key'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => _toggle(key),
              child: Semantics(label: covered ? '已遮盖，点按显示' : null, child: child),
            )
          : child,
    );
  }
}

/// Opens [lesson] in a sheet over the current page, so a quiz is not left to read it.
Future<void> showLessonSheet(BuildContext context, Lesson lesson) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        key: const ValueKey('lesson-sheet'),
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(lessonTitle(lesson), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          LessonBody(text: lesson.body),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
        ],
      ),
    ),
  );
}

/// "看这一节讲义" under an answered question: the section the question was generated from, if this
/// device has it. Shows nothing for a question without one.
class LessonLink extends ConsumerStatefulWidget {
  const LessonLink({super.key, required this.chunkId});

  final String chunkId;

  @override
  ConsumerState<LessonLink> createState() => _LessonLinkState();
}

class _LessonLinkState extends ConsumerState<LessonLink> {
  Future<Lesson?>? _lesson;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LessonLink old) {
    super.didUpdateWidget(old);
    if (old.chunkId != widget.chunkId) _load();
  }

  void _load() {
    _lesson = widget.chunkId.isEmpty ? null : ref.read(repositoryProvider).lesson(widget.chunkId);
  }

  @override
  Widget build(BuildContext context) {
    final future = _lesson;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<Lesson?>(
      future: future,
      builder: (context, snap) {
        final lesson = snap.data;
        if (lesson == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('open-lesson'),
              icon: const Icon(Icons.auto_stories_outlined),
              label: const Text('看这一节讲义'),
              onPressed: () => showLessonSheet(context, lesson),
            ),
          ),
        );
      },
    );
  }
}
