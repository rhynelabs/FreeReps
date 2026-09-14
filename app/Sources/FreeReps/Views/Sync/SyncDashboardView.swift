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
                        Button(vm.isFullSyncRunning ? "Stop" : "Cancel Sync", role: .destructive) { vm.cancelSync() }
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

                if !vm.isFullSyncRunning {
                    olderDataSection
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
            LabeledContent("Progress", value: vm.overallProgress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
            ProgressView(value: vm.overallProgress)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Older data

    /// Categories an older-data sync started but has not finished.
    private var olderDataPending: [(CategorySyncState, SyncState.OlderDataProgress)] {
        vm.categories.compactMap { category in
            guard category.id != "cat_strength", selection.includes(category.id) else { return nil }
            return vm.syncState.olderDataProgress(for: category.id).map { (category, $0) }
        }
    }

    /// Where a stopped older-data sync stands. Categories run a few at a time,
    /// so this is the furthest one; the rows below show each category.
    private var olderDataSubtitle: String {
        let pending = olderDataPending
        let left = pending.count == 1 ? "1 category left" : "\(pending.count) categories left"
        let furthest = pending.compactMap { _, progress -> Date? in
            if case .sentUpTo(let date) = progress { return date }
            return nil
        }.max()
        guard let furthest else { return "Nothing sent yet · \(left)" }
        return "Sent up to \(furthest.formatted(.dateTime.month(.abbreviated).year())) · \(left)"
    }

    /// The only place older data is offered: separate from being up to date,
    /// because new data syncs on its own.
    private var olderDataSection: some View {
        Section {
            if olderDataPending.isEmpty {
                Button("Sync Older Data") { vm.startFullSync() }
                    .disabled(vm.isAnySyncRunning || !selection.isEnabled)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Older Data").font(.headline)
                        Text(olderDataSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button("Continue") { vm.startFullSync() }
                    .disabled(vm.isAnySyncRunning || !selection.isEnabled)
            }
        } footer: {
            Text(olderDataFooter)
        }
    }

    private var olderDataFooter: String {
        if !olderDataPending.isEmpty {
            return "Continues where it stopped. New data keeps syncing in the meantime."
        }
        if vm.hasCompletedFullSync, let anchor = vm.syncState.backfillAnchorDate {
            return "Older data is on your server through \(anchor.formatted(date: .abbreviated, time: .omitted))."
        }
        let start = FreeRepsConfig.load().backfillStartDate.formatted(.dateTime.month(.abbreviated).year())
        return "Sends everything in Apple Health since \(start). Keep FreeReps open while it runs; if it stops, it continues where it left off."
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
