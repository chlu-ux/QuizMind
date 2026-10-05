import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/stats.dart';
import '../exam/exam_session.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/topics.dart';

/// Practice statistics of one bank: accuracy, coverage, a 7/30-day chart, exam scores, and the weak spots.
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  late Future<BankReport> _report;
  int _range = 7;

  /// Related tags are merged by default ("UML 辨析" into "UML"); the detailed view lists them as tagged.
  bool _merged = true;

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
                  _DailyChart(
                    days: _range == 7 ? r.daily : r.daily30,
                    range: _range,
                    onRange: (v) => setState(() => _range = v),
                  ),
                  const SizedBox(height: 12),
                  _MeterCard(title: '按题型 / 难度', groups: [...r.byType, ...r.byDifficulty]),
                  if (r.examTrend.isNotEmpty) ...[const SizedBox(height: 12), _ExamTrend(points: r.examTrend)],
                  if (r.byTag.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _TagCard(
                      groups: _merged ? r.byTagMerged : r.byTag,
                      merged: _merged,
                      onMerged: (v) => setState(() => _merged = v),
                      onTopic: _practiseTopic,
                    ),
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

  /// Practises one knowledge point, as the list groups it (merged or detailed).
  Future<void> _practiseTopic(String label) async {
    final all = await ref.read(repositoryProvider).bankQuestions(widget.bank.id);
    if (!mounted) return;
    final qs = topicQuestions(all, label, merged: _merged);
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这个知识点没有可练习的题目')));
      return;
    }
    await startQuiz(context, title: '知识点 · $label', questions: orderQuestions(qs, QuizOrder.random));
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
        _StatTile('连续学习', '${r.streakDays} 天', '今天学习 ${formatDuration(r.daily30.last.studyMs)}'),
        _StatTile('当前状态', '${r.latestCorrect} 题', '最近一次答对 · 错题本 ${r.wrongBook}'),
        _StatTile('刷题时间', _duration(r.practiceMs), '答题用时 · 今天 ${formatDuration(r.daily30.last.practiceMs)}'),
        _StatTile('学习时间', _duration(r.studyMs), '含看解析 ${formatDuration(r.reviewMs)}'),
      ],
    );
  }
}

/// "1小时5分" / "12分钟" / "<1分钟" for a big figure.
String _duration(int ms) => durationParts(ms).map((p) => '${p.v}${p.u}').join();

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

class _DailyChart extends StatefulWidget {
  const _DailyChart({required this.days, required this.range, required this.onRange});

  final List<DayStat> days;
  final int range;
  final ValueChanged<int> onRange;

  @override
  State<_DailyChart> createState() => _DailyChartState();
}

class _DailyChartState extends State<_DailyChart> {
  static const _barHeight = 96.0;

  /// The bars show how many questions were answered, or how long was spent.
  bool _time = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = widget.days;
    final range = widget.range;
    final peak = days.fold<int>(1, (m, d) {
      final v = _time ? d.studyMs : d.attempts;
      return v > m ? v : m;
    });
    final total = days.fold<int>(0, (n, d) => n + d.attempts);
    final practice = days.fold<int>(0, (n, d) => n + d.practiceMs);
    final review = days.fold<int>(0, (n, d) => n + d.reviewMs);
    final ok = Colors.green.shade600;
    final bad = theme.colorScheme.error;
    final main = theme.colorScheme.primary;
    final soft = Color.alphaBlend(main.withValues(alpha: 0.4), theme.colorScheme.surface);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('最近 $range 天', style: theme.textTheme.titleSmall),
                const Spacer(),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: 7, label: Text('7 天')),
                    ButtonSegment(value: 30, label: Text('30 天')),
                  ],
                  selected: {range},
                  onSelectionChanged: (s) => widget.onRange(s.first),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '共 $total 次作答 · 刷题 ${formatDuration(practice)} · 解析 ${formatDuration(review)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('次数')),
                    ButtonSegment(value: true, label: Text('时长')),
                  ],
                  selected: {_time},
                  onSelectionChanged: (s) => setState(() => _time = s.first),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < days.length; i++)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 16,
                          child: OverflowBox(
                            maxWidth: 40,
                            child: Text(
                              range != 7
                                  ? ''
                                  : _time
                                  ? formatMinutes(days[i].studyMs)
                                  : (days[i].attempts > 0 ? '${days[i].percent}%' : ''),
                              style: theme.textTheme.labelSmall,
                              maxLines: 1,
                            ),
                          ),
                        ),
                        Container(
                          height: _barHeight,
                          width: range == 7 ? 24 : 6,
                          alignment: Alignment.bottomCenter,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: _time
                                ? [
                                    Container(height: _barHeight * days[i].reviewMs / peak, color: soft),
                                    Container(height: _barHeight * days[i].practiceMs / peak, color: main),
                                  ]
                                : [
                                    Container(
                                      height: _barHeight * (days[i].attempts - days[i].correct) / peak,
                                      color: bad,
                                    ),
                                    Container(height: _barHeight * days[i].correct / peak, color: ok),
                                  ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 14,
                          child: OverflowBox(
                            maxWidth: 40,
                            child: Text(
                              range == 7 || i % 5 == 4 ? days[i].label : '',
                              style: theme.textTheme.labelSmall,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (color, label)
                    in _time ? [(main, '刷题（答题用时）'), (soft, '看解析')] : [(ok, '答对'), (bad, '答错')]) ...[
                  Icon(Icons.square_rounded, size: 12, color: color),
                  const SizedBox(width: 4),
                  Text(label, style: theme.textTheme.bodySmall),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MeterCard extends StatelessWidget {
  const _MeterCard({required this.title, required this.groups, this.note, this.trailing, this.onTap});

  final String title;
  final List<GroupStat> groups;
  final String? note;
  final Widget? trailing;

  /// Makes each row tappable, told its label.
  final ValueChanged<String>? onTap;

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
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                ?trailing,
              ],
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(note!, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            for (final g in groups)
              InkWell(
                onTap: onTap == null ? null : () => onTap!(g.label),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
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

/// Knowledge-point accuracy with a toggle between merged ("归类") and as-tagged ("细分") views.
class _TagCard extends StatelessWidget {
  const _TagCard({required this.groups, required this.merged, required this.onMerged, required this.onTopic});

  final List<GroupStat> groups;
  final bool merged;
  final ValueChanged<bool> onMerged;
  final ValueChanged<String> onTopic;

  @override
  Widget build(BuildContext context) {
    final shown = groups.length < 8 ? groups.length : 8;
    return _MeterCard(
      title: '知识点（薄弱的在前）',
      note: '点一个知识点直接开始刷；共 ${groups.length} 个，显示前 $shown 个${merged ? '；相近的标签已合并（如「UML 辨析」归入「UML」）' : ''}',
      trailing: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: true, label: Text('归类')),
          ButtonSegment(value: false, label: Text('细分')),
        ],
        selected: {merged},
        onSelectionChanged: (s) => onMerged(s.first),
      ),
      groups: groups.take(8).toList(),
      onTap: onTopic,
    );
  }
}

/// Exam scores as a line, oldest to newest, with the pass line dashed.
class _ExamTrend extends StatelessWidget {
  const _ExamTrend({required this.points});

  final List<ExamPoint> points;

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
            Row(
              children: [
                Text('考试成绩', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('最近 ${points.length} 场 · 虚线是 $passPercent 分及格线', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Semantics(
              label: '最近 ${points.length} 场考试成绩',
              child: SizedBox(
                key: const ValueKey('exam-trend'),
                height: 130,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TrendPainter(
                    points: points,
                    line: theme.colorScheme.primary,
                    pass: Colors.green.shade600,
                    fail: theme.colorScheme.error,
                    grid: theme.colorScheme.outlineVariant,
                    text: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.line,
    required this.pass,
    required this.fail,
    required this.grid,
    required this.text,
  });

  final List<ExamPoint> points;
  final Color line;
  final Color pass;
  final Color fail;
  final Color grid;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 28.0, top = 12.0, bottom = 14.0;
    final h = size.height - top - bottom;
    double y(num percent) => top + (100 - percent) * h / 100;
    double x(int i) => points.length == 1 ? size.width / 2 : left + i * (size.width - left - 12) / (points.length - 1);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, y(100)), Offset(size.width, y(100)), gridPaint);
    canvas.drawLine(Offset(left, y(0)), Offset(size.width, y(0)), gridPaint);

    // The pass line, dashed.
    final passPaint = Paint()
      ..color = pass
      ..strokeWidth = 1;
    for (var dx = left; dx < size.width; dx += 8) {
      canvas.drawLine(Offset(dx, y(passPercent)), Offset(dx + 4, y(passPercent)), passPaint);
    }

    void label(String t, Offset at, {TextAlign align = TextAlign.left}) {
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(color: text, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = align == TextAlign.center ? at.dx - tp.width / 2 : at.dx;
      tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
    }

    label('100', Offset(0, y(100)));
    label('$passPercent', Offset(0, y(passPercent)));
    label('0', Offset(8, y(0)));

    if (points.length > 1) {
      final path = Path()..moveTo(x(0), y(points[0].percent));
      for (var i = 1; i < points.length; i++) {
        path.lineTo(x(i), y(points[i].percent));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(Offset(x(i), y(points[i].percent)), 4, Paint()..color = points[i].passed ? line : fail);
      label('${points[i].percent}', Offset(x(i), y(points[i].percent) - 11), align: TextAlign.center);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}
