import SwiftUI

/// The cards the Overview shows around "Last Night": a day's activity and
/// steps, and the last workouts. They borrow the Fitness app's vocabulary, but
/// at the density and restraint of a Health list — mostly monochrome, the ring
/// colors as small accents — because the page answers "is everything tracked
/// and on the server", it is not the Fitness app.

// MARK: - Colors

/// The Fitness app's palette. The saturated dark-mode tones are lowered on a
/// white background, where they otherwise read as highlighter ink.
enum FitnessColor {
    static func move(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.98, green: 0.07, blue: 0.33)
                        : Color(red: 0.91, green: 0.05, blue: 0.29)
    }

    static func exercise(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.58, green: 0.91, blue: 0.17)
                        : Color(red: 0.33, green: 0.70, blue: 0.05)
    }

    static func stand(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.03, green: 0.87, blue: 0.87)
                        : Color(red: 0.00, green: 0.62, blue: 0.67)
    }

    /// System indigo, which is already muted in both appearances; the bars
    /// are the only colored thing in the steps row.
    static func steps(_ scheme: ColorScheme) -> Color {
        .indigo
    }
}

// MARK: - Activity

/// One of the three rings as a column: the value in the ring's color, the goal
/// and unit small and gray beside it, the name under it, and a thin bar for
/// how far the ring is closed. Three of these side by side say what the rings
/// say in a third of the height; the bar is the ring, unrolled.
struct ActivityColumn: View {
    let title: String
    let value: Double
    let goal: Double
    let unit: String
    let color: Color

    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let tint = redaction.contains(.placeholder) ? Color.secondary : color
        let progress = goal > 0 ? min(max(value / goal, 0), 1) : 0
        VStack(alignment: .leading, spacing: 0) {
            // The goal sits beside the value while both fit in a third of the
            // card; a "8,000 /15,000 KCAL" pair does not, and then the goal
            // drops under the value instead of shrinking past legibility or
            // running into the next column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    valueText(tint)
                    goalText
                }
                VStack(alignment: .leading, spacing: 1) {
                    valueText(tint)
                    goalText
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // Lets a taller column push its bar down to the neighbours' bars,
            // so the three bars stay on one line whichever layout the columns
            // ended up with.
            Spacer(minLength: 6)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.2))
                    Capsule().fill(tint)
                        .frame(width: max(proxy.size.width * progress, progress > 0 ? 4 : 0))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("\(title): \(formattedValue) of \(formattedGoal) \(unit)")
    }

    private func valueText(_ tint: Color) -> some View {
        Text(formattedValue)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
    }

    private var goalText: some View {
        Text("/\(formattedGoal) \(unit)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// Grouped the way the locale groups ("8,000"), so a big day reads as a
    /// number and not as a digit run.
    private var formattedValue: String { Int(value.rounded()).formatted() }
    private var formattedGoal: String { Int(goal.rounded()).formatted() }
}

// MARK: - Steps

/// Today by the hour, the way the Health app draws steps: a bar in every hour
/// that has steps, filling most of its slot, standing on one faint baseline.
/// Hours without steps stay empty — a track behind each of them turns the
/// chart into a picket fence.
struct StepsChart: View {
    /// Twenty-four values, midnight first, in the phone's time zone.
    let hours: [Double]
    let color: Color

    @Environment(\.redactionReasons) private var redaction

    private static let height: CGFloat = 36
    private static let baseline: CGFloat = 1
    /// The share of an hour's slot the bar covers; the rest is the gap.
    private static let fill: CGFloat = 0.72

    var body: some View {
        let tint = redaction.contains(.placeholder) ? Color.secondary.opacity(0.35) : color
        VStack(alignment: .leading, spacing: 3) {
            Canvas(opaque: false) { context, size in
                let slot = size.width / 24
                let width = slot * Self.fill
                let floor = size.height - Self.baseline
                let peak = max(hours.max() ?? 0, 1)
                for hour in 0..<24 {
                    let value = hour < hours.count ? hours[hour] : 0
                    guard value > 0 else { continue }
                    // A few steps in an hour still show as a sliver.
                    let height = max(CGFloat(value / peak) * floor, 2)
                    let rect = CGRect(x: CGFloat(hour) * slot, y: floor - height, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 2)), with: .color(tint))
                }
                context.fill(Path(CGRect(x: 0, y: floor, width: size.width, height: Self.baseline)),
                             with: .color(Color.secondary.opacity(0.3)))
            }
            .frame(height: Self.height)

            // Each caption starts where its hour's bar starts.
            HStack(spacing: 0) {
                ForEach(["0", "6", "12", "18"], id: \.self) { label in
                    Text(label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement()
        .accessibilityLabel("Steps by hour")
    }
}

// MARK: - Workouts

/// One workout the way a Health list row reads: the activity badge, the name,
/// the one number that matters — distance when there is one, otherwise the
/// duration — and the day at the trailing edge. No color: the number is the
/// emphasis.
struct WorkoutRow: View {
    let workout: ServerOverview.Workout

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 0) {
                Text(workout.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(headline.value)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let unit = headline.unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    // On the headline's baseline, the way Fitness sets the day.
                    Text(day)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 1)
    }

    /// The figure on a faint gray disc, the way Settings and Health badge a
    /// row without shouting.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))
            Image(systemName: workout.kind.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }

    /// Distance when the workout covered ground, duration otherwise.
    private var headline: (value: String, unit: String?) {
        if let meters = workout.distanceMeters, meters > 0 {
            let kilometers = meters / 1000
            let digits = kilometers < 100 ? 2 : 1
            return (kilometers.formatted(.number.precision(.fractionLength(digits))), "KM")
        }
        let minutes = Int((workout.duration / 60).rounded())
        return (String(format: "%d:%02d", minutes / 60, minutes % 60), nil)
    }

    /// "Today", "Yesterday", the weekday within the last week, a short date before that.
    private var day: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(workout.start) { return "Today" }
        if calendar.isDateInYesterday(workout.start) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: workout.start),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 7 { return workout.start.formatted(.dateTime.weekday(.wide)) }
        return workout.start.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
    }
}

extension ServerOverview.Workout {
    /// What the server calls the workout, reduced to the handful of shapes that
    /// get their own symbol. Names come from HealthKit ("Traditional Strength
    /// Training"), Hevy or Alpha Progression, so this matches on words.
    enum Kind {
        case running, cycling, walking, hiking, strength, swimming, yoga, rowing, other

        /// All of these ship with iOS 16, so they are safe on the 17.6 target.
        var symbol: String {
            switch self {
            case .running: return "figure.run"
            case .cycling: return "figure.outdoor.cycle"
            case .walking: return "figure.walk"
            case .hiking: return "figure.hiking"
            case .strength: return "figure.strengthtraining.traditional"
            case .swimming: return "figure.pool.swim"
            case .yoga: return "figure.yoga"
            case .rowing: return "figure.rower"
            case .other: return "figure.mixed.cardio"
            }
        }
    }

    var kind: Kind {
        let name = self.name.lowercased()
        if name.contains("hik") { return .hiking }
        if name.contains("run") { return .running }
        if name.contains("cycl") || name.contains("bike") || name.contains("biking") { return .cycling }
        if name.contains("walk") { return .walking }
        if name.contains("swim") { return .swimming }
        if name.contains("yoga") || name.contains("pilates") { return .yoga }
        if name.contains("row") { return .rowing }
        if name.contains("strength") || name.contains("weight") || name.contains("lifting")
            || name.contains("gym") || name.contains("core") { return .strength }
        return .other
    }
}
