import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import '../../data/session_store.dart';
import '../quiz/quiz_page.dart';
import '../quiz/quiz_session.dart';
import '../quiz/resume.dart';
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
          if (!wide) return listView;
          return Row(children: [
            SizedBox(width: 320, child: listView),
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

  Bank get bank => widget.bank;

  @override
  void initState() {
    super.initState();
    _stats = ref.read(repositoryProvider).bankStats(bank.id);
    _saved = ref.read(sessionStoreProvider).load(bank.id);
  }

  void _refresh() => setState(() {
        _stats = ref.read(repositoryProvider).bankStats(bank.id);
        _saved = ref.read(sessionStoreProvider).load(bank.id);
      });

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
                      Text('已做 ${s.answered} / ${s.total} 题 · 最近一次答对 ${s.correct} 题'),
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
                label: Text('继续刷题 · 第 ${saved.index + 1} / ${saved.total} 题'),
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
              label: const Text('按顺序刷题'),
            ),
          ],
        ),
      ),
    );
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
    await startQuiz(context, title: bank.title, questions: orderQuestions(qs, order), scope: bank.id);
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
