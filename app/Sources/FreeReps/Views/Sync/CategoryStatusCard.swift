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

    @State private var showResetConfirm = false

    var body: some View {
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
                if case .failed(let message) = state.status {
                    DisclosureGroup("Error details") {
                        Text(message)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
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
        .padding(.vertical, 2)
        .opacity(isIncluded ? 1 : 0.5)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSyncRunning && isIncluded {
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

    /// One honest line: "n new records" is what the server inserted in the last run, so a
    /// re-sent category reads "Nothing new" rather than a small number.
    private var detail: String {
        guard isIncluded else { return "Off" }
        switch state.status {
        case .syncing:
            return state.periodLabel ?? "Syncing\u{2026}"
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

    private var iconColor: Color {
        guard isIncluded else { return .secondary }
        switch state.status {
        case .failed:    return .red
        case .syncing:   return .blue
        case .completed: return .green
        case .idle:      return state.daysBehind != nil ? .orange : .blue
        }
    }
}
