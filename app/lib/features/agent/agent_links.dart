import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart' show Question;
import '../../data/progress.dart';
import '../quiz/lesson_page.dart';
import '../quiz/quiz_media.dart';

/// The two kinds of link the assistant writes (docs/agent-design.md §5.3).
enum AgentLinkKind { lesson, question }

/// Splits `lesson:ID` / `question:ID`. Anything else (an ordinary web link, a made-up scheme) is not ours.
({AgentLinkKind kind, String id})? parseAgentLink(String? href) {
  if (href == null) return null;
  for (final (prefix, kind) in [
    ('lesson:', AgentLinkKind.lesson),
    ('question:', AgentLinkKind.question),
  ]) {
    if (href.startsWith(prefix)) {
      final id = href.substring(prefix.length).trim();
      return id.isEmpty ? null : (kind: kind, id: id);
    }
  }
  return null;
}

/// Opens what a tapped link in an assistant answer points at: a lesson opens the reading page, a
/// question a read-only view of it. What is not on this device yet (not synced) is said so.
Future<void> openAgentLink(
  BuildContext context,
  WidgetRef ref,
  String? href,
) async {
  final link = parseAgentLink(href);
  if (link == null) return;
  final repo = ref.read(repositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  switch (link.kind) {
    case AgentLinkKind.lesson:
      final lesson = await repo.lesson(link.id);
      final bank = lesson == null ? null : await repo.bank(lesson.bankId);
      if (bank == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('这一节在本机找不到，先同步一下再试')),
        );
        return;
      }
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => LessonPage(bank: bank, lessonId: lesson!.id),
        ),
      );
    case AgentLinkKind.question:
      final q = await repo.question(link.id);
      if (q == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('这道题在本机找不到，先同步一下再试')),
        );
        return;
      }
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => QuestionPreview(question: q),
      );
  }
}

/// A question as the learner would review it: stem, options with the right ones marked, explanation. Read only.
class QuestionPreview extends StatelessWidget {
  const QuestionPreview({super.key, required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = question;
    final options = q.options;
    final answer = q.answer;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shrinkWrap: true,
          children: [
            QuizMarkdown(q.stem),
            const SizedBox(height: 8),
            for (var i = 0; i < options.length; i++)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: answer.contains(i)
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${String.fromCharCode(65 + i)}.  ',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Expanded(child: Text(options[i])),
                    if (answer.contains(i))
                      Icon(
                        Icons.check_circle,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ),
            if (q.explanation.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('解析', style: theme.textTheme.titleSmall),
              QuizMarkdown(q.explanation),
            ],
          ],
        ),
      ),
    );
  }
}
