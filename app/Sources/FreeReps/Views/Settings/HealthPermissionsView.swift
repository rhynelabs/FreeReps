import SwiftUI

struct HealthPermissionsView: View {
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject private var selection = HealthSyncSelection.shared
    @ObservedObject private var state = SyncState.shared
    @Environment(\.scenePhase) private var scenePhase

    private var connection: HealthConnection { vm.healthConnection }
    private var categories: [CategorySyncState] { state.categories.filter { $0.id != "cat_strength" } }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FreeReps"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: connection == .connected ? "heart.fill" : "heart.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(connection == .connected ? Color.red : Color.secondary)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection == .connected ? "Connected" : "Not Connected")
                            .font(.headline)
                        Text(connection == .connected
                             ? "\(appName) reads your Health data and uploads it to your server."
                             : "\(appName) doesn't read any Health data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if connection == .connected {
                    Button("Disconnect", role: .destructive) { vm.disconnectHealth() }
                        .accessibilityIdentifier("disconnect-health")
                } else {
                    Button { vm.connectHealth() } label: {
                        HStack {
                            Text("Connect Apple Health")
                            if vm.isRequestingPermissions {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(vm.isRequestingPermissions)
                    .accessibilityIdentifier("connect-health")
                }
            } footer: {
                if connection == .paused {
                    Text("Apple Health may still allow access. To remove it, open Health → Profile → Apps → \(appName).")
                }
            }

            if let message = vm.errorMessage {
                Section { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }

            if connection == .connected {
                Section {
                    Button { vm.testHealthAccess() } label: {
                        HStack {
                            Text("Check Connection")
                            Spacer()
                            if vm.isTestingHealth {
                                ProgressView()
                            } else if let check = vm.healthReadCheck {
                                testResult(check)
                            }
                        }
                    }
                    .disabled(vm.isTestingHealth)
                    .accessibilityIdentifier("check-health-connection")
                    Button("Open Apple Health") { vm.openHealthApp() }
                } footer: {
                    Text(accessFooter)
                }

                Section {
                    ForEach(categories) { category in
                        Toggle(category.id == "cat_category" ? "Sleep & Health Events" : category.displayName,
                               isOn: Binding(get: { selection.includes(category.id) },
                                             set: { selection.setCategory(category.id, enabled: $0); vm.selectionChanged() }))
                    }
                } header: {
                    HStack {
                        Text("Data to Sync")
                        Spacer()
                        let allOn = categories.allSatisfy { selection.includes($0.id) }
                        Button(allOn ? "Turn All Off" : "Turn All On") {
                            for category in categories { selection.setCategory(category.id, enabled: !allOn) }
                            vm.selectionChanged()
                        }
                        .font(.footnote)
                        .textCase(nil)
                    }
                } footer: {
                    Text("Turned-off data is neither read nor uploaded.")
                }

                Section {
                    if #available(iOS 26, *) {
                        Button("Choose Medications") { vm.requestMedicationAccess() }
                    }
                    Button("Choose Vision Prescriptions") { vm.requestVisionPrescriptionAccess() }
                } header: {
                    Text("Medications & Vision")
                } footer: {
                    Text("Apple asks you to pick these entries one by one.")
                }
                .disabled(vm.isRequestingPermissions)
            }
        }
        .navigationTitle("Apple Health")
        .onAppear { vm.refreshPermissionsState() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            vm.refreshPermissionsState()
            // Coming back from Apple Health: show whether the change took effect.
            if vm.healthReadCheck != nil { vm.testHealthAccess() }
        }
    }

    private func testResult(_ check: HealthKitService.ReadCheck) -> some View {
        let (text, icon, color): (String, String, Color) = switch check {
        case .readable: ("Working", "checkmark.circle.fill", .green)
        case .noData: ("No Data", "exclamationmark.triangle.fill", .orange)
        case .failed: ("Failed", "xmark.circle.fill", .red)
        }
        return Label(text, systemImage: icon).foregroundStyle(color)
    }

    private var accessFooter: String {
        let path = "Profile → Apps → \(appName)"
        switch vm.healthReadCheck {
        case .noData:
            return "\(appName) can't see steps, heart rate, sleep or workouts. Access is probably turned off in Apple Health: \(path)."
        case .failed(let message):
            return message
        case .readable, nil:
            return "Apple Health decides which data \(appName) may read: \(path)."
        }
    }
}
