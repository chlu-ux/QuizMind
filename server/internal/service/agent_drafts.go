package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/pipeline"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// agentDraftTTL is how long a draft may wait for the learner before it is retired.
const agentDraftTTL = 7 * 24 * time.Hour

// agentDrafter checks and stores the questions the assistant proposes. A question must pass the
// same rules as one the pipeline wrote, must not duplicate any live question or draft of the bank,
// and, when a validator model is bound, must be answered the same way by that model without seeing
// the answer key. Only then is it stored, as a draft.
type agentDrafter struct {
	s     *Service
	model string
}

func (d agentDrafter) Propose(ctx context.Context, scope agent.DraftScope, lessonID string, qs []agent.ProposedQuestion) ([]agent.ProposeResult, error) {
	results := make([]agent.ProposeResult, len(qs))
	failAll := func(msg string) ([]agent.ProposeResult, error) {
		for i := range results {
			results[i] = agent.ProposeResult{Error: msg}
		}
		return results, nil
	}

	q := d.s.reader()
	chunk, err := q.GetChunk(ctx, lessonID)
	if errors.Is(err, sql.ErrNoRows) {
		return failAll(fmt.Sprintf("没有 id 为 %q 的小节，请先用 search_lessons 取得 lesson_id", lessonID))
	}
	if err != nil {
		return nil, err
	}
	if chunk.Status != "active" {
		return failAll("这一节的讲义已经更新或删除，请重新查找")
	}
	doc, err := q.GetDocument(ctx, chunk.DocumentID)
	if err != nil {
		return nil, err
	}
	alive, err := q.CountAgentDrafts(ctx, scope.ConversationID)
	if err != nil {
		return nil, err
	}

	// A draft that is being replaced does not count as a duplicate of its replacement.
	replaced := map[string]bool{}
	for _, pq := range qs {
		if pq.Replaces == "" {
			continue
		}
		row, err := q.GetAgentDraft(ctx, pq.Replaces)
		if err == nil && row.ConversationID == scope.ConversationID && row.Status == "draft" {
			replaced[pq.Replaces] = true
		}
	}
	live, err := q.ListLiveQuestionsByBank(ctx, doc.BankID)
	if err != nil {
		return nil, err
	}
	existing := make([]pipeline.Existing, 0, len(live))
	for _, l := range live {
		if replaced[l.ID] {
			continue
		}
		var opts []string
		_ = json.Unmarshal([]byte(l.Options), &opts)
		existing = append(existing, pipeline.Existing{ID: l.ID, Hash: l.ContentHash, Stem: l.Stem, Options: opts})
	}
	dedupe := pipeline.NewDeduper(existing, d.s.Cfg.Pipeline.DedupeThreshold)
	validator, _ := d.s.LLM.For(llm.RoleValidator) // none bound: questions are stored unverified

	for i, pq := range qs {
		fail := func(format string, a ...any) { results[i] = agent.ProposeResult{Error: fmt.Sprintf(format, a...)} }
		if pq.Replaces != "" && !replaced[pq.Replaces] {
			fail("replaces 指向的草稿 %q 不存在、不属于本对话或已处理", pq.Replaces)
			continue
		}
		if pq.Replaces == "" && alive >= agent.MaxDraftsPerChat {
			fail("本对话的草稿已有 %d 道，达到上限；请先让用户采纳或丢弃一些", alive)
			continue
		}
		v, err := pipeline.ValidateQuestion(pipeline.GeneratedQuestion{
			Type: pq.Type, Stem: pq.Stem, Options: pq.Options, AnswerIndex: pq.AnswerIndex, Explanation: pq.Explanation,
			Difficulty: pq.Difficulty, Tags: pq.Tags, SourceQuote: pq.SourceQuote,
		}, chunk.Text)
		if err != nil {
			if strings.Contains(err.Error(), "source_quote") {
				fail("source_quote 在这一节原文里找不到（%s），请逐字摘抄原文中的一句话，不要改写或拼接", err.Error())
			} else {
				fail("未通过规则校验：%s", err.Error())
			}
			continue
		}
		id := newID()
		if other, dup := dedupe.Check(id, v); dup {
			fail("与已有题目重复（%s），请换一个考点或角度", other)
			continue
		}

		verified := false
		if validator != nil {
			got, err := pipeline.VerifyAnswer(ctx, validator, v, chunk.HeadingPath, chunk.Text)
			switch {
			case errors.Is(err, llm.ErrBudgetExceeded):
				return nil, err
			case err != nil:
				d.s.Log.Warn("agent draft verification failed", "err", err)
				fail("独立复核暂时不可用，请稍后再试")
				continue
			case got != v.AnswerIndex:
				fail("独立复核认为正确答案是「%s」，与你给的「%s」不一致，请检查答案是否正确、题目是否有歧义",
					v.Options[got], v.Options[v.AnswerIndex])
				continue
			}
			verified = true
		}

		now := nowMs()
		row := store.InsertQuestionParams{
			ID: id, BankID: doc.BankID, ChunkID: sql.NullString{String: chunk.ID, Valid: true},
			Type: v.Type, Stem: v.Stem, Options: jsonArray(v.Options), Answer: jsonArray([]int{v.AnswerIndex}),
			Explanation: v.Explanation, Difficulty: int64(v.Difficulty), Tags: jsonArray(v.Tags),
			SourceQuote: v.SourceQuote, Status: "draft", ContentHash: v.Hash,
			GenModel: d.model, GenPromptVersion: agent.PromptVersion, CreatedAt: now, UpdatedAt: now,
		}
		isVerified := int64(0)
		if verified {
			isVerified = 1
		}
		err = d.s.DB.WithTx(ctx, func(tx *sql.Tx) error {
			qs := store.New(tx)
			if err := qs.InsertQuestion(ctx, row); err != nil {
				return err
			}
			if err := qs.InsertAgentDraft(ctx, store.InsertAgentDraftParams{
				QuestionID: id, ConversationID: scope.ConversationID, LessonID: chunk.ID, DeviceID: scope.DeviceID,
				Verified: isVerified, CreatedAt: now,
			}); err != nil {
				return err
			}
			if pq.Replaces != "" {
				return qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
					Status: "rejected", ReviewNote: "replaced by a newer draft", UpdatedAt: now, ID: pq.Replaces,
				})
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
		if pq.Replaces == "" {
			alive++
		}
		results[i] = agent.ProposeResult{OK: true, DraftID: id, Draft: &agent.Draft{
			DraftID: id, LessonID: chunk.ID, Type: v.Type, Stem: v.Stem, Options: v.Options, AnswerIndex: v.AnswerIndex,
			Explanation: v.Explanation, Difficulty: v.Difficulty, Tags: v.Tags, SourceQuote: v.SourceQuote, Verified: verified,
		}}
	}
	return results, nil
}

func (d agentDrafter) Drafts(ctx context.Context, conversationID string) ([]agent.Draft, error) {
	return d.s.listAgentDrafts(ctx, conversationID)
}

func (s *Service) listAgentDrafts(ctx context.Context, conversationID string) ([]agent.Draft, error) {
	rows, err := s.reader().ListAgentDrafts(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	out := make([]agent.Draft, 0, len(rows))
	for _, r := range rows {
		out = append(out, buildAgentDraft(r.ID, r.ChunkID.String, r.Type, r.Stem, r.Options, r.Answer, r.Tags, r.Explanation,
			r.SourceQuote, r.Difficulty, r.Verified != 0))
	}
	return out, nil
}

// buildAgentDraft makes the draft the apps show from the columns of a stored question.
func buildAgentDraft(id, lessonID, typ, stem, options, answer, tags, explanation, quote string, difficulty int64, verified bool) agent.Draft {
	d := agent.Draft{DraftID: id, LessonID: lessonID, Type: typ, Stem: stem, Explanation: explanation, Difficulty: int(difficulty),
		SourceQuote: quote, Verified: verified, Options: []string{}, Tags: []string{}}
	var ans []int
	_ = json.Unmarshal([]byte(options), &d.Options)
	_ = json.Unmarshal([]byte(tags), &d.Tags)
	_ = json.Unmarshal([]byte(answer), &ans)
	if len(ans) > 0 {
		d.AnswerIndex = ans[0]
	}
	return d
}

// AgentDrafts lists the drafts of a conversation that still wait for a decision, so an app that
// reopens the chat can show their cards again.
func (s *Service) AgentDrafts(ctx context.Context, token, conversationID string) ([]agent.Draft, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return nil, err
	}
	if conversationID == "" || len(conversationID) > agentIDMax {
		return nil, invalid("conversation_id is required")
	}
	return s.listAgentDrafts(ctx, conversationID)
}

// AgentDraftResult is the state of a draft after the learner decided on it.
type AgentDraftResult struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

// AcceptAgentDraft sends a draft to the review queue (status needs_review). Accepting does not
// publish: a reviewer still approves it in the admin UI like any other question.
func (s *Service) AcceptAgentDraft(ctx context.Context, token, id string) (AgentDraftResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentDraftResult{}, err
	}
	row, err := s.reader().GetAgentDraft(ctx, id)
	if err != nil {
		return AgentDraftResult{}, notFound(err, "draft")
	}
	if row.Status != "draft" {
		return AgentDraftResult{}, invalid("这道草稿已经处理过了")
	}
	// The question was written from the section's text as it was; if that changed, the quote may be gone.
	chunk, err := s.reader().GetChunk(ctx, row.LessonID)
	if err != nil || chunk.Status != "active" {
		return AgentDraftResult{}, invalid("这一节讲义已经更新，这道草稿已过期，请让助手重新出题")
	}
	return s.decideAgentDraft(ctx, id, "needs_review", "")
}

// DiscardAgentDraft throws a draft away.
func (s *Service) DiscardAgentDraft(ctx context.Context, token, id string) (AgentDraftResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentDraftResult{}, err
	}
	if _, err := s.reader().GetAgentDraft(ctx, id); err != nil {
		return AgentDraftResult{}, notFound(err, "draft")
	}
	return s.decideAgentDraft(ctx, id, "rejected", "discarded by user")
}

func (s *Service) decideAgentDraft(ctx context.Context, id, status, note string) (AgentDraftResult, error) {
	v, err := s.transition(ctx, id, func(q store.Question) (string, string, bool, error) {
		if q.Status != "draft" {
			return "", "", false, invalid("这道草稿已经处理过了")
		}
		return status, note, false, nil
	})
	if err != nil {
		return AgentDraftResult{}, err
	}
	return AgentDraftResult{ID: v.ID, Status: v.Status}, nil
}

// RetireStaleAgentDrafts takes drafts that nobody decided on for a week out of the way.
func (s *Service) RetireStaleAgentDrafts(ctx context.Context) (int64, error) {
	now := time.Now()
	return store.New(s.DB.Write).RetireStaleDrafts(ctx, store.RetireStaleDraftsParams{
		UpdatedAt: now.UnixMilli(), CreatedAt: now.Add(-agentDraftTTL).UnixMilli(),
	})
}
