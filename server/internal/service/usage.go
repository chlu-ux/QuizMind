package service

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

// Who made a logged model call.
const (
	// SourceServer: the pipeline or the assistant. Only these count towards the daily token budget.
	SourceServer = "server"
	// SourceClient: an app, reporting what an AI explanation it requested itself cost.
	SourceClient = "client"
)

// UsageRow is the token use of one (day, source, role, model).
type UsageRow struct {
	Day            string `json:"day"`
	Source         string `json:"source"`
	Role           string `json:"role"`
	Model          string `json:"model"`
	Calls          int64  `json:"calls"`
	InputTokens    int64  `json:"input_tokens"`
	OutputTokens   int64  `json:"output_tokens"`
	CachedTokens   int64  `json:"cached_tokens"`
	Failures       int64  `json:"failures"`
	EstimatedCalls int64  `json:"estimated_calls"` // calls whose token counts an app guessed
}

func (s *Service) Usage(ctx context.Context, days int) ([]UsageRow, error) {
	rows, err := s.reader().UsageByDay(ctx, sinceDays(days))
	if err != nil {
		return nil, err
	}
	out := make([]UsageRow, 0, len(rows))
	for _, r := range rows {
		day, _ := r.Day.(string)
		out = append(out, UsageRow{Day: day, Source: r.Source, Role: r.Role, Model: r.Model, Calls: r.Calls,
			InputTokens: r.InputTokens, OutputTokens: r.OutputTokens, CachedTokens: r.CachedTokens,
			Failures: r.Failures, EstimatedCalls: r.EstimatedCalls})
	}
	return out, nil
}

func sinceDays(days int) int64 {
	if days <= 0 || days > 365 {
		days = 30
	}
	return nowMs() - int64(days)*24*3600*1000
}

// CallFilter narrows the call list. Empty strings mean "any".
type CallFilter struct {
	Days          int
	Source, Role  string
	FailedOnly    bool
	Limit, Offset int
}

// CallView is one logged model call, with the question it was about when there is one.
type CallView struct {
	ID           string `json:"id"`
	Source       string `json:"source"`
	Role         string `json:"role"`
	Provider     string `json:"provider"`
	Model        string `json:"model"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	CachedTokens int64  `json:"cached_tokens"`
	LatencyMs    int64  `json:"latency_ms"`
	OK           bool   `json:"ok"`
	Error        string `json:"error"`
	Estimated    bool   `json:"estimated"`
	CreatedAt    int64  `json:"created_at"`
	DeviceID     string `json:"device_id"`
	JobID        string `json:"job_id"`
	QuestionID   string `json:"question_id"`
	QuestionStem string `json:"question_stem"`
	BankTitle    string `json:"bank_title"`
}

type CallPage struct {
	Items []CallView `json:"items"`
	Total int64      `json:"total"`
}

func (s *Service) ListCalls(ctx context.Context, f CallFilter) (CallPage, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 20
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
	var failed any
	if f.FailedOnly {
		failed = int64(1)
	}
	since := sinceDays(f.Days)
	q := s.reader()
	rows, err := q.ListLLMCalls(ctx, store.ListLLMCallsParams{Since: since, Source: opt(f.Source), Role: opt(f.Role),
		FailedOnly: failed, PageLimit: int64(f.Limit), PageOffset: int64(f.Offset)})
	if err != nil {
		return CallPage{}, err
	}
	total, err := q.CountLLMCalls(ctx, store.CountLLMCallsParams{Since: since, Source: opt(f.Source), Role: opt(f.Role), FailedOnly: failed})
	if err != nil {
		return CallPage{}, err
	}
	page := CallPage{Items: make([]CallView, 0, len(rows)), Total: total}
	for _, r := range rows {
		page.Items = append(page.Items, CallView{
			ID: r.ID, Source: r.Source, Role: r.Role, Provider: r.Provider, Model: r.Model,
			InputTokens: r.InputTokens, OutputTokens: r.OutputTokens, CachedTokens: r.CachedTokens,
			LatencyMs: r.LatencyMs, OK: r.Ok == 1, Error: r.Error, Estimated: r.Estimated == 1,
			CreatedAt: r.CreatedAt, DeviceID: r.DeviceID, JobID: r.JobID, QuestionID: r.RefID,
			QuestionStem: r.QuestionStem, BankTitle: r.BankTitle,
		})
	}
	return page, nil
}

// ---- usage reported by the apps ----

const maxUsagePerRequest = 100

// UsageIn is one AI-explanation call as an app reports it. The app picks the id (a ULID), so a report
// that is sent twice, for instance after a lost response, counts once.
type UsageIn struct {
	ID           string `json:"id"`
	QuestionID   string `json:"question_id"`
	DeviceID     string `json:"device_id"`
	Model        string `json:"model"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	CachedTokens int64  `json:"cached_tokens"`
	LatencyMs    int64  `json:"latency_ms"`
	OK           bool   `json:"ok"`
	Error        string `json:"error"`
	// Estimated is true when the endpoint reported no token counts and the app guessed them.
	Estimated bool  `json:"estimated"`
	CreatedAt int64 `json:"created_at"`
}

const (
	maxReportedTokens = 50_000_000
	maxReportedError  = 500
)

// UploadAIUsage records the AI-explanation calls an app made. The access token is the one that guards
// the AI configuration; usage still counts when the feature has been switched off since, so a report
// queued on a phone is not lost.
func (s *Service) UploadAIUsage(ctx context.Context, token string, in []UsageIn) (UploadResult, error) {
	if err := s.checkAppToken(ctx, token); err != nil {
		return UploadResult{}, err
	}
	if len(in) > maxUsagePerRequest {
		return UploadResult{}, invalid("at most %d usage records per request", maxUsagePerRequest)
	}
	latest := time.Now().Add(24 * time.Hour).UnixMilli()
	for i, u := range in {
		switch {
		case u.ID == "" || len(u.ID) > 64:
			return UploadResult{}, invalid("usage %d: id is required and at most 64 characters", i)
		case len(u.Model) > 200 || len(u.QuestionID) > 64 || len(u.DeviceID) > 64:
			return UploadResult{}, invalid("usage %d: a field is too long", i)
		case u.InputTokens < 0 || u.OutputTokens < 0 || u.CachedTokens < 0 ||
			u.InputTokens > maxReportedTokens || u.OutputTokens > maxReportedTokens || u.CachedTokens > maxReportedTokens:
			return UploadResult{}, invalid("usage %d: token counts must be between 0 and %d", i, maxReportedTokens)
		case u.LatencyMs < 0 || u.LatencyMs > 3_600_000:
			return UploadResult{}, invalid("usage %d: latency_ms is out of range", i)
		case u.CreatedAt <= 0 || u.CreatedAt > latest:
			return UploadResult{}, invalid("usage %d: created_at is missing or in the future", i)
		}
	}
	var res UploadResult
	err := s.DB.WithTx(ctx, func(tx *sql.Tx) error {
		q := store.New(tx)
		for _, u := range in {
			msg := ""
			if !u.OK {
				msg = truncateRunes(strings.TrimSpace(u.Error), maxReportedError)
			}
			ok, est := int64(0), int64(0)
			if u.OK {
				ok = 1
			}
			if u.Estimated {
				est = 1
			}
			rows, err := q.InsertClientLLMCall(ctx, store.InsertClientLLMCallParams{
				ID: u.ID, Role: string(llm.RoleExplain), Provider: string(llm.ProtocolOpenAI), Model: u.Model,
				InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, CachedTokens: u.CachedTokens,
				LatencyMs: u.LatencyMs, Ok: ok, Error: msg, CreatedAt: u.CreatedAt,
				DeviceID: u.DeviceID, RefID: u.QuestionID, Estimated: est,
			})
			if err != nil {
				return err
			}
			if rows > 0 {
				res.Accepted++
			} else {
				res.Ignored++
			}
		}
		return nil
	})
	return res, err
}

func truncateRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
