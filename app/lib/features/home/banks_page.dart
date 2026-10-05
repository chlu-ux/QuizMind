import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import '../../data/session_store.dart';
import '../exam/exam_setup_page.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/resume.dart';
import '../stats/stats_page.dart';
import 'goal_card.dart';
import 'question_list_page.dart';
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
                        builder: (_) => Scaffold(appBar: AppBar(title: Text(b.title)), body: BankDetail(bank: b)),
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
  const BankDetail({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<BankDetail> createState() => _BankDetailState();
}

class _BankDetailState extends ConsumerState<BankDetail> {
  late Future<BankStats> _stats;
  SavedSession? _saved;
  bool _examInProgress = false;
  int? _seqIndex; // where "按顺序刷题" left off, if anywhere

  Bank get bank => widget.bank;

  @override
  void initState() {
    super.initState();
    _stats = ref.read(repositoryProvider).bankStats(bank.id);
    _saved = ref.read(sessionStoreProvider).load(bank.id);
    _loadExamDraft();
    _loadSequential();
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
      _stats = ref.read(repositoryProvider).bankStats(bank.id);
      _saved = ref.read(sessionStoreProvider).load(bank.id);
    });
    _loadExamDraft();
    _loadSequential();
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
            Text(bank.title, style: theme.textTheme.headlineSmall),
            if (bank.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(bank.description)),
            const SizedBox(height: 20),
            FutureBuilder<BankStats>(
              future: _stats,
              builder: (context, snap) {
                final s = snap.data;
                if (s == null) return const SizedBox(height: 72);
                final progress = s.total == 0 ? 0.0 : s.answered / s.total;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('累计做过 ${s.answered} / ${s.total} 题（不重复）· 最近一次答对 ${s.correct} 题'),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            if (_saved case final saved?) ...[
              FilledButton.icon(
                onPressed: _resume,
                icon: const Icon(Icons.play_arrow),
                label: Text('继续上一轮 · 第 ${saved.index + 1} / ${saved.total} 题（本轮已答 ${saved.answered}）'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _start(QuizOrder.random, onlyNew: false),
                icon: const Icon(Icons.shuffle),
                label: const Text('重新随机刷题'),
              ),
            ] else
              FilledButton.icon(
                onPressed: () => _start(QuizOrder.random, onlyNew: false),
                icon: const Icon(Icons.shuffle),
                label: const Text('随机刷题'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _start(QuizOrder.random, onlyNew: true),
              icon: const Icon(Icons.fiber_new_outlined),
              label: const Text('只做没做过的'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _start(QuizOrder.sequential, onlyNew: false),
              icon: const Icon(Icons.format_list_numbered),
              label: Text(_seqIndex == null ? '按顺序刷题' : '按顺序刷题 · 从第 ${_seqIndex! + 1} 题继续'),
            ),
            if (_seqIndex != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _start(QuizOrder.sequential, onlyNew: false, fromStart: true),
                icon: const Icon(Icons.restart_alt),
                label: const Text('按顺序重做（从第 1 题）'),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _open(ExamSetupPage(bank: bank)),
              icon: const Icon(Icons.assignment_outlined),
              label: Text(_examInProgress ? '模拟考试 · 有未完成的考试' : '模拟考试'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _open(TopicsPage(bank: bank)),
              icon: const Icon(Icons.label_outline),
              label: const Text('按知识点刷题'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _open(SearchPage(bank: bank)),
              icon: const Icon(Icons.search),
              label: const Text('搜索题目'),
            ),
            const SizedBox(height: 8),
            Consumer(builder: (context, ref, _) {
              final count = ref.watch(bankWrongBookProvider(bank.id)).value?.length ?? 0;
              return OutlinedButton.icon(
                onPressed: count == 0
                    ? null
                    : () => _open(QuestionListPage(kind: QuestionListKind.wrongBook, initialBankId: bank.id)),
                icon: const Icon(Icons.error_outline),
                label: Text(count == 0 ? '本题库错题本 · 没有错题' : '本题库错题本 · $count 题'),
              );
            }),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _open(StatsPage(bank: bank)),
              icon: const Icon(Icons.bar_chart),
              label: const Text('统计分析'),
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

  Future<void> _start(QuizOrder order, {required bool onlyNew, bool fromStart = false}) async {
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
      if (fromStart) {
        await store.setSequentialPosition(bank.id, null);
      } else if (store.sequentialPosition(bank.id) case final id?) {
        startAt = ordered.indexWhere((q) => q.id == id).clamp(0, ordered.length - 1);
      }
      onPosition = (q) => store.setSequentialPosition(bank.id, q?.id);
    }
    if (!mounted) return;
    await startQuiz(context, title: bank.title, questions: ordered, startAt: startAt, scope: bank.id, onPosition: onPosition);
    if (mounted) _refresh();
  }

  Future<void> _resume() async {
    final saved = _saved;
    if (saved == null) return;
    final plan = await planResume(saved, ref.read(repositoryProvider));
    if (!mounted) return;
    if (plan == null) {
      // Every question in it has since been withdrawn.
      await ref.read(sessionStoreProvider).clear(bank.id);
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上次的题目已不存在，请重新开始')));
      return;
    }
    await startQuiz(context, title: plan.title, questions: plan.questions, startAt: plan.index, scope: bank.id, resume: plan);
    if (mounted) _refresh();
  }
}
