import Combine
import Foundation
import HealthKit
import UIKit
import UserNotifications

/// Manages HKObserverQuery-based background delivery for continuous HealthKit → FreeReps sync.
///
/// Other health apps use this pattern: register observer queries for each data type at launch,
/// enable background delivery, and HealthKit wakes the app when new data is written. Unlike
/// BGProcessingTask (which runs when the device is idle/locked), observer callbacks fire
/// close to when data is recorded — the device is typically unlocked, so HealthKit data is accessible.
@MainActor
final class BackgroundSyncManager {

    static let shared = BackgroundSyncManager()

    private let healthStore = HealthKitService.shared.store
    private var observerQueries: [HKObserverQuery] = []
    /// Sample types that changed since the last observer-triggered run. Non-empty
    /// means a run is owed; the set stays filled while a run is in progress or
    /// the quiet period is being waited out.
    private var pendingTypes: Set<String> = []
    /// The one timer for the pending run. Every observer event replaces it, so
    /// a burst of events ends in a single run.
    private var debounceTask: Task<Void, Never>?
    private var isSyncing = false
    private var observationGeneration = 0
    /// When the last sync run of any kind ended — manual, scheduled or
    /// observer-triggered. Read off `SyncState`, so the sync path stays untouched.
    private var lastSyncEnded: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Multiple types change at once (a workout saves distance, energy and
    /// heart rate together); wait this long for all of them to arrive.
    private static let debounceInterval: TimeInterval = 5
    /// Observer events keep arriving while and right after a sync writes to the
    /// server — the device trace shows runs 2–5 s apart. Nothing that lands in
    /// this span after a run is worth a run of its own.
    private static let quietInterval: TimeInterval = 60

    private init() {
        // The end of any run starts the quiet period. A change that arrived
        // during the run is still pending, so the run's end also schedules it.
        let state = SyncState.shared
        Publishers.CombineLatest(state.$isFullSyncRunning, state.$isIncrementalSyncRunning)
            .map { $0 || $1 }
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastSyncEnded = Date()
                if !self.pendingTypes.isEmpty { self.scheduleSync() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Call once from AppDelegate.didFinishLaunchingWithOptions to start monitoring HealthKit.
    func startObserving() {
        observationGeneration += 1
        let generation = observationGeneration
        debounceTask?.cancel()
        for query in observerQueries { healthStore.stop(query) }
        observerQueries.removeAll()
        let revision = HealthSyncSelection.shared.revision
        healthStore.disableAllBackgroundDelivery { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation,
                      HealthSyncSelection.shared.revision == revision,
                      HealthSyncSelection.shared.isEnabled,
                      UserDefaults.standard.bool(forKey: "backgroundSyncEnabled") else { return }
                self.setupObserverQueries()
                self.enableBackgroundDelivery()
            }
        }
    }

    // MARK: - Observer Queries

    private func setupObserverQueries() {
        let readTypes = HealthKitService.selectedReadTypes

        for type in readTypes {
            guard let sampleType = type as? HKSampleType else { continue }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
                [weak self] _, completionHandler, error in
                Task { @MainActor in
                    self?.handleObserverUpdate(sampleType: sampleType, error: error)
                    // MUST always call completionHandler or iOS thinks the query is still running
                    completionHandler()
                }
            }

            healthStore.execute(query)
            observerQueries.append(query)
        }
    }

    private func enableBackgroundDelivery() {
        let readTypes = HealthKitService.selectedReadTypes

        for type in readTypes {
            guard let sampleType = type as? HKSampleType else { continue }

            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error = error {
                    print("[BackgroundSyncManager] enableBackgroundDelivery failed for \(sampleType.identifier): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Observer Callback Handling

    private func handleObserverUpdate(sampleType: HKSampleType, error: Error?) {
        guard HealthSyncSelection.shared.isEnabled else { return }
        if let error = error {
            postFailureNotification("HealthKit observer error: \(error.localizedDescription)")
            return
        }

        pendingTypes.insert(sampleType.identifier)
        scheduleSync()
    }

    /// How long the quiet period after the last run still has to go; nil once
    /// it is over or no run has ended yet.
    private var quietTimeRemaining: TimeInterval? {
        guard let lastSyncEnded else { return nil }
        let remaining = Self.quietInterval - Date().timeIntervalSince(lastSyncEnded)
        return remaining > 0 ? remaining : nil
    }

    /// One run for everything that arrived: first the debounce for the burst of
    /// observer callbacks, then whatever is left of the quiet period after the
    /// last run. A run in progress leaves the change pending; its end schedules
    /// the run (see `init`). Manual syncs never come through here, so the
    /// Sync Now button and pull to refresh are not held back.
    private func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(Self.debounceInterval))
            guard !Task.isCancelled else { return }

            if let remaining = quietTimeRemaining {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }

            guard !isSyncing, !SyncState.shared.isAnySyncRunning, !SyncService.isSyncRunning else { return }

            let types = pendingTypes
            pendingTypes.removeAll()

            guard !types.isEmpty else { return }
            await triggerIncrementalSync()
        }
    }

    // MARK: - Trigger Sync

    private func triggerIncrementalSync() async {
        guard HealthSyncSelection.shared.isEnabled else { return }
        guard UserDefaults.standard.bool(forKey: "backgroundSyncEnabled") else { return }
        guard !isSyncing, !SyncService.isSyncRunning else { return }
        isSyncing = true
        defer { isSyncing = false }

        let config = FreeRepsConfig.load()

        // Request extra background execution time from iOS.
        // The expiry handler cancels the sync task so runIncrementalSync exits cleanly
        // via CancellationError (no failure notification), then ends the background task.
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        var syncTask: Task<Void, Never>?
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "observer-sync") {
            syncTask?.cancel()
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }

        let state = SyncState.shared
        let service = SyncService(syncState: state)
        service.isBackgroundSync = true
        service.suppressLiveActivity = true
        let task = Task { await service.runIncrementalSync(config: config) }
        syncTask = task
        await task.value

        // Post notification on failure. Cancellation (expiry) sets no errorMessage,
        // so this only fires on genuine sync errors.
        if let error = state.errorMessage {
            postFailureNotification(error)
        }
    }

    // MARK: - Failure Notifications

    func postFailureNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "FreeReps Sync Failed"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sync-failure",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BackgroundSyncManager] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    /// Request notification permission. Call once at app launch.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error {
                print("[BackgroundSyncManager] Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}
