import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../quiz/modules.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/topics.dart';

/// The modules of one bank: each document is a chapter. Tapping one practises its questions, in
/// the document's order or shuffled. Like the knowledge-point page this is a one-off: it is not
/// saved and never touches the bank's sequential position.
class ModulesPage extends ConsumerStatefulWidget {
  const ModulesPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<ModulesPage> createState() => _ModulesPageState();
}

class _ModulesPageState extends ConsumerState<ModulesPage> {
  List<Question> _questions = const [];
  List<Attempt> _attempts = const [];
  bool _loaded = false;
  bool _shuffled = false;
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
    TopicFilter.all: '这个模块还没有题目',
    TopicFilter.unanswered: '这个模块的题都做过了',
    TopicFilter.missed: '这个模块还没有做错过的题',
  };

  Future<void> _start(ModuleSummary m) async {
    final pool = applyTopicFilter(moduleQuestions(_questions, m.id), _attempts, _filter);
    if (pool.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_empty[_filter]!)));
      return;
    }
    await startQuiz(
      context,
      title: '模块 · ${m.label}',
      questions: orderQuestions(pool, _shuffled ? QuizOrder.random : QuizOrder.sequential),
    );
    if (mounted) _load();
  }

  void _toggle(TopicFilter f) => setState(() => _filter = _filter == f ? TopicFilter.all : f);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modules = moduleSummary(_questions, _attempts);
    return Scaffold(
      appBar: AppBar(title: Text('按模块刷题 · ${widget.bank.title}')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : modules.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('还没有模块信息，请先同步一次题库', textAlign: TextAlign.center),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      Row(children: [
                        Expanded(child: Text('每个模块是一份文档，点一个模块刷它的题', style: theme.textTheme.bodySmall)),
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [ButtonSegment(value: false, label: Text('顺序')), ButtonSegment(value: true, label: Text('随机'))],
                          selected: {_shuffled},
                          onSelectionChanged: (s) => setState(() => _shuffled = s.first),
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
                      for (final m in modules)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: Opacity(
                            opacity: topicAvailable(m, _filter) == 0 ? 0.45 : 1,
                            child: ListTile(
                              key: ValueKey('module-${m.id}'),
                              title: Text(m.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${m.count} 题${_filter == TopicFilter.all ? '' : ' · 可刷 ${topicAvailable(m, _filter)}'} · 做过 ${m.answered}',
                              ),
                              trailing: m.accuracy == null
                                  ? Text('未做', style: theme.textTheme.bodySmall)
                                  : Text('${m.accuracy}%', style: TextStyle(fontWeight: FontWeight.w600, color: _tone(theme, m.accuracy!))),
                              onTap: () => _start(m),
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
