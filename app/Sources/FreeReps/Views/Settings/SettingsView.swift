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
                        SettingsRow(Text("FreeReps Connection")) {
                            iconBox("server.rack", color: .orange)
                        } subtitle: {
                            Text(verbatim: connectionSummary).lineLimit(1)
                        }
                    }

                    NavigationLink {
                        HealthPermissionsView(vm: vm)
                    } label: {
                        SettingsRow(Text("Apple Health Sync")) {
                            iconBox("heart.fill", color: .red)
                        } subtitle: {
                            Text(vm.healthConnection == .connected ? "Connected" : "Not connected")
                        }
                    }
                }

                Section("Sync") {
                    Toggle(isOn: $backgroundSyncEnabled) {
                        SettingsRow(Text("Background Sync")) {
                            iconBox("arrow.triangle.2.circlepath", color: backgroundSyncEnabled ? .blue : .secondary)
                        } subtitle: {
                            Text(!healthSelection.isEnabled ? "Paused while Apple Health is disconnected" : backgroundSyncEnabled
                                ? "Health data syncs automatically via FreeReps"
                                : "No data is synced in the background")
                        }
                    }
                    .onChange(of: backgroundSyncEnabled) { _, _ in
                        BackgroundSyncManager.shared.startObserving()
                    }

                    Toggle(isOn: $keepScreenOnDuringSync) {
                        SettingsRow(Text("Keep Screen On")) {
                            iconBox("sun.max.fill", color: .yellow)
                        } subtitle: {
                            Text("Prevent display sleep during full sync")
                        }
                    }

                    NavigationLink {
                        SyncAdvancedView(vm: vm, syncViewModel: syncViewModel)
                    } label: {
                        SettingsRow(Text("Advanced")) {
                            iconBox("gearshape.fill", color: .gray)
                        } subtitle: {
                            Text("Older data start date, reset sync state")
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
                        SettingsRow(Text("Acknowledgements")) {
                            iconBox("doc.text.fill", color: .indigo)
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

/// A list row in the typography of the iOS Settings app: a body-weight title
/// over a secondary subtitle, behind a leading icon of fixed width so the
/// titles of neighbouring rows line up. Semibold titles and caption subtitles
/// read as flimsy next to Apple's own rows, so the fonts are fixed here rather
/// than chosen per row.
struct SettingsRow<Icon: View, Subtitle: View>: View {
    private let title: Text
    private let icon: Icon
    private let subtitle: Subtitle

    init(_ title: Text, @ViewBuilder icon: () -> Icon, @ViewBuilder subtitle: () -> Subtitle) {
        self.title = title
        self.icon = icon()
        self.subtitle = subtitle()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 36)
            // Concrete colours rather than the hierarchical styles: inside a
            // destructive button those would inherit the red tint, and only the
            // icon is meant to carry it.
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.body)
                    .foregroundStyle(Color.primary)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

extension SettingsRow where Subtitle == EmptyView {
    init(_ title: Text, @ViewBuilder icon: () -> Icon) {
        self.init(title, icon: icon) { EmptyView() }
    }
}
