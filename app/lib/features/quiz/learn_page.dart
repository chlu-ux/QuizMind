import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import 'lesson_page.dart';
import 'lesson_style.dart';
import 'lessons.dart';

/// 先学后练: the study text of one bank by chapter, with how far the learner has got in each section.
/// Tapping a section opens it to read, and from there its own questions are one tap away.
class LearnPage extends ConsumerStatefulWidget {
  const LearnPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<LearnPage> createState() => _LearnPageState();
}

class _LearnPageState extends ConsumerState<LearnPage> {
  List<Lesson> _lessons = const [];
  Map<String, LessonProgress> _progress = const {};
  bool _loaded = false;

  /// Chapters the reader opened or closed by hand; the rest are closed, except the one holding the next section to study.
  final Map<String, bool> _forced = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final lessons = await repo.lessons(widget.bank.id);
    final progress = lessonProgress(
      lessons,
      await repo.bankQuestions(widget.bank.id),
      await repo.bankAttempts(widget.bank.id),
      await repo.lessonReadIds(widget.bank.id),
    );
    if (!mounted) return;
    setState(() {
      _lessons = lessons;
      _progress = progress;
      _loaded = true;
    });
  }

  Future<void> _open(Lesson l) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LessonPage(bank: widget.bank, lessonId: l.id)));
    if (mounted) _load();
  }

  bool _isOpen(Chapter c, Lesson? next) => _forced[c.id] ?? (next != null && c.lessons.any((l) => l.id == next.id));

  @override
  Widget build(BuildContext context) {
    // A sync that brought new study text re-reads the bank rows.
    ref.listen(banksProvider, (_, _) => _load());
    return Scaffold(
      appBar: AppBar(title: Text('学习 · ${widget.bank.title}')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _lessons.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('这个题库还没有讲义。同步一次试试，或在管理后台上传文档。', textAlign: TextAlign.center),
                  ),
                )
              : _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = groupChapters(_lessons);
    final next = nextToStudy(_lessons, _progress);
    final read = _lessons.where((l) => _progress[l.id]?.read ?? false).length;
    final mastered = _lessons.where((l) => _progress[l.id]?.state == LessonState.mastered).length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('已读 $read / ${_lessons.length} 节 · 已掌握 $mastered 节', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: read / _lessons.length, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 8),
                  Text(
                    '先读讲义，再做这一节的题；做过至少 $masterMinAnswered 题（不足 $masterMinAnswered 题则全部做完）且最近一次正确率达到 $masterMinAccuracy%，算「已掌握」',
                    style: theme.textTheme.bodySmall,
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            if (next != null)
              FilledButton.icon(
                key: const ValueKey('continue-learning'),
                icon: const Icon(Icons.play_arrow),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                onPressed: () => _open(next),
                label: Text(
                  '${(_progress[next.id]?.read ?? false) ? '继续巩固' : read == 0 ? '开始学习' : '继续学习'} · ${lessonTitle(next)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              Center(child: Text('所有小节都已读完并掌握 🎉', style: theme.textTheme.bodyMedium)),
            const SizedBox(height: 8),
            for (final c in chapters) ..._chapter(context, c, next),
          ],
        ),
      ),
    );
  }

  List<Widget> _chapter(BuildContext context, Chapter c, Lesson? next) {
    final theme = Theme.of(context);
    final open = _isOpen(c, next);
    final read = c.lessons.where((l) => _progress[l.id]?.read ?? false).length;
    final mastered = c.lessons.where((l) => _progress[l.id]?.state == LessonState.mastered).length;
    return [
      InkWell(
        key: ValueKey('chapter-${c.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _forced[c.id] = !open),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right),
            const SizedBox(width: 4),
            Expanded(child: Text(c.title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text('$read/${c.lessons.length} · 掌握 $mastered', style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
      if (open)
        for (final l in c.lessons) _lessonRow(context, l),
    ];
  }

  Widget _lessonRow(BuildContext context, Lesson l) {
    final p = _progress[l.id];
    final detail = p == null || p.total == 0
        ? '没有配套的题'
        : '${p.total} 题 · 做过 ${p.answered}${p.accuracy == null ? '' : ' · 正确率 ${p.accuracy}%'}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        key: ValueKey('lesson-${l.id}'),
        title: Text(lessonTitle(l), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(detail),
        trailing: LessonStateTag(p?.state ?? LessonState.unread),
        onTap: () => _open(l),
      ),
    );
  }
}
