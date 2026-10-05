import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/topics.dart';

/// The knowledge points of one bank, biggest first. Tapping one practises its questions at random.
/// The practice is a one-off: it is not saved, so it never replaces the bank's "continue last round".
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage> {
  List<Question> _questions = const [];
  List<Attempt> _attempts = const [];
  bool _loaded = false;

  /// Related tags merged ("UML 辨析" into "UML"), as on the stats page and the exam setup.
  bool _merged = true;

  /// Which questions of a topic to draw; the two switches exclude each other.
  TopicFilter _filter = TopicFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final qs = await repo.bankQuestions(widget.bank.id);
    final attempts = await repo.bankAttempts(widget.bank.id);
    if (!mounted) return;
    setState(() {
      _questions = qs;
      _attempts = attempts;
      _loaded = true;
    });
  }

  static const _empty = {
    TopicFilter.all: '这个知识点还没有题目',
    TopicFilter.unanswered: '这个知识点的题都做过了',
    TopicFilter.missed: '这个知识点还没有做错过的题',
  };

  Future<void> _start(String label) async {
    final pool = applyTopicFilter(topicQuestions(_questions, label, merged: _merged), _attempts, _filter);
    if (pool.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_empty[_filter]!)));
      return;
    }
    await startQuiz(context, title: '知识点 · $label', questions: orderQuestions(pool, QuizOrder.random));
    if (mounted) _load();
  }

  void _toggle(TopicFilter f) => setState(() => _filter = _filter == f ? TopicFilter.all : f);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topics = topicSummary(_questions, _attempts, merged: _merged);
    return Scaffold(
      appBar: AppBar(title: Text('按知识点刷题 · ${widget.bank.title}')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : topics.isEmpty
              ? const Center(child: Text('这个题库的题目还没有知识点标签'))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      Row(children: [
                        Expanded(child: Text('点一个知识点，随机刷它下面的题', style: theme.textTheme.bodySmall)),
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [ButtonSegment(value: true, label: Text('归类')), ButtonSegment(value: false, label: Text('细分'))],
                          selected: {_merged},
                          onSelectionChanged: (s) => setState(() => _merged = s.first),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        FilterChip(
                          label: const Text('只刷没做过的'),
                          selected: _filter == TopicFilter.unanswered,
                          onSelected: (_) => _toggle(TopicFilter.unanswered),
                        ),
                        FilterChip(
                          label: const Text('只刷做错过的'),
                          selected: _filter == TopicFilter.missed,
                          onSelected: (_) => _toggle(TopicFilter.missed),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      for (final t in topics)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: Opacity(
                            opacity: topicAvailable(t, _filter) == 0 ? 0.45 : 1,
                            child: ListTile(
                              key: ValueKey('topic-${t.label}'),
                              title: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${t.count} 题${_filter == TopicFilter.all ? '' : ' · 可刷 ${topicAvailable(t, _filter)}'} · 做过 ${t.answered}',
                              ),
                              trailing: t.accuracy == null
                                  ? Text('未做', style: theme.textTheme.bodySmall)
                                  : Text('${t.accuracy}%', style: TextStyle(fontWeight: FontWeight.w600, color: _tone(theme, t.accuracy!))),
                              onTap: () => _start(t.label),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
    );
  }
}

/// Green when solid, amber when shaky, red when poor (as on the stats page).
Color _tone(ThemeData theme, int percent) {
  if (percent >= 80) return Colors.green.shade600;
  if (percent >= 60) return Colors.amber.shade700;
  return theme.colorScheme.error;
}
