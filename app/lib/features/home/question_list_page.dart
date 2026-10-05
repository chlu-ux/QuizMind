import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/media_text.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import 'bank_filter.dart';
import 'sync_widgets.dart';

enum QuestionListKind { wrongBook, favorites }

/// The wrong book or the favorites: a list that can be practised as a whole or
/// from any entry, and narrowed to one bank.
class QuestionListPage extends ConsumerStatefulWidget {
  const QuestionListPage({super.key, required this.kind, this.initialBankId});

  final QuestionListKind kind;

  /// Opens narrowed to this bank (from a bank's own page); null shows every bank.
  final String? initialBankId;

  @override
  ConsumerState<QuestionListPage> createState() => _QuestionListPageState();
}

class _QuestionListPageState extends ConsumerState<QuestionListPage> {
  // '' = every bank. The page lives on in the tab bar, so the choice also lasts until the app is closed.
  late String _bankId = widget.initialBankId ?? '';

  @override
  void didUpdateWidget(QuestionListPage old) {
    super.didUpdateWidget(old);
    final id = widget.initialBankId;
    if (id != null && id != old.initialBankId) _bankId = id;
  }

  @override
  Widget build(BuildContext context) {
    final wrong = widget.kind == QuestionListKind.wrongBook;
    final base = wrong ? '错题本' : '收藏';
    final data = ref.watch(wrong ? wrongBookProvider : favoritesProvider);
    final banks = ref.watch(banksProvider).value ?? const <Bank>[];
    final repo = ref.read(repositoryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(base), actions: const [SyncButton()]),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (all) {
          if (all.isEmpty) {
            return Center(
              child: Text(wrong ? '没有错题，继续保持' : '还没有收藏的题目', style: Theme.of(context).textTheme.bodyLarge),
            );
          }
          final options = bankOptions(all, banks);
          // A bank with nothing left on the list cannot stay selected: show everything.
          final active = options.any((o) => o.id == _bankId) ? _bankId : '';
          final qs = inBank(all, active);
          String nameOf(String id) => options.where((o) => o.id == id).firstOrNull?.name ?? unknownBank;
          final title = active.isEmpty ? base : '$base · ${nameOf(active)}';
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(children: [
                if (options.length > 1 || active.isNotEmpty)
                  SizedBox(
                    height: 52,
                    child: ListView(
                      key: const Key('bank-filter'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('全部 ${all.length}'),
                            selected: active.isEmpty,
                            onSelected: (_) => setState(() => _bankId = ''),
                          ),
                        ),
                        for (final o in options)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text('${o.name} ${o.count}'),
                              selected: active == o.id,
                              onSelected: (_) => setState(() => _bankId = o.id),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    Text('共 ${qs.length} 题'),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () => startQuiz(context, title: title, questions: orderQuestions(qs, QuizOrder.random)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('随机练习'),
                    ),
                  ]),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: qs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final q = qs[i];
                      final type = q.type == 'judge' ? '判断题' : '单选题';
                      return ListTile(
                        title: Text(plainText(q.stem), maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(active.isEmpty ? '$type · ${nameOf(q.bankId)}' : type),
                        trailing: IconButton(
                          tooltip: wrong ? '移出错题本' : '取消收藏',
                          icon: Icon(wrong ? Icons.check_circle_outline : Icons.star),
                          onPressed: () => wrong ? repo.clearFromWrongBook(q.id) : repo.setFavorite(q.id, false),
                        ),
                        onTap: () => startQuiz(context, title: title, questions: qs, startAt: i),
                      );
                    },
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}
