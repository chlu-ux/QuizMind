import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/exam_store.dart';
import 'exam_page.dart';
import 'exam_session.dart';

/// Picks the size and time limit of a mock exam, and lists the earlier ones.
class ExamSetupPage extends ConsumerStatefulWidget {
  const ExamSetupPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<ExamSetupPage> createState() => _ExamSetupPageState();
}

class _ExamSetupPageState extends ConsumerState<ExamSetupPage> {
  /// Seconds per question; null = no time limit.
  static const _paces = <(String, int?)>[('每题 30 秒', 30), ('每题 1 分钟', 60), ('每题 2 分钟', 120), ('不限时', null)];

  late Future<int> _available;
  late List<ExamRecord> _history;
  int? _count;
  int? _pace = 60;

  @override
  void initState() {
    super.initState();
    _available = ref.read(repositoryProvider).bankQuestions(widget.bank.id).then((qs) => qs.length);
    _history = ref.read(examStoreProvider).history(widget.bank.id);
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
      body: FutureBuilder<int>(
        future: _available,
        builder: (context, snap) {
          final available = snap.data;
          if (available == null) return const Center(child: CircularProgressIndicator());
          if (available == 0) return const Center(child: Text('这个题库还没有题目'));
          final choices = examCountChoices(available);
          final count = choices.contains(_count) ? _count! : (choices.contains(20) ? 20 : choices.first);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('题量', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final n in choices)
                                ChoiceChip(
                                  label: Text(n == available && choices.length > 1 ? '全部 $n 题' : '$n 题'),
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
                            '从题库随机抽 $count 题，限时 ${_limitText(count)}，不显示答案，交卷后统一评分，$passPercent% 及格。'
                            '没作答的题按答错算，不记入做题记录；作答过的题会记入统计，答错的进入错题本。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => _begin(count), child: const Text('开始考试')),
                  if (_history.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('考试记录', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final e in _history.take(10)) _HistoryTile(record: e),
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
    final qs = drawExam(await repo.bankQuestions(widget.bank.id), count);
    if (!mounted) return;
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这个题库还没有题目')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExamPage(bankId: widget.bank.id, title: widget.bank.title, questions: qs, limitSec: _limit(count)),
      ),
    );
    if (mounted) setState(() => _history = ref.read(examStoreProvider).history(widget.bank.id));
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record});

  final ExamRecord record;

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
