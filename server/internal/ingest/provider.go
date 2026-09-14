package ingest

import "time"

// Result holds the outcome of an ingest operation.
type Result struct {
	MetricsReceived int      `json:"metrics_received"`
	MetricsInserted int64    `json:"metrics_inserted"`
	MetricsUpdated  int64    `json:"metrics_updated,omitempty"`
	MetricsSkipped  int64    `json:"metrics_skipped"`
	MetricsRejected int      `json:"metrics_rejected"`
	RejectedNames   []string `json:"rejected_names,omitempty"`

	SleepSessionsInserted int `json:"sleep_sessions_inserted,omitempty"`
	SleepStagesInserted   int64 `json:"sleep_stages_inserted,omitempty"`

	// SleepStagesFrom and SleepStagesTo span the sleep stages this ingest
	// received, inserted or not, so the caller can rebuild sessions for
	// those nights alone. Both are zero while no stage arrived.
	SleepStagesFrom time.Time `json:"-"`
	SleepStagesTo   time.Time `json:"-"`

	WorkoutsReceived int   `json:"workouts_received,omitempty"`
	WorkoutsInserted int   `json:"workouts_inserted,omitempty"`
	WorkoutHRPoints  int64 `json:"workout_hr_points,omitempty"`
	WorkoutRoutePoints int64 `json:"workout_route_points,omitempty"`

	SetsReceived int   `json:"sets_received"`
	SetsInserted int64 `json:"sets_inserted"`

	ECGRecordingsInserted    int   `json:"ecg_recordings_inserted,omitempty"`
	AudiogramsInserted       int   `json:"audiograms_inserted,omitempty"`
	ActivitySummariesInserted int64 `json:"activity_summaries_inserted,omitempty"`
	ActivitySummariesUpdated int64 `json:"activity_summaries_updated,omitempty"`
	MedicationsInserted      int   `json:"medications_inserted,omitempty"`
	VisionPrescriptionsInserted int `json:"vision_prescriptions_inserted,omitempty"`
	StateOfMindInserted      int64 `json:"state_of_mind_inserted,omitempty"`
	CategorySamplesInserted  int64 `json:"category_samples_inserted,omitempty"`

	Message string `json:"message,omitempty"`
}

// AddSleepStages counts inserted stage rows and widens the stage span to
// cover [from, to]. The span grows for duplicates too: a client that resends
// a batch after a dropped connection is the only chance to build the night
// whose first upload was cut off before its session was written.
func (r *Result) AddSleepStages(inserted int64, from, to time.Time) {
	r.SleepStagesInserted += inserted
	if r.SleepStagesFrom.IsZero() || from.Before(r.SleepStagesFrom) {
		r.SleepStagesFrom = from
	}
	if to.After(r.SleepStagesTo) {
		r.SleepStagesTo = to
	}
}
