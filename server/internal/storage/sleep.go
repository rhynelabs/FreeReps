package storage

import (
	"cmp"
	"context"
	"fmt"
	"log/slog"
	"slices"
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
	sortSleepStageRows(rows)

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

// sortSleepStageRows puts the rows in the order of idx_sleep_stages_dedup, in
// place, so that concurrent statements sharing rows wait on them in the same
// order; see sortHealthMetricRows.
func sortSleepStageRows(rows []models.SleepStageRow) {
	slices.SortStableFunc(rows, func(a, b models.SleepStageRow) int {
		return cmp.Or(
			a.StartTime.Compare(b.StartTime),
			a.EndTime.Compare(b.EndTime),
			cmp.Compare(a.Stage, b.Stage),
			cmp.Compare(a.UserID, b.UserID),
		)
	})
}

// SleepSessionResult is a sleep session with optional stage data.
type SleepSessionResult struct {
	models.SleepSessionRow
	ID int64
}

// QuerySleepSessions retrieves the sleep sessions dated on any day that
// [start, end) touches. See dateBounds for why the instants are not passed
// through as they are.
func (db *DB) QuerySleepSessions(ctx context.Context, start, end time.Time, userID int) ([]SleepSessionResult, error) {
	from, to := dateBounds(start, end)
	rows, err := db.Pool.Query(ctx,
		`SELECT id, user_id, date, total_sleep, asleep, core, deep, rem, in_bed, sleep_start, sleep_end, in_bed_start, in_bed_end
		 FROM sleep_sessions
		 WHERE date >= $1 AND date < $2 AND user_id = $3
		 ORDER BY date DESC`,
		from, to, userID)
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

	created, err := db.insertBackfillSessions(ctx, userID, nightsOverlapping(groupNights(stages), from, to))
	if err != nil {
		return created, err
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

	created, err := db.insertBackfillSessions(ctx, userID, groupNights(stages))
	if err != nil {
		return created, err
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

// nightSession sums one night's stages into the session row the backfill
// writes. Split from the insert so the grouping and the date can be checked
// without a database.
//
// The night is dated by the UTC day its last stage ends on, computed in UTC
// on purpose: the stage times come back from pgx in the process time zone,
// and a time.Time bound to the DATE column encodes as the calendar day in
// its own location. Truncating in that location would date a night ending
// 07:46Z as the previous day on a host west of UTC, where it collides with
// the night before and ON CONFLICT DO NOTHING drops it for good. The UTC day
// is not the user's day — for a user in UTC+2, a night that ends before
// 02:00 local time is dated the day before — but it is the one convention
// every reader of the column shares (dateBounds, the aggregated ingest path).
func nightSession(userID int, night []models.SleepStageRow) models.SleepSessionRow {
	sleepStart := night[0].StartTime
	sleepEnd := night[len(night)-1].EndTime

	var deep, core, rem float64
	for _, s := range night {
		switch s.Stage {
		case "Deep":
			deep += s.DurationHr
		case "Core":
			core += s.DurationHr
		case "REM":
			rem += s.DurationHr
		}
	}

	totalSleep := deep + core + rem
	inBed := sleepEnd.Sub(sleepStart).Hours()
	date := sleepEnd.UTC().Truncate(24 * time.Hour)

	return models.SleepSessionRow{
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
}

// A VALUES statement stays below PostgreSQL's 65,535-parameter limit and
// turns a full multi-year backfill into a few commits instead of one commit
// per night.
const maxBackfillSessionsPerBatch = 1000

// insertBackfillSessions writes the sessions and their derived metrics in the
// same transaction. A server interruption can therefore never leave a
// session whose metric was not written, which the old two-transaction path
// could not repair on its next ON CONFLICT DO NOTHING run.
func (db *DB) insertBackfillSessions(ctx context.Context, userID int, nights [][]models.SleepStageRow) (int, error) {
	if len(nights) == 0 {
		return 0, nil
	}

	sessions := make([]models.SleepSessionRow, len(nights))
	for i, night := range nights {
		sessions[i] = nightSession(userID, night)
	}

	var created int
	for start := 0; start < len(sessions); start += maxBackfillSessionsPerBatch {
		end := min(start+maxBackfillSessionsPerBatch, len(sessions))
		batchCreated, err := db.insertBackfillSessionBatch(ctx, sessions[start:end])
		created += batchCreated
		if err != nil {
			return created, err
		}
	}
	return created, nil
}

func (db *DB) insertBackfillSessionBatch(ctx context.Context, sessions []models.SleepSessionRow) (int, error) {
	args := make([]any, 0, len(sessions)*12)
	values := make([]string, 0, len(sessions))
	for i, session := range sessions {
		base := i * 12
		values = append(values, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5, base+6,
			base+7, base+8, base+9, base+10, base+11, base+12,
		))
		args = append(args,
			session.UserID, session.Date, session.TotalSleep, session.Asleep,
			session.Core, session.Deep, session.REM, session.InBed,
			session.SleepStart, session.SleepEnd, session.InBedStart, session.InBedEnd,
		)
	}

	// DO NOTHING is deliberate: backfill is a fallback and must not overwrite
	// a session from a direct source such as Oura or HAE.
	query := `WITH inserted_sessions AS (
		INSERT INTO sleep_sessions (user_id, date, total_sleep, asleep, core, deep, rem, in_bed, sleep_start, sleep_end, in_bed_start, in_bed_end)
		VALUES ` + strings.Join(values, ",") + `
		ON CONFLICT (user_id, date) DO NOTHING
		RETURNING user_id, date, total_sleep
	), inserted_metrics AS (
		INSERT INTO health_metrics (time, user_id, metric_name, source, units, qty)
		SELECT (date::timestamp + interval '12 hours') AT TIME ZONE 'UTC',
		       user_id, 'sleep_analysis', 'FreeReps Backfill', 'hr', total_sleep
		FROM inserted_sessions
		ON CONFLICT (metric_name, source, time, user_id) DO NOTHING
		RETURNING user_id
	)
	SELECT count(*)::int FROM inserted_sessions`

	var created int
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		created = 0
		if err := tx.QueryRow(ctx, query, args...).Scan(&created); err != nil {
			return fmt.Errorf("inserting backfill sessions: %w", err)
		}
		return nil
	})
	return created, err
}
