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
}

// MARK: -

enum SyncStatus: Equatable {
    case idle
    case syncing
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .syncing: return "Syncing…"
        case .completed: return "Synced"
        case .failed: return "Error"
        }
    }

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

    /// "Mar – Jun 2025 · 4 of 9 periods" while a window of older data is being read.
    var periodLabel: String? {
        guard let period else { return nil }
        let months = period.formatted(Date.IntervalFormatStyle().month(.abbreviated).year())
        return "\(months) · \(currentProgress + 1) of \(totalEstimated) periods"
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
    @Published var overallProgress: Double = 0.0
    @Published var currentOperation: String = ""
    @Published var errorMessage: String?
    @Published var hasCompletedFullSync: Bool = false
    @Published var backfillCursors: [String: Date] = [:]
    @Published var backfillAnchorDate: Date?
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

        recalcOverall()
    }

    func resetAllLocalState() {
        overallProgress = 0
        backfillCursors = [:]
        backfillAnchorDate = nil
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
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].status = .idle
        categories[idx].recordCount = 0
        categories[idx].lastSyncDate = nil
        categories[idx].currentProgress = 0
        persist()
    }

    func recalcOverall() {
        let total = Double(categories.count)
        guard total > 0 else {
            overallProgress = 0
            return
        }
        let completedCount = Double(categories.filter { $0.status == .completed }.count)
        let syncingProgress = categories.filter { $0.status.isActive }.map { $0.progressFraction }.reduce(0, +)
        overallProgress = (completedCount + syncingProgress) / total
        // totalRecords is not summed from per-category session counts here —
        // it is set directly from actual DB COUNT(*) queries in refreshRecordCounts().
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
            backfillAnchorDate: backfillAnchorDate
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
        for persisted in snap.categories {
            guard let idx = categories.firstIndex(where: { $0.id == persisted.id }) else { continue }
            categories[idx].recordCount = persisted.recordCount
            categories[idx].lastSyncDate = persisted.lastSyncDate
            if persisted.completed { categories[idx].status = .completed }
            if let message = persisted.failureMessage { categories[idx].status = .failed(message) }
        }
        recalcOverall()
    }
}
