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

// stageBetween builds a stage from its start and end, with the duration the
// ingest path would have computed.
func stageBetween(start, end, name string) models.SleepStageRow {
	s, err := time.Parse(time.RFC3339, start)
	if err != nil {
		panic(err)
	}
	e, err := time.Parse(time.RFC3339, end)
	if err != nil {
		panic(err)
	}
	return models.SleepStageRow{
		StartTime:  s,
		EndTime:    e,
		Stage:      name,
		DurationHr: e.Sub(s).Hours(),
		Source:     "Apple Watch",
	}
}

// nightOf20260914 is the night as the deployed server held it on
// 2026-09-14 — 27 Apple Watch stages, a 19-minute awake stretch across
// midnight UTC, the previous night's last stage 16 hours before — when its
// session went missing from the sleep endpoint. The session had in fact been
// built; the read path hid it (see dateBounds). The shape stays here so the
// grouping and the date are pinned for a night that ends on the day it is
// queried.
func nightOf20260914() []models.SleepStageRow {
	return []models.SleepStageRow{
		stageBetween("2026-09-13T23:39:28Z", "2026-09-13T23:43:27Z", "Core"),
		stageBetween("2026-09-13T23:43:27Z", "2026-09-14T00:02:23Z", "Awake"),
		stageBetween("2026-09-14T00:02:23Z", "2026-09-14T00:03:53Z", "Core"),
		stageBetween("2026-09-14T00:03:53Z", "2026-09-14T00:09:22Z", "Deep"),
		stageBetween("2026-09-14T00:09:22Z", "2026-09-14T00:09:52Z", "Awake"),
		stageBetween("2026-09-14T00:09:52Z", "2026-09-14T01:09:40Z", "Core"),
		stageBetween("2026-09-14T01:09:40Z", "2026-09-14T01:15:09Z", "Deep"),
		stageBetween("2026-09-14T01:15:09Z", "2026-09-14T01:19:38Z", "Core"),
		stageBetween("2026-09-14T01:19:38Z", "2026-09-14T01:30:36Z", "Deep"),
		stageBetween("2026-09-14T01:30:36Z", "2026-09-14T01:50:03Z", "Core"),
		stageBetween("2026-09-14T01:50:03Z", "2026-09-14T01:52:32Z", "Deep"),
		stageBetween("2026-09-14T01:52:32Z", "2026-09-14T02:06:00Z", "Core"),
		stageBetween("2026-09-14T02:06:00Z", "2026-09-14T03:07:18Z", "REM"),
		stageBetween("2026-09-14T03:07:18Z", "2026-09-14T03:33:13Z", "Core"),
		stageBetween("2026-09-14T03:33:13Z", "2026-09-14T03:42:11Z", "Deep"),
		stageBetween("2026-09-14T03:42:11Z", "2026-09-14T03:44:11Z", "Awake"),
		stageBetween("2026-09-14T03:44:11Z", "2026-09-14T04:19:34Z", "Core"),
		stageBetween("2026-09-14T04:19:34Z", "2026-09-14T04:43:00Z", "REM"),
		stageBetween("2026-09-14T04:43:00Z", "2026-09-14T04:51:28Z", "Core"),
		stageBetween("2026-09-14T04:51:28Z", "2026-09-14T05:57:46Z", "REM"),
		stageBetween("2026-09-14T05:57:46Z", "2026-09-14T06:35:08Z", "Core"),
		stageBetween("2026-09-14T06:35:08Z", "2026-09-14T06:36:38Z", "Awake"),
		stageBetween("2026-09-14T06:36:38Z", "2026-09-14T07:13:01Z", "Core"),
		stageBetween("2026-09-14T07:13:01Z", "2026-09-14T07:15:31Z", "Awake"),
		stageBetween("2026-09-14T07:15:31Z", "2026-09-14T07:40:26Z", "Core"),
		stageBetween("2026-09-14T07:40:26Z", "2026-09-14T07:41:56Z", "Awake"),
		stageBetween("2026-09-14T07:41:56Z", "2026-09-14T07:46:25Z", "Core"),
	}
}

// TestNightSessionDatesTheNightByItsEnd feeds the night of 2026-09-14
// together with the tail of the night before through the grouping and the
// session builder: the awake stretch across midnight must not split it, the
// 16-hour gap before it must, and the session must be dated 2026-09-14 by
// the UTC day its last stage ends on.
func TestNightSessionDatesTheNightByItsEnd(t *testing.T) {
	stages := append([]models.SleepStageRow{
		stageBetween("2026-09-13T07:17:48Z", "2026-09-13T07:22:17Z", "Deep"),
		stageBetween("2026-09-13T07:22:17Z", "2026-09-13T07:25:16Z", "Awake"),
		stageBetween("2026-09-13T07:25:16Z", "2026-09-13T07:34:44Z", "Core"),
	}, nightOf20260914()...)

	nights := groupNights(stages)
	if len(nights) != 2 {
		t.Fatalf("groupNights = %d nights, want 2 (the tail of 2026-09-13 and the night of 2026-09-14)", len(nights))
	}
	night := nights[1]
	if len(night) != 27 {
		t.Fatalf("night has %d stages, want 27 — the awake stretch across midnight must not split it", len(night))
	}

	session := nightSession(2, night)
	if got := session.Date.Format("2006-01-02"); got != "2026-09-14" {
		t.Errorf("session date = %s, want 2026-09-14", got)
	}
	if !session.SleepStart.Equal(mustTime(t, "2026-09-13T23:39:28Z")) {
		t.Errorf("sleep start = %v, want 2026-09-13T23:39:28Z", session.SleepStart)
	}
	if !session.SleepEnd.Equal(mustTime(t, "2026-09-14T07:46:25Z")) {
		t.Errorf("sleep end = %v, want 2026-09-14T07:46:25Z", session.SleepEnd)
	}

	var asleep float64
	for _, s := range night {
		if s.Stage != "Awake" {
			asleep += s.DurationHr
		}
	}
	if diff := session.TotalSleep - asleep; diff > 1e-9 || diff < -1e-9 {
		t.Errorf("total sleep = %v h, want %v h (every stage but Awake)", session.TotalSleep, asleep)
	}
	if session.Core+session.Deep+session.REM != session.TotalSleep {
		t.Errorf("core+deep+rem = %v, want total sleep %v", session.Core+session.Deep+session.REM, session.TotalSleep)
	}
	if diff := session.InBed - 8.115833333; diff > 1e-6 || diff < -1e-6 {
		t.Errorf("in bed = %v h, want 8.1158 h (23:39:28 to 07:46:25)", session.InBed)
	}
}

// TestNightSessionDateIgnoresTheProcessZone pins the date to the UTC day
// whatever location the stage times carry. pgx returns timestamptz values in
// the process zone and encodes a time.Time bound to the DATE column as the
// calendar day in that zone; a host west of UTC used to date this night
// 2026-09-13, where the previous night already sits and ON CONFLICT DO
// NOTHING drops it.
func TestNightSessionDateIgnoresTheProcessZone(t *testing.T) {
	west := time.FixedZone("UTC-5", -5*60*60)
	var night []models.SleepStageRow
	for _, s := range nightOf20260914() {
		s.StartTime = s.StartTime.In(west)
		s.EndTime = s.EndTime.In(west)
		night = append(night, s)
	}

	session := nightSession(2, night)
	// Format reads the calendar day in the value's own location, which is
	// exactly what the pgx date encoding does.
	if got := session.Date.Format("2006-01-02"); got != "2026-09-14" {
		t.Errorf("session date = %s in %v, want 2026-09-14", got, session.Date.Location())
	}
	if !session.Date.Equal(mustTime(t, "2026-09-14T00:00:00Z")) {
		t.Errorf("session date instant = %v, want 2026-09-14T00:00:00Z", session.Date)
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
