import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/progress.dart';
import '../quiz/quiz_page.dart';
import 'exam_session.dart';

/// Score, pass/fail, per-question marks and a review with the right answers. Used
/// right after hand-in and for looking at an earlier exam.
class ExamResultView extends StatelessWidget {
  const ExamResultView({super.key, required this.record, required this.entries, this.title = '考试结果'});

  final ExamRecord record;
  final List<ExamEntry> entries;
  final String title;

  String _option(Question q, int i) =>
      q.type == 'judge' ? q.options[i] : '${String.fromCharCode(65 + i)}. ${q.options[i]}';

  String _picked(ExamEntry e) =>
      e.selected.isEmpty || e.question == null ? '未作答' : e.selected.map((i) => _option(e.question!, i)).join('、');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = record;
    final good = Colors.green.shade600;
    final color = r.passed ? good : theme.colorScheme.error;
    final secs = (r.usedMs / 1000).round();
    final missed = [
      for (final e in entries)
        if (!e.correct && e.question != null) e.question!,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
              if (entries.isEmpty)
                Text('这场考试是旧版本记录的，只保留了成绩，没有逐题明细。', style: theme.textTheme.bodySmall)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < entries.length; i++)
                      Container(
                        width: 44,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(
                            (entries[i].correct ? good : theme.colorScheme.error).withValues(alpha: 0.14),
                            theme.colorScheme.surface,
                          ),
                          border: Border.all(color: entries[i].correct ? good : theme.colorScheme.error),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(color: entries[i].correct ? good : theme.colorScheme.error),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              if (missed.isNotEmpty) ...[
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(builder: (_) => QuizPage(title: '重做错题', questions: missed)),
                  ),
                  icon: const Icon(Icons.replay),
                  label: Text('重做错题 (${missed.length})'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
              if (entries.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('逐题解析', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (var i = 0; i < entries.length; i++)
                  _ReviewTile(
                    index: i,
                    entry: entries[i],
                    picked: _picked(entries[i]),
                    answer: entries[i].question == null
                        ? ''
                        : entries[i].question!.answer.map((a) => _option(entries[i].question!, a)).join('、'),
                  ),
              ],
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
  const _ReviewTile({required this.index, required this.entry, required this.picked, required this.answer});

  final int index;
  final ExamEntry entry;
  final String picked;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = entry.question;
    final ok = entry.correct;
    final color = ok ? Colors.green.shade600 : theme.colorScheme.error;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(ok ? Icons.check_circle : Icons.cancel, color: color),
        title: Text(
          '${index + 1}. ${q?.stem ?? '（这道题已下线）'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: q == null
            ? [
                Text(
                  '题目已被下线，看不到内容；当时你${entry.selected.isEmpty ? '没有作答' : '作了答'}，${ok ? '答对了' : '没答对'}。',
                  style: theme.textTheme.bodySmall,
                ),
              ]
            : [
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
