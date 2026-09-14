package storage

import (
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
)

// benchHealthMetricRows is one 5,000-row batch as processMetrics hands it to
// InsertHealthMetrics: a fifth hourly buckets without a source UUID, the rest
// individual samples with one.
func benchHealthMetricRows() []models.HealthMetricRow {
	base := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	rows := make([]models.HealthMetricRow, 0, maxRowsPerBatch)
	for i := 0; i < 1000; i++ {
		qty := float64(i)
		rows = append(rows, models.HealthMetricRow{
			Time: base.Add(time.Duration(i) * time.Hour), UserID: 1,
			MetricName: "step_count", Source: "iPhone", Units: "count", Qty: &qty,
		})
	}
	for i := 0; i < 2000; i++ {
		v := float64(55 + i%70)
		id := uuid.New()
		rows = append(rows, models.HealthMetricRow{
			Time: base.Add(time.Duration(i) * 3 * time.Minute), UserID: 1,
			MetricName: "heart_rate", Source: "Apple Watch", Units: "count/min",
			MinVal: &v, AvgVal: &v, MaxVal: &v, SourceUUID: &id,
		})
	}
	for i := 0; i < 2000; i++ {
		v := float64(i%100) / 3
		id := uuid.New()
		rows = append(rows, models.HealthMetricRow{
			Time: base.Add(time.Duration(i) * 5 * time.Minute), UserID: 1,
			MetricName: "heart_rate_variability", Source: "Apple Watch", Units: "ms",
			Qty: &v, SourceUUID: &id,
		})
	}
	return rows
}

// BenchmarkDedupeHealthMetricRows measures the conflict-key pass over a batch
// with no repeats, which is the common case and the fast path.
func BenchmarkDedupeHealthMetricRows(b *testing.B) {
	rows := benchHealthMetricRows()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if got := dedupeHealthMetricRows(rows); len(got) != len(rows) {
			b.Fatalf("dedupe dropped rows: %d of %d", len(got), len(rows))
		}
	}
}

// BenchmarkDedupeHealthMetricRowsWithRepeats is the slow path: the batch
// carries every bucket twice, so the kept slice has to be rebuilt.
func BenchmarkDedupeHealthMetricRowsWithRepeats(b *testing.B) {
	rows := benchHealthMetricRows()
	rows = append(rows, rows[:1000]...)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if got := dedupeHealthMetricRows(rows); len(got) != maxRowsPerBatch {
			b.Fatalf("kept %d rows, want %d", len(got), maxRowsPerBatch)
		}
	}
}

// BenchmarkHealthMetricColumnsFrom measures turning a batch into the twelve
// arrays the insert binds.
func BenchmarkHealthMetricColumnsFrom(b *testing.B) {
	rows := benchHealthMetricRows()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c := healthMetricColumnsFrom(rows)
		if len(c.times) != len(rows) {
			b.Fatal("column count mismatch")
		}
	}
}
