import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/ai_chat.dart';
import '../../data/ai_prompt.dart';
import '../../data/database.dart';
import '../settings/settings_page.dart';

/// "AI 解读" under an answered question: asks the model, streams the answer in,
/// and saves it (replacing any earlier one) once it is complete. A saved
/// explanation is shown straight away, also offline.
///
/// Give it a key per question: moving to another question must start from scratch.
class AiExplainCard extends ConsumerStatefulWidget {
  const AiExplainCard({super.key, required this.question, required this.selected});

  final Question question;

  /// The option indexes the learner picked.
  final List<int> selected;

  @override
  ConsumerState<AiExplainCard> createState() => _AiExplainCardState();
}

class _AiExplainCardState extends ConsumerState<AiExplainCard> {
  StreamSubscription<String>? _sub;
  CancelToken? _cancel;
  String? _partial; // non-null while a request is running
  String? _error;

  bool get _loading => _partial != null;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _cancel?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    _cancel = null;
  }

  void _ask() {
    final config = ref.read(aiSettingsProvider).effective;
    if (config == null) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: const Text('还没有 AI 配置：连接服务器同步，或在设置里手动填写'),
        action: SnackBarAction(
          label: '去设置',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
        ),
      ));
      return;
    }
    final q = widget.question;
    final selected = widget.selected;
    final repo = ref.read(repositoryProvider);
    final cancel = CancelToken();
    final buffer = StringBuffer();
    _cancel = cancel;
    setState(() {
      _partial = '';
      _error = null;
    });
    _sub = ref
        .read(aiChatProvider)
        .stream(config, buildExplainMessages(q, selected), cancel: cancel)
        .listen(
      (piece) {
        buffer.write(piece);
        if (mounted) setState(() => _partial = buffer.toString());
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _partial = null;
          _error = e is AiException ? e.message : '解读失败：$e';
        });
      },
      onDone: () async {
        final text = buffer.toString().trim();
        if (text.isNotEmpty) {
          await repo.saveNote(
            questionId: q.id,
            content: text,
            model: config.model,
            promptVersion: aiPromptVersion,
            selected: selected,
          );
        }
        if (mounted) setState(() => _partial = null);
      },
      cancelOnError: true,
    );
  }

  void _cancelRequest() {
    _stop();
    setState(() => _partial = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = ref.watch(_noteProvider(widget.question.id)).value;
    final text = _loading ? _partial! : note?.content;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('AI 解读', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_loading)
              TextButton(onPressed: _cancelRequest, child: const Text('停止'))
            else if (note != null) ...[
              IconButton(
                tooltip: '复制',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: note.content));
                  messenger.showSnackBar(const SnackBar(content: Text('已复制')));
                },
              ),
              TextButton(onPressed: _ask, child: const Text('重新解读')),
            ],
          ]),
          if (text != null && text.isNotEmpty) ...[
            const SizedBox(height: 4),
            MarkdownBody(data: text, selectable: !_loading),
          ],
          if (_loading && (text == null || text.isEmpty))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('正在思考…'),
              ]),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (!_loading && note == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton.tonalIcon(
                onPressed: _ask,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: Text(_error == null ? '让 AI 讲解这道题' : '重试'),
              ),
            ),
          if (!_loading && note != null && note.model.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('由 ${note.model} 生成，已保存在本机', style: theme.textTheme.labelSmall),
            ),
        ]),
      ),
    );
  }
}

final _noteProvider = StreamProvider.autoDispose.family<AiNote?, String>(
  (ref, questionId) => ref.watch(repositoryProvider).watchNote(questionId),
);
