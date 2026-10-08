import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/agent_models.dart';
import '../../data/media_text.dart';
import '../quiz/quiz_media.dart';
import 'agent_controller.dart';
import 'agent_files.dart';

/// What the learner said.
class UserBubble extends StatelessWidget {
  const UserBubble(
    this.text, {
    super.key,
    this.attachments = const [],
    this.localImages = const {},
  });

  final String text;

  /// The files this message carried: pictures as thumbnails, the others as tags under the words.
  final List<AgentAttachment> attachments;

  /// Pictures chosen on this device, by attachment id; the others are fetched to be shown.
  final Map<String, Uint8List> localImages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, top: 8, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              text,
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
            if (attachments.any((a) => a.isImage))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in attachments)
                      if (a.isImage)
                        AttachedImage(
                          key: ValueKey('agent-image-${a.id}'),
                          attachment: a,
                          local: localImages[a.id],
                        ),
                  ],
                ),
              ),
            if (attachments.any((a) => !a.isImage))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final a in attachments)
                      if (!a.isImage)
                        Container(
                          key: const ValueKey('agent-file-tag'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '📎 ${a.name}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The bytes of a picture kept on the server, fetched with the access token. Dropped when nothing
/// shows it.
final agentImageProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, id) => ref.watch(agentApiProvider).attachmentBytes(id),
);

/// A picture the learner gave the assistant, as a small tile that opens it large.
class AttachedImage extends ConsumerWidget {
  const AttachedImage({super.key, required this.attachment, this.local});

  final AgentAttachment attachment;

  /// The picture's bytes when it was chosen on this device; otherwise it is fetched.
  final Uint8List? local;

  static const _side = 88.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bytes = local != null
        ? AsyncValue.data(local!)
        : ref.watch(agentImageProvider(attachment.id));
    return Semantics(
      label: '查看图片 ${attachment.name}',
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: bytes.value == null
            ? null
            : () => showAgentImage(context, bytes.value!, attachment.name),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: _side,
            height: _side,
            child: bytes.when(
              data: (b) => Image.memory(
                b,
                fit: BoxFit.cover,
                cacheWidth: 300,
                errorBuilder: (_, _, _) => _tileNote(theme, '无法显示'),
              ),
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (_, _) => _tileNote(theme, '无法显示'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tileNote(ThemeData theme, String text) => ColoredBox(
    color: theme.colorScheme.surface,
    child: Center(child: Text(text, style: theme.textTheme.labelSmall)),
  );
}

/// Shows a picture large; pinch to zoom, tap outside to close.
Future<void> showAgentImage(
  BuildContext context,
  Uint8List bytes,
  String name,
) => showDialog<void>(
  context: context,
  builder: (_) => Dialog.fullscreen(
    backgroundColor: Colors.black87,
    child: Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            key: const ValueKey('agent-image-big'),
            child: Center(child: Image.memory(bytes, semanticLabel: name)),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: IconButton(
              key: const ValueKey('agent-image-close'),
              tooltip: '关闭',
              color: Colors.white,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      ],
    ),
  ),
);

/// One line about a lookup the assistant is doing ("在讲义里查找…"); faded once it is done.
class ToolStatusRow extends StatelessWidget {
  const ToolStatusRow(this.row, {super.key});

  final ToolRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final done = row.status != 'running';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Opacity(
        opacity: done ? 0.6 : 1,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.status == 'running')
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Icon(
                row.status == 'error' ? Icons.error_outline : Icons.check,
                size: 14,
                color: row.status == 'error' ? theme.colorScheme.error : muted,
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                row.label,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The assistant's side of the conversation: its lookups, its words and the drafts it made.
class AssistantMessage extends StatelessWidget {
  const AssistantMessage({
    super.key,
    required this.message,
    required this.drafts,
    required this.onLink,
    required this.onAccept,
    required this.onDiscard,
    required this.onRevise,
    required this.onSetAll,
  });

  final AgentMsg message;
  final Map<String, DraftEntry> drafts;
  final void Function(String? href) onLink;
  final void Function(String id) onAccept;
  final void Function(String id) onDiscard;
  final void Function(String id) onRevise;
  final void Function(List<String> ids, bool adopt) onSetAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;
    final lookingUp = m.tools.any((t) => t.status == 'running');
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(right: 16, top: 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in m.tools) ToolStatusRow(t),
            if (m.text.isNotEmpty)
              QuizMarkdown(m.text, selectable: !m.streaming, onTapLink: onLink),
            if (m.streaming && m.text.isEmpty && !lookingUp)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在思考…'),
                  ],
                ),
              ),
            if (m.draftIds.any(drafts.containsKey))
              DraftGroup(
                key: ValueKey('drafts-${m.id}'),
                entries: [
                  for (final id in m.draftIds) ?drafts[id],
                ],
                onAccept: onAccept,
                onDiscard: onDiscard,
                onRevise: onRevise,
                onSetAll: onSetAll,
              ),
            if (m.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  m.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (m.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  m.note!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The questions the assistant wrote in one answer, as one compact card: a line per question with a
/// switch for adopting it, and the question itself unfolding when tapped. A long run of questions
/// takes a screen or two instead of a page each.
class DraftGroup extends StatefulWidget {
  const DraftGroup({
    super.key,
    required this.entries,
    required this.onAccept,
    required this.onDiscard,
    required this.onRevise,
    required this.onSetAll,
  });

  final List<DraftEntry> entries;
  final void Function(String id) onAccept;
  final void Function(String id) onDiscard;
  final void Function(String id) onRevise;
  final void Function(List<String> ids, bool adopt) onSetAll;

  @override
  State<DraftGroup> createState() => _DraftGroupState();
}

class _DraftGroupState extends State<DraftGroup> {
  /// Questions shown unfolded. One or two are shown at once; more are folded up until tapped.
  late final Set<String> _open = {
    if (widget.entries.length <= 2) for (final e in widget.entries) e.draft.id,
  };

  /// Folded up as a whole, leaving the header.
  bool _folded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = widget.entries;
    final adopted = entries.where((e) => e.phase == DraftPhase.accepted).length;
    final busy = entries.any((e) => e.phase == DraftPhase.working);
    final allAdopted = adopted == entries.length;
    final ids = [for (final e in entries) e.draft.id];
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(top: 8),
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('drafts-header'),
            onTap: () => setState(() => _folded = !_folded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Icon(Icons.fact_check_outlined, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('出了 ${entries.length} 道题', style: theme.textTheme.titleSmall),
                        Text(
                          '已采纳 $adopted 道 · 采纳的题在题库里，可随时取消',
                          key: const ValueKey('drafts-summary'),
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (entries.length > 1)
                    TextButton(
                      key: const ValueKey('drafts-all'),
                      onPressed: busy ? null : () => widget.onSetAll(ids, !allAdopted),
                      child: Text(allAdopted ? '全部取消' : '全部采纳'),
                    ),
                  Icon(_folded ? Icons.expand_more : Icons.expand_less, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (!_folded)
            for (var i = 0; i < entries.length; i++) ...[
              const Divider(height: 1),
              DraftTile(
                key: ValueKey('draft-${entries[i].draft.id}'),
                number: i + 1,
                entry: entries[i],
                open: _open.contains(entries[i].draft.id),
                onToggleOpen: () => setState(() {
                  final id = entries[i].draft.id;
                  if (!_open.remove(id)) _open.add(id);
                }),
                onAccept: () => widget.onAccept(entries[i].draft.id),
                onDiscard: () => widget.onDiscard(entries[i].draft.id),
                onRevise: () => widget.onRevise(entries[i].draft.id),
              ),
            ],
        ],
      ),
    );
  }
}

/// One question of a [DraftGroup]: a line with the stem and the adopt switch; the options, the
/// explanation and the source show when it is [open].
class DraftTile extends StatelessWidget {
  const DraftTile({
    super.key,
    required this.number,
    required this.entry,
    required this.open,
    required this.onToggleOpen,
    required this.onAccept,
    required this.onDiscard,
    required this.onRevise,
  });

  final int number;
  final DraftEntry entry;
  final bool open;
  final VoidCallback onToggleOpen;
  final VoidCallback onAccept;
  final VoidCallback onDiscard;
  final VoidCallback onRevise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = entry.draft;
    final working = entry.phase == DraftPhase.working;
    final adopted = entry.phase == DraftPhase.accepted;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('draft-row-${d.id}'),
          onTap: onToggleOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 22,
                  child: Text('$number', style: theme.textTheme.labelLarge?.copyWith(color: muted)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plainText(d.stem).replaceAll(RegExp(r'\s+'), ' '),
                        maxLines: open ? null : 2,
                        overflow: open ? null : TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: adopted ? null : muted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          d.type == 'judge' ? '判断题' : '单选题',
                          '难度 ${'★' * d.difficulty.clamp(1, 5)}',
                          if (!d.verified) '未经独立复核',
                        ].join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 56,
                  child: Center(
                    child: working
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Switch(
                            key: ValueKey('draft-switch-${d.id}'),
                            value: adopted,
                            onChanged: (on) => on ? onAccept() : onDiscard(),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(34, 0, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                QuizMarkdown(d.stem, selectable: false),
                for (var i = 0; i < d.options.length; i++)
                  _OptionRow(index: i, text: d.options[i], correct: i == d.answerIndex),
                if (d.explanation.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('解析', style: theme.textTheme.labelLarge),
                  QuizMarkdown(d.explanation, selectable: false),
                ],
                if (d.sourceQuote.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('出处原文', style: theme.textTheme.labelLarge),
                  Text('「${d.sourceQuote}」', style: theme.textTheme.bodySmall),
                ],
                if (entry.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(entry.error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: ValueKey('draft-revise-${d.id}'),
                    onPressed: working ? null : onRevise,
                    child: const Text('让它改改'),
                  ),
                ),
              ],
            ),
          )
        else if (entry.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(34, 0, 12, 8),
            child: Text(entry.error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.index,
    required this.text,
    required this.correct,
  });

  final int index;
  final String text;
  final bool correct;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: correct
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: correct
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${String.fromCharCode(65 + index)}.  ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Expanded(child: Text(text)),
          if (correct)
            Icon(
              Icons.check_circle,
              size: 18,
              color: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }
}

/// A banner above the conversation saying why the assistant cannot be used, with a way to fix it.
class AgentBanner extends StatelessWidget {
  const AgentBanner({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
      ),
    );
  }
}

/// The few questions worth asking first, so an empty page is not a blank box.
class QuickPrompts extends StatelessWidget {
  const QuickPrompts({
    super.key,
    required this.prompts,
    required this.onPick,
    required this.enabled,
  });

  final List<String> prompts;
  final ValueChanged<String> onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in prompts)
          ActionChip(
            label: Text(p),
            onPressed: enabled ? () => onPick(p) : null,
          ),
      ],
    );
  }
}

/// The text box with its send / stop button.
class AgentInputBar extends StatelessWidget {
  const AgentInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.canSend,
    required this.hint,
    required this.onSend,
    required this.onStop,
    this.files = const [],
    this.canAttach = false,
    this.vision = false,
    this.canAttachImage = false,
    this.onAttach,
    this.onRemoveFile,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final bool canSend;
  final String hint;
  final VoidCallback onSend;
  final VoidCallback onStop;

  /// Files chosen for the next message.
  final List<PendingFile> files;
  final bool canAttach;

  /// The model can look at pictures: the plus button then offers a file or a picture.
  final bool vision;
  final bool canAttachImage;
  final void Function(AttachKind kind)? onAttach;
  final void Function(int key)? onRemoveFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (files.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 6),
                  child: Column(
                    key: const ValueKey('agent-files'),
                    children: [
                      for (final f in files)
                        _FileRow(
                          file: f,
                          onRemove: () => onRemoveFile?.call(f.key),
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (vision && canSend && canAttach)
                    PopupMenuButton<AttachKind>(
                      key: const ValueKey('agent-attach'),
                      tooltip: '添加文件或图片',
                      icon: const Icon(Icons.add_circle_outline),
                      onSelected: onAttach,
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          key: ValueKey('agent-attach-file'),
                          value: AttachKind.file,
                          child: Text('添加文件'),
                        ),
                        PopupMenuItem(
                          key: const ValueKey('agent-attach-image'),
                          value: AttachKind.image,
                          enabled: canAttachImage,
                          child: const Text('添加图片'),
                        ),
                      ],
                    )
                  else
                    IconButton(
                      key: const ValueKey('agent-attach'),
                      tooltip: canAttach
                          ? (vision ? '添加文件或图片' : '添加 .md / .txt 等文本文件')
                          : '文件数量到上限了',
                      onPressed: canSend && canAttach
                          ? () => onAttach?.call(AttachKind.file)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('agent-input'),
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: hint,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (busy)
                    IconButton.filledTonal(
                      key: const ValueKey('agent-stop'),
                      tooltip: '停止',
                      onPressed: onStop,
                      icon: const Icon(Icons.stop),
                    )
                  else
                    IconButton.filled(
                      key: const ValueKey('agent-send'),
                      tooltip: '发送',
                      onPressed: canSend ? onSend : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.onRemove});

  final PendingFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = file.status == FileStatus.error;
    final size = file.size < 1024
        ? '${file.size} B'
        : '${(file.size / 1024).round()} KB';
    return Container(
      key: const ValueKey('agent-file'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: failed
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (file.preview != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  file.preview!,
                  key: const ValueKey('agent-file-preview'),
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  cacheWidth: 120,
                  errorBuilder: (_, _, _) =>
                      const SizedBox(width: 36, height: 36),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.preview != null ? file.name : '📎 ${file.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  switch (file.status) {
                    FileStatus.uploading => '上传中…',
                    FileStatus.error => file.error ?? '',
                    FileStatus.ready => size,
                  },
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('agent-file-remove'),
            tooltip: '移除文件',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}
