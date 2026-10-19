/// The assistant, running on this device: the conversation loop of server/internal/agent/agent.go. The
/// model is called directly, the tools run on the library the device keeps, and the questions the model
/// writes go into the question bank here and reach the server at the next sync.
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/ulid.dart';
import '../agent_models.dart';
import '../models.dart';
import 'agent_spec.dart';
import 'agent_tools.dart';
import 'anthropic_chat.dart';
import 'library.dart';
import 'local_agent_store.dart';
import 'local_drafter.dart';
import 'text_filters.dart';

class LocalAgent {
  LocalAgent({
    required this.spec,
    required this.chat,
    required this.library,
    required this.store,
    this.reportUsage,
    this.toolTimeout = const Duration(seconds: 15),
    DateTime Function()? clock,
    String Function()? newId,
  })  : _clock = clock ?? DateTime.now,
        _newId = newId ?? newUlid;

  final LocalAgentSpec spec;
  final AnthropicChat chat;
  final AgentLibrary library;
  final LocalAgentStore store;

  /// Told what each model call cost.
  final void Function(AiUsage usage)? reportUsage;
  final Duration toolTimeout;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// Answers [req]. Cancelling [cancel] stops the model; the stream then ends with an [AgentException].
  Stream<AgentEvent> run(AgentChatRequest req, {CancelToken? cancel}) {
    final out = StreamController<AgentEvent>();
    () async {
      try {
        await _run(req, cancel, out.add);
      } on AgentException catch (e) {
        if (cancel?.isCancelled ?? false) {
          out.addError(AgentException('已停止'));
        } else {
          out.add(AgentErrorEvent(code: e.code ?? 'internal', message: e.message));
        }
      } catch (_) {
        out.add(const AgentErrorEvent(code: 'internal', message: '助手出错了，请稍后再试。'));
      } finally {
        await out.close();
      }
    }();
    return out.stream;
  }

  Future<void> _run(AgentChatRequest req, CancelToken? cancel, void Function(AgentEvent) emit) async {
    emit(const AgentLocalEvent());
    emit(AgentStarted(req.conversationId));

    final first = req.began ?? req.context;
    // What the learner was looking at is fixed when the conversation begins: it is written once, as the
    // start of what the learner said, and the instructions stay one fixed text.
    final fresh = await _brief(ToolEnv(library, first.bankId, clock: _clock), first, _clock());
    await store.ensureConversation(
      id: req.conversationId,
      mode: req.mode,
      bankId: first.bankId,
      lessonId: first.lessonId,
      questionId: first.questionId,
      briefing: fresh,
      firstText: req.message,
      seed: req.history,
    );
    final c = await store.contextOf(req.conversationId) ?? first;
    final brief = await store.briefingOf(req.conversationId);
    await store.appendMessage(req.conversationId, 'user', text: req.message);
    final stored = await store.history(req.conversationId);
    final history = [for (final m in stored) LlmMessage.text(m.role, m.text)];
    final head = history.indexWhere((m) => m.role == 'user');
    final opening = brief.isEmpty ? fresh : brief;
    if (head >= 0) history[head] = LlmMessage.text('user', '$opening\n\n${stored[head].text}');
    // A conversation taken up on a later day: the newest message says what day it is, so the model does not
    // take the day the brief gives for today. It goes last, where it costs no cache.
    final now = _clock();
    final today = '${now.year}年${now.month}月${now.day}日';
    if (history.isNotEmpty && !opening.contains('对话开始于 $today')) {
      final last = history.last;
      history[history.length - 1] = LlmMessage(last.role, [...last.blocks, LlmBlock.text('（今天是 $today。）')]);
    }

    final env = ToolEnv(library, c.bankId, clock: _clock);
    await _brief(env, c, _clock()); // marks the lesson and question in it as ones the model may link to
    for (final m in stored) {
      if (m.role == 'assistant') env.see(LinkFilter.idsIn(m.text));
    }
    final drafter = LocalDrafter(store: store, env: env, conversationId: req.conversationId, spec: spec);
    final tools = ToolSet(env, drafter: drafter, maxResult: spec.maxToolResult);
    final specs = [for (final t in spec.tools) if (tools.has(t.name)) t];
    final system = [spec.prompt];

    // What the learner will see of the answer, kept so it is stored however the answer ends.
    final text = StringBuffer();
    final rows = <StoredTool>[];
    final draftIds = <String>[];
    var note = '', error = '';
    var finished = false;
    void say(String s) {
      if (s.isEmpty) return;
      text.write(s);
      emit(AgentDelta(s));
    }

    Future<void> save() => store.appendMessage(req.conversationId, 'assistant',
        text: text.toString(), tools: rows, draftIds: draftIds, note: note, error: error);

    try {
      var inputTokens = 0, outputTokens = 0;
      Future<LlmTurn> turn(List<AgentToolSpec> toolSpecs) async {
        final filter = LinkFilter(env.known);
        final started = _clock();
        try {
          final t = await chat.converse(
            config: spec.model,
            system: system,
            messages: history,
            tools: toolSpecs,
            onText: (s) => say(filter.write(s)),
            cancel: cancel,
          );
          say(filter.flush());
          inputTokens += t.usage.input;
          outputTokens += t.usage.output;
          _report(req, t.usage, started, ok: true);
          return t;
        } on AgentException catch (e) {
          say(filter.flush());
          _report(req, const LlmUsage(), started, ok: false, error: e.message);
          rethrow;
        }
      }

      AgentDone done(String stop) => AgentDone(stop: stop, inputTokens: inputTokens, outputTokens: outputTokens);

      for (var round = 1; round <= spec.maxRounds; round++) {
        final t = await turn(specs);
        if (t.stopReason == 'refusal') {
          error = '模型拒绝回答这个问题，换个问法试试。';
          emit(AgentErrorEvent(code: 'refused', message: error));
          finished = true;
          return;
        }
        if (t.stopReason == 'max_tokens') {
          note = '回答太长，被截断了';
          emit(done('max_tokens'));
          finished = true;
          return;
        }
        final calls = t.toolCalls;
        if (t.stopReason != 'tool_use' || calls.isEmpty) {
          emit(done('end_turn'));
          finished = true;
          return;
        }
        history.add(LlmMessage('assistant', t.blocks));
        history.add(LlmMessage('user', await _runTools(tools, calls, rows, emit)));
        final drafts = env.takeDrafts();
        if (drafts.isNotEmpty) {
          for (final d in drafts) {
            if (!draftIds.contains(d.id)) draftIds.add(d.id);
          }
          emit(AgentDraftsEvent(drafts));
        }
        if (cancel?.isCancelled ?? false) throw AgentException('已停止');
      }

      // Out of rounds: one last turn, so the learner still gets an answer. The tools stay declared, since
      // leaving them out would change the start of the request and lose the cache; the nudge asks for none.
      // A model that calls one anyway without saying anything gets a turn without tools.
      final last = history.last;
      history[history.length - 1] = LlmMessage(last.role, [...last.blocks, LlmBlock.text(spec.wrapUpNudge)]);
      final t = await turn(specs);
      final said = t.blocks.any((b) => b.kind == BlockKind.text && b.text.trim().isNotEmpty);
      if (t.toolCalls.isNotEmpty && !said) await turn(const []);
      note = '查了很多资料，只能先答到这里';
      emit(done('max_rounds'));
      finished = true;
    } on AgentException catch (e) {
      if (cancel?.isCancelled ?? false) {
        note = '已停止';
      } else {
        error = e.message;
      }
      rethrow;
    } finally {
      if (!finished && error.isEmpty && note.isEmpty) error = '助手出错了，请稍后再试。';
      await save();
    }
  }

  Future<List<LlmBlock>> _runTools(
    ToolSet tools,
    List<LlmBlock> calls,
    List<StoredTool> rows,
    void Function(AgentEvent) emit,
  ) async {
    final labels = <String>[];
    for (final c in calls) {
      final label = await tools.label(c.toolName, c.toolInput);
      labels.add(label);
      emit(AgentToolEvent(id: c.toolUseId, name: c.toolName, label: label, status: 'running'));
    }
    final results = await Future.wait([
      for (final c in calls)
        tools.execute(c.toolName, c.toolInput).timeout(
              toolTimeout,
              onTimeout: () => ('工具执行超时，请缩小范围或换个办法。', true),
            ),
    ]);
    final blocks = <LlmBlock>[];
    for (var i = 0; i < calls.length; i++) {
      final (out, isErr) = results[i];
      blocks.add(LlmBlock.toolResult(toolUseId: calls[i].toolUseId, text: out, isError: isErr));
      final status = isErr ? 'error' : 'done';
      rows.add(StoredTool(id: calls[i].toolUseId, label: labels[i], status: status));
      emit(AgentToolEvent(id: calls[i].toolUseId, name: calls[i].toolName, label: labels[i], status: status));
    }
    return blocks;
  }

  void _report(AgentChatRequest req, LlmUsage u, DateTime started, {required bool ok, String error = ''}) {
    final sink = reportUsage;
    if (sink == null) return;
    sink(AiUsage(
      id: _newId(),
      role: 'agent',
      questionId: req.conversationId,
      deviceId: req.deviceId,
      model: spec.model.model,
      inputTokens: u.input,
      outputTokens: u.output,
      cachedTokens: u.cached,
      latencyMs: _clock().difference(started).inMilliseconds,
      ok: ok,
      error: error,
      createdAt: started.millisecondsSinceEpoch,
    ));
  }

  /// What the learner was looking at when a conversation began, as the start of what they said, and marks
  /// its ids as known. A lesson or question that is not in the library is left out.
  Future<String> _brief(ToolEnv env, AgentContext c, DateTime at) async {
    final sb = StringBuffer('<context>\n对话开始于 ${at.year}年${at.month}月${at.day}日。\n');
    if (c.lessonId.isNotEmpty) {
      final l = await env.lib.lesson(c.lessonId);
      if (l != null) {
        env.see([l.id]);
        // No more of it than get_lesson would give: the brief is not counted in the history's budget.
        final runes = l.text.runes;
        final text = runes.length <= spec.maxToolResult ? l.text : '${String.fromCharCodes(runes.take(spec.maxToolResult))}…';
        sb.write('用户正在阅读这一节讲义：\n<lesson id="${l.id}" path="${l.headingPath}">\n$text\n</lesson>\n');
      }
    }
    if (c.questionId.isNotEmpty) {
      for (final q in await env.lib.questions()) {
        if (q.id != c.questionId) continue;
        env.see([q.id, q.lessonId]);
        sb.write('用户正在看这道题：\n<question id="${q.id}">\n题干：${q.stem}\n');
        for (var i = 0; i < q.options.length; i++) {
          sb.write('${String.fromCharCode(65 + i)}. ${q.options[i]}\n');
        }
        sb.write('标准答案：${_letters(q.answer)}\n解析：${q.explanation}\n');
        if (c.selected.isNotEmpty) sb.write('用户选了：${_letters(c.selected)}\n');
        if (q.lessonId.isNotEmpty) sb.write('出自小节 lesson_id=${q.lessonId}\n');
        sb.write('</question>\n');
        break;
      }
    }
    if (c.bankId.isNotEmpty) sb.write('用户当前所在的题库 bank_id=${c.bankId}；工具默认只在这个题库里查。\n');
    sb.write('</context>');
    return sb.toString();
  }

  String _letters(List<int> idx) => [for (final i in idx) if (i >= 0 && i < 26) String.fromCharCode(65 + i)].join();
}
