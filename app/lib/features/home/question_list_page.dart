import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import 'sync_widgets.dart';

enum QuestionListKind { wrongBook, favorites }

/// The wrong book or the favorites: a list that can be practised as a whole or
/// from any entry.
class QuestionListPage extends ConsumerWidget {
  const QuestionListPage({super.key, required this.kind});

  final QuestionListKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wrong = kind == QuestionListKind.wrongBook;
    final title = wrong ? '错题本' : '收藏';
    final data = ref.watch(wrong ? wrongBookProvider : favoritesProvider);
    final repo = ref.read(repositoryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(title), actions: const [SyncButton()]),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (qs) {
          if (qs.isEmpty) {
            return Center(
              child: Text(wrong ? '没有错题，继续保持' : '还没有收藏的题目', style: Theme.of(context).textTheme.bodyLarge),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(children: [
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
                      return ListTile(
                        title: Text(q.stem, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(q.type == 'judge' ? '判断题' : '单选题'),
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
