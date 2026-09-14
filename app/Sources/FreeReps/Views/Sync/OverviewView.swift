import SwiftUI

/// The everyday answer: is the server up to date, what arrived last night,
/// and how much is stored. Per-category detail lives in the Data tab.
struct OverviewView: View {
    @ObservedObject var vm: SyncViewModel
    @ObservedObject private var selection = HealthSyncSelection.shared
    @StateObject private var server = ServerOverview()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                lastNightSection
                serverSection
                BrandFooter()
            }
            .navigationTitle("Overview")
            .refreshable { await server.load() }
            .task { await server.load() }
            .onAppear { vm.refreshLatestHealthKitDates() }
            .onChange(of: vm.isAnySyncRunning) { _, running in
                if !running { Task { await server.load() } }
            }
        }
    }

    // MARK: - Status

    private enum Status {
        case paused, syncing, failed(String), behind(Int), neverSynced, upToDate(Date)
    }

    private var included: [CategorySyncState] {
        vm.categories.filter { $0.id != "cat_strength" && selection.includes($0.id) }
    }

    private var status: Status {
        if !selection.isEnabled { return .paused }
        if vm.isAnySyncRunning { return .syncing }
        let failed = included.filter { if case .failed = $0.status { return true } else { return false } }
        if let message = vm.errorMessage { return .failed(message) }
        if !failed.isEmpty {
            return .failed(failed.count == 1 ? "\(failed[0].displayName) couldn't sync." : "\(failed.count) categories couldn't sync.")
        }
        let behind = included.filter { $0.daysBehind != nil }.count
        if behind > 0 { return .behind(behind) }
        guard let last = vm.lastSyncDate else { return .neverSynced }
        return .upToDate(last)
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: statusIcon.name)
                    .font(.system(size: 30))
                    .foregroundStyle(statusIcon.color)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)

            if vm.isAnySyncRunning {
                ProgressView(value: vm.overallProgress)
                    .tint(.blue)
                Button("Cancel Sync", role: .destructive) { vm.cancelSync() }
            } else if selection.isEnabled {
                Button("Sync Now") { vm.startRecentSync() }
                    .accessibilityIdentifier("sync-now")
                if !vm.hasCompletedFullSync {
                    Button("Import History") { vm.startFullSync() }
                }
            }
        } footer: {
            if selection.isEnabled && !vm.isAnySyncRunning && !vm.hasCompletedFullSync {
                Text("Older data isn't on your server yet. Importing history reads all of it once; keep FreeReps open while it runs.")
            }
        }
    }

    private var statusIcon: (name: String, color: Color) {
        switch status {
        case .paused: return ("pause.circle.fill", .secondary)
        case .syncing: return ("arrow.triangle.2.circlepath.circle.fill", .blue)
        case .failed: return ("exclamationmark.circle.fill", .red)
        case .behind: return ("clock.badge.exclamationmark.fill", .orange)
        case .neverSynced: return ("circle.dashed", .secondary)
        case .upToDate: return ("checkmark.circle.fill", .green)
        }
    }

    private var statusTitle: String {
        switch status {
        case .paused: return "Sync Paused"
        case .syncing: return "Syncing"
        case .failed: return "Sync Failed"
        case .behind: return "Not Up to Date"
        case .neverSynced: return "Not Synced Yet"
        case .upToDate: return "Up to Date"
        }
    }

    private var statusSubtitle: String {
        switch status {
        case .paused: return "Connect Apple Health in Settings to sync."
        case .syncing: return vm.currentOperation.isEmpty ? "Reading Apple Health…" : vm.currentOperation
        case .failed(let message): return message
        case .behind(let count): return count == 1 ? "1 category has newer data." : "\(count) categories have newer data."
        case .neverSynced: return "Sync to send your Health data to your server."
        case .upToDate(let date): return "Synced \(date.formatted(.relative(presentation: .named)))"
        }
    }

    // MARK: - Last night

    private var lastNightSection: some View {
        Section {
            if let night = server.lastNight {
                LabeledContent("Sleep", value: Self.duration(hours: night.hours))
                LabeledContent("Asleep", value: "\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
            } else {
                Text(server.state == .loading ? "Loading…" : "No sleep on your server yet")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Last Night")
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            if let stats = server.stats {
                LabeledContent("Health Metrics", value: stats.metrics.formatted())
                LabeledContent("Workouts", value: stats.workouts.formatted())
                LabeledContent("Sleep Nights", value: stats.sleepNights.formatted())
                if let earliest = stats.earliest {
                    LabeledContent("Since", value: earliest.formatted(.dateTime.month(.wide).year()))
                }
            } else {
                Text(server.state == .loading ? "Loading…" : "Not available")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On Your Server")
        } footer: {
            if case .failed(let message) = server.state {
                Text(message)
            }
        }
    }

    private static func duration(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Reads what the server holds, independent of this iPhone's sync state.
@MainActor
final class ServerOverview: ObservableObject {
    enum State: Equatable { case loading, loaded, failed(String) }

    struct Stats {
        let metrics: Int
        let workouts: Int
        let sleepNights: Int
        let earliest: Date?
    }

    struct Night {
        let hours: Double
        let start: Date
        let end: Date
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var stats: Stats?
    @Published private(set) var lastNight: Night?

    func load() async {
        let service = FreeRepsService(config: .load())
        do {
            let statsData = try await service.get(path: "api/v1/stats")
            let since = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
            let sleepData = try await service.get(path: "api/v1/sleep", queryItems: [
                URLQueryItem(name: "start", value: since.formatted(.iso8601.year().month().day())),
            ])
            stats = Self.decodeStats(statsData)
            lastNight = Self.decodeLastNight(sleepData)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed("Your server couldn't be reached: \(error.localizedDescription)")
        }
    }

    private static func decodeStats(_ data: Data) -> Stats? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Stats(metrics: json["total_metric_rows"] as? Int ?? 0,
                     workouts: json["total_workouts"] as? Int ?? 0,
                     sleepNights: json["total_sleep_nights"] as? Int ?? 0,
                     earliest: (json["earliest_data"] as? String).flatMap(date))
    }

    /// The newest session that ended within the last 24 hours.
    private static func decodeLastNight(_ data: Data) -> Night? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]] else { return nil }
        let nights = sessions.compactMap { session -> Night? in
            guard let hours = session["TotalSleep"] as? Double, hours > 0,
                  let start = (session["SleepStart"] as? String).flatMap(date),
                  let end = (session["SleepEnd"] as? String).flatMap(date) else { return nil }
            return Night(hours: hours, start: start, end: end)
        }
        return nights
            .filter { Date().timeIntervalSince($0.end) < 24 * 3600 }
            .max { $0.end < $1.end }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
