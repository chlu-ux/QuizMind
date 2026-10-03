package jobs_test

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/jobs"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

type rig struct {
	db     *db.DB
	queue  *jobs.Queue
	runner *jobs.Runner
}

func newRig(t *testing.T, concurrency int) *rig {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "app.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	q := jobs.NewQueue(d)
	r := jobs.NewRunner(d, q, concurrency, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	r.PollInterval = 10 * time.Millisecond
	r.BackoffFn = func(int64) time.Duration { return 10 * time.Millisecond }
	return &rig{db: d, queue: q, runner: r}
}

func (g *rig) start(t *testing.T) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { g.runner.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
}

func (g *rig) enqueue(t *testing.T, typ string) string {
	t.Helper()
	var id string
	require.NoError(t, g.db.WithTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		id, err = g.queue.EnqueueTx(context.Background(), store.New(tx), typ, "", map[string]string{})
		return err
	}))
	g.queue.Notify()
	return id
}

func (g *rig) job(t *testing.T, id string) store.Job {
	t.Helper()
	j, err := store.New(g.db.Read).GetJob(context.Background(), id)
	require.NoError(t, err)
	return j
}

func (g *rig) waitStatus(t *testing.T, id, want string) store.Job {
	t.Helper()
	require.Eventually(t, func() bool { return g.job(t, id).Status == want }, 5*time.Second, 5*time.Millisecond)
	return g.job(t, id)
}

func TestRunsJobToCompletion(t *testing.T) {
	g := newRig(t, 1)
	var ran atomic.Int32
	g.runner.Register("ok", func(context.Context, store.Job) error { ran.Add(1); return nil })
	var after atomic.Int32
	g.runner.AfterJob = func(context.Context, store.Job) { after.Add(1) }
	g.start(t)

	id := g.enqueue(t, "ok")
	j := g.waitStatus(t, id, "done")
	assert.EqualValues(t, 1, j.Attempts)
	assert.EqualValues(t, 1, ran.Load())
	assert.Eventually(t, func() bool { return after.Load() == 1 }, time.Second, 5*time.Millisecond)
}

func TestRetriesThenSucceeds(t *testing.T) {
	g := newRig(t, 1)
	var n atomic.Int32
	g.runner.Register("flaky", func(context.Context, store.Job) error {
		if n.Add(1) < 3 {
			return errors.New("temporary")
		}
		return nil
	})
	g.start(t)
	id := g.enqueue(t, "flaky")
	j := g.waitStatus(t, id, "done")
	assert.EqualValues(t, 3, j.Attempts)
}

func TestFailsAfterMaxAttempts(t *testing.T) {
	g := newRig(t, 1)
	var after atomic.Int32
	g.runner.AfterJob = func(context.Context, store.Job) { after.Add(1) }
	g.runner.Register("bad", func(context.Context, store.Job) error { return errors.New("always broken") })
	g.start(t)
	id := g.enqueue(t, "bad")
	j := g.waitStatus(t, id, "failed")
	assert.EqualValues(t, 3, j.Attempts)
	assert.Contains(t, j.LastError, "always broken")
	assert.Eventually(t, func() bool { return after.Load() == 1 }, time.Second, 5*time.Millisecond,
		"AfterJob fires once, on the terminal failure only")
}

func TestPermanentErrorSkipsRetries(t *testing.T) {
	g := newRig(t, 1)
	g.runner.Register("perm", func(context.Context, store.Job) error { return jobs.Permanent(errors.New("nope")) })
	g.start(t)
	id := g.enqueue(t, "perm")
	j := g.waitStatus(t, id, "failed")
	assert.EqualValues(t, 1, j.Attempts)
}

func TestDeferDoesNotChargeAttempts(t *testing.T) {
	g := newRig(t, 1)
	var n atomic.Int32
	g.runner.Register("deferred", func(context.Context, store.Job) error {
		if n.Add(1) <= 5 { // more deferrals than max_attempts
			return jobs.Defer(errors.New("budget spent"), 5*time.Millisecond)
		}
		return nil
	})
	g.start(t)
	id := g.enqueue(t, "deferred")
	j := g.waitStatus(t, id, "done")
	assert.EqualValues(t, 1, j.Attempts, "deferrals were free")
}

func TestUnknownTypeAndPanicFailPermanently(t *testing.T) {
	g := newRig(t, 1)
	g.runner.Register("boom", func(context.Context, store.Job) error { panic("kaboom") })
	g.start(t)
	a := g.enqueue(t, "no-such-type")
	b := g.enqueue(t, "boom")
	assert.Contains(t, g.waitStatus(t, a, "failed").LastError, "no handler")
	assert.Contains(t, g.waitStatus(t, b, "failed").LastError, "kaboom")
}

func TestRecoversJobsLeftRunningByCrashedProcess(t *testing.T) {
	g := newRig(t, 1)
	id := g.enqueue(t, "ok")
	// Simulate a crash: the job was claimed, its lease expired, nobody finished it.
	past := time.Now().Add(-time.Hour).UnixMilli()
	_, err := g.db.Write.Exec(`UPDATE job SET status='running', attempts=1, lease_until=? WHERE id=?`, past, id)
	require.NoError(t, err)

	var ran atomic.Int32
	g.runner.Register("ok", func(context.Context, store.Job) error { ran.Add(1); return nil })
	g.start(t)
	g.waitStatus(t, id, "done")
	assert.EqualValues(t, 1, ran.Load())
}

func TestEachJobRunsExactlyOnceUnderConcurrency(t *testing.T) {
	g := newRig(t, 4)
	var ran atomic.Int32
	g.runner.Register("count", func(context.Context, store.Job) error { ran.Add(1); time.Sleep(2 * time.Millisecond); return nil })
	const n = 40
	ids := make([]string, n)
	for i := range ids {
		ids[i] = g.enqueue(t, "count")
	}
	g.start(t)
	for _, id := range ids {
		g.waitStatus(t, id, "done")
	}
	assert.EqualValues(t, n, ran.Load(), "no job claimed twice")
}

func TestShutdownMidJobHandsItBack(t *testing.T) {
	g := newRig(t, 1)
	started := make(chan struct{})
	g.runner.Register("slow", func(ctx context.Context, _ store.Job) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { g.runner.Run(ctx); close(done) }()

	id := g.enqueue(t, "slow")
	<-started
	cancel()
	<-done
	j := g.job(t, id)
	assert.Equal(t, "pending", j.Status, "interrupted job is requeued, not failed")
	assert.EqualValues(t, 0, j.Attempts, "and the interruption is not charged as an attempt")
}
