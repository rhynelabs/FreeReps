import SwiftUI

struct SyncAdvancedView: View {
    @ObservedObject var vm: SettingsViewModel
    let syncViewModel: SyncViewModel
    @State private var showResetSyncConfirmation = false
    /// True for a few seconds after a reset, so the row itself confirms it:
    /// the alert closes without a trace otherwise.
    @State private var didResetSyncState = false
    /// The feedback timer, so a second reset restarts the 3 seconds instead of
    /// letting the first timer end them early.
    @State private var resetFeedbackTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Picker(selection: Binding(
                    get: { vm.config.backfillMonths ?? 0 },
                    set: { vm.config.backfillMonths = $0 == 0 ? nil : $0 }
                )) {
                    Text("1 Month").tag(1)
                    Text("6 Months").tag(6)
                    Text("1 Year").tag(12)
                    Text("2 Years").tag(24)
                    Text("All Data").tag(0)
                } label: {
                    Text("Older Data")
                }
            } footer: {
                Text("Sync Older Data sends everything in Apple Health from this point on. Sync Now only looks at recent data.")
            }

            Section {
                Button(role: .destructive) {
                    showResetSyncConfirmation = true
                } label: {
                    // Only the icon carries the destructive tint; the text keeps
                    // the same weight as the other settings rows.
                    SettingsRow(Text("Reset Sync State")) {
                        Image(systemName: didResetSyncState ? "checkmark.circle.fill" : "arrow.counterclockwise")
                            .foregroundStyle(didResetSyncState ? .green : .red)
                    } subtitle: {
                        Text(didResetSyncState
                             ? "Sync state cleared. The next Sync Older Data starts from the beginning."
                             : "Clears all sync progress. Next sync will re-send all data.")
                    }
                }
                // Stays enabled during the confirmation feedback: a second reset
                // is harmless and only restarts the feedback.
                .disabled(syncViewModel.isAnySyncRunning)
                .animation(.default, value: didResetSyncState)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.config) { vm.saveConfig() }
        .alert("Reset Sync State", isPresented: $showResetSyncConfirmation) {
            Button("Reset", role: .destructive) {
                syncViewModel.resetAllSyncState()
                didResetSyncState = true
                resetFeedbackTask?.cancel()
                resetFeedbackTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    didResetSyncState = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will clear all sync progress and cursors. The next sync will re-send all health data to FreeReps. Server-side data is not affected.")
        }
    }
}
