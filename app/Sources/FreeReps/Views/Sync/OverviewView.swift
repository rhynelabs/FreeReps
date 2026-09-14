import SwiftUI

/// The everyday answer: is the server up to date, what arrived last night,
/// and how much is stored. Per-category detail and older data live in the
/// Sync tab.
///
/// A `List` of inset-grouped sections in the density of Settings: a status row
/// like `HealthPermissionsView`, plain button rows, `LabeledContent` for values.
struct OverviewView: View {
    @ObservedObject var vm: SyncViewModel
    @ObservedObject private var selection = HealthSyncSelection.shared
    @StateObject private var server = ServerOverview()
    /// Ticks so "Synced 4 minutes ago" ages while the page stays open.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if server.stats == nil, case .failed(let message) = server.state {
                    unreachableSection(message)
                } else {
                    lastNightSection
                    serverSection
                }
                BrandFooter()
            }
            .navigationTitle("Overview")
            .refreshable {
                // Pulling down means "get the newest data", not just re-read the server.
                if !vm.isAnySyncRunning, selection.isEnabled { vm.startRecentSync() }
                await server.load()
            }
            .task { await server.load() }
            .onAppear {
                now = Date()
                vm.refreshLatestHealthKitDates()
            }
            .onReceive(clock) { now = $0 }
            .onChange(of: vm.isAnySyncRunning) { _, running in
                if !running {
                    now = Date()
                    Task { await server.load() }
                }
            }
        }
    }

    // MARK: - Status

    private enum Status {
        case paused, syncing(older: Bool), failed(String), behind(Int), neverSynced, upToDate(Date)
    }

    private var included: [CategorySyncState] {
        vm.categories.filter { $0.id != "cat_strength" && selection.includes($0.id) }
    }

    private var status: Status {
        if !selection.isEnabled { return .paused }
        if vm.isAnySyncRunning { return .syncing(older: vm.isFullSyncRunning) }
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
                    .symbolEffect(.pulse, isActive: vm.isAnySyncRunning)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if vm.isAnySyncRunning {
                        ProgressView(value: vm.overallProgress)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.vertical, 4)

            if vm.isAnySyncRunning {
                Button(vm.isFullSyncRunning ? "Stop" : "Cancel Sync", role: .destructive) { vm.cancelSync() }
            } else if selection.isEnabled {
                Button(isFailed ? "Try Again" : "Sync Now") { vm.startRecentSync() }
                    .accessibilityIdentifier("sync-now")
            }
        }
    }

    private var statusIcon: (name: String, color: Color) {
        switch status {
        case .paused: return ("pause.circle.fill", .secondary)
        case .syncing: return ("arrow.triangle.2.circlepath.circle.fill", .blue)
        case .failed: return ("exclamationmark.circle.fill", .red)
        case .behind: return ("clock.badge.exclamationmark.fill", .orange)
        case .neverSynced: return ("arrow.up.heart.fill", .blue)
        case .upToDate: return ("checkmark.circle.fill", .green)
        }
    }

    private var statusTitle: String {
        switch status {
        case .paused: return "Sync Paused"
        case .syncing(let older): return older ? "Syncing Older Data" : "Syncing New Data"
        case .failed: return "Sync Failed"
        case .behind: return "Not Up to Date"
        case .neverSynced: return "Not Synced Yet"
        case .upToDate: return "Up to Date"
        }
    }

    private var statusSubtitle: String {
        switch status {
        case .paused: return "Connect Apple Health in Settings to sync."
        case .syncing: return vm.currentOperation.isEmpty ? "Reading Apple Health\u{2026}" : vm.currentOperation
        case .failed(let message): return message
        case .behind(let count): return count == 1 ? "1 category has newer data." : "\(count) categories have newer data."
        case .neverSynced: return "Send your Health data to your server."
        case .upToDate(let date): return syncedLabel(date)
        }
    }

    /// "Synced just now" for the first minute, then "Synced 4 minutes ago".
    private func syncedLabel(_ date: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Synced just now" }
        return "Synced \(date.formatted(.relative(presentation: .named)))"
    }

    private var isFailed: Bool {
        if case .failed = status { return true } else { return false }
    }

    // MARK: - Server

    private var lastNightSection: some View {
        Section("Last Night") {
            if let night = server.lastNight {
                nightRows(night)
            } else if server.state == .loading {
                nightRows(.init(hours: 7.5, start: .now, end: .now))
                    .redacted(reason: .placeholder)
            } else {
                Text("No sleep recorded")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func nightRows(_ night: ServerOverview.Night) -> some View {
        let minutes = Int((night.hours * 60).rounded())
        LabeledContent("Sleep", value: Duration.seconds(minutes * 60), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
        LabeledContent("Asleep", value: "\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
            .monospacedDigit()
    }

    private var serverSection: some View {
        Section {
            if let stats = server.stats {
                statRows(stats)
            } else {
                statRows(.init(metrics: 1_000_000, workouts: 100, sleepNights: 100, earliest: .now, latest: .now))
                    .redacted(reason: .placeholder)
            }
        } header: {
            Text("On Your Server")
        } footer: {
            if case .failed(let message) = server.state {
                Text("Couldn't refresh: \(message)")
            }
        }
    }

    @ViewBuilder
    private func statRows(_ stats: ServerOverview.Stats) -> some View {
        if let latest = stats.latest {
            LabeledContent("Latest Data", value: latest, format: .dateTime.month(.abbreviated).day().hour().minute())
        }
        LabeledContent("Health Metrics", value: stats.metrics, format: .number)
        LabeledContent("Workouts", value: stats.workouts, format: .number)
        LabeledContent("Sleep Nights", value: stats.sleepNights, format: .number)
        if let earliest = stats.earliest {
            LabeledContent("Since", value: earliest, format: .dateTime.month(.abbreviated).year())
        }
    }

    private func unreachableSection(_ message: String) -> some View {
        Section("On Your Server") {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server Not Reachable")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Button("Try Again") { Task { await server.load() } }
        }
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
        /// Newest sample the server holds, whatever sent it.
        let latest: Date?
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
        // Placeholders while nothing is known; a refresh keeps the last values on screen.
        if stats == nil { state = .loading }
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
            state = .failed(error.localizedDescription)
        }
    }

    private static func decodeStats(_ data: Data) -> Stats? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Stats(metrics: json["total_metric_rows"] as? Int ?? 0,
                     workouts: json["total_workouts"] as? Int ?? 0,
                     sleepNights: json["total_sleep_nights"] as? Int ?? 0,
                     earliest: (json["earliest_data"] as? String).flatMap(date),
                     latest: (json["latest_data"] as? String).flatMap(date))
    }

    /// The newest session that ended within the last 24 hours. Falls back to the
    /// sleep stages of that stretch: the server builds the session from them
    /// after an upload, and until it has, the stages are what it holds.
    private static func decodeLastNight(_ data: Data) -> Night? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let recent = { (end: Date) in Date().timeIntervalSince(end) < 24 * 3600 }
        let sessions = (json["sessions"] as? [[String: Any]] ?? []).compactMap { session -> Night? in
            guard let hours = session["TotalSleep"] as? Double, hours > 0,
                  let start = (session["SleepStart"] as? String).flatMap(date),
                  let end = (session["SleepEnd"] as? String).flatMap(date) else { return nil }
            return Night(hours: hours, start: start, end: end)
        }
        if let night = sessions.filter({ recent($0.end) }).max(by: { $0.end < $1.end }) { return night }

        let asleep: Set<String> = ["Core", "Deep", "REM", "Asleep"]
        let stages = (json["stages"] as? [[String: Any]] ?? []).compactMap { stage -> (start: Date, end: Date, hours: Double)? in
            guard let start = (stage["StartTime"] as? String).flatMap(date),
                  let end = (stage["EndTime"] as? String).flatMap(date),
                  let name = stage["Stage"] as? String else { return nil }
            let hours = asleep.contains(name) ? (stage["DurationHr"] as? Double ?? 0) : 0
            return (start, end, hours)
        }
        .filter { recent($0.end) }
        .sorted { $0.start < $1.start }
        // A break of more than three hours separates a nap from the night.
        var night: [(start: Date, end: Date, hours: Double)] = []
        for stage in stages {
            if let last = night.last, stage.start.timeIntervalSince(last.end) > 3 * 3600 { night = [] }
            night.append(stage)
        }
        guard let first = night.first, let last = night.last else { return nil }
        let hours = night.reduce(0) { $0 + $1.hours }
        return hours > 0 ? Night(hours: hours, start: first.start, end: last.end) : nil
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
