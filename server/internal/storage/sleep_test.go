package storage

import (
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
)

func stage(start string, hours float64) models.SleepStageRow {
	t, err := time.Parse(time.RFC3339, start)
	if err != nil {
		panic(err)
	}
	return models.SleepStageRow{
		StartTime:  t,
		EndTime:    t.Add(time.Duration(hours * float64(time.Hour))),
		Stage:      "Core",
		DurationHr: hours,
	}
}

// TestNightsOverlappingKeepsStraddlingNightWhole exists because the scoped
// backfill writes with ON CONFLICT DO NOTHING: a night cut at the window edge
// would become a short session that no later run corrects. A night that
// straddles the window must come back with all its stages, one entirely
// outside it must not come back at all, and grouping must not change just
// because the query was narrowed.
func TestNightsOverlappingKeepsStraddlingNightWhole(t *testing.T) {
	stages := []models.SleepStageRow{
		// Night 1: entirely before the window.
		stage("2026-09-10T23:00:00Z", 3),
		stage("2026-09-11T02:00:00Z", 4),
		// Night 2: begins before the window, ends inside it.
		stage("2026-09-11T23:00:00Z", 3),
		stage("2026-09-12T02:00:00Z", 4),
		// Night 3: entirely after the window.
		stage("2026-09-13T23:00:00Z", 6),
	}
	from, _ := time.Parse(time.RFC3339, "2026-09-12T02:00:00Z")
	to, _ := time.Parse(time.RFC3339, "2026-09-12T06:00:00Z")

	nights := groupNights(stages)
	if len(nights) != 3 {
		t.Fatalf("groupNights = %d nights, want 3", len(nights))
	}

	kept := nightsOverlapping(nights, from, to)
	if len(kept) != 1 {
		t.Fatalf("nightsOverlapping kept %d nights, want 1", len(kept))
	}
	if len(kept[0]) != 2 {
		t.Errorf("kept night has %d stages, want 2 (the stage before the window must stay)", len(kept[0]))
	}
	if !kept[0][0].StartTime.Equal(stages[2].StartTime) {
		t.Errorf("kept night starts at %v, want %v", kept[0][0].StartTime, stages[2].StartTime)
	}
}
