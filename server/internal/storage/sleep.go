package storage

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/jackc/pgx/v5"
)

// InsertSleepSession upserts a sleep session (one per date per user).
func (db *DB) InsertSleepSession(ctx context.Context, row models.SleepSessionRow) error {
	_, err := db.Pool.Exec(ctx,
		`INSERT INTO sleep_sessions (user_id, date, total_sleep, asleep, core, deep, rem, in_bed, sleep_start, sleep_end, in_bed_start, in_bed_end)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		 ON CONFLICT (user_id, date) DO UPDATE SET
		   total_sleep = EXCLUDED.total_sleep,
		   asleep = EXCLUDED.asleep,
		   core = EXCLUDED.core,
		   deep = EXCLUDED.deep,
		   rem = EXCLUDED.rem,
		   in_bed = EXCLUDED.in_bed,
		   sleep_start = EXCLUDED.sleep_start,
		   sleep_end = EXCLUDED.sleep_end,
		   in_bed_start = EXCLUDED.in_bed_start,
		   in_bed_end = EXCLUDED.in_bed_end`,
		row.UserID, row.Date, row.TotalSleep, row.Asleep, row.Core, row.Deep, row.REM,
		row.InBed, row.SleepStart, row.SleepEnd, row.InBedStart, row.InBedEnd)
	if err != nil {
		return fmt.Errorf("inserting sleep session: %w", err)
	}
	return nil
}

// InsertSleepStages batch-inserts sleep stage rows. Returns count inserted.
func (db *DB) InsertSleepStages(ctx context.Context, rows []models.SleepStageRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}

	query := `INSERT INTO sleep_stages (start_time, end_time, user_id, stage, duration_hr, source) VALUES `
	args := make([]any, 0, len(rows)*6)
	valueStrings := make([]string, 0, len(rows))

	for i, r := range rows {
		base := i * 6
		valueStrings = append(valueStrings, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5, base+6,
		))
		args = append(args, r.StartTime, r.EndTime, r.UserID, r.Stage, r.DurationHr, r.Source)
	}

	query += strings.Join(valueStrings, ",") + " ON CONFLICT DO NOTHING"

	// An ingest write: the app re-sends what a lost commit would drop.
	var inserted int64
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return fmt.Errorf("inserting sleep stages: %w", err)
		}
		inserted = tag.RowsAffected()
		return nil
	})
	return inserted, err
}

// SleepSessionResult is a sleep session with optional stage data.
type SleepSessionResult struct {
	models.SleepSessionRow
	ID int64
}

// QuerySleepSessions retrieves sleep sessions in a date range.
func (db *DB) QuerySleepSessions(ctx context.Context, start, end time.Time, userID int) ([]SleepSessionResult, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT id, user_id, date, total_sleep, asleep, core, deep, rem, in_bed, sleep_start, sleep_end, in_bed_start, in_bed_end
		 FROM sleep_sessions
		 WHERE date >= $1 AND date < $2 AND user_id = $3
		 ORDER BY date DESC`,
		start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying sleep sessions: %w", err)
	}
	defer rows.Close()

	var result []SleepSessionResult
	for rows.Next() {
		var r SleepSessionResult
		if err := rows.Scan(&r.ID, &r.UserID, &r.Date, &r.TotalSleep, &r.Asleep,
			&r.Core, &r.Deep, &r.REM, &r.InBed, &r.SleepStart, &r.SleepEnd,
			&r.InBedStart, &r.InBedEnd); err != nil {
			return nil, fmt.Errorf("scanning sleep session: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}

// QuerySleepStages retrieves individual sleep stages in a time range.
func (db *DB) QuerySleepStages(ctx context.Context, start, end time.Time, userID int) ([]models.SleepStageRow, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT start_time, end_time, user_id, stage, duration_hr, source
		 FROM sleep_stages
		 WHERE start_time >= $1 AND start_time < $2 AND user_id = $3
		 ORDER BY start_time ASC`,
		start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying sleep stages: %w", err)
	}
	defer rows.Close()

	var result []models.SleepStageRow
	for rows.Next() {
		var r models.SleepStageRow
		if err := rows.Scan(&r.StartTime, &r.EndTime, &r.UserID, &r.Stage, &r.DurationHr, &r.Source); err != nil {
			return nil, fmt.Errorf("scanning sleep stage: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}

// SleepStageUserIDs returns distinct user IDs that have sleep stage data.
func (db *DB) SleepStageUserIDs(ctx context.Context) ([]int, error) {
	rows, err := db.Pool.Query(ctx, `SELECT DISTINCT user_id FROM sleep_stages ORDER BY user_id`)
	if err != nil {
		return nil, fmt.Errorf("querying sleep stage user IDs: %w", err)
	}
	defer rows.Close()

	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning user ID: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// BackfillSleepSessions synthesizes sleep sessions from existing sleep stages
// that don't yet have corresponding sessions. Called at server startup and
// after each HAE TCP import. Idempotent (ON CONFLICT DO NOTHING).
//
// It reads every stage of every user. A request that has just written a few
// stages wants BackfillSleepSessionsFor instead.
func (db *DB) BackfillSleepSessions(ctx context.Context, log *slog.Logger) error {
	userIDs, err := db.SleepStageUserIDs(ctx)
	if err != nil {
		return fmt.Errorf("getting user IDs for backfill: %w", err)
	}
	if len(userIDs) == 0 {
		return nil
	}

	var totalCreated int
	for _, userID := range userIDs {
		created, err := db.backfillUserSleepSessions(ctx, log, userID)
		if err != nil {
			return fmt.Errorf("backfilling user %d: %w", userID, err)
		}
		totalCreated += created
	}

	log.Info("sleep session backfill complete", "users", len(userIDs), "sessions_created", totalCreated)
	return nil
}

// backfillNightPad is how far past [from, to] BackfillSleepSessionsFor reads
// so that a night straddling the window edge is grouped whole. A night is a
// chain of stages with gaps under 12 hours; one that reaches three days past
// the stages just written would need a nap every half day for that long.
const backfillNightPad = 3 * 24 * time.Hour

// BackfillSleepSessionsFor is BackfillSleepSessions for one user, limited to
// the nights that overlap [from, to] — the span of the stages a request just
// wrote. Returns the number of sessions created.
//
// Same ON CONFLICT DO NOTHING as the full backfill, for the same reason (see
// the 2026-03-26 incident): a session a direct source wrote is never
// overwritten. That is also why only whole nights are written — a night cut
// at the window edge would become a short session no later run corrects.
func (db *DB) BackfillSleepSessionsFor(ctx context.Context, log *slog.Logger, userID int, from, to time.Time) (int, error) {
	stages, err := db.QuerySleepStages(ctx, from.Add(-backfillNightPad), to.Add(backfillNightPad), userID)
	if err != nil {
		return 0, fmt.Errorf("querying stages: %w", err)
	}

	var created int
	for _, night := range nightsOverlapping(groupNights(stages), from, to) {
		n, err := db.insertBackfillSession(ctx, userID, night)
		if err != nil {
			return created, err
		}
		created += n
	}

	if created > 0 {
		log.Info("backfilled sleep sessions for user", "user_id", userID, "sessions", created, "from", from, "to", to)
	}
	return created, nil
}

func (db *DB) backfillUserSleepSessions(ctx context.Context, log *slog.Logger, userID int) (int, error) {
	stages, err := db.QuerySleepStages(ctx,
		time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC),
		userID)
	if err != nil {
		return 0, fmt.Errorf("querying stages: %w", err)
	}

	var created int
	for _, night := range groupNights(stages) {
		n, err := db.insertBackfillSession(ctx, userID, night)
		if err != nil {
			return created, err
		}
		created += n
	}

	if created > 0 {
		log.Info("backfilled sleep sessions for user", "user_id", userID, "sessions", created)
	}
	return created, nil
}

// groupNights sorts stages by start and splits them into nights: a gap of
// more than 12 hours between one stage's end and the next one's start opens a
// new night.
func groupNights(stages []models.SleepStageRow) [][]models.SleepStageRow {
	if len(stages) == 0 {
		return nil
	}

	sort.Slice(stages, func(i, j int) bool {
		return stages[i].StartTime.Before(stages[j].StartTime)
	})

	var nights [][]models.SleepStageRow
	var currentNight []models.SleepStageRow

	for _, stage := range stages {
		if len(currentNight) == 0 {
			currentNight = append(currentNight, stage)
			continue
		}
		lastEnd := currentNight[len(currentNight)-1].EndTime
		if stage.StartTime.Sub(lastEnd) > 12*time.Hour {
			nights = append(nights, currentNight)
			currentNight = []models.SleepStageRow{stage}
		} else {
			currentNight = append(currentNight, stage)
		}
	}
	if len(currentNight) > 0 {
		nights = append(nights, currentNight)
	}
	return nights
}

// nightsOverlapping keeps the nights that have at least one instant in
// common with [from, to]. A night is kept whole or not at all.
func nightsOverlapping(nights [][]models.SleepStageRow, from, to time.Time) [][]models.SleepStageRow {
	var kept [][]models.SleepStageRow
	for _, night := range nights {
		first := night[0].StartTime
		last := night[len(night)-1].EndTime
		if last.Before(from) || first.After(to) {
			continue
		}
		kept = append(kept, night)
	}
	return kept
}

// insertBackfillSession writes one night as a session and, when the night
// was new, its sleep_analysis metric. Returns 1 when a session was created,
// 0 when a direct source already owns that date.
func (db *DB) insertBackfillSession(ctx context.Context, userID int, night []models.SleepStageRow) (int, error) {
	sleepStart := night[0].StartTime
	sleepEnd := night[len(night)-1].EndTime

	var deep, core, rem, awake, inBedDur float64
	for _, s := range night {
		switch s.Stage {
		case "Deep":
			deep += s.DurationHr
		case "Core":
			core += s.DurationHr
		case "REM":
			rem += s.DurationHr
		case "Awake":
			awake += s.DurationHr
		case "In Bed":
			inBedDur += s.DurationHr
		}
	}

	totalSleep := deep + core + rem
	inBed := sleepEnd.Sub(sleepStart).Hours()
	date := sleepEnd.Truncate(24 * time.Hour)

	session := models.SleepSessionRow{
		UserID:     userID,
		Date:       date,
		TotalSleep: totalSleep,
		Asleep:     totalSleep,
		Core:       core,
		Deep:       deep,
		REM:        rem,
		InBed:      inBed,
		SleepStart: sleepStart,
		SleepEnd:   sleepEnd,
		InBedStart: sleepStart,
		InBedEnd:   sleepEnd,
	}

	// Use DO NOTHING: backfill is a fallback — don't overwrite sessions
	// from direct sources (Oura, HAE) which have more accurate data.
	tag, err := db.Pool.Exec(ctx,
		`INSERT INTO sleep_sessions (user_id, date, total_sleep, asleep, core, deep, rem, in_bed, sleep_start, sleep_end, in_bed_start, in_bed_end)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		 ON CONFLICT (user_id, date) DO NOTHING`,
		session.UserID, session.Date, session.TotalSleep, session.Asleep,
		session.Core, session.Deep, session.REM, session.InBed,
		session.SleepStart, session.SleepEnd, session.InBedStart, session.InBedEnd)
	if err != nil {
		return 0, fmt.Errorf("inserting backfill session: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return 0, nil // session already exists from a direct source
	}

	qty := totalSleep
	sleepMetric := models.HealthMetricRow{
		Time:       date.Add(12 * time.Hour), // noon UTC for stable dedup
		UserID:     userID,
		MetricName: "sleep_analysis",
		Source:     "FreeReps Backfill",
		Units:      "hr",
		Qty:        &qty,
	}
	if _, _, err := db.InsertHealthMetrics(ctx, []models.HealthMetricRow{sleepMetric}); err != nil {
		return 1, fmt.Errorf("inserting backfill sleep_analysis metric: %w", err)
	}
	return 1, nil
}
