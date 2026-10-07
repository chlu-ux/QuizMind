import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import 'lesson_style.dart';
import 'lesson_widgets.dart';
import 'lessons.dart';
import 'quiz_page.dart';
import 'quiz_session.dart';

/// One section of the study text to read, with its questions one tap away and the neighbouring sections to either side.
class LessonPage extends ConsumerStatefulWidget {
  const LessonPage({super.key, required this.bank, required this.lessonId});

  final Bank bank;
  final String lessonId;

  @override
  ConsumerState<LessonPage> createState() => _LessonPageState();
}

class _LessonPageState extends ConsumerState<LessonPage> {
  Lesson? _lesson;
  String _chapter = '';
  Lesson? _prev;
  Lesson? _next;
  List<Question> _questions = const [];
  LessonProgress? _progress;
  bool _read = false;
  bool _loaded = false;

  /// 背诵遮盖: sentences are blurred until tapped.
  bool _cover = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final all = await repo.lessons(widget.bank.id);
    final at = all.indexWhere((l) => l.id == widget.lessonId);
    Lesson? lesson;
    LessonProgress? progress;
    var questions = const <Question>[];
    var read = false;
    var chapter = '';
    if (at >= 0) {
      lesson = all[at];
      questions = lessonQuestions(lesson.id, await repo.bankQuestions(widget.bank.id));
      final reads = await repo.lessonReadIds(widget.bank.id);
      read = reads.contains(lesson.id);
      progress = lessonProgress([lesson], questions, await repo.bankAttempts(widget.bank.id), reads)[lesson.id];
      chapter = groupChapters(all).firstWhere((c) => c.id == lesson!.documentId).title;
    }
    if (!mounted) return;
    setState(() {
      _lesson = lesson;
      // Neighbours within the reading order of the whole bank, so the last section of a chapter leads on to the next chapter.
      _prev = at > 0 ? all[at - 1] : null;
      _next = at >= 0 && at + 1 < all.length ? all[at + 1] : null;
      _chapter = chapter;
      _questions = questions;
      _progress = progress;
      _read = read;
      _loaded = true;
    });
  }

  Future<void> _setRead(bool value) async {
    final l = _lesson;
    if (l == null) return;
    final repo = ref.read(repositoryProvider);
    if (value) {
      await repo.markLessonRead(l);
    } else {
      await repo.unmarkLessonRead(l.id);
    }
    if (mounted) _load();
  }

  /// The quiz over this section's questions, in random order. Like practice by knowledge point it is a
  /// one-off: not saved, so it never replaces the bank's "continue last round".
  Future<void> _practise() async {
    final l = _lesson;
    if (l == null) return;
    await _setRead(true);
    if (!mounted) return;
    await startQuiz(context, title: '本节 · ${lessonTitle(l)}', questions: orderQuestions(_questions, QuizOrder.random));
    if (mounted) _load();
  }

  /// Marks this section read and moves to [to]; the back button then returns to where this page was opened from.
  Future<void> _go(Lesson? to) async {
    if (to == null) return;
    await _setRead(true);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => LessonPage(bank: widget.bank, lessonId: to.id)),
    );
  }

  Future<void> _done() async {
    if (_next != null) return _go(_next);
    await _setRead(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lesson = _lesson;
    return Scaffold(
      appBar: AppBar(
        title: Text(lesson == null ? '讲义' : lessonTitle(lesson), maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          if (lesson != null)
            TextButton(
              key: const ValueKey('cover-toggle'),
              onPressed: () => setState(() => _cover = !_cover),
              child: Text(_cover ? '显示全部' : '背诵遮盖'),
            ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : lesson == null
              ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('这一节不存在，可能讲义已更新')))
              : SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        children: [
                          Row(children: [
                            Expanded(child: Text(_chapter, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            LessonStateTag(_progress?.state ?? LessonState.unread),
                          ]),
                          const SizedBox(height: 8),
                          if (_cover) ...[
                            Text('点一句话显示它，先自己回忆再看', style: theme.textTheme.bodySmall),
                            const SizedBox(height: 8),
                          ],
                          LessonBody(text: lesson.body, cover: _cover),
                          if (_questions.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Text(
                                  '本节 ${_questions.length} 题 · 做过 ${_progress?.answered ?? 0}'
                                  '${_progress?.accuracy == null ? '' : ' · 最近一次正确率 ${_progress!.accuracy}%'}',
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (_questions.isNotEmpty)
                            FilledButton(
                              key: const ValueKey('practise-lesson'),
                              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                              onPressed: _practise,
                              child: Text('学完了，做这一节的 ${_questions.length} 道题'),
                            )
                          else
                            FilledButton(
                              key: const ValueKey('lesson-done'),
                              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                              onPressed: _done,
                              child: Text(_next != null ? '学完了，下一节' : '学完了'),
                            ),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey('prev-lesson'),
                                onPressed: _prev == null ? null : () => _go(_prev),
                                child: const Text('‹ 上一节'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey('next-lesson'),
                                onPressed: _next == null ? null : () => _go(_next),
                                child: const Text('下一节 ›'),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          TextButton(
                            key: const ValueKey('toggle-read'),
                            onPressed: () => _setRead(!_read),
                            child: Text(_read ? '✓ 已读（点此取消）' : '标记为已读'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}
