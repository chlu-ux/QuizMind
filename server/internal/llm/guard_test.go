package llm_test

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

type memRecorder struct {
	mu     sync.Mutex
	recs   []llm.CallRecord
	tokens int64
}

func (m *memRecorder) Record(_ context.Context, r llm.CallRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.recs = append(m.recs, r)
	m.tokens += r.Usage.InputTokens + r.Usage.OutputTokens
	return nil
}

func (m *memRecorder) TokensSince(context.Context, time.Time) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.tokens, nil
}

func TestGuard_RecordsCallsIncludingFailures(t *testing.T) {
	rec := &memRecorder{}
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1}, rec)
	ok := g.Wrap(llm.RoleGenerator, fake.New(func(llm.JSONRequest) (any, error) { return map[string]any{}, nil }))
	bad := g.Wrap(llm.RoleValidator, fake.New(func(llm.JSONRequest) (any, error) { return nil, errors.New("boom") }))

	var out map[string]any
	ctx := llm.WithJobID(context.Background(), "job-1")
	_, err := ok.GenerateJSON(ctx, llm.JSONRequest{User: "hello world"}, &out)
	require.NoError(t, err)
	_, err = bad.GenerateJSON(ctx, llm.JSONRequest{}, &out)
	require.Error(t, err)

	require.Len(t, rec.recs, 2)
	assert.Equal(t, llm.RoleGenerator, rec.recs[0].Role)
	assert.Equal(t, "job-1", rec.recs[0].JobID)
	assert.Equal(t, "fake", rec.recs[0].Provider)
	assert.NoError(t, rec.recs[0].Err)
	assert.Equal(t, llm.RoleValidator, rec.recs[1].Role)
	assert.Error(t, rec.recs[1].Err, "failed calls are logged too")
}

func TestGuard_DailyBudgetStopsCalls(t *testing.T) {
	rec := &memRecorder{}
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1, DailyTokenBudget: 100}, rec)
	var calls atomic.Int32
	c := g.Wrap(llm.RoleGenerator, fake.New(func(llm.JSONRequest) (any, error) { calls.Add(1); return map[string]any{}, nil }))

	var out map[string]any
	rec.tokens = 150 // already over budget today
	_, err := c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
	assert.ErrorIs(t, err, llm.ErrBudgetExceeded)
	assert.EqualValues(t, 0, calls.Load(), "the model is not called once the budget is spent")
}

func TestGuard_LimitsConcurrency(t *testing.T) {
	rec := &memRecorder{}
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 2}, rec)
	var inflight, peak atomic.Int32
	c := g.Wrap(llm.RoleGenerator, fake.New(func(llm.JSONRequest) (any, error) {
		n := inflight.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		inflight.Add(-1)
		return map[string]any{}, nil
	}))

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var out map[string]any
			_, err := c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
			assert.NoError(t, err)
		}()
	}
	wg.Wait()
	assert.LessOrEqual(t, peak.Load(), int32(2))
	assert.Len(t, rec.recs, 8)
}

func TestGuard_CancelledContextWhileWaiting(t *testing.T) {
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1}, &memRecorder{})
	release := make(chan struct{})
	c := g.Wrap(llm.RoleGenerator, fake.New(func(llm.JSONRequest) (any, error) { <-release; return map[string]any{}, nil }))

	go func() {
		var out map[string]any
		_, _ = c.GenerateJSON(context.Background(), llm.JSONRequest{}, &out)
	}()
	time.Sleep(30 * time.Millisecond) // let the first call take the only slot

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	var out map[string]any
	_, err := c.GenerateJSON(ctx, llm.JSONRequest{}, &out)
	assert.ErrorIs(t, err, context.DeadlineExceeded)
	close(release)
}

func TestRegistry_MissingRole(t *testing.T) {
	r := llm.NewRegistry()
	_, err := r.For(llm.RoleGenerator)
	assert.Error(t, err)
}
