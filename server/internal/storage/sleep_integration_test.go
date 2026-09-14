//go:build integration

package storage

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
)

func sleepIntegrationDB(t *testing.T) *DB {
	t.Helper()
	dsn := os.Getenv("FREEREPS_TEST_DSN")
	if dsn == "" {
		t.Skip("FREEREPS_TEST_DSN not set")
	}

	migrations, err := filepath.Abs("../../migrations")
	if err != nil {
		t.Fatalf("resolving migrations path: %v", err)
	}
	if err := RunMigrations(dsn, migrations); err != nil {
		t.Fatalf("running migrations: %v", err)
	}

	ctx := context.Background()
	db, err := New(ctx, dsn)
	if err != nil {
		t.Fatalf("connecting: %v", err)
	}
	t.Cleanup(db.Close)

	var dbName string
	if err := db.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&dbName); err != nil {
		t.Fatalf("reading database name: %v", err)
	}
	if dbName == "freereps" {
		t.Fatalf("refusing to truncate the database named %q", dbName)
	}
	if _, err := db.Pool.Exec(ctx, `TRUNCATE sleep_sessions, health_metrics`); err != nil {
		t.Fatalf("truncating sleep tables: %v", err)
	}
	return db
}

// TestBackfillSessionsAreAtomicAndIdempotent exists because the old backfill
// committed every session and its metric separately. A restart could leave a
// session without its metric, and a multi-year history required thousands of
// commits before the server opened its listener.
func TestBackfillSessionsAreAtomicAndIdempotent(t *testing.T) {
	db := sleepIntegrationDB(t)
	ctx := context.Background()
	userID := 987654
	nights := make([][]models.SleepStageRow, maxBackfillSessionsPerBatch+1)
	base := time.Date(2020, 1, 1, 23, 0, 0, 0, time.UTC)
	for i := range nights {
		start := base.AddDate(0, 0, i)
		nights[i] = []models.SleepStageRow{{
			StartTime: start, EndTime: start.Add(7 * time.Hour),
			Stage: "Core", DurationHr: 7,
		}}
	}

	direct := nightSession(userID, nights[0])
	direct.TotalSleep = 99
	if err := db.InsertSleepSession(ctx, direct); err != nil {
		t.Fatalf("inserting direct session: %v", err)
	}

	created, err := db.insertBackfillSessions(ctx, userID, nights)
	if err != nil {
		t.Fatalf("backfilling sessions: %v", err)
	}
	if created != maxBackfillSessionsPerBatch {
		t.Fatalf("created %d sessions, want %d", created, maxBackfillSessionsPerBatch)
	}

	var sessions, metrics int
	if err := db.Pool.QueryRow(ctx,
		`SELECT (SELECT count(*) FROM sleep_sessions WHERE user_id = $1),
		        (SELECT count(*) FROM health_metrics WHERE user_id = $1 AND source = 'FreeReps Backfill')`,
		userID).Scan(&sessions, &metrics); err != nil {
		t.Fatalf("counting backfill rows: %v", err)
	}
	if sessions != len(nights) || metrics != maxBackfillSessionsPerBatch {
		t.Fatalf("got %d sessions and %d metrics, want %d and %d",
			sessions, metrics, len(nights), maxBackfillSessionsPerBatch)
	}

	var directTotal float64
	if err := db.Pool.QueryRow(ctx,
		`SELECT total_sleep FROM sleep_sessions WHERE user_id = $1 AND date = $2`,
		userID, direct.Date).Scan(&directTotal); err != nil {
		t.Fatalf("reading direct session: %v", err)
	}
	if directTotal != 99 {
		t.Fatalf("direct session total = %v, want 99", directTotal)
	}

	created, err = db.insertBackfillSessions(ctx, userID, nights)
	if err != nil {
		t.Fatalf("repeating backfill: %v", err)
	}
	if created != 0 {
		t.Fatalf("repeat created %d sessions, want 0", created)
	}
}
