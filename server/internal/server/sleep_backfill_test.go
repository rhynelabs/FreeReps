package server

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"
)

type recordedRun struct {
	userID   int
	from, to time.Time
}

// blockingBackfill is a run function whose first call blocks until released,
// so a test can pile requests up behind it.
type blockingBackfill struct {
	mu      sync.Mutex
	runs    []recordedRun
	started chan struct{}
	release chan struct{}
	err     error
}

func (b *blockingBackfill) run(_ context.Context, userID int, from, to time.Time) error {
	b.mu.Lock()
	b.runs = append(b.runs, recordedRun{userID, from, to})
	first := len(b.runs) == 1
	b.mu.Unlock()
	if first {
		close(b.started)
		<-b.release
	}
	return b.err
}

func (b *blockingBackfill) recorded() []recordedRun {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]recordedRun(nil), b.runs...)
}

func newBlockingRunner(t *testing.T) (*sleepBackfillRunner, *blockingBackfill) {
	t.Helper()
	b := &blockingBackfill{started: make(chan struct{}), release: make(chan struct{})}
	r := &sleepBackfillRunner{
		run:     b.run,
		log:     slog.New(slog.DiscardHandler),
		timeout: time.Second,
	}
	return r, b
}

func at(hour int) time.Time {
	return time.Date(2026, 9, 14, hour, 0, 0, 0, time.UTC)
}

// TestSleepBackfillCoalescesRequestsWhileRunning exists because the backfill
// left the request path: a history upload sends many sleep batches for one
// user in quick succession, and without the guard each would start its own
// run over the same nights. Three requests arriving during one run must end
// in exactly one follow-up run whose span covers all three.
func TestSleepBackfillCoalescesRequestsWhileRunning(t *testing.T) {
	r, b := newBlockingRunner(t)

	r.Request(1, at(1), at(2))
	<-b.started

	r.Request(1, at(5), at(6))
	r.Request(1, at(0), at(1))
	r.Request(1, at(7), at(8))

	close(b.release)
	r.wg.Wait()

	runs := b.recorded()
	if len(runs) != 2 {
		t.Fatalf("runs = %d, want 2 (the active one and a single merged follow-up): %v", len(runs), runs)
	}
	if !runs[1].from.Equal(at(0)) || !runs[1].to.Equal(at(8)) {
		t.Errorf("follow-up span = [%v, %v], want [%v, %v]", runs[1].from, runs[1].to, at(0), at(8))
	}

	r.mu.Lock()
	_, stillActive := r.active[1]
	r.mu.Unlock()
	if stillActive {
		t.Error("user still marked active after the queue drained")
	}
}

// TestSleepBackfillSerializesPerUserOnly exists so the guard is not mistaken
// for a global lock: a run for one user must not hold up another user's.
func TestSleepBackfillSerializesPerUserOnly(t *testing.T) {
	r, b := newBlockingRunner(t)

	r.Request(1, at(1), at(2))
	<-b.started
	r.Request(2, at(3), at(4))

	// User 2's run does not wait for user 1's release.
	deadline := time.After(2 * time.Second)
	for {
		runs := b.recorded()
		if len(runs) == 2 && runs[1].userID == 2 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("user 2's run did not start while user 1's was blocked: %v", runs)
		case <-time.After(5 * time.Millisecond):
		}
	}

	close(b.release)
	r.wg.Wait()
}

// TestSleepBackfillRequestAfterDrainStartsFresh exists because the active
// entry is removed under the same lock that reads the queue; a request that
// arrives after the drain must start a new run rather than be lost.
func TestSleepBackfillRequestAfterDrainStartsFresh(t *testing.T) {
	r, b := newBlockingRunner(t)
	b.err = errors.New("boom") // a failing run must not wedge the user either

	r.Request(1, at(1), at(2))
	close(b.release)
	r.wg.Wait()

	r.Request(1, at(3), at(4))
	r.wg.Wait()

	if runs := b.recorded(); len(runs) != 2 {
		t.Fatalf("runs = %d, want 2: %v", len(runs), runs)
	}
}
