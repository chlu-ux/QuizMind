import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../data/agent_models.dart';
import 'agent_controller.dart';
import 'agent_page.dart';

/// The conversations with the assistant that the server keeps, newest first.
class AgentHistoryPage extends ConsumerStatefulWidget {
  const AgentHistoryPage({super.key});

  @override
  ConsumerState<AgentHistoryPage> createState() => _AgentHistoryPageState();
}

class _AgentHistoryPageState extends ConsumerState<AgentHistoryPage> {
  final _items = <AgentConversationItem>[];
  bool _hasMore = false;
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || !ref.read(aiSettingsProvider).token.isNotEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(agentApiProvider).conversations(before: more && _items.isNotEmpty ? _items.last.updatedAt : null);
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(page.items);
        _hasMore = page.hasMore;
        _loaded = true;
      });
    } on AgentException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '出错了：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(AgentConversationItem c) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentPage(
          args: AgentArgs(
            mode: c.mode,
            bankId: c.bankId,
            lessonId: c.lessonId,
            questionId: c.questionId,
            conversationId: c.id,
          ),
        ),
      ),
    );
    // Cards may have been decided on in there.
    if (mounted) await _load();
  }

  Future<void> _delete(AgentConversationItem c) async {
    final pending = c.pendingDrafts > 0 ? '\n还有 ${c.pendingDrafts} 道没处理的草稿也会被丢弃。' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这场对话？'),
        content: Text('删除后无法恢复。$pending'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(agentApiProvider).deleteConversation(c.id);
      if (mounted) setState(() => _items.removeWhere((x) => x.id == c.id));
    } on AgentException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bankTitles = {for (final b in ref.watch(banksProvider).value ?? const []) b.id: b.title};
    final hasToken = ref.watch(aiSettingsProvider.select((s) => s.token.isNotEmpty));
    Widget body;
    if (!hasToken) {
      body = const Center(key: ValueKey('history-no-token'), child: Text('还没有填访问令牌。到「设置 → AI 解读」填写后台设置的访问令牌。'));
    } else if (_error != null) {
      body = Center(
        key: const ValueKey('history-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    } else if (_loaded && _items.isEmpty) {
      body = const Center(key: ValueKey('history-empty'), child: Text('还没有对话'));
    } else if (!_loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        children: [
          for (final c in _items)
            ListTile(
              key: ValueKey('history-${c.id}'),
              title: Text(c.title.isEmpty ? '（没有标题）' : c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  c.mode == 'create' ? '出题' : '问 AI',
                  if (bankTitles[c.bankId] != null) bankTitles[c.bankId]!,
                  DateFormat('M月d日 HH:mm').format(DateTime.fromMillisecondsSinceEpoch(c.updatedAt)),
                  if (c.pendingDrafts > 0) '${c.pendingDrafts} 道草稿待处理',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: c.pendingDrafts > 0 ? TextStyle(color: theme.colorScheme.error) : null,
              ),
              onTap: () => _open(c),
              trailing: IconButton(
                tooltip: '删除对话',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(c),
              ),
            ),
          if (_hasMore)
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton(
                key: const ValueKey('history-more'),
                onPressed: _loading ? null : () => _load(more: true),
                child: Text(_loading ? '加载中…' : '加载更多'),
              ),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('历史对话')),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: body)),
    );
  }
}
