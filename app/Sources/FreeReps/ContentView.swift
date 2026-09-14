import SwiftUI

struct ContentView: View {
    @StateObject private var syncViewModel = SyncViewModel()
    @EnvironmentObject var importState: ImportState
    @AppStorage("keepScreenOnDuringSync") private var keepScreenOnDuringSync = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            OverviewView(vm: syncViewModel)
                .tabItem {
                    Label("Overview", systemImage: "heart.text.square")
                }

            SyncDashboardView(vm: syncViewModel)
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            SettingsView(syncViewModel: syncViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(syncViewModel)
        // Both tabs start syncing older data, so screen and prerequisite handling live here.
        .onChange(of: syncViewModel.isFullSyncRunning) { _, isRunning in
            UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenOnDuringSync
        }
        // An older-data sync that iOS stopped in the background continues once the user is
        // back: the phone is unlocked, so Apple Health is readable again. The background
        // task clears the same flag before it runs, so only one of the two starts it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, UserDefaults.standard.bool(forKey: "pendingFullSyncResume") else { return }
            UserDefaults.standard.set(false, forKey: "pendingFullSyncResume")
            syncViewModel.startFullSync()
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
