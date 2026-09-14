package storage

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/jackc/pgx/v5"
)

// activitySummaryConflictSQL resolves a conflict on the (user_id, date) primary
// key by refreshing the row when its values changed.
//
// A day's rings are one aggregate that grows until midnight, and the app sends
// the current day with every sync. Under DO NOTHING the first upload of a day
// won and every later one was dropped, so today read as the near-zero values
// the morning sync had seen. There is no sample-vs-aggregate distinction in
// this table — every row is a day total — so the only guard is IS DISTINCT FROM
// over the six value columns, which keeps an unchanged re-upload from writing
// a new row version.
//
// RETURNING (xmax = 0) reports per row whether it was inserted rather than
// updated, so new rows stay countable apart from refreshed ones. A conflicting
// row whose values did not change is not returned at all.
const activitySummaryConflictSQL = ` ON CONFLICT (user_id, date) DO UPDATE SET
	active_energy = EXCLUDED.active_energy,
	active_energy_goal = EXCLUDED.active_energy_goal,
	exercise_time = EXCLUDED.exercise_time,
	exercise_time_goal = EXCLUDED.exercise_time_goal,
	stand_hours = EXCLUDED.stand_hours,
	stand_hours_goal = EXCLUDED.stand_hours_goal
WHERE (activity_summaries.active_energy, activity_summaries.active_energy_goal,
       activity_summaries.exercise_time, activity_summaries.exercise_time_goal,
       activity_summaries.stand_hours, activity_summaries.stand_hours_goal)
  IS DISTINCT FROM
      (EXCLUDED.active_energy, EXCLUDED.active_energy_goal,
       EXCLUDED.exercise_time, EXCLUDED.exercise_time_goal,
       EXCLUDED.stand_hours, EXCLUDED.stand_hours_goal)
RETURNING (xmax = 0)`

// InsertActivitySummaries batch-inserts activity summary rows. It returns how
// many rows were new and how many existing days it refreshed; rows that
// conflicted without changing are counted in neither.
//
// The rows travel as a multi-row VALUES list: a request carries at most a few
// hundred days, so the parameter count that forced health_metrics onto
// unnest() never comes near the limit here.
func (db *DB) InsertActivitySummaries(ctx context.Context, rows []models.ActivitySummaryRow) (inserted, updated int64, err error) {
	if len(rows) == 0 {
		return 0, 0, nil
	}

	rows = dedupeActivitySummaryRows(rows)

	query := `INSERT INTO activity_summaries (user_id, date, active_energy, active_energy_goal, exercise_time, exercise_time_goal, stand_hours, stand_hours_goal) VALUES `
	args := make([]any, 0, len(rows)*8)
	valueStrings := make([]string, 0, len(rows))

	for i, r := range rows {
		base := i * 8
		valueStrings = append(valueStrings, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5, base+6, base+7, base+8,
		))
		args = append(args, r.UserID, r.Date, r.ActiveEnergy, r.ActiveEnergyGoal,
			r.ExerciseTime, r.ExerciseTimeGoal, r.StandHours, r.StandHoursGoal)
	}

	query += strings.Join(valueStrings, ",") + activitySummaryConflictSQL

	// An ingest write: the app re-sends what a lost commit would drop.
	err = db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		// A rerun after a deadlock starts the count over.
		inserted, updated = 0, 0
		result, err := tx.Query(ctx, query, args...)
		if err != nil {
			return fmt.Errorf("inserting activity summaries: %w", err)
		}
		defer result.Close()

		for result.Next() {
			var isInsert bool
			if err := result.Scan(&isInsert); err != nil {
				return fmt.Errorf("scanning activity summary insert result: %w", err)
			}
			if isInsert {
				inserted++
			} else {
				updated++
			}
		}
		if err := result.Err(); err != nil {
			return fmt.Errorf("inserting activity summaries: %w", err)
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	return inserted, updated, nil
}

// dedupeActivitySummaryRows keeps the last row per (user_id, date).
//
// ON CONFLICT DO UPDATE aborts the whole INSERT when one statement would touch
// the same row twice ("cannot affect row a second time"), where DO NOTHING
// silently dropped the repeat. A payload that carries the same day twice must
// not turn into a failed batch, and the later copy is the one that should win.
//
// The key is the calendar day as pgx encodes a time.Time into DATE: year,
// month and day read in the value's own location, the clock part discarded.
// Two times on the same calendar day are one row to Postgres, so they have to
// be one row here.
func dedupeActivitySummaryRows(rows []models.ActivitySummaryRow) []models.ActivitySummaryRow {
	type conflictKey struct {
		userID int
		year   int
		month  time.Month
		day    int
	}
	keyOf := func(r models.ActivitySummaryRow) conflictKey {
		y, m, d := r.Date.Date()
		return conflictKey{r.UserID, y, m, d}
	}

	lastAt := make(map[conflictKey]int, len(rows))
	for i, r := range rows {
		lastAt[keyOf(r)] = i
	}
	if len(lastAt) == len(rows) {
		return rows
	}

	kept := make([]models.ActivitySummaryRow, 0, len(lastAt))
	for i, r := range rows {
		if lastAt[keyOf(r)] == i {
			kept = append(kept, r)
		}
	}
	return kept
}

// QueryActivitySummaries retrieves the activity summaries dated on any day
// that [start, end) touches. See dateBounds for why the instants are not
// passed through as they are.
func (db *DB) QueryActivitySummaries(ctx context.Context, start, end time.Time, userID int) ([]models.ActivitySummaryRow, error) {
	from, to := dateBounds(start, end)
	rows, err := db.Pool.Query(ctx,
		`SELECT user_id, date, active_energy, active_energy_goal, exercise_time, exercise_time_goal, stand_hours, stand_hours_goal
		 FROM activity_summaries
		 WHERE date >= $1 AND date < $2 AND user_id = $3
		 ORDER BY date DESC`,
		from, to, userID)
	if err != nil {
		return nil, fmt.Errorf("querying activity summaries: %w", err)
	}
	defer rows.Close()

	var result []models.ActivitySummaryRow
	for rows.Next() {
		var r models.ActivitySummaryRow
		if err := rows.Scan(&r.UserID, &r.Date, &r.ActiveEnergy, &r.ActiveEnergyGoal,
			&r.ExerciseTime, &r.ExerciseTimeGoal, &r.StandHours, &r.StandHoursGoal); err != nil {
			return nil, fmt.Errorf("scanning activity summary: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
