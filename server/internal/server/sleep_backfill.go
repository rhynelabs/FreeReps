package server

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// sleepBackfillTimeout bounds one scoped backfill run. The run reads a
// padded window of stages and writes a handful of sessions; a run that
// takes longer than this is stuck on the database, not busy.
const sleepBackfillTimeout = 30 * time.Second

// sleepBackfillRunner runs the scoped sleep session backfill off the request
// path, at most once per user at a time.
//
// The ingest response does not depend on the backfill: nothing in the result
// reports what it built, and the stages it reads are committed before it
// starts. Awaiting it made a batch with sleep rows take 400–2,400 ms where
// the same-size batch without took 85 ms. Running it detached without a
// guard would let a history upload — many sleep batches in flight for one
// user — start one backfill per batch, all regrouping the same nights. So a
// request that arrives while the user's run is active widens the span of one
// follow-up run instead: N overlapping requests end in at most two runs.
type sleepBackfillRunner struct {
	run     func(ctx context.Context, userID int, from, to time.Time) error
	log     *slog.Logger
	timeout time.Duration

	mu sync.Mutex
	// active holds every user with a run in progress. The value is the
	// span queued for the follow-up run, nil when nothing is queued.
	active map[int]*timeSpan
	// wg lets a test wait for the detached runs; the server does not.
	wg sync.WaitGroup
}

type timeSpan struct{ from, to time.Time }

func (s *timeSpan) widen(from, to time.Time) {
	if from.Before(s.from) {
		s.from = from
	}
	if to.After(s.to) {
		s.to = to
	}
}

// Request asks for a backfill of the user's nights overlapping [from, to]
// and returns at once. The run starts now if the user has none active, and
// is merged into the follow-up run otherwise.
func (r *sleepBackfillRunner) Request(userID int, from, to time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active == nil {
		r.active = map[int]*timeSpan{}
	}
	if queued, running := r.active[userID]; running {
		if queued == nil {
			r.active[userID] = &timeSpan{from: from, to: to}
		} else {
			queued.widen(from, to)
		}
		return
	}
	r.active[userID] = nil
	r.wg.Add(1)
	go r.loop(userID, timeSpan{from: from, to: to})
}

// loop runs the span it was started with, then whatever was queued while it
// ran, until nothing is queued. The user's active entry is removed under the
// same lock that checks the queue, so a Request cannot slip between the
// check and the exit.
func (r *sleepBackfillRunner) loop(userID int, span timeSpan) {
	defer r.wg.Done()
	for {
		r.runOne(userID, span)

		r.mu.Lock()
		next := r.active[userID]
		if next == nil {
			delete(r.active, userID)
			r.mu.Unlock()
			return
		}
		r.active[userID] = nil
		r.mu.Unlock()
		span = *next
	}
}

func (r *sleepBackfillRunner) runOne(userID int, span timeSpan) {
	// A background context, not the request's: the request is answered by
	// now, and a follow-up run merges spans from several requests anyway.
	ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
	defer cancel()
	if err := r.run(ctx, userID, span.from, span.to); err != nil {
		r.log.Warn("sleep session backfill after REST ingest failed",
			"user_id", userID, "from", span.from, "to", span.to, "error", err)
	}
}
