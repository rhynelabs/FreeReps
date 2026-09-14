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
                    todaySection
                    lastNightSection
                    workoutsSection
                    serverSection
                }
                BrandFooter()
            }
            .navigationTitle("Overview")
            // Five cards have to share one screen; the default gap between them is
            // sized for pages with two.
            .listSectionSpacing(.compact)
            .refreshable {
                // Pulling down means "get the newest data", not just re-read the server.
                if !vm.isAnySyncRunning, selection.isEnabled { vm.startRecentSync() }
                await server.load(force: true)
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
                    // The symbols share the filled circle, so a replace effect
                    // draws the old and new glyph half transparent over each
                    // other while the tint blends green to blue — the "ghost".
                    // The icon swaps in one frame like the texts beside it.
                    .contentTransition(.identity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .contentTransition(.identity)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.identity)
                    if vm.isAnySyncRunning {
                        ProgressView(value: vm.overallProgress)
                            .padding(.top, 4)
                            .transition(.identity)
                    }
                }
            }
            .padding(.vertical, 4)
            // Pull-to-refresh flips `isAnySyncRunning` inside the List's animated
            // refresh transaction. Left alone, the texts cross-fade (old and new
            // copy half transparent on top of each other) and the row height
            // eases; the state should just swap.
            .transaction { $0.animation = nil }
            .id("status-row")

            // One row for both states. Two `if` branches give the List two
            // different rows to delete and insert, which it cross-fades.
            if vm.isAnySyncRunning || selection.isEnabled {
                Button(actionTitle, role: vm.isAnySyncRunning ? .destructive : nil) {
                    if vm.isAnySyncRunning { vm.cancelSync() } else { vm.startRecentSync() }
                }
                .accessibilityIdentifier(vm.isAnySyncRunning ? "cancel-sync" : "sync-now")
                .transaction { $0.animation = nil }
                .id("status-action")
            }
        }
    }

    private var actionTitle: String {
        if vm.isAnySyncRunning { return vm.isFullSyncRunning ? "Stop" : "Cancel Sync" }
        return isFailed ? "Try Again" : "Sync Now"
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

    // MARK: - Today

    @Environment(\.colorScheme) private var scheme

    /// The header names the day the card shows. It is "Today" only when the
    /// data is from today; a phone that has not synced since Thursday reads
    /// "Thursday" over Thursday's numbers instead of an empty today.
    private var todaySection: some View {
        Section(Self.dayLabel(server.activity?.day ?? server.steps?.day ?? Date())) {
            if let activity = server.activity {
                activityRows(activity)
            } else if server.state == .loading {
                activityRows(Self.placeholderActivity)
                    .redacted(reason: .placeholder)
            } else {
                Text("No activity recorded")
                    .foregroundStyle(.secondary)
            }

            if let steps = server.steps {
                stepsRows(steps)
            } else if server.state == .loading {
                stepsRows(Self.placeholderSteps)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private func activityRows(_ activity: ServerOverview.Activity) -> some View {
        // The three rings as columns, with no heading of their own: the day
        // above the card and the three names under the numbers say what this is.
        HStack(alignment: .top, spacing: 14) {
            ActivityColumn(title: "Move", value: activity.move, goal: activity.moveGoal,
                           unit: "KCAL", color: FitnessColor.move(scheme))
            ActivityColumn(title: "Exercise", value: activity.exercise, goal: activity.exerciseGoal,
                           unit: "MIN", color: FitnessColor.exercise(scheme))
            ActivityColumn(title: "Stand", value: activity.stand, goal: activity.standGoal,
                           unit: "HR", color: FitnessColor.stand(scheme))
        }
        .padding(.vertical, 6)
    }

    private func stepsRows(_ steps: ServerOverview.Steps) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps")
                    .font(.headline)
                Spacer()
                Text(steps.total, format: .number)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            StepsChart(hours: steps.hours, color: FitnessColor.steps(scheme))
        }
        .padding(.vertical, 4)
    }

    private static var placeholderActivity: ServerOverview.Activity {
        .init(day: Calendar.current.startOfDay(for: Date()), move: 472, moveGoal: 750,
              exercise: 36, exerciseGoal: 30, stand: 7, standGoal: 12)
    }

    private static var placeholderSteps: ServerOverview.Steps {
        var hours = [Double](repeating: 0, count: 24)
        for hour in 7..<21 { hours[hour] = Double((hour * 137) % 400 + 60) }
        return .init(day: Calendar.current.startOfDay(for: Date()), total: 5_242, hours: hours)
    }

    // MARK: - Day labels

    /// "Today", "Yesterday", then "3 Days Ago", "2 Weeks Ago" — a section
    /// header, so every word is capitalized.
    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return relativeLabel(day)
    }

    /// The night is named by the morning it ended in: "Last Night" when that
    /// was today, "2 Nights Ago" when yesterday, then the same words as the
    /// day header so the two read alike.
    private static func nightLabel(_ end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(end) { return "Last Night" }
        if calendar.isDateInYesterday(end) { return "2 Nights Ago" }
        return relativeLabel(end)
    }

    private static func relativeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        // Foundation rounds to weeks and months on its own past a week.
        if days < 7 { return "\(days) Days Ago" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide)).capitalized
    }

    // MARK: - Workouts

    private var workoutsSection: some View {
        Section("Recent Workouts") {
            if let workouts = server.workouts, !workouts.isEmpty {
                ForEach(workouts) { WorkoutRow(workout: $0) }
            } else if server.workouts == nil, server.state == .loading {
                ForEach(Self.placeholderWorkouts) { WorkoutRow(workout: $0) }
                    .redacted(reason: .placeholder)
            } else {
                Text("No workouts in the last two weeks")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var placeholderWorkouts: [ServerOverview.Workout] {
        (0..<3).map { index in
            .init(id: "placeholder-\(index)", name: "Outdoor Walk",
                  start: Date().addingTimeInterval(Double(-index) * 86_400),
                  duration: 2_580, distanceMeters: 6_398)
        }
    }

    // MARK: - Server

    private var lastNightSection: some View {
        Section(server.lastNight.map { Self.nightLabel($0.end) } ?? "Last Night") {
            if let night = server.lastNight {
                nightRows(night)
            } else if server.state == .loading {
                nightRows(Self.placeholderNight)
                    .redacted(reason: .placeholder)
            } else {
                Text("No sleep recorded")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nightRows(_ night: ServerOverview.Night) -> some View {
        let minutes = Int((night.hours * 60).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sleep")
                    .font(.headline)
                Spacer()
                Text(Duration.seconds(minutes * 60)
                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(.headline)
                    .monospacedDigit()
            }
            Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !night.stages.isEmpty {
                SleepStagesChart(start: night.start, end: night.end, stages: night.stages)
            }
        }
        .padding(.vertical, 4)
    }

    /// A plausible night to show redacted while the server is being read.
    private static var placeholderNight: ServerOverview.Night {
        let pattern: [(ServerOverview.Night.Kind, Double)] = [
            (.core, 1.2), (.deep, 0.8), (.core, 1.0), (.rem, 0.7), (.awake, 0.2),
            (.core, 1.4), (.deep, 0.6), (.rem, 0.9), (.core, 0.7),
        ]
        let start = Date().addingTimeInterval(-7.5 * 3600)
        var cursor = start
        var stages: [ServerOverview.Night.Stage] = []
        for (kind, hours) in pattern {
            let next = cursor.addingTimeInterval(hours * 3600)
            stages.append(.init(start: cursor, end: next, kind: kind))
            cursor = next
        }
        return .init(hours: 7.5, start: start, end: cursor, stages: stages)
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
            Button("Try Again") { Task { await server.load(force: true) } }
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

    /// One day of Apple's activity rings, as the watch closed them.
    struct Activity {
        /// Local midnight of the day the rings belong to.
        let day: Date
        let move: Double
        let moveGoal: Double
        let exercise: Double
        let exerciseGoal: Double
        let stand: Double
        let standGoal: Double
    }

    /// One day's steps, and how they fell across the hours of this time zone.
    struct Steps {
        /// Local midnight of the day the steps belong to.
        let day: Date
        let total: Int
        /// Twenty-four values, midnight first.
        let hours: [Double]
    }

    struct Workout: Identifiable {
        let id: String
        let name: String
        let start: Date
        let duration: TimeInterval
        let distanceMeters: Double?
    }

    struct Night {
        let hours: Double
        let start: Date
        let end: Date
        /// The stages of this night, in order. Empty when the server holds the
        /// session but no detail.
        var stages: [Stage] = []

        struct Stage {
            let start: Date
            let end: Date
            let kind: Kind
        }

        /// What the server calls "Asleep" or "In Bed" — and anything unknown —
        /// is a night without stage detail.
        enum Kind: Hashable {
            case awake, rem, core, deep, asleep

            init(_ name: String) {
                switch name {
                case "Awake": self = .awake
                case "REM": self = .rem
                case "Core": self = .core
                case "Deep": self = .deep
                default: self = .asleep
                }
            }
        }
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var stats: Stats?
    @Published private(set) var lastNight: Night?
    @Published private(set) var activity: Activity?
    @Published private(set) var steps: Steps?
    @Published private(set) var workouts: [Workout]?

    /// The load in flight, if any. Appearance, the end of a sync and a pull to
    /// refresh each ask for a load and tend to arrive within the same second;
    /// one set of requests serves them all.
    private var inFlight: Task<Void, Never>?
    /// When the last load ended, loaded or failed. Appearance and the end of a
    /// sync also arrive a second *apart* — too late to join the load in flight,
    /// too soon for the server to hold anything new.
    private var lastFinished: Date?
    private static let reloadInterval: TimeInterval = 2

    /// `force` is for the user's own hand — pull to refresh, Try Again — which
    /// always loads. Everything else is a no-op right after a finished load.
    func load(force: Bool = false) async {
        if let inFlight {
            await inFlight.value
            return
        }
        if !force, let lastFinished, Date().timeIntervalSince(lastFinished) < Self.reloadInterval {
            return
        }
        let task = Task { await fetch() }
        inFlight = task
        defer { inFlight = nil }
        // The caller that started the load owns it: when SwiftUI cancels that
        // caller, the requests stop as they did before the load was shared.
        // Callers that only joined return quietly, the last values still shown.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func fetch() async {
        // Placeholders while nothing is known; a refresh keeps the last values on screen.
        if stats == nil { state = .loading }
        let service = FreeRepsService(config: .load())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let day = { (offset: Int) in
            (calendar.date(byAdding: .day, value: offset, to: today) ?? today)
                .formatted(.iso8601.year().month().day())
        }

        // All five requests go out together. Only the two the page has always
        // shown decide whether the server counts as reachable; a server that
        // does not answer for rings, steps or workouts leaves those cards empty
        // instead of hiding everything behind "not reachable".
        //
        // Rings and sleep are asked for weeks, not days: the card names the day
        // it shows, so a phone that has not synced for a while still shows its
        // newest day rather than an empty today.
        async let statsData = service.get(path: "api/v1/stats")
        async let sleepData = service.get(path: "api/v1/sleep", queryItems: [
            URLQueryItem(name: "start", value: day(-30)),
        ])
        async let activityData: Data? = try? await service.get(path: "api/v1/activity-summaries", queryItems: [
            URLQueryItem(name: "start", value: day(-14)),
            URLQueryItem(name: "end", value: day(1)),
        ])
        async let dailyStepsData: Data? = try? await service.get(path: "api/v1/timeseries", queryItems: [
            URLQueryItem(name: "metric", value: "step_count"),
            URLQueryItem(name: "start", value: Self.timestamp(calendar.date(byAdding: .day, value: -14, to: today) ?? today)),
            URLQueryItem(name: "end", value: Self.timestamp(tomorrow)),
            URLQueryItem(name: "agg", value: "daily"),
        ])
        async let workoutData: Data? = try? await service.get(path: "api/v1/workouts", queryItems: [
            URLQueryItem(name: "start", value: day(-14)),
        ])

        do {
            let (statsBody, sleepBody) = try await (statsData, sleepData)
            let activityBody = await activityData
            let dailyStepsBody = await dailyStepsData
            let workoutBody = await workoutData
            stats = Self.decodeStats(statsBody)
            lastNight = Self.decodeLastNight(sleepBody)
            activity = activityBody.flatMap(Self.decodeActivity)
            workouts = workoutBody.flatMap(Self.decodeWorkouts)

            // The day the card shows: the newest with rings, else the newest
            // with steps. Its hours are a second, dependent request.
            let shown = activity?.day ?? dailyStepsBody.flatMap(Self.newestStepsDay)
            if let shown, let next = calendar.date(byAdding: .day, value: 1, to: shown) {
                let stepsBody = try? await service.get(path: "api/v1/timeseries", queryItems: [
                    URLQueryItem(name: "metric", value: "step_count"),
                    URLQueryItem(name: "start", value: Self.timestamp(shown)),
                    URLQueryItem(name: "end", value: Self.timestamp(next)),
                    URLQueryItem(name: "agg", value: "hourly"),
                ])
                steps = stepsBody.flatMap { Self.decodeSteps($0, day: shown) }
            } else {
                steps = nil
            }
            state = .loaded
            lastFinished = Date()
        } catch is CancellationError {
            // A cancelled load showed nothing; the next request must run.
            return
        } catch {
            state = .failed(error.localizedDescription)
            lastFinished = Date()
        }
    }

    /// The newest day with any ring above zero. The server dates a summary at
    /// midnight UTC, so the day is read in UTC and rebuilt in the local calendar
    /// — the two name the same day.
    private static func decodeActivity(_ data: Data) -> Activity? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let local = Calendar.current

        return rows.compactMap { row -> Activity? in
            guard let stamp = (row["Date"] as? String).flatMap(date),
                  let day = local.date(from: utc.dateComponents([.year, .month, .day], from: stamp)) else { return nil }
            let activity = Activity(day: day,
                                    move: row["ActiveEnergy"] as? Double ?? 0,
                                    moveGoal: row["ActiveEnergyGoal"] as? Double ?? 0,
                                    exercise: row["ExerciseTime"] as? Double ?? 0,
                                    exerciseGoal: row["ExerciseTimeGoal"] as? Double ?? 0,
                                    stand: row["StandHours"] as? Double ?? 0,
                                    standGoal: row["StandHoursGoal"] as? Double ?? 0)
            // A day whose rings are all still at zero has not been recorded yet.
            return activity.move + activity.exercise + activity.stand > 0 ? activity : nil
        }
        .max { $0.day < $1.day }
    }

    /// Local midnight of the newest daily bucket that holds steps. A daily
    /// bucket is a UTC day; naming the local day after its UTC date is right
    /// for the fallback this serves.
    private static func newestStepsDay(_ data: Data) -> Date? {
        guard let points = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return points.compactMap { point -> Date? in
            guard let stamp = (point["time"] as? String).flatMap(date),
                  let value = point["avg"] as? Double, value > 0 else { return nil }
            return Calendar.current.date(from: utc.dateComponents([.year, .month, .day], from: stamp))
        }
        .max()
    }

    /// Hourly buckets into the 24 hours of this time zone. The server buckets in
    /// UTC; reading each bucket's start in the local calendar puts it back where
    /// the user walked it.
    private static func decodeSteps(_ data: Data, day: Date) -> Steps? {
        guard let points = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var hours = [Double](repeating: 0, count: 24)
        for point in points {
            guard let stamp = (point["time"] as? String).flatMap(date),
                  let value = point["avg"] as? Double, value > 0 else { continue }
            let hour = Calendar.current.component(.hour, from: stamp)
            hours[min(max(hour, 0), 23)] += value
        }
        return Steps(day: day, total: Int(hours.reduce(0, +).rounded()), hours: hours)
    }

    /// The three newest workouts of the requested stretch.
    private static func decodeWorkouts(_ data: Data) -> [Workout]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> Workout? in
            guard let id = row["ID"] as? String,
                  let start = (row["StartTime"] as? String).flatMap(date) else { return nil }
            let name = (row["alpha_session_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["Name"] as? String ?? "Workout")
            // Distances arrive in meters, kilometers or miles depending on the source.
            let distance = (row["Distance"] as? Double).map { value -> Double in
                switch (row["DistanceUnits"] as? String ?? "m").lowercased() {
                case "km": return value * 1000
                case "mi": return value * 1609.344
                default: return value
                }
            }
            return Workout(id: id, name: name, start: start,
                           duration: row["DurationSec"] as? Double ?? 0,
                           distanceMeters: distance)
        }
        .sorted { $0.start > $1.start }
        .prefix(3)
        .map { $0 }
    }

    /// An instant the server parses as RFC 3339, so a range means local midnight
    /// and not midnight UTC.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func decodeStats(_ data: Data) -> Stats? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Stats(metrics: json["total_metric_rows"] as? Int ?? 0,
                     workouts: json["total_workouts"] as? Int ?? 0,
                     sleepNights: json["total_sleep_nights"] as? Int ?? 0,
                     earliest: (json["earliest_data"] as? String).flatMap(date),
                     latest: (json["latest_data"] as? String).flatMap(date))
    }

    /// The newest session the server holds. Falls back to the newest stretch of
    /// sleep stages: the server builds the session from them after an upload,
    /// and until it has, the stages are what it holds.
    private static func decodeLastNight(_ data: Data) -> Night? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let asleep: Set<String> = ["Core", "Deep", "REM", "Asleep"]
        let stages = (json["stages"] as? [[String: Any]] ?? []).compactMap { stage -> (start: Date, end: Date, kind: Night.Kind, hours: Double)? in
            guard let start = (stage["StartTime"] as? String).flatMap(date),
                  let end = (stage["EndTime"] as? String).flatMap(date),
                  let name = stage["Stage"] as? String else { return nil }
            let hours = asleep.contains(name) ? (stage["DurationHr"] as? Double ?? 0) : 0
            return (start, end, Night.Kind(name), hours)
        }
        .sorted { $0.start < $1.start }

        let sessions = (json["sessions"] as? [[String: Any]] ?? []).compactMap { session -> Night? in
            guard let hours = session["TotalSleep"] as? Double, hours > 0,
                  let start = (session["SleepStart"] as? String).flatMap(date),
                  let end = (session["SleepEnd"] as? String).flatMap(date) else { return nil }
            // Everything that overlaps the session belongs to it; a stage may
            // start before the first asleep minute or end after the last.
            let within = stages
                .filter { $0.end > start && $0.start < end }
                .map { Night.Stage(start: $0.start, end: $0.end, kind: $0.kind) }
            return Night(hours: hours, start: start, end: end, stages: within)
        }
        if let night = sessions.max(by: { $0.end < $1.end }) { return night }

        // A break of more than three hours separates a nap from the night.
        var night: [(start: Date, end: Date, kind: Night.Kind, hours: Double)] = []
        for stage in stages {
            if let last = night.last, stage.start.timeIntervalSince(last.end) > 3 * 3600 { night = [] }
            night.append(stage)
        }
        guard let first = night.first, let last = night.last else { return nil }
        let hours = night.reduce(0) { $0 + $1.hours }
        guard hours > 0 else { return nil }
        return Night(hours: hours, start: first.start, end: last.end,
                     stages: night.map { Night.Stage(start: $0.start, end: $0.end, kind: $0.kind) })
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// A hypnogram of one night in the style of the Health app's sleep detail: one
/// lane per stage from Awake down to Deep, every stage a chunky rounded bar
/// placed by its time within the night. The colors carry the lanes, so there
/// are no row labels.
///
/// The construction is Health's, as reverse-engineered by the react-native
/// sleep-stages hypnogram. Two layers. Underneath, one translucent shape in a
/// vertical gradient of the lane colors: every bar's *halo*, the bar grown by
/// one rim on each side; every transition a vertical line exactly one rim wide
/// standing in the column the two neighbouring halos share, from the middle of
/// one bar to the middle of the next; and at both ends a small concave fillet
/// that sweeps the line into the halo edge it meets. On top, the opaque bars.
/// Because the line lives inside the rims and the fillets flare along the halo
/// edges, the path reads as flowing out of one stage and into the next rather
/// than as a stroke laid across them.
///
/// Drawn in a single `Canvas`, so a night with sixty stages costs one pass and
/// no view identity churn.
struct SleepStagesChart: View {
    let start: Date
    let end: Date
    let stages: [ServerOverview.Night.Stage]

    @Environment(\.redactionReasons) private var redaction
    @Environment(\.colorScheme) private var scheme

    /// Lanes are tight on purpose: the bar takes about seven tenths of its
    /// lane, leaving four points of air between one halo and the next.
    private static let laneHeight: CGFloat = 24
    private static let barHeight: CGFloat = 17
    private static let barRadius: CGFloat = 4.5
    /// Width of the halo around a bar; the transition line is the same width,
    /// so it fits the rim column two halos share without overhang.
    private static let rim: CGFloat = 1.5
    /// Radius of the sweep where a line meets a halo edge.
    private static let filletRadius: CGFloat = 3
    /// A stage of a few minutes still has to be visible.
    private static let minimumBarWidth: CGFloat = 3
    private static let haloOpacity: Double = 0.3

    /// A night with stage detail gets the four Health lanes; a night that only
    /// knows "asleep" gets a single one. Mixed input — an "In Bed" stretch next
    /// to real stages — draws the detail and leaves the coarse stages out.
    private var lanes: [ServerOverview.Night.Kind] {
        let detail: [ServerOverview.Night.Kind] = [.awake, .rem, .core, .deep]
        return Set(stages.map(\.kind)).isDisjoint(with: detail) ? [.asleep] : detail
    }

    private var drawn: [ServerOverview.Night.Stage] {
        let shown = Set(lanes)
        return stages.filter { shown.contains($0.kind) }.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chart
                .frame(height: Self.laneHeight * CGFloat(lanes.count))

            HStack {
                Text(start.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(end.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement()
        .accessibilityLabel("Sleep stages")
    }

    private var chart: some View {
        let items = drawn
        let lanes = self.lanes
        return Canvas(opaque: false) { context, size in
            let rim = Self.rim
            let span = max(end.timeIntervalSince(start), 60)
            // The first and last halo need room for their rim inside the canvas.
            func position(_ date: Date) -> CGFloat {
                let fraction = date.timeIntervalSince(start) / span
                return rim + CGFloat(min(max(fraction, 0), 1)) * (size.width - 2 * rim)
            }
            func centerY(_ kind: ServerOverview.Night.Kind) -> CGFloat {
                let lane = lanes.firstIndex(of: kind) ?? 0
                return (CGFloat(lane) + 0.5) * Self.laneHeight
            }

            // A bar ends one rim short of its stage's end: that column belongs
            // to the halo, and it is where the line to the next stage stands.
            let bars: [(rect: CGRect, kind: ServerOverview.Night.Kind)] = items.map { stage in
                let left = position(stage.start)
                let right = min(max(position(stage.end) - rim, left + Self.minimumBarWidth), size.width - rim)
                let rect = CGRect(x: left, y: centerY(stage.kind) - Self.barHeight / 2,
                                  width: max(right - left, Self.minimumBarWidth), height: Self.barHeight)
                return (rect, stage.kind)
            }

            // One vertical gradient of the lane colors under the whole chart, so
            // a line takes the color of the lane it passes and a halo the color
            // of its own bar; the shapes are filled opaque inside one layer and
            // the layer is what is translucent, so overlaps do not double up.
            let shading: GraphicsContext.Shading
            if lanes.count == 1 {
                shading = .color(color(lanes[0]))
            } else {
                let stops = lanes.enumerated().map { index, kind in
                    Gradient.Stop(color: color(kind), location: centerY(kind) / size.height)
                }
                shading = .linearGradient(Gradient(stops: stops),
                                          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            }

            // The opacity has to sit on the context that composites the layer:
            // set on the layer itself it applies per fill, and the line would
            // show through the rim it stands in.
            var underlay = context
            underlay.opacity = Self.haloOpacity
            underlay.drawLayer { layer in
                for bar in bars {
                    let halo = bar.rect.insetBy(dx: -rim, dy: -rim)
                    layer.fill(Self.roundedRect(halo, radius: Self.barRadius + rim), with: shading)
                }
                for (previous, next) in zip(bars, bars.dropFirst()) where previous.rect.midY != next.rect.midY {
                    // The line's left edge is the previous bar's end, its right
                    // edge the next bar's start: the column both halos claim.
                    let x = previous.rect.maxX
                    let line = CGRect(x: x, y: min(previous.rect.midY, next.rect.midY),
                                      width: rim, height: abs(next.rect.midY - previous.rect.midY))
                    layer.fill(Path(line), with: shading)

                    // The sweeps: one flares left along the edge of the halo the
                    // line leaves, one flares right along the edge of the halo it
                    // enters. Health hides them on bars too thin to carry them.
                    let down = next.rect.midY > previous.rect.midY
                    let previousHalo = previous.rect.insetBy(dx: -rim, dy: -rim)
                    let nextHalo = next.rect.insetBy(dx: -rim, dy: -rim)
                    let gap = down ? nextHalo.minY - previousHalo.maxY : previousHalo.minY - nextHalo.maxY
                    // The halo corner the line runs through is haloRadius wide;
                    // the line covers its rim, the patch the rest. A bar too
                    // thin for a sweep still gets the patch, or the rounding
                    // would leave a notch beside the line.
                    let haloRadius = Self.barRadius + rim
                    func radius(for bar: CGRect) -> CGFloat {
                        bar.width > 2 * Self.filletRadius ? min(Self.filletRadius, gap) : 0
                    }
                    func patch(for bar: CGRect) -> CGSize {
                        CGSize(width: min(haloRadius - rim, bar.width), height: haloRadius)
                    }
                    let leaving = CGPoint(x: x, y: down ? previousHalo.maxY : previousHalo.minY)
                    layer.fill(Self.fillet(at: leaving, alongX: -1, alongY: down ? 1 : -1,
                                           radius: radius(for: previous.rect), patch: patch(for: previous.rect)),
                               with: shading)
                    if abs(nextHalo.minX - x) < 0.5 {
                        let entering = CGPoint(x: x + rim, y: down ? nextHalo.minY : nextHalo.maxY)
                        layer.fill(Self.fillet(at: entering, alongX: 1, alongY: down ? -1 : 1,
                                               radius: radius(for: next.rect), patch: patch(for: next.rect)),
                                   with: shading)
                    }
                }
            }

            for bar in bars {
                context.fill(Self.roundedRect(bar.rect, radius: Self.barRadius), with: .color(color(bar.kind)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A continuous-corner rounded rect whose radius never exceeds what the
    /// rect can carry — a one-minute stage is narrower than two corners.
    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r), style: .continuous)
    }

    /// The concave wedge in the inside corner where a vertical line meets a
    /// horizontal halo edge: bounded by the line (running `alongY` from the
    /// corner), the edge (running `alongX` from the corner) and a quarter circle
    /// tangent to both. Behind the wedge sits a square patch `patch` deep into
    /// the halo: the halo's own corner is rounded, and without the patch a
    /// notch stays open between that rounding and the line. The patch is under
    /// the opaque bar except for the rim, where it squares the halo off the way
    /// Health does where a line joins. Half a point of overlap into the line
    /// keeps antialiasing from leaving a hairline seam along the join.
    private static func fillet(at corner: CGPoint, alongX: CGFloat, alongY: CGFloat,
                               radius: CGFloat, patch: CGSize) -> Path {
        let overlap: CGFloat = 0.5
        let reach = max(radius, patch.width)
        var path = Path()
        if radius > 0.5 {
            let onLine = CGPoint(x: corner.x, y: corner.y + alongY * radius)
            let onEdge = CGPoint(x: corner.x + alongX * radius, y: corner.y)
            path.move(to: CGPoint(x: corner.x - alongX * overlap, y: onLine.y))
            path.addLine(to: onLine)
            path.addArc(tangent1End: corner, tangent2End: onEdge, radius: radius)
        } else {
            path.move(to: CGPoint(x: corner.x - alongX * overlap, y: corner.y))
        }
        path.addLine(to: CGPoint(x: corner.x + alongX * reach, y: corner.y))
        path.addLine(to: CGPoint(x: corner.x + alongX * reach, y: corner.y - alongY * patch.height))
        path.addLine(to: CGPoint(x: corner.x - alongX * overlap, y: corner.y - alongY * patch.height))
        path.closeSubpath()
        return path
    }

    private func color(_ kind: ServerOverview.Night.Kind) -> Color {
        // The placeholder night is fake data; it must not read as a real one.
        if redaction.contains(.placeholder) { return Color.secondary.opacity(0.3) }
        return stageColor(kind)
    }

    /// Health's stage colors. Core and Deep are lifted on a dark background,
    /// where the daylight indigo all but disappears.
    private func stageColor(_ kind: ServerOverview.Night.Kind) -> Color {
        let dark = scheme == .dark
        switch kind {
        case .awake: return Color(red: 1.0, green: 0.45, blue: 0.35)
        case .rem: return Color(red: 0.20, green: 0.78, blue: 0.92)
        case .core, .asleep: return dark ? Color(red: 0.13, green: 0.55, blue: 1.0) : Color(red: 0.0, green: 0.48, blue: 1.0)
        case .deep: return dark ? Color(red: 0.42, green: 0.46, blue: 0.92) : Color(red: 0.22, green: 0.26, blue: 0.68)
        }
    }
}
