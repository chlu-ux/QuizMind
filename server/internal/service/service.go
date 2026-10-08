// Package service holds the application logic shared by the HTTP API and the
// background job handlers.
package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/config"
	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

var (
	ErrNotFound = errors.New("not found")
	ErrInvalid  = errors.New("invalid request")
)

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

// Job type names.
const (
	JobChunkDocument = "chunk_document"
	JobGenerateChunk = "generate_chunk"
)

type Service struct {
	DB  *db.DB
	Cfg config.Config
	LLM *llm.Registry
	// Guard limits and logs every model call made through LLM; its limits come from the stored
	// model configuration (see ReloadLLM).
	Guard *llm.Guard
	Queue *jobs.Queue
	Hub   *events.Hub
	Log   *slog.Logger

	// agentBusy counts running assistant conversations per device.
	agentMu   sync.Mutex
	agentBusy map[string]int
}

func New(d *db.DB, cfg config.Config, reg *llm.Registry, q *jobs.Queue, hub *events.Hub, log *slog.Logger) *Service {
	return &Service{DB: d, Cfg: cfg, LLM: reg, Guard: llm.NewGuard(defaultLLMLimits().toGuard(), LLMRecorder{DB: d}),
		Queue: q, Hub: hub, Log: log}
}

// RegisterHandlers wires the pipeline job handlers into the runner.
func (s *Service) RegisterHandlers(r *jobs.Runner) {
	r.Register(JobChunkDocument, s.handleChunkDocument)
	r.Register(JobGenerateChunk, s.handleGenerateChunk)
	r.AfterJob = func(ctx context.Context, j store.Job) {
		if j.DocumentID != "" {
			s.refreshDocumentStatus(ctx, j.DocumentID)
		}
	}
}

func nowMs() int64 { return time.Now().UnixMilli() }

func (s *Service) reader() *store.Queries { return store.New(s.DB.Read) }

func notFound(err error, what string) error {
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: %s", ErrNotFound, what)
	}
	return err
}

func jsonArray[T any](v []T) string {
	if v == nil {
		v = []T{}
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// LLMRecorder persists model calls to llm_call_log and reports daily spend.
type LLMRecorder struct{ DB *db.DB }

func (r LLMRecorder) Record(ctx context.Context, rec llm.CallRecord) error {
	ok := int64(1)
	msg := ""
	if rec.Err != nil {
		ok, msg = 0, rec.Err.Error()
	}
	return store.New(r.DB.Write).InsertLLMCall(ctx, store.InsertLLMCallParams{
		ID: newID(), JobID: rec.JobID, Role: string(rec.Role), Provider: rec.Provider, Model: rec.Model,
		InputTokens: rec.Usage.InputTokens, OutputTokens: rec.Usage.OutputTokens, CachedTokens: rec.Usage.CachedTokens,
		LatencyMs: rec.LatencyMs, Ok: ok, Error: msg, CreatedAt: rec.OccurredAt.UnixMilli(), Source: SourceServer,
		DeviceID: rec.DeviceID, RefID: rec.RefID,
	})
}

func (r LLMRecorder) TokensSince(ctx context.Context, t time.Time) (int64, error) {
	return store.New(r.DB.Read).SumTokensSince(ctx, t.UnixMilli())
}
