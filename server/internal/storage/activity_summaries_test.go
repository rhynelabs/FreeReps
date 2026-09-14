package storage

import (
	"strings"
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
)

// TestActivitySummaryConflictSQLRefreshesChangedDays exists because the
// conflict clause is the only thing that lets today's rings grow past the
// morning sync. A fall back to DO NOTHING fails nothing: the insert still
// succeeds, and the damage is a day that quietly stops at its first upload.
// The statement text is asserted so an edit has to be deliberate.
func TestActivitySummaryConflictSQLRefreshesChangedDays(t *testing.T) {
	checks := []string{
		// The primary key of activity_summaries.
		"ON CONFLICT (user_id, date) DO UPDATE SET",
		// Every ring and every goal is refreshed together.
		"active_energy = EXCLUDED.active_energy",
		"stand_hours_goal = EXCLUDED.stand_hours_goal",
		// An unchanged re-upload writes no new row version.
		"IS DISTINCT FROM",
		// Inserted rows stay countable apart from refreshed ones.
		"RETURNING (xmax = 0)",
	}

	for _, check := range checks {
		if !strings.Contains(activitySummaryConflictSQL, check) {
			t.Errorf("activitySummaryConflictSQL missing %q in:\n%s", check, activitySummaryConflictSQL)
		}
	}

	if strings.Contains(activitySummaryConflictSQL, "DO NOTHING") {
		t.Errorf("the conflict clause is back to DO NOTHING:\n%s", activitySummaryConflictSQL)
	}
}

// TestDedupeActivitySummaryRowsKeepsTheLast exists because ON CONFLICT DO
// UPDATE aborts the whole statement when one row would be touched twice, where
// the old DO NOTHING dropped the repeat silently. A payload that repeats a day
// must still be accepted, with the later value winning.
func TestDedupeActivitySummaryRowsKeepsTheLast(t *testing.T) {
	day := time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)
	morning, evening, other := 1.15, 487.0, 612.0

	rows := []models.ActivitySummaryRow{
		{UserID: 1, Date: day, ActiveEnergy: &morning},
		{UserID: 1, Date: day.AddDate(0, 0, -1), ActiveEnergy: &other},
		// The same day again, sent later in the day with fuller rings.
		{UserID: 1, Date: day, ActiveEnergy: &evening},
	}

	got := dedupeActivitySummaryRows(rows)
	if len(got) != 2 {
		t.Fatalf("expected 2 rows after dedupe, got %d", len(got))
	}
	if !got[0].Date.Equal(day.AddDate(0, 0, -1)) || !got[1].Date.Equal(day) {
		t.Fatalf("unexpected rows kept: %v", got)
	}
	if *got[1].ActiveEnergy != evening {
		t.Errorf("the later value has to win, got %v", *got[1].ActiveEnergy)
	}

	// The column is DATE, so two times on the same calendar day are one row to
	// Postgres and have to collapse here too; the clock part is discarded.
	sameDay := []models.ActivitySummaryRow{
		{UserID: 1, Date: day, ActiveEnergy: &morning},
		{UserID: 1, Date: day.Add(23 * time.Hour), ActiveEnergy: &evening},
	}
	if got := dedupeActivitySummaryRows(sameDay); len(got) != 1 || *got[0].ActiveEnergy != evening {
		t.Errorf("two times on one calendar day were not collapsed to the later one: %v", got)
	}

	// A different user or a different day is a different row and stays.
	distinct := []models.ActivitySummaryRow{
		{UserID: 1, Date: day},
		{UserID: 2, Date: day},
		{UserID: 2, Date: day.AddDate(0, 0, 1)},
	}
	if got := dedupeActivitySummaryRows(distinct); len(got) != len(distinct) {
		t.Errorf("distinct conflict keys were collapsed: %v", got)
	}
}
