import Foundation
import HealthKit
import SwiftUI

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var config: FreeRepsConfig = .load()
    @Published var connectionTestState: ConnectionTestState = .idle
    @Published var serverVersion: String?
    @Published var permissionsRequested: Bool = UserDefaults.standard.bool(forKey: "hk_permissions_requested")
    @Published var authorizationRequestStatus: HKAuthorizationRequestStatus = .unknown
    @Published var errorMessage: String?
    @Published var isRequestingPermissions = false
    @Published var isTestingHealth = false
    @Published var healthReadCheck: HealthKitService.ReadCheck?

    private let healthKit = HealthKitService.shared

    init() { }

    func saveConfig() {
        config.save()
    }

    // MARK: - Connection test

    func testConnection() {
        guard connectionTestState != .testing else { return }
        connectionTestState = .testing
        serverVersion = nil
        let cfg = config
        Task {
            let service = FreeRepsService(config: cfg)
            do {
                let response = try await service.ping()
                connectionTestState = .success("Connected! \(response)")
                // Fetch server version after successful connection
                await fetchServerVersion(service: service)
            } catch {
                connectionTestState = .failure(error.localizedDescription)
            }
        }
    }

    private func fetchServerVersion(service: FreeRepsService) async {
        do {
            let data = try await service.get(path: "api/v1/version")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
               let version = json["version"] {
                serverVersion = version
            }
        } catch {
            // Non-critical — just don't show version
        }
    }

    // MARK: - HealthKit permissions

    var healthConnection: HealthConnection {
        let needsRequest: Bool? = switch authorizationRequestStatus {
        case .shouldRequest: true
        case .unnecessary: false
        default: nil
        }
        return .resolve(needsRequest: needsRequest, requestedBefore: permissionsRequested,
                        syncEnabled: HealthSyncSelection.shared.isEnabled)
    }

    func refreshPermissionsState() {
        guard !isRequestingPermissions else { return }
        Task {
            do {
                authorizationRequestStatus = try await healthKit.authorizationRequestStatus()
                await SyncTrace.shared.record("authorization.status", ["status": String(authorizationRequestStatus.rawValue)])
                if authorizationRequestStatus == .unnecessary {
                    permissionsRequested = true
                    UserDefaults.standard.set(true, forKey: "hk_permissions_requested")
                }
            } catch {
                authorizationRequestStatus = .unknown
            }
        }
    }

    func testHealthAccess() {
        guard !isTestingHealth else { return }
        isTestingHealth = true
        healthReadCheck = nil
        Task {
            healthReadCheck = await healthKit.checkReadAccess()
            isTestingHealth = false
        }
    }

    func selectionChanged() {
        SyncService.stopForSelectionChange()
        errorMessage = nil
        healthReadCheck = nil
        BackgroundSyncManager.shared.startObserving()
        refreshPermissionsState()
    }

    /// Shows Apple's sheet when iOS still needs an answer, then resumes syncing.
    func connectHealth() {
        guard authorizationRequestStatus != .unnecessary else {
            setHealthSyncEnabled(true)
            return
        }
        requestPermission(label: "general") { [weak self, healthKit] in
            try await healthKit.requestAllPermissions()
            UserDefaults.standard.set(true, forKey: "hk_permissions_requested")
            self?.permissionsRequested = true
            self?.setHealthSyncEnabled(true)
        }
    }

    /// Apps cannot revoke HealthKit access; this stops FreeReps from reading and uploading.
    func disconnectHealth() {
        setHealthSyncEnabled(false)
    }

    private func setHealthSyncEnabled(_ enabled: Bool) {
        HealthSyncSelection.shared.setEnabled(enabled)
        selectionChanged()
    }

    func openHealthApp() {
        errorMessage = nil
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url) { [weak self] opened in
                Task { @MainActor in
                    if !opened {
                        self?.errorMessage = "Apple Health could not be opened. Open it from your Home Screen."
                    }
                }
            }
        }
    }

    private func requestPermission(label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        errorMessage = nil
        Task {
            defer {
                isRequestingPermissions = false
                refreshPermissionsState()
            }
            await SyncTrace.shared.record("authorization.started", ["request": label])
            do {
                try await operation()
                await SyncTrace.shared.record("authorization.finished", ["request": label])
            } catch {
                let cause = error as NSError
                if error is CancellationError ||
                    (cause.domain == HKErrorDomain && cause.code == HKError.Code.errorUserCanceled.rawValue) {
                    await SyncTrace.shared.record("authorization.cancelled", ["request": label])
                    return
                }
                errorMessage = "Apple Health could not complete this request: \(error.localizedDescription)"
                await SyncTrace.shared.record("authorization.failed", ["request": label,
                    "domain": cause.domain, "code": String(cause.code)])
            }
        }
    }

    // MARK: - Per-object authorization (medications & vision prescriptions)

    func requestVisionPrescriptionAccess() {
        requestPermission(label: "vision_prescriptions") { [healthKit] in
            try await healthKit.requestVisionPrescriptionAuthorization()
        }
    }

    func requestMedicationAccess() {
        requestPermission(label: "medications") { [healthKit] in
            if #available(iOS 26, *) {
                try await healthKit.requestMedicationAuthorization()
            }
        }
    }
}
