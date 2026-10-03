package llm

import (
	"context"
	"fmt"
	"time"

	"golang.org/x/time/rate"
)

// CallRecord is one logged model call.
type CallRecord struct {
	JobID      string
	Role       Role
	Provider   string
	Model      string
	Usage      Usage
	LatencyMs  int64
	Err        error
	OccurredAt time.Time
}

// Recorder persists call logs and reports spend. Implemented by the service
// layer on top of the database.
type Recorder interface {
	Record(ctx context.Context, rec CallRecord) error
	// TokensSince returns total input+output tokens recorded at or after t.
	TokensSince(ctx context.Context, t time.Time) (int64, error)
}

type Limits struct {
	MaxConcurrency   int
	RPS              float64
	DailyTokenBudget int64 // 0 = unlimited
}

// Guard wraps a Client with a shared concurrency cap, rate limiter, daily token
// budget, and call logging. One Guard is shared by every role so limits apply
// to the whole process.
type Guard struct {
	sem chan struct{}
	lim *rate.Limiter
	rec Recorder
	max int64
	now func() time.Time
}

func NewGuard(l Limits, rec Recorder) *Guard {
	if l.MaxConcurrency < 1 {
		l.MaxConcurrency = 1
	}
	rps := rate.Inf
	if l.RPS > 0 {
		rps = rate.Limit(l.RPS)
	}
	burst := l.MaxConcurrency
	return &Guard{
		sem: make(chan struct{}, l.MaxConcurrency),
		lim: rate.NewLimiter(rps, burst),
		rec: rec,
		max: l.DailyTokenBudget,
		now: time.Now,
	}
}

// Wrap returns a Client that enforces the guard's limits for the given role.
func (g *Guard) Wrap(role Role, c Client) Client {
	return &guarded{g: g, role: role, inner: c}
}

type guarded struct {
	g     *Guard
	role  Role
	inner Client
}

func (c *guarded) Name() string  { return c.inner.Name() }
func (c *guarded) Model() string { return c.inner.Model() }

type jobIDKey struct{}

// WithJobID tags the context so call logs can be tied back to a job.
func WithJobID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, jobIDKey{}, id)
}

func (c *guarded) GenerateJSON(ctx context.Context, req JSONRequest, out any) (Usage, error) {
	g := c.g
	if g.max > 0 {
		day := g.now()
		start := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, day.Location())
		used, err := g.rec.TokensSince(ctx, start)
		if err != nil {
			return Usage{}, fmt.Errorf("check token budget: %w", err)
		}
		if used >= g.max {
			return Usage{}, ErrBudgetExceeded
		}
	}
	if err := g.lim.Wait(ctx); err != nil {
		return Usage{}, err
	}
	select {
	case g.sem <- struct{}{}:
		defer func() { <-g.sem }()
	case <-ctx.Done():
		return Usage{}, ctx.Err()
	}

	started := g.now()
	usage, err := c.inner.GenerateJSON(ctx, req, out)
	jobID, _ := ctx.Value(jobIDKey{}).(string)
	// Log with a detached context so a cancelled request still records its cost.
	logCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	_ = g.rec.Record(logCtx, CallRecord{
		JobID:      jobID,
		Role:       c.role,
		Provider:   c.inner.Name(),
		Model:      c.inner.Model(),
		Usage:      usage,
		LatencyMs:  g.now().Sub(started).Milliseconds(),
		Err:        err,
		OccurredAt: started,
	})
	return usage, err
}
