import Foundation
import TailscaleKit

enum EmbeddedTailscaleError: LocalizedError {
    case notSignedIn
    case timedOut
    case loginPageMissing

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Tailscale in Settings → FreeReps Connection."
        case .timedOut: return "Tailscale did not connect in time. Check your internet connection."
        case .loginPageMissing: return "Tailscale's sign-in page did not load. Try again."
        }
    }
}

/// Writes Tailscale's own log to Caches/tailscale.log for troubleshooting.
/// Go writes into a pipe, so every line can be stamped with the time it arrived.
private final class TailscaleLogFile: LogSink {
    private let pipe = Pipe()
    private let file: FileHandle?
    private let lock = NSLock()

    var logFileHandle: Int32? { pipe.fileHandleForWriting.fileDescriptor }

    init() {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 2_000_000 { try? FileManager.default.removeItem(at: url) }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.write(text, source: "go")
        }
    }

    func log(_ message: String) {
        write(message, source: "swift")
    }

    private func write(_ text: String, source: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let lines = text.split(whereSeparator: \.isNewline).map { "\(stamp) \(source): \($0)\n" }
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(contentsOf: Data(lines.joined().utf8))
    }
}

/// Runs a Tailscale node inside FreeReps, so the app reaches a tailnet server
/// without the system VPN. The node's identity lives in Application Support;
/// the server resolves it to the signed-in Tailscale user like any other device.
@MainActor
final class EmbeddedTailscale: ObservableObject {
    static let shared = EmbeddedTailscale()

    enum Phase: Equatable {
        case signedOut
        /// Signed in; the node starts when a request needs it.
        case idle
        case connecting
        case waitingForLogin(URL)
        case connected
        case failed(String)
    }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        /// MagicDNS name without the trailing dot.
        let host: String
        let online: Bool
    }

    @Published private(set) var phase: Phase
    @Published private(set) var devices: [Device] = []
    /// Devices that answered like a FreeReps server.
    @Published private(set) var servers: [Device] = []
    @Published private(set) var isSearching = false

    private var node: TailscaleNode?
    private var connectTask: Task<Void, Error>?
    private let stateDirectory: URL
    private static let signedInKey = "embeddedTailscaleSignedIn"
    /// One sink for the app's lifetime, so Go never writes to a closed pipe.
    private static let log = TailscaleLogFile()

    private init() {
        stateDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale", isDirectory: true)
        phase = UserDefaults.standard.bool(forKey: Self.signedInKey) ? .idle : .signedOut
    }

    var isSignedIn: Bool { UserDefaults.standard.bool(forKey: Self.signedInKey) }

    // MARK: - Lifecycle

    /// Starts the node and shows the Tailscale sign-in page if needed.
    func signIn() async {
        do {
            try await connect(interactive: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Connects with the saved identity. Never waits for a login.
    func connectForSync() async throws {
        guard isSignedIn else { throw EmbeddedTailscaleError.notSignedIn }
        try await connect(interactive: false)
    }

    /// iOS can reclaim the node's loopback proxy while the app is suspended,
    /// so a failed request gets one fresh node before it is reported.
    func restart() async throws {
        await stop()
        try await connectForSync()
    }

    /// Stops the node but keeps the identity for the next connection.
    func stop() async {
        connectTask?.cancel()
        connectTask = nil
        if let node { try? await node.close() }
        node = nil
        if isSignedIn { phase = .idle }
    }

    /// Stops a running node unless a sync still needs it or a login is in progress.
    func stopIfIdle() async {
        guard phase == .connected, !SyncService.isSyncRunning else { return }
        await stop()
    }

    func signOut() async {
        SyncService.stopForSelectionChange()
        await stop()
        try? FileManager.default.removeItem(at: stateDirectory)
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        devices = []
        servers = []
        phase = .signedOut
    }

    func refreshDevices() async {
        guard let node, let status = try? await Self.status(of: node) else { return }
        apply(status)
    }

    /// Asks every online device for FreeReps' version endpoint; the ones that
    /// answer are servers, whatever their name.
    func findServers() async {
        guard !isSearching, let configuration = try? await sessionConfiguration() else { return }
        isSearching = true
        defer { isSearching = false }
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let started = Date()
        var found: [Device] = []
        await withTaskGroup(of: Device?.self) { group in
            for device in devices where device.online {
                group.addTask { await Self.answersAsServer(device, session: session) ? device : nil }
            }
            // Show each server as it answers; a silent device only delays the end.
            for await device in group {
                guard let device else { continue }
                found.append(device)
                servers = devices.filter { found.contains($0) }
            }
        }
        servers = devices.filter { found.contains($0) }
        await SyncTrace.shared.record("tailscale.servers_found", [
            "servers": String(servers.count), "probed": String(devices.filter(\.online).count),
            "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
        ])
    }

    nonisolated private static func answersAsServer(_ device: Device, session: URLSession) async -> Bool {
        guard let url = URL(string: "https://\(device.host)/api/v1/version"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["version"] is String
    }

    /// A URLSession configuration that routes requests through the node.
    func sessionConfiguration() async throws -> URLSessionConfiguration {
        try await connectForSync()
        guard let node else { throw EmbeddedTailscaleError.notSignedIn }
        let (configuration, _) = try await URLSessionConfiguration.tailscaleSession(node)
        return configuration
    }

    // MARK: - Connection

    private func connect(interactive: Bool) async throws {
        if node != nil, phase == .connected { return }
        if let connectTask { return try await connectTask.value }
        let task = Task {
            // The first registration with Tailscale sometimes never answers;
            // a fresh node gets the sign-in page within seconds.
            for attempt in 1... {
                do {
                    return try await bringUp(interactive: interactive)
                } catch EmbeddedTailscaleError.loginPageMissing where attempt < 3 {
                    await SyncTrace.shared.record("tailscale.login_retry", ["attempt": String(attempt)])
                    if let node { try? await node.close() }
                    node = nil
                }
            }
        }
        connectTask = task
        defer { connectTask = nil }
        do {
            try await task.value
        } catch {
            await SyncTrace.shared.record("tailscale.failed", ["error": String(describing: error)])
            if let node { try? await node.close() }
            node = nil
            throw error
        }
    }

    private func bringUp(interactive: Bool) async throws {
        phase = .connecting
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let configuration = Configuration(hostName: "freereps-iphone", path: stateDirectory.path,
                                          authKey: nil, controlURL: kDefaultControlURL, ephemeral: false)
        let node = try TailscaleNode(config: configuration, logger: Self.log)
        self.node = node
        await SyncTrace.shared.record("tailscale.starting", ["interactive": String(interactive)])

        // up() blocks until the node runs, which needs a login the first time.
        // Poll the status meanwhile to surface the login page.
        let up = Task.detached { try await node.up() }
        let started = Date()
        let deadline = started.addingTimeInterval(interactive ? 600 : 25)
        var lastState = ""
        var loginURL: URL?
        while true {
            try Task.checkCancellation()
            if let status = try? await Self.status(of: node) {
                if status.BackendState != lastState {
                    lastState = status.BackendState
                    await SyncTrace.shared.record("tailscale.state", [
                        "state": lastState, "has_auth_url": String(!(status.AuthURL ?? "").isEmpty),
                        "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
                    ])
                }
                if status.BackendState == "Running" { break }
                if status.BackendState == "NeedsLogin" || status.BackendState == "NeedsMachineAuth" {
                    guard interactive else {
                        up.cancel()
                        await SyncTrace.shared.record("tailscale.needs_login")
                        UserDefaults.standard.set(false, forKey: Self.signedInKey)
                        phase = .signedOut
                        throw EmbeddedTailscaleError.notSignedIn
                    }
                    if let url = URL(string: status.AuthURL ?? ""), url.scheme == "https" {
                        if loginURL == nil {
                            await SyncTrace.shared.record("tailscale.login_page", [
                                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
                            ])
                        }
                        loginURL = url
                        phase = .waitingForLogin(url)
                    } else if loginURL == nil, status.BackendState == "NeedsLogin",
                              Date().timeIntervalSince(started) > 8 {
                        up.cancel()
                        throw EmbeddedTailscaleError.loginPageMissing
                    }
                }
            }
            guard Date() < deadline else {
                up.cancel()
                throw EmbeddedTailscaleError.timedOut
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        try await up.value

        UserDefaults.standard.set(true, forKey: Self.signedInKey)
        if let status = try? await Self.status(of: node) { apply(status) }
        phase = .connected
        await SyncTrace.shared.record("tailscale.connected", [
            "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            "devices": String(devices.count),
        ])
    }

    private func apply(_ status: StatusSnapshot) {
        devices = (status.Peer ?? [:]).map { id, peer in
            let host = peer.DNSName.hasSuffix(".") ? String(peer.DNSName.dropLast()) : peer.DNSName
            return Device(id: id, name: peer.HostName, host: host, online: peer.Online)
        }
        .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
    }

    /// The subset of ipnstate.Status the app reads; decoded locally so a new
    /// field in Tailscale's status document cannot break it.
    private struct StatusSnapshot: Decodable {
        struct Peer: Decodable {
            let HostName: String
            let DNSName: String
            let Online: Bool
        }
        let BackendState: String
        let AuthURL: String?
        let Peer: [String: Peer]?
    }

    private static func status(of node: TailscaleNode) async throws -> StatusSnapshot {
        try JSONDecoder().decode(StatusSnapshot.self, from: try await node.statusJSON())
    }
}
