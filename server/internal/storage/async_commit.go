package storage

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// withAsyncCommit runs fn inside a transaction whose commit returns before the
// WAL record reaches disk.
//
// This is for the ingest batch writes and nothing else. Every row the app
// sends can be sent again: the app keeps anchors and cursors per category, and
// the server dedupes on a unique index, so a crash that loses the last few
// hundred milliseconds of commits loses nothing that the next sync does not
// restore. What the fsync per commit costs is the whole point — on the NAS
// storage the deployed database runs on, a 5,000-row batch took 650 ms alone
// and three seconds with twenty batches in flight, while throughput stayed
// flat; the disk, not the CPU, was serialising the commits. Durability is not
// weakened for anything else: the setting is SET LOCAL, so it ends with the
// transaction and the connection goes back to the pool synchronous.
//
// The setting is issued through tx.Exec, which runs on the connection the
// transaction was begun on, so it applies to this commit and no other.
//
// The same property — every write here can be repeated — is what lets a
// transaction Postgres aborted as the loser of a deadlock be run again from
// the start (retryTx). fn is therefore called up to txAttempts times and must
// not carry state from one call into the next.
//
// fn must have consumed and closed any result set before it returns; Commit
// on a connection with a row stream still open fails.
func (db *DB) withAsyncCommit(ctx context.Context, fn func(tx pgx.Tx) error) error {
	return retryTx(ctx, txRetryPause, func() error { return db.runAsyncCommit(ctx, fn) })
}

func (db *DB) runAsyncCommit(ctx context.Context, fn func(tx pgx.Tx) error) error {
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	// A no-op after Commit; the error it returns then (ErrTxClosed) is not
	// worth a branch.
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, "SET LOCAL synchronous_commit = off"); err != nil {
		return fmt.Errorf("setting synchronous_commit: %w", err)
	}
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("committing: %w", err)
	}
	return nil
}

// Retry policy for a transaction Postgres aborted to break a lock cycle.
const (
	txAttempts   = 3
	txRetryPause = 50 * time.Millisecond
)

// retryTx runs attempt up to txAttempts times, again after a deadlock (40P01)
// or a serialization failure (40001). Both mean Postgres rolled this
// transaction back so that another could finish, and the other has finished
// by the time the rerun begins, so the same statements usually go through
// unopposed. The pause before a rerun is uniform in [pause, 4·pause] and
// doubles per attempt, so that transactions that deadlocked together do not
// return in step. Returns the last error when the attempts are used up or
// ctx ends during a pause.
func retryTx(ctx context.Context, pause time.Duration, attempt func() error) error {
	for n := 1; ; n++ {
		err := attempt()
		if err == nil || n == txAttempts || !isRetryableTxError(err) {
			return err
		}
		wait := (pause + rand.N(3*pause+1)) << (n - 1)
		select {
		case <-ctx.Done():
			return err
		case <-time.After(wait):
		}
	}
}

// isRetryableTxError reports whether err is a Postgres error that a fresh run
// of the same transaction can be expected to clear.
func isRetryableTxError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return pgErr.Code == "40P01" || pgErr.Code == "40001"
}
