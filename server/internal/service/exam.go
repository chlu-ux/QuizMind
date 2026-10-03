package service

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/chlu-ux/quizmind/server/internal/store"
)

// ExamItemIn is one question of a handed-in paper: the question id, the option
// indexes picked (empty when left blank) and whether that was right.
type ExamItemIn struct {
	Q string `json:"q"`
	S []int  `json:"s"`
	C bool   `json:"c"`
}

// ExamIn is a finished mock exam uploaded by a device. ID is a client ULID, which
// makes uploads idempotent; the exam never changes afterwards.
type ExamIn struct {
	ID         string       `json:"id"`
	BankID     string       `json:"bank_id"`
	Title      string       `json:"title"`
	FinishedAt int64        `json:"finished_at"`
	Total      int64        `json:"total"`
	Correct    int64        `json:"correct"`
	Answered   int64        `json:"answered"`
	Percent    int64        `json:"percent"`
	Passed     bool         `json:"passed"`
	LimitSec   *int64       `json:"limit_sec"`
	UsedMs     int64        `json:"used_ms"`
	DeviceID   string       `json:"device_id"`
	Items      []ExamItemIn `json:"items"`
}

type ExamOut struct {
	ExamIn
	SyncSeq int64 `json:"sync_seq"`
}

type SyncExamsPage struct {
	Items   []ExamOut `json:"items"`
	NextSeq int64     `json:"next_seq"`
	HasMore bool      `json:"has_more"`
}

// maxExamBatch bounds one upload; an exam is rarely more than a few KB.
const (
	maxExamBatch = 10
	maxExamItems = 1000
)

// UploadExams appends finished exams. An id the server already has is ignored,
// so the app's outbox always drains.
func (s *Service) UploadExams(ctx context.Context, in []ExamIn) (UploadResult, error) {
	if len(in) > maxExamBatch {
		return UploadResult{}, invalid("at most %d exams per request", maxExamBatch)
	}
	for i, e := range in {
		switch {
		case e.ID == "" || len(e.ID) > 64 || e.BankID == "" || len(e.BankID) > 64 || e.FinishedAt <= 0:
			return UploadResult{}, invalid("exam %d: id, bank_id and finished_at are required", i)
		case len(e.Title) > 200 || len(e.DeviceID) > 64:
			return UploadResult{}, invalid("exam %d: title or device_id is too long", i)
		case e.Total <= 0 || e.Correct < 0 || e.Correct > e.Total || e.Answered < 0 || e.Answered > e.Total || e.Percent < 0 || e.Percent > 100 || e.UsedMs < 0:
			return UploadResult{}, invalid("exam %d: scores are out of range", i)
		case len(e.Items) > maxExamItems:
			return UploadResult{}, invalid("exam %d: at most %d items", i, maxExamItems)
		}
		for _, it := range e.Items {
			if it.Q == "" || len(it.Q) > 64 {
				return UploadResult{}, invalid("exam %d: every item needs a question id", i)
			}
		}
	}
	var res UploadResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		qs := store.New(tx)
		for _, e := range in {
			seq, err := qs.NextSyncSeq(ctx)
			if err != nil {
				return err
			}
			items := e.Items
			if items == nil {
				items = []ExamItemIn{}
			}
			for i := range items {
				if items[i].S == nil {
					items[i].S = []int{}
				}
			}
			raw, err := json.Marshal(items)
			if err != nil {
				return err
			}
			var limit sql.NullInt64
			if e.LimitSec != nil {
				limit = sql.NullInt64{Int64: *e.LimitSec, Valid: true}
			}
			passed := int64(0)
			if e.Passed {
				passed = 1
			}
			n, err := qs.InsertExam(ctx, store.InsertExamParams{
				ID: e.ID, BankID: e.BankID, Title: e.Title, FinishedAt: e.FinishedAt, Total: e.Total,
				Correct: e.Correct, Answered: e.Answered, Percent: e.Percent, Passed: passed,
				LimitSec: limit, UsedMs: e.UsedMs, DeviceID: e.DeviceID, Items: string(raw), SyncSeq: seq,
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

// SyncExams returns exams uploaded after the given server sync_seq.
func (s *Service) SyncExams(ctx context.Context, since int64, limit int) (SyncExamsPage, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := s.reader().ListExamsSince(ctx, store.ListExamsSinceParams{Since: since, PageLimit: int64(limit) + 1})
	if err != nil {
		return SyncExamsPage{}, err
	}
	page := SyncExamsPage{Items: []ExamOut{}, NextSeq: since}
	if len(rows) > limit {
		rows, page.HasMore = rows[:limit], true
	}
	for _, r := range rows {
		var items []ExamItemIn
		if err := json.Unmarshal([]byte(r.Items), &items); err != nil || items == nil {
			items = []ExamItemIn{}
		}
		out := ExamOut{SyncSeq: r.SyncSeq, ExamIn: ExamIn{
			ID: r.ID, BankID: r.BankID, Title: r.Title, FinishedAt: r.FinishedAt, Total: r.Total,
			Correct: r.Correct, Answered: r.Answered, Percent: r.Percent, Passed: r.Passed != 0,
			UsedMs: r.UsedMs, DeviceID: r.DeviceID, Items: items,
		}}
		if r.LimitSec.Valid {
			v := r.LimitSec.Int64
			out.LimitSec = &v
		}
		page.NextSeq = r.SyncSeq
		page.Items = append(page.Items, out)
	}
	return page, nil
}
