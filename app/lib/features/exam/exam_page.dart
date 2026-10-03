import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/progress.dart';
import '../quiz/quiz_page.dart';
import 'exam_session.dart';

/// A mock exam over [questions]: no feedback while answering, graded on hand-in.
/// Shows the result and a per-question review once it is over.
class ExamPage extends ConsumerStatefulWidget {
  const ExamPage({super.key, required this.bankId, required this.title, required this.questions, this.limitSec});

  final String bankId;
  final String title;
  final List<Question> questions;
  final int? limitSec;

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
    exam = ExamSession(
      bankId: widget.bankId,
      title: widget.title,
      questions: widget.questions,
      repo: ref.read(repositoryProvider),
      store: ref.read(examStoreProvider),
      limitSec: widget.limitSec,
    );
    if (widget.limitSec != null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
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
    await exam.submit();
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
    if (await _confirm(blank > 0 ? '还有 $blank 题没有作答，确定交卷吗？' : '确定交卷吗？', ok: '交卷')) {
      await _finish();
    }
  }

  Future<void> _quit() async {
    if (await _confirm('退出后本次考试不会保存，确定退出吗？', ok: '退出') && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: exam,
      builder: (context, _) {
        final result = exam.result;
        if (result != null) return ExamResultView(result: result);
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
                  Text('已答 ${exam.answeredCount} / ${exam.length}', style: theme.textTheme.bodySmall),
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
                      child: OutlinedButton(
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
                ],
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: exam.busy ? null : _handIn, child: const Text('交卷')),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => setState(() => _sheet = false), child: const Text('继续答题')),
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

/// Score, pass/fail, per-question marks and a review with the right answers.
class ExamResultView extends StatelessWidget {
  const ExamResultView({super.key, required this.result});

  final ExamResult result;

  String _option(Question q, int i) =>
      q.type == 'judge' ? q.options[i] : '${String.fromCharCode(65 + i)}. ${q.options[i]}';

  String _picked(ExamItem it) =>
      it.selected.isEmpty ? '未作答' : it.selected.map((i) => _option(it.question, i)).join('、');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result.record;
    final good = Colors.green.shade600;
    final color = r.passed ? good : theme.colorScheme.error;
    final secs = (r.usedMs / 1000).round();
    final missed = result.missed;
    return Scaffold(
      appBar: AppBar(title: const Text('考试结果')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${r.percent}',
                textAlign: TextAlign.center,
                style: theme.textTheme.displayLarge?.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: r.passed ? '及格' : '未及格',
                      style: TextStyle(color: color, fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: '（$passPercent 分及格）', style: theme.textTheme.bodySmall),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      _line('答对', '${r.correct} / ${r.total} 题'),
                      _line('未作答', '${r.total - r.answered} 题'),
                      _line(
                        '用时',
                        '${secs ~/ 60} 分 ${(secs % 60).toString().padLeft(2, '0')} 秒${r.limitSec == null ? '' : ' / ${(r.limitSec! / 60).round().clamp(1, 9999)} 分钟'}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < result.items.length; i++)
                    Container(
                      width: 44,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(
                          (result.items[i].correct ? good : theme.colorScheme.error).withValues(alpha: 0.14),
                          theme.colorScheme.surface,
                        ),
                        border: Border.all(color: result.items[i].correct ? good : theme.colorScheme.error),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(color: result.items[i].correct ? good : theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (missed.isNotEmpty) ...[
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) => QuizPage(title: '重做错题', questions: [for (final it in missed) it.question]),
                    ),
                  ),
                  icon: const Icon(Icons.replay),
                  label: Text('重做错题 (${missed.length})'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
              const SizedBox(height: 20),
              Text('逐题解析', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (var i = 0; i < result.items.length; i++)
                _ReviewTile(
                  index: i,
                  item: result.items[i],
                  picked: _picked(result.items[i]),
                  answer: result.items[i].question.answer.map((a) => _option(result.items[i].question, a)).join('、'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label), Text(value)]),
  );
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.index, required this.item, required this.picked, required this.answer});

  final int index;
  final ExamItem item;
  final String picked;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = item.question;
    final ok = item.correct;
    final color = ok ? Colors.green.shade600 : theme.colorScheme.error;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(ok ? Icons.check_circle : Icons.cancel, color: color),
        title: Text('${index + 1}. ${q.stem}', maxLines: 2, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(data: q.stem, selectable: true),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '你的答案：'),
                TextSpan(
                  text: picked,
                  style: TextStyle(color: color),
                ),
              ],
            ),
          ),
          if (!ok)
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '正确答案：'),
                  TextSpan(
                    text: answer,
                    style: TextStyle(color: Colors.green.shade600),
                  ),
                ],
              ),
            ),
          if (q.explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            MarkdownBody(data: q.explanation, selectable: true),
          ],
          if (q.sourceQuote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
              ),
              padding: const EdgeInsets.only(left: 10),
              child: Text('原文：${q.sourceQuote}', style: theme.textTheme.bodySmall),
            ),
          ],
        ],
      ),
    );
  }
}
