import Foundation

/// Local troubleshooting events. Never records credentials, response bodies or health values.
actor SyncTrace {
    static let shared = SyncTrace()
    static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freereps-sync-trace.json")
    }

    struct Event: Codable {
        let date: Date
        let stage: String
        let fields: [String: String]
    }
    private var events: [Event] = []

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(saved.suffix(1000))
        }
    }

    func record(_ stage: String, _ fields: [String: String] = [:]) {
        events.append(Event(date: Date(), stage: stage, fields: fields))
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
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

    private let session: URLSession
    private let configuration: FreeRepsConfig

    init(config: FreeRepsConfig) {
        self.configuration = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 120
        sessionConfig.timeoutIntervalForResource = 300
        // Trust Tailscale certificates
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Cancels in-flight requests, e.g. when the user pauses Health sync.
    func cancelRequests() {
        session.invalidateAndCancel()
    }

    /// POST a FreeReps payload to FreeReps and return the ingest result.
    func ingest(_ payload: FreeRepsPayload) async throws -> IngestResult {
        let url = try configuration.validatedBaseURL().appendingPathComponent("api/v1/ingest/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch EncodingError.invalidValue(_, let context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            await SyncTrace.shared.record("encode.failed", ["field": path])
            throw FreeRepsError.encodingError(path)
        }

        let (data, response) = try await performRequest(request)

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

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let started = Date()
        let requestID = UUID().uuidString
        let fields = ["request_id": requestID, "path": request.url?.path ?? "",
                      "method": request.httpMethod ?? "GET", "bytes": String(request.httpBody?.count ?? 0)]
        await SyncTrace.shared.record("http.started", fields)
        do {
            let result = try await session.data(for: request)
            await SyncTrace.shared.record("http.finished", [
                "request_id": requestID, "status": String((result.1 as? HTTPURLResponse)?.statusCode ?? 0),
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ])
            return result
        } catch {
            let cause = error as NSError
            await SyncTrace.shared.record("http.failed", ["request_id": requestID,
                "domain": cause.domain, "code": String(cause.code)])
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw FreeRepsError.connectionFailed(error.localizedDescription)
        }
    }
}
