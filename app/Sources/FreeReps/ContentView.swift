import SwiftUI

struct ContentView: View {
    @StateObject private var syncViewModel = SyncViewModel()
    @EnvironmentObject var importState: ImportState
    @AppStorage("keepScreenOnDuringSync") private var keepScreenOnDuringSync = true

    var body: some View {
        TabView {
            OverviewView(vm: syncViewModel)
                .tabItem {
                    Label("Overview", systemImage: "heart.text.square")
                }

            SyncDashboardView(vm: syncViewModel)
                .tabItem {
                    Label("Data", systemImage: "list.bullet.rectangle")
                }

            SettingsView(syncViewModel: syncViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(syncViewModel)
        // Both tabs start a history import, so screen and prerequisite handling live here.
        .onChange(of: syncViewModel.isFullSyncRunning) { _, isRunning in
            UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenOnDuringSync
        }
        .alert("Sync Prerequisites", isPresented: $syncViewModel.showPrerequisiteAlert) {
            Button("Continue Anyway") { }
            Button("Cancel Sync", role: .cancel) {
                syncViewModel.cancelSync()
            }
        } message: {
            let titles = syncViewModel.prerequisiteIssues.map { $0.title }
            Text("Issues found:\n\(titles.joined(separator: "\n"))\n\nThe sync will continue but some data may be missing. Fix these issues in Settings for a complete sync.")
        }
    }
}
