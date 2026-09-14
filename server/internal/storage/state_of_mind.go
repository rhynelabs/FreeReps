package storage

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/jackc/pgx/v5"
)

// InsertStateOfMind batch-inserts state of mind rows. Returns count inserted.
// Uses ON CONFLICT DO NOTHING on UUID PK.
func (db *DB) InsertStateOfMind(ctx context.Context, rows []models.StateOfMindRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	sortStateOfMindRows(rows)

	query := `INSERT INTO state_of_mind (id, user_id, kind, valence, labels, associations, start_date, source) VALUES `
	args := make([]any, 0, len(rows)*8)
	valueStrings := make([]string, 0, len(rows))

	for i, r := range rows {
		base := i * 8
		valueStrings = append(valueStrings, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5, base+6, base+7, base+8,
		))
		args = append(args, r.ID, r.UserID, r.Kind, r.Valence, r.Labels, r.Associations,
			r.StartDate, r.Source)
	}

	query += strings.Join(valueStrings, ",") + " ON CONFLICT DO NOTHING"

	// An ingest write: the app re-sends what a lost commit would drop.
	var inserted int64
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return fmt.Errorf("inserting state of mind: %w", err)
		}
		inserted = tag.RowsAffected()
		return nil
	})
	return inserted, err
}

// sortStateOfMindRows orders the rows by primary key, in place, so that
// concurrent statements sharing rows wait on them in the same order; see
// sortHealthMetricRows.
func sortStateOfMindRows(rows []models.StateOfMindRow) {
	slices.SortStableFunc(rows, func(a, b models.StateOfMindRow) int {
		return bytes.Compare(a.ID[:], b.ID[:])
	})
}

// QueryStateOfMind retrieves state of mind records in a time range for a user.
func (db *DB) QueryStateOfMind(ctx context.Context, start, end time.Time, userID int) ([]models.StateOfMindRow, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT id, user_id, kind, valence, labels, associations, start_date, source
		 FROM state_of_mind
		 WHERE start_date >= $1 AND start_date < $2 AND user_id = $3
		 ORDER BY start_date DESC`,
		start, end, userID)
	if err != nil {
		return nil, fmt.Errorf("querying state of mind: %w", err)
	}
	defer rows.Close()

	var result []models.StateOfMindRow
	for rows.Next() {
		var r models.StateOfMindRow
		if err := rows.Scan(&r.ID, &r.UserID, &r.Kind, &r.Valence, &r.Labels,
			&r.Associations, &r.StartDate, &r.Source); err != nil {
			return nil, fmt.Errorf("scanning state of mind: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
