import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SyncDashboardView: View {
    @ObservedObject var vm: SyncViewModel
    @EnvironmentObject var importState: ImportState
    @State private var navigateToHealthPermissions = false
    @State private var showFilePicker = false
    @ObservedObject private var selection = HealthSyncSelection.shared

    var body: some View {
        NavigationStack {
            List {
                if vm.isAnySyncRunning {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.blue)
                                .frame(width: 40)
                                .symbolEffect(.pulse)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.isFullSyncRunning ? "Syncing Older Data" : "Syncing New Data")
                                    .font(.headline)
                                Text(vm.currentOperation.isEmpty ? "Reading Apple Health\u{2026}" : vm.currentOperation)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        overallProgress
                        LabeledContent("New Records", value: vm.syncState.newRecordsThisRun.formatted())
                            .monospacedDigit()
                        if vm.isFullSyncRunning {
                            noticeRow(
                                icon: "lock.open.display",
                                color: .blue,
                                title: "Keep Screen On",
                                message: "Apple Health can't be read while iPhone is locked."
                            )
                        }
                        Button("Cancel Sync", role: .destructive) { vm.cancelSync() }
                    }
                }

                if let err = vm.errorMessage {
                    Section {
                        noticeRow(icon: "exclamationmark.triangle.fill", color: .red, title: "Sync Failed", message: err)
                            .textSelection(.enabled)
                    }
                }

                if !vm.prerequisiteIssues.isEmpty && !vm.isAnySyncRunning {
                    Section("Action Required") {
                        ForEach(vm.prerequisiteIssues) { issue in
                            if issue.actionLabel.isEmpty {
                                noticeRow(icon: "exclamationmark.circle.fill", color: .orange, title: issue.title, message: issue.message)
                            } else {
                                Button { handlePrerequisiteAction(issue) } label: {
                                    noticeRow(icon: "exclamationmark.circle.fill", color: .orange, title: issue.title,
                                              message: issue.message, action: issue.actionLabel)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                // Category cards
                Section("Categories") {
                    ForEach(vm.categories) { cat in
                        CategoryStatusCard(
                            state: cat,
                            onReset: { vm.resetCategory(categoryID: cat.id) },
                            onSync: { vm.startCategorySync(categoryID: cat.id) },
                            isSyncRunning: vm.isAnySyncRunning,
                            isIncluded: selection.isEnabled && selection.includes(cat.id),
                            olderData: cat.id == "cat_strength" ? nil : vm.syncState.olderDataProgress(for: cat.id)
                        )
                    }
                }

                Section {
                    Button("Sync Older Data") { vm.startFullSync() }
                        .disabled(vm.isAnySyncRunning || !selection.isEnabled)
                } footer: {
                    Text("Sends all Apple Health data from before your first sync. If it's interrupted, it continues where it stopped.")
                }

                Section {
                    Button("Import File…") { showFilePicker = true }
                        .disabled(vm.isAnySyncRunning)
                } footer: {
                    Text("Uploads a CSV export, for example from Alpha Progression.")
                }

            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $navigateToHealthPermissions) {
                HealthPermissionsView(vm: SettingsViewModel())
            }
            .onAppear {
                vm.refreshRecordCounts()
                vm.checkPrerequisites()
                vm.refreshLatestHealthKitDates()
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else {
                        importState.status = .error("Cannot access file")
                        importState.showResult = true
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let data = try? Data(contentsOf: url) else {
                        importState.status = .error("Failed to read file")
                        importState.showResult = true
                        return
                    }
                    performImport(data: data)
                case .failure(let error):
                    importState.status = .error(error.localizedDescription)
                    importState.showResult = true
                }
            }
        }
    }

    private var overallProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Overall Progress", value: vm.overallProgress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
            ProgressView(value: vm.overallProgress)
        }
        .padding(.vertical, 2)
    }

    /// A notice in the style of a Settings row: symbol, headline, secondary text.
    private func noticeRow(icon: String, color: Color, title: String, message: String, action: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let action {
                    Text(action)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func handlePrerequisiteAction(_ issue: SyncPrerequisiteIssue) {
        switch issue {
        case .healthPermissionsNotRequested, .somePermissionsDenied:
            navigateToHealthPermissions = true
        case .connectionFailed:
            break
        case .healthDataUnavailable:
            break
        }
    }

    private func performImport(data: Data) {
        importState.status = .uploading
        importState.showResult = true

        Task {
            let config = FreeRepsConfig.load()
            let service = FreeRepsService(config: config)
            do {
                let result = try await service.uploadCSV(data: data)
                importState.status = .success(setsInserted: result.sets_inserted)
                // Update the Weight Training category card
                let existing = vm.syncState.categories.first(where: { $0.id == "cat_strength" })?.recordCount ?? 0
                vm.syncState.updateCategory("cat_strength", status: .completed, recordCount: existing + Int(result.sets_inserted), lastSyncDate: Date())
                vm.syncState.persist()
            } catch {
                importState.status = .error(error.localizedDescription)
            }
        }
    }
}
