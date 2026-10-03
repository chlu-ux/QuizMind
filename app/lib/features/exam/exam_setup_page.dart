import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/exam_store.dart';
import '../../data/models.dart';
import 'exam_page.dart';
import 'exam_review_page.dart';
import 'exam_session.dart';

/// Picks how a mock exam is put together (strategy, topics, size, time), picks up an
/// unfinished one, and lists the earlier ones.
class ExamSetupPage extends ConsumerStatefulWidget {
  const ExamSetupPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<ExamSetupPage> createState() => _ExamSetupPageState();
}

class _ExamSetupPageState extends ConsumerState<ExamSetupPage> {
  /// Seconds per question; null = no time limit.
  static const _paces = <(String, int?)>[('每题 30 秒', 30), ('每题 1 分钟', 60), ('每题 2 分钟', 120), ('不限时', null)];

  late Future<List<Question>> _questions;
  List<ExamRecord> _history = const [];
  ExamDraft? _draft;
  int? _count;
  int? _pace = 60;
  PaperStrategy _strategy = PaperStrategy.random;
  final Set<String> _topics = {};

  @override
  void initState() {
    super.initState();
    _questions = ref.read(repositoryProvider).bankQuestions(widget.bank.id);
    _reload();
  }

  Future<void> _reload() async {
    final repo = ref.read(repositoryProvider);
    final history = await repo.exams(widget.bank.id);
    final draft = await repo.examDraft(widget.bank.id);
    if (mounted) {
      setState(() {
        _history = history;
        _draft = draft;
      });
    }
  }

  int? _limit(int count) => _pace == null ? null : _pace! * count;

  String _limitText(int count) {
    final sec = _limit(count);
    if (sec == null) return '不限时';
    final m = (sec / 60).round();
    return m >= 1 ? '$m 分钟' : '$sec 秒';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.bank.title} · 模拟考试')),
      body: FutureBuilder<List<Question>>(
        future: _questions,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          if (all.isEmpty) return const Center(child: Text('这个题库还没有题目'));
          final topics = paperTags(all);
          final pool = paperPool(all, _topics);
          final choices = pool.isEmpty ? <int>[] : examCountChoices(pool.length);
          final count = choices.contains(_count) ? _count! : (choices.contains(20) ? 20 : (choices.firstOrNull ?? 0));
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_draft case final draft?) ...[_ResumeCard(draft: draft, onResume: _resume, onDiscard: _discard)],
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('出卷方式', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in PaperStrategy.values)
                                ChoiceChip(
                                  label: Text(s.label),
                                  selected: _strategy == s,
                                  onSelected: (_) => setState(() => _strategy = s),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(_strategy.hint, style: theme.textTheme.bodySmall),
                          if (topics.length > 1) ...[
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Text('知识点', style: theme.textTheme.titleSmall),
                                const Spacer(),
                                if (_topics.isNotEmpty)
                                  TextButton(onPressed: () => setState(_topics.clear), child: Text('清除（${_topics.length}）')),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 168),
                              child: SingleChildScrollView(
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    ChoiceChip(
                                      label: const Text('全部'),
                                      selected: _topics.isEmpty,
                                      onSelected: (_) => setState(_topics.clear),
                                    ),
                                    for (final t in topics.take(40))
                                      FilterChip(
                                        label: Text('${t.label} ${t.count}'),
                                        selected: _topics.contains(t.label),
                                        onSelected: (on) => setState(() => on ? _topics.add(t.label) : _topics.remove(t.label)),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Text('题量', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final n in choices)
                                ChoiceChip(
                                  label: Text(n == pool.length && choices.length > 1 ? '全部 $n 题' : '$n 题'),
                                  selected: n == count,
                                  onSelected: (_) => setState(() => _count = n),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text('时间', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (label, value) in _paces)
                                ChoiceChip(
                                  label: Text(label),
                                  selected: _pace == value,
                                  onSelected: (_) => setState(() => _pace = value),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '共 $count 题，限时 ${_limitText(count)}，不显示答案，交卷后统一评分，$passPercent% 及格。'
                            '没作答的题按答错算，不记入做题记录；作答过的题会记入统计，答错的进入错题本。'
                            '考到一半退出，进度会保留，回到这里可以继续。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: pool.isEmpty ? null : () => _begin(count),
                    child: Text(_draft == null ? '开始考试' : '另开一场新考试'),
                  ),
                  if (_history.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('考试记录', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final e in _history.take(10))
                      _HistoryTile(
                        record: e,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => ExamReviewPage(examId: e.id)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _begin(int count) async {
    final repo = ref.read(repositoryProvider);
    final all = await repo.bankQuestions(widget.bank.id);
    final history = await repo.practiceHistory(all.map((q) => q.id));
    final wrongIds = {for (final q in await repo.watchWrongBook().first) q.id};
    final qs = drawPaper(
      all,
      count,
      strategy: _strategy,
      tags: _topics.toList(),
      history: history,
      wrongIds: wrongIds,
    );
    if (!mounted) return;
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有符合条件的题目')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExamPage(bankId: widget.bank.id, title: widget.bank.title, questions: qs, limitSec: _limit(count)),
      ),
    );
    await _reload();
  }

  Future<void> _resume() async {
    final d = _draft;
    if (d == null) return;
    final repo = ref.read(repositoryProvider);
    final qs = await repo.questionsByIds(d.ids);
    if (!mounted) return;
    if (qs.isEmpty) {
      await repo.clearExamDraft(d.bankId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这场考试的题目都已下线，无法继续')));
      await _reload();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExamPage(bankId: d.bankId, title: d.title, questions: qs, limitSec: d.limitSec, draft: d),
      ),
    );
    await _reload();
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('放弃这场没做完的考试？已作的答案不会保存，也不计入统计。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('放弃')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).clearExamDraft(widget.bank.id);
    await _reload();
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.draft, required this.onResume, required this.onDiscard});

  final ExamDraft draft;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  String get _left {
    final limit = draft.limitSec;
    if (limit == null) return '不限时';
    final elapsed = (DateTime.now().millisecondsSinceEpoch - draft.startedAt) / 1000;
    final r = (limit - elapsed).ceil().clamp(0, 1 << 30);
    if (r == 0) return '时间已到，继续将直接交卷';
    return '剩余 ${r ~/ 60}:${(r % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('有一场没做完的考试', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '已答 ${draft.answers.length} / ${draft.ids.length} 题 · $_left',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: FilledButton(onPressed: onResume, child: const Text('继续考试'))),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: onDiscard, child: const Text('放弃')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record, required this.onTap});

  final ExamRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = record.passed ? Colors.green.shade600 : theme.colorScheme.error;
    final t = DateTime.fromMillisecondsSinceEpoch(record.finishedAt);
    String p(int n) => n.toString().padLeft(2, '0');
    final secs = (record.usedMs / 1000).round();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        trailing: const Icon(Icons.chevron_right),
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${record.percent} 分',
                style: TextStyle(fontWeight: FontWeight.w700, color: color),
              ),
              TextSpan(text: ' · ${record.passed ? '及格' : '未及格'}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        subtitle: Text(
          '${t.month}月${t.day}日 ${p(t.hour)}:${p(t.minute)} · 答对 ${record.correct}/${record.total}'
          ' · 用时 ${secs ~/ 60}分${p(secs % 60)}秒',
        ),
      ),
    );
  }
}
