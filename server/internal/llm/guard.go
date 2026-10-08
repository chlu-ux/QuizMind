package llm

import (
	"context"
	"fmt"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// CallRecord is one logged model call.
type CallRecord struct {
	JobID string
	// RefID is what the call was for (an assistant conversation); DeviceID is who asked.
	RefID      string
	DeviceID   string
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
	mu  sync.RWMutex
	sem chan struct{}
	lim *rate.Limiter
	max int64
	rec Recorder
	now func() time.Time
}

func NewGuard(l Limits, rec Recorder) *Guard {
	g := &Guard{rec: rec, now: time.Now}
	g.SetLimits(l)
	return g
}

// SetLimits changes the limits for calls that start from now on. A call already in flight finishes
// under the limits it started with.
func (g *Guard) SetLimits(l Limits) {
	if l.MaxConcurrency < 1 {
		l.MaxConcurrency = 1
	}
	rps := rate.Inf
	if l.RPS > 0 {
		rps = rate.Limit(l.RPS)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.sem = make(chan struct{}, l.MaxConcurrency)
	g.lim = rate.NewLimiter(rps, l.MaxConcurrency)
	g.max = l.DailyTokenBudget
}

func (g *Guard) snapshot() (sem chan struct{}, lim *rate.Limiter, max int64) {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.sem, g.lim, g.max
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

// admit checks the daily budget, then waits for the rate limiter and a concurrency slot. The
// returned function frees the slot.
func (g *Guard) admit(ctx context.Context) (release func(), err error) {
	sem, lim, max := g.snapshot()
	if max > 0 {
		day := g.now()
		start := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, day.Location())
		used, err := g.rec.TokensSince(ctx, start)
		if err != nil {
			return nil, fmt.Errorf("check token budget: %w", err)
		}
		if used >= max {
			return nil, ErrBudgetExceeded
		}
	}
	if err := lim.Wait(ctx); err != nil {
		return nil, err
	}
	select {
	case sem <- struct{}{}:
		return func() { <-sem }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// record logs one finished call with a detached context, so a cancelled request still records its cost.
func (g *Guard) record(ctx context.Context, role Role, inner interface {
	Name() string
	Model() string
}, started time.Time, usage Usage, err error) {
	jobID, _ := ctx.Value(jobIDKey{}).(string)
	r := refFrom(ctx)
	logCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	_ = g.rec.Record(logCtx, CallRecord{
		JobID:      jobID,
		RefID:      r.refID,
		DeviceID:   r.deviceID,
		Role:       role,
		Provider:   inner.Name(),
		Model:      inner.Model(),
		Usage:      usage,
		LatencyMs:  g.now().Sub(started).Milliseconds(),
		Err:        err,
		OccurredAt: started,
	})
}

func (c *guarded) GenerateJSON(ctx context.Context, req JSONRequest, out any) (Usage, error) {
	release, err := c.g.admit(ctx)
	if err != nil {
		return Usage{}, err
	}
	defer release()
	started := c.g.now()
	usage, err := c.inner.GenerateJSON(ctx, req, out)
	c.g.record(ctx, c.role, c.inner, started, usage, err)
	return usage, err
}

// WrapConverser returns a Converser that enforces the guard's limits for the given role. Each call
// to Converse is one admission: a conversation holds a slot only while the model is answering, not
// while the caller runs tools between turns, so a long chat cannot starve the pipeline.
func (g *Guard) WrapConverser(role Role, c Converser) Converser {
	return &guardedConverser{g: g, role: role, inner: c}
}

type guardedConverser struct {
	g     *Guard
	role  Role
	inner Converser
}

func (c *guardedConverser) Name() string  { return c.inner.Name() }
func (c *guardedConverser) Model() string { return c.inner.Model() }

func (c *guardedConverser) Converse(ctx context.Context, req ChatRequest, emit func(StreamEvent)) (ChatTurn, Usage, error) {
	release, err := c.g.admit(ctx)
	if err != nil {
		return ChatTurn{}, Usage{}, err
	}
	defer release()
	started := c.g.now()
	turn, usage, err := c.inner.Converse(ctx, req, emit)
	c.g.record(ctx, c.role, c.inner, started, usage, err)
	return turn, usage, err
}
