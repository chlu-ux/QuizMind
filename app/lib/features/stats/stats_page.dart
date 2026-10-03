import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/stats.dart';
import '../quiz/quiz_page.dart';

/// Practice statistics of one bank: accuracy, coverage, a 7-day chart, and the weak spots.
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  late Future<BankReport> _report;

  @override
  void initState() {
    super.initState();
    _report = ref.read(repositoryProvider).bankReport(widget.bank.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.bank.title} · 统计')),
      body: FutureBuilder<BankReport>(
        future: _report,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('读取失败：${snap.error}'));
          final r = snap.data;
          if (r == null) return const Center(child: CircularProgressIndicator());
          if (r.attempts == 0) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bar_chart, size: 56),
                  const SizedBox(height: 12),
                  const Text('还没有答题记录，做几道题再来看统计'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('去刷题')),
                ],
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Overview(report: r),
                  const SizedBox(height: 12),
                  _DailyChart(days: r.daily),
                  const SizedBox(height: 12),
                  _MeterCard(title: '按题型 / 难度', groups: [...r.byType, ...r.byDifficulty]),
                  if (r.byTag.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _MeterCard(title: '知识点（薄弱的在前）', groups: r.byTag.take(8).toList()),
                  ],
                  if (r.weakest.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _Weakest(weakest: r.weakest.take(5).toList(), onPractise: () => _practise(r)),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _practise(BankReport r) {
    startQuiz(context, title: '薄弱题', questions: [for (final w in r.weakest.take(20)) w.question]);
  }
}

/// Green when solid, amber when shaky, red when poor.
Color _tone(BuildContext context, int? percent) {
  if (percent == null) return Theme.of(context).colorScheme.outline;
  if (percent >= 80) return Colors.green.shade600;
  if (percent >= 60) return Colors.amber.shade700;
  return Theme.of(context).colorScheme.error;
}

class _Overview extends StatelessWidget {
  const _Overview({required this.report});

  final BankReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final coverage = r.totalQuestions == 0 ? 0 : (r.answeredQuestions * 100 / r.totalQuestions).round();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.7,
      children: [
        _StatTile('总正确率', '${r.accuracy}%', '答对 ${r.correct} / ${r.attempts} 次', color: _tone(context, r.accuracy)),
        _StatTile('覆盖率', '$coverage%', '做过 ${r.answeredQuestions} / ${r.totalQuestions} 题'),
        _StatTile('连续学习', '${r.streakDays} 天', '累计 ${formatDuration(r.studyMs)}'),
        _StatTile('当前状态', '${r.latestCorrect} 题', '最近一次答对 · 错题本 ${r.wrongBook}'),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.label, this.value, this.note, {this.color});

  final String label;
  final String value;
  final String note;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
            Text(note, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.days});

  final List<DayStat> days;

  static const _barHeight = 96.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = days.fold<int>(1, (m, d) => d.attempts > m ? d.attempts : m);
    final total = days.fold<int>(0, (n, d) => n + d.attempts);
    final ok = Colors.green.shade600;
    final bad = theme.colorScheme.error;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('最近 7 天', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('共 $total 次', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in days)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 16,
                          child: Text(d.attempts == 0 ? '' : '${d.percent}%', style: theme.textTheme.labelSmall),
                        ),
                        Container(
                          height: _barHeight,
                          width: 24,
                          alignment: Alignment.bottomCenter,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(height: _barHeight * (d.attempts - d.correct) / peak, color: bad),
                              Container(height: _barHeight * d.correct / peak, color: ok),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(d.label, style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.square_rounded, size: 12, color: ok),
                const SizedBox(width: 4),
                Text('答对', style: theme.textTheme.bodySmall),
                const SizedBox(width: 12),
                Icon(Icons.square_rounded, size: 12, color: bad),
                const SizedBox(width: 4),
                Text('答错', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MeterCard extends StatelessWidget {
  const _MeterCard({required this.title, required this.groups});

  final String title;
  final List<GroupStat> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(width: 84, child: Text(g.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (g.percent ?? 0) / 100,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                        color: _tone(context, g.percent),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${g.percent}%',
                        textAlign: TextAlign.end,
                        style: TextStyle(fontWeight: FontWeight.w600, color: _tone(context, g.percent)),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text('${g.attempts}次', textAlign: TextAlign.end, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Weakest extends StatelessWidget {
  const _Weakest({required this.weakest, required this.onPractise});

  final List<WeakQuestion> weakest;
  final VoidCallback onPractise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最常做错的题', style: theme.textTheme.titleSmall),
            for (final w in weakest)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(w.question.stem, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text('错 ${w.wrong}/${w.attempts}', style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: onPractise, child: const Text('专攻薄弱题（最多 20 道）')),
            ),
          ],
        ),
      ),
    );
  }
}
