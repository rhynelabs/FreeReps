import ActivityKit
import BackgroundTasks
import CoreLocation
import Foundation
import HealthKit
import UIKit

// Rows per upload. The server takes up to 5,000 per statement, and one request
// costs it far more than the rows do.
private let batchSize = 5_000

// MARK: - AsyncSemaphore

/// Limits concurrent access to a resource (e.g. cap HealthKit queries at 5).
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.count = value }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }
}

// MARK: - BatchUploader

/// Rows a `BatchUploader` packs into requests. A piece splits at any row, so a
/// request fills up exactly whatever sizes the pieces come in.
protocol UploadRows {
    var rowCount: Int { get }
    /// The first `count` rows and the rest.
    func split(at count: Int) -> (head: Self, tail: Self)
}

extension FreeRepsMetric: UploadRows {
    var rowCount: Int { data.count }
    func split(at count: Int) -> (head: FreeRepsMetric, tail: FreeRepsMetric) {
        (FreeRepsMetric(name: name, units: units, data: Array(data.prefix(count))),
         FreeRepsMetric(name: name, units: units, data: Array(data.dropFirst(count))))
    }
}

/// Category samples of one Health type, as one piece for the uploader.
struct CategoryRows: UploadRows {
    var samples: [FreeRepsCategorySample]
    var rowCount: Int { samples.count }
    func split(at count: Int) -> (head: CategoryRows, tail: CategoryRows) {
        (CategoryRows(samples: Array(samples.prefix(count))), CategoryRows(samples: Array(samples.dropFirst(count))))
    }
}

/// One request the server acknowledged.
struct UploadAck: Sendable {
    let window: Int
    let rows: Int
    let inserted: Int
    let elapsedMs: Int
    /// Requests of the window sent and acknowledged so far, this one included.
    let windowBatchesSent: Int
    let windowBatchesAcked: Int
}

/// A window every request of which the server has acknowledged.
struct UploadedWindow: Sendable {
    let index: Int
    let rows: Int
    let inserted: Int
}

typealias MetricUploader = BatchUploader<FreeRepsMetric>
typealias CategoryUploader = BatchUploader<CategoryRows>

/// Collects rows from several Health types and uploads them in full batches, a
/// few requests at a time. Small types share a request, and a type with many
/// rows keeps reading while its earlier pages upload.
///
/// Rows carry the backfill window they were read in. The caller hears when a
/// whole window is on the server and moves its cursor then, instead of draining
/// the pipeline at every window boundary. Each batch holds rows of one window
/// only (`endWindow` flushes), so a window's rows and inserted count are exact.
actor BatchUploader<Rows: UploadRows> {
    /// An upload that failed, wrapped so a reader can tell it from its own errors.
    struct UploadFailed: Error { let underlying: Error }

    private struct WindowState {
        var batchesSent = 0
        var batchesAcked = 0
        var rowsSent = 0
        var rowsInserted = 0
        var isDrained: Bool { batchesAcked == batchesSent }
    }

    private let label: String
    private let batchSize: Int
    private let maxInFlight: Int
    private let makePayload: @Sendable ([Rows]) -> FreeRepsPayload
    private let insertedRows: @Sendable (IngestResult) -> Int?
    private let ingest: @Sendable (FreeRepsPayload) async throws -> IngestResult
    private let onBatch: (@Sendable (UploadAck) async -> Void)?
    private let onWindowUploaded: (@Sendable (UploadedWindow) async -> Void)?

    private var pending: [Rows] = []
    private var pendingRows = 0
    private var currentWindow = 0
    private var windows: [Int: WindowState] = [:]
    /// Windows whose rows are all sent, oldest first; each leaves once acknowledged.
    private var closedWindows: [Int] = []
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextBatchID = 0
    private var inserted = 0
    /// The first error a request hit; every later call rethrows it.
    private var failure: Error?
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0

    /// - Parameters:
    ///   - label: Names the uploader in the trace, e.g. the category it serves.
    ///   - onBatch: Called for every acknowledged request, before the next
    ///     request takes its slot; keep it short.
    ///   - onWindowUploaded: Called once per window, in window order, when the
    ///     last of its requests is acknowledged. Never called for a window one
    ///     of whose requests failed.
    init(label: String, batchSize: Int, maxInFlight: Int,
         makePayload: @escaping @Sendable ([Rows]) -> FreeRepsPayload,
         insertedRows: @escaping @Sendable (IngestResult) -> Int?,
         ingest: @escaping @Sendable (FreeRepsPayload) async throws -> IngestResult,
         onBatch: (@Sendable (UploadAck) async -> Void)? = nil,
         onWindowUploaded: (@Sendable (UploadedWindow) async -> Void)? = nil) {
        self.label = label
        self.batchSize = batchSize
        self.maxInFlight = maxInFlight
        self.makePayload = makePayload
        self.insertedRows = insertedRows
        self.ingest = ingest
        self.onBatch = onBatch
        self.onWindowUploaded = onWindowUploaded
    }

    /// Rows added from now on belong to window `index`.
    func beginWindow(_ index: Int) {
        currentWindow = index
        if windows[index] == nil { windows[index] = WindowState() }
    }

    /// Sends the rest of window `index`; it is reported once all of it is acknowledged.
    func endWindow(_ index: Int) async throws {
        try await flush()
        if windows[index] == nil { windows[index] = WindowState() }
        closedWindows.append(index)
        for window in takeUploadedWindows() { await onWindowUploaded?(window) }
    }

    func add(_ rows: Rows) async throws {
        try rethrowFailure()
        var rest = rows
        while rest.rowCount > 0 {
            let (head, tail) = rest.split(at: min(batchSize - pendingRows, rest.rowCount))
            pending.append(head)
            pendingRows += head.rowCount
            rest = tail
            if pendingRows >= batchSize { try await flush() }
        }
    }

    /// Uploads what is left and waits for every request. Returns the rows inserted.
    func finish() async throws -> Int {
        try await flush()
        while !inFlight.isEmpty {
            await waitForBatch(cancellable: true)
            try Task.checkCancellation()
            try rethrowFailure()
        }
        try rethrowFailure()
        return inserted
    }

    /// Cancels the requests in flight and drops the rows not sent yet. Returns
    /// once every request has reported, so no callback fires after it.
    func cancel() async {
        pending = []
        pendingRows = 0
        for task in inFlight.values { task.cancel() }
        while !inFlight.isEmpty { await waitForBatch(cancellable: false) }
    }

    private func flush() async throws {
        guard pendingRows > 0 else { return }
        let rows = pending
        let count = pendingRows
        let window = currentWindow
        pending = []
        pendingRows = 0
        // Counted as sent before the slot wait: should the wait end in an error,
        // the window stays unacknowledged and its cursor does not move.
        windows[window, default: WindowState()].batchesSent += 1
        windows[window]!.rowsSent += count
        while inFlight.count >= maxInFlight {
            await waitForBatch(cancellable: true)
            try Task.checkCancellation()
            try rethrowFailure()
        }
        try rethrowFailure()
        let id = nextBatchID
        nextBatchID += 1
        let payload = makePayload(rows)
        let started = Date()
        let ingest = self.ingest
        let insertedRows = self.insertedRows
        inFlight[id] = Task {
            let outcome: Result<Int, Error>
            do {
                outcome = .success(try await insertedRows(ingest(payload)) ?? count)
            } catch {
                outcome = .failure(error)
            }
            await self.batchFinished(id, window: window, rows: count, started: started, outcome: outcome)
        }
    }

    private func batchFinished(_ id: Int, window: Int, rows: Int, started: Date, outcome: Result<Int, Error>) async {
        switch outcome {
        case .success(let count):
            inserted += count
            var state = windows[window] ?? WindowState()
            state.batchesAcked += 1
            state.rowsInserted += count
            windows[window] = state
            // Decided before the callbacks suspend this actor, so a window is
            // reported exactly once even while other batches finish.
            let uploaded = takeUploadedWindows()
            await SyncTrace.shared.record("upload.batch", [
                "uploader": label, "window": String(window), "rows": String(rows), "inserted": String(count),
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ])
            if let onBatch {
                await onBatch(UploadAck(window: window, rows: rows, inserted: count,
                                        elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
                                        windowBatchesSent: state.batchesSent, windowBatchesAcked: state.batchesAcked))
            }
            for window in uploaded { await onWindowUploaded?(window) }
        case .failure(let error):
            if failure == nil { failure = error }
        }
        inFlight.removeValue(forKey: id)
        resumeWaiters()
    }

    /// Closed windows whose requests are all acknowledged, oldest first, up to
    /// the first one still in flight — so windows are reported in order.
    private func takeUploadedWindows() -> [UploadedWindow] {
        var uploaded: [UploadedWindow] = []
        while let index = closedWindows.first, let state = windows[index], state.isDrained {
            closedWindows.removeFirst()
            windows.removeValue(forKey: index)
            uploaded.append(UploadedWindow(index: index, rows: state.rowsSent, inserted: state.rowsInserted))
        }
        return uploaded
    }

    private func rethrowFailure() throws {
        guard let failure else { return }
        if failure is CancellationError { throw CancellationError() }
        throw UploadFailed(underlying: failure)
    }

    /// Suspends until a request finishes. A cancellable wait also ends when the
    /// caller is cancelled, so a stopped sync does not sit out a slow request;
    /// `cancel()` waits without that, because it needs the requests to report.
    private func waitForBatch(cancellable: Bool) async {
        let id = nextWaiterID
        nextWaiterID += 1
        guard cancellable else {
            await withCheckedContinuation { waiters[id] = $0 }
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func resumeWaiters() {
        let resumed = waiters
        waiters = [:]
        for continuation in resumed.values { continuation.resume() }
    }
}

// MARK: - SyncService

@MainActor
final class SyncService: ObservableObject {

    private let healthKit = HealthKitService.shared
    let syncState: SyncState
    private var freereps: FreeRepsService?
    private var selectionRevision = 0
    private static weak var activeService: SyncService?

    static func stopForSelectionChange() {
        activeService?.taskForCancellation?.cancel()
        if let client = activeService?.freereps { Task { await client.cancelRequests() } }
    }

    private func checkSelection() throws {
        try Task.checkCancellation()
        try HealthSyncSelection.shared.checkRevision(selectionRevision)
    }

    private func beginSelectedSync() -> Bool {
        guard HealthSyncSelection.shared.isEnabled else {
            syncState.currentOperation = "Apple Health sync is paused"
            return false
        }
        guard syncState.categories.contains(where: { $0.id != "cat_strength" && HealthSyncSelection.shared.includes($0.id) }) else {
            syncState.currentOperation = "Choose data to sync in Settings → Apple Health"
            return false
        }
        selectionRevision = HealthSyncSelection.shared.revision
        Self.activeService = self
        return true
    }

    /// Sparse categories that have very few records — skip 90-day windowing, query full range at once.
    private static let sparseCategories: Set<String> = [
        "cat_ecg", "cat_audiogram", "cat_vision", "cat_state_of_mind", "cat_medications"
    ]

    // When true, skip live activity and allow resumable sync across background task invocations
    var isBackgroundSync = false

    // When true, never create or update a Live Activity (used for observer-triggered real-time syncs)
    var suppressLiveActivity = false

    /// Set by the caller before `runHistoricalBackfill` so the background-task expiry
    /// handler can cancel the Swift Task when iOS reclaims background time.
    var taskForCancellation: Task<Void, Never>?

    // Class-level flag so BackgroundSyncManager can check whether ANY SyncService instance
    // (foreground or background) is currently running, preventing concurrent syncs.
    @MainActor static private(set) var isSyncRunning = false

    // Live Activity
    private var liveActivity: Activity<SyncActivityAttributes>?
    private var lastLiveActivityUpdate: Date = .distantPast

    /// Older data is read in stretches this long, one category at a time per stretch.
    private static let backfillWindow: TimeInterval = 90 * 24 * 60 * 60

    // MARK: - Run progress

    /// The run's progress in equal steps: one window of one category for older
    /// data, one Health type or special category for new data. Steps only add up,
    /// so the bar never moves back while categories run side by side.
    private var runStepsDone = 0
    private var runStepsTotal = 1
    /// Windows partly acknowledged by the server, by "category/index". Each
    /// share only grows and stays below one; when the window is fully on the
    /// server it leaves the map and counts as a whole step, so the bar moves
    /// between windows without ever moving back.
    private var partialSteps: [String: Double] = [:]
    /// Counts up per run, so an upload callback from a run that has ended
    /// cannot touch the progress of the next one.
    private var runID = 0
    /// Categories being read right now, in the order they started, each with
    /// the window it is on and the rows the server has acknowledged so far.
    private var activeCategories: [ActiveCategory] = []

    private struct ActiveCategory {
        let name: String
        var window: String?
        var rows = 0
    }

    /// Older data weighs its progress by rows instead of steps: a window of
    /// Vitals holds a hundred times the rows of one of Nutrition, so equal
    /// steps left the last five per cent taking a third of the run. Windows
    /// run oldest to newest, and over a long range the early ones are empty
    /// — a phone from 2015 has nothing for 1999 — so each category's windows
    /// still to come are estimated at its rows per *non-empty* acknowledged
    /// window, or at its last non-empty one when that held more; averaging
    /// the empty ones in put the bar at 99 % with every heavy window ahead.
    /// A category without a non-empty window yet takes the run's average.
    private var weighsRows = false
    private var rowEstimates: [String: RowEstimate] = [:]
    /// Rows acknowledged in windows still open, by "category/index".
    private var partialRows: [String: Int] = [:]

    private struct RowEstimate {
        var windowsLeft: Int
        /// Every row the server acknowledged, empty windows and the
        /// acknowledged part of a failed window included.
        var rowsAcked = 0
        var nonEmptyWindows = 0
        var rowsInNonEmptyWindows = 0
        var lastNonEmptyRows = 0

        /// Rows expected of one window still to come, or nil without a
        /// non-empty window to judge by.
        var rowsPerWindow: Double? {
            guard nonEmptyWindows > 0 else { return nil }
            return max(Double(rowsInNonEmptyWindows) / Double(nonEmptyWindows), Double(lastNonEmptyRows))
        }
    }

    /// Requests of a run in flight at once, across every uploader. The server
    /// is the limit: with 27 in flight it inserted no more rows per second
    /// than with eight, but a 5,000-row batch took 3 s in the median and 11 s
    /// at worst, and one request timed out.
    private static let requestSlotCount = 8
    private var requestSlots = AsyncSemaphore(value: requestSlotCount)

    private func beginRun(steps: Int, weighRows: Bool = false) {
        runID += 1
        runStepsDone = 0
        runStepsTotal = max(steps, 1)
        partialSteps = [:]
        weighsRows = weighRows
        rowEstimates = [:]
        partialRows = [:]
        activeCategories = []
        requestSlots = AsyncSemaphore(value: Self.requestSlotCount)
        syncState.overallProgress = 0
    }

    /// The run is over and nothing of it is left: the bar reaches the end,
    /// which the rows estimate holds back from until then.
    private func completeRun() {
        syncState.overallProgress = 1
    }

    private func advanceRun(by steps: Int = 1) {
        runStepsDone += steps
        refreshProgress()
    }

    /// Credits part of a window's step from its acknowledged batches; the share
    /// stays short of a whole step until the window is done.
    private func partialStep(_ key: String, fraction: Double) {
        partialSteps[key] = max(partialSteps[key] ?? 0, min(fraction, 0.95))
        refreshProgress()
    }

    /// Registers the windows a category has left, for the rows estimate.
    private func expectWindows(_ count: Int, for catID: String) {
        rowEstimates[catID] = RowEstimate(windowsLeft: count)
    }

    /// Credits rows the server acknowledged for a window still open.
    private func windowRows(_ key: String, rows: Int) {
        partialRows[key, default: 0] += rows
        refreshProgress()
    }

    /// Moves a window from the estimate to the rows acknowledged. The rows
    /// reported for the window win over the partial credit, which a retried
    /// window may have collected twice.
    private func windowAcknowledged(_ catID: String, key: String, rows: Int, windows: Int = 1) {
        let partial = partialRows.removeValue(forKey: key) ?? 0
        let rows = max(rows, partial)
        var estimate = rowEstimates[catID] ?? RowEstimate(windowsLeft: windows)
        estimate.windowsLeft = max(estimate.windowsLeft - windows, 0)
        estimate.rowsAcked += rows
        if rows > 0 {
            estimate.nonEmptyWindows += windows
            estimate.rowsInNonEmptyWindows += rows
            estimate.lastNonEmptyRows = rows / windows
        }
        rowEstimates[catID] = estimate
    }

    /// Rows acknowledged over rows acknowledged plus the estimate of the rest;
    /// nil until some window with rows is acknowledged, when there is nothing
    /// to estimate from. The windows left are the newest of each category,
    /// so taking them all as non-empty is right.
    private func rowsWeightedProgress() -> Double? {
        let nonEmptyWindows = rowEstimates.values.reduce(0) { $0 + $1.nonEmptyWindows }
        guard nonEmptyWindows > 0 else { return nil }
        let runAverage = Double(rowEstimates.values.reduce(0) { $0 + $1.rowsInNonEmptyWindows }) / Double(nonEmptyWindows)
        let remaining = rowEstimates.values.reduce(0.0) { sum, estimate in
            sum + (estimate.rowsPerWindow ?? runAverage) * Double(estimate.windowsLeft)
        }
        let acked = Double(rowEstimates.values.reduce(0) { $0 + $1.rowsAcked } + partialRows.values.reduce(0, +))
        guard acked + remaining > 0 else { return 1 }
        return acked / (acked + remaining)
    }

    /// Never lower than the value shown before, whichever way it is counted;
    /// the rows estimate stops at 0.99 until `completeRun`, because it is one.
    private func refreshProgress() {
        let steps = min(1, (Double(runStepsDone) + partialSteps.values.reduce(0, +)) / Double(runStepsTotal))
        let value = weighsRows ? min(rowsWeightedProgress() ?? 0, 0.99) : steps
        syncState.overallProgress = max(syncState.overallProgress, value)
    }

    /// Where a category's HealthKit anchors live in `SyncState.anchors`; the
    /// category prefix lets a reset drop them together.
    static func anchorKey(category: String, type: String) -> String { "\(category)/\(type)" }

    /// Windows left to read for a category between `start` and `anchor`.
    private func windowsLeft(for catID: String, from start: Date, until anchor: Date) -> Int {
        let cursor = max(syncState.backfillCursors[catID] ?? start, start)
    /// Before it exists the bar stays at 0 rather than racing up the step
    /// count through the empty early windows, which take seconds.
        guard cursor < anchor else { return 0 }
        return Int(ceil(anchor.timeIntervalSince(cursor) / Self.backfillWindow))
    }

    /// Names the categories being read, e.g. "Nutrition, Vitals, and Activity".
    private func categoryStarted(_ name: String) {
        if !activeCategories.contains(where: { $0.name == name }) {
            activeCategories.append(ActiveCategory(name: name))
        }
        refreshHeadline()
    }

    private func categoryFinished(_ name: String) {
        activeCategories.removeAll { $0.name == name }
        if !activeCategories.isEmpty { refreshHeadline() }
    }

    /// Notes the window a category is on, e.g. "window 3 of 9".
    private func categoryWindow(_ name: String, _ window: String) {
        categoryStarted(name)
        activeCategories[activeCategories.firstIndex { $0.name == name }!].window = window
        refreshHeadline()
    }

    /// Adds rows the server acknowledged for a category.
    private func categoryRows(_ name: String, add rows: Int) {
        guard let index = activeCategories.firstIndex(where: { $0.name == name }) else { return }
        activeCategories[index].rows += rows
        refreshHeadline()
    }

    /// "Vitals · window 7 of 9 · 12,345 rows and Workouts · window 2 of 9".
    private func refreshHeadline() {
        syncState.currentOperation = activeCategories.map { category in
            var parts = [category.name]
            if let window = category.window { parts.append(window) }
            if category.rows > 0 { parts.append("\(category.rows.formatted()) rows") }
            return parts.joined(separator: " \u{00B7} ")
        }.formatted(.list(type: .and))
    }

    init(syncState: SyncState) {
        self.syncState = syncState
        if syncState.categories.isEmpty {
            setupCategories()
            syncState.restore()
        }
    }

    private func setupCategories() {
        var cats: [CategorySyncState] = []
        // Quantity categories
        for (cat, types) in HealthDataTypes.quantityTypesByCategory {
            let count = types.count
            cats.append(CategorySyncState(
                id: "qty_\(cat.rawValue)",
                displayName: cat.rawValue,
                systemImage: cat.systemImage,
                status: .idle,
                recordCount: 0,
                lastSyncDate: nil,
                currentProgress: 0,
                totalEstimated: count
            ))
        }
        // Special categories
        let specials: [(String, String, String)] = [
            ("cat_category", "Health Events", "heart.text.square.fill"),
            ("cat_workouts", "Workouts", "dumbbell.fill"),
            ("cat_bp", "Blood Pressure", "drop.fill"),
            ("cat_ecg", "ECG", "waveform.path.ecg.rectangle.fill"),
            ("cat_audiogram", "Audiogram", "ear.badge.waveform"),
            ("cat_activity_summaries", "Activity Rings", "chart.bar.fill"),
            ("cat_workout_routes", "Workout Routes", "map.fill"),
            ("cat_medications", "Medications", "pills.fill"),
            ("cat_vision", "Vision Prescriptions", "eye.fill"),
            ("cat_state_of_mind", "State of Mind", "brain.head.profile"),
            ("cat_strength", "Weight Training", "figure.strengthtraining.traditional"),
        ]
        for (id, name, icon) in specials {
            cats.append(CategorySyncState(
                id: id,
                displayName: name,
                systemImage: icon,
                status: .idle,
                recordCount: 0,
                lastSyncDate: nil,
                currentProgress: 0,
                totalEstimated: 1
            ))
        }
        syncState.categories = cats
    }

    // MARK: - Live Activity

    private func startLiveActivity(isFullSync: Bool) {
        guard !suppressLiveActivity else { return }
        if isBackgroundSync {
            liveActivity = Activity<SyncActivityAttributes>.activities.first
            if liveActivity != nil { return }
            // No existing activity — only create one if the app is currently active.
            // BGProcessingTask keeps the app in .background state, so this only fires when
            // the user has the app open (e.g. they opened the app mid-background-sync).
            guard UIApplication.shared.applicationState == .active else { return }
            // Fall through to create a new activity
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let initial = SyncActivityAttributes.ContentState(
            phase: "Connecting",
            operation: "Connecting to FreeReps\u{2026}",
            recordsInserted: 0,
            isFullSync: isFullSync
        )
        do {
            liveActivity = try Activity.request(
                attributes: SyncActivityAttributes(),
                content: ActivityContent(state: initial, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activities not available or denied — sync continues without it
        }
    }

    private func updateLiveActivity(phase: String, operation: String, records: Int) {
        guard !suppressLiveActivity else { return }
        // If no activity yet and we're now in the foreground, try to create one.
        // This covers the case where the user opens the app mid-background-sync.
        if liveActivity == nil {
            startLiveActivity(isFullSync: syncState.isFullSyncRunning)
        }
        guard Date().timeIntervalSince(lastLiveActivityUpdate) >= 1.0 else { return }
        lastLiveActivityUpdate = Date()
        let activity = liveActivity ?? Activity<SyncActivityAttributes>.activities.first
        guard let activity else { return }
        let isFullSync = syncState.isFullSyncRunning
        let state = SyncActivityAttributes.ContentState(
            phase: phase,
            operation: operation,
            recordsInserted: records,
            isFullSync: isFullSync
        )
        let content = ActivityContent(state: state, staleDate: nil)
        // Await the update directly to ensure it completes before moving on
        Task { @MainActor in
            await activity.update(content)
        }
    }

    private func endLiveActivity(totalRecords: Int) {
        guard !suppressLiveActivity else { return }
        let activity = liveActivity ?? Activity<SyncActivityAttributes>.activities.first
        guard let activity else { return }
        let isFullSync = syncState.isFullSyncRunning
        let finalState = SyncActivityAttributes.ContentState(
            phase: "Done",
            operation: "Synced \(totalRecords.formatted()) new records",
            recordsInserted: totalRecords,
            isFullSync: isFullSync
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)
        // Capture reference and nil out immediately to prevent double-end
        self.liveActivity = nil
        // End with a short delay so the "Done" state is visible before dismissal
        Task { @MainActor in
            await activity.end(finalContent, dismissalPolicy: .after(.now + 5))
        }
    }

    // MARK: - Connection management

    func connectFreeReps(config: FreeRepsConfig) {
        self.freereps = FreeRepsService(config: config)
    }

    func disconnectFreeReps() {
        self.freereps = nil
    }

    // MARK: - Pre-sync validation

    /// Check HealthKit authorization and FreeReps connectivity before syncing.
    /// Returns a list of issues that need user attention.
    func validatePrerequisites(config: FreeRepsConfig) async -> [SyncPrerequisiteIssue] {
        guard HealthSyncSelection.shared.isEnabled else { return [] }
        var issues: [SyncPrerequisiteIssue] = []

        // Check HealthKit availability
        if !healthKit.isAvailable {
            issues.append(.healthDataUnavailable)
            return issues
        }

        // Check if permissions were ever requested
        let permissionsRequested = UserDefaults.standard.bool(forKey: "hk_permissions_requested")
        if !permissionsRequested {
            issues.append(.healthPermissionsNotRequested)
        }

        // Read permission cannot be inferred from write-authorization status.
        if permissionsRequested,
           (try? await healthKit.authorizationRequestStatus()) == .shouldRequest {
            issues.append(.healthPermissionsNotRequested)
        }

        // Test FreeReps connectivity
        do {
            let service = FreeRepsService(config: config)
            _ = try await service.ping()
        } catch {
            issues.append(.connectionFailed(error.localizedDescription))
        }

        return issues
    }

    // MARK: - Full sync

    func runFullSync(config: FreeRepsConfig) async {
        await runHistoricalBackfill(config: config)
    }

    // MARK: - Single-category sync

    func runSingleCategorySync(categoryID: String, config: FreeRepsConfig) async {
        guard HealthSyncSelection.shared.includes(categoryID) else { return }
        guard !Self.isSyncRunning, !syncState.isAnySyncRunning, beginSelectedSync() else { return }
        syncState.isFullSyncRunning = true
        SyncService.isSyncRunning = true
        defer { SyncService.isSyncRunning = false }
        syncState.errorMessage = nil
        syncState.newRecordsThisRun = 0
        syncState.currentOperation = "Connecting\u{2026}"
        startLiveActivity(isFullSync: false)

        let anchor = Date()
        let epoch = config.backfillStartDate

        do {
            connectFreeReps(config: config)
            guard let freereps else { throw FreeRepsError.connectionFailed("FreeReps not initialized") }
            _ = try await freereps.ping()
            try checkSelection()

            syncState.updateCategory(categoryID, status: .syncing)
            let isSparse = Self.sparseCategories.contains(categoryID)
            let windows = isSparse ? 1 : windowsLeft(for: categoryID, from: epoch, until: anchor)
            beginRun(steps: windows, weighRows: !isSparse)
            if !isSparse { expectWindows(windows, for: categoryID) }
            let displayName = syncState.categories.first { $0.id == categoryID }?.displayName ?? categoryID
            categoryStarted(displayName)

            let count: Int
            var failedTypes: String?
            if categoryID.hasPrefix("qty_") {
                let rawCat = String(categoryID.dropFirst(4))
                guard let cat = HealthCategory(rawValue: rawCat),
                      let types = HealthDataTypes.quantityTypesByCategory.first(where: { $0.0 == cat })?.1 else {
                    throw FreeRepsError.connectionFailed("Unknown category: \(categoryID)")
                }
                let backfill = try await backfillQuantityCategory(
                    catID: categoryID, cat: cat, types: types,
                    from: epoch, until: anchor, config: config
                )
                count = backfill.inserted
                failedTypes = backfill.failedTypes
            } else if isSparse {
                // Sparse categories: skip windowing, query full range directly
                switch categoryID {
                case "cat_ecg":           count = try await syncECG(since: epoch, until: anchor)
                case "cat_audiogram":     count = try await syncAudiograms(since: epoch, until: anchor)
                case "cat_medications":   count = try await syncMedications(since: epoch, until: anchor)
                case "cat_vision":        count = try await syncVisionPrescriptions(since: epoch, until: anchor)
                case "cat_state_of_mind": count = try await syncStateOfMind(since: epoch, until: anchor)
                default: count = 0
                }
            } else {
                count = try await backfillSpecialCategory(
                    catID: categoryID, displayName: displayName, from: epoch, until: anchor, config: config
                )
            }

            try checkSelection()
            categoryFinished(displayName)

            syncState.newRecordsThisRun = count
            if let failedTypes {
                // The other types are on the server; the row names the ones that are not.
                syncState.updateCategory(categoryID, status: .failed("Completed with failed types: \(failedTypes)"), recordCount: count)
                syncState.errorMessage = "Some types of \(displayName) couldn't be read. Everything else is saved."
            } else {
                syncState.updateCategory(categoryID, status: .completed, recordCount: count, lastSyncDate: Date())
            }
            completeRun()
            syncState.currentOperation = ""
            // Clear cursor so a future full sync re-visits this category from the beginning
            syncState.backfillCursors.removeValue(forKey: categoryID)
            syncState.persist()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            disconnectFreeReps()

        } catch is CancellationError {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.currentOperation = HealthSyncSelection.shared.isEnabled ? "Sync stopped; progress saved" : "Apple Health sync is paused"
            if case .syncing = syncState.categories.first(where: { $0.id == categoryID })?.status {
                syncState.updateCategory(categoryID, status: .idle)
            }
            syncState.persist()
        } catch {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.errorMessage = error.localizedDescription
            syncState.currentOperation = ""
            syncState.updateCategory(categoryID, status: .failed(error.localizedDescription))
            syncState.persist()
        }

        syncState.isFullSyncRunning = false
    }

    // MARK: - Historical backfill (windowed, resumable)

    func runHistoricalBackfill(config: FreeRepsConfig) async {
        guard !Self.isSyncRunning, !syncState.isAnySyncRunning, beginSelectedSync() else { return }
        syncState.isFullSyncRunning = true
        SyncService.isSyncRunning = true
        defer { SyncService.isSyncRunning = false }
        syncState.errorMessage = nil
        syncState.newRecordsThisRun = 0
        syncState.currentOperation = "Connecting\u{2026}"
        startLiveActivity(isFullSync: true)

        if !isBackgroundSync {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        defer {
            if !isBackgroundSync {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        if !isBackgroundSync {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "health-full-sync") {
                self.taskForCancellation?.cancel()
                self.syncState.persist()
                UserDefaults.standard.set(true, forKey: "pendingFullSyncResume")
                let req = BGProcessingTaskRequest(identifier: AppDelegate.syncTaskIdentifier)
                req.requiresNetworkConnectivity = true
                req.requiresExternalPower = false
                req.earliestBeginDate = nil
                try? BGTaskScheduler.shared.submit(req)
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }

        let earliest = config.backfillStartDate
        let historicalStart: Date

        if let previousAnchor = syncState.backfillAnchorDate, syncState.hasCompletedFullSync {
            // A full backfill previously completed. Re-run with a 7-day lookback so samples
            // that arrived in HealthKit after the previous anchor (with past startDates) are
            // captured. FreeReps uses ON CONFLICT DO NOTHING, making this safe.
            historicalStart = previousAnchor.addingTimeInterval(-7 * 24 * 3600)
            syncState.backfillAnchorDate = Date()
            syncState.backfillCursors.removeAll()
            syncState.hasCompletedFullSync = false
            syncState.persist()
        } else if syncState.backfillAnchorDate != nil {
            // Anchor exists but sync hasn't completed — resuming an interrupted backfill.
            // If backfill range was shortened, clear cursors that predate the new start.
            historicalStart = earliest
            for (key, cursor) in syncState.backfillCursors where cursor < earliest {
                syncState.backfillCursors[key] = nil
            }
        } else {
            // First-time full sync: backfill from configured start date.
            syncState.backfillAnchorDate = Date()
            syncState.persist()
            historicalStart = earliest
        }
        let anchor = syncState.backfillAnchorDate!

        do {
            connectFreeReps(config: config)
            guard let freereps else { throw FreeRepsError.connectionFailed("FreeReps not initialized") }
            _ = try await freereps.ping()
            try checkSelection()

            /// Categories that stopped short: windows of theirs are still unsynced.
            var failedCategories: [String] = []
            /// Categories whose windows all went through, minus the types that
            /// could not be read in some of them.
            var partlyFailedCategories: [String] = []

            let pending = HealthDataTypes.quantityTypesByCategory.filter { cat, _ in
                let catID = "qty_\(cat.rawValue)"
                return HealthSyncSelection.shared.includes(catID) && syncState.backfillCursors[catID] != anchor
            }
            let heavySpecials: [(String, String)] = [
                ("cat_category", "Health Events"),
                ("cat_workouts", "Workouts"),
                ("cat_bp", "Blood Pressure"),
                ("cat_activity_summaries", "Activity Rings"),
                ("cat_workout_routes", "Workout Routes"),
            ].filter { HealthSyncSelection.shared.includes($0.0) && syncState.backfillCursors[$0.0] != anchor }
            let sparseSpecials: [(String, String)] = [
                ("cat_ecg", "ECG"),
                ("cat_audiogram", "Audiograms"),
                ("cat_medications", "Medications"),
                ("cat_vision", "Vision Prescriptions"),
                ("cat_state_of_mind", "State of Mind"),
            ].filter { HealthSyncSelection.shared.includes($0.0) && syncState.backfillCursors[$0.0] != anchor }

            let windowSteps = pending.map { "qty_\($0.0.rawValue)" } + heavySpecials.map(\.0)
            beginRun(steps: windowSteps.reduce(0) { $0 + windowsLeft(for: $1, from: historicalStart, until: anchor) } + sparseSpecials.count,
                     weighRows: true)
            for catID in windowSteps { expectWindows(windowsLeft(for: catID, from: historicalStart, until: anchor), for: catID) }

            // Quantity categories — 90-day windowed backfill. A few categories run at
            // once so uploads overlap with Health reads; the server handles them in
            // parallel. The heavy special categories run alongside in a lane of their
            // own: one after another they took half the wall time for a seventh of
            // the rows. Each category still walks its windows in order and keeps its
            // own cursor, so nothing is shared between the tasks but the main actor.
            let categorySemaphore = AsyncSemaphore(value: 3)
            let specialSemaphore = AsyncSemaphore(value: 3)
            // A child returns the category's name when something failed, and
            // whether the category stopped short (true) or only lost some types.
            try await withThrowingTaskGroup(of: (name: String, sunk: Bool)?.self) { group in
                for (cat, types) in pending {
                    group.addTask { @MainActor [self] in
                        await categorySemaphore.wait()
                        defer { Task { await categorySemaphore.signal() } }
                        try checkSelection()
                        let catID = "qty_\(cat.rawValue)"
                        syncState.updateCategory(catID, status: .syncing)
                        categoryStarted(cat.rawValue)
                        defer { categoryFinished(cat.rawValue) }
                        do {
                            let backfill = try await backfillQuantityCategory(
                                catID: catID, cat: cat, types: types,
                                from: historicalStart, until: anchor, config: config
                            )
                            try checkSelection()
                            updateLiveActivity(phase: cat.rawValue, operation: "Synced older data: \(cat.rawValue)", records: syncState.newRecordsThisRun)
                            if let failedTypes = backfill.failedTypes {
                                syncState.updateCategory(catID, status: .failed("Completed with failed types: \(failedTypes)"),
                                                         recordCount: backfill.inserted)
                                return (cat.rawValue, false)
                            }
                            syncState.updateCategory(catID, status: .completed, recordCount: backfill.inserted, lastSyncDate: Date())
                            return nil
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            syncState.updateCategory(catID, status: .failed(error.localizedDescription))
                            print("Category \(cat.rawValue) failed: \(error.localizedDescription)")
                            return (cat.rawValue, true)
                        }
                    }
                }
                for (catID, displayName) in heavySpecials {
                    group.addTask { @MainActor [self] in
                        await specialSemaphore.wait()
                        defer { Task { await specialSemaphore.signal() } }
                        try checkSelection()
                        syncState.updateCategory(catID, status: .syncing)
                        categoryStarted(displayName)
                        defer { categoryFinished(displayName) }
                        do {
                            let count = try await backfillSpecialCategory(
                                catID: catID, displayName: displayName,
                                from: historicalStart, until: anchor, config: config
                            )
                            try checkSelection()
                            syncState.updateCategory(catID, status: .completed, recordCount: count, lastSyncDate: Date())
                            updateLiveActivity(phase: displayName, operation: "Synced older data: \(displayName)", records: syncState.newRecordsThisRun)
                            return nil
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            syncState.updateCategory(catID, status: .failed(error.localizedDescription))
                            print("Category \(displayName) failed: \(error.localizedDescription)")
                            return (displayName, true)
                        }
                    }
                }
                for try await failed in group {
                    guard let failed else { continue }
                    if failed.sunk { failedCategories.append(failed.name) } else { partlyFailedCategories.append(failed.name) }
                }
            }

            // Sparse categories — skip windowing, query full range, run in parallel
            try checkSelection()
            syncState.currentOperation = "Reading ECG, Audiograms, Medications, Vision, State of Mind\u{2026}"
            do {
                try await withThrowingTaskGroup(of: (String, String, Int).self) { group in
                    for (catID, displayName) in sparseSpecials {
                        syncState.updateCategory(catID, status: .syncing)

                        group.addTask { [self] in
                            let count: Int
                            switch catID {
                            case "cat_ecg":       count = try await syncECG(since: historicalStart, until: anchor)
                            case "cat_audiogram": count = try await syncAudiograms(since: historicalStart, until: anchor)
                            case "cat_medications": count = try await syncMedications(since: historicalStart, until: anchor)
                            case "cat_vision":    count = try await syncVisionPrescriptions(since: historicalStart, until: anchor)
                            case "cat_state_of_mind": count = try await syncStateOfMind(since: historicalStart, until: anchor)
                            default: count = 0
                            }
                            return (catID, displayName, count)
                        }
                    }
                    for try await (catID, displayName, count) in group {
                        try checkSelection()
                        syncState.updateCategory(catID, status: .completed, recordCount: count, lastSyncDate: Date())
                        syncState.backfillCursors[catID] = anchor
                        syncState.newRecordsThisRun += count
                        advanceRun()
                        updateLiveActivity(phase: displayName, operation: "Synced older data: \(displayName)", records: syncState.newRecordsThisRun)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Individual sparse category failures are caught within the task group
                failedCategories.append("Sparse categories")
                print("Sparse categories failed: \(error.localizedDescription)")
            }
            syncState.persist()

            // Mark complete even if some categories failed — successful ones keep their progress.
            // A category that only lost types has its cursor at the anchor like the
            // rest: there is no window left to come back for, so it does not hold
            // the run open.
            syncState.hasCompletedFullSync = failedCategories.isEmpty && HealthSyncSelection.shared.disabledCategories.isEmpty
            if failedCategories.isEmpty {
                syncState.lastSyncDate = anchor
                completeRun()
            }
            if failedCategories.isEmpty && partlyFailedCategories.isEmpty {
                syncState.currentOperation = "Older data synced"
            } else {
                var problems: [String] = []
                if !failedCategories.isEmpty {
                    problems.append("Couldn't sync \(failedCategories.joined(separator: ", ")).")
                }
                if !partlyFailedCategories.isEmpty {
                    problems.append("Some types of \(partlyFailedCategories.joined(separator: ", ")) couldn't be read; the category shows which.")
                }
                syncState.errorMessage = (problems + ["Everything else is saved."]).joined(separator: " ")
                syncState.currentOperation = "Older data synced with errors"
            }

            syncState.persist()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            disconnectFreeReps()

        } catch is CancellationError {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.currentOperation = HealthSyncSelection.shared.isEnabled ? "Sync stopped; progress saved" : "Apple Health sync is paused"
            for i in syncState.categories.indices {
                if case .syncing = syncState.categories[i].status {
                    syncState.categories[i].status = .idle
                }
            }
            syncState.persist()
        } catch {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.errorMessage = error.localizedDescription
            syncState.currentOperation = ""
            for i in syncState.categories.indices {
                if case .syncing = syncState.categories[i].status {
                    syncState.categories[i].status = .failed(error.localizedDescription)
                }
            }
            syncState.persist()
        }

        syncState.isFullSyncRunning = false
    }

    // MARK: - Backfill helpers

    /// One category's windows while its uploader runs. On the main actor because
    /// an acknowledged window moves the cursor in `SyncState`.
    @MainActor
    private final class WindowLedger {
        let runID: Int
        /// Where each started window ends, by index.
        var ends: [Int: Date] = [:]
        /// Windows acknowledged so far, counted from the first window of the
        /// backfill. Acknowledgements arrive in window order from one uploader;
        /// a retry's uploader may report a window the first attempt had already
        /// acknowledged, which then counts once.
        var uploadedCount: Int
        var inserted = 0
        /// Types whose read failed, by display name, with the windows it
        /// failed in. Keyed by window so a retry that reads a window again
        /// counts it once.
        var failedTypes: [String: TypeFailure] = [:]

        struct TypeFailure {
            var windows: Set<Int>
            let reason: String
        }

        init(runID: Int, uploadedCount: Int) {
            self.runID = runID
            self.uploadedCount = uploadedCount
        }

        func noteFailure(of typeDesc: QuantityTypeDescriptor, in window: Int, error: Error) {
            let cause = error as NSError
            var failure = failedTypes[typeDesc.displayName]
                ?? TypeFailure(windows: [], reason: "\(cause.localizedDescription) [\(cause.domain):\(cause.code)]")
            failure.windows.insert(window)
            failedTypes[typeDesc.displayName] = failure
        }

        /// "Basal Energy Burned in 3 windows (… [com.apple.healthkit:3])", or nil.
        var failureSummary: String? {
            guard !failedTypes.isEmpty else { return nil }
            return failedTypes.sorted { $0.key < $1.key }.map { name, failure in
                let windows = failure.windows.count == 1 ? "1 window" : "\(failure.windows.count) windows"
                return "\(name) in \(windows) (\(failure.reason))"
            }.joined(separator: ", ")
        }
    }

    /// Backfills a quantity category in 90-day windows from `historicalStart` to `anchor`,
    /// resuming from `syncState.backfillCursors[catID]` if set.
    ///
    /// The windows share one uploader, and the cursor follows the server's
    /// acknowledgements (`windowUploaded`), not the reads. A failed request ends
    /// the attempt; the next one resumes behind the last acknowledged window,
    /// and three attempts in a row without progress fail the category.
    ///
    /// A type whose read fails does not end the attempt: the window goes on
    /// without that type's rows, the cursor passes it once the other types are
    /// acknowledged, and `failedTypes` names the type in the result. Retrying
    /// would not help — the errors seen so far are HealthKit refusing a range
    /// it has no data for — and it cost six requests in flight per attempt.
    private func backfillQuantityCategory(
        catID: String,
        cat: HealthCategory,
        types: [QuantityTypeDescriptor],
        from historicalStart: Date,
        until anchor: Date,
        config: FreeRepsConfig
    ) async throws -> (inserted: Int, failedTypes: String?) {
        let windowSize = Self.backfillWindow
        let totalWindows = Int(ceil(anchor.timeIntervalSince(historicalStart) / windowSize))
        func index(of cursor: Date) -> Int {
            cursor > historicalStart ? Int(ceil(cursor.timeIntervalSince(historicalStart) / windowSize)) : 0
        }
        var cursor = syncState.backfillCursors[catID] ?? historicalStart
        let ledger = WindowLedger(runID: runID, uploadedCount: index(of: cursor))
        var retries = 0

        while cursor < anchor {
            do {
                try await uploadQuantityWindows(
                    catID: catID, cat: cat, types: types,
                    from: cursor, firstIndex: index(of: cursor), until: anchor,
                    totalWindows: totalWindows, ledger: ledger
                )
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Acknowledged windows stay; the next attempt resumes behind them.
                let resumeAt = syncState.backfillCursors[catID] ?? historicalStart
                if resumeAt > cursor { retries = 0 }
                cursor = resumeAt
                guard retries < 3, Self.isRetryable(error) else {
                    throw backfillFailure(error, category: catID, start: cursor,
                                          end: min(cursor.addingTimeInterval(windowSize), anchor))
                }
                retries += 1
                try await Task.sleep(for: Self.retryDelays[retries - 1])
            }
        }
        return (ledger.inserted, ledger.failureSummary)
    }

    /// Reads the windows from `cursor` to `anchor` one after another into a
    /// single uploader, so the next window's Health read starts while the last
    /// batches of the previous one are still on their way. The cursor moves
    /// from the uploader's window callbacks, never from here.
    private func uploadQuantityWindows(
        catID: String,
        cat: HealthCategory,
        types: [QuantityTypeDescriptor],
        from cursor: Date,
        firstIndex: Int,
        until anchor: Date,
        totalWindows: Int,
        ledger: WindowLedger
    ) async throws {
        let name = cat.rawValue
        let uploader = makeMetricUploader(label: catID, onBatch: { @MainActor [self] ack in
            batchAcknowledged(ack, catID: catID, name: name, ledger: ledger)
        }, onWindowUploaded: { @MainActor [self] window in
            await windowUploaded(window, catID: catID, totalWindows: totalWindows, ledger: ledger)
        })
        do {
            var cursor = cursor
            var index = firstIndex
            while cursor < anchor {
                try checkSelection()
                let windowEnd = min(cursor.addingTimeInterval(Self.backfillWindow), anchor)
                ledger.ends[index] = windowEnd
                // The window shows on the category's own row; the headline names the
                // categories running side by side.
                syncState.updateCategory(catID, status: .syncing, progress: index, total: totalWindows, period: cursor..<windowEnd)
                categoryWindow(name, "window \(index + 1) of \(totalWindows)")
                await SyncTrace.shared.record("window.started", [
                    "category": catID, "index": String(index), "total": String(totalWindows),
                ])
                await uploader.beginWindow(index)
                let windowStart = cursor
                let windowIndex = index
                _ = try await readQuantityTypes(types, since: { _ in windowStart }, until: windowEnd, onTypeFailed: { typeDesc, error in
                    // A store that cannot be read at all is not one type's failure:
                    // it ends the attempt, and the retry finds the window unacknowledged.
                    if HealthKitService.affectsWholeStore(error) { throw error }
                    ledger.noteFailure(of: typeDesc, in: windowIndex, error: error)
                }, into: uploader)
                try await uploader.endWindow(index)
                cursor = windowEnd
                index += 1
            }
            _ = try await uploader.finish()
        } catch {
            await uploader.cancel()
            throw error
        }
    }

    /// Credits an acknowledged batch to the run's counters and the window's step.
    private func batchAcknowledged(_ ack: UploadAck, catID: String, name: String, ledger: WindowLedger) {
        guard ledger.runID == runID else { return }
        syncState.newRecordsThisRun += ack.inserted
        categoryRows(name, add: ack.rows)
        if ack.window >= ledger.uploadedCount {
            partialStep("\(catID)/\(ack.window)", fraction: Double(ack.windowBatchesAcked) / Double(max(ack.windowBatchesSent, 1)))
            windowRows("\(catID)/\(ack.window)", rows: ack.rows)
        }
        updateLiveActivity(phase: name, operation: syncState.currentOperation, records: syncState.newRecordsThisRun)
    }

    /// Moves the cursor past a window the server has acknowledged in full. The
    /// cursor only moves forward: windows are reported in order, so a report
    /// for an earlier index than the ledger's count was already covered.
    private func windowUploaded(_ window: UploadedWindow, catID: String, totalWindows: Int, ledger: WindowLedger) async {
        guard ledger.runID == runID else { return }
        await SyncTrace.shared.record("window.finished", [
            "category": catID, "index": String(window.index), "total": String(totalWindows),
            "rows": String(window.rows), "inserted": String(window.inserted),
        ])
        ledger.inserted += window.inserted
        let key = "\(catID)/\(window.index)"
        partialSteps.removeValue(forKey: key)
        guard window.index >= ledger.uploadedCount else {
            partialRows.removeValue(forKey: key)
            refreshProgress()
            return
        }
        let steps = window.index + 1 - ledger.uploadedCount
        ledger.uploadedCount = window.index + 1
        if let end = ledger.ends[window.index] {
            syncState.backfillCursors[catID] = end
            syncState.persist()
        }
        windowAcknowledged(catID, key: key, rows: window.rows, windows: steps)
        advanceRun(by: steps)
    }

    /// Pauses between attempts at one window. A server restart takes longer than
    /// a blip, so the pauses grow to cover one.
    private static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

    /// Whether another attempt at the same window can end differently. An
    /// encoding error is the client's own and repeats on every attempt; three
    /// timed retries of it only cancelled the uploads running alongside.
    private static func isRetryable(_ error: Error) -> Bool {
        if case FreeRepsError.encodingError = error { return false }
        return true
    }

    /// Backfills a special (non-quantity) category in 90-day windows, resuming from cursor.
    private func backfillSpecialCategory(
        catID: String,
        displayName: String,
        from historicalStart: Date,
        until anchor: Date,
        config: FreeRepsConfig
    ) async throws -> Int {
        let windowSize = Self.backfillWindow
        var cursor = syncState.backfillCursors[catID] ?? historicalStart
        var total = 0
        let totalWindows = Int(ceil(anchor.timeIntervalSince(historicalStart) / windowSize))
        var windowIdx = cursor > historicalStart
            ? Int(ceil(cursor.timeIntervalSince(historicalStart) / windowSize))
            : 0

        while cursor < anchor {
            try checkSelection()

            let windowEnd = min(cursor.addingTimeInterval(windowSize), anchor)
            syncState.updateCategory(catID, status: .syncing, progress: windowIdx, total: totalWindows, period: cursor..<windowEnd)
            categoryWindow(displayName, "window \(windowIdx + 1) of \(totalWindows)")
            await SyncTrace.shared.record("window.started", [
                "category": catID, "index": String(windowIdx), "total": String(totalWindows),
            ])
            var retries = 0
            var window: SpecialWindow = (inserted: 0, rows: 0)
            while true {
                do {
                    window = try await syncSpecialWindow(catID: catID, displayName: displayName,
                                                         index: windowIdx, start: cursor, end: windowEnd)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch where retries < 3 && Self.isRetryable(error) {
                    retries += 1
                    try await Task.sleep(for: Self.retryDelays[retries - 1])
                } catch {
                    throw backfillFailure(error, category: catID, start: cursor, end: windowEnd)
                }
            }
            await SyncTrace.shared.record("window.finished", [
                "category": catID, "index": String(windowIdx), "total": String(totalWindows),
                "inserted": String(window.inserted), "rows": String(window.rows),
            ])
            total += window.inserted
            syncState.newRecordsThisRun += window.inserted
            partialSteps.removeValue(forKey: "\(catID)/\(windowIdx)")
            windowAcknowledged(catID, key: "\(catID)/\(windowIdx)", rows: window.rows)

            cursor = windowEnd
            windowIdx += 1
            syncState.backfillCursors[catID] = cursor
            syncState.persist()
            advanceRun()
            updateLiveActivity(phase: displayName, operation: syncState.currentOperation, records: syncState.newRecordsThisRun)
        }
        return total
    }

    /// What a window of a special category sent: the records the UI counts,
    /// and the rows the server looked at, which weigh the progress. Workouts
    /// and routes carry points that outnumber the records by thousands; the
    /// other categories report rows inserted, not sent, close enough for the
    /// estimate.
    private typealias SpecialWindow = (inserted: Int, rows: Int)

    /// One window of a special category. Category samples go through a batching
    /// uploader whose acknowledgements credit part of the window's step; the
    /// other categories are small enough to count per window.
    private func syncSpecialWindow(catID: String, displayName: String, index: Int, start: Date, end: Date) async throws -> SpecialWindow {
        switch catID {
        case "cat_category":
            let run = runID
            let key = "\(catID)/\(index)"
            let inserted = try await syncCategorySamples(since: start, until: end) { @MainActor [self] ack in
                guard run == runID else { return }
                categoryRows(displayName, add: ack.rows)
                partialStep(key, fraction: Double(ack.windowBatchesAcked) / Double(max(ack.windowBatchesSent, 1)))
                windowRows(key, rows: ack.rows)
                updateLiveActivity(phase: displayName, operation: syncState.currentOperation, records: syncState.newRecordsThisRun)
            }
            return (inserted, inserted)
        case "cat_workouts":
            return try await syncWorkouts(since: start, until: end)
        case "cat_bp":
            let inserted = try await syncBloodPressure(since: start, until: end)
            return (inserted, inserted)
        case "cat_activity_summaries":
            let inserted = try await syncActivitySummaries(since: start, until: end)
            return (inserted, inserted)
        case "cat_workout_routes":
            return try await syncWorkoutRoutes(since: start, until: end)
        default:
            return (0, 0)
        }
    }

    // MARK: - Incremental sync

    private func backfillFailure(_ error: Error, category: String, start: Date, end: Date) -> NSError {
        let cause = error as NSError
        let formatter = ISO8601DateFormatter()
        return NSError(domain: "FreeReps.Backfill", code: cause.code, userInfo: [
            NSLocalizedDescriptionKey: "\(category), \(formatter.string(from: start)) to \(formatter.string(from: end)): \(cause.localizedDescription) [\(cause.domain):\(cause.code)]",
            NSUnderlyingErrorKey: cause,
        ])
    }

    func runIncrementalSync(config: FreeRepsConfig) async {
        guard !Self.isSyncRunning, !syncState.isAnySyncRunning, beginSelectedSync() else { return }
        syncState.isIncrementalSyncRunning = true
        SyncService.isSyncRunning = true
        defer {
            syncState.isIncrementalSyncRunning = false
            SyncService.isSyncRunning = false
            for i in syncState.categories.indices where syncState.categories[i].status == .syncing {
                syncState.categories[i].status = .idle
            }
            syncState.persist()
        }
        let syncStartedAt = Date()
        syncState.errorMessage = nil
        syncState.newRecordsThisRun = 0
        startLiveActivity(isFullSync: false)

        // Keep screen awake during foreground sync to prevent auto-lock killing HealthKit access
        if !isBackgroundSync {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        defer {
            if !isBackgroundSync {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

        // Request extra background execution time if user switches away during sync
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        if !isBackgroundSync {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "health-incremental-sync") {
                self.syncState.persist()
                let req = BGProcessingTaskRequest(identifier: AppDelegate.syncTaskIdentifier)
                req.requiresNetworkConnectivity = true
                req.earliestBeginDate = nil
                try? BGTaskScheduler.shared.submit(req)
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }

        do {
            // Pre-first-unlock guard: isProtectedDataAvailable is false only before the very
            // first unlock after boot. The errorDatabaseInaccessible suppression below handles
            // the common screen-locked case (device unlocked at least once since boot).
            if isBackgroundSync {
                guard UIApplication.shared.isProtectedDataAvailable else {
                    syncState.isIncrementalSyncRunning = false
                    return
                }
            }

            connectFreeReps(config: config)
            guard let freereps else { throw FreeRepsError.connectionFailed("FreeReps not initialized") }
            _ = try await freereps.ping()
            try checkSelection()

            syncState.currentOperation = "Checking for new data\u{2026}"

            // Mirrored into the state so the app shows the same number as the Live Activity.
            var total: Int {
                get { syncState.newRecordsThisRun }
                set { syncState.newRecordsThisRun = newValue }
            }
            var failedCategories: [String] = []

            let quantityCategories = HealthDataTypes.quantityTypesByCategory
                .filter { HealthSyncSelection.shared.includes("qty_\($0.0.rawValue)") }
            let specialIDs = ["cat_category", "cat_workouts", "cat_bp", "cat_ecg", "cat_audiogram", "cat_activity_summaries",
                              "cat_workout_routes", "cat_medications", "cat_vision", "cat_state_of_mind"]
            beginRun(steps: quantityCategories.reduce(0) { $0 + $1.1.count }
                + specialIDs.filter { HealthSyncSelection.shared.includes($0) }.count)

            for (cat, types) in quantityCategories {
                let catID = "qty_\(cat.rawValue)"
                let querySince = recentQueryStart(categoryID: catID, now: syncStartedAt)
                let bucketSince = recentBucketStart(categoryID: catID, now: syncStartedAt)
                try checkSelection()

                syncState.updateCategory(catID, status: .syncing)
                var catDelta = 0
                var failedTypes: [String] = []
                var databaseInaccessible: Error?
                do {
                    // Individual samples come through a HealthKit anchor, so only what was
                    // added since the last run is read; hourly buckets are recomputed for
                    // the last day, because late samples change the sums of past hours.
                    let outcome = try await uploadQuantityTypes(
                        types,
                        label: catID,
                        since: { $0.syncStrategy.isIndividual ? querySince : bucketSince },
                        anchorKey: { Self.anchorKey(category: catID, type: $0.id) },
                        onTypeFailed: { typeDesc, error in
                            if self.isBackgroundSync, (error as? HKError)?.code == .errorDatabaseInaccessible {
                                databaseInaccessible = error
                            }
                            let cause = error as NSError
                            failedTypes.append("\(typeDesc.displayName): \(error.localizedDescription) [\(cause.domain):\(cause.code)]")
                        }
                    )
                    catDelta = outcome.inserted
                    if failedTypes.isEmpty { syncState.anchors.merge(outcome.anchors) { _, new in new } }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let cause = error as NSError
                    failedTypes.append("\(error.localizedDescription) [\(cause.domain):\(cause.code)]")
                }
                if let databaseInaccessible { throw databaseInaccessible }
                advanceRun(by: types.count)
                let existing = syncState.categories.first(where: { $0.id == catID })?.recordCount ?? 0
                if failedTypes.isEmpty {
                    try checkSelection()
                    syncState.updateCategory(catID, status: .completed, recordCount: existing + catDelta, lastSyncDate: Date())
                } else {
                    failedCategories.append(cat.rawValue)
                    syncState.updateCategory(catID,
                        status: .failed("Failed types: \(failedTypes.joined(separator: ", "))"),
                        recordCount: existing + catDelta)
                }
                total += catDelta
                updateLiveActivity(phase: cat.rawValue, operation: "Synced \(cat.rawValue)", records: total)
            }

            // Special categories, one at a time; each is a single Health read.
            let specials: [(id: String, name: String, sync: (Date) async throws -> Int)] = [
                ("cat_category", "Health Events", { @MainActor date in try await self.syncCategorySamples(since: date, anchored: true) }),
                ("cat_workouts", "Workouts", { @MainActor date in try await self.syncWorkouts(since: date, anchored: true).inserted }),
                ("cat_bp", "Blood Pressure", { @MainActor date in try await self.syncBloodPressure(since: date) }),
                ("cat_ecg", "ECG", { @MainActor date in try await self.syncECG(since: date) }),
                ("cat_audiogram", "Audiograms", { @MainActor date in try await self.syncAudiograms(since: date) }),
                ("cat_activity_summaries", "Activity Rings", { @MainActor date in try await self.syncActivitySummaries(since: date) }),
                ("cat_workout_routes", "Workout Routes", { @MainActor date in try await self.syncWorkoutRoutes(since: date, anchored: true).inserted }),
                ("cat_medications", "Medications", { @MainActor date in try await self.syncMedications(since: date) }),
                ("cat_vision", "Vision Prescriptions", { @MainActor date in try await self.syncVisionPrescriptions(since: date) }),
                ("cat_state_of_mind", "State of Mind", { @MainActor date in try await self.syncStateOfMind(since: date) }),
            ]
            for special in specials where HealthSyncSelection.shared.includes(special.id) {
                let querySince = recentQueryStart(categoryID: special.id, now: syncStartedAt)
                try checkSelection()
                syncState.updateCategory(special.id, status: .syncing)
                do {
                    let count = try await special.sync(querySince)
                    let existing = syncState.categories.first(where: { $0.id == special.id })?.recordCount ?? 0
                    try checkSelection()
                    syncState.updateCategory(special.id, status: .completed, recordCount: existing + count, lastSyncDate: Date())
                    total += count
                    updateLiveActivity(phase: special.name, operation: "Synced \(special.name)", records: total)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isBackgroundSync, (error as? HKError)?.code == .errorDatabaseInaccessible {
                        throw error
                    }
                    failedCategories.append(special.name)
                    syncState.updateCategory(special.id, status: .failed(error.localizedDescription))
                }
                advanceRun()
            }

            try checkSelection()
            if !failedCategories.isEmpty {
                syncState.errorMessage = "Sync completed with errors in: \(failedCategories.joined(separator: ", "))"
            }

            if failedCategories.isEmpty { syncState.lastSyncDate = syncStartedAt }
            syncState.currentOperation = "Synced \(total.formatted()) new records"
            syncState.persist()
            endLiveActivity(totalRecords: total)
            disconnectFreeReps()

        } catch is CancellationError {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.currentOperation = HealthSyncSelection.shared.isEnabled ? "Sync stopped; progress saved" : "Apple Health sync is paused"
            syncState.persist()
        } catch let error as HKError where isBackgroundSync && error.code == .errorDatabaseInaccessible {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.currentOperation = "Waiting for Health data to become available"
        } catch {
            disconnectFreeReps()
            endLiveActivity(totalRecords: syncState.newRecordsThisRun)
            syncState.errorMessage = error.localizedDescription
            syncState.currentOperation = ""
            syncState.persist()
        }

        syncState.isIncrementalSyncRunning = false
    }

    /// Where a read without a HealthKit anchor starts: a week before the last
    /// confirmed sync, so entries other apps write into the past still arrive.
    private func recentQueryStart(categoryID: String, now: Date) -> Date {
        let confirmed = syncState.categories.first { $0.id == categoryID }?.lastSyncDate
        return (confirmed ?? now).addingTimeInterval(-7 * 24 * 3600)
    }

    /// Where hourly buckets are recomputed from: a day back, which covers a
    /// watch that syncs its samples to the iPhone hours late. The first run
    /// takes the same week as everything else.
    private func recentBucketStart(categoryID: String, now: Date) -> Date {
        guard syncState.categories.first(where: { $0.id == categoryID })?.lastSyncDate != nil else {
            return recentQueryStart(categoryID: categoryID, now: now)
        }
        return now.addingTimeInterval(-26 * 3600)
    }

    // MARK: - Ingest helper

    /// Sends a payload to FreeReps, throwing if the service is not initialized.
    ///
    /// Every request of a run passes through here, so this is where the run's
    /// request slots are taken: the uploaders' own caps (six for metrics,
    /// three for category samples) only keep one category from holding every
    /// slot, and the workout, route and blood pressure requests count too.
    private func ingest(_ payload: FreeRepsPayload) async throws -> IngestResult {
        try checkSelection()
        guard let freereps else {
            throw FreeRepsError.connectionFailed("FreeReps service not initialized")
        }
        let slots = requestSlots
        await slots.wait()
        defer { Task { await slots.signal() } }
        try checkSelection()
        return try await freereps.ingest(payload)
    }

    // MARK: - Activity summary sync

    private func syncActivitySummaries(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        let summaries = try await healthKit.fetchActivitySummaries(from: since, until: until)
        guard !summaries.isEmpty else { return 0 }
        let calendar = Calendar.current
        var total = 0

        for batch in summaries.chunked(into: batchSize) {
            let records: [FreeRepsActivitySummary] = batch.compactMap { summary in
                guard let date = calendar.date(from: summary.dateComponents(for: calendar)) else { return nil }
                return FreeRepsActivitySummary(
                    date: haeDateOnly(date),
                    active_energy: summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                    active_energy_goal: summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                    exercise_time: summary.appleExerciseTime.doubleValue(for: .minute()),
                    exercise_time_goal: summary.appleExerciseTimeGoal.doubleValue(for: .minute()),
                    stand_hours: summary.appleStandHours.doubleValue(for: .count()),
                    stand_hours_goal: summary.appleStandHoursGoal.doubleValue(for: .count())
                )
            }
            guard !records.isEmpty else { continue }
            let payload = FreeRepsPayload(data: FreeRepsData(activity_summaries: records))
            try checkSelection()
            let result = try await ingest(payload)
            total += result.activity_summaries_inserted ?? batch.count
        }
        return total
    }

    // MARK: - Workout route sync

    /// How long after a workout ends a route may still arrive. Beyond this the
    /// workout is taken to have none (indoor, treadmill, no GPS).
    private static let routeGracePeriod: TimeInterval = 48 * 3600

    private func syncWorkoutRoutes(since: Date?, until: Date? = nil, anchored: Bool = false) async throws -> SpecialWindow {
        try checkSelection()
        var total: SpecialWindow = (inserted: 0, rows: 0)
        if anchored, let start = since {
            // Its own anchor, not the one of "cat_workouts": the two categories
            // are enabled and reset independently. A failed upload leaves the
            // anchor where it was, so the next run reads the same workouts again.
            //
            // The anchor tracks workouts, and the watch can deliver a workout
            // before its route. A workout the anchor has passed without a route
            // is kept on a retry list and checked again first on each run.
            let pending = try await uploadPendingRoutes()
            total.inserted += pending.inserted
            total.rows += pending.rows
            let key = Self.anchorKey(category: "cat_workout_routes", type: "workouts")
            let changes = try await healthKit.changedWorkouts(anchor: syncState.anchors[key], fallbackSince: start)
            for outcome in try await uploadRoutes(forEach: changes.added) {
                if outcome.uploaded {
                    total.inserted += 1
                    total.rows += outcome.points
                    syncState.routesPending.removeValue(forKey: outcome.uuid)
                } else {
                    syncState.routesPending[outcome.uuid] = outcome.endDate
                }
            }
            syncState.anchors[key] = changes.anchor
        } else {
            try await healthKit.streamWorkouts(from: since, until: until) { [self] workouts in
                for outcome in try await uploadRoutes(forEach: workouts) where outcome.uploaded {
                    total.inserted += 1
                    total.rows += outcome.points
                }
            }
        }
        return total
    }

    /// What became of one workout's route in `uploadRoutes(forEach:)`.
    private struct RouteOutcome {
        let uuid: String
        let endDate: Date
        /// Route points the server took; none when the workout has no route yet.
        let points: Int
        var uploaded: Bool { points > 0 }
    }

    /// How many workouts have their routes read and uploaded at once. Each
    /// route is one request of 2–6 MB of JSON (0.5–1.5 MB gzipped), and
    /// HealthKit streams the locations in chunks; one at a time, the read sits
    /// idle while the upload runs. Routes are the tail of an older-data run,
    /// alone after the other categories, so they may take most of the run's
    /// `requestSlotCount`, which still caps the total.
    private static let routeConcurrency = 6

    /// Runs `uploadRoutes(of:)` for the workouts, `routeConcurrency` at a time.
    /// The outcomes come back in completion order, which the callers do not
    /// depend on. They apply the outcomes to `syncState` themselves: the child
    /// tasks only read and upload, so a failure anywhere cancels the rest and
    /// leaves the pending list untouched — the anchor stays too, and the next
    /// run reads the same workouts again.
    private func uploadRoutes(forEach workouts: [HKWorkout]) async throws -> [RouteOutcome] {
        var outcomes: [RouteOutcome] = []
        outcomes.reserveCapacity(workouts.count)
        try await withThrowingTaskGroup(of: RouteOutcome.self) { group in
            var next = 0
            var running = 0
            while next < workouts.count || running > 0 {
                while running < Self.routeConcurrency, next < workouts.count {
                    try checkSelection()
                    let workout = workouts[next]
                    next += 1
                    running += 1
                    group.addTask { @MainActor [self] in
                        RouteOutcome(uuid: workout.uuid.uuidString, endDate: workout.endDate,
                                     points: try await uploadRoutes(of: workout))
                    }
                }
                guard let outcome = try await group.next() else { break }
                running -= 1
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Retries the workouts still waiting for a route. One that has a route now
    /// leaves the list once uploaded; one past the grace period leaves it
    /// without; one deleted from Health stays until the grace period passes.
    private func uploadPendingRoutes() async throws -> SpecialWindow {
        let cutoff = Date().addingTimeInterval(-Self.routeGracePeriod)
        syncState.routesPending = syncState.routesPending.filter { $0.value >= cutoff }
        let uuids = syncState.routesPending.keys.compactMap { UUID(uuidString: $0) }
        guard !uuids.isEmpty else { return (0, 0) }
        var total: SpecialWindow = (inserted: 0, rows: 0)
        let workouts = try await healthKit.workouts(uuids: uuids)
        for outcome in try await uploadRoutes(forEach: workouts) where outcome.uploaded {
            syncState.routesPending.removeValue(forKey: outcome.uuid)
            total.inserted += 1
            total.rows += outcome.points
        }
        return total
    }

    /// Sends the workout's route to the server and returns the points sent.
    /// Zero when the workout has no route yet — or none could be read, which
    /// is treated the same way, as a retry costs one query and a lost route
    /// costs the map. A route the encoder refuses is skipped the same way:
    /// the fault is in the data, so sending it again cannot help.
    private func uploadRoutes(of workout: HKWorkout) async throws -> Int {
        try checkSelection()
        var points = 0
        let routes: [HKWorkoutRoute]
        do { routes = try await healthKit.fetchWorkoutRoutes(for: workout) } catch { return 0 }
        for route in routes {
            try checkSelection()
            let locations: [CLLocation]
            do { locations = try await healthKit.fetchRouteLocations(for: route) } catch { continue }
            guard !locations.isEmpty else { continue }

            let routePoints = locations.compactMap(Self.routePoint)
            guard !routePoints.isEmpty else { continue }
            // Send workout with route data — FreeReps uses ON CONFLICT DO NOTHING for the workout itself
            let hbWorkout = FreeRepsWorkout(
                id: workout.uuid.uuidString,
                name: workout.activityTypeName,
                start: haeDate(workout.startDate),
                end: haeDate(workout.endDate),
                duration: workout.duration,
                route: routePoints
            )
            let payload = FreeRepsPayload(data: FreeRepsData(workouts: [hbWorkout]))
            do {
                _ = try await ingest(payload)
            } catch FreeRepsError.encodingError(let field) {
                await SyncTrace.shared.record("route.skipped", ["workout": workout.uuid.uuidString, "field": field])
                continue
            }
            points += routePoints.count
        }
        return points
    }

    /// A location as a route point, or nil when its coordinate is not a
    /// number. The other fields keep CoreLocation's negative "invalid"
    /// sentinels; only NaN and infinity become nil, as the encoder rejects
    /// them (see `FreeRepsRoutePoint`).
    private static func routePoint(_ loc: CLLocation) -> FreeRepsRoutePoint? {
        func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
        guard loc.coordinate.latitude.isFinite, loc.coordinate.longitude.isFinite else { return nil }
        return FreeRepsRoutePoint(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: finite(loc.altitude),
            course: finite(loc.course),
            courseAccuracy: finite(loc.courseAccuracy),
            horizontalAccuracy: finite(loc.horizontalAccuracy),
            verticalAccuracy: finite(loc.verticalAccuracy),
            timestamp: haeDate(loc.timestamp),
            speed: finite(loc.speed),
            speedAccuracy: finite(loc.speedAccuracy)
        )
    }

    // MARK: - Medication sync

    private func syncMedications(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        if #available(iOS 26, *) {
            return try await syncMedicationsIOS26(since: since, until: until)
        }
        return 0
    }

    @available(iOS 26, *)
    private func syncMedicationsIOS26(since: Date?, until: Date? = nil) async throws -> Int {
        var total = 0
        let medications = (try? await healthKit.fetchUserAnnotatedMedications()) ?? []

        if medications.isEmpty {
            let events = try await healthKit.fetchMedicationDoseEvents(from: since, until: until)
            for event in events {
                try checkSelection()
                total += try await ingestMedicationDoseEvent(event, medicationName: nil)
            }
            return total
        }

        for annotated in medications {
            let concept = annotated.medication
            let conceptPredicate = NSPredicate(
                format: "%K == %@",
                HKPredicateKeyPathMedicationConceptIdentifier,
                concept.identifier
            )
            let events = try await healthKit.fetchMedicationDoseEvents(
                from: since, until: until, additionalPredicate: conceptPredicate
            )
            for event in events {
                try checkSelection()
                total += try await ingestMedicationDoseEvent(event, medicationName: concept.displayText)
            }
        }
        return total
    }

    @available(iOS 26, *)
    private func ingestMedicationDoseEvent(_ event: HKMedicationDoseEvent, medicationName: String?) async throws -> Int {
        let record = FreeRepsMedication(
            id: event.uuid.uuidString,
            name: medicationName ?? "Unknown",
            dosage: event.doseQuantity.map { "\($0) \(event.unit.unitString)" },
            log_status: logStatusString(event.logStatus),
            start_date: haeDate(event.startDate),
            end_date: haeDate(event.endDate),
            source: event.sourceRevision.source.name
        )
        let payload = FreeRepsPayload(data: FreeRepsData(medications: [record]))
        _ = try await ingest(payload)
        return 1
    }

    @available(iOS 26, *)
    private func logStatusString(_ status: HKMedicationDoseEvent.LogStatus) -> String {
        switch status {
        case .taken:               return "taken"
        case .skipped:             return "skipped"
        case .snoozed:             return "snoozed"
        case .notInteracted:       return "notInteracted"
        case .notificationNotSent: return "notificationNotSent"
        case .notLogged:           return "notLogged"
        @unknown default:          return "unknown"
        }
    }

    // MARK: - Quantity sync

    /// Reads one quantity type and hands the points to `sink` as they come, in
    /// pieces of at most `batchSize` rows. Returns the new HealthKit anchor when
    /// `anchorKey` is set: the read then covers everything added since the last
    /// anchor, or since `since` when there is none yet.
    private func readQuantityType(
        typeDesc: QuantityTypeDescriptor,
        since: Date?,
        until: Date? = nil,
        anchorKey: String? = nil,
        sink: (FreeRepsMetric) async throws -> Void
    ) async throws -> Data? {
        guard let metricName = hkToFreeRepsMetricName[typeDesc.id] else { return nil }
        try checkSelection()
        let start = since ?? Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        let end = until ?? Date()

        switch typeDesc.syncStrategy {
        case .aggregate(let interval):
            // On-device min/avg/max buckets for high-frequency discrete types.
            let buckets = try await statisticsBuckets(typeDesc, from: start, until: end) {
                try await healthKit.queryAggregatedStatistics(
                    typeID: typeDesc.hkIdentifier, unit: typeDesc.unit, from: start, until: end, interval: interval)
            }
            let points = buckets.map { FreeRepsMetricDataPoint(date: haeDate($0.startDate), Min: $0.min, Avg: $0.avg, Max: $0.max) }
            if !points.isEmpty { try await sink(FreeRepsMetric(name: metricName, units: typeDesc.unitString, data: points)) }
            return nil

        case .aggregateCumulative(let interval):
            // Hourly sums for steps, energy and distance; individual samples would double-count.
            let buckets = try await statisticsBuckets(typeDesc, from: start, until: end) {
                try await healthKit.queryCumulativeStatistics(
                    typeID: typeDesc.hkIdentifier, unit: typeDesc.unit, from: start, until: end, interval: interval)
            }
            let points = buckets.map { FreeRepsMetricDataPoint(date: haeDate($0.startDate), qty: $0.sum) }
            if !points.isEmpty { try await sink(FreeRepsMetric(name: metricName, units: typeDesc.unitString, data: points)) }
            return nil

        case .individual:
            func metric(_ samples: [HKQuantitySample]) -> FreeRepsMetric {
                FreeRepsMetric(name: metricName, units: typeDesc.unitString, data: samples.map { s in
                    FreeRepsMetricDataPoint(date: haeDate(s.startDate),
                                            qty: s.quantity.doubleValue(for: typeDesc.unit),
                                            source_uuid: s.uuid.uuidString)
                })
            }
            if let anchorKey {
                let changes = try await healthKit.changedQuantitySamples(
                    typeID: typeDesc.hkIdentifier, anchor: syncState.anchors[anchorKey], fallbackSince: start)
                for page in changes.added.chunked(into: batchSize) { try await sink(metric(page)) }
                return changes.anchor
            }
            // Skip empty windows without paging through them.
            if let hkType = typeDesc.hkType, until != nil,
               !(try await healthKit.sampleExists(for: hkType, from: start, to: end)) { return nil }
            try await healthKit.streamQuantitySamples(typeID: typeDesc.hkIdentifier, from: since, until: until) { page in
                try await sink(metric(page))
            }
            return nil
        }
    }

    /// Runs a statistics collection query. Over a range HealthKit has no data
    /// source for — basal energy from before the watch existed — it answers
    /// "invalid argument" (3, "Unable to invalidate interval: no data source
    /// available") or "no data" (11) instead of an empty collection. Both mean
    /// no rows in this window, not a failed type; a retry gets the same answer.
    private func statisticsBuckets<Bucket>(
        _ typeDesc: QuantityTypeDescriptor, from start: Date, until end: Date,
        query: () async throws -> [Bucket]
    ) async throws -> [Bucket] {
        do {
            return try await query()
        } catch let error where HealthKitService.meansNoDataInRange(error) {
            let formatter = ISO8601DateFormatter()
            await SyncTrace.shared.record("quantity.empty", [
                "type": typeDesc.id, "from": formatter.string(from: start), "to": formatter.string(from: end),
                "code": String((error as NSError).code),
            ])
            return []
        }
    }

    /// Six requests in flight per uploader, within the run's shared cap of
    /// `requestSlotCount`: the per-uploader cap keeps one category from taking
    /// every slot; the shared one keeps the server's queue short. Watch
    /// `upload.batch` `elapsed_ms` in the trace — it includes the wait for a
    /// slot; `http.finished` `elapsed_ms` is the server alone.
    private func makeMetricUploader(
        label: String,
        onBatch: (@Sendable (UploadAck) async -> Void)? = nil,
        onWindowUploaded: (@Sendable (UploadedWindow) async -> Void)? = nil
    ) -> MetricUploader {
        MetricUploader(
            label: label, batchSize: batchSize, maxInFlight: 6,
            makePayload: { FreeRepsPayload(data: FreeRepsData(metrics: $0)) },
            insertedRows: { $0.metrics_inserted },
            ingest: { [self] payload in try await self.ingest(payload) },
            onBatch: onBatch, onWindowUploaded: onWindowUploaded
        )
    }

    /// Reads a category's quantity types a few at a time and uploads them through
    /// one `MetricUploader`, so small types share a request and reads overlap with
    /// uploads. Returns the rows the server inserted and the anchors to keep.
    private func uploadQuantityTypes(
        _ types: [QuantityTypeDescriptor],
        label: String,
        since: @escaping (QuantityTypeDescriptor) -> Date?,
        until: Date? = nil,
        anchorKey: ((QuantityTypeDescriptor) -> String)? = nil,
        onTypeFailed: ((QuantityTypeDescriptor, Error) throws -> Void)? = nil
    ) async throws -> (inserted: Int, anchors: [String: Data]) {
        let uploader = makeMetricUploader(label: label)
        do {
            let anchors = try await readQuantityTypes(types, since: since, until: until, anchorKey: anchorKey,
                                                      onTypeFailed: onTypeFailed, into: uploader)
            let inserted = try await uploader.finish()
            return (inserted, anchors)
        } catch {
            await uploader.cancel()
            throw error
        }
    }

    /// Reads the types five at a time into `uploader`. Returns the anchors to keep.
    ///
    /// A type whose read fails is handed to `onTypeFailed` and the others go
    /// on; without the callback, or when it throws, the failure ends the read.
    /// A failed upload always ends it — the uploader is broken for every type.
    private func readQuantityTypes(
        _ types: [QuantityTypeDescriptor],
        since: @escaping (QuantityTypeDescriptor) -> Date?,
        until: Date? = nil,
        anchorKey: ((QuantityTypeDescriptor) -> String)? = nil,
        onTypeFailed: ((QuantityTypeDescriptor, Error) throws -> Void)? = nil,
        into uploader: MetricUploader
    ) async throws -> [String: Data] {
        let semaphore = AsyncSemaphore(value: 5)
        var anchors: [String: Data] = [:]
        try await withThrowingTaskGroup(of: (String, Data)?.self) { group in
            for typeDesc in types {
                group.addTask { @MainActor [self] in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    try checkSelection()
                    let key = anchorKey?(typeDesc)
                    do {
                        await SyncTrace.shared.record("quantity.started", ["type": typeDesc.id])
                        let anchor = try await readQuantityType(typeDesc: typeDesc, since: since(typeDesc), until: until,
                                                                anchorKey: key) { try await uploader.add($0) }
                        await SyncTrace.shared.record("quantity.finished", ["type": typeDesc.id])
                        if let key, let anchor { return (key, anchor) }
                        return nil
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MetricUploader.UploadFailed {
                        throw error.underlying
                    } catch {
                        let cause = error as NSError
                        await SyncTrace.shared.record("quantity.failed", ["type": typeDesc.id,
                            "domain": cause.domain, "code": String(cause.code)])
                        guard let onTypeFailed else { throw error }
                        try onTypeFailed(typeDesc, error)
                        return nil
                    }
                }
            }
            for try await pair in group {
                if let (key, anchor) = pair { anchors[key] = anchor }
            }
        }
        return anchors
    }

    // MARK: - Category sync

    /// Uploads category samples such as sleep stages. The types are read a few
    /// at a time into one uploader, so the many small types share requests the
    /// way quantity types do. With `anchored`, each type is read through its
    /// HealthKit anchor, so only additions since the last run come back; the
    /// anchors are kept once every type is on the server — a failure anywhere
    /// leaves them all where they were.
    private func syncCategorySamples(since: Date?, until: Date? = nil, anchored: Bool = false,
                                     insertBatchSize: Int = batchSize,
                                     onBatch: (@Sendable (UploadAck) async -> Void)? = nil) async throws -> Int {
        try checkSelection()
        let uploader = CategoryUploader(
            label: "cat_category", batchSize: insertBatchSize, maxInFlight: 3,
            makePayload: { FreeRepsPayload(data: FreeRepsData(category_samples: $0.flatMap(\.samples))) },
            insertedRows: { $0.category_samples_inserted },
            ingest: { [self] payload in try await self.ingest(payload) },
            onBatch: onBatch
        )
        let semaphore = AsyncSemaphore(value: 5)
        var newAnchors: [String: Data] = [:]
        do {
            try await withThrowingTaskGroup(of: (String, Data)?.self) { group in
                for typeDesc in HealthDataTypes.allCategoryTypes {
                    group.addTask { @MainActor [self] in
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }
                        try checkSelection()
                        await SyncTrace.shared.record("category.started", ["type": typeDesc.id])
                        var rows = 0
                        func upload(_ hkBatch: [HKCategorySample]) async throws {
                            rows += hkBatch.count
                            let samples = hkBatch.map { s in
                                FreeRepsCategorySample(
                                    id: s.uuid.uuidString,
                                    type: typeDesc.id,
                                    value: s.value,
                                    value_label: typeDesc.valueLabels[s.value],
                                    start_date: haeDate(s.startDate),
                                    end_date: haeDate(s.endDate),
                                    source: s.sourceDisplayName
                                )
                            }
                            try await uploader.add(CategoryRows(samples: samples))
                        }
                        do {
                            let result: (String, Data)?
                            if anchored, let start = since {
                                let key = Self.anchorKey(category: "cat_category", type: typeDesc.id)
                                let changes = try await healthKit.changedCategorySamples(
                                    typeID: typeDesc.hkIdentifier, anchor: syncState.anchors[key], fallbackSince: start)
                                try await upload(changes.added)
                                result = (key, changes.anchor)
                            } else {
                                try await healthKit.streamCategorySamples(
                                    typeID: typeDesc.hkIdentifier, from: since, until: until, handler: upload)
                                result = nil
                            }
                            await SyncTrace.shared.record("category.finished", ["type": typeDesc.id, "rows": String(rows)])
                            return result
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as CategoryUploader.UploadFailed {
                            throw error.underlying
                        }
                    }
                }
                for try await pair in group {
                    if let (key, anchor) = pair { newAnchors[key] = anchor }
                }
            }
            let total = try await uploader.finish()
            syncState.anchors.merge(newAnchors) { _, new in new }
            return total
        } catch {
            await uploader.cancel()
            throw error
        }
    }

    // MARK: - Workout sync

    private func syncWorkouts(since: Date?, until: Date? = nil, anchored: Bool = false) async throws -> SpecialWindow {
        try checkSelection()
        var total: SpecialWindow = (inserted: 0, rows: 0)
        let hrUnit = HKUnit(from: "count/min")
        func upload(_ workouts: [HKWorkout]) async throws {
            for batch in workouts.chunked(into: batchSize) {
                var hbWorkouts: [FreeRepsWorkout] = []
                for w in batch {
                    try checkSelection()
                    // Query per-minute HR aggregates for this workout's time window
                    var hrData: [FreeRepsWorkoutHRPoint]?
                    if w.duration > 0 {
                        do {
                            let buckets = try await self.healthKit.queryAggregatedStatistics(
                                typeID: .heartRate, unit: hrUnit,
                                from: w.startDate, until: w.endDate,
                                interval: 60 // 1-minute buckets, matching HAE format
                            )
                            if !buckets.isEmpty {
                                hrData = buckets.map { b in
                                    FreeRepsWorkoutHRPoint(
                                        date: haeDate(b.startDate),
                                        Min: b.min, Avg: b.avg, Max: b.max,
                                        units: "bpm",
                                        source: w.sourceDisplayName
                                    )
                                }
                            }
                        }
                    }

                    let activeEnergy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()

                    // Location type (indoor/outdoor)
                    let locationType = w.workoutActivities.first?.workoutConfiguration.locationType
                    let isIndoor = locationType == .indoor ? true : locationType == .outdoor ? false : nil
                    let location = locationType == .indoor ? "Indoor" : locationType == .outdoor ? "Outdoor" : nil

                    // Elevation from workout metadata
                    let elevUp = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)
                        .map { FreeRepsQuantity(qty: $0.doubleValue(for: .meter()), units: "m") }
                    let elevDown = (w.metadata?[HKMetadataKeyElevationDescended] as? HKQuantity)
                        .map { FreeRepsQuantity(qty: $0.doubleValue(for: .meter()), units: "m") }

                    // HR summary from per-minute buckets
                    var hrSummary: FreeRepsHRSummary?
                    if let hrs = hrData, !hrs.isEmpty {
                        let count = Double(hrs.count)
                        let avgBPM = hrs.reduce(0.0) { $0 + $1.Avg } / count
                        let maxBPM = hrs.map(\.Max).max()!
                        let minBPM = hrs.map(\.Min).min()!
                        hrSummary = FreeRepsHRSummary(
                            min: FreeRepsQuantity(qty: minBPM, units: "bpm"),
                            avg: FreeRepsQuantity(qty: avgBPM, units: "bpm"),
                            max: FreeRepsQuantity(qty: maxBPM, units: "bpm")
                        )
                    }

                    hbWorkouts.append(FreeRepsWorkout(
                        id: w.uuid.uuidString,
                        name: w.activityTypeName,
                        start: haeDate(w.startDate),
                        end: haeDate(w.endDate),
                        duration: w.duration,
                        location: location,
                        isIndoor: isIndoor,
                        activeEnergyBurned: activeEnergy.map { FreeRepsQuantity(qty: $0.doubleValue(for: .kilocalorie()), units: "kcal") },
                        distance: w.totalDistance.map { FreeRepsQuantity(qty: $0.doubleValue(for: .meter()), units: "m") },
                        elevationUp: elevUp,
                        elevationDown: elevDown,
                        heartRate: hrSummary,
                        heartRateData: hrData
                    ))
                }
                let payload = FreeRepsPayload(data: FreeRepsData(workouts: hbWorkouts))
                try checkSelection()
                let result = try await ingest(payload)
                total.inserted += result.workouts_inserted ?? batch.count
                total.rows += payload.data.rowCount
            }
        }
        if anchored, let start = since {
            let key = Self.anchorKey(category: "cat_workouts", type: "workouts")
            let changes = try await healthKit.changedWorkouts(anchor: syncState.anchors[key], fallbackSince: start)
            try await upload(changes.added)
            syncState.anchors[key] = changes.anchor
        } else {
            try await healthKit.streamWorkouts(from: since, until: until, handler: upload)
        }
        return total
    }

    // MARK: - Blood pressure sync

    private func syncBloodPressure(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        let correlations = try await healthKit.fetchBloodPressure(from: since, until: until)
        guard !correlations.isEmpty else { return 0 }

        let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!
        let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!
        var total = 0

        for batch in correlations.chunked(into: batchSize) {
            // Send systolic and diastolic as separate metrics
            var sysPoints: [FreeRepsMetricDataPoint] = []
            var diaPoints: [FreeRepsMetricDataPoint] = []
            for corr in batch {
                guard let sys = (corr.objects(for: systolicType) as? Set<HKQuantitySample>)?.first,
                      let dia = (corr.objects(for: diastolicType) as? Set<HKQuantitySample>)?.first else { continue }
                sysPoints.append(FreeRepsMetricDataPoint(date: haeDate(corr.startDate), qty: sys.quantity.doubleValue(for: .millimeterOfMercury()), source_uuid: corr.uuid.uuidString))
                diaPoints.append(FreeRepsMetricDataPoint(date: haeDate(corr.startDate), qty: dia.quantity.doubleValue(for: .millimeterOfMercury()), source_uuid: corr.uuid.uuidString))
            }
            if sysPoints.isEmpty { continue }
            let metrics = [
                FreeRepsMetric(name: "blood_pressure_systolic", units: "mmHg", data: sysPoints),
                FreeRepsMetric(name: "blood_pressure_diastolic", units: "mmHg", data: diaPoints),
            ]
            let payload = FreeRepsPayload(data: FreeRepsData(metrics: metrics))
            let result = try await ingest(payload)
            total += result.metrics_inserted ?? sysPoints.count
        }
        return total
    }

    // MARK: - ECG sync

    private func syncECG(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        let recordings = try await healthKit.fetchECG(from: since, until: until)
        guard !recordings.isEmpty else { return 0 }

        var total = 0
        // ECG recordings include voltage data, so batch more conservatively
        for batch in recordings.chunked(into: 50) {
            var items: [FreeRepsECG] = []
            for ecg in batch {
                try checkSelection()
                let voltages = try await healthKit.fetchECGVoltageMeasurements(for: ecg)
                let mvUnit = HKUnit(from: "mV")
                let voltageArray = voltages.compactMap { v -> Double? in
                    v.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: mvUnit)
                }

                items.append(FreeRepsECG(
                    id: ecg.uuid.uuidString,
                    classification: ecg.classification.label,
                    average_heart_rate: ecg.averageHeartRate?.doubleValue(for: HKUnit(from: "count/min")),
                    sampling_frequency: ecg.samplingFrequency?.doubleValue(for: HKUnit(from: "Hz")),
                    voltage_measurements: voltageArray.isEmpty ? nil : voltageArray,
                    start_date: haeDate(ecg.startDate),
                    source: ecg.sourceRevision.source.name
                ))
            }
            guard !items.isEmpty else { continue }
            try checkSelection()
            let payload = FreeRepsPayload(data: FreeRepsData(ecg_recordings: items))
            let result = try await ingest(payload)
            total += result.ecg_recordings_inserted ?? items.count
        }
        return total
    }

    // MARK: - Audiogram sync

    private func syncAudiograms(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        let audiograms = try await healthKit.fetchAudiograms(from: since, until: until)
        guard !audiograms.isEmpty else { return 0 }

        var total = 0
        for batch in audiograms.chunked(into: batchSize) {
            let items: [FreeRepsAudiogram] = batch.map { ag in
                let points = ag.sensitivityPoints.map { pt in
                    AudiogramPoint(
                        hz: pt.frequency.doubleValue(for: .hertz()),
                        left_db: pt.leftEarSensitivity?.doubleValue(for: HKUnit.decibelHearingLevel()),
                        right_db: pt.rightEarSensitivity?.doubleValue(for: HKUnit.decibelHearingLevel())
                    )
                }
                return FreeRepsAudiogram(
                    id: ag.uuid.uuidString,
                    sensitivity_points: points,
                    start_date: haeDate(ag.startDate),
                    source: ag.sourceRevision.source.name
                )
            }
            try checkSelection()
            let payload = FreeRepsPayload(data: FreeRepsData(audiograms: items))
            let result = try await ingest(payload)
            total += result.audiograms_inserted ?? items.count
        }
        return total
    }

    // MARK: - Vision prescription sync

    private func syncVisionPrescriptions(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        let prescriptions = try await healthKit.fetchVisionPrescriptions(from: since, until: until)
        guard !prescriptions.isEmpty else { return 0 }

        let diopterUnit = HKUnit(from: "D")
        let degreeUnit = HKUnit.count()
        let mmUnit = HKUnit.meterUnit(with: .milli)

        var total = 0
        for batch in prescriptions.chunked(into: batchSize) {
            let items: [FreeRepsVisionPrescription] = batch.map { p in
                var rightEye: [String: Double]?
                var leftEye: [String: Double]?

                if let glasses = p as? HKGlassesPrescription {
                    if let r = glasses.rightEye {
                        var eye: [String: Double] = ["sphere": r.sphere.doubleValue(for: diopterUnit)]
                        if let c = r.cylinder { eye["cylinder"] = c.doubleValue(for: diopterUnit) }
                        if let a = r.axis { eye["axis"] = a.doubleValue(for: degreeUnit) }
                        if let add = r.addPower { eye["add"] = add.doubleValue(for: diopterUnit) }
                        rightEye = eye
                    }
                    if let l = glasses.leftEye {
                        var eye: [String: Double] = ["sphere": l.sphere.doubleValue(for: diopterUnit)]
                        if let c = l.cylinder { eye["cylinder"] = c.doubleValue(for: diopterUnit) }
                        if let a = l.axis { eye["axis"] = a.doubleValue(for: degreeUnit) }
                        if let add = l.addPower { eye["add"] = add.doubleValue(for: diopterUnit) }
                        leftEye = eye
                    }
                } else if let contacts = p as? HKContactsPrescription {
                    if let r = contacts.rightEye {
                        var eye: [String: Double] = ["sphere": r.sphere.doubleValue(for: diopterUnit)]
                        if let c = r.cylinder { eye["cylinder"] = c.doubleValue(for: diopterUnit) }
                        if let a = r.axis { eye["axis"] = a.doubleValue(for: degreeUnit) }
                        if let add = r.addPower { eye["add"] = add.doubleValue(for: diopterUnit) }
                        if let bc = r.baseCurve { eye["base_curve"] = bc.doubleValue(for: mmUnit) }
                        if let d = r.diameter { eye["diameter"] = d.doubleValue(for: mmUnit) }
                        rightEye = eye
                    }
                    if let l = contacts.leftEye {
                        var eye: [String: Double] = ["sphere": l.sphere.doubleValue(for: diopterUnit)]
                        if let c = l.cylinder { eye["cylinder"] = c.doubleValue(for: diopterUnit) }
                        if let a = l.axis { eye["axis"] = a.doubleValue(for: degreeUnit) }
                        if let add = l.addPower { eye["add"] = add.doubleValue(for: diopterUnit) }
                        if let bc = l.baseCurve { eye["base_curve"] = bc.doubleValue(for: mmUnit) }
                        if let d = l.diameter { eye["diameter"] = d.doubleValue(for: mmUnit) }
                        leftEye = eye
                    }
                }

                let prescType: String?
                switch p.prescriptionType {
                case .glasses: prescType = "glasses"
                case .contacts: prescType = "contacts"
                @unknown default: prescType = nil
                }

                return FreeRepsVisionPrescription(
                    id: p.uuid.uuidString,
                    date_issued: haeDate(p.startDate),
                    expiration_date: p.expirationDate.map { haeDate($0) },
                    prescription_type: prescType,
                    right_eye: rightEye,
                    left_eye: leftEye,
                    source: p.sourceRevision.source.name
                )
            }
            try checkSelection()
            let payload = FreeRepsPayload(data: FreeRepsData(vision_prescriptions: items))
                        } catch let error where HealthKitService.meansNoDataInRange(error) {
                            // A workout from before the watch: no heart-rate
                            // source for its minutes, not a failed workout (see
                            // `statisticsBuckets`).
                            await SyncTrace.shared.record("workout.hr_empty", [
                                "workout": w.uuid.uuidString, "code": String((error as NSError).code),
                            ])
            let result = try await ingest(payload)
            total += result.vision_prescriptions_inserted ?? items.count
        }
        return total
    }

    // MARK: - State of Mind sync

    private func syncStateOfMind(since: Date?, until: Date? = nil) async throws -> Int {
        try checkSelection()
        if #available(iOS 18, *) {
            return try await syncStateOfMindIOS18(since: since, until: until)
        }
        return 0
    }

    @available(iOS 18, *)
    private func syncStateOfMindIOS18(since: Date?, until: Date? = nil) async throws -> Int {
        let samples = try await healthKit.fetchStateOfMind(from: since, until: until)
        guard !samples.isEmpty else { return 0 }

        var total = 0
        for batch in samples.chunked(into: batchSize) {
            let items: [FreeRepsStateOfMind] = batch.map { sample in
                FreeRepsStateOfMind(
                    id: sample.uuid.uuidString,
                    kind: sample.kind.rawValue,
                    valence: sample.valence,
                    labels: sample.labels.map { $0.rawValue },
                    associations: sample.associations.map { $0.rawValue },
                    start_date: haeDate(sample.startDate),
                    source: sample.sourceRevision.source.name
                )
            }
            try checkSelection()
            let payload = FreeRepsPayload(data: FreeRepsData(state_of_mind: items))
            let result = try await ingest(payload)
            total += result.state_of_mind_inserted ?? items.count
        }
        return total
    }
}

// MARK: - Sync prerequisite issues

enum SyncPrerequisiteIssue: Identifiable {
    case healthDataUnavailable
    case healthPermissionsNotRequested
    case somePermissionsDenied(count: Int)
    case connectionFailed(String)

    var id: String {
        switch self {
        case .healthDataUnavailable: return "healthUnavailable"
        case .healthPermissionsNotRequested: return "permissionsNotRequested"
        case .somePermissionsDenied: return "permissionsDenied"
        case .connectionFailed: return "connectionFailed"
        }
    }

    var title: String {
        switch self {
        case .healthDataUnavailable:
            return "Health Data Unavailable"
        case .healthPermissionsNotRequested:
            return "Health Permissions Not Requested"
        case .somePermissionsDenied(let count):
            return "\(count) Health Permission(s) Denied"
        case .connectionFailed:
            return "FreeReps Connection Failed"
        }
    }

    var message: String {
        switch self {
        case .healthDataUnavailable:
            return "HealthKit is not available on this device."
        case .healthPermissionsNotRequested:
            return "Go to Settings \u{2192} Apple Health Permissions and request access to sync all your health data."
        case .somePermissionsDenied:
            return "Some health data types were denied. Go to Settings \u{2192} Health Permissions to review and re-request missing permissions."
        case .connectionFailed(let err):
            return "Could not connect to FreeReps: \(err). Check your connection settings."
        }
    }

    var actionLabel: String {
        switch self {
        case .healthDataUnavailable: return ""
        case .healthPermissionsNotRequested: return "Review Permissions"
        case .somePermissionsDenied: return "Review Permissions"
        case .connectionFailed: return "Check Settings"
        }
    }
}

// MARK: - Array chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
