import Foundation
import Combine

/// What the Health screen shows. iOS hides read grants and offers no revoke API,
/// so "connected" means the permission sheet was answered and FreeReps syncs.
enum HealthConnection: Equatable {
    case notConnected
    case connected
    /// Disconnected in FreeReps; Apple's permission may still be in place.
    case paused

    /// `needsRequest` is nil until iOS has answered `statusForAuthorizationRequest`.
    static func resolve(needsRequest: Bool?, requestedBefore: Bool, syncEnabled: Bool) -> HealthConnection {
        if needsRequest ?? !requestedBefore { return .notConnected }
        return syncEnabled ? .connected : .paused
    }
}

/// App-level sharing choices, independent of Apple's opaque read permissions.
@MainActor
final class HealthSyncSelection: ObservableObject {
    static let shared = HealthSyncSelection()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var disabledCategories: Set<String>
    @Published private(set) var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "healthSyncEnabled") as? Bool ?? true
        disabledCategories = Set(defaults.stringArray(forKey: "healthSyncDisabledCategories") ?? [])
    }

    func includes(_ category: String) -> Bool { !disabledCategories.contains(category) }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: "healthSyncEnabled")
        revision += 1
    }

    func setCategory(_ category: String, enabled: Bool) {
        guard includes(category) != enabled else { return }
        if enabled { disabledCategories.remove(category) } else { disabledCategories.insert(category) }
        defaults.set(disabledCategories.sorted(), forKey: "healthSyncDisabledCategories")
        revision += 1
    }

    func checkRevision(_ expected: Int) throws {
        guard isEnabled, revision == expected else { throw CancellationError() }
    }
}

enum FreeRepsConfigError: LocalizedError {
    case invalidServerAddress

    var errorDescription: String? {
        "Enter a server hostname or an http(s) address without a path, login, query or fragment."
    }
}

struct FreeRepsConfig: Codable, Equatable {
    var host: String
    var port: UInt16
    var useHTTPS: Bool = true
    var testMode: Bool = false
    var testHost: String = ""
    var testPort: UInt16 = 443
    /// Max months of HealthKit history to backfill. nil = all data (back to 2000).
    /// Legacy: `backfillYears` is decoded and converted to months for backward compatibility.
    var backfillMonths: Int? = 24

    /// Backward-compatible computed property. Setting this updates backfillMonths.
    var backfillYears: Int? {
        get { backfillMonths.map { $0 / 12 } }
        set { backfillMonths = newValue.map { $0 * 12 } }
    }

    init(host: String, port: UInt16, useHTTPS: Bool = true, testMode: Bool = false, testHost: String = "", testPort: UInt16 = 443, backfillMonths: Int? = 24) {
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.testMode = testMode
        self.testHost = testHost
        self.testPort = testPort
        self.backfillMonths = backfillMonths
    }

    static let `default` = FreeRepsConfig(
        host: "freereps.your-tailnet.ts.net",
        port: 443,
        useHTTPS: true,
        testMode: false,
        testHost: "",
        testPort: 443,
        backfillMonths: 24
    )

    func validatedBaseURL() throws -> URL {
        let effectiveHost: String
        let effectivePort: UInt16
        if testMode {
            effectiveHost = testHost
            effectivePort = testPort
        } else {
            effectiveHost = host
            effectivePort = port
        }
        let input = effectiveHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, effectivePort > 0,
              !input.contains(where: { $0.isWhitespace }), !input.contains("\\") else {
            throw FreeRepsConfigError.invalidServerAddress
        }
        let hasScheme = input.contains("://")
        let address = hasScheme ? input : "\(useHTTPS ? "https" : "http")://\(input)"
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let hostname = components.host, !hostname.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.allSatisfy({ $0 == "/" }),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw FreeRepsConfigError.invalidServerAddress
        }
        components.scheme = scheme
        // A pasted URL owns its scheme and port. A hostname uses the saved controls.
        if components.port == nil && !hasScheme { components.port = Int(effectivePort) }
        components.path = ""
        guard let url = components.url else { throw FreeRepsConfigError.invalidServerAddress }
        return url
    }

    /// Earliest date to backfill from, based on `backfillMonths`.
    var backfillStartDate: Date {
        if let months = backfillMonths {
            return Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        }
        return Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, useHTTPS, testMode, testHost, testPort, backfillMonths, backfillYears
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        useHTTPS = try c.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? true
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
        testHost = try c.decodeIfPresent(String.self, forKey: .testHost) ?? ""
        testPort = try c.decodeIfPresent(UInt16.self, forKey: .testPort) ?? 443

        // Migrate: prefer backfillMonths, fall back to backfillYears * 12
        if let months = try c.decodeIfPresent(Int.self, forKey: .backfillMonths) {
            backfillMonths = months
        } else if let years = try c.decodeIfPresent(Int.self, forKey: .backfillYears) {
            backfillMonths = years * 12
        } else {
            backfillMonths = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(useHTTPS, forKey: .useHTTPS)
        try c.encode(testMode, forKey: .testMode)
        try c.encode(testHost, forKey: .testHost)
        try c.encode(testPort, forKey: .testPort)
        try c.encode(backfillMonths, forKey: .backfillMonths)
    }

    private static let userDefaultsKey = "freerepsConfig_v1"

    static func load() -> FreeRepsConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(FreeRepsConfig.self, from: data) else {
            return .default
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: FreeRepsConfig.userDefaultsKey)
        }
    }
}
