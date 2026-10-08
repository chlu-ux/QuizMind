import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_page.dart';
import '../exam/exam_setup_page.dart';
import '../quiz/learn_page.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../stats/stats_page.dart';
import 'goal_card.dart';
import 'question_list_page.dart';
import 'modules_page.dart';
import 'search_page.dart';
import 'topics_page.dart';
import 'sync_widgets.dart';

/// Bank list. On wide screens the bank detail sits to the right of the list;
/// on narrow screens tapping a bank opens it full screen.
class BanksPage extends ConsumerStatefulWidget {
  const BanksPage({super.key});

  @override
  ConsumerState<BanksPage> createState() => _BanksPageState();
}

class _BanksPageState extends ConsumerState<BanksPage> {
  String? selectedId;

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(banksProvider);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      appBar: AppBar(title: const Text('题库'), actions: const [SyncButton()]),
      body: banks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyBanks();
          final selected = list.where((b) => b.id == selectedId).firstOrNull ?? list.first;
          final listView = RefreshIndicator(
            onRefresh: () => ref.read(syncProvider.notifier).run(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final b = list[i];
                return ListTile(
                  selected: wide && b.id == selected.id,
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(b.title),
                  subtitle: b.description.isEmpty ? null : Text(b.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text('${b.questionCount} 题'),
                  onTap: () {
                    if (wide) {
                      setState(() => selectedId = b.id);
                    } else {
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => Scaffold(appBar: AppBar(title: Text(b.title)), body: BankDetail(bank: b, showTitle: false)),
                      ));
                    }
                  },
                );
              },
            ),
          );
          final withGoal = Column(children: [const GoalCard(), Expanded(child: listView)]);
          if (!wide) return withGoal;
          return Row(children: [
            SizedBox(width: 320, child: withGoal),
            const VerticalDivider(width: 1),
            Expanded(child: BankDetail(key: ValueKey(selected.id), bank: selected)),
          ]);
        },
      ),
    );
  }
}

class _EmptyBanks extends ConsumerWidget {
  const _EmptyBanks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(settingsProvider.select((s) => s.configured));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_download_outlined, size: 56),
          const SizedBox(height: 12),
          Text(configured ? '还没有题库，点右上角同步' : '先到「设置」填写服务器地址，再同步题库', textAlign: TextAlign.center),
          if (configured) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: () => ref.read(syncProvider.notifier).run(), child: const Text('立即同步')),
          ],
        ]),
      ),
    );
  }
}

class BankDetail extends ConsumerStatefulWidget {
  const BankDetail({super.key, required this.bank, this.showTitle = true});

  final Bank bank;

  /// Off when the page already shows the bank's name in its app bar.
  final bool showTitle;

  @override
  ConsumerState<BankDetail> createState() => _BankDetailState();
}

class _BankDetailState extends ConsumerState<BankDetail> {
  late Future<BankStats> _stats;
  bool _examInProgress = false;
  int? _seqIndex; // where "按顺序刷题" left off, if anywhere
  int? _unseen; // questions never answered, once the stats have loaded
  ({int total, int read}) _lessons = (total: 0, read: 0); // the bank's study text; total 0 = it has none

  Bank get bank => widget.bank;

  @override
  void initState() {
    super.initState();
    _stats = _loadStats();
    _loadExamDraft();
    _loadSequential();
    _loadLessons();
  }

  Future<void> _loadLessons() async {
    final summary = await ref.read(repositoryProvider).lessonSummary(bank.id);
    if (mounted && summary != _lessons) setState(() => _lessons = summary);
  }

  Future<BankStats> _loadStats() async {
    final s = await ref.read(repositoryProvider).bankStats(bank.id);
    if (mounted) setState(() => _unseen = s.total - s.answered);
    return s;
  }

  /// The 1-based place in the bank's fixed order that sequential practice continues from.
  Future<void> _loadSequential() async {
    final id = ref.read(sessionStoreProvider).sequentialPosition(bank.id);
    int? index;
    if (id != null) {
      final qs = await ref.read(repositoryProvider).bankQuestions(bank.id);
      final i = qs.indexWhere((q) => q.id == id);
      if (i > 0) index = i;
    }
    if (mounted && index != _seqIndex) setState(() => _seqIndex = index);
  }

  Future<void> _loadExamDraft() async {
    final draft = await ref.read(repositoryProvider).examDraft(bank.id);
    if (mounted && (draft != null) != _examInProgress) setState(() => _examInProgress = draft != null);
  }

  void _refresh() {
    setState(() {
      _stats = _loadStats();
      });
    _loadExamDraft();
    _loadSequential();
    _loadLessons();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A finished sync rewrites the bank rows; re-read the stats then.
    ref.listen(banksProvider, (_, _) => _refresh());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.showTitle) Text(bank.title, style: theme.textTheme.headlineSmall),
            if (bank.description.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: widget.showTitle ? 4 : 0),
                child: Text(
                  bank.description,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 16),
            FutureBuilder<BankStats>(
              future: _stats,
              builder: (context, snap) {
                final s = snap.data;
                if (s == null) return const SizedBox(height: 96);
                final progress = s.total == 0 ? 0.0 : s.answered / s.total;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${s.answered}',
                                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(text: ' / ${s.total} 题已做', style: theme.textTheme.titleMedium),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(value: progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                        const SizedBox(height: 8),
                        Text('不重复计数 · 最近一次答对 ${s.correct} 题', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            if (_lessons.total > 0) ...[
              _GridTile(
                icon: Icons.auto_stories_outlined,
                title: '先学后练',
                subtitle: '讲义 ${_lessons.read} / ${_lessons.total} 节已读',
                onTap: () => _open(LearnPage(bank: bank)),
              ),
              const SizedBox(height: 12),
            ],
            // Sequential practice is the main action: it always carries on from where the learner last was.
            // Starting over is "从第 1 题重做" inside the quiz.
            _PrimaryAction(
              onPressed: () => _start(QuizOrder.sequential, onlyNew: false),
              icon: Icons.format_list_numbered,
              title: '按顺序刷题',
              subtitle: _seqIndex == null ? '按题库原顺序，从第 1 题开始' : '从第 ${_seqIndex! + 1} 题继续',
            ),
            const SizedBox(height: 12),
            Consumer(
              builder: (context, ref, _) {
                final wrong = ref.watch(bankWrongBookProvider(bank.id)).value?.length ?? 0;
                final unseen = _unseen;
                final tiles = [
                  _GridTile(icon: Icons.shuffle, title: '随机刷题', onTap: () => _start(QuizOrder.random, onlyNew: false)),
                  _GridTile(
                    icon: Icons.fiber_new_outlined,
                    title: '只做没做过的',
                    subtitle: unseen == null ? null : (unseen == 0 ? '都做过了' : '还有 $unseen 题'),
                    onTap: unseen == 0 ? null : () => _start(QuizOrder.random, onlyNew: true),
                  ),
                  _GridTile(icon: Icons.folder_open_outlined, title: '按模块刷题', onTap: () => _open(ModulesPage(bank: bank))),
                  _GridTile(icon: Icons.label_outline, title: '按知识点刷题', onTap: () => _open(TopicsPage(bank: bank))),
                  _GridTile(
                    icon: Icons.assignment_outlined,
                    title: '模拟考试',
                    subtitle: _examInProgress ? '有未完成的' : null,
                    onTap: () => _open(ExamSetupPage(bank: bank)),
                  ),
                  _GridTile(icon: Icons.search, title: '搜索题目', onTap: () => _open(SearchPage(bank: bank))),
                  _GridTile(
                    icon: Icons.error_outline,
                    title: '错题本',
                    subtitle: wrong == 0 ? '没有错题' : '$wrong 题',
                    onTap: wrong == 0
                        ? null
                        : () => _open(QuestionListPage(kind: QuestionListKind.wrongBook, initialBankId: bank.id)),
                  ),
                  _GridTile(icon: Icons.bar_chart, title: '统计分析', onTap: () => _open(StatsPage(bank: bank))),
                  // The assistant lives on the server, so this only makes sense once there is one.
                  if (ref.watch(settingsProvider).configured)
                    _GridTile(
                      icon: Icons.auto_awesome_outlined,
                      title: 'AI 助手',
                      subtitle: '答疑、小测、出题',
                      onTap: () => _open(AgentPage(args: AgentArgs(bankId: bank.id))),
                    ),
                ];
                // Two to a row, both as tall as the taller one so a longer label never ragged the grid.
                return Column(
                  children: [
                    for (var i = 0; i < tiles.length; i += 2)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: tiles[i]),
                              const SizedBox(width: 12),
                              Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) _refresh();
  }

  Future<void> _start(QuizOrder order, {required bool onlyNew}) async {
    final repo = ref.read(repositoryProvider);
    var qs = await repo.bankQuestions(bank.id);
    if (onlyNew) {
      final answered = await repo.answeredIds(qs.map((q) => q.id));
      qs = qs.where((q) => !answered.contains(q.id)).toList();
    }
    if (!mounted) return;
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(onlyNew ? '这个题库的题都做过了' : '这个题库还没有题目')));
      return;
    }
    final ordered = orderQuestions(qs, order);
    final store = ref.read(sessionStoreProvider);
    var startAt = 0;
    ValueChanged<Question?>? onPosition;
    if (order == QuizOrder.sequential) {
      // Picks up at the question the learner was last on, wherever the bank has grown since.
      if (store.sequentialPosition(bank.id) case final id?) {
        startAt = ordered.indexWhere((q) => q.id == id).clamp(0, ordered.length - 1);
      }
      onPosition = (q) => store.setSequentialPosition(bank.id, q?.id);
    }
    if (!mounted) return;
    await startQuiz(context, title: bank.title, questions: ordered, startAt: startAt, scope: bank.id, onPosition: onPosition);
    if (mounted) _refresh();
  }
}

/// The one filled button on a bank page.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.onPressed, required this.icon, required this.title, required this.subtitle});

  final VoidCallback onPressed;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onPrimary;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.85))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry of the bank page's grid: an icon beside a title and, when there is something to say, a short status line.
/// A null [onTap] greys it out.
class _GridTile extends StatelessWidget {
  const _GridTile({required this.icon, required this.title, required this.onTap, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final fg = enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: enabled ? scheme.primary : fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                    if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
