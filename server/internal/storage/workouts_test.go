package storage

import (
	"strings"
	"testing"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
)

// TestDedupeWorkoutRowsKeepsTheLast exists because a request is written in
// one statement now: a payload that carries the same workout twice — the app
// retrying a partial upload inside one request — must collapse to one row,
// with the later copy winning, and rows with distinct ids must all survive.
func TestDedupeWorkoutRowsKeepsTheLast(t *testing.T) {
	a, b := uuid.New(), uuid.New()
	rows := []models.WorkoutRow{
		{ID: a, Name: "Running"},
		{ID: b, Name: "Cycling"},
		{ID: a, Name: "Running", Location: "Outdoor"},
	}

	got := dedupeWorkoutRows(rows)
	if len(got) != 2 {
		t.Fatalf("expected 2 rows after dedupe, got %d", len(got))
	}
	if got[0].ID != b || got[1].ID != a {
		t.Fatalf("unexpected rows kept: %v", got)
	}
	if got[1].Location != "Outdoor" {
		t.Errorf("the later copy has to win, got %q", got[1].Location)
	}

	distinct := []models.WorkoutRow{{ID: a}, {ID: b}, {ID: uuid.New()}}
	if got := dedupeWorkoutRows(distinct); len(got) != len(distinct) {
		t.Errorf("distinct ids were collapsed: %v", got)
	}
}

// TestValuesPlaceholdersNumberRowsInOrder exists because the placeholder list
// is what pairs each argument with its column; an off-by-one here writes a
// workout's distance into its heart rate without any error.
func TestValuesPlaceholdersNumberRowsInOrder(t *testing.T) {
	if got := valuesPlaceholders(1, 3); got != "($1,$2,$3)" {
		t.Errorf("one row: got %q", got)
	}
	if got := valuesPlaceholders(2, 2); got != "($1,$2),($3,$4)" {
		t.Errorf("two rows: got %q", got)
	}
	if got := valuesPlaceholders(0, 5); got != "" {
		t.Errorf("no rows: got %q", got)
	}
}

// TestWorkoutStatementsStayUnderParameterLimit exists because the extended
// protocol refuses a statement with more than 65,535 parameters, and the
// chunk sizes are constants that have to be kept in step with the column
// lists by hand.
func TestWorkoutStatementsStayUnderParameterLimit(t *testing.T) {
	const limit = 65535
	tables := []struct {
		name  string
		sql   string
		rows  int
		width int
	}{
		{"workouts", insertWorkoutsSQL, workoutRowsPerStatement, 21},
		{"workout_heart_rate", insertWorkoutHeartRateSQL, workoutHRRowsPerStatement, 7},
		{"workout_routes", insertWorkoutRoutesSQL, workoutRouteRowsPerStatement, 10},
	}
	for _, tb := range tables {
		if tb.rows*tb.width > limit {
			t.Errorf("%s: %d rows x %d params = %d, over the %d limit", tb.name, tb.rows, tb.width, tb.rows*tb.width, limit)
		}
		// The column list between the parentheses has to be as wide as the
		// argument list the insert builds.
		cols := tb.sql[strings.Index(tb.sql, "(")+1 : strings.LastIndex(tb.sql, ")")]
		if n := len(strings.Split(cols, ",")); n != tb.width {
			t.Errorf("%s: statement names %d columns, insert passes %d", tb.name, n, tb.width)
		}
	}
}
