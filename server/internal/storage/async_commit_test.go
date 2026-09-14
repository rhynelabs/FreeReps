package storage

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestRetryTxRerunsAfterDeadlock exists because the deadlock of 2026-09-14
// (INCIDENTS.md) cost the losing request its whole window: the transaction
// can be run again on the spot, but only for the two codes that mean the
// other side has finished, a bounded number of times, and not once the
// request is gone.
func TestRetryTxRerunsAfterDeadlock(t *testing.T) {
	deadlock := fmt.Errorf("inserting workout routes: %w", &pgconn.PgError{Code: "40P01"})
	serialization := &pgconn.PgError{Code: "40001"}
	unique := &pgconn.PgError{Code: "23505"}

	// failing returns an attempt that fails n times with err, then succeeds.
	failing := func(n int, err error) (func() error, *int) {
		calls := 0
		return func() error {
			calls++
			if calls <= n {
				return err
			}
			return nil
		}, &calls
	}

	attempt, calls := failing(2, deadlock)
	if err := retryTx(context.Background(), 0, attempt); err != nil || *calls != 3 {
		t.Errorf("two deadlocks then success: err=%v calls=%d", err, *calls)
	}

	attempt, calls = failing(3, serialization)
	if err := retryTx(context.Background(), 0, attempt); !errors.Is(err, serialization) || *calls != txAttempts {
		t.Errorf("failing every time: err=%v calls=%d, want the last error after %d attempts", err, *calls, txAttempts)
	}

	attempt, calls = failing(2, unique)
	if err := retryTx(context.Background(), 0, attempt); !errors.Is(err, unique) || *calls != 1 {
		t.Errorf("unique violation: err=%v calls=%d, want no rerun", err, *calls)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	attempt, calls = failing(2, deadlock)
	if err := retryTx(ctx, time.Hour, attempt); !errors.Is(err, deadlock) || *calls != 1 {
		t.Errorf("request gone: err=%v calls=%d, want the deadlock back without a rerun", err, *calls)
	}

	if isRetryableTxError(errors.New("connection reset")) {
		t.Error("an error that is not from Postgres must not be retried")
	}
}
