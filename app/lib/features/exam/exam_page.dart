import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/exam_store.dart';
import 'exam_result_view.dart';
import 'exam_session.dart';

/// A mock exam over [questions]: no feedback while answering, graded on hand-in.
/// Shows the result and a per-question review once it is over. Progress is saved as
/// it goes; pass the saved [draft] (with the questions that still exist) to pick an
/// unfinished exam up again.
class ExamPage extends ConsumerStatefulWidget {
  const ExamPage({
    super.key,
    required this.bankId,
    required this.title,
    required this.questions,
    this.limitSec,
    this.draft,
  });

  final String bankId;
  final String title;
  final List<Question> questions;
  final int? limitSec;
  final ExamDraft? draft;

  @override
  ConsumerState<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends ConsumerState<ExamPage> {
  late final ExamSession exam;
  late final SyncController _sync;
  Timer? _ticker;
  bool _sheet = false;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(syncProvider.notifier);
    final repo = ref.read(repositoryProvider);
    final draft = widget.draft;
    exam =
        (draft == null ? null : ExamSession.restore(draft, widget.questions, repo)) ??
        ExamSession(
          bankId: widget.bankId,
          title: widget.title,
          questions: widget.questions,
          repo: repo,
          limitSec: widget.limitSec,
        );
    exam.save(); // so a kill before the first answer still finds it
    if (exam.limitSec != null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
      if (exam.remainingSec() == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('考试时间已到，已按现有答案交卷')));
          unawaited(_finish());
        });
      }
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (exam.remainingSec() == 0 && !exam.submitted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('时间到，已自动交卷')));
      unawaited(_finish());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    exam.dispose();
    // Push what was answered while the learner is likely still online.
    Future.microtask(_sync.run);
    super.dispose();
  }

  Future<void> _finish() async {
    try {
      await exam.submit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('交卷失败：$e，请再试一次')));
      }
      return;
    }
    _ticker?.cancel();
    if (mounted) setState(() => _sheet = false);
  }

  Future<bool> _confirm(String message, {String ok = '确定'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(ok)),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _handIn() async {
    final blank = exam.length - exam.answeredCount;
    final notes = [
      if (blank > 0) '还有 $blank 题没有作答',
      if (exam.markedCount > 0) '有 ${exam.markedCount} 题标记了待检查',
    ];
    if (await _confirm(notes.isEmpty ? '确定交卷吗？' : '${notes.join('，')}，确定交卷吗？', ok: '交卷')) {
      await _finish();
    }
  }

  /// Leaving keeps the progress (resume from the exam setup page); only a timed exam asks first,
  /// because its clock keeps running.
  Future<void> _quit() async {
    if (exam.limitSec != null &&
        !await _confirm('退出后进度会保留，可以回到「模拟考试」继续，但限时考试的计时不会暂停。确定退出吗？', ok: '退出')) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _abandon() async {
    if (!await _confirm('放弃这次考试？已作的答案不会保存，也不计入统计。', ok: '放弃')) return;
    exam.dispose();
    await ref.read(repositoryProvider).clearExamDraft(exam.bankId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: exam,
      builder: (context, _) {
        final result = exam.result;
        if (result != null) return ExamResultView(record: result.record, entries: result.entries);
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _quit();
          },
          child: CallbackShortcuts(
            bindings: {
              for (var i = 0; i < 4; i++)
                SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i)): () => exam.selectAt(i),
              const SingleActivator(LogicalKeyboardKey.arrowRight): exam.next,
              const SingleActivator(LogicalKeyboardKey.keyJ): exam.next,
              const SingleActivator(LogicalKeyboardKey.arrowLeft): exam.previous,
              const SingleActivator(LogicalKeyboardKey.keyK): exam.previous,
              const SingleActivator(LogicalKeyboardKey.keyM): exam.toggleMark,
            },
            child: Focus(autofocus: true, child: _sheet ? _buildSheet(context) : _buildQuestion(context)),
          ),
        );
      },
    );
  }

  String? get _clock {
    final r = exam.remainingSec();
    if (r == null) return null;
    return '${r ~/ 60}:${(r % 60).toString().padLeft(2, '0')}';
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = exam.remainingSec();
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), tooltip: '退出考试', onPressed: _quit),
      title: Text('模拟考试 · ${exam.index + 1}/${exam.length}'),
      actions: [
        if (_clock case final clock?)
          Center(
            child: Text(
              '⏱ $clock',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: (remaining ?? 99) <= 60 ? theme.colorScheme.error : null,
              ),
            ),
          ),
        TextButton(onPressed: exam.busy ? null : _handIn, child: const Text('交卷')),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(3),
        child: LinearProgressIndicator(value: exam.answeredCount / exam.length),
      ),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _appBar(context),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Text('答题卡', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    '已答 ${exam.answeredCount} / ${exam.length}${exam.markedCount > 0 ? ' · 待检查 ${exam.markedCount}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < exam.length; i++)
                    SizedBox(
                      width: 52,
                      height: 44,
                      child: Badge(
                        isLabelVisible: exam.isMarked(i),
                        label: const Icon(Icons.flag, size: 10),
                        backgroundColor: Colors.amber.shade700,
                        child: SizedBox.expand(
                          child: OutlinedButton(
                            key: ValueKey('sheet-$i'),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              backgroundColor: exam.isAnswered(i) ? theme.colorScheme.primaryContainer : null,
                              side: BorderSide(
                                width: i == exam.index ? 2 : 1,
                                color: i == exam.index ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant,
                              ),
                            ),
                            onPressed: () {
                              exam.go(i);
                              setState(() => _sheet = false);
                            },
                            child: Text('${i + 1}'),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text('蓝底 = 已答，旗标 = 待检查', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              FilledButton(onPressed: exam.busy ? null : _handIn, child: const Text('交卷')),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => setState(() => _sheet = false), child: const Text('继续答题')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: exam.busy ? null : _abandon,
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                child: const Text('放弃本次考试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context) {
    final theme = Theme.of(context);
    final q = exam.current;
    return Scaffold(
      appBar: _appBar(context),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(
                  children: [
                    Chip(label: Text(q.type == 'judge' ? '判断题' : '单选题'), visualDensity: VisualDensity.compact),
                    const Spacer(),
                    FilterChip(
                      avatar: Icon(Icons.flag, size: 16, color: exam.isMarked(exam.index) ? Colors.amber.shade800 : null),
                      label: Text(exam.isMarked(exam.index) ? '已标记待检查' : '标记待检查'),
                      selected: exam.isMarked(exam.index),
                      onSelected: (_) => exam.toggleMark(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                MarkdownBody(
                  data: q.stem,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme)
                      .copyWith(p: theme.textTheme.titleMedium?.copyWith(height: 1.5)),
                ),
                const SizedBox(height: 16),
                for (final opt in exam.displayOptions)
                  _ExamOption(
                    label: exam.labelOf(opt.original),
                    text: opt.text,
                    selected: exam.selected.contains(opt.original),
                    onTap: () => exam.select(opt.original),
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Row(
                children: [
                  OutlinedButton(onPressed: exam.index > 0 ? exam.previous : null, child: const Text('上一题')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => setState(() => _sheet = true), child: const Text('答题卡')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: exam.index < exam.length - 1
                        ? FilledButton(onPressed: exam.next, child: const Text('下一题'))
                        : FilledButton(onPressed: exam.busy ? null : _handIn, child: const Text('交卷')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExamOption extends StatelessWidget {
  const _ExamOption({required this.label, required this.text, required this.selected, required this.onTap});

  final String label;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = selected ? scheme.primary : scheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: selected ? scheme.primary : scheme.surfaceContainerHighest,
                  foregroundColor: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
