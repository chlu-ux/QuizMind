import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/progress.dart';
import '../../data/repository.dart';
import 'quiz_session.dart';
import 'session_store.dart';

/// Opens a quiz over [questions]. Returns when the learner leaves.
///
/// With a [scope] (a bank id) the quiz is saved as the learner goes, so it can be
/// picked up again; pass [resume] to continue a saved one instead of starting over.
Future<void> startQuiz(
  BuildContext context, {
  required String title,
  required List<Question> questions,
  int startAt = 0,
  String? scope,
  ResumePlan? resume,
}) {
  if (questions.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有可练习的题目')));
    return Future.value();
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => QuizPage(title: title, questions: questions, startAt: startAt, scope: scope, resume: resume),
  ));
}

class QuizPage extends ConsumerStatefulWidget {
  const QuizPage({
    super.key,
    required this.title,
    required this.questions,
    this.startAt = 0,
    this.scope,
    this.resume,
    this.shuffleOptions = true,
  });

  final String title;
  final List<Question> questions;
  final int startAt;

  /// Where progress is saved; null for quizzes that are not worth resuming.
  final String? scope;
  final ResumePlan? resume;
  final bool shuffleOptions;

  @override
  ConsumerState<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends ConsumerState<QuizPage> {
  late final QuizSession session;
  late final SyncController _sync;
  late final SessionStore _store;
  (int, int)? _saved; // (index, answered) last written

  @override
  void initState() {
    super.initState();
    _sync = ref.read(syncProvider.notifier);
    _store = ref.read(sessionStoreProvider);
    final resume = widget.resume;
    session = QuizSession(
      title: widget.title,
      questions: widget.questions,
      repo: ref.read(repositoryProvider),
      startAt: widget.startAt,
      seed: resume?.seed,
      shuffleOptions: widget.shuffleOptions,
      restored: resume?.restored ?? const {},
    );
    final scope = widget.scope;
    if (scope != null) {
      if (resume == null) {
        unawaited(_store.start(scope,
            title: widget.title, ids: [for (final q in widget.questions) q.id], seed: session.seed, index: session.index));
      }
      _saved = (session.index, session.answeredCount);
      session.addListener(_persist);
    }
  }

  /// Keeps the saved progress in step with the quiz. Finishing clears it: there
  /// is nothing left to continue.
  void _persist() {
    final scope = widget.scope;
    if (scope == null) return;
    if (session.finished) {
      unawaited(_store.clear(scope));
      return;
    }
    final now = (session.index, session.answeredCount);
    if (now == _saved) return;
    _saved = now;
    unawaited(_store.saveProgress(scope, index: session.index, answers: session.answerSnapshot));
  }

  @override
  void dispose() {
    session.dispose();
    // Push what was answered while the learner is likely still online.
    Future.microtask(_sync.run);
    super.dispose();
  }

  void _primary() {
    if (session.submitted) {
      session.next();
    } else {
      session.submit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.finished) return QuizSummary(session: session);
        return CallbackShortcuts(
          bindings: {
            for (var i = 0; i < 4; i++)
              SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i)): () => session.selectAt(i),
            const SingleActivator(LogicalKeyboardKey.enter): _primary,
            const SingleActivator(LogicalKeyboardKey.keyJ): session.next,
            const SingleActivator(LogicalKeyboardKey.arrowRight): session.next,
            const SingleActivator(LogicalKeyboardKey.keyK): session.previous,
            const SingleActivator(LogicalKeyboardKey.arrowLeft): session.previous,
          },
          child: Focus(
            autofocus: true,
            child: _QuizScaffold(session: session, onPrimary: _primary, onFlagged: _afterFlag),
          ),
        );
      },
    );
  }

  Future<void> _afterFlag() async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    await session.flagCurrent();
    messenger.showSnackBar(const SnackBar(content: Text('已反馈，下次同步时提交给服务器')));
    if (session.isLast && session.answeredCount == 0) {
      nav.pop(); // nothing left to show
    } else {
      session.next();
    }
  }
}

class _QuizScaffold extends ConsumerWidget {
  const _QuizScaffold({required this.session, required this.onPrimary, required this.onFlagged});

  final QuizSession session;
  final VoidCallback onPrimary;
  final Future<void> Function() onFlagged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = session.current;
    final repo = ref.read(repositoryProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${session.index + 1}/${session.length}', style: theme.textTheme.labelMedium),
        ]),
        actions: [
          StreamBuilder<QuestionState?>(
            stream: repo.watchState(q.id),
            builder: (context, snap) {
              final fav = snap.data?.favorite ?? false;
              return IconButton(
                tooltip: fav ? '取消收藏' : '收藏',
                icon: Icon(fav ? Icons.star : Icons.star_border),
                onPressed: () => repo.setFavorite(q.id, !fav),
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'flag') await onFlagged();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'flag', child: Text('题目有误，反馈'))],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(value: (session.index + (session.submitted ? 1 : 0)) / session.length),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(children: [
                  Chip(
                    label: Text(q.type == 'judge' ? '判断题' : '单选题'),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                  Text('难度 ${'★' * q.difficulty}', style: theme.textTheme.labelMedium),
                ]),
                const SizedBox(height: 8),
                MarkdownBody(data: q.stem, selectable: true, styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.titleMedium?.copyWith(height: 1.5),
                )),
                const SizedBox(height: 16),
                for (final opt in session.displayOptions)
                  _OptionTile(
                    label: session.labelOf(opt.original),
                    text: opt.text,
                    selected: session.selected.contains(opt.original),
                    revealed: session.submitted,
                    isAnswer: q.answer.contains(opt.original),
                    onTap: () => session.select(opt.original),
                  ),
                if (session.outcome case final o?) ...[
                  const SizedBox(height: 8),
                  _ResultCard(outcome: o, question: q, answerLabel: q.answer.map((i) => q.type == 'judge' ? q.options[i] : session.labelOf(i)).join('、')),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Row(children: [
                OutlinedButton.icon(
                  onPressed: session.canGoBack ? session.previous : null,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('上一题'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: session.busy || (!session.submitted && session.selected.isEmpty) ? null : onPrimary,
                  child: Text(session.submitted ? (session.isLast ? '完成' : '下一题') : '提交'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.text,
    required this.selected,
    required this.revealed,
    required this.isAnswer,
    required this.onTap,
  });

  final String label;
  final String text;
  final bool selected;
  final bool revealed;
  final bool isAnswer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color? bg;
    Color border = scheme.outlineVariant;
    IconData? icon;
    if (revealed) {
      if (isAnswer) {
        bg = Colors.green.withValues(alpha: 0.15);
        border = Colors.green;
        icon = Icons.check_circle;
      } else if (selected) {
        bg = scheme.errorContainer;
        border = scheme.error;
        icon = Icons.cancel;
      }
    } else if (selected) {
      bg = scheme.primaryContainer;
      border = scheme.primary;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: bg ?? Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: revealed ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: selected || (revealed && isAnswer) ? border : scheme.surfaceContainerHighest,
                foregroundColor: selected || (revealed && isAnswer) ? scheme.surface : scheme.onSurfaceVariant,
                child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
              if (icon != null) Icon(icon, color: border),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.outcome, required this.question, required this.answerLabel});

  final AnswerOutcome outcome;
  final Question question;

  /// The right answer as the learner sees it: a letter for single choice (it follows
  /// the shuffled layout), the option text for judge questions.
  final String answerLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = outcome.correct;
    // Blend onto the surface instead of using a translucent colour: a Card's
    // shadow shows through transparency and turns the tint grey.
    final accent = ok ? Colors.green : theme.colorScheme.error;
    return Card(
      elevation: 0,
      color: Color.alphaBlend(accent.withValues(alpha: 0.12), theme.colorScheme.surface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: accent.withValues(alpha: 0.4))),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ok ? '回答正确' : '回答错误，正确答案：$answerLabel',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          if (outcome.enteredWrongBook)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('已加入错题本', style: theme.textTheme.bodySmall),
            ),
          if (question.explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            MarkdownBody(data: question.explanation, selectable: true),
          ],
          if (question.sourceQuote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
              ),
              padding: const EdgeInsets.only(left: 10),
              child: Text('原文：${question.sourceQuote}', style: theme.textTheme.bodySmall),
            ),
          ],
        ]),
      ),
    );
  }
}

class QuizSummary extends ConsumerWidget {
  const QuizSummary({super.key, required this.session});

  final QuizSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = session.answeredCount;
    final correct = session.correctCount;
    final missed = session.missed;
    final pct = total == 0 ? 0 : (correct * 100 / total).round();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${session.title} · 完成')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('$pct%', textAlign: TextAlign.center, style: theme.textTheme.displayLarge),
              Text('答对 $correct / $total 题', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              const SizedBox(height: 24),
              if (missed.isNotEmpty) ...[
                Text('本次错题', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final q in missed)
                  ListTile(dense: true, leading: const Icon(Icons.close, color: Colors.red), title: Text(q.stem, maxLines: 2, overflow: TextOverflow.ellipsis)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final nav = Navigator.of(context);
                    nav.pushReplacement(MaterialPageRoute<void>(
                      builder: (_) => QuizPage(title: '重做错题', questions: missed),
                    ));
                  },
                  icon: const Icon(Icons.replay),
                  label: Text('重做错题 (${missed.length})'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
            ],
          ),
        ),
      ),
    );
  }
}
