package storage

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// alphaWorkoutNamespace is the UUID namespace for deterministic synthetic Alpha workout IDs.
var alphaWorkoutNamespace = uuid.MustParse("7ba7b810-9dad-11d1-80b4-00c04fd430c8")

// hevyWorkoutNamespace is the UUID namespace for deterministic synthetic Hevy workout IDs.
// Unlike Alpha, the payload is Hevy's own workout id, so the synthetic id stays
// stable even when the session is renamed or its start time is corrected.
var hevyWorkoutNamespace = uuid.MustParse("8ba7b810-9dad-11d1-80b4-00c04fd430c8")

// syntheticWorkoutName is the workout type reported for sessions that exist only
// in workout_sets. The frontend type filters match on this value.
const syntheticWorkoutName = "Traditional Strength Training"

// syntheticWorkoutID derives the deterministic id for a strength session that has
// no row in the workouts table.
func syntheticWorkoutID(s SetSessionInfo) uuid.UUID {
	if s.Source == "Hevy" && s.ExternalID != "" {
		return uuid.NewSHA1(hevyWorkoutNamespace, []byte("hevy:workout:"+s.ExternalID))
	}
	return uuid.NewSHA1(alphaWorkoutNamespace,
		[]byte("alpha:"+s.SessionDate.Format(time.RFC3339)+":"+s.SessionName))
}

// syntheticWorkoutEnd returns the session end. Hevy reports it directly; Alpha
// only carries a duration string that has to be parsed and added to the start.
func syntheticWorkoutEnd(s SetSessionInfo) time.Time {
	if s.SessionEnd != nil && !s.SessionEnd.IsZero() {
		return *s.SessionEnd
	}
	return s.SessionDate.Add(parseAlphaDuration(s.SessionDuration))
}

// Rows per multi-row INSERT for each of the three workout tables. The extended
// protocol allows 65,535 parameters per statement; each chunk stays under that
// with the column count of its table (21, 7 and 10).
const (
	workoutRowsPerStatement      = 3000
	workoutHRRowsPerStatement    = 9000
	workoutRouteRowsPerStatement = 6000
)

// insertWorkoutsSQL takes the workout columns as a multi-row VALUES list.
// The primary key is the HealthKit UUID, so a re-sent workout is a no-op and
// the command tag counts only the rows that were new.
const insertWorkoutsSQL = `INSERT INTO workouts (id, user_id, name, source, start_time, end_time, duration_sec, location, is_indoor,
	 active_energy_burned, active_energy_units, total_energy, total_energy_units,
	 distance, distance_units, avg_heart_rate, max_heart_rate, min_heart_rate,
	 elevation_up, elevation_down, raw_json) VALUES `

const insertWorkoutHeartRateSQL = `INSERT INTO workout_heart_rate (time, workout_id, user_id, min_bpm, avg_bpm, max_bpm, source) VALUES `

const insertWorkoutRoutesSQL = `INSERT INTO workout_routes (time, workout_id, user_id, latitude, longitude, altitude, speed, course, horizontal_accuracy, vertical_accuracy) VALUES `

// valuesPlaceholders renders the "($1,$2),($3,$4)" part of a multi-row
// INSERT for rows rows of width columns each.
func valuesPlaceholders(rows, width int) string {
	var sb strings.Builder
	for i := 0; i < rows; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteByte('(')
		for j := 0; j < width; j++ {
			if j > 0 {
				sb.WriteByte(',')
			}
			sb.WriteByte('$')
			sb.WriteString(strconv.Itoa(i*width + j + 1))
		}
		sb.WriteByte(')')
	}
	return sb.String()
}

// WorkoutBatch is what one ingest request carries for the workouts table and
// its two point tables.
type WorkoutBatch struct {
	Workouts  []models.WorkoutRow
	HeartRate []models.WorkoutHRRow
	Routes    []models.WorkoutRouteRow
}

// WorkoutBatchCounts reports the rows InsertWorkoutBatch inserted, per table.
type WorkoutBatchCounts struct {
	Workouts    int64
	HRPoints    int64
	RoutePoints int64
}

// InsertWorkoutBatch inserts the workouts of one request in one transaction,
// then their heart-rate points and route points in a second. Rows that already
// exist are skipped and not counted.
//
// Two transactions rather than one per workout: a request with 151 workouts
// took 44 s on the deployed server, because each workout was its own
// synchronous commit — one fsync on the NAS's disk — followed by a second
// transaction for its heart-rate points.
//
// Two rather than one: the point tables are hypertables, and a new chunk gets
// a copy of the foreign key to workouts, which takes ShareRowExclusiveLock on
// workouts — a lock the RowExclusiveLock of an uncommitted workouts insert
// conflicts with. Three concurrent requests that each held that lock and each
// needed a chunk deadlocked on 2026-09-14 (INCIDENTS.md). With the workouts
// committed first, the points transaction holds only the foreign key's
// KEY SHARE on their rows, which chunk creation does not conflict with, and
// the workouts transaction never creates a chunk because workouts is a plain
// table. A request that fails between the two commits leaves its workouts
// without points until the app re-sends them, which it does; ON CONFLICT
// DO NOTHING makes the re-send cheap.
func (db *DB) InsertWorkoutBatch(ctx context.Context, b WorkoutBatch) (WorkoutBatchCounts, error) {
	var counts WorkoutBatchCounts
	if len(b.Workouts) == 0 && len(b.HeartRate) == 0 && len(b.Routes) == 0 {
		return counts, nil
	}
	b.Workouts = dedupeWorkoutRows(b.Workouts)
	sortWorkoutPoints(b.HeartRate, b.Routes)

	// An ingest write: the app re-sends what a lost commit would drop.
	if len(b.Workouts) > 0 {
		err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
			var err error
			counts.Workouts, err = insertWorkouts(ctx, tx, b.Workouts)
			return err
		})
		if err != nil {
			return counts, err
		}
	}
	if len(b.HeartRate) == 0 && len(b.Routes) == 0 {
		return counts, nil
	}
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		var err error
		if counts.HRPoints, err = insertWorkoutHeartRate(ctx, tx, b.HeartRate); err != nil {
			return err
		}
		counts.RoutePoints, err = insertWorkoutRoutes(ctx, tx, b.Routes)
		return err
	})
	return counts, err
}

// sortWorkoutPoints orders both point tables by (workout_id, time), in place,
// so that concurrent statements sharing rows wait on them in the same order;
// see sortHealthMetricRows. Points arrive per workout in time order, so the
// sort has little to do.
func sortWorkoutPoints(hr []models.WorkoutHRRow, routes []models.WorkoutRouteRow) {
	slices.SortStableFunc(hr, func(a, b models.WorkoutHRRow) int {
		return compareWorkoutPoint(a.WorkoutID, b.WorkoutID, a.Time, b.Time)
	})
	slices.SortStableFunc(routes, func(a, b models.WorkoutRouteRow) int {
		return compareWorkoutPoint(a.WorkoutID, b.WorkoutID, a.Time, b.Time)
	})
}

func compareWorkoutPoint(aID, bID uuid.UUID, aTime, bTime time.Time) int {
	if c := bytes.Compare(aID[:], bID[:]); c != 0 {
		return c
	}
	return aTime.Compare(bTime)
}

// dedupeWorkoutRows keeps the last row per id. The primary key would skip the
// repeat anyway, but not before its raw_json travelled to the server twice.
func dedupeWorkoutRows(rows []models.WorkoutRow) []models.WorkoutRow {
	lastAt := make(map[uuid.UUID]int, len(rows))
	for i, r := range rows {
		lastAt[r.ID] = i
	}
	if len(lastAt) == len(rows) {
		return rows
	}

	kept := make([]models.WorkoutRow, 0, len(lastAt))
	for i, r := range rows {
		if lastAt[r.ID] == i {
			kept = append(kept, r)
		}
	}
	return kept
}

func insertWorkouts(ctx context.Context, tx pgx.Tx, rows []models.WorkoutRow) (int64, error) {
	var total int64
	for start := 0; start < len(rows); start += workoutRowsPerStatement {
		chunk := rows[start:min(start+workoutRowsPerStatement, len(rows))]
		args := make([]any, 0, len(chunk)*21)
		for _, r := range chunk {
			args = append(args, r.ID, r.UserID, r.Name, r.Source, r.StartTime, r.EndTime, r.DurationSec,
				r.Location, r.IsIndoor,
				r.ActiveEnergyBurned, r.ActiveEnergyUnits, r.TotalEnergy, r.TotalEnergyUnits,
				r.Distance, r.DistanceUnits, r.AvgHeartRate, r.MaxHeartRate, r.MinHeartRate,
				r.ElevationUp, r.ElevationDown, r.RawJSON)
		}
		query := insertWorkoutsSQL + valuesPlaceholders(len(chunk), 21) + " ON CONFLICT DO NOTHING"
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return total, fmt.Errorf("inserting workouts: %w", err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

func insertWorkoutHeartRate(ctx context.Context, tx pgx.Tx, rows []models.WorkoutHRRow) (int64, error) {
	var total int64
	for start := 0; start < len(rows); start += workoutHRRowsPerStatement {
		chunk := rows[start:min(start+workoutHRRowsPerStatement, len(rows))]
		args := make([]any, 0, len(chunk)*7)
		for _, r := range chunk {
			args = append(args, r.Time, r.WorkoutID, r.UserID, r.MinBPM, r.AvgBPM, r.MaxBPM, r.Source)
		}
		query := insertWorkoutHeartRateSQL + valuesPlaceholders(len(chunk), 7) + " ON CONFLICT DO NOTHING"
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return total, fmt.Errorf("inserting workout heart rate: %w", err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

func insertWorkoutRoutes(ctx context.Context, tx pgx.Tx, rows []models.WorkoutRouteRow) (int64, error) {
	var total int64
	for start := 0; start < len(rows); start += workoutRouteRowsPerStatement {
		chunk := rows[start:min(start+workoutRouteRowsPerStatement, len(rows))]
		args := make([]any, 0, len(chunk)*10)
		for _, r := range chunk {
			args = append(args, r.Time, r.WorkoutID, r.UserID, r.Latitude, r.Longitude,
				r.Altitude, r.Speed, r.Course, r.HorizontalAccuracy, r.VerticalAccuracy)
		}
		query := insertWorkoutRoutesSQL + valuesPlaceholders(len(chunk), 10) + " ON CONFLICT DO NOTHING"
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return total, fmt.Errorf("inserting workout routes: %w", err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// InsertWorkout inserts a single workout row with a synchronous commit, for
// the Oura sync and the demo seed. Returns true if inserted, false if duplicate.
func (db *DB) InsertWorkout(ctx context.Context, row models.WorkoutRow) (bool, error) {
	tag, err := db.Pool.Exec(ctx,
		insertWorkoutsSQL+valuesPlaceholders(1, 21)+" ON CONFLICT DO NOTHING",
		row.ID, row.UserID, row.Name, row.Source, row.StartTime, row.EndTime, row.DurationSec,
		row.Location, row.IsIndoor,
		row.ActiveEnergyBurned, row.ActiveEnergyUnits, row.TotalEnergy, row.TotalEnergyUnits,
		row.Distance, row.DistanceUnits, row.AvgHeartRate, row.MaxHeartRate, row.MinHeartRate,
		row.ElevationUp, row.ElevationDown, row.RawJSON)
	if err != nil {
		return false, fmt.Errorf("inserting workout: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// InsertWorkoutHeartRate batch-inserts workout HR data points on their own,
// for the demo seed. Returns count inserted.
func (db *DB) InsertWorkoutHeartRate(ctx context.Context, rows []models.WorkoutHRRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	var inserted int64
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		var err error
		inserted, err = insertWorkoutHeartRate(ctx, tx, rows)
		return err
	})
	return inserted, err
}

// WorkoutDetail is a workout with its HR and route data.
type WorkoutDetail struct {
	models.WorkoutRow
	HeartRateData []models.WorkoutHRRow
	RouteData     []models.WorkoutRouteRow
}

// QueryWorkouts retrieves workouts in a time range, optionally filtered by type name.
// Deduplicates overlapping workouts from different sources using source priority:
// when two workouts start within the same 5-minute window, only the highest-priority
// source's workout is returned. Excludes raw_json to keep the list payload small.
func (db *DB) QueryWorkouts(ctx context.Context, start, end time.Time, userID int, nameFilter string) ([]models.WorkoutRow, error) {
	priorities := db.ResolveSourcePriority(ctx, userID, "activity")
	priorityExpr := sourcePriorityCaseSQL(priorities)
	where := `start_time >= $1 AND start_time < $2 AND user_id = $3`
	args := []any{start, end, userID}
	if nameFilter != "" {
		where += ` AND name = $4`
		args = append(args, nameFilter)
	}
	query := fmt.Sprintf(
		`WITH ranked AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY date_trunc('hour', start_time) + INTERVAL '5 min' * FLOOR(EXTRACT(MINUTE FROM start_time) / 5)
				ORDER BY %s
			) AS rn
			FROM workouts
			WHERE %s
		)
		SELECT id, user_id, name, source, start_time, end_time, duration_sec, location, is_indoor,
			active_energy_burned, active_energy_units, total_energy, total_energy_units,
			distance, distance_units, avg_heart_rate, max_heart_rate, min_heart_rate,
			elevation_up, elevation_down
		FROM ranked WHERE rn = 1
		ORDER BY start_time DESC`, priorityExpr, where)
	rows, err := db.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying workouts: %w", err)
	}
	defer rows.Close()

	return scanWorkoutListRows(rows)
}

// GetWorkout retrieves a single workout by ID with all associated data.
func (db *DB) GetWorkout(ctx context.Context, workoutID uuid.UUID, userID int) (*WorkoutDetail, error) {
	row := db.Pool.QueryRow(ctx,
		`SELECT id, user_id, name, start_time, end_time, duration_sec, location, is_indoor,
		 active_energy_burned, active_energy_units, total_energy, total_energy_units,
		 distance, distance_units, avg_heart_rate, max_heart_rate, min_heart_rate,
		 elevation_up, elevation_down, raw_json
		 FROM workouts
		 WHERE id = $1 AND user_id = $2`,
		workoutID, userID)

	var w models.WorkoutRow
	err := row.Scan(&w.ID, &w.UserID, &w.Name, &w.StartTime, &w.EndTime, &w.DurationSec,
		&w.Location, &w.IsIndoor,
		&w.ActiveEnergyBurned, &w.ActiveEnergyUnits, &w.TotalEnergy, &w.TotalEnergyUnits,
		&w.Distance, &w.DistanceUnits, &w.AvgHeartRate, &w.MaxHeartRate, &w.MinHeartRate,
		&w.ElevationUp, &w.ElevationDown, &w.RawJSON)
	if err != nil {
		return nil, fmt.Errorf("querying workout: %w", err)
	}

	detail := &WorkoutDetail{WorkoutRow: w}

	// Get HR data
	hrRows, err := db.Pool.Query(ctx,
		`SELECT time, workout_id, user_id, min_bpm, avg_bpm, max_bpm, source
		 FROM workout_heart_rate
		 WHERE workout_id = $1 AND user_id = $2
		 ORDER BY time ASC`,
		workoutID, userID)
	if err != nil {
		return nil, fmt.Errorf("querying workout HR: %w", err)
	}
	defer hrRows.Close()

	for hrRows.Next() {
		var hr models.WorkoutHRRow
		if err := hrRows.Scan(&hr.Time, &hr.WorkoutID, &hr.UserID, &hr.MinBPM, &hr.AvgBPM, &hr.MaxBPM, &hr.Source); err != nil {
			return nil, fmt.Errorf("scanning workout HR: %w", err)
		}
		detail.HeartRateData = append(detail.HeartRateData, hr)
	}
	if err := hrRows.Err(); err != nil {
		return nil, err
	}

	// Get route data
	routeRows, err := db.Pool.Query(ctx,
		`SELECT time, workout_id, user_id, latitude, longitude, altitude, speed, course, horizontal_accuracy, vertical_accuracy
		 FROM workout_routes
		 WHERE workout_id = $1 AND user_id = $2
		 ORDER BY time ASC`,
		workoutID, userID)
	if err != nil {
		return nil, fmt.Errorf("querying workout routes: %w", err)
	}
	defer routeRows.Close()

	for routeRows.Next() {
		var r models.WorkoutRouteRow
		if err := routeRows.Scan(&r.Time, &r.WorkoutID, &r.UserID, &r.Latitude, &r.Longitude,
			&r.Altitude, &r.Speed, &r.Course, &r.HorizontalAccuracy, &r.VerticalAccuracy); err != nil {
			return nil, fmt.Errorf("scanning workout route: %w", err)
		}
		detail.RouteData = append(detail.RouteData, r)
	}

	return detail, routeRows.Err()
}

// scanWorkoutListRows scans workout rows without raw_json (for list queries).
func scanWorkoutListRows(rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
}) ([]models.WorkoutRow, error) {
	var result []models.WorkoutRow
	for rows.Next() {
		var w models.WorkoutRow
		if err := rows.Scan(&w.ID, &w.UserID, &w.Name, &w.Source, &w.StartTime, &w.EndTime, &w.DurationSec,
			&w.Location, &w.IsIndoor,
			&w.ActiveEnergyBurned, &w.ActiveEnergyUnits, &w.TotalEnergy, &w.TotalEnergyUnits,
			&w.Distance, &w.DistanceUnits, &w.AvgHeartRate, &w.MaxHeartRate, &w.MinHeartRate,
			&w.ElevationUp, &w.ElevationDown); err != nil {
			return nil, fmt.Errorf("scanning workout: %w", err)
		}
		result = append(result, w)
	}
	return result, rows.Err()
}

// QueryWorkoutsMerged returns workouts enriched with strength session names from
// workout_sets. Apple/Oura workouts near such a session get its name for display;
// sessions with no nearby workout get a synthetic workout entry.
//
// Neither Alpha Progression nor Hevy writes rows into the workouts table — that
// was tried for Alpha and reverted in commit 411f4c1, because the same training
// session already arrives from Apple Health with heart rate data and the two
// rows cannot be deduplicated reliably by start time.
func (db *DB) QueryWorkoutsMerged(ctx context.Context, start, end time.Time, userID int, nameFilter string) ([]models.WorkoutRow, error) {
	workouts, err := db.QueryWorkouts(ctx, start, end, userID, nameFilter)
	if err != nil {
		return nil, err
	}

	// Fetch sessions with 2h padding to catch sessions just outside the range.
	alphaSessions, err := db.QuerySetSessions(ctx, start.Add(-2*time.Hour), end.Add(2*time.Hour), userID)
	if err != nil {
		return nil, err
	}
	if len(alphaSessions) == 0 {
		return workouts, nil
	}

	// Match Alpha sessions to workouts by nearest time within ±2h.
	matched := make(map[int]bool)   // index into workouts
	alphaUsed := make(map[int]bool) // index into alphaSessions

	type pair struct {
		wi, ai int
		dist   time.Duration
	}
	var pairs []pair
	for wi, w := range workouts {
		for ai, a := range alphaSessions {
			dist := w.StartTime.Sub(a.SessionDate)
			if dist < 0 {
				dist = -dist
			}
			if dist <= 2*time.Hour {
				pairs = append(pairs, pair{wi, ai, dist})
			}
		}
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].dist < pairs[j].dist })

	for _, p := range pairs {
		if matched[p.wi] || alphaUsed[p.ai] {
			continue
		}
		workouts[p.wi].AlphaSessionName = alphaSessions[p.ai].SessionName
		matched[p.wi] = true
		alphaUsed[p.ai] = true
	}

	// Create synthetic workouts for unmatched sessions.
	for ai, a := range alphaSessions {
		if alphaUsed[ai] {
			continue
		}
		// Skip if outside the requested range.
		if a.SessionDate.Before(start) || !a.SessionDate.Before(end) {
			continue
		}
		// Skip if name filter is set and doesn't match the synthetic base name.
		if nameFilter != "" && nameFilter != syntheticWorkoutName {
			continue
		}
		sessionEnd := syntheticWorkoutEnd(a)
		source := a.Source
		if source == "" {
			source = "Alpha Progression"
		}
		workouts = append(workouts, models.WorkoutRow{
			ID:               syntheticWorkoutID(a),
			UserID:           userID,
			Name:             syntheticWorkoutName,
			Source:           source,
			StartTime:        a.SessionDate,
			EndTime:          sessionEnd,
			DurationSec:      sessionEnd.Sub(a.SessionDate).Seconds(),
			AlphaSessionName: a.SessionName,
		})
	}

	sort.Slice(workouts, func(i, j int) bool {
		return workouts[i].StartTime.After(workouts[j].StartTime)
	})
	return workouts, nil
}

// parseAlphaDuration parses Alpha Progression duration strings like "1:02 hr".
func parseAlphaDuration(s string) time.Duration {
	s = strings.TrimSpace(strings.TrimSuffix(s, "hr"))
	parts := strings.SplitN(s, ":", 2)
	if len(parts) != 2 {
		return 0
	}
	hours, _ := strconv.Atoi(strings.TrimSpace(parts[0]))
	mins, _ := strconv.Atoi(strings.TrimSpace(parts[1]))
	return time.Duration(hours)*time.Hour + time.Duration(mins)*time.Minute
}
