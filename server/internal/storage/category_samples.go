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

// InsertCategorySamples batch-inserts category sample rows. Returns count inserted.
// Uses ON CONFLICT DO NOTHING on UUID PK.
func (db *DB) InsertCategorySamples(ctx context.Context, rows []models.CategorySampleRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	sortCategorySampleRows(rows)

	query := `INSERT INTO category_samples (id, user_id, type, value, value_label, start_date, end_date, source) VALUES `
	args := make([]any, 0, len(rows)*8)
	valueStrings := make([]string, 0, len(rows))

	for i, r := range rows {
		base := i * 8
		valueStrings = append(valueStrings, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5, base+6, base+7, base+8,
		))
		args = append(args, r.ID, r.UserID, r.Type, r.Value, r.ValueLabel,
			r.StartDate, r.EndDate, r.Source)
	}

	query += strings.Join(valueStrings, ",") + " ON CONFLICT DO NOTHING"

	// An ingest write: the app re-sends what a lost commit would drop.
	var inserted int64
	err := db.withAsyncCommit(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return fmt.Errorf("inserting category samples: %w", err)
		}
		inserted = tag.RowsAffected()
		return nil
	})
	return inserted, err
}

// sortCategorySampleRows orders the rows by primary key, in place, so that
// concurrent statements sharing rows wait on them in the same order; see
// sortHealthMetricRows.
func sortCategorySampleRows(rows []models.CategorySampleRow) {
	slices.SortStableFunc(rows, func(a, b models.CategorySampleRow) int {
		return bytes.Compare(a.ID[:], b.ID[:])
	})
}

// QueryCategorySamples retrieves category samples in a time range for a user,
// optionally filtered by type.
func (db *DB) QueryCategorySamples(ctx context.Context, start, end time.Time, userID int, typeFilter string) ([]models.CategorySampleRow, error) {
	query := `SELECT id, user_id, type, value, value_label, start_date, end_date, source
		 FROM category_samples
		 WHERE start_date >= $1 AND start_date < $2 AND user_id = $3`
	args := []any{start, end, userID}
	if typeFilter != "" {
		query += ` AND type = $4`
		args = append(args, typeFilter)
	}
	query += ` ORDER BY start_date DESC`

	rows, err := db.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying category samples: %w", err)
	}
	defer rows.Close()

	var result []models.CategorySampleRow
	for rows.Next() {
		var r models.CategorySampleRow
		if err := rows.Scan(&r.ID, &r.UserID, &r.Type, &r.Value, &r.ValueLabel,
			&r.StartDate, &r.EndDate, &r.Source); err != nil {
			return nil, fmt.Errorf("scanning category sample: %w", err)
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
