package health

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/claude/freereps/internal/models"
	"github.com/google/uuid"
)

// benchPayload builds the payload the iOS app sends for one 5,000-row batch:
// hourly buckets it computes itself (no source UUID) and individual HealthKit
// samples that carry one. The mix is what a history upload looks like in the
// sync trace — mostly samples, with a few days of buckets.
func benchPayload(b *testing.B) []byte {
	b.Helper()

	const (
		bucketRows  = 1000 // 250 hours × 4 cumulative metrics
		hrRows      = 2000 // heart_rate samples, Min/Avg/Max shape
		qtyRows     = 2000 // one-value samples across a few metrics
		bucketNames = 4
	)
	base := time.Date(2026, 8, 1, 0, 0, 0, 0, time.FixedZone("CEST", 2*3600))

	type point map[string]any
	metrics := map[string]*models.HealthMetric{}
	add := func(name, units string, p point) {
		m, ok := metrics[name]
		if !ok {
			m = &models.HealthMetric{Name: name, Units: units}
			metrics[name] = m
		}
		raw, err := json.Marshal(p)
		if err != nil {
			b.Fatal(err)
		}
		m.Data = append(m.Data, raw)
	}

	buckets := [bucketNames][2]string{
		{"step_count", "count"}, {"active_energy", "kcal"},
		{"distance_walking_running", "km"}, {"basal_energy_burned", "kcal"},
	}
	for i := 0; i < bucketRows; i++ {
		name := buckets[i%bucketNames]
		t := base.Add(time.Duration(i/bucketNames) * time.Hour)
		add(name[0], name[1], point{
			"date": t.Format(models.HealthTimeLayout),
			"qty":  float64(i%900) + 0.25,
		})
	}
	for i := 0; i < hrRows; i++ {
		t := base.Add(time.Duration(i) * 3 * time.Minute)
		add("heart_rate", "count/min", point{
			"date":        t.Format(models.HealthTimeLayout),
			"qty":         float64(55 + i%70),
			"source_uuid": uuid.New().String(),
		})
	}
	qtyNames := [4][2]string{
		{"heart_rate_variability", "ms"}, {"respiratory_rate", "count/min"},
		{"blood_oxygen_saturation", "%"}, {"apple_sleeping_wrist_temperature", "degC"},
	}
	for i := 0; i < qtyRows; i++ {
		name := qtyNames[i%len(qtyNames)]
		t := base.Add(time.Duration(i) * 5 * time.Minute)
		add(name[0], name[1], point{
			"date":        t.Format(models.HealthTimeLayout),
			"qty":         float64(i%100) / 3,
			"source_uuid": uuid.New().String(),
		})
	}

	var payload models.HealthPayload
	for _, m := range metrics {
		payload.Data.Metrics = append(payload.Data.Metrics, *m)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		b.Fatal(err)
	}
	return body
}

func gzipped(b *testing.B, body []byte) []byte {
	b.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(body); err != nil {
		b.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		b.Fatal(err)
	}
	return buf.Bytes()
}

// convertAll is the per-point part of processMetrics with the allowlist and the
// store taken out: every data point through convertMetricDataPoint.
func convertAll(b *testing.B, payload *models.HealthPayload) []models.HealthMetricRow {
	b.Helper()
	var rows []models.HealthMetricRow
	for _, m := range payload.Data.Metrics {
		for _, raw := range m.Data {
			row, err := convertMetricDataPoint(m.Name, m.Units, raw, 1)
			if err != nil {
				b.Fatal(err)
			}
			rows = append(rows, *row)
		}
	}
	return rows
}

func countPoints(p *models.HealthPayload) int {
	n := 0
	for _, m := range p.Data.Metrics {
		n += len(m.Data)
	}
	return n
}

// BenchmarkIngestDecode is the handler's first step: the JSON body into
// HealthPayload, data points left as raw messages.
func BenchmarkIngestDecode(b *testing.B) {
	body := benchPayload(b)
	b.SetBytes(int64(len(body)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var payload models.HealthPayload
		if err := json.NewDecoder(bytes.NewReader(body)).Decode(&payload); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkIngestGunzipDecode is the same with the gzip the app sends in front
// of it, as DecompressRequest hands it to the handler.
func BenchmarkIngestGunzipDecode(b *testing.B) {
	body := benchPayload(b)
	zipped := gzipped(b, body)
	b.SetBytes(int64(len(body)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		zr, err := gzip.NewReader(bytes.NewReader(zipped))
		if err != nil {
			b.Fatal(err)
		}
		var payload models.HealthPayload
		if err := json.NewDecoder(zr).Decode(&payload); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkIngestConvert is the second decode: each raw data point into its
// shape and on to a HealthMetricRow.
func BenchmarkIngestConvert(b *testing.B) {
	body := benchPayload(b)
	var payload models.HealthPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		b.Fatal(err)
	}
	points := countPoints(&payload)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows := convertAll(b, &payload)
		if len(rows) != points {
			b.Fatalf("converted %d rows, want %d", len(rows), points)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(points), "ns/row")
}

// BenchmarkIngestGoSide is everything the Go side does with a batch before
// the storage call: gunzip, decode, convert. Compare its ns/op with the
// database's time for the same batch.
func BenchmarkIngestGoSide(b *testing.B) {
	body := benchPayload(b)
	zipped := gzipped(b, body)
	b.SetBytes(int64(len(body)))
	b.ReportAllocs()
	b.ResetTimer()
	var points int
	for i := 0; i < b.N; i++ {
		zr, err := gzip.NewReader(bytes.NewReader(zipped))
		if err != nil {
			b.Fatal(err)
		}
		var payload models.HealthPayload
		if err := json.NewDecoder(zr).Decode(&payload); err != nil {
			b.Fatal(err)
		}
		rows := convertAll(b, &payload)
		points = len(rows)
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(points), "ns/row")
	if points != 5000 {
		b.Fatal(fmt.Sprintf("payload has %d points, want 5000", points))
	}
}
