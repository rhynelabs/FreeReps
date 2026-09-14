import Foundation
import Combine

// MARK: - Persistence helpers

struct PersistedCategory: Codable {
    let id: String
    let recordCount: Int
    let lastSyncDate: Date?
    let completed: Bool
    var failureMessage: String? = nil
}

struct PersistedSnapshot: Codable {
    let lastSyncDate: Date?
    let categories: [PersistedCategory]
    let totalRecords: Int?
    let hasCompletedFullSync: Bool?
    let backfillCursors: [String: Date]?
    let backfillAnchorDate: Date?
    var anchors: [String: Data]? = nil
    var routesPending: [String: Date]? = nil
}

// MARK: -

enum SyncStatus: Equatable {
    case idle
    case syncing
    case completed
    case failed(String)

    var isActive: Bool {
        if case .syncing = self { return true }
        return false
    }
}

struct CategorySyncState: Identifiable {
    let id: String          // category identifier
    let displayName: String
    let systemImage: String
    var status: SyncStatus
    var recordCount: Int
    var lastSyncDate: Date?
    var currentProgress: Int
    var totalEstimated: Int
    var latestHealthKitDate: Date? = nil  // newest HK sample, queried on demand (not persisted)
    var period: Range<Date>? = nil        // the 90-day window of older data being read (not persisted)

    var progressFraction: Double {
        guard totalEstimated > 0 else { return 0 }
        return min(1.0, Double(currentProgress) / Double(totalEstimated))
    }

    /// "Mar – Jun 2025" while that stretch of older data is being read.
    var periodLabel: String? {
        period?.formatted(Date.IntervalFormatStyle().month(.abbreviated).year())
    }

    var daysBehind: Int? {
        guard let latestHK = latestHealthKitDate,
              let lastSync = lastSyncDate,
              latestHK > lastSync else { return nil }
        let days = Calendar.current.dateComponents([.day], from: lastSync, to: latestHK).day ?? 0
        return days >= 1 ? days : nil
    }
}

@MainActor
class SyncState: ObservableObject {
    // Foreground views and background jobs must update the same snapshot.
    static let shared = SyncState()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    @Published var isFullSyncRunning = false
    @Published var isIncrementalSyncRunning = false
    @Published var categories: [CategorySyncState] = []
    @Published var totalRecords: Int = 0
    @Published var lastSyncDate: Date?
    /// Share of the current run that is done; `SyncService` counts it up in equal steps.
    @Published var overallProgress: Double = 0.0
    @Published var currentOperation: String = ""
    @Published var errorMessage: String?
    @Published var hasCompletedFullSync: Bool = false
    @Published var backfillCursors: [String: Date] = [:]
    @Published var backfillAnchorDate: Date?
    /// HealthKit query anchors by `SyncService.anchorKey`, each stored once the
    /// samples it covers are on the server. A daily sync reads only what was
    /// added after its anchor.
    var anchors: [String: Data] = [:]
    /// Workouts (UUID string → end date) the routes anchor has passed but that
    /// had no route yet: the watch can deliver the route a while after the
    /// workout. Each is checked again on the next runs until it has one or is
    /// too old to expect one.
    var routesPending: [String: Date] = [:]
    /// Rows the server reported as newly inserted in the current or last run. Not persisted;
    /// this is the number the Live Activity shows.
    @Published var newRecordsThisRun = 0

    var isAnySyncRunning: Bool { isFullSyncRunning || isIncrementalSyncRunning }

    enum OlderDataProgress: Equatable {
        case notStarted
        case sentUpTo(Date)
    }

    /// Where an unfinished older-data sync stands for a category; nil when nothing is pending
    /// for it. Older data is sent forward in time from the configured start until the run's
    /// anchor, so a cursor at the anchor means the category is done.
    func olderDataProgress(for id: String) -> OlderDataProgress? {
        guard let anchor = backfillAnchorDate, !hasCompletedFullSync else { return nil }
        guard let cursor = backfillCursors[id] else { return .notStarted }
        return cursor < anchor ? .sentUpTo(cursor) : nil
    }

    func updateCategory(_ id: String, status: SyncStatus? = nil, recordCount: Int? = nil,
                        lastSyncDate: Date? = nil, progress: Int? = nil, total: Int? = nil,
                        period: Range<Date>? = nil) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        if let s = status {
            categories[idx].status = s
            if !s.isActive { categories[idx].period = nil }
        }
        if let r = recordCount { categories[idx].recordCount = r }
        if let d = lastSyncDate { categories[idx].lastSyncDate = d }
        if let p = progress { categories[idx].currentProgress = p }
        if let t = total { categories[idx].totalEstimated = t }
        if let period { categories[idx].period = period }
    }

    func resetAllLocalState() {
        overallProgress = 0
        backfillCursors = [:]
        backfillAnchorDate = nil
        anchors = [:]
        routesPending = [:]
        hasCompletedFullSync = false
        lastSyncDate = nil
        totalRecords = 0
        currentOperation = ""
        errorMessage = nil
        for i in categories.indices {
            categories[i].status = .idle
            categories[i].recordCount = 0
            categories[i].lastSyncDate = nil
            categories[i].currentProgress = 0
            categories[i].latestHealthKitDate = nil
        }
        persist()
    }

    func resetCategoryLocalState(_ id: String) {
        backfillCursors.removeValue(forKey: id)
        anchors = anchors.filter { !$0.key.hasPrefix("\(id)/") }
        if id == "cat_workout_routes" { routesPending = [:] }
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].status = .idle
        categories[idx].recordCount = 0
        categories[idx].lastSyncDate = nil
        categories[idx].currentProgress = 0
        persist()
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "com.freereps.syncSnapshot"

    func persist() {
        let snap = PersistedSnapshot(
            lastSyncDate: lastSyncDate,
            categories: categories.map { category in
                PersistedCategory(
                    id: category.id,
                    recordCount: category.recordCount,
                    lastSyncDate: category.lastSyncDate,
                    completed: category.status == .completed,
                    failureMessage: {
                        if case .failed(let message) = category.status { return message }
                        return nil
                    }()
                )
            },
            totalRecords: totalRecords,
            hasCompletedFullSync: hasCompletedFullSync,
            backfillCursors: backfillCursors.isEmpty ? nil : backfillCursors,
            backfillAnchorDate: backfillAnchorDate,
            anchors: anchors.isEmpty ? nil : anchors,
            routesPending: routesPending.isEmpty ? nil : routesPending
        )
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    func restore() {
        guard
            let data = defaults.data(forKey: Self.userDefaultsKey),
            let snap = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else { return }
        lastSyncDate = snap.lastSyncDate
        if let saved = snap.totalRecords { totalRecords = saved }
        hasCompletedFullSync = snap.hasCompletedFullSync ?? false
        backfillCursors = snap.backfillCursors ?? [:]
        backfillAnchorDate = snap.backfillAnchorDate
        anchors = snap.anchors ?? [:]
        routesPending = snap.routesPending ?? [:]
        for persisted in snap.categories {
            guard let idx = categories.firstIndex(where: { $0.id == persisted.id }) else { continue }
            categories[idx].recordCount = persisted.recordCount
            categories[idx].lastSyncDate = persisted.lastSyncDate
            if persisted.completed { categories[idx].status = .completed }
            if let message = persisted.failureMessage { categories[idx].status = .failed(message) }
        }
    }
}
