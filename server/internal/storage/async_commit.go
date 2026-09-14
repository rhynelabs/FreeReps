package storage

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
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
// fn must have consumed and closed any result set before it returns; Commit
// on a connection with a row stream still open fails.
func (db *DB) withAsyncCommit(ctx context.Context, fn func(tx pgx.Tx) error) error {
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
