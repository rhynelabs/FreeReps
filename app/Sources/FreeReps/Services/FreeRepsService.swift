import Foundation
import zlib

/// Local troubleshooting events, one JSON object per line. Never records
/// credentials, response bodies or health values.
actor SyncTrace {
    static let shared = SyncTrace()
    static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freereps-sync-trace.jsonl")
    }
    /// Past this size the older half is dropped when the app next starts.
    private static let maxBytes = 8 << 20

    struct Event: Codable {
        let date: Date
        let stage: String
        let fields: [String: String]
    }
    private var handle: FileHandle?

    private init() {}

    func record(_ stage: String, _ fields: [String: String] = [:]) {
        guard var line = try? JSONEncoder().encode(Event(date: Date(), stage: stage, fields: fields)) else { return }
        line.append(0x0A)
        if handle == nil { handle = Self.openForAppending() }
        try? handle?.write(contentsOf: line)
    }

    private static func openForAppending() -> FileHandle? {
        let url = fileURL
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > maxBytes,
           let data = try? Data(contentsOf: url) {
            let tail = data[(data.count / 2)...]
            if let newline = tail.firstIndex(of: 0x0A) {
                try? data[(newline + 1)...].write(to: url, options: .atomic)
            }
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Errors from FreeReps HTTP communication.
enum FreeRepsError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case encodingError(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid FreeReps URL"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .encodingError(let path): return "Cannot encode payload field: \(path)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}

/// Ingest result returned by FreeReps after processing a payload.
struct IngestResult: Codable {
    var metrics_received: Int?
    var metrics_inserted: Int?
    var metrics_skipped: Int?
    var metrics_rejected: Int?
    var sleep_sessions_inserted: Int?
    var sleep_stages_inserted: Int?
    var workouts_received: Int?
    var workouts_inserted: Int?
    var ecg_recordings_inserted: Int?
    var audiograms_inserted: Int?
    var activity_summaries_inserted: Int?
    var medications_inserted: Int?
    var vision_prescriptions_inserted: Int?
    var state_of_mind_inserted: Int?
    var category_samples_inserted: Int?
    var message: String?

    var totalInserted: Int {
        let a: Int = (metrics_inserted ?? 0) + (sleep_sessions_inserted ?? 0) + (sleep_stages_inserted ?? 0)
        let b: Int = (workouts_inserted ?? 0) + (ecg_recordings_inserted ?? 0) + (audiograms_inserted ?? 0)
        let c: Int = (activity_summaries_inserted ?? 0) + (medications_inserted ?? 0)
        let d: Int = (vision_prescriptions_inserted ?? 0) + (state_of_mind_inserted ?? 0) + (category_samples_inserted ?? 0)
        return a + b + c + d
    }
}

/// Result from the unified import endpoint (CSV uploads).
struct ImportResult: Codable {
    var sets_received: Int
    var sets_inserted: Int64
    var message: String?
}

/// Lightweight HTTP client for FreeReps ingest API.
actor FreeRepsService {

    private var session: URLSession?
    private let configuration: FreeRepsConfig

    init(config: FreeRepsConfig) {
        self.configuration = config
    }

    /// Cancels in-flight requests, e.g. when the user pauses Health sync.
    func cancelRequests() {
        session?.invalidateAndCancel()
        session = nil
    }

    /// Created on first use: in Tailscale mode the session needs a running node.
    private func currentSession() async throws -> URLSession {
        if let session { return session }
        let sessionConfig = configuration.usesEmbeddedTailscale
            ? try await EmbeddedTailscale.shared.sessionConfiguration()
            : URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = Self.ingestTimeout
        sessionConfig.timeoutIntervalForResource = 300
        let session = URLSession(configuration: sessionConfig)
        self.session = session
        return session
    }

    /// Servers before 1.3 reject a compressed body as invalid JSON. Remembered per
    /// client, so every sync run tries once more and picks up a server upgrade.
    private var serverAcceptsGzip = true

    /// POST a FreeReps payload to FreeReps and return the ingest result.
    func ingest(_ payload: FreeRepsPayload) async throws -> IngestResult {
        let url = try configuration.validatedBaseURL().appendingPathComponent("api/v1/ingest/")
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch EncodingError.invalidValue(_, let context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            await SyncTrace.shared.record("encode.failed", ["field": path])
            throw FreeRepsError.encodingError(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The session allows 120 s, but a request carries its own default of
        // 60 s, and which one wins is not documented; set both so a 5,000-row
        // batch on a loaded server (11 s seen) has the same margin either way.
        request.timeoutInterval = Self.ingestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // JSON of health samples shrinks about tenfold; the server inflates it back.
        let compressed = serverAcceptsGzip ? body.gzipped() : nil
        if let compressed {
            request.httpBody = compressed
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = body
        }
        let trace = ["rows": String(payload.data.rowCount), "json_bytes": String(body.count)]

        // Ingest is idempotent — the server drops rows it already has — so a
        // request that timed out can be sent again.
        var (data, response) = try await performRequest(request, trace: trace, retryTimeouts: true)
        if compressed != nil, let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 415 {
            serverAcceptsGzip = false
            await SyncTrace.shared.record("http.gzip_unsupported", ["status": String(status)])
            request.httpBody = body
            request.setValue(nil, forHTTPHeaderField: "Content-Encoding")
            (data, response) = try await performRequest(request, trace: trace, retryTimeouts: true)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FreeRepsError.connectionFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FreeRepsError.httpError(statusCode: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(IngestResult.self, from: data)
        } catch {
            throw FreeRepsError.decodingError(error.localizedDescription)
        }
    }

    /// Upload a CSV file to the unified import endpoint.
    func uploadCSV(data: Data) async throws -> ImportResult {
        let url = try configuration.validatedBaseURL().appendingPathComponent("api/v1/import")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw FreeRepsError.connectionFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw FreeRepsError.httpError(statusCode: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(ImportResult.self, from: responseData)
        } catch {
            throw FreeRepsError.decodingError(error.localizedDescription)
        }
    }

    /// Ping FreeReps to verify connectivity and identity.
    func ping() async throws -> String {
        let url = try configuration.validatedBaseURL().appendingPathComponent("api/v1/me")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw FreeRepsError.connectionFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FreeRepsError.httpError(statusCode: http.statusCode, body: body)
        }

        // Return raw JSON for display
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// GET a JSON response from a FreeReps endpoint.
    func get(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let url = try configuration.validatedBaseURL().appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FreeRepsError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw FreeRepsError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw FreeRepsError.connectionFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FreeRepsError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }

    /// Errors the node's loopback proxy produces while it is not usable: "bad URL"
    /// for the first seconds after the node starts, before the peer path exists,
    /// and connection errors once iOS has reclaimed the proxy in the background.
    private static let proxyErrors: Set<URLError.Code> = [.badURL, .cannotConnectToHost, .networkConnectionLost]
    /// Pauses before another attempt; the last one through the proxy restarts the node.
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
    /// Idle time allowed on an ingest request, in seconds.
    private static let ingestTimeout: TimeInterval = 120

    /// - Parameter retryTimeouts: Send the request again after a timeout. Only
    ///   for requests the server can receive twice without harm.
    private func performRequest(_ request: URLRequest, trace: [String: String] = [:],
                                retryTimeouts: Bool = false, attempt: Int = 0) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let started = Date()
        let requestID = UUID().uuidString
        let fields = ["request_id": requestID, "path": request.url?.path ?? "",
                      "method": request.httpMethod ?? "GET", "bytes": String(request.httpBody?.count ?? 0)]
        await SyncTrace.shared.record("http.started", fields.merging(trace) { current, _ in current })
        let session: URLSession
        do {
            session = try await currentSession()
        } catch {
            await SyncTrace.shared.record("http.no_session", ["request_id": requestID])
            if error is CancellationError { throw error }
            throw FreeRepsError.connectionFailed(error.localizedDescription)
        }
        do {
            let result = try await session.data(for: request)
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            var fields = [
                "request_id": requestID, "status": String(status),
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ]
            // The server's own account of a failure, e.g. a 500's {"error": …}.
            if !(200..<300).contains(status) {
                fields["body"] = String((String(data: result.0, encoding: .utf8) ?? "").prefix(300))
            }
            await SyncTrace.shared.record("http.finished", fields)
            return result
        } catch {
            let cause = error as NSError
            await SyncTrace.shared.record("http.failed", ["request_id": requestID,
                "domain": cause.domain, "code": String(cause.code),
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))])
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let code = (error as? URLError)?.code
            let proxyFailed = configuration.usesEmbeddedTailscale && code.map(Self.proxyErrors.contains) == true
            let timedOut = retryTimeouts && code == .timedOut
            if attempt < Self.retryDelays.count, proxyFailed || timedOut {
                await SyncTrace.shared.record("http.retry", ["request_id": requestID, "attempt": String(attempt + 1),
                                                             "reason": timedOut ? "timeout" : "proxy"])
                try await Task.sleep(for: Self.retryDelays[attempt])
                if proxyFailed {
                    // A timeout is the server's: the proxy and its session are fine.
                    self.session = nil
                    if attempt == Self.retryDelays.count - 1 {
                        try await EmbeddedTailscale.shared.restart()
                    }
                }
                return try await performRequest(request, trace: trace, retryTimeouts: retryTimeouts, attempt: attempt + 1)
            }
            throw FreeRepsError.connectionFailed(error.localizedDescription)
        }
    }
}

extension Data {
    /// gzip-compresses the data with zlib; nil if zlib refuses (it never does for plain data).
    func gzipped() -> Data? {
        var stream = z_stream()
        // windowBits 15 + 16 selects the gzip wrapper instead of zlib's own.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data(capacity: count / 8 + 64)
        var chunk = [Bytef](repeating: 0, count: 64 * 1024)
        let finished: Bool = withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                output.append(contentsOf: chunk[0..<(chunk.count - Int(stream.avail_out))])
                if status == Z_STREAM_END { return true }
                if status != Z_OK && status != Z_BUF_ERROR { return false }
            }
        }
        return finished ? output : nil
    }
}
