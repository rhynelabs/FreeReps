package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// DataStats holds aggregate statistics about all stored data.
type DataStats struct {
	// TotalMetricRows is the planner's estimate once the user holds more than
	// metricRowsExactBelow rows, exact below that. See countMetricRows.
	TotalMetricRows  int64             `json:"total_metric_rows"`
	TotalWorkouts    int64             `json:"total_workouts"`
	TotalSleepNights int64             `json:"total_sleep_nights"`
	TotalSets        int64             `json:"total_sets"`
	EarliestData     *time.Time        `json:"earliest_data"`
	LatestData       *time.Time        `json:"latest_data"`
	WorkoutsByType   []WorkoutTypeStat `json:"workouts_by_type"`
}

// WorkoutTypeStat holds summary stats for a single workout type.
type WorkoutTypeStat struct {
	Name          string   `json:"name"`
	Count         int64    `json:"count"`
	TotalDuration float64  `json:"total_duration_sec"`
	TotalDistance *float64 `json:"total_distance,omitempty"`
}

// metricRowsExactBelow is the estimate under which countMetricRows runs the
// exact count after all. Planner statistics are unreliable on chunks that
// have not been analysed since their first rows arrived — which is the small,
// fresh database, where an exact count over the index is cheap anyway. Above
// it the exact count is what took half a second per Overview load.
const metricRowsExactBelow = 200_000

// GetDataStats returns aggregate statistics for a user's stored data.
func (db *DB) GetDataStats(ctx context.Context, userID int) (*DataStats, error) {
	stats := &DataStats{}

	var err error
	stats.TotalMetricRows, err = db.countMetricRows(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("counting metrics: %w", err)
	}

	// The remaining tables are small enough for exact counts over their
	// (user_id, ...) indexes.
	err = db.Pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM workouts WHERE user_id = $1`, userID,
	).Scan(&stats.TotalWorkouts)
	if err != nil {
		return nil, fmt.Errorf("counting workouts: %w", err)
	}

	err = db.Pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM sleep_sessions WHERE user_id = $1`, userID,
	).Scan(&stats.TotalSleepNights)
	if err != nil {
		return nil, fmt.Errorf("counting sleep sessions: %w", err)
	}

	err = db.Pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM workout_sets WHERE user_id = $1`, userID,
	).Scan(&stats.TotalSets)
	if err != nil {
		return nil, fmt.Errorf("counting sets: %w", err)
	}

	// Date range (earliest/latest across metrics and workouts). Each MIN/MAX
	// is its own subquery so the planner can answer it with one index probe
	// (the hypertable's time index, idx_workouts_user_start) instead of a scan.
	err = db.Pool.QueryRow(ctx,
		`SELECT MIN(t), MAX(t) FROM (
			SELECT MIN(time) AS t FROM health_metrics WHERE user_id = $1
			UNION ALL
			SELECT MIN(start_time) FROM workouts WHERE user_id = $1
			UNION ALL
			SELECT MAX(time) FROM health_metrics WHERE user_id = $1
			UNION ALL
			SELECT MAX(start_time) FROM workouts WHERE user_id = $1
		) sub`, userID,
	).Scan(&stats.EarliestData, &stats.LatestData)
	if err != nil {
		return nil, fmt.Errorf("querying date range: %w", err)
	}

	// Workouts by type
	rows, err := db.Pool.Query(ctx,
		`SELECT name, COUNT(*), COALESCE(SUM(duration_sec), 0),
		        SUM(CASE WHEN distance_units = 'mi' THEN distance * 1.60934
		                 WHEN distance_units = 'm'  THEN distance / 1000
		                 ELSE distance END)
		 FROM workouts
		 WHERE user_id = $1
		 GROUP BY name
		 ORDER BY COUNT(*) DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("querying workouts by type: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var s WorkoutTypeStat
		if err := rows.Scan(&s.Name, &s.Count, &s.TotalDuration, &s.TotalDistance); err != nil {
			return nil, fmt.Errorf("scanning workout type stat: %w", err)
		}
		stats.WorkoutsByType = append(stats.WorkoutsByType, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return stats, nil
}

// countMetricRows returns how many health_metrics rows the user has: the
// planner's estimate when that is large, the exact count when it is small.
//
// health_metrics is the one table whose count grows without bound, and an
// exact COUNT(*) walks every index entry of the user — 507 ms median, 4.6 s
// worst on the deployed server, paid on every Overview load. The estimate
// costs a planning pass and reads no table data. Its error is whatever
// autovacuum's statistics lag behind by, which for a display of "N metric
// rows" is invisible. TimescaleDB's approximate_row_count would be cheaper
// still but counts the whole table, and the figure is per user.
func (db *DB) countMetricRows(ctx context.Context, userID int) (int64, error) {
	estimate, err := db.estimateMetricRows(ctx, userID)
	if err != nil {
		return 0, err
	}
	if estimate >= metricRowsExactBelow {
		return estimate, nil
	}

	var exact int64
	err = db.Pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM health_metrics WHERE user_id = $1`, userID,
	).Scan(&exact)
	return exact, err
}

// estimateMetricRows asks the planner how many health_metrics rows it expects
// for the user. On a hypertable the top plan node appends the chunks, so its
// row estimate is the sum over them; on plain PostgreSQL it is the table
// estimate. The parameter is bound, so the estimate uses the user_id's own
// frequency from the column statistics, not a generic selectivity.
func (db *DB) estimateMetricRows(ctx context.Context, userID int) (int64, error) {
	var raw string
	err := db.Pool.QueryRow(ctx,
		`EXPLAIN (FORMAT JSON) SELECT 1 FROM health_metrics WHERE user_id = $1`, userID,
	).Scan(&raw)
	if err != nil {
		return 0, fmt.Errorf("explaining metric count: %w", err)
	}
	return planRows([]byte(raw))
}

// planRows reads the top node's row estimate out of EXPLAIN (FORMAT JSON)
// output, which is an array with one plan per statement.
func planRows(explainJSON []byte) (int64, error) {
	var plans []struct {
		Plan struct {
			Rows float64 `json:"Plan Rows"`
		} `json:"Plan"`
	}
	if err := json.Unmarshal(explainJSON, &plans); err != nil {
		return 0, fmt.Errorf("parsing plan: %w", err)
	}
	if len(plans) == 0 {
		return 0, fmt.Errorf("parsing plan: no plan in output")
	}
	return int64(plans[0].Plan.Rows), nil
}
