import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/agent_models.dart';
import '../settings/settings_page.dart';
import 'agent_controller.dart';
import 'agent_history_page.dart';
import 'agent_links.dart';
import 'agent_widgets.dart';

/// Whether the assistant can be used right now; retried when the page asks again.
final agentStatusProvider = FutureProvider.autoDispose<AgentStatus>(
  (ref) => ref.watch(agentApiProvider).status(),
  // A wrong token or a server without the assistant does not fix itself; show it at once and let
  // the learner retry (the banner has a button), instead of Riverpod's silent backoff.
  retry: (_, _) => null,
);

/// The conversation with the study assistant: ask about the lessons (learn), or have it write
/// questions that wait here for the learner's decision (create).
class AgentPage extends ConsumerStatefulWidget {
  const AgentPage({super.key, required this.args, this.initialText = ''});

  final AgentArgs args;

  /// Put in the text box, not sent: the learner finishes the sentence.
  final String initialText;

  @override
  ConsumerState<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends ConsumerState<AgentPage> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialText,
  );
  final _focus = FocusNode();
  final _scroll = ScrollController();

  AgentArgs get args => widget.args;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _prompts {
    if (args.isCreate) return const ['出 5 道单选题', '出 3 道判断题', '出几道偏难的题'];
    if (args.questionId.isNotEmpty) {
      return const ['为什么我选的不对？', '再讲细一点', '举个例子帮我记住'];
    }
    if (args.lessonId.isNotEmpty) {
      return const ['讲一下这一节', '这一节有哪些考点？', '出几道题考考我'];
    }
    return const ['我哪里比较薄弱？', '帮我安排一下复习顺序', '出几道题考考我'];
  }

  void _send([String? text]) {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    _input.clear();
    ref.read(agentControllerProvider(args).notifier).send(t);
    _scrollToEnd();
  }

  /// Follows the answer as it is written, unless the learner scrolled up to read something;
  /// [force] goes to the end whatever (a stored conversation that was just opened).
  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (force || max - _scroll.offset < 160) _scroll.jumpTo(max);
    });
  }

  void _revise(String draftId) {
    final prompt = ref
        .read(agentControllerProvider(args).notifier)
        .revisionPrompt(draftId);
    _input.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _focus.requestFocus();
  }

  void _openHistory() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const AgentHistoryPage()),
  );

  /// Leaves this conversation for a new one that starts from the same place.
  void _newConversation() {
    final a = args;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AgentPage(
          args: AgentArgs(
            mode: a.mode,
            bankId: a.bankId,
            lessonId: a.lessonId,
            questionId: a.questionId,
            fresh: DateTime.now().microsecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  void _openSettings() =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));

  /// Why the assistant cannot be used, if it cannot, and what to do about it.
  AgentBanner? _banner(bool hasToken, AsyncValue<AgentStatus> status) {
    if (!hasToken) {
      return AgentBanner(
        message: '还没有填访问令牌。到「设置 → AI 解读」填写后台设置的访问令牌。',
        actionLabel: '去设置',
        onAction: _openSettings,
      );
    }
    return status.when(
      loading: () => null,
      data: (s) => s.available ? null : AgentBanner(message: 'AI 助手暂时不可用'),
      error: (e, _) {
        final code = e is AgentException ? e.status : null;
        if (code == 401) {
          return AgentBanner(
            message: e.toString(),
            actionLabel: '去设置',
            onAction: _openSettings,
          );
        }
        if (code == 404) return AgentBanner(message: e.toString());
        return AgentBanner(
          message: e.toString(),
          actionLabel: '重试',
          onAction: () => ref.invalidate(agentStatusProvider),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentControllerProvider(args));
    final controller = ref.read(agentControllerProvider(args).notifier);
    final hasToken = ref.watch(
      aiSettingsProvider.select((s) => s.token.isNotEmpty),
    );
    final status = hasToken
        ? ref.watch(agentStatusProvider)
        : const AsyncValue<AgentStatus>.loading();
    final ready = hasToken && (status.value?.available ?? false);
    final banner = _banner(hasToken, status);
    ref.listen(
      agentControllerProvider(args),
      (prev, next) => _scrollToEnd(force: prev?.opening == true && !next.opening),
    );

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(args.isCreate ? 'AI 出题' : '问 AI'),
        actions: [
          if (state.messages.isNotEmpty)
            IconButton(
              key: const ValueKey('agent-new'),
              tooltip: '新对话',
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: _newConversation,
            ),
          IconButton(
            key: const ValueKey('agent-history'),
            tooltip: '历史对话',
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          ?banner,
          if (ready && args.isCreate && !status.value!.verified)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                '后台没有配置复核模型，出的题不会经过独立复核',
                style: theme.textTheme.labelSmall,
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: state.opening
                    ? const Center(
                        key: ValueKey('agent-opening'),
                        child: CircularProgressIndicator(),
                      )
                    : state.openError != null
                    ? Center(
                        key: const ValueKey('agent-open-error'),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                state.openError!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: theme.colorScheme.error),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton(onPressed: controller.open, child: const Text('重试')),
                                  OutlinedButton(onPressed: _openHistory, child: const Text('回到历史')),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    : state.messages.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            args.isCreate
                                ? '告诉我出几道题、什么题型，我会依据讲义原文出题，出好的题先放在这里，由你决定是否采纳。'
                                : '可以问我讲义里的内容、你的薄弱点，或者让我出题考你。',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 16),
                          QuickPrompts(
                            prompts: _prompts,
                            enabled: ready,
                            onPick: _send,
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: state.messages.length,
                        itemBuilder: (context, i) {
                          final m = state.messages[i];
                          if (m.role == 'user') return UserBubble(m.text);
                          return AssistantMessage(
                            key: ValueKey('msg-${m.id}'),
                            message: m,
                            drafts: state.drafts,
                            onLink: (href) => openAgentLink(context, ref, href),
                            onAccept: controller.accept,
                            onDiscard: controller.discard,
                            onRevise: _revise,
                          );
                        },
                      ),
              ),
            ),
          ),
          AgentInputBar(
            controller: _input,
            focusNode: _focus,
            busy: state.busy,
            canSend: ready && !state.opening && state.openError == null,
            hint: ready
                ? (args.isCreate ? '说说想出什么题' : '问点什么')
                : (hasToken ? '连接助手后才能提问' : '先填写访问令牌'),
            onSend: _send,
            onStop: controller.stop,
          ),
        ],
      ),
    );
  }
}
