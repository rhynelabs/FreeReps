package withings

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/claude/freereps/internal/config"
	"github.com/claude/freereps/internal/storage"
)

// measureDataType is the sync state key. Withings exposes further data types
// (activity, sleep) that FreeReps does not read; the column keeps the table
// usable if that ever changes.
const measureDataType = "measure"

// syncStats tracks counts across a sync cycle for import logging.
type syncStats struct {
	metricsReceived int
	metricsInserted int64
}

// Syncer polls the Withings API and stores measurements in FreeReps.
type Syncer struct {
	client   *Client
	tokenMgr *TokenManager
	db       *storage.DB
	cfg      config.WithingsConfig
	log      *slog.Logger
}

// NewSyncer creates a new Withings sync orchestrator.
func NewSyncer(client *Client, tokenMgr *TokenManager, db *storage.DB, cfg config.WithingsConfig, log *slog.Logger) *Syncer {
	return &Syncer{
		client:   client,
		tokenMgr: tokenMgr,
		db:       db,
		cfg:      cfg,
		log:      log,
	}
}

// Run starts the polling loop. Blocks until ctx is cancelled.
func (s *Syncer) Run(ctx context.Context) {
	if err := s.SyncOnce(ctx); err != nil {
		s.log.Error("initial withings sync failed", "error", err)
	}

	ticker := time.NewTicker(s.cfg.SyncInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.log.Info("withings sync stopped")
			return
		case <-ticker.C:
			if err := s.SyncOnce(ctx); err != nil {
				s.log.Error("withings sync cycle failed", "error", err)
			}
		}
	}
}

// SyncOnce syncs every authorized user.
func (s *Syncer) SyncOnce(ctx context.Context) error {
	users, err := s.db.ListWithingsAuthorizedUsers(ctx)
	if err != nil {
		return fmt.Errorf("listing withings users: %w", err)
	}
	if len(users) == 0 {
		return nil
	}

	s.log.Info("withings sync starting", "users", len(users))
	for _, uid := range users {
		s.SyncUser(ctx, uid)
	}
	s.log.Info("withings sync complete")
	return nil
}

// SyncUser fetches measurements for one user and writes an import log.
func (s *Syncer) SyncUser(ctx context.Context, userID int) {
	start := time.Now()
	stats := &syncStats{}

	token, err := s.tokenMgr.GetValidToken(ctx, userID)
	if err != nil {
		s.logImport(ctx, userID, start, stats, fmt.Errorf("getting token: %w", err))
		return
	}

	if err := s.syncMeasures(ctx, userID, token, stats); err != nil {
		s.log.Error("withings measure sync failed", "user_id", userID, "error", err)
		s.logImport(ctx, userID, start, stats, err)
		return
	}

	s.db.InvalidateAvailableMetrics(userID)
	s.logImport(ctx, userID, start, stats, nil)
}

// TriggerSync performs an immediate sync for a specific user (manual sync button).
func (s *Syncer) TriggerSync(ctx context.Context, userID int) error {
	s.SyncUser(ctx, userID)
	return nil
}

// syncMeasures fetches the measurement delta and stores it.
//
// The sync state advances only after the rows are written. A crash between
// fetch and insert therefore repeats the window on the next cycle rather than
// skipping it; the natural key on health_metrics turns the repeat into a no-op.
func (s *Syncer) syncMeasures(ctx context.Context, userID int, token string, stats *syncStats) error {
	state, err := s.db.GetWithingsSyncState(ctx, userID, measureDataType)
	if err != nil {
		return fmt.Errorf("getting sync state: %w", err)
	}

	var lastUpdate, startDate int64
	if state != nil && state.LastUpdate > 0 {
		lastUpdate = state.LastUpdate
	} else {
		startDate = time.Now().AddDate(0, 0, -s.cfg.BackfillDays).Unix()
	}

	groups, updateTime, err := s.client.GetMeasures(ctx, token, RequestedTypes(), lastUpdate, startDate)
	if err != nil {
		return fmt.Errorf("fetching measures: %w", err)
	}

	rows := MapMeasureGroups(groups, userID)
	stats.metricsReceived = len(rows)
	if len(rows) > 0 {
		inserted, _, err := s.db.InsertHealthMetrics(ctx, rows)
		if err != nil {
			return fmt.Errorf("inserting measures: %w", err)
		}
		stats.metricsInserted = inserted
	}

	if updateTime <= 0 {
		// No usable server timestamp: leave the state alone so the next cycle
		// repeats the window instead of advancing past data it never saw.
		s.log.Warn("withings response carried no updatetime", "user_id", userID)
		return nil
	}
	return s.db.UpsertWithingsSyncState(ctx, userID, measureDataType, updateTime)
}

// logImport writes an import log entry for a Withings sync cycle.
func (s *Syncer) logImport(ctx context.Context, userID int, start time.Time, stats *syncStats, syncErr error) {
	durationMs := int(time.Since(start).Milliseconds())
	status := "success"
	var errMsg *string

	if syncErr != nil {
		status = "error"
		msg := syncErr.Error()
		errMsg = &msg
	}

	if _, err := s.db.InsertImportLog(ctx, storage.ImportLog{
		UserID:          userID,
		Source:          "withings_sync",
		Status:          status,
		MetricsReceived: stats.metricsReceived,
		MetricsInserted: stats.metricsInserted,
		DurationMs:      &durationMs,
		ErrorMessage:    errMsg,
	}); err != nil {
		s.log.Error("failed to log withings import", "error", err)
	}
}
