package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/chlu-ux/quizmind/server/internal/pipeline"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

type QuestionView struct {
	ID               string   `json:"id"`
	BankID           string   `json:"bank_id"`
	ChunkID          string   `json:"chunk_id"`
	Type             string   `json:"type"`
	Stem             string   `json:"stem"`
	Options          []string `json:"options"`
	Answer           []int    `json:"answer"`
	Explanation      string   `json:"explanation"`
	Difficulty       int64    `json:"difficulty"`
	Tags             []string `json:"tags"`
	SourceQuote      string   `json:"source_quote"`
	Status           string   `json:"status"`
	ReviewNote       string   `json:"review_note"`
	GenModel         string   `json:"gen_model"`
	GenPromptVersion string   `json:"gen_prompt_version"`
	FlagCount        int64    `json:"flag_count"`
	SyncSeq          *int64   `json:"sync_seq"`
	CreatedAt        int64    `json:"created_at"`
	UpdatedAt        int64    `json:"updated_at"`
}

// FlagView is one report from an app. ResolvedAt is nil while it is unhandled.
type FlagView struct {
	Reason     string `json:"reason"`
	CreatedAt  int64  `json:"created_at"`
	ResolvedAt *int64 `json:"resolved_at"`
}

type QuestionDetail struct {
	QuestionView
	ChunkText   string `json:"chunk_text"`
	HeadingPath string `json:"heading_path"`
	DocumentID  string `json:"document_id"`
	// Flags lists the reports, newest first. Counts that predate the question_flag
	// table have no rows here, so flag_count can exceed the unresolved ones listed.
	Flags []FlagView `json:"flags"`
}

func questionView(q store.Question) QuestionView {
	v := QuestionView{
		ID: q.ID, BankID: q.BankID, ChunkID: q.ChunkID.String, Type: q.Type, Stem: q.Stem,
		Explanation: q.Explanation, Difficulty: q.Difficulty, SourceQuote: q.SourceQuote,
		Status: q.Status, ReviewNote: q.ReviewNote, GenModel: q.GenModel, GenPromptVersion: q.GenPromptVersion,
		FlagCount: q.FlagCount, CreatedAt: q.CreatedAt, UpdatedAt: q.UpdatedAt,
		Options: []string{}, Answer: []int{}, Tags: []string{},
	}
	_ = json.Unmarshal([]byte(q.Options), &v.Options)
	_ = json.Unmarshal([]byte(q.Answer), &v.Answer)
	_ = json.Unmarshal([]byte(q.Tags), &v.Tags)
	if q.SyncSeq.Valid {
		seq := q.SyncSeq.Int64
		v.SyncSeq = &seq
	}
	return v
}

type QuestionFilter struct {
	Status, BankID, DocumentID string
	// Search is a case-insensitive substring match on the stem, options and explanation.
	Search string
	// Flagged keeps only questions with unresolved reports, whatever their status.
	Flagged       bool
	Limit, Offset int
}

type QuestionPage struct {
	Items []QuestionView `json:"items"`
	Total int64          `json:"total"`
}

func (s *Service) ListQuestions(ctx context.Context, f QuestionFilter) (QuestionPage, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	opt := func(v string) any {
		if v == "" {
			return nil
		}
		return v
	}
	var search any
	if t := strings.TrimSpace(f.Search); t != "" {
		search = t
	}
	flagged := int64(0)
	if f.Flagged {
		flagged = 1
	}
	qs := s.reader()
	rows, err := qs.ListQuestions(ctx, store.ListQuestionsParams{
		Status: opt(f.Status), BankID: opt(f.BankID), DocumentID: opt(f.DocumentID), Flagged: flagged, Search: search,
		PageLimit: int64(f.Limit), PageOffset: int64(f.Offset),
	})
	if err != nil {
		return QuestionPage{}, err
	}
	total, err := qs.CountQuestions(ctx, store.CountQuestionsParams{
		Status: opt(f.Status), BankID: opt(f.BankID), DocumentID: opt(f.DocumentID), Flagged: flagged, Search: search,
	})
	if err != nil {
		return QuestionPage{}, err
	}
	page := QuestionPage{Items: make([]QuestionView, 0, len(rows)), Total: total}
	for _, r := range rows {
		page.Items = append(page.Items, questionView(r))
	}
	return page, nil
}

func (s *Service) GetQuestion(ctx context.Context, id string) (QuestionDetail, error) {
	return questionDetail(ctx, s.reader(), id)
}

func questionDetail(ctx context.Context, qs *store.Queries, id string) (QuestionDetail, error) {
	d, err := qs.GetQuestionDetail(ctx, id)
	if err != nil {
		return QuestionDetail{}, notFound(err, "question")
	}
	flags, err := qs.ListQuestionFlags(ctx, id)
	if err != nil {
		return QuestionDetail{}, err
	}
	out := detailView(d)
	out.Flags = make([]FlagView, 0, len(flags))
	for _, f := range flags {
		v := FlagView{Reason: f.Reason, CreatedAt: f.CreatedAt}
		if f.ResolvedAt.Valid {
			t := f.ResolvedAt.Int64
			v.ResolvedAt = &t
		}
		out.Flags = append(out.Flags, v)
	}
	return out, nil
}

func detailView(d store.GetQuestionDetailRow) QuestionDetail {
	q := store.Question{
		ID: d.ID, BankID: d.BankID, ChunkID: d.ChunkID, Type: d.Type, Stem: d.Stem, Options: d.Options,
		Answer: d.Answer, Explanation: d.Explanation, Difficulty: d.Difficulty, Tags: d.Tags,
		SourceQuote: d.SourceQuote, Status: d.Status, ReviewNote: d.ReviewNote, ContentHash: d.ContentHash,
		GenModel: d.GenModel, GenPromptVersion: d.GenPromptVersion, FlagCount: d.FlagCount,
		SyncSeq: d.SyncSeq, CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt,
	}
	return QuestionDetail{QuestionView: questionView(q), ChunkText: d.ChunkText,
		HeadingPath: d.HeadingPath, DocumentID: d.DocumentID}
}

// QuestionEdit holds the fields a reviewer may change. Nil means "leave as is".
type QuestionEdit struct {
	Stem        *string   `json:"stem"`
	Options     *[]string `json:"options"`
	AnswerIndex *int      `json:"answer_index"`
	Explanation *string   `json:"explanation"`
	Difficulty  *int      `json:"difficulty"`
	Tags        *[]string `json:"tags"`
}

// EditQuestion applies reviewer edits after re-running the same rules the
// generator output goes through. Editing a published question republishes it
// (new sync_seq) so clients pick up the change.
func (s *Service) EditQuestion(ctx context.Context, id string, e QuestionEdit) (QuestionDetail, error) {
	var out QuestionDetail
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		d, err := qs.GetQuestionDetail(ctx, id)
		if err != nil {
			return notFound(err, "question")
		}
		cur := questionView(store.Question{
			ID: d.ID, Type: d.Type, Stem: d.Stem, Options: d.Options, Answer: d.Answer, Explanation: d.Explanation,
			Difficulty: d.Difficulty, Tags: d.Tags, SourceQuote: d.SourceQuote, Status: d.Status,
		})
		switch d.Status {
		case "stale", "retired":
			return invalid("a %s question cannot be edited", d.Status)
		}

		g := pipeline.GeneratedQuestion{
			Type: cur.Type, Stem: cur.Stem, Options: cur.Options, Explanation: cur.Explanation,
			Difficulty: int(cur.Difficulty), Tags: cur.Tags, SourceQuote: cur.SourceQuote,
		}
		if len(cur.Answer) > 0 {
			g.AnswerIndex = cur.Answer[0]
		}
		if e.Stem != nil {
			g.Stem = *e.Stem
		}
		if e.Options != nil {
			g.Options = *e.Options
		}
		if e.AnswerIndex != nil {
			g.AnswerIndex = *e.AnswerIndex
		}
		if e.Explanation != nil {
			g.Explanation = *e.Explanation
		}
		if e.Difficulty != nil {
			g.Difficulty = *e.Difficulty
		}
		if e.Tags != nil {
			g.Tags = *e.Tags
		}

		v, err := pipeline.ValidateQuestion(g, d.ChunkText)
		if err != nil {
			return invalid("%v", err)
		}
		if err := checkMedia(ctx, qs, append([]string{v.Stem, v.Explanation}, v.Options...)...); err != nil {
			return err
		}
		now := nowMs()
		if err := qs.UpdateQuestionContent(ctx, store.UpdateQuestionContentParams{
			Type: v.Type, Stem: v.Stem, Options: jsonArray(v.Options), Answer: jsonArray([]int{v.AnswerIndex}),
			Explanation: v.Explanation, Difficulty: int64(v.Difficulty), Tags: jsonArray(v.Tags),
			ContentHash: v.Hash, UpdatedAt: now, ID: id,
		}); err != nil {
			return err
		}
		if d.Status == "published" {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			if err := qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
				Status: d.Status, ReviewNote: d.ReviewNote, SyncSeq: sql.NullInt64{Int64: seq, Valid: true},
				UpdatedAt: now, ID: id,
			}); err != nil {
				return err
			}
		}
		out, err = questionDetail(ctx, qs, id)
		return err
	})
	return out, err
}

// ApproveQuestion publishes a question. Rejected questions may be approved too,
// which lets a reviewer overrule an automatic rejection. Approving also settles
// the question's reports. A published question that still has reports is a
// "the reports are wrong" ruling, so it goes through DismissFlags.
func (s *Service) ApproveQuestion(ctx context.Context, id string) (QuestionView, error) {
	return s.transition(ctx, id, func(q store.Question) (string, string, bool, error) {
		switch q.Status {
		case "published":
			if q.FlagCount > 0 {
				return "published", "", true, nil
			}
			return "", "", false, nil
		case "needs_review", "validated", "rejected", "draft":
			return "published", "", true, nil
		}
		return "", "", false, invalid("a %s question cannot be approved", q.Status)
	})
}

// RejectQuestion rejects a question; if it was published it is withdrawn.
func (s *Service) RejectQuestion(ctx context.Context, id, note string) (QuestionView, error) {
	return s.transition(ctx, id, func(q store.Question) (string, string, bool, error) {
		switch q.Status {
		case "needs_review", "validated", "published", "draft":
			if note == "" {
				note = "rejected by reviewer"
			}
			return "rejected", note, q.Status == "published", nil
		case "rejected":
			return "", "", false, nil
		}
		return "", "", false, invalid("a %s question cannot be rejected", q.Status)
	})
}

// transition runs decide against the current row and applies the result. decide
// returns (newStatus, note, bumpSeq, err); an empty newStatus means no change.
// bumpSeq assigns a fresh sync_seq. Publishing always bumps it.
func (s *Service) transition(ctx context.Context, id string,
	decide func(store.Question) (string, string, bool, error)) (QuestionView, error) {

	var out QuestionView
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		q, err := qs.GetQuestion(ctx, id)
		if err != nil {
			return notFound(err, "question")
		}
		status, note, bump, err := decide(q)
		if err != nil {
			return err
		}
		if status == "" {
			out = questionView(q)
			return nil
		}
		seq := sql.NullInt64{}
		if bump || status == "published" {
			n, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			seq = sql.NullInt64{Int64: n, Valid: true}
		}
		now := nowMs()
		if err := qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
			Status: status, ReviewNote: note, SyncSeq: seq, UpdatedAt: now, ID: id,
		}); err != nil {
			return err
		}
		// Publishing or rejecting is the reviewer's verdict on the reports too.
		if err := settleFlags(ctx, qs, id, now); err != nil {
			return err
		}
		q2, err := qs.GetQuestion(ctx, id)
		if err != nil {
			return err
		}
		out = questionView(q2)
		return nil
	})
	return out, err
}

// settleFlags marks every open report on a question as handled and zeroes its counter.
func settleFlags(ctx context.Context, qs *store.Queries, id string, now int64) error {
	if err := qs.ResolveQuestionFlags(ctx, store.ResolveQuestionFlagsParams{
		ResolvedAt: sql.NullInt64{Int64: now, Valid: true}, QuestionID: id,
	}); err != nil {
		return err
	}
	return qs.ClearQuestionFlagCount(ctx, id)
}

// DismissFlags is the reviewer's "dealt with it": the reports are marked handled
// and the counter goes back to zero.
//   - A question the reports took offline is published again.
//   - A published question gets a fresh sync_seq, so a device that hid it after
//     its own report gets it back.
//   - Any other state (an automatic check failed, say) is left as it is; only
//     the reports are cleared.
func (s *Service) DismissFlags(ctx context.Context, id string) (QuestionView, error) {
	var out QuestionView
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		q, err := qs.GetQuestion(ctx, id)
		if err != nil {
			return notFound(err, "question")
		}
		now := nowMs()
		if err := settleFlags(ctx, qs, id, now); err != nil {
			return err
		}
		offlineByFlags := q.Status == "needs_review" && q.ReviewNote == flagNote
		if q.Status == "published" || offlineByFlags {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			note := q.ReviewNote
			if offlineByFlags {
				note = ""
			}
			if err := qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
				Status: "published", ReviewNote: note, SyncSeq: sql.NullInt64{Int64: seq, Valid: true},
				UpdatedAt: now, ID: id,
			}); err != nil {
				return err
			}
		}
		q2, err := qs.GetQuestion(ctx, id)
		if err != nil {
			return err
		}
		out = questionView(q2)
		return nil
	})
	return out, err
}

type BulkResult struct {
	Done   int               `json:"done"`
	Failed map[string]string `json:"failed"`
}

// BulkReview approves or rejects many questions; one failure does not stop the rest.
func (s *Service) BulkReview(ctx context.Context, action string, ids []string, note string) (BulkResult, error) {
	if action != "approve" && action != "reject" {
		return BulkResult{}, invalid("action must be approve or reject")
	}
	if len(ids) == 0 || len(ids) > 500 {
		return BulkResult{}, invalid("ids must contain 1..500 entries")
	}
	res := BulkResult{Failed: map[string]string{}}
	for _, id := range ids {
		var err error
		if action == "approve" {
			_, err = s.ApproveQuestion(ctx, id)
		} else {
			_, err = s.RejectQuestion(ctx, id, note)
		}
		if err != nil {
			res.Failed[id] = fmt.Sprint(err)
			continue
		}
		res.Done++
	}
	return res, nil
}
