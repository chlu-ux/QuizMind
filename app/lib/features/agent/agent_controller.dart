import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/ulid.dart';
import '../../data/agent_models.dart';
import 'agent_files.dart';

/// Where a conversation starts: which assistant mode and what the learner is looking at, or, with
/// [conversationId], a conversation kept on the server. Two pages with equal args share one
/// conversation while either is open.
class AgentArgs {
  const AgentArgs({
    required this.mode,
    this.bankId = '',
    this.lessonId = '',
    this.questionId = '',
    this.selected = const [],
    this.conversationId = '',
    this.fresh = 0,
  });

  /// learn | create
  final String mode;
  final String bankId;
  final String lessonId;
  final String questionId;
  final List<int> selected;

  /// Set to read a stored conversation back and carry on in it; empty for a new one.
  final String conversationId;

  /// Makes otherwise equal args a different conversation ("new conversation" from a page that
  /// has the same starting point).
  final int fresh;

  bool get isCreate => mode == 'create';

  @override
  bool operator ==(Object other) =>
      other is AgentArgs &&
      other.mode == mode &&
      other.bankId == bankId &&
      other.lessonId == lessonId &&
      other.questionId == questionId &&
      other.conversationId == conversationId &&
      other.fresh == fresh &&
      other.selected.length == selected.length &&
      [
        for (var i = 0; i < selected.length; i++)
          other.selected[i] == selected[i],
      ].every((e) => e);

  @override
  int get hashCode =>
      Object.hash(mode, bankId, lessonId, questionId, conversationId, fresh, Object.hashAll(selected));
}

class ToolRow {
  const ToolRow({required this.id, required this.label, required this.status});

  final String id;
  final String label;

  /// running | done | error
  final String status;
}

class AgentMsg {
  const AgentMsg({
    required this.id,
    required this.role,
    this.text = '',
    this.tools = const [],
    this.draftIds = const [],
    this.streaming = false,
    this.error,
    this.note,
    this.attachments = const [],
    this.localImages = const {},
  });

  final int id;
  final String role; // user | assistant
  final String text;
  final List<ToolRow> tools;

  /// Drafts shown as cards under this message.
  final List<String> draftIds;
  final bool streaming;
  final String? error;

  /// A remark about how the answer ended (stopped, cut short).
  final String? note;

  /// The files this message carried.
  final List<AgentAttachment> attachments;

  /// The bytes of the pictures chosen on this device and sent from here, by attachment id; the others
  /// are fetched from the server to be shown.
  final Map<String, Uint8List> localImages;

  AgentMsg copyWith({
    String? text,
    List<ToolRow>? tools,
    List<String>? draftIds,
    bool? streaming,
    String? error,
    String? note,
  }) => AgentMsg(
    id: id,
    role: role,
    text: text ?? this.text,
    tools: tools ?? this.tools,
    draftIds: draftIds ?? this.draftIds,
    streaming: streaming ?? this.streaming,
    error: error ?? this.error,
    note: note ?? this.note,
    attachments: attachments,
    localImages: localImages,
  );
}

/// The words sent when a file comes with no question.
const fileOnlyText = '请看一下我给你的文件。';

enum FileStatus { uploading, ready, error }

/// A file chosen for the next message: on its way to the server, or kept there waiting to be sent.
class PendingFile {
  const PendingFile({
    required this.key,
    required this.name,
    required this.size,
    required this.status,
    this.isImage = false,
    this.preview,
    this.attachment,
    this.error,
  });

  final int key;
  final String name;
  final int size;
  final FileStatus status;

  /// A picture; [preview] holds its bytes to show it by while it is only on this device.
  final bool isImage;
  final Uint8List? preview;
  final AgentAttachment? attachment;

  /// Why the file was not taken.
  final String? error;

  PendingFile withPreview(Uint8List bytes) => PendingFile(
    key: key,
    name: name,
    size: size,
    status: status,
    isImage: isImage,
    preview: bytes,
    attachment: attachment,
    error: error,
  );

  PendingFile copyWith({
    FileStatus? status,
    AgentAttachment? attachment,
    String? error,
  }) => PendingFile(
    key: key,
    name: name,
    size: size,
    status: status ?? this.status,
    isImage: isImage,
    preview: preview,
    attachment: attachment ?? this.attachment,
    error: error ?? this.error,
  );
}

enum DraftPhase { pending, working, accepted, discarded }

class DraftEntry {
  const DraftEntry(this.draft, {this.phase = DraftPhase.pending, this.error});

  final AgentDraft draft;
  final DraftPhase phase;
  final String? error;

  DraftEntry copyWith({
    DraftPhase? phase,
    String? error,
    bool clearError = false,
  }) => DraftEntry(
    draft,
    phase: phase ?? this.phase,
    error: clearError ? null : (error ?? this.error),
  );
}

class AgentState {
  const AgentState({
    this.messages = const [],
    this.drafts = const {},
    this.busy = false,
    this.opening = false,
    this.openError,
    this.files = const [],
  });

  final List<AgentMsg> messages;
  final Map<String, DraftEntry> drafts;

  /// Files chosen for the next message.
  final List<PendingFile> files;

  bool get uploading => files.any((f) => f.status == FileStatus.uploading);

  List<PendingFile> get readyFiles => [
    for (final f in files)
      if (f.status == FileStatus.ready) f,
  ];

  /// Pictures this conversation holds, sent or chosen.
  int get imageCount =>
      messages.fold<int>(
        0,
        (n, m) => n + m.attachments.where((a) => a.isImage).length,
      ) +
      files.where((f) => f.isImage && f.status != FileStatus.error).length;

  /// Files this conversation holds: the ones sent before and the ones chosen now.
  int get fileCount =>
      messages.fold<int>(0, (n, m) => n + m.attachments.length) +
      files.where((f) => f.status != FileStatus.error).length;

  /// Another file may be added.
  bool get canAttach =>
      fileCount < agentMaxFiles &&
      files.where((f) => f.status != FileStatus.error).length <
          agentMaxFilesPerMessage;

  /// An answer is being written.
  final bool busy;

  /// A stored conversation is being read from the server.
  final bool opening;

  /// Why a stored conversation could not be opened.
  final String? openError;

  AgentState copyWith({
    List<AgentMsg>? messages,
    Map<String, DraftEntry>? drafts,
    bool? busy,
    bool? opening,
    String? openError,
    bool clearOpenError = false,
    List<PendingFile>? files,
  }) => AgentState(
    files: files ?? this.files,
    messages: messages ?? this.messages,
    drafts: drafts ?? this.drafts,
    busy: busy ?? this.busy,
    opening: opening ?? this.opening,
    openError: clearOpenError ? null : (openError ?? this.openError),
  );
}

final agentControllerProvider = NotifierProvider.autoDispose
    .family<AgentController, AgentState, AgentArgs>(AgentController.new);

class AgentController extends Notifier<AgentState> {
  AgentController(this.args);

  final AgentArgs args;

  late final String _conversationId;
  int _nextId = 1;
  int _nextFile = 1;
  CancelToken? _cancel;

  @override
  AgentState build() {
    ref.onDispose(() => _cancel?.cancel());
    if (args.conversationId.isEmpty) {
      _conversationId = newUlid();
      return const AgentState();
    }
    _conversationId = args.conversationId;
    Future.microtask(_open);
    return const AgentState(opening: true);
  }

  String get conversationId => _conversationId;

  /// Reads the stored conversation back: its messages, lookups, notes, and the cards as they stand.
  Future<void> open() => _open();

  Future<void> _open() async {
    state = state.copyWith(opening: true, clearOpenError: true);
    try {
      final stored = await ref.read(agentApiProvider).conversation(_conversationId);
      if (!ref.mounted) return;
      final drafts = <String, DraftEntry>{};
      final messages = <AgentMsg>[];
      for (final m in stored.messages) {
        for (final d in m.drafts) {
          drafts[d.draft.id] = DraftEntry(d.draft, phase: switch (d.phase) {
            StoredDraftPhase.pending => DraftPhase.pending,
            StoredDraftPhase.accepted => DraftPhase.accepted,
            StoredDraftPhase.discarded => DraftPhase.discarded,
          });
        }
        messages.add(AgentMsg(
          id: _nextId++,
          role: m.role,
          text: m.text,
          tools: [for (final t in m.tools) ToolRow(id: t.id, label: t.label, status: t.status)],
          draftIds: [for (final d in m.drafts) d.draft.id],
          attachments: m.attachments,
          error: m.error.isEmpty ? null : m.error,
          note: m.note.isEmpty ? null : m.note,
        ));
      }
      state = state.copyWith(messages: messages, drafts: drafts, opening: false);
    } on AgentException catch (e) {
      if (ref.mounted) state = state.copyWith(opening: false, openError: e.message);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(opening: false, openError: '出错了：$e');
    }
  }

  // ---- files ----

  /// Why [f] cannot be taken, judged before uploading; the server checks again.
  String _refusal(PickedFile f, {required bool vision}) {
    if (f.size == 0) return '这个文件是空的';
    if (f.isImage) {
      if (!vision) return '当前助手模型不支持识别图片';
      if (f.size > agentImageMaxBytes) {
        return '图片太大了（超过 ${agentImageMaxBytes ~/ 1024 ~/ 1024} MB），请压缩或裁剪后再上传';
      }
      if (state.imageCount >= agentMaxImages) {
        return '一场对话最多 $agentMaxImages 张图片';
      }
    } else {
      final dot = f.name.lastIndexOf('.');
      final ext = dot < 0 ? '' : f.name.substring(dot).toLowerCase();
      if (!agentFileExtensions.contains(ext)) {
        return '不支持这种文件，可以上传 ${agentFileExtensions.join(' ')} 文本文件';
      }
      if (f.size > agentFileMaxBytes) {
        return '文件太大了（超过 ${agentFileMaxBytes ~/ 1024} KB），请截取需要的部分再上传';
      }
    }
    if (!state.canAttach) {
      return '一场对话最多 $agentMaxFiles 个文件，一条消息最多带 $agentMaxFilesPerMessage 个';
    }
    return '';
  }

  void _setFile(int key, PendingFile Function(PendingFile) change) =>
      state = state.copyWith(
        files: [for (final f in state.files) f.key == key ? change(f) : f],
      );

  /// Uploads [picked] for the next message. A file that is not taken stays in the list with the
  /// reason, until dismissed.
  ///
  /// Pictures are taken only when [vision] says the assistant's model can look at them.
  Future<void> addFiles(List<PickedFile> picked, {bool vision = false}) async {
    for (final f in picked) {
      if (!ref.mounted) return;
      final key = _nextFile++;
      final why = _refusal(f, vision: vision);
      state = state.copyWith(
        files: [
          ...state.files,
          PendingFile(
            key: key,
            name: f.name,
            size: f.size,
            status: why.isEmpty ? FileStatus.uploading : FileStatus.error,
            isImage: f.isImage,
            error: why.isEmpty ? null : why,
          ),
        ],
      );
      if (why.isNotEmpty) continue;
      try {
        final bytes = await f.read();
        // The thumbnail needs the bytes, which are in hand anyway.
        if (f.isImage) {
          _setFile(key, (p) => p.withPreview(bytes));
        }
        final a = await ref
            .read(agentApiProvider)
            .uploadAttachment(_conversationId, f.name, bytes);
        if (!ref.mounted) return;
        _setFile(
          key,
          (p) => p.copyWith(status: FileStatus.ready, attachment: a),
        );
      } on AgentException catch (e) {
        if (ref.mounted) {
          _setFile(key, (p) => p.copyWith(status: FileStatus.error, error: e.message));
        }
      } catch (e) {
        if (ref.mounted) {
          _setFile(key, (p) => p.copyWith(status: FileStatus.error, error: '出错了：$e'));
        }
      }
    }
  }

  /// Takes a file off the next message and, if it reached the server, removes it there.
  Future<void> removeFile(int key) async {
    final f = state.files.where((x) => x.key == key).firstOrNull;
    if (f == null) return;
    state = state.copyWith(
      files: [
        for (final x in state.files)
          if (x.key != key) x,
      ],
    );
    final a = f.attachment;
    if (a == null) return;
    try {
      await ref.read(agentApiProvider).deleteAttachment(a.id);
    } catch (_) {
      // The server drops unsent files after a day anyway.
    }
  }

  /// Sends [text] (with the chosen files) and streams the answer in.
  Future<void> send(String text) async {
    final sending = state.readyFiles;
    final t = text.trim().isEmpty && sending.isNotEmpty
        ? fileOnlyText
        : text.trim();
    // Not while a stored conversation is being read, or when it could not be: its history is unknown.
    if (t.isEmpty || state.busy || state.uploading || state.opening || state.openError != null) return;
    final attachments = [for (final f in sending) f.attachment!];
    final user = AgentMsg(
      id: _nextId++,
      role: 'user',
      text: t,
      attachments: attachments,
      localImages: {
        for (final f in sending)
          if (f.preview != null) f.attachment!.id: f.preview!,
      },
    );
    final bot = AgentMsg(id: _nextId++, role: 'assistant', streaming: true);
    state = state.copyWith(
      messages: [...state.messages, user, bot],
      busy: true,
      // Files that were not taken are not sent; they leave with the message that carried the good ones.
      files: const [],
    );

    final cancel = _cancel = CancelToken();
    try {
      final request = AgentChatRequest(
        conversationId: _conversationId,
        mode: args.mode,
        deviceId: ref.read(settingsProvider).deviceId,
        message: t,
        attachmentIds: [for (final a in attachments) a.id],
        context: AgentContext(
          bankId: args.bankId,
          lessonId: args.lessonId,
          questionId: args.questionId,
          selected: args.selected,
        ),
      );
      await for (final ev
          in ref.read(agentApiProvider).chat(request, cancel: cancel)) {
        if (!ref.mounted) return;
        _apply(bot.id, ev);
      }
    } on AgentException catch (e) {
      if (ref.mounted) {
        if (cancel.isCancelled) {
          _patch(bot.id, (m) => m.copyWith(note: '已停止'));
        } else {
          _patch(bot.id, (m) => m.copyWith(error: e.message));
        }
      }
    } catch (e) {
      if (ref.mounted) _patch(bot.id, (m) => m.copyWith(error: '出错了：$e'));
    } finally {
      if (ref.mounted) {
        _patch(
          bot.id,
          (m) => m.copyWith(
            streaming: false,
            // A tool that never reported back is not still running.
            tools: [
              for (final r in m.tools)
                r.status == 'running'
                    ? ToolRow(id: r.id, label: r.label, status: 'done')
                    : r,
            ],
          ),
        );
        state = state.copyWith(busy: false);
      }
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  /// Stops the answer being written; what has arrived stays.
  void stop() => _cancel?.cancel();

  void _patch(int id, AgentMsg Function(AgentMsg) change) {
    state = state.copyWith(
      messages: [for (final m in state.messages) m.id == id ? change(m) : m],
    );
  }

  void _apply(int id, AgentEvent ev) {
    switch (ev) {
      case AgentStarted():
        break;
      case AgentDelta(:final text):
        _patch(id, (m) => m.copyWith(text: m.text + text));
      case AgentToolEvent():
        _patch(id, (m) {
          final row = ToolRow(id: ev.id, label: ev.label, status: ev.status);
          final tools = [...m.tools];
          final at = tools.indexWhere((r) => r.id == ev.id);
          if (at < 0) {
            tools.add(row);
          } else {
            tools[at] = row;
          }
          return m.copyWith(tools: tools);
        });
      case AgentDraftsEvent(:final drafts):
        final entries = {...state.drafts};
        for (final d in drafts) {
          entries.putIfAbsent(d.id, () => DraftEntry(d));
        }
        state = state.copyWith(drafts: entries);
        _patch(
          id,
          (m) => m.copyWith(
            draftIds: [
              ...m.draftIds,
              for (final d in drafts)
                if (!m.draftIds.contains(d.id)) d.id,
            ],
          ),
        );
      case AgentDone(:final stop):
        if (stop == 'max_tokens') {
          _patch(id, (m) => m.copyWith(note: '回答太长，被截断了'));
        }
        if (stop == 'max_rounds') {
          _patch(id, (m) => m.copyWith(note: '查了很多资料，只能先答到这里'));
        }
      case AgentErrorEvent(:final message):
        _patch(id, (m) => m.copyWith(error: message));
    }
  }

  // ---- drafts ----

  /// Sends the draft to the review queue; a reviewer still has to approve it before anyone practises it.
  Future<void> accept(String draftId) => _decide(draftId, accept: true);

  Future<void> discard(String draftId) => _decide(draftId, accept: false);

  Future<void> _decide(String id, {required bool accept}) async {
    final entry = state.drafts[id];
    if (entry == null || entry.phase == DraftPhase.working) return;
    _setDraft(id, entry.copyWith(phase: DraftPhase.working, clearError: true));
    try {
      final api = ref.read(agentApiProvider);
      if (accept) {
        await api.acceptDraft(id);
      } else {
        await api.discardDraft(id);
      }
      if (ref.mounted) {
        _setDraft(
          id,
          entry.copyWith(
            phase: accept ? DraftPhase.accepted : DraftPhase.discarded,
            clearError: true,
          ),
        );
      }
    } on AgentException catch (e) {
      if (ref.mounted) {
        _setDraft(
          id,
          entry.copyWith(phase: DraftPhase.pending, error: e.message),
        );
      }
    } catch (e) {
      if (ref.mounted) {
        _setDraft(
          id,
          entry.copyWith(phase: DraftPhase.pending, error: '出错了：$e'),
        );
      }
    }
  }

  void _setDraft(String id, DraftEntry entry) =>
      state = state.copyWith(drafts: {...state.drafts, id: entry});

  /// The words that start a request to rewrite a draft; the learner finishes the sentence. The id lets
  /// the assistant replace exactly that draft.
  String revisionPrompt(String draftId) {
    final d = state.drafts[draftId]?.draft;
    final stem = d == null ? '' : d.stem.replaceAll(RegExp(r'\s+'), ' ');
    final shown = stem.length > 30 ? '${stem.substring(0, 30)}…' : stem;
    return '请修改这道草稿（draft_id：$draftId，题干：「$shown」）：';
  }
}
