package storage

import (
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
)

// The insert-order tests exist because two concurrent statements that share
// rows deadlock unless they take them in the same order (INCIDENTS.md,
// 2026-09-14). The order each insert binds is its table's unique key, and the
// sort happens after the dedupe so that the later copy of a row still wins.

func TestHealthMetricRowsBindInIndexOrder(t *testing.T) {
	t0 := time.Date(2026, 9, 14, 18, 0, 0, 0, time.UTC)
	q := func(v float64) *float64 { return &v }
	rows := []models.HealthMetricRow{
		{Time: t0.Add(time.Hour), UserID: 1, MetricName: "step_count", Qty: q(1)},
		{Time: t0, UserID: 2, MetricName: "heart_rate", Source: "Watch"},
		{Time: t0, UserID: 1, MetricName: "step_count", Qty: q(10)},
		{Time: t0, UserID: 1, MetricName: "heart_rate", Source: "Watch"},
		{Time: t0, UserID: 1, MetricName: "heart_rate", Source: "Phone"},
		{Time: t0, UserID: 1, MetricName: "step_count", Qty: q(20)}, // repeat of the third row
	}

	rows = dedupeHealthMetricRows(rows)
	sortHealthMetricRows(rows)
	c := healthMetricColumnsFrom(rows)

	var got []string
	for i := range c.times {
		got = append(got, fmt.Sprintf("%s|%s|%s|%d", c.metricNames[i], c.sources[i], c.times[i].Format(time.RFC3339), c.userIDs[i]))
	}
	want := []string{
		"heart_rate|Phone|2026-09-14T18:00:00Z|1",
		"heart_rate|Watch|2026-09-14T18:00:00Z|1",
		"heart_rate|Watch|2026-09-14T18:00:00Z|2",
		"step_count||2026-09-14T18:00:00Z|1",
		"step_count||2026-09-14T19:00:00Z|1",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("bound order:\n  %v\nwant:\n  %v", got, want)
	}
	if c.qty[3].Float64 != 20 {
		t.Errorf("the later copy of the repeated bucket has to win, got qty %v", c.qty[3].Float64)
	}
}

func TestWorkoutPointsBindByWorkoutThenTime(t *testing.T) {
	a := uuid.MustParse("00000000-0000-0000-0000-000000000001")
	b := uuid.MustParse("00000000-0000-0000-0000-000000000002")
	t0 := time.Date(2022, 5, 1, 9, 0, 0, 0, time.UTC)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }

	hr := []models.WorkoutHRRow{
		{WorkoutID: b, Time: at(1)}, {WorkoutID: a, Time: at(2)}, {WorkoutID: b, Time: at(0)}, {WorkoutID: a, Time: at(0)},
	}
	routes := []models.WorkoutRouteRow{
		{WorkoutID: b, Time: at(0)}, {WorkoutID: a, Time: at(5)}, {WorkoutID: a, Time: at(4)},
	}
	sortWorkoutPoints(hr, routes)

	wantHR := []models.WorkoutHRRow{
		{WorkoutID: a, Time: at(0)}, {WorkoutID: a, Time: at(2)}, {WorkoutID: b, Time: at(0)}, {WorkoutID: b, Time: at(1)},
	}
	if !slices.EqualFunc(hr, wantHR, func(x, y models.WorkoutHRRow) bool { return x.WorkoutID == y.WorkoutID && x.Time.Equal(y.Time) }) {
		t.Errorf("heart rate order: %v", hr)
	}
	wantRoutes := []models.WorkoutRouteRow{
		{WorkoutID: a, Time: at(4)}, {WorkoutID: a, Time: at(5)}, {WorkoutID: b, Time: at(0)},
	}
	if !slices.EqualFunc(routes, wantRoutes, func(x, y models.WorkoutRouteRow) bool { return x.WorkoutID == y.WorkoutID && x.Time.Equal(y.Time) }) {
		t.Errorf("route order: %v", routes)
	}
}

func TestDoNothingTablesBindInKeyOrder(t *testing.T) {
	t0 := time.Date(2026, 9, 13, 23, 0, 0, 0, time.UTC)
	h := func(n int) time.Time { return t0.Add(time.Duration(n) * time.Hour) }

	stages := []models.SleepStageRow{
		{StartTime: h(1), EndTime: h(2), Stage: "core", UserID: 1},
		{StartTime: h(0), EndTime: h(2), Stage: "rem", UserID: 1},
		{StartTime: h(0), EndTime: h(1), Stage: "rem", UserID: 2},
		{StartTime: h(0), EndTime: h(1), Stage: "rem", UserID: 1},
		{StartTime: h(0), EndTime: h(1), Stage: "deep", UserID: 1},
	}
	sortSleepStageRows(stages)
	var got []string
	for _, s := range stages {
		got = append(got, fmt.Sprintf("%d-%d-%s-%d", s.StartTime.Hour(), s.EndTime.Hour(), s.Stage, s.UserID))
	}
	want := []string{"23-0-deep-1", "23-0-rem-1", "23-0-rem-2", "23-1-rem-1", "0-1-core-1"}
	if !slices.Equal(got, want) {
		t.Errorf("sleep stage order: %v, want %v", got, want)
	}

	ids := []uuid.UUID{
		uuid.MustParse("00000000-0000-0000-0000-000000000003"),
		uuid.MustParse("00000000-0000-0000-0000-000000000001"),
		uuid.MustParse("ffffffff-0000-0000-0000-000000000000"),
		uuid.MustParse("00000000-0000-0000-0000-000000000002"),
	}
	sortedIDs := []uuid.UUID{ids[1], ids[3], ids[0], ids[2]}

	samples := make([]models.CategorySampleRow, len(ids))
	moods := make([]models.StateOfMindRow, len(ids))
	for i, id := range ids {
		samples[i].ID, moods[i].ID = id, id
	}
	sortCategorySampleRows(samples)
	sortStateOfMindRows(moods)
	for i, id := range sortedIDs {
		if samples[i].ID != id {
			t.Errorf("category samples: row %d is %s, want %s", i, samples[i].ID, id)
		}
		if moods[i].ID != id {
			t.Errorf("state of mind: row %d is %s, want %s", i, moods[i].ID, id)
		}
	}
}
