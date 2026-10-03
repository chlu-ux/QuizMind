// Package jobs is a durable job queue backed by the SQLite job table, plus a
// worker pool. Jobs survive restarts: a job whose lease expired while running
// (process crash) is returned to the queue on the next start.
package jobs

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/chlu-ux/quizmind/server/internal/db"
	"github.com/chlu-ux/quizmind/server/internal/events"
	"github.com/chlu-ux/quizmind/server/internal/ids"
	"github.com/chlu-ux/quizmind/server/internal/store"
)

const (
	defaultMaxAttempts = 3
	leaseDuration      = 10 * time.Minute
	pollInterval       = time.Second
	baseBackoff        = 30 * time.Second
	maxBackoff         = 10 * time.Minute
)

// Handler processes one job. Return nil on success. Wrap the error with
// Permanent to fail without retrying, or Defer to retry later without using up
// an attempt.
type Handler func(ctx context.Context, job store.Job) error

type permanentError struct{ err error }

func (e permanentError) Error() string { return e.err.Error() }
func (e permanentError) Unwrap() error { return e.err }

// Permanent marks err as not worth retrying.
func Permanent(err error) error { return permanentError{err} }

type deferError struct {
	err   error
	delay time.Duration
}

func (e deferError) Error() string { return e.err.Error() }
func (e deferError) Unwrap() error { return e.err }

// Defer asks the runner to retry the job after delay without charging an attempt.
func Defer(err error, delay time.Duration) error { return deferError{err, delay} }

// Queue enqueues jobs and wakes workers.
type Queue struct {
	db   *db.DB
	wake chan struct{}
}

func NewQueue(d *db.DB) *Queue { return &Queue{db: d, wake: make(chan struct{}, 1)} }

// EnqueueTx inserts a job using qs, which may be bound to the caller's
// transaction so that "create document" and "enqueue chunking" commit together.
// Call Notify after the transaction commits.
func (q *Queue) EnqueueTx(ctx context.Context, qs *store.Queries, typ, documentID string, payload any) (string, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	now := time.Now().UnixMilli()
	id := ids.New()
	err = qs.InsertJob(ctx, store.InsertJobParams{
		ID: id, Type: typ, DocumentID: documentID, Payload: string(raw),
		MaxAttempts: defaultMaxAttempts, RunAt: now, CreatedAt: now, UpdatedAt: now,
	})
	return id, err
}

// Notify wakes idle workers so a new job starts without waiting for the poll.
func (q *Queue) Notify() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

// Runner executes jobs with a fixed number of workers.
type Runner struct {
	db          *db.DB
	queue       *Queue
	handlers    map[string]Handler
	concurrency int
	log         *slog.Logger
	hub         *events.Hub
	// AfterJob runs after a job reaches done or failed (not on retry).
	AfterJob func(ctx context.Context, job store.Job)
	// PollInterval and BackoffFn default to production values; tests shorten them.
	PollInterval time.Duration
	BackoffFn    func(attempt int64) time.Duration
	now          func() time.Time
}

func NewRunner(d *db.DB, q *Queue, concurrency int, log *slog.Logger, hub *events.Hub) *Runner {
	return &Runner{
		db: d, queue: q, handlers: map[string]Handler{}, concurrency: concurrency,
		log: log, hub: hub, now: time.Now, PollInterval: pollInterval, BackoffFn: backoff,
	}
}

func (r *Runner) Register(typ string, h Handler) { r.handlers[typ] = h }

// Run blocks until ctx is cancelled, then waits for in-flight jobs to finish.
func (r *Runner) Run(ctx context.Context) {
	qs := store.New(r.db.Write)
	if n, err := qs.RecoverExpiredJobs(ctx, r.now().UnixMilli()); err != nil {
		r.log.Error("recover expired jobs", "err", err)
	} else if n > 0 {
		r.log.Warn("recovered jobs left running by a previous process", "count", n)
	}

	var wg sync.WaitGroup
	for i := 0; i < r.concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.worker(ctx)
		}()
	}
	wg.Wait()
}

func (r *Runner) worker(ctx context.Context) {
	for {
		job, ok := r.claim(ctx)
		if ok {
			r.execute(ctx, job)
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-r.queue.wake:
		case <-time.After(r.PollInterval):
		}
	}
}

func (r *Runner) claim(ctx context.Context) (store.Job, bool) {
	if ctx.Err() != nil {
		return store.Job{}, false
	}
	now := r.now()
	job, err := store.New(r.db.Write).ClaimJob(ctx, store.ClaimJobParams{
		LeaseUntil: sql.NullInt64{Int64: now.Add(leaseDuration).UnixMilli(), Valid: true},
		Now:        now.UnixMilli(),
	})
	if errors.Is(err, sql.ErrNoRows) {
		return store.Job{}, false
	}
	if err != nil {
		r.log.Error("claim job", "err", err)
		return store.Job{}, false
	}
	r.publish(job, "running", "")
	return job, true
}

func (r *Runner) execute(ctx context.Context, job store.Job) {
	h, ok := r.handlers[job.Type]
	if !ok {
		r.finish(ctx, job, Permanent(fmt.Errorf("no handler for job type %q", job.Type)))
		return
	}
	err := safeCall(ctx, h, job)
	r.finish(ctx, job, err)
}

func safeCall(ctx context.Context, h Handler, job store.Job) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = Permanent(fmt.Errorf("panic in job handler: %v", p))
		}
	}()
	return h(ctx, job)
}

func (r *Runner) finish(ctx context.Context, job store.Job, err error) {
	// Persist the outcome even if the server is shutting down.
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	qs := store.New(r.db.Write)
	now := r.now()

	var perm permanentError
	var def deferError
	switch {
	case err == nil:
		if e := qs.CompleteJob(wctx, store.CompleteJobParams{UpdatedAt: now.UnixMilli(), ID: job.ID}); e != nil {
			r.log.Error("complete job", "job", job.ID, "err", e)
		}
		r.publish(job, "done", "")
		r.after(wctx, job)

	case ctx.Err() != nil && errors.Is(err, ctx.Err()):
		// Shutting down mid-job: hand it back untouched for the next start.
		_ = qs.DeferJob(wctx, store.DeferJobParams{RunAt: now.UnixMilli(), LastError: "interrupted by shutdown", UpdatedAt: now.UnixMilli(), ID: job.ID})

	case errors.As(err, &def):
		r.log.Warn("job deferred", "job", job.ID, "type", job.Type, "delay", def.delay, "reason", def.err)
		_ = qs.DeferJob(wctx, store.DeferJobParams{
			RunAt: now.Add(def.delay).UnixMilli(), LastError: def.err.Error(), UpdatedAt: now.UnixMilli(), ID: job.ID,
		})
		r.publish(job, "pending", def.err.Error())

	case errors.As(err, &perm) || job.Attempts >= job.MaxAttempts:
		r.log.Error("job failed", "job", job.ID, "type", job.Type, "attempts", job.Attempts, "err", err)
		_ = qs.FailJob(wctx, store.FailJobParams{LastError: err.Error(), UpdatedAt: now.UnixMilli(), ID: job.ID})
		r.publish(job, "failed", err.Error())
		r.after(wctx, job)

	default:
		delay := r.BackoffFn(job.Attempts)
		r.log.Warn("job failed, will retry", "job", job.ID, "type", job.Type, "attempt", job.Attempts, "retry_in", delay, "err", err)
		_ = qs.RescheduleJob(wctx, store.RescheduleJobParams{
			RunAt: now.Add(delay).UnixMilli(), LastError: err.Error(), UpdatedAt: now.UnixMilli(), ID: job.ID,
		})
		r.publish(job, "pending", err.Error())
	}
}

func (r *Runner) after(ctx context.Context, job store.Job) {
	if r.AfterJob != nil {
		r.AfterJob(ctx, job)
	}
}

func (r *Runner) publish(job store.Job, status, errMsg string) {
	if r.hub == nil {
		return
	}
	r.hub.Publish(events.Event{Type: "job", ID: job.ID, DocumentID: job.DocumentID, Status: status, Kind: job.Type, Error: errMsg})
}

func backoff(attempt int64) time.Duration {
	d := baseBackoff
	for i := int64(1); i < attempt && d < maxBackoff; i++ {
		d *= 2
	}
	return min(d, maxBackoff)
}
