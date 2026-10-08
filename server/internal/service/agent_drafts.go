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

// draftNote is the review note of a question the learner took back; only such a question can be
// adopted again.
const draftNote = "discarded by user"

// adoptedStatus is what a question becomes when the learner adopts it: published at once, or waiting
// in the review queue when the admin asked for every assistant question to be reviewed.
func (s *Service) adoptedStatus(ctx context.Context) (string, error) {
	c, err := s.loadAIConfig(ctx)
	if err != nil {
		return "", err
	}
	if c.ReviewAgentQuestions {
		return "needs_review", nil
	}
	return "published", nil
}

// liveDraftStatus says whether a question of a conversation is in play (not thrown away).
func liveDraftStatus(status string) bool {
	return status == "draft" || status == "needs_review" || status == "published"
}

// agentDrafter checks and stores the questions the assistant proposes. A question must pass the
// same rules as one the pipeline wrote, must not duplicate any live question or draft of the bank,
// and, when a validator model is bound, must be answered the same way by that model without seeing
// the answer key. Only then is it stored, already adopted: the learner can take it back.
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
	adopted, err := d.s.adoptedStatus(ctx)
	if err != nil {
		return nil, err
	}

	// A question that is being replaced does not count as a duplicate of its replacement. The map
	// holds its status, which says whether taking it back must be announced to the apps.
	replaced := map[string]string{}
	for _, pq := range qs {
		if pq.Replaces == "" {
			continue
		}
		row, err := q.GetAgentDraft(ctx, pq.Replaces)
		if err == nil && row.ConversationID == scope.ConversationID && liveDraftStatus(row.Status) {
			replaced[pq.Replaces] = row.Status
		}
	}
	live, err := q.ListLiveQuestionsByBank(ctx, doc.BankID)
	if err != nil {
		return nil, err
	}
	existing := make([]pipeline.Existing, 0, len(live))
	for _, l := range live {
		if _, gone := replaced[l.ID]; gone {
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
		if _, ok := replaced[pq.Replaces]; pq.Replaces != "" && !ok {
			fail("replaces 指向的题 %q 不存在、不属于本对话或已被用户取消采纳", pq.Replaces)
			continue
		}
		if pq.Replaces == "" && alive >= agent.MaxDraftsPerChat {
			fail("本对话已经出了 %d 道题，达到上限；请告诉用户新开一个对话再继续出题", alive)
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
			SourceQuote: v.SourceQuote, Status: adopted, ContentHash: v.Hash,
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
			if adopted == "published" {
				if err := publishNow(ctx, qs, id, "", now); err != nil {
					return err
				}
			}
			if pq.Replaces != "" {
				return withdraw(ctx, qs, pq.Replaces, replaced[pq.Replaces], "replaced by a newer draft", now)
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
			Adopted: true,
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
		d := buildAgentDraft(r.ID, r.ChunkID.String, r.Type, r.Stem, r.Options, r.Answer, r.Tags, r.Explanation,
			r.SourceQuote, r.Difficulty, r.Verified != 0)
		d.Adopted = r.Status != "draft"
		out = append(out, d)
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

// publishNow makes a question published with a fresh sync_seq, so the apps pick it up.
func publishNow(ctx context.Context, qs *store.Queries, id, note string, now int64) error {
	seq, err := qs.NextSyncSeq(ctx)
	if err != nil {
		return err
	}
	return qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
		Status: "published", ReviewNote: note, SyncSeq: sql.NullInt64{Int64: seq, Valid: true}, UpdatedAt: now, ID: id,
	})
}

// withdraw rejects a question that was in play. One that was published gets a fresh sync_seq, which
// is how the apps learn it is gone.
func withdraw(ctx context.Context, qs *store.Queries, id, was, note string, now int64) error {
	seq := sql.NullInt64{}
	if was == "published" {
		n, err := qs.NextSyncSeq(ctx)
		if err != nil {
			return err
		}
		seq = sql.NullInt64{Int64: n, Valid: true}
	}
	return qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
		Status: "rejected", ReviewNote: note, SyncSeq: seq, UpdatedAt: now, ID: id,
	})
}

// AcceptAgentDraft adopts a question of the assistant: it is published, or sent to the review queue
// when the admin wants every assistant question reviewed. New questions are adopted already, so this
// is mostly "adopt again" after the learner took one back. Adopting a question that is adopted
// already changes nothing.
func (s *Service) AcceptAgentDraft(ctx context.Context, token, id string) (AgentDraftResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentDraftResult{}, err
	}
	row, err := s.reader().GetAgentDraft(ctx, id)
	if err != nil {
		return AgentDraftResult{}, notFound(err, "draft")
	}
	if row.Status == "needs_review" || row.Status == "published" {
		return AgentDraftResult{ID: id, Status: row.Status}, nil
	}
	// The question was written from the section's text as it was; if that changed, the quote may be gone.
	chunk, err := s.reader().GetChunk(ctx, row.LessonID)
	if err != nil || chunk.Status != "active" {
		return AgentDraftResult{}, invalid("这一节讲义已经更新，这道题已过期，请让助手重新出题")
	}
	status, err := s.adoptedStatus(ctx)
	if err != nil {
		return AgentDraftResult{}, err
	}
	v, err := s.transition(ctx, id, func(q store.Question) (string, string, bool, error) {
		switch {
		case q.Status == "draft", q.Status == "rejected" && q.ReviewNote == draftNote:
			return status, "", false, nil
		case q.Status == "needs_review", q.Status == "published":
			return "", "", false, nil
		}
		return "", "", false, invalid("这道题已被后台驳回或下线，不能再采纳")
	})
	if err != nil {
		return AgentDraftResult{}, err
	}
	return AgentDraftResult{ID: v.ID, Status: v.Status}, nil
}

// DiscardAgentDraft takes an adopted question back (or throws a draft away). A published one
// disappears from the apps; its answers stay. The learner can adopt it again.
func (s *Service) DiscardAgentDraft(ctx context.Context, token, id string) (AgentDraftResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return AgentDraftResult{}, err
	}
	if _, err := s.reader().GetAgentDraft(ctx, id); err != nil {
		return AgentDraftResult{}, notFound(err, "draft")
	}
	v, err := s.transition(ctx, id, func(q store.Question) (string, string, bool, error) {
		switch q.Status {
		case "draft", "needs_review":
			return "rejected", draftNote, false, nil
		case "published":
			return "rejected", draftNote, true, nil
		case "rejected", "retired":
			return "", "", false, nil // already out
		}
		return "", "", false, invalid("这道题现在不能取消采纳")
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
