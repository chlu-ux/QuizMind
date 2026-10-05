import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/progress.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/search.dart';

/// Rows drawn at once; a broad word in a big bank would otherwise put thousands of widgets on screen.
const searchShowLimit = 100;
const _debounce = Duration(milliseconds: 200);

/// Searches the questions of one bank on this device (stem, options, explanation, tags). It needs no
/// server, so it works offline.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  List<Question> _questions = const [];
  bool _loaded = false;
  // What is actually searched: the box, a moment after the last key press.
  String _query = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ref.read(repositoryProvider).bankQuestions(widget.bank.id).then((qs) {
      if (!mounted) return;
      setState(() {
        _questions = qs;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _typed(String text) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  static const _where = {SearchWhere.option: '选项', SearchWhere.tag: '知识点', SearchWhere.explanation: '解析'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terms = searchTerms(_query);
    final hits = _loaded ? searchQuestions(_questions, _query) : const <SearchHit>[];
    final results = [for (final h in hits) h.question];
    final title = '搜索：${_query.trim()}';
    final mark = TextStyle(backgroundColor: Colors.amber.withValues(alpha: 0.4));

    TextSpan spans(String text, TextStyle? base) => TextSpan(style: base, children: [
          for (final p in highlight(text, terms)) TextSpan(text: p.text, style: p.hit ? mark : null),
        ]);

    return Scaffold(
      appBar: AppBar(title: Text('搜索 · ${widget.bank.title}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索题干、选项、解析、知识点',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: _typed,
              ),
            ),
            if (terms.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('输入关键词开始搜索。多个词用空格分开，都要出现；不分大小写和全角半角；离线也能用。', style: theme.textTheme.bodySmall),
              )
            else if (hits.isEmpty)
              Padding(padding: const EdgeInsets.all(32), child: Text('没有找到包含「${terms.join(' ')}」的题目'))
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(children: [
                  Text('找到 ${hits.length} 题'),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => startQuiz(context, title: title, questions: orderQuestions(results, QuizOrder.random)),
                    icon: const Icon(Icons.play_arrow),
                    label: Text('练习这 ${hits.length} 道'),
                  ),
                ]),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: hits.length > searchShowLimit ? searchShowLimit + 1 : hits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i >= searchShowLimit) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(child: Text('还有 ${hits.length - searchShowLimit} 条，请缩小范围', style: theme.textTheme.bodySmall)),
                      );
                    }
                    final h = hits[i];
                    final q = h.question;
                    return ListTile(
                      title: Text.rich(spans(q.stem, null), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (h.snippet.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text.rich(TextSpan(children: [
                              TextSpan(text: '${_where[h.where]}：'),
                              spans(h.snippet, null),
                            ]), maxLines: 3, overflow: TextOverflow.ellipsis),
                          ),
                        Text('${q.type == 'judge' ? '判断题' : '单选题'} · 难度 ${'★' * q.difficulty}'
                            '${q.tags.isEmpty ? '' : ' · ${q.tags.join('、')}'}'),
                      ]),
                      onTap: () => startQuiz(context, title: title, questions: results, startAt: i),
                    );
                  },
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
