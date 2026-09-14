import SwiftUI

struct SettingsView: View {
    let syncViewModel: SyncViewModel
    @StateObject private var vm = SettingsViewModel()
    @ObservedObject private var healthSelection = HealthSyncSelection.shared
    @AppStorage("keepScreenOnDuringSync") private var keepScreenOnDuringSync = true
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    NavigationLink {
                        FreeRepsSettingsView(vm: vm)
                    } label: {
                        HStack(spacing: 12) {
                            iconBox("server.rack", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("FreeReps Connection")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: connectionSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    NavigationLink {
                        HealthPermissionsView(vm: vm)
                    } label: {
                        HStack(spacing: 12) {
                            iconBox("heart.fill", color: .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Health Sync")
                                    .font(.subheadline.weight(.semibold))
                                Text(vm.healthConnection == .connected ? "Connected" : "Not connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Sync") {
                    Toggle(isOn: $backgroundSyncEnabled) {
                        HStack(spacing: 12) {
                            iconBox("arrow.triangle.2.circlepath", color: backgroundSyncEnabled ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Background Sync")
                                    .font(.subheadline.weight(.semibold))
                                Text(!healthSelection.isEnabled ? "Paused while Apple Health is disconnected" : backgroundSyncEnabled
                                    ? "Health data syncs automatically via FreeReps"
                                    : "No data is synced in the background")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: backgroundSyncEnabled) { _, _ in
                        BackgroundSyncManager.shared.startObserving()
                    }

                    Toggle(isOn: $keepScreenOnDuringSync) {
                        HStack(spacing: 12) {
                            iconBox("sun.max.fill", color: .yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Screen On")
                                    .font(.subheadline.weight(.semibold))
                                Text("Prevent display sleep during full sync")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        SyncAdvancedView(vm: vm, syncViewModel: syncViewModel)
                    } label: {
                        HStack(spacing: 12) {
                            iconBox("gearshape.fill", color: .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced")
                                    .font(.subheadline.weight(.semibold))
                                Text("Older data start date, reset sync state")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("About") {
                    Link(destination: URL(string: "https://github.com/meltforce/FreeReps/releases/tag/\(appVersion)")!) {
                        LabeledContent("App Version") {
                            HStack(spacing: 4) {
                                Text(appVersion)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let serverVersion = vm.serverVersion {
                        Link(destination: URL(string: "https://github.com/meltforce/FreeReps/releases/tag/\(serverVersion)")!) {
                            LabeledContent("Server Version") {
                                HStack(spacing: 4) {
                                    Text(serverVersion)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("HealthKit Types", value: "\(HealthDataTypes.allQuantityTypes.count + HealthDataTypes.allCategoryTypes.count)")
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        HStack(spacing: 12) {
                            iconBox("doc.text.fill", color: .indigo)
                            Text("Acknowledgements")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                BrandFooter()
            }
            .navigationTitle("Settings")
            .onAppear { vm.refreshPermissionsState() }
            .onChange(of: vm.config) { vm.saveConfig() }
        }
    }

    private var connectionSummary: String {
        switch vm.config.connectionMode {
        case .tailscale:
            let server = vm.config.tailnetHost.split(separator: ".").first.map(String.init)
            return server.map { "Tailscale · \($0)" } ?? "Tailscale · not set up"
        case .address:
            return vm.config.host.isEmpty ? "No server address" : vm.config.host
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func iconBox(_ systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(width: 36, height: 36)
            Image(systemName: systemName)
                .font(.system(size: 18))
                .foregroundStyle(.white)
        }
    }
}
