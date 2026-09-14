package storage

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// sourcePriorityCaseSQL generates a SQL CASE expression that maps source values
// to priority numbers. Lower numbers = higher priority. Sources not in the list
// get the lowest priority. Named sources use prefix matching (e.g. "Apple Watch"
// matches "Apple Watch Series 9"); empty string uses exact match.
// Returns "1" if no priorities are configured (all sources equal = no-op dedup).
func sourcePriorityCaseSQL(priorities []string) string {
	if len(priorities) == 0 {
		return "1"
	}
	var b strings.Builder
	b.WriteString("CASE ")
	for i, src := range priorities {
		if src == "" {
			fmt.Fprintf(&b, "WHEN source = '' THEN %d ", i+1)
		} else {
			fmt.Fprintf(&b, "WHEN source LIKE '%s%%' THEN %d ", src, i+1)
		}
	}
	fmt.Fprintf(&b, "ELSE %d END", len(priorities)+1)
	return b.String()
}

// dedupCTE returns a WITH clause that deduplicates health_metrics at a fixed
// 5-minute granularity using source priority. The CTE selects all columns plus
// a row number (rn) partitioned by 5-minute time buckets. Callers should filter
// with "WHERE rn = 1" to keep only the highest-priority source per bucket.
func dedupCTE(priorities []string, metricParam, startParam, endParam, userIDParam string) string {
	priorityExpr := sourcePriorityCaseSQL(priorities)
	return fmt.Sprintf(
		`WITH deduped AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY time_bucket('5 minutes', time)
				ORDER BY %s
			) AS rn
			FROM health_metrics
			WHERE metric_name = %s AND time >= %s AND time < %s AND user_id = %s
		) `, priorityExpr, metricParam, startParam, endParam, userIDParam)
}

// dedupCTEMultiMetric returns a dedup CTE for queries that span multiple metrics
// (e.g. GetDailySums). Partitions by metric_name in addition to time bucket.
func dedupCTEMultiMetric(priorities []string, userIDParam, inClause string) string {
	priorityExpr := sourcePriorityCaseSQL(priorities)
	return fmt.Sprintf(
		`WITH deduped AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY metric_name, time_bucket('5 minutes', time)
				ORDER BY %s
			) AS rn
			FROM health_metrics
			WHERE user_id = %s AND metric_name IN (%s)
		) `, priorityExpr, userIDParam, inClause)
}

// dedupCTEMultiMetricRange is dedupCTEMultiMetric with the time range inside the
// CTE rather than in the caller's WHERE clause.
//
// That distinction is the whole cost of the query. Filtering outside makes
// Postgres number every row the user holds for those metrics before discarding
// all but the window — which is why the front page took the same five seconds
// whether it asked for 30 days or a year. Inside, the range joins the index
// condition on idx_health_metrics_dedup_cover.
func dedupCTEMultiMetricRange(priorities []string, userIDParam, inClause, startParam, endParam string) string {
	priorityExpr := sourcePriorityCaseSQL(priorities)
	return fmt.Sprintf(
		`WITH deduped AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY metric_name, time_bucket('5 minutes', time)
				ORDER BY %s
			) AS rn
			FROM health_metrics
			WHERE user_id = %s AND metric_name IN (%s)
			  AND time >= %s AND time < %s
		) `, priorityExpr, userIDParam, inClause, startParam, endParam)
}

// cumulativeMetrics are metrics that should be summed (not averaged) when aggregating.
var cumulativeMetrics = map[string]bool{
	"active_energy":                 true,
	"basal_energy_burned":           true,
	"apple_exercise_time":           true,
	"step_count":                    true,
	"distance_walking_running":      true,
	"distance_cycling":              true,
	"distance_swimming":             true,
	"distance_wheelchair":           true,
	"flights_climbed":               true,
	"apple_move_time":               true,
	"apple_stand_time":              true,
	"push_count":                    true,
	"swimming_stroke_count":         true,
	"distance_downhill_snow_sports": true,
	// Daily training volume: a week's figure is the sum of its days, not their
	// average.
	TrainingTonnageMetric: true,
}

// maxRowsPerBatch bounds one INSERT.
//
// It no longer has anything to do with the 65535-parameter limit of the
// extended protocol: the rows travel as twelve arrays, so a statement costs
// twelve parameters whatever its length. What the bound still does is cap the
// memory one statement holds at once — the twelve arrays plus the RETURNING
// result — so a client that uploads its whole history in one request does not
// materialize it all in the server.
const maxRowsPerBatch = 5000

// insertHealthMetricsSQL inserts a batch given as twelve arrays and refreshes
// aggregated rows that changed.
//
// unnest() expands the arrays back into rows, which keeps the statement text
// and the parameter count constant: 5,000 rows used to mean 60,000 parameters
// and a statement Postgres had to parse and plan from scratch every time.
//
// The conflict target names the columns of idx_health_metrics_dedup
// (migrations/000001_init.up.sql), in its order. TimescaleDB accepts
// ON CONFLICT ... DO UPDATE on a hypertable when the arbiter index contains the
// partitioning column, which `time` is; it also refuses to create a unique
// index on a hypertable without that column, so the two constraints agree and
// the target stays valid as long as the index exists.
//
// The guard is what separates the two kinds of row that share this table.
// Hourly buckets the app computes itself (steps, energy, distance) carry no
// source UUID and are re-sent with a larger sum as the hour fills, so they have
// to be refreshed; a row that came from an individual HealthKit sample is
// immutable and is never touched, whichever side of the conflict it sits on.
// The IS DISTINCT FROM clause keeps an unchanged re-upload from writing a new
// row version, which would be dead weight in a compressed chunk.
//
// RETURNING (xmax = 0) reports per row whether it was inserted rather than
// updated, so the caller can keep counting new rows separately from refreshed
// ones. A conflicting row the guard rejects is not returned at all — it is
// neither inserted nor updated.
const insertHealthMetricsSQL = `INSERT INTO health_metrics (time, user_id, metric_name, source, units, qty, min_val, avg_val, max_val, systolic, diastolic, source_uuid)
SELECT * FROM unnest($1::timestamptz[], $2::int[], $3::text[], $4::text[], $5::text[], $6::float8[], $7::float8[], $8::float8[], $9::float8[], $10::float8[], $11::float8[], $12::uuid[])
ON CONFLICT (metric_name, source, time, user_id) DO UPDATE SET
	qty = EXCLUDED.qty,
	min_val = EXCLUDED.min_val,
	avg_val = EXCLUDED.avg_val,
	max_val = EXCLUDED.max_val,
	units = EXCLUDED.units
WHERE health_metrics.source_uuid IS NULL
  AND EXCLUDED.source_uuid IS NULL
  AND (health_metrics.qty IS DISTINCT FROM EXCLUDED.qty
    OR health_metrics.min_val IS DISTINCT FROM EXCLUDED.min_val
    OR health_metrics.avg_val IS DISTINCT FROM EXCLUDED.avg_val
    OR health_metrics.max_val IS DISTINCT FROM EXCLUDED.max_val)
RETURNING (xmax = 0)`

// InsertHealthMetrics batch-inserts health metric rows. It returns how many rows
// were new and how many existing aggregated rows it refreshed; rows that
// conflicted without being refreshed are counted in neither.
func (db *DB) InsertHealthMetrics(ctx context.Context, rows []models.HealthMetricRow) (inserted, updated int64, err error) {
	if len(rows) == 0 {
		return 0, 0, nil
	}

	rows = dedupeHealthMetricRows(rows)

	for start := 0; start < len(rows); start += maxRowsPerBatch {
		end := start + maxRowsPerBatch
		if end > len(rows) {
			end = len(rows)
		}
		batchInserted, batchUpdated, err := db.insertHealthMetricsBatch(ctx, rows[start:end])
		inserted += batchInserted
		updated += batchUpdated
		if err != nil {
			return inserted, updated, err
		}
	}
	return inserted, updated, nil
}

// dedupeHealthMetricRows keeps the last row per conflict key.
//
// ON CONFLICT DO UPDATE refuses to touch the same row twice in one statement
// and aborts the whole INSERT when it would ("cannot affect row a second
// time"), where DO NOTHING silently dropped the repeat. A payload that carries
// the same bucket twice — the app retrying a partial upload inside one request
// — must not turn into a failed batch, and the later copy is the one that
// should win.
//
// The key is the unique index, with the timestamp in microseconds because that
// is the resolution timestamptz stores: two times that differ by less
// than that are one row to Postgres.
func dedupeHealthMetricRows(rows []models.HealthMetricRow) []models.HealthMetricRow {
	type conflictKey struct {
		metricName string
		source     string
		micros     int64
		userID     int
	}

	lastAt := make(map[conflictKey]int, len(rows))
	for i, r := range rows {
		lastAt[conflictKey{r.MetricName, r.Source, r.Time.UnixMicro(), r.UserID}] = i
	}
	if len(lastAt) == len(rows) {
		return rows
	}

	kept := make([]models.HealthMetricRow, 0, len(lastAt))
	for i, r := range rows {
		if lastAt[conflictKey{r.MetricName, r.Source, r.Time.UnixMicro(), r.UserID}] == i {
			kept = append(kept, r)
		}
	}
	return kept
}

// healthMetricColumns is one batch turned on its side: twelve parallel arrays,
// the shape unnest() expands back into rows.
type healthMetricColumns struct {
	times       []time.Time
	userIDs     []int32
	metricNames []string
	sources     []string
	units       []string
	qty         []pgtype.Float8
	minVal      []pgtype.Float8
	avgVal      []pgtype.Float8
	maxVal      []pgtype.Float8
	systolic    []pgtype.Float8
	diastolic   []pgtype.Float8
	sourceUUIDs []pgtype.UUID
}

// healthMetricColumnsFrom transposes rows into the arrays the insert binds.
//
// The nullable columns use pgtype rather than *float64 and *uuid.UUID because a
// Go slice of pointers encodes as an array of that element type only if every
// element is addressable the same way; the pgtype values carry their own Valid
// flag, so a nil pointer becomes SQL NULL instead of a zero.
func healthMetricColumnsFrom(rows []models.HealthMetricRow) healthMetricColumns {
	c := healthMetricColumns{
		times:       make([]time.Time, len(rows)),
		userIDs:     make([]int32, len(rows)),
		metricNames: make([]string, len(rows)),
		sources:     make([]string, len(rows)),
		units:       make([]string, len(rows)),
		qty:         make([]pgtype.Float8, len(rows)),
		minVal:      make([]pgtype.Float8, len(rows)),
		avgVal:      make([]pgtype.Float8, len(rows)),
		maxVal:      make([]pgtype.Float8, len(rows)),
		systolic:    make([]pgtype.Float8, len(rows)),
		diastolic:   make([]pgtype.Float8, len(rows)),
		sourceUUIDs: make([]pgtype.UUID, len(rows)),
	}
	for i, r := range rows {
		c.times[i] = r.Time
		c.userIDs[i] = int32(r.UserID)
		c.metricNames[i] = r.MetricName
		c.sources[i] = r.Source
		c.units[i] = r.Units
		c.qty[i] = nullableFloat8(r.Qty)
		c.minVal[i] = nullableFloat8(r.MinVal)
		c.avgVal[i] = nullableFloat8(r.AvgVal)
		c.maxVal[i] = nullableFloat8(r.MaxVal)
		c.systolic[i] = nullableFloat8(r.Systolic)
		c.diastolic[i] = nullableFloat8(r.Diastolic)
		c.sourceUUIDs[i] = nullableUUID(r.SourceUUID)
	}
	return c
}

// nullableFloat8 maps a nil pointer to SQL NULL rather than to 0.0, which for
// qty would read as a measured zero.
func nullableFloat8(v *float64) pgtype.Float8 {
	if v == nil {
		return pgtype.Float8{}
	}
	return pgtype.Float8{Float64: *v, Valid: true}
}

// nullableUUID maps a nil pointer to SQL NULL, which is also what marks a row
// as aggregated rather than a single sample.
func nullableUUID(v *uuid.UUID) pgtype.UUID {
	if v == nil {
		return pgtype.UUID{}
	}
	return pgtype.UUID{Bytes: *v, Valid: true}
}

func (db *DB) insertHealthMetricsBatch(ctx context.Context, rows []models.HealthMetricRow) (inserted, updated int64, err error) {
	c := healthMetricColumnsFrom(rows)

	result, err := db.Pool.Query(ctx, insertHealthMetricsSQL,
		c.times, c.userIDs, c.metricNames, c.sources, c.units,
		c.qty, c.minVal, c.avgVal, c.maxVal,
		c.systolic, c.diastolic, c.sourceUUIDs)
	if err != nil {
		return 0, 0, fmt.Errorf("inserting health metrics: %w", err)
	}
	defer result.Close()

	for result.Next() {
		var isInsert bool
		if err := result.Scan(&isInsert); err != nil {
			return 0, 0, fmt.Errorf("scanning health metric insert result: %w", err)
		}
		if isInsert {
			inserted++
		} else {
			updated++
		}
	}
	if err := result.Err(); err != nil {
		return 0, 0, fmt.Errorf("inserting health metrics: %w", err)
	}
	return inserted, updated, nil
}

// QueryHealthMetrics retrieves health metrics by name and time range.
func (db *DB) QueryHealthMetrics(ctx context.Context, metricName string, start, end time.Time, userID int) ([]models.HealthMetricRow, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT time, user_id, metric_name, source, units, qty, min_val, avg_val, max_val, systolic, diastolic, source_uuid
		 FROM health_metrics
		 WHERE metric_name = $1 AND time >= $2 AND time < $3 AND user_id = $4
		 ORDER BY time ASC`,
		metricName, start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying health metrics: %w", err)
	}
	defer rows.Close()

	return scanHealthMetricRows(rows)
}

// GetLatestMetrics returns the most recent data point for each metric, resolved
// against the user's source priority.
//
// The priority applies within a 5-minute bucket, as everywhere else: the newest
// bucket wins, and inside it the highest-priority source. Ordering by time alone
// would let a lower-priority device that wrote a minute later decide both the
// value and the source name shown beside it — while the series next to it, which
// does dedupe by priority, came from the other device.
func (db *DB) GetLatestMetrics(ctx context.Context, userID int) ([]models.HealthMetricRow, error) {
	return db.latestMetrics(ctx, userID, nil)
}

// recentLookupDays bounds the first pass of the latest-value lookup.
//
// health_metrics is a hypertable, and without a time predicate TimescaleDB
// cannot exclude chunks — every per-metric lookup walks back through all of
// them until it finds a row, which costs the same whether the reading is from
// this morning or two years ago. Nearly every metric has something within this
// window, so the bounded pass answers almost all of them and the unbounded
// second pass runs for the few stragglers.
const recentLookupDays = 120

// GetLatestMetricsFor is GetLatestMetrics restricted to named metrics.
//
// Two passes: a bounded one that TimescaleDB can satisfy from recent chunks,
// then an unbounded one for whichever names it did not answer — a metric like
// body weight, last recorded months ago, still reports its value.
func (db *DB) GetLatestMetricsFor(ctx context.Context, userID int, names []string) ([]models.HealthMetricRow, error) {
	if len(names) == 0 {
		return nil, nil
	}

	priorities := db.ResolveSourcePriority(ctx, userID, "_default")
	since := time.Now().AddDate(0, 0, -recentLookupDays)

	recent, err := db.queryLatest(ctx, latestMetricsForNamesRecentQuery(priorities, since), userID, names)
	if err != nil {
		return nil, err
	}

	found := make(map[string]bool, len(recent))
	for _, row := range recent {
		found[row.MetricName] = true
	}
	var stale []string
	for _, name := range names {
		if !found[name] {
			stale = append(stale, name)
		}
	}
	if len(stale) == 0 {
		return recent, nil
	}

	older, err := db.queryLatest(ctx, latestMetricsForNamesQuery(priorities), userID, stale)
	if err != nil {
		return nil, err
	}
	return append(recent, older...), nil
}

func (db *DB) latestMetrics(ctx context.Context, userID int, names []string) ([]models.HealthMetricRow, error) {
	priorities := db.ResolveSourcePriority(ctx, userID, "_default")
	if names == nil {
		return db.queryLatest(ctx, latestMetricsQuery(priorities), userID)
	}
	return db.queryLatest(ctx, latestMetricsForNamesQuery(priorities), userID, names)
}

func (db *DB) queryLatest(ctx context.Context, query string, args ...any) ([]models.HealthMetricRow, error) {
	rows, err := db.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying latest metrics: %w", err)
	}
	defer rows.Close()

	return scanHealthMetricRows(rows)
}

// latestMetricsQuery builds the deduplicated latest-per-metric query. Split out
// so the priority ordering can be asserted without a database.
//
// Two steps, both index-driven. The first walks idx_health_metrics_dedup_cover
// backwards to find the newest timestamp per metric — one row per metric, no
// scan. The second reopens only the five minutes before each of those, which is
// the window source priority is defined over.
//
// The obvious form — ROW_NUMBER over every row, then DISTINCT ON — is what made
// the front page take five seconds: it numbered 4.5 million rows to return
// seventeen.
func latestMetricsQuery(priorities []string) string {
	return fmt.Sprintf(
		`WITH newest AS (
			SELECT DISTINCT ON (metric_name) metric_name, time AS peak
			FROM health_metrics
			WHERE user_id = $1
			ORDER BY metric_name, time DESC
		)
		SELECT DISTINCT ON (h.metric_name)
		       h.time, h.user_id, h.metric_name, h.source, h.units,
		       h.qty, h.min_val, h.avg_val, h.max_val,
		       h.systolic, h.diastolic, h.source_uuid
		 FROM newest n
		 JOIN health_metrics h
		   ON h.user_id = $1
		  AND h.metric_name = n.metric_name
		  AND h.time > n.peak - interval '5 minutes'
		  AND h.time <= n.peak
		 ORDER BY h.metric_name, %s, h.time DESC`, sourcePriorityCaseSQL(priorities))
}

// latestMetricsForNamesRecentQuery is latestMetricsForNamesQuery with a lower
// time bound, which is what lets TimescaleDB skip old chunks. Metrics with
// nothing in the window return no row and are retried unbounded.
func latestMetricsForNamesRecentQuery(priorities []string, since time.Time) string {
	return fmt.Sprintf(
		`WITH newest AS (
			SELECT m.metric_name, l.time AS peak
			FROM unnest($2::text[]) AS m(metric_name)
			CROSS JOIN LATERAL (
				SELECT time FROM health_metrics h
				WHERE h.user_id = $1 AND h.metric_name = m.metric_name
				  AND h.time >= %s
				ORDER BY h.time DESC
				LIMIT 1
			) l
		)
		SELECT DISTINCT ON (h.metric_name)
		       h.time, h.user_id, h.metric_name, h.source, h.units,
		       h.qty, h.min_val, h.avg_val, h.max_val,
		       h.systolic, h.diastolic, h.source_uuid
		 FROM newest n
		 JOIN health_metrics h
		   ON h.user_id = $1
		  AND h.metric_name = n.metric_name
		  AND h.time > n.peak - interval '5 minutes'
		  AND h.time <= n.peak
		 ORDER BY h.metric_name, %s, h.time DESC`,
		sqlTimestamp(since), sourcePriorityCaseSQL(priorities))
}

// latestMetricsForNamesQuery is latestMetricsQuery with the metric names given
// as a parameter, so each one becomes a bounded index lookup rather than a walk
// across every entry the user has.
func latestMetricsForNamesQuery(priorities []string) string {
	return fmt.Sprintf(
		`WITH newest AS (
			SELECT m.metric_name, l.time AS peak
			FROM unnest($2::text[]) AS m(metric_name)
			CROSS JOIN LATERAL (
				SELECT time FROM health_metrics h
				WHERE h.user_id = $1 AND h.metric_name = m.metric_name
				ORDER BY h.time DESC
				LIMIT 1
			) l
		)
		SELECT DISTINCT ON (h.metric_name)
		       h.time, h.user_id, h.metric_name, h.source, h.units,
		       h.qty, h.min_val, h.avg_val, h.max_val,
		       h.systolic, h.diastolic, h.source_uuid
		 FROM newest n
		 JOIN health_metrics h
		   ON h.user_id = $1
		  AND h.metric_name = n.metric_name
		  AND h.time > n.peak - interval '5 minutes'
		  AND h.time <= n.peak
		 ORDER BY h.metric_name, %s, h.time DESC`, sourcePriorityCaseSQL(priorities))
}

// GetTimeSeries returns aggregated time-series data using time_bucket.
// bucketSize should be a PostgreSQL interval like '1 day', '1 hour'.
// Cumulative metrics (active_energy, basal_energy_burned, apple_exercise_time)
// use SUM; all others use AVG.
func (db *DB) GetTimeSeries(ctx context.Context, metricName string, start, end time.Time, bucketSize string, userID int) ([]TimeSeriesPoint, error) {
	aggFunc := "AVG"
	if cumulativeMetrics[metricName] {
		aggFunc = "SUM"
	}
	priorities := db.ResolveSourcePriorityForMetric(ctx, userID, metricName)
	cte := dedupCTE(priorities, "$2", "$3", "$4", "$5")
	query := fmt.Sprintf(
		`%sSELECT time_bucket($1::interval, time) AS bucket,
		        %s(COALESCE(qty, avg_val)) AS avg_val,
		        MIN(COALESCE(qty, min_val)) AS min_val,
		        MAX(COALESCE(qty, max_val)) AS max_val,
		        COUNT(*) AS count
		 FROM deduped WHERE rn = 1
		 GROUP BY bucket
		 ORDER BY bucket ASC`, cte, aggFunc)
	rows, err := db.Pool.Query(ctx, query,
		bucketSize, metricName, start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying time series: %w", err)
	}
	defer rows.Close()

	var result []TimeSeriesPoint
	for rows.Next() {
		var p TimeSeriesPoint
		if err := rows.Scan(&p.Time, &p.Avg, &p.Min, &p.Max, &p.Count); err != nil {
			return nil, fmt.Errorf("scanning time series: %w", err)
		}
		result = append(result, p)
	}
	return result, rows.Err()
}

// TimeSeriesPoint is an aggregated data point.
type TimeSeriesPoint struct {
	Time  time.Time `json:"time"`
	Avg   *float64  `json:"avg"`
	Min   *float64  `json:"min"`
	Max   *float64  `json:"max"`
	Count int64     `json:"count"`
}

// DailySum represents the sum of a cumulative metric for the current day.
type DailySum struct {
	MetricName string  `json:"MetricName"`
	Units      string  `json:"Units"`
	Total      float64 `json:"Total"`
}

// GetDailySums returns summed values for the most recent day with data for cumulative metrics.
// Uses the latest available data day rather than today, so historical data still shows values.
func (db *DB) GetDailySums(ctx context.Context, userID int, metricNames []string) ([]DailySum, error) {
	if len(metricNames) == 0 {
		return nil, nil
	}

	// Build IN clause
	params := make([]string, len(metricNames))
	args := make([]any, 0, len(metricNames)+1)
	args = append(args, userID)
	for i, name := range metricNames {
		params[i] = fmt.Sprintf("$%d", i+2)
		args = append(args, name)
	}

	inClause := strings.Join(params, ",")
	// DailySums spans multiple metrics (potentially different categories).
	// Use the user's _default priority.
	priorities := db.ResolveSourcePriority(ctx, userID, "_default")
	cte := dedupCTEMultiMetric(priorities, "$1", inClause)

	query := fmt.Sprintf(
		`%sSELECT metric_name,
		        COALESCE(MAX(units), '') as units,
		        COALESCE(SUM(COALESCE(qty, avg_val, 0)), 0) as total
		 FROM deduped
		 WHERE rn = 1
		   AND time >= (SELECT date_trunc('day', MAX(time)) FROM deduped WHERE rn = 1)
		 GROUP BY metric_name`,
		cte)

	rows, err := db.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying daily sums: %w", err)
	}
	defer rows.Close()

	var result []DailySum
	for rows.Next() {
		var s DailySum
		if err := rows.Scan(&s.MetricName, &s.Units, &s.Total); err != nil {
			return nil, fmt.Errorf("scanning daily sum: %w", err)
		}
		result = append(result, s)
	}
	return result, rows.Err()
}

// MetricStats holds aggregate statistics for a single metric over a time range.
type MetricStats struct {
	Metric string   `json:"metric"`
	Avg    *float64 `json:"avg"`
	Min    *float64 `json:"min"`
	Max    *float64 `json:"max"`
	StdDev *float64 `json:"stddev"`
	Count  int64    `json:"count"`
}

// GetMetricStats returns aggregate statistics for a metric over a time range.
func (db *DB) GetMetricStats(ctx context.Context, metricName string, start, end time.Time, userID int) (*MetricStats, error) {
	priorities := db.ResolveSourcePriorityForMetric(ctx, userID, metricName)
	cte := dedupCTE(priorities, "$1", "$2", "$3", "$4")
	query := fmt.Sprintf(
		`%sSELECT AVG(COALESCE(qty, avg_val)),
		        MIN(COALESCE(qty, min_val)),
		        MAX(COALESCE(qty, max_val)),
		        STDDEV_POP(COALESCE(qty, avg_val)),
		        COUNT(*)
		 FROM deduped WHERE rn = 1`, cte)
	row := db.Pool.QueryRow(ctx, query, metricName, start, end, userID)

	stats := &MetricStats{Metric: metricName}
	if err := row.Scan(&stats.Avg, &stats.Min, &stats.Max, &stats.StdDev, &stats.Count); err != nil {
		return nil, fmt.Errorf("querying metric stats: %w", err)
	}
	return stats, nil
}

// CorrelationPoint is a time-aligned pair of metric values.
type CorrelationPoint struct {
	Time time.Time `json:"time"`
	X    *float64  `json:"x"`
	Y    *float64  `json:"y"`
}

// CorrelationResult holds paired data and a Pearson correlation coefficient.
type CorrelationResult struct {
	Points   []CorrelationPoint `json:"points"`
	PearsonR *float64           `json:"pearson_r"`
	Count    int64              `json:"count"`
}

// GetCorrelation joins two metrics on time buckets and computes their Pearson correlation.
// Uses SUM for cumulative metrics, AVG for all others.
func (db *DB) GetCorrelation(ctx context.Context, xMetric, yMetric string, start, end time.Time, bucket string, userID int) (*CorrelationResult, error) {
	xAgg := "AVG"
	if cumulativeMetrics[xMetric] {
		xAgg = "SUM"
	}
	yAgg := "AVG"
	if cumulativeMetrics[yMetric] {
		yAgg = "SUM"
	}
	// For correlation, use the priority for the X metric's category.
	priorities := db.ResolveSourcePriorityForMetric(ctx, userID, xMetric)
	priorityExpr := sourcePriorityCaseSQL(priorities)
	query := fmt.Sprintf(
		`WITH x_deduped AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY time_bucket('5 minutes', time)
				ORDER BY %s
			) AS rn
			FROM health_metrics
			WHERE metric_name = $2 AND time >= $4 AND time < $5 AND user_id = $6
		), y_deduped AS (
			SELECT *, ROW_NUMBER() OVER (
				PARTITION BY time_bucket('5 minutes', time)
				ORDER BY %s
			) AS rn
			FROM health_metrics
			WHERE metric_name = $3 AND time >= $4 AND time < $5 AND user_id = $6
		), x AS (
			SELECT time_bucket($1::interval, time) AS bucket,
			       %s(COALESCE(qty, avg_val)) AS val
			FROM x_deduped WHERE rn = 1
			GROUP BY bucket
		), y AS (
			SELECT time_bucket($1::interval, time) AS bucket,
			       %s(COALESCE(qty, avg_val)) AS val
			FROM y_deduped WHERE rn = 1
			GROUP BY bucket
		)
		SELECT x.bucket, x.val, y.val
		FROM x JOIN y ON x.bucket = y.bucket
		ORDER BY x.bucket ASC`, priorityExpr, priorityExpr, xAgg, yAgg)
	rows, err := db.Pool.Query(ctx, query,
		bucket, xMetric, yMetric, start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying correlation: %w", err)
	}
	defer rows.Close()

	var points []CorrelationPoint
	for rows.Next() {
		var p CorrelationPoint
		if err := rows.Scan(&p.Time, &p.X, &p.Y); err != nil {
			return nil, fmt.Errorf("scanning correlation point: %w", err)
		}
		points = append(points, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := &CorrelationResult{
		Points: points,
		Count:  int64(len(points)),
	}

	// Compute Pearson R
	if len(points) >= 3 {
		var sumX, sumY, sumXY, sumX2, sumY2 float64
		var n float64
		for _, p := range points {
			if p.X != nil && p.Y != nil {
				x, y := *p.X, *p.Y
				sumX += x
				sumY += y
				sumXY += x * y
				sumX2 += x * x
				sumY2 += y * y
				n++
			}
		}
		if n >= 3 {
			denom := (n*sumX2 - sumX*sumX) * (n*sumY2 - sumY*sumY)
			if denom > 0 {
				r := (n*sumXY - sumX*sumY) / math.Sqrt(denom)
				result.PearsonR = &r
			}
		}
	}

	return result, nil
}

func scanHealthMetricRows(rows pgx.Rows) ([]models.HealthMetricRow, error) {
	var result []models.HealthMetricRow
	for rows.Next() {
		var r models.HealthMetricRow
		if err := rows.Scan(&r.Time, &r.UserID, &r.MetricName, &r.Source, &r.Units,
			&r.Qty, &r.MinVal, &r.AvgVal, &r.MaxVal, &r.Systolic, &r.Diastolic, &r.SourceUUID); err != nil {
			return nil, fmt.Errorf("scanning health metric row: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
