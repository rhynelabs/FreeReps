import SwiftUI

struct CategoryStatusCard: View {
    let state: CategorySyncState
    var onReset: (() -> Void)? = nil
    var onSync: (() -> Void)? = nil
    var isSyncRunning: Bool = false
    /// False when the category is turned off in Settings → Apple Health.
    var isIncluded: Bool = true
    /// Set while an older-data sync has not finished this category.
    var olderData: SyncState.OlderDataProgress? = nil
    /// True for the Weight Training card: it is filled by the CSV import,
    /// no sync ever touches it, so it neither waits for one nor offers one.
    var isImport: Bool = false

    @State private var showResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: state.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.displayName)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isFailed ? .red : .secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: state.recordCount)
                    if case .syncing = state.status {
                        ProgressView(value: state.progressFraction)
                            .frame(maxWidth: 180)
                    }
                }

                Spacer()

                // Last sync time + staleness indicator
                VStack(alignment: .trailing, spacing: 2) {
                    if let date = state.lastSyncDate {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let days = state.daysBehind {
                        Text(days == 1 ? "1 day behind" : "\(days) days behind")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if case .failed(let message) = state.status {
                // Always open: the row already says "Failed", and the reason is
                // what the user came to read. Kept outside the HStack so it can
                // use the row's full width instead of the column next to the icon.
                failureDetails(message)
            }
        }
        .padding(.vertical, 2)
        .opacity(isIncluded ? 1 : 0.5)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSyncRunning && isIncluded && !isImport {
                Button {
                    onSync?()
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSyncRunning {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset", systemImage: "trash.fill")
                }
            }
        }
        .confirmationDialog(
            "Reset \(state.displayName)?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Local Progress", role: .destructive) {
                onReset?()
            }
        } message: {
            Text("This resets the saved sync progress for \(state.displayName) on this iPhone. Records already stored on the server are kept.")
        }
    }

    /// A HealthKit failure, one paragraph per type that could not be read.
    private struct Failure: Identifiable {
        let id: Int
        /// The type that failed, when the message names one.
        let type: String?
        /// HealthKit's own words, kept verbatim so they can be searched for.
        let text: String
    }

    /// Splits `SyncService`'s "Failed types: A: reason [domain:code], B: reason [domain:code]"
    /// into one entry per type. Any other message is shown as is, in one entry.
    private static func failures(in message: String) -> [Failure] {
        let prefix = "Failed types: "
        guard message.hasPrefix(prefix) else { return [Failure(id: 0, type: nil, text: message)] }
        // Each entry ends in "[domain:code]", so that is the only separator a
        // reason's own commas cannot fake.
        let entries = message.dropFirst(prefix.count)
            .components(separatedBy: "], ")
            .map { $0.hasSuffix("]") ? $0 : $0 + "]" }
        return entries.enumerated().map { index, entry in
            guard let colon = entry.range(of: ": ") else { return Failure(id: index, type: nil, text: entry) }
            return Failure(id: index, type: String(entry[..<colon.lowerBound]),
                           text: String(entry[colon.upperBound...]))
        }
    }

    private func failureDetails(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.failures(in: message)) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.type.map { "HealthKit could not read \($0):" } ?? "HealthKit reported:")
                        .foregroundStyle(.red)
                    Text(failure.text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
        // Let the text take as many lines as it needs; the row must never cut it off.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One honest line: "n new records" is what the server inserted in the last run, so a
    /// re-sent category reads "Nothing new" rather than a small number.
    private var detail: String {
        if isImport {
            guard state.lastSyncDate != nil else { return "Import a CSV from Alpha Progression" }
            return state.recordCount == 1 ? "1 set imported" : "\(state.recordCount.formatted()) sets imported"
        }
        guard isIncluded else { return "Off" }
        switch state.status {
        case .syncing:
            // The window index belongs next to the period it covers; the rows
            // the server acknowledged are only counted per run, in the footer.
            // Gated on the period: it is cleared when the window loop ends, while
            // the window numbers stay behind and would mislabel a later new-data run.
            guard let period = state.periodLabel else { return "Syncing\u{2026}" }
            guard state.totalEstimated > 0 else { return period }
            return "\(period) \u{00B7} window \(state.currentProgress + 1) of \(state.totalEstimated)"
        case .failed:
            return "Failed"
        case .idle, .completed:
            switch olderData {
            case .notStarted:
                return "Older data: not sent yet"
            case .sentUpTo(let date):
                return "Older data: up to \(date.formatted(.dateTime.month(.abbreviated).year()))"
            case nil:
                guard state.lastSyncDate != nil else { return "Not synced yet" }
                return state.recordCount > 0 ? "\(state.recordCount.formatted()) new records" : "Nothing new"
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state.status { return true } else { return false }
    }

    /// Blue means syncing and nothing else: an idle category waiting its turn
    /// in a run is gray, so the eye finds the ones that are actually working.
    private var iconColor: Color {
        if isImport { return state.lastSyncDate != nil ? .green : .secondary }
        guard isIncluded else { return .secondary }
        switch state.status {
        case .failed:    return .red
        case .syncing:   return .blue
        case .completed: return .green
        case .idle:      return state.daysBehind != nil ? .orange : .secondary
        }
    }
}
