/// Checks and stores the questions the model proposes while the server is out of reach. A question must
/// pass the same rules the server applies, must not duplicate any question of the bank, and is then added
/// to the bank here at once (the learner can take it back); the next sync sends it to the server, which
/// checks it again (server/internal/service/agent_drafts.go).
library;

import '../../core/ulid.dart';
import '../agent_models.dart';
import 'agent_spec.dart';
import 'agent_tools.dart';
import 'local_agent_store.dart';
import 'question_rules.dart';

class LocalDrafter implements Drafter {
  LocalDrafter({
    required this.store,
    required this.env,
    required this.conversationId,
    required this.spec,
    String Function()? newId,
  }) : _newId = newId ?? newUlid;

  final LocalAgentStore store;
  final ToolEnv env;
  final String conversationId;
  final LocalAgentSpec spec;
  final String Function() _newId;

  @override
  Future<List<ProposeResult>> propose(String lessonId, List<ProposedQuestion> qs) async {
    List<ProposeResult> failAll(String msg) => [for (final _ in qs) ProposeResult.fail(msg)];

    final lesson = await env.lib.lesson(lessonId);
    if (lesson == null) return failAll('没有 id 为 "$lessonId" 的小节，请先用 search_lessons 取得 lesson_id');
    var alive = await store.liveQuestionCount(conversationId);

    // A question that is being replaced does not count as a duplicate of its replacement.
    final replaced = <String>{};
    for (final pq in qs) {
      if (pq.replaces.isEmpty) continue;
      final row = await store.question(pq.replaces);
      if (row != null && row.agentConv == conversationId && !row.hidden) replaced.add(pq.replaces);
    }
    final live = <String, ExistingQuestion>{
      for (final q in await env.lib.questions())
        if (q.bankId == lesson.bankId) q.id: ExistingQuestion(q.id, q.stem, q.options),
    };
    // The library was read when the conversation began; what this conversation wrote since is in the store.
    for (final d in await drafts()) {
      if (d.adopted) live.putIfAbsent(d.id, () => ExistingQuestion(d.id, d.stem, d.options));
    }
    replaced.forEach(live.remove);
    final dedupe = Deduper(live.values, spec.dedupeThreshold);

    final results = <ProposeResult>[];
    for (final pq in qs) {
      if (pq.replaces.isNotEmpty && !replaced.contains(pq.replaces)) {
        results.add(ProposeResult.fail('replaces 指向的题 "${pq.replaces}" 不存在、不属于本对话或已被用户取消采纳'));
        continue;
      }
      if (pq.replaces.isEmpty && alive >= spec.maxDraftsPerChat) {
        results.add(ProposeResult.fail('本对话已经出了 $alive 道题，达到上限；请告诉用户新开一个对话再继续出题'));
        continue;
      }
      final ValidQuestion v;
      try {
        v = validateQuestion(pq, lesson.text);
      } on RuleError catch (e) {
        results.add(ProposeResult.fail(e.message.contains('source_quote')
            ? 'source_quote 在这一节原文里找不到（${e.message}），请逐字摘抄原文中的一句话，不要改写或拼接'
            : '未通过规则校验：${e.message}'));
        continue;
      }
      final id = _newId();
      final other = dedupe.check(id, v);
      if (other != null) {
        results.add(ProposeResult.fail('与已有题目重复（$other），请换一个考点或角度'));
        continue;
      }
      await store.insertQuestion(
        id: id,
        bankId: lesson.bankId,
        lessonId: lesson.id,
        documentId: lesson.documentId,
        documentTitle: lesson.documentTitle,
        documentOrder: lesson.documentOrder,
        type: v.type,
        stem: v.stem,
        options: v.options,
        answerIndex: v.answerIndex,
        explanation: v.explanation,
        difficulty: v.difficulty,
        tags: v.tags,
        sourceQuote: v.sourceQuote,
        conversationId: conversationId,
      );
      if (pq.replaces.isNotEmpty) {
        await store.decide(pq.replaces, adopt: false);
        replaced.remove(pq.replaces);
      } else {
        alive++;
      }
      results.add(ProposeResult.ok(AgentDraft(
        id: id,
        lessonId: lesson.id,
        type: v.type,
        stem: v.stem,
        options: v.options,
        answerIndex: v.answerIndex,
        explanation: v.explanation,
        difficulty: v.difficulty,
        tags: v.tags,
        sourceQuote: v.sourceQuote,
        verified: false,
        adopted: true,
      )));
    }
    return results;
  }

  @override
  Future<List<AgentDraft>> drafts() async =>
      [for (final q in await store.conversationQuestions(conversationId)) store.draftOf(q)];
}
