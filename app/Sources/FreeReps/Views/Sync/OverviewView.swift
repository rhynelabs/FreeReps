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

    func load() async {
        if let inFlight {
            await inFlight.value
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
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
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
/// placed by its time within the night, every transition a straight vertical
/// line fading from the color it leaves to the color it enters. The bars are
/// the only opaque element; the lines are translucent and sit in a faint wide
/// glow, which is how Health keeps the stages in front and the path behind.
/// The colors carry the lanes, so there are no row labels.
///
/// Drawn in a single `Canvas`, so a night with sixty stages costs one pass and
/// no view identity churn.
struct SleepStagesChart: View {
    let start: Date
    let end: Date
    let stages: [ServerOverview.Night.Stage]

    @Environment(\.redactionReasons) private var redaction
    @Environment(\.colorScheme) private var scheme

    private static let laneHeight: CGFloat = 26
    private static let barHeight: CGFloat = 14
    private static let barRadius: CGFloat = 5
    /// A stage of a few minutes still has to be visible.
    private static let minimumBarWidth: CGFloat = 3.5
    private static let connectorWidth: CGFloat = 2
    private static let connectorOpacity: Double = 0.45
    private static let glowOpacity: Double = 0.12

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
            let span = max(end.timeIntervalSince(start), 60)
            func position(_ date: Date) -> CGFloat {
                let fraction = date.timeIntervalSince(start) / span
                return CGFloat(min(max(fraction, 0), 1)) * size.width
            }
            func centerY(_ kind: ServerOverview.Night.Kind) -> CGFloat {
                let lane = lanes.firstIndex(of: kind) ?? 0
                return (CGFloat(lane) + 0.5) * Self.laneHeight
            }
            // A transition stands on the boundary the two stages share and runs
            // from the middle of one bar to the middle of the next.
            let transitions: [(line: Path, shading: GraphicsContext.Shading)] = zip(items, items.dropFirst()).compactMap { previous, next in
                let from = CGPoint(x: position(previous.end), y: centerY(previous.kind))
                let to = CGPoint(x: from.x, y: centerY(next.kind))
                guard from.y != to.y else { return nil }
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [color(previous.kind), color(next.kind)]),
                    startPoint: from, endPoint: to)
                return (line, shading)
            }

            // Glow, then line, then bars: each layer is translucent so the one
            // under it shows through, and the bars cover the line ends.
            context.drawLayer { layer in
                layer.opacity = Self.glowOpacity
                for transition in transitions {
                    layer.stroke(transition.line, with: transition.shading,
                                 style: StrokeStyle(lineWidth: 3 * Self.connectorWidth))
                }
            }
            context.drawLayer { layer in
                layer.opacity = Self.connectorOpacity
                for transition in transitions {
                    layer.stroke(transition.line, with: transition.shading,
                                 style: StrokeStyle(lineWidth: Self.connectorWidth))
                }
            }

            for stage in items {
                let left = position(stage.start)
                let width = min(max(position(stage.end) - left, Self.minimumBarWidth),
                                max(size.width - left, Self.minimumBarWidth))
                let rect = CGRect(x: left, y: centerY(stage.kind) - Self.barHeight / 2,
                                  width: width, height: Self.barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.barRadius),
                             with: .color(color(stage.kind)))
            }
        }
        .frame(maxWidth: .infinity)
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
