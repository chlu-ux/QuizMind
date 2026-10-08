import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/ulid.dart';
import '../../data/agent_models.dart';

/// Where a conversation starts: which assistant mode and what the learner is looking at. Two
/// pages with equal args share one conversation while either is open.
class AgentArgs {
  const AgentArgs({
    required this.mode,
    this.bankId = '',
    this.lessonId = '',
    this.questionId = '',
    this.selected = const [],
  });

  /// learn | create
  final String mode;
  final String bankId;
  final String lessonId;
  final String questionId;
  final List<int> selected;

  bool get isCreate => mode == 'create';

  @override
  bool operator ==(Object other) =>
      other is AgentArgs &&
      other.mode == mode &&
      other.bankId == bankId &&
      other.lessonId == lessonId &&
      other.questionId == questionId &&
      other.selected.length == selected.length &&
      [
        for (var i = 0; i < selected.length; i++)
          other.selected[i] == selected[i],
      ].every((e) => e);

  @override
  int get hashCode =>
      Object.hash(mode, bankId, lessonId, questionId, Object.hashAll(selected));
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
  });

  final List<AgentMsg> messages;
  final Map<String, DraftEntry> drafts;

  /// An answer is being written.
  final bool busy;

  AgentState copyWith({
    List<AgentMsg>? messages,
    Map<String, DraftEntry>? drafts,
    bool? busy,
  }) => AgentState(
    messages: messages ?? this.messages,
    drafts: drafts ?? this.drafts,
    busy: busy ?? this.busy,
  );
}

/// The most the server takes in one request; older messages are dropped by the client.
const agentMaxMessages = 30;
const agentMaxChars = 24000;

/// The text history to send. The server keeps nothing: the assistant looks things up again with its
/// tools when it needs them, so only the words of the conversation are sent. Empty answers (a failed
/// or stopped one) are left out, neighbours with the same role are joined so roles alternate, and the
/// oldest messages are dropped until the request fits what the server accepts.
List<AgentTurn> buildAgentHistory(Iterable<AgentMsg> messages) {
  final turns = <AgentTurn>[];
  for (final m in messages) {
    final text = m.text.trim();
    if (text.isEmpty) continue;
    if (turns.isNotEmpty && turns.last.role == m.role) {
      turns[turns.length - 1] = AgentTurn(
        m.role,
        '${turns.last.content}\n\n$text',
      );
    } else {
      turns.add(AgentTurn(m.role, text));
    }
  }
  int chars() => turns.fold(0, (n, t) => n + t.content.runes.length);
  while (turns.length > agentMaxMessages ||
      (turns.length > 1 && chars() > agentMaxChars)) {
    turns.removeAt(0);
  }
  while (turns.isNotEmpty && turns.first.role != 'user') {
    turns.removeAt(0);
  }
  return turns;
}

const _createConvKey = 'agent_create_conversation';

final agentControllerProvider = NotifierProvider.autoDispose
    .family<AgentController, AgentState, AgentArgs>(AgentController.new);

class AgentController extends Notifier<AgentState> {
  AgentController(this.args);

  final AgentArgs args;

  late final String _conversationId;
  int _nextId = 1;
  CancelToken? _cancel;

  @override
  AgentState build() {
    // A question-writing conversation is remembered, so the drafts it made can be shown again when
    // the page is reopened; a learning conversation starts fresh.
    final prefs = ref.read(sharedPrefsProvider);
    if (args.isCreate) {
      var id = prefs.getString(_createConvKey);
      if (id == null || id.isEmpty) {
        id = newUlid();
        unawaited(prefs.setString(_createConvKey, id));
      }
      _conversationId = id;
      Future.microtask(_restoreDrafts);
    } else {
      _conversationId = newUlid();
    }
    ref.onDispose(() => _cancel?.cancel());
    return const AgentState();
  }

  String get conversationId => _conversationId;

  Future<void> _restoreDrafts() async {
    try {
      final drafts = await ref.read(agentApiProvider).drafts(_conversationId);
      if (!ref.mounted || drafts.isEmpty) return;
      final entries = {
        ...state.drafts,
        for (final d in drafts) d.id: state.drafts[d.id] ?? DraftEntry(d),
      };
      final note = AgentMsg(
        id: _nextId++,
        role: 'assistant',
        text: '上次还有 ${drafts.length} 道草稿没有处理：',
        draftIds: [for (final d in drafts) d.id],
      );
      state = state.copyWith(
        messages: [...state.messages, note],
        drafts: entries,
      );
    } catch (_) {
      // Not being able to restore is not worth a message; the learner can simply ask again.
    }
  }

  /// Sends [text] and streams the answer in.
  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty || state.busy) return;
    final user = AgentMsg(id: _nextId++, role: 'user', text: t);
    final bot = AgentMsg(id: _nextId++, role: 'assistant', streaming: true);
    final history = buildAgentHistory([...state.messages, user]);
    state = state.copyWith(
      messages: [...state.messages, user, bot],
      busy: true,
    );

    final cancel = _cancel = CancelToken();
    try {
      final request = AgentChatRequest(
        conversationId: _conversationId,
        mode: args.mode,
        deviceId: ref.read(settingsProvider).deviceId,
        messages: history,
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
