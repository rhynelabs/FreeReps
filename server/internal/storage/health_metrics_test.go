package storage

import (
	"strings"
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

// TestSourcePriorityCaseSQL verifies that the SQL CASE expression correctly
// maps source names to priority numbers, ensuring higher-priority sources
// win during deduplication.
func TestSourcePriorityCaseSQL(t *testing.T) {
	tests := []struct {
		name       string
		priorities []string
		wantSQL    string
	}{
		{
			name:       "empty priorities returns constant 1 (no-op dedup)",
			priorities: nil,
			wantSQL:    "1",
		},
		{
			name:       "single named source",
			priorities: []string{"Oura"},
			wantSQL:    "CASE WHEN source LIKE 'Oura%' THEN 1 ELSE 2 END",
		},
		{
			name:       "oura then empty string",
			priorities: []string{"Oura", ""},
			wantSQL:    "CASE WHEN source LIKE 'Oura%' THEN 1 WHEN source = '' THEN 2 ELSE 3 END",
		},
		{
			name:       "three sources with prefix matching",
			priorities: []string{"Oura", "Apple Watch", ""},
			wantSQL:    "CASE WHEN source LIKE 'Oura%' THEN 1 WHEN source LIKE 'Apple Watch%' THEN 2 WHEN source = '' THEN 3 ELSE 4 END",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := sourcePriorityCaseSQL(tt.priorities)
			if got != tt.wantSQL {
				t.Errorf("sourcePriorityCaseSQL() =\n  %q\nwant:\n  %q", got, tt.wantSQL)
			}
		})
	}
}

// TestDedupCTE verifies that the generated CTE has the correct structure:
// a WITH clause using time_bucket, ROW_NUMBER, and the right parameter placeholders.
func TestDedupCTE(t *testing.T) {
	cte := dedupCTE([]string{"Oura", ""}, "$2", "$3", "$4", "$5")

	checks := []string{
		"WITH deduped AS",
		"time_bucket('5 minutes', time)",
		"ROW_NUMBER()",
		"LIKE 'Oura%' THEN 1",
		"source = '' THEN 2",
		"metric_name = $2",
		"time >= $3",
		"time < $4",
		"user_id = $5",
	}

	for _, check := range checks {
		if !strings.Contains(cte, check) {
			t.Errorf("dedupCTE missing %q in:\n%s", check, cte)
		}
	}
}

// TestLatestMetricsQueryDedupesBySourcePriority exists because the latest value
// and the series drawn beside it used to be resolved differently: the series
// deduplicated by source priority while the latest row was picked by timestamp
// alone. A lower-priority device writing a minute later then decided both the
// value and the source name shown next to a sparkline computed from the other
// device.
func TestLatestMetricsQueryDedupesBySourcePriority(t *testing.T) {
	query := latestMetricsQuery([]string{"Oura", ""})

	checks := []string{
		// Step one: the newest timestamp per metric, straight off the index.
		"SELECT DISTINCT ON (metric_name) metric_name, time AS peak",
		// Step two: only the five minutes priority is defined over.
		"h.time > n.peak - interval '5 minutes'",
		// Priority decides within that window, recency breaks the tie.
		"WHEN source LIKE 'Oura%' THEN 1",
		"ORDER BY h.metric_name,",
		"h.time DESC",
	}

	for _, check := range checks {
		if !strings.Contains(query, check) {
			t.Errorf("latestMetricsQuery missing %q in:\n%s", check, query)
		}
	}
}

// TestLatestMetricsQueryDoesNotWindowTheWholeTable exists because the obvious
// way to apply source priority — ROW_NUMBER over every row, then DISTINCT ON —
// numbered 4.5 million rows to return seventeen and cost the front page five
// seconds. The shape, not the result, is what regresses.
func TestLatestMetricsQueryDoesNotWindowTheWholeTable(t *testing.T) {
	query := latestMetricsQuery([]string{"Oura", ""})

	if strings.Contains(query, "ROW_NUMBER") {
		t.Errorf("latestMetricsQuery numbers rows again:\n%s", query)
	}
	// Every scan of health_metrics has to be bounded by a time predicate.
	if strings.Contains(query, "PARTITION BY") {
		t.Errorf("latestMetricsQuery partitions again:\n%s", query)
	}
}

// TestLatestMetricsRecentQueryIsBoundedInTime exists because health_metrics is
// a hypertable: without a lower bound on time, TimescaleDB cannot exclude
// chunks and each per-metric lookup walks back through all of them. The bound
// has to sit inside the LATERAL subquery, where the chunk scan happens — not in
// the outer join.
func TestLatestMetricsRecentQueryIsBoundedInTime(t *testing.T) {
	since := time.Date(2026, 4, 7, 0, 0, 0, 0, time.UTC)
	query := latestMetricsForNamesRecentQuery([]string{"Oura", ""}, since)

	lateral := strings.Index(query, "CROSS JOIN LATERAL")
	closing := strings.Index(query[lateral:], ") l")
	if lateral < 0 || closing < 0 {
		t.Fatalf("unexpected query shape:\n%s", query)
	}
	inner := query[lateral : lateral+closing]

	// A literal, not a parameter: a bind parameter hides the value from the
	// planner, which then cannot exclude chunks and plans across all 514 of
	// them — 584ms of planning against 12ms, measured in production.
	if !strings.Contains(inner, "h.time >= TIMESTAMPTZ '2026-04-07") {
		t.Errorf("the lower bound is not an inlined literal inside the LATERAL:\n%s", query)
	}
	if !strings.Contains(inner, "LIMIT 1") {
		t.Errorf("expected a LIMIT 1 lookup per metric:\n%s", query)
	}
}

// TestDedupCTEMultiMetricRangeFiltersInsideTheCTE exists because the same
// filter one level out — in the caller's WHERE — makes Postgres number the
// user's whole history before narrowing to the window, which is why the front
// page took the same time for 30 days as for a year.
func TestDedupCTEMultiMetricRangeFiltersInsideTheCTE(t *testing.T) {
	cte := dedupCTEMultiMetricRange([]string{"Oura", ""}, "$1", "$2,$3", "$4", "$5")

	openParen := strings.Index(cte, "(")
	closeParen := strings.LastIndex(cte, ")")
	if openParen < 0 || closeParen < 0 {
		t.Fatalf("unexpected CTE shape:\n%s", cte)
	}
	inner := cte[openParen:closeParen]

	for _, check := range []string{"time >= $4", "time < $5"} {
		if !strings.Contains(inner, check) {
			t.Errorf("range predicate %q is outside the CTE body:\n%s", check, cte)
		}
	}
}

// TestLatestMetricsQueryWithoutPrioritiesIsANoOp verifies the query still
// resolves when no priority is configured, rather than emitting an empty CASE.
func TestLatestMetricsQueryWithoutPrioritiesIsANoOp(t *testing.T) {
	query := latestMetricsQuery(nil)

	// sourcePriorityCaseSQL collapses to the constant 1, leaving recency as the
	// only tiebreaker rather than emitting an empty CASE.
	if !strings.Contains(query, "ORDER BY h.metric_name, 1, h.time DESC") {
		t.Errorf("expected the no-op ordering, got:\n%s", query)
	}
}

// TestDedupCTEMultiMetric verifies the multi-metric CTE partitions by both
// metric_name and time bucket, preventing cross-metric deduplication.
func TestDedupCTEMultiMetric(t *testing.T) {
	cte := dedupCTEMultiMetric([]string{"Oura", ""}, "$1", "$2,$3")

	checks := []string{
		"WITH deduped AS",
		"PARTITION BY metric_name, time_bucket('5 minutes', time)",
		"user_id = $1",
		"metric_name IN ($2,$3)",
	}

	for _, check := range checks {
		if !strings.Contains(cte, check) {
			t.Errorf("dedupCTEMultiMetric missing %q in:\n%s", check, cte)
		}
	}
}

// TestInsertHealthMetricsSQLRefreshesOnlyAggregates exists because the guard on
// the ON CONFLICT clause is the only thing standing between a re-uploaded batch
// and overwritten sample data. Nothing about a dropped guard fails loudly: the
// insert still succeeds, and the damage shows up as history that quietly
// changed. The statement text is asserted so an edit has to be deliberate.
func TestInsertHealthMetricsSQLRefreshesOnlyAggregates(t *testing.T) {
	checks := []string{
		// One statement, twelve parameters, whatever the row count.
		"SELECT * FROM unnest($1::timestamptz[]",
		"$12::uuid[])",
		// The columns of idx_health_metrics_dedup, time included, which is what
		// lets TimescaleDB accept the clause on a hypertable at all.
		"ON CONFLICT (metric_name, source, time, user_id) DO UPDATE SET",
		// Both sides have to be aggregates for the refresh to happen.
		"WHERE health_metrics.source_uuid IS NULL",
		"AND EXCLUDED.source_uuid IS NULL",
		// An unchanged re-upload writes no new row version.
		"health_metrics.qty IS DISTINCT FROM EXCLUDED.qty",
		// Inserted rows stay countable apart from refreshed ones.
		"RETURNING (xmax = 0)",
	}

	for _, check := range checks {
		if !strings.Contains(insertHealthMetricsSQL, check) {
			t.Errorf("insertHealthMetricsSQL missing %q in:\n%s", check, insertHealthMetricsSQL)
		}
	}

	// DO NOTHING is the behaviour this replaced; it would freeze today's
	// hourly totals again without changing anything a test could observe.
	if strings.Contains(insertHealthMetricsSQL, "DO NOTHING") {
		t.Errorf("the conflict clause is back to DO NOTHING:\n%s", insertHealthMetricsSQL)
	}
}

// TestHealthMetricColumnsFromEncodesNulls covers the reason the arrays hold
// pgtype values rather than pointers: a nil pointer has to reach Postgres as
// NULL. A qty of 0.0 where NULL was meant reads as a measured zero, and a
// zeroed source_uuid would make a sample row look like an aggregate — which is
// exactly the row the conflict guard then refreshes.
func TestHealthMetricColumnsFromEncodesNulls(t *testing.T) {
	qty := 1234.5
	sampleID := uuid.MustParse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	ts := time.Date(2026, 9, 14, 8, 0, 0, 0, time.UTC)

	c := healthMetricColumnsFrom([]models.HealthMetricRow{
		{
			Time:       ts,
			UserID:     7,
			MetricName: "step_count",
			Source:     "",
			Units:      "count",
			Qty:        &qty,
		},
		{
			Time:       ts,
			UserID:     7,
			MetricName: "heart_rate",
			Source:     "Apple Watch",
			Units:      "count/min",
			AvgVal:     &qty,
			SourceUUID: &sampleID,
		},
	})

	if len(c.times) != 2 || c.times[0] != ts {
		t.Fatalf("unexpected time column: %v", c.times)
	}
	if c.userIDs[0] != 7 || c.metricNames[1] != "heart_rate" || c.sources[1] != "Apple Watch" {
		t.Errorf("unexpected scalar columns: %v %v %v", c.userIDs, c.metricNames, c.sources)
	}

	if !c.qty[0].Valid || c.qty[0].Float64 != qty {
		t.Errorf("qty with a value did not survive: %+v", c.qty[0])
	}
	if c.qty[1].Valid {
		t.Errorf("a nil qty has to be NULL, not %v", c.qty[1].Float64)
	}
	if !c.avgVal[1].Valid || c.avgVal[1].Float64 != qty {
		t.Errorf("avg_val with a value did not survive: %+v", c.avgVal[1])
	}
	for name, col := range map[string]pgtype.Float8{
		"min_val":   c.minVal[0],
		"max_val":   c.maxVal[0],
		"systolic":  c.systolic[0],
		"diastolic": c.diastolic[0],
	} {
		if col.Valid {
			t.Errorf("%s should be NULL, got %v", name, col.Float64)
		}
	}

	// The aggregated row carries no UUID; the sample row carries its own.
	if c.sourceUUIDs[0].Valid {
		t.Errorf("an aggregated row must have a NULL source_uuid, got %x", c.sourceUUIDs[0].Bytes)
	}
	if !c.sourceUUIDs[1].Valid || c.sourceUUIDs[1].Bytes != sampleID {
		t.Errorf("sample UUID did not survive: %+v", c.sourceUUIDs[1])
	}
}

// TestDedupeHealthMetricRowsKeepsTheLast exists because ON CONFLICT DO UPDATE
// aborts the whole statement when one row would be touched twice, where the old
// DO NOTHING dropped the repeat silently. A payload that repeats a bucket must
// still be accepted, with the later value winning.
func TestDedupeHealthMetricRowsKeepsTheLast(t *testing.T) {
	ts := time.Date(2026, 9, 14, 8, 0, 0, 0, time.UTC)
	early, late, other := 100.0, 250.0, 42.0

	rows := []models.HealthMetricRow{
		{Time: ts, UserID: 1, MetricName: "step_count", Qty: &early},
		{Time: ts, UserID: 1, MetricName: "active_energy", Qty: &other},
		// Same conflict key as the first row, sent again with a larger sum.
		{Time: ts, UserID: 1, MetricName: "step_count", Qty: &late},
	}

	got := dedupeHealthMetricRows(rows)
	if len(got) != 2 {
		t.Fatalf("expected 2 rows after dedupe, got %d", len(got))
	}
	if got[0].MetricName != "active_energy" || got[1].MetricName != "step_count" {
		t.Fatalf("unexpected rows kept: %v", got)
	}
	if *got[1].Qty != late {
		t.Errorf("the later value has to win, got %v", *got[1].Qty)
	}

	// A different user, source or timestamp is a different row and stays.
	distinct := []models.HealthMetricRow{
		{Time: ts, UserID: 1, MetricName: "step_count", Source: "Apple Watch"},
		{Time: ts, UserID: 1, MetricName: "step_count", Source: "iPhone"},
		{Time: ts, UserID: 2, MetricName: "step_count", Source: "iPhone"},
		{Time: ts.Add(time.Hour), UserID: 2, MetricName: "step_count", Source: "iPhone"},
	}
	if got := dedupeHealthMetricRows(distinct); len(got) != len(distinct) {
		t.Errorf("distinct conflict keys were collapsed: %v", got)
	}
}
