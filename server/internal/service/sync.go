package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"

	"github.com/chlu-ux/quizmind/server/internal/store"
)

// flagThreshold is how many "this question is wrong" reports take a published
// question offline for re-review.
const flagThreshold = 2

// AppBank is the bank summary the mobile app lists.
type AppBank struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Description   string `json:"description"`
	QuestionCount int64  `json:"question_count"`
}

func (s *Service) AppBanks(ctx context.Context) ([]AppBank, error) {
	qs := s.reader()
	banks, err := qs.ListBanks(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := qs.ListPublishedQuestionCountsByBank(ctx)
	if err != nil {
		return nil, err
	}
	counts := make(map[string]int64, len(rows))
	for _, r := range rows {
		counts[r.BankID] = r.N
	}
	out := make([]AppBank, 0, len(banks))
	for _, b := range banks {
		out = append(out, AppBank{ID: b.ID, Title: b.Title, Description: b.Description, QuestionCount: counts[b.ID]})
	}
	return out, nil
}

// SyncQuestion is a published question as the app stores it. It deliberately
// omits review metadata and the source chunk.
type SyncQuestion struct {
	ID          string   `json:"id"`
	BankID      string   `json:"bank_id"`
	Type        string   `json:"type"`
	Stem        string   `json:"stem"`
	Options     []string `json:"options"`
	Answer      []int    `json:"answer"`
	Explanation string   `json:"explanation"`
	Difficulty  int64    `json:"difficulty"`
	Tags        []string `json:"tags"`
	SourceQuote string   `json:"source_quote"`
	SyncSeq     int64    `json:"sync_seq"`
	UpdatedAt   int64    `json:"updated_at"`
}

type SyncQuestionsPage struct {
	Items   []SyncQuestion `json:"items"`
	Deleted []string       `json:"deleted"`
	NextSeq int64          `json:"next_seq"`
	HasMore bool           `json:"has_more"`
}

// SyncQuestions returns changes with sync_seq > since in sync_seq order. A
// question that is no longer published (withdrawn, rejected, flagged, stale)
// appears in Deleted so the app can hide it while keeping the answer history.
func (s *Service) SyncQuestions(ctx context.Context, since int64, limit int) (SyncQuestionsPage, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	rows, err := s.reader().ListSyncQuestions(ctx, store.ListSyncQuestionsParams{
		Since: sql.NullInt64{Int64: since, Valid: true}, PageLimit: int64(limit) + 1,
	})
	if err != nil {
		return SyncQuestionsPage{}, err
	}
	page := SyncQuestionsPage{Items: []SyncQuestion{}, Deleted: []string{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, q := range rows {
		page.NextSeq = q.SyncSeq.Int64
		if q.Status != "published" {
			page.Deleted = append(page.Deleted, q.ID)
			continue
		}
		v := questionView(q)
		page.Items = append(page.Items, SyncQuestion{
			ID: v.ID, BankID: v.BankID, Type: v.Type, Stem: v.Stem, Options: v.Options, Answer: v.Answer,
			Explanation: v.Explanation, Difficulty: v.Difficulty, Tags: v.Tags, SourceQuote: v.SourceQuote,
			SyncSeq: q.SyncSeq.Int64, UpdatedAt: v.UpdatedAt,
		})
	}
	return page, nil
}

// AttemptIn is one answer record uploaded by the app. ID is a client-generated
// ULID, which makes uploads idempotent.
type AttemptIn struct {
	ID         string `json:"id"`
	QuestionID string `json:"question_id"`
	DeviceID   string `json:"device_id"`
	Answer     []int  `json:"answer"`
	IsCorrect  bool   `json:"is_correct"`
	DurationMs *int64 `json:"duration_ms"`
	// ReviewMs is the time spent after answering; it can be raised by re-uploading the attempt.
	ReviewMs   *int64 `json:"review_ms"`
	AnsweredAt int64  `json:"answered_at"`
}

type UploadResult struct {
	Accepted int `json:"accepted"`
	Ignored  int `json:"ignored"`
}

const maxBatch = 500

// UploadAttempts appends attempts. Duplicates (same id) and attempts for
// unknown questions are ignored rather than failing the batch, so the app's
// outbox always drains. A duplicate that carries a larger review_ms raises it.
func (s *Service) UploadAttempts(ctx context.Context, in []AttemptIn) (UploadResult, error) {
	if len(in) > maxBatch {
		return UploadResult{}, invalid("at most %d attempts per request", maxBatch)
	}
	for i, a := range in {
		if a.ID == "" || len(a.ID) > 64 || a.QuestionID == "" || strings.TrimSpace(a.DeviceID) == "" || a.AnsweredAt <= 0 {
			return UploadResult{}, invalid("attempt %d: id, question_id, device_id and answered_at are required", i)
		}
	}
	var res UploadResult
	now := nowMs()
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		for _, a := range in {
			var dur, review sql.NullInt64
			if a.DurationMs != nil {
				dur = sql.NullInt64{Int64: *a.DurationMs, Valid: true}
			}
			if a.ReviewMs != nil && *a.ReviewMs >= 0 {
				review = sql.NullInt64{Int64: *a.ReviewMs, Valid: true}
			}
			correct := int64(0)
			if a.IsCorrect {
				correct = 1
			}
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			n, err := qs.InsertAttempt(ctx, store.InsertAttemptParams{
				ID: a.ID, QuestionID: a.QuestionID, DeviceID: a.DeviceID, Answer: jsonArray(a.Answer),
				IsCorrect: correct, DurationMs: dur, ReviewMs: review, AnsweredAt: a.AnsweredAt, ReceivedAt: now, SyncSeq: seq,
			})
			if err != nil {
				return err
			}
			if n > 0 {
				res.Accepted++
			} else {
				res.Ignored++
			}
		}
		return nil
	})
	return res, err
}

// AttemptOut is an attempt as downloaded by another device: AttemptIn plus the
// server cursor.
type AttemptOut struct {
	AttemptIn
	SyncSeq int64 `json:"sync_seq"`
}

type SyncAttemptsPage struct {
	Items   []AttemptOut `json:"items"`
	NextSeq int64        `json:"next_seq"`
	HasMore bool         `json:"has_more"`
}

// SyncAttempts returns attempts uploaded after the given server sync_seq, so
// every device can compute statistics over the whole answer history. Attempts
// are an append-only log, so the client only has to skip ids it already has.
func (s *Service) SyncAttempts(ctx context.Context, since int64, limit int) (SyncAttemptsPage, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	rows, err := s.reader().ListAttemptsSince(ctx, store.ListAttemptsSinceParams{Since: since, PageLimit: int64(limit) + 1})
	if err != nil {
		return SyncAttemptsPage{}, err
	}
	page := SyncAttemptsPage{Items: []AttemptOut{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, r := range rows {
		var answer []int
		if err := json.Unmarshal([]byte(r.Answer), &answer); err != nil || answer == nil {
			answer = []int{}
		}
		out := AttemptOut{SyncSeq: r.SyncSeq, AttemptIn: AttemptIn{
			ID: r.ID, QuestionID: r.QuestionID, DeviceID: r.DeviceID, Answer: answer,
			IsCorrect: r.IsCorrect != 0, AnsweredAt: r.AnsweredAt,
		}}
		if r.DurationMs.Valid {
			v := r.DurationMs.Int64
			out.DurationMs = &v
		}
		if r.ReviewMs.Valid {
			v := r.ReviewMs.Int64
			out.ReviewMs = &v
		}
		page.NextSeq = r.SyncSeq
		page.Items = append(page.Items, out)
	}
	return page, nil
}

// StateIn / StateOut carry the per-question learning state. FSRS is opaque to
// the server.
type StateIn struct {
	QuestionID string          `json:"question_id"`
	FSRS       json.RawMessage `json:"fsrs"`
	DueAt      *int64          `json:"due_at"`
	Favorite   bool            `json:"favorite"`
	WrongCount int64           `json:"wrong_count"`
	UpdatedAt  int64           `json:"updated_at"`
}

type StateOut struct {
	StateIn
	SyncSeq int64 `json:"sync_seq"`
}

// UploadStates merges states last-writer-wins on the client's updated_at. A
// state that is not newer than the stored one is ignored.
func (s *Service) UploadStates(ctx context.Context, in []StateIn) (UploadResult, error) {
	if len(in) > maxBatch {
		return UploadResult{}, invalid("at most %d states per request", maxBatch)
	}
	for i, st := range in {
		if st.QuestionID == "" || st.UpdatedAt <= 0 || st.WrongCount < 0 {
			return UploadResult{}, invalid("state %d: question_id and updated_at are required", i)
		}
	}
	var res UploadResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		for _, st := range in {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			var fsrs sql.NullString
			if len(st.FSRS) > 0 && string(st.FSRS) != "null" {
				fsrs = sql.NullString{String: string(st.FSRS), Valid: true}
			}
			var due sql.NullInt64
			if st.DueAt != nil {
				due = sql.NullInt64{Int64: *st.DueAt, Valid: true}
			}
			fav := int64(0)
			if st.Favorite {
				fav = 1
			}
			n, err := qs.UpsertQuestionState(ctx, store.UpsertQuestionStateParams{
				QuestionID: st.QuestionID, Fsrs: fsrs, DueAt: due, Favorite: fav, WrongCount: st.WrongCount,
				UpdatedAt: st.UpdatedAt, SyncSeq: seq,
			})
			if err != nil {
				return err
			}
			if n > 0 {
				res.Accepted++
			} else {
				res.Ignored++
			}
		}
		return nil
	})
	return res, err
}

type SyncStatesPage struct {
	Items   []StateOut `json:"items"`
	NextSeq int64      `json:"next_seq"`
	HasMore bool       `json:"has_more"`
}

// SyncStates returns states changed after the given server sync_seq, so a
// second device converges on what the first one uploaded.
func (s *Service) SyncStates(ctx context.Context, since int64, limit int) (SyncStatesPage, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	rows, err := s.reader().ListStatesSince(ctx, store.ListStatesSinceParams{Since: since, PageLimit: int64(limit) + 1})
	if err != nil {
		return SyncStatesPage{}, err
	}
	page := SyncStatesPage{Items: []StateOut{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, r := range rows {
		out := StateOut{SyncSeq: r.SyncSeq, StateIn: StateIn{
			QuestionID: r.QuestionID, Favorite: r.Favorite != 0, WrongCount: r.WrongCount, UpdatedAt: r.UpdatedAt,
		}}
		if r.Fsrs.Valid {
			out.FSRS = json.RawMessage(r.Fsrs.String)
		}
		if r.DueAt.Valid {
			v := r.DueAt.Int64
			out.DueAt = &v
		}
		page.NextSeq = r.SyncSeq
		page.Items = append(page.Items, out)
	}
	return page, nil
}

// maxSessionBytes bounds one saved quiz. A 1000-question bank is about 40 KB.
const maxSessionBytes = 512 << 10

// maxSessionBatch bounds one upload. There is one session per bank, so this is plenty.
const maxSessionBatch = 50

// SessionIn is the saved quiz of one scope (a bank id). Data is the client's
// progress document, opaque to the server; null or absent means the quiz was
// finished and any saved copy should disappear.
type SessionIn struct {
	Scope     string          `json:"scope"`
	Data      json.RawMessage `json:"data"`
	UpdatedAt int64           `json:"updated_at"`
	DeviceID  string          `json:"device_id"`
}

type SessionOut struct {
	SessionIn
	SyncSeq int64 `json:"sync_seq"`
}

// UploadSessions merges saved quizzes last-writer-wins on the client's
// updated_at. Finished quizzes are kept as tombstones (Data null) so that
// finishing on one device clears the others.
func (s *Service) UploadSessions(ctx context.Context, in []SessionIn) (UploadResult, error) {
	if len(in) > maxSessionBatch {
		return UploadResult{}, invalid("at most %d sessions per request", maxSessionBatch)
	}
	for i, ss := range in {
		switch {
		case ss.Scope == "" || len(ss.Scope) > 64 || ss.UpdatedAt <= 0:
			return UploadResult{}, invalid("session %d: scope and updated_at are required", i)
		case len(ss.DeviceID) > 64:
			return UploadResult{}, invalid("session %d: device_id is too long", i)
		case len(ss.Data) > maxSessionBytes:
			return UploadResult{}, invalid("session %d: data is larger than %d bytes", i, maxSessionBytes)
		case len(ss.Data) > 0 && !json.Valid(ss.Data):
			return UploadResult{}, invalid("session %d: data is not valid JSON", i)
		}
	}
	var res UploadResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		for _, ss := range in {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			var data sql.NullString
			if len(ss.Data) > 0 && string(ss.Data) != "null" {
				data = sql.NullString{String: string(ss.Data), Valid: true}
			}
			n, err := qs.UpsertQuizSession(ctx, store.UpsertQuizSessionParams{
				Scope: ss.Scope, Data: data, UpdatedAt: ss.UpdatedAt, DeviceID: ss.DeviceID, SyncSeq: seq,
			})
			if err != nil {
				return err
			}
			if n > 0 {
				res.Accepted++
			} else {
				res.Ignored++
			}
		}
		return nil
	})
	return res, err
}

type SyncSessionsPage struct {
	Items   []SessionOut `json:"items"`
	NextSeq int64        `json:"next_seq"`
	HasMore bool         `json:"has_more"`
}

// SyncSessions returns saved quizzes changed after the given server sync_seq.
func (s *Service) SyncSessions(ctx context.Context, since int64, limit int) (SyncSessionsPage, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := s.reader().ListQuizSessionsSince(ctx, store.ListQuizSessionsSinceParams{Since: since, PageLimit: int64(limit) + 1})
	if err != nil {
		return SyncSessionsPage{}, err
	}
	page := SyncSessionsPage{Items: []SessionOut{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, r := range rows {
		out := SessionOut{SyncSeq: r.SyncSeq, SessionIn: SessionIn{Scope: r.Scope, UpdatedAt: r.UpdatedAt, DeviceID: r.DeviceID}}
		if r.Data.Valid {
			out.Data = json.RawMessage(r.Data.String)
		}
		page.NextSeq = r.SyncSeq
		page.Items = append(page.Items, out)
	}
	return page, nil
}

type FlagResult struct {
	FlagCount int64  `json:"flag_count"`
	Status    string `json:"status"`
}

// flagNote is the review note a question gets when reports take it offline. It
// is how DismissFlags tells "went offline because of reports" from "went offline
// for another reason" (a failed automatic check, say).
const flagNote = "flagged by app users"

// FlagReasons are the reasons a client may attach to a report. Anything else is
// stored as "other", so a newer client never gets an older server to reject it.
var FlagReasons = []string{"wrong_answer", "ambiguous", "typo", "other"}

func normalizeFlagReason(r string) string {
	for _, v := range FlagReasons {
		if r == v {
			return r
		}
	}
	return "other"
}

// FlagQuestion records a "this question has a problem" report with its reason.
// Reaching flagThreshold unresolved reports takes the question offline
// (needs_review) and bumps its sync_seq so every device drops it. Flagging a
// question that is already offline is a no-op.
func (s *Service) FlagQuestion(ctx context.Context, id, reason string) (FlagResult, error) {
	var res FlagResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		q, err := qs.GetQuestion(ctx, id)
		if err != nil {
			return notFound(err, "question")
		}
		res = FlagResult{FlagCount: q.FlagCount, Status: q.Status}
		if q.Status != "published" {
			return nil
		}
		now := nowMs()
		if err := qs.InsertQuestionFlag(ctx, store.InsertQuestionFlagParams{
			ID: newID(), QuestionID: id, Reason: normalizeFlagReason(reason), CreatedAt: now,
		}); err != nil {
			return err
		}
		count, err := qs.BumpQuestionFlag(ctx, store.BumpQuestionFlagParams{UpdatedAt: now, ID: id})
		if err != nil {
			return err
		}
		res.FlagCount = count
		if count < flagThreshold {
			return nil
		}
		seq, err := qs.NextSyncSeq(ctx)
		if err != nil {
			return err
		}
		res.Status = "needs_review"
		return qs.SetQuestionStatus(ctx, store.SetQuestionStatusParams{
			Status: res.Status, ReviewNote: flagNote, SyncSeq: sql.NullInt64{Int64: seq, Valid: true},
			UpdatedAt: now, ID: id,
		})
	})
	return res, err
}
