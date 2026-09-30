import Foundation

public enum APIError: Error, LocalizedError, Sendable {
    case notConfigured
    case insecureURL
    case network(String)
    case unauthorized(String)
    case notFound(String)
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Server URL is not set"
        case .insecureURL: return "Server URL must use HTTPS"
        case .network(let m): return "Network error: \(m)"
        case .unauthorized(let m): return "Credentials rejected (\(m))"
        case .notFound(let m): return "Not found (\(m))"
        case .http(let c, let m): return "Server error \(c): \(m)"
        case .badResponse(let m): return "Unexpected response: \(m)"
        }
    }

    /// Transient errors are retried with backoff; the rest need a human or
    /// are terminal for that request.
    public var isTransient: Bool {
        switch self {
        case .network: return true
        case .http(let c, _): return c >= 500 || c == 429 || c == 408
        case .badResponse: return true
        default: return false
        }
    }
}

/// One job as delivered by `companionPoll`. Parsed field by field so that a
/// single malformed entry never poisons the rest of the batch.
public struct RemoteJob: Sendable {
    public var jobId: String?
    public var eventType: String
    public var headline: String
    public var html: String?
    public var paperSize: String
    public var eventDataJSON: String?
    public var gameKey: String
    public var problems: [String]

    public init(dict: [String: Any]) {
        var problems: [String] = []
        let rawId = dict["job_id"]
        if let s = rawId as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            jobId = s
        } else if let n = rawId as? NSNumber {
            jobId = n.stringValue
        } else {
            jobId = nil
            problems.append("missing job_id")
        }
        eventType = (dict["event_type"] as? String) ?? "unknown"
        headline = (dict["headline"] as? String) ?? ""
        html = dict["rendered_html"] as? String
        paperSize = ((dict["paper_size"] as? String) ?? "letter").lowercased()
        let ed = dict["event_data"] as? [String: Any]
        if let ed, let data = try? JSONSerialization.data(withJSONObject: ed) {
            eventDataJSON = String(data: data, encoding: .utf8)
        } else {
            eventDataJSON = nil
        }
        gameKey = RemoteJob.deriveGameKey(eventType: eventType, eventData: ed, topLevel: dict)
        self.problems = problems
    }

    /// Groups jobs by game so one game's failure does not reorder another's.
    static func deriveGameKey(eventType: String, eventData: [String: Any]?, topLevel: [String: Any] = [:]) -> String {
        if eventType == "test" { return "test" }
        for key in ["espn_event_id", "monitored_game_id"] {
            if let v = topLevel[key] as? String, !v.isEmpty { return "game:\(v)" }
            if let v = topLevel[key] as? NSNumber { return "game:\(v.stringValue)" }
        }
        if let ed = eventData {
            for key in ["espnEventId", "espn_event_id", "gameId", "eventId"] {
                if let v = ed[key] as? String, !v.isEmpty { return "game:\(v)" }
                if let v = ed[key] as? NSNumber { return "game:\(v.stringValue)" }
            }
            let away = (ed["awayTeam"] as? [String: Any])?["abbr"] as? String
            let home = (ed["homeTeam"] as? [String: Any])?["abbr"] as? String
            if let away, let home { return "game:\(away)@\(home)" }
        }
        return "game:unknown"
    }
}

public struct HeartbeatResult: Sendable { public let queued: Int }

public final class APIClient: @unchecked Sendable {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "GamePrintCompanion/\(AppInfo.version) (macOS)"]
        session = URLSession(configuration: cfg)
    }

    private func endpoint(_ server: String, _ fn: String) throws -> URL {
        guard !server.isEmpty, let url = URL(string: "\(server)/functions/\(fn)"), let host = url.host else {
            throw APIError.notConfigured
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        if url.scheme != "https" && !local { throw APIError.insecureURL }
        return url
    }

    private func post(_ server: String, _ fn: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: try endpoint(server, fn))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.network((error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? String) ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            guard let json else { throw APIError.badResponse("body is not a JSON object") }
            return json
        case 401, 403: throw APIError.unauthorized(message)
        case 404: throw APIError.notFound(message)
        default: throw APIError.http(http.statusCode, message)
        }
    }

    private func auth(_ c: Credentials) -> [String: Any] {
        ["device_id": c.deviceId, "auth_token": c.authToken]
    }

    public func heartbeat(server: String, creds: Credentials, printer: String?) async throws -> HeartbeatResult {
        var body = auth(creds)
        body["platform"] = "macOS"
        body["app_version"] = AppInfo.version
        if let printer { body["selected_printer"] = printer }
        let json = try await post(server, "companionHeartbeat", body)
        let queued = (json["queued"] as? NSNumber)?.intValue ?? 0
        return HeartbeatResult(queued: queued)
    }

    public func poll(server: String, creds: Credentials) async throws -> [[String: Any]] {
        let json = try await post(server, "companionPoll", auth(creds))
        guard let jobs = json["jobs"] as? [Any] else { throw APIError.badResponse("missing jobs array") }
        return jobs.map { ($0 as? [String: Any]) ?? [:] }
    }

    public func ack(server: String, creds: Credentials, jobId: String, printed: Bool, reason: String?) async throws {
        var body = auth(creds)
        body["job_id"] = jobId
        body["outcome"] = printed ? "printed" : "failed"
        if let reason, !printed { body["reason"] = String(reason.prefix(300)) }
        _ = try await post(server, "companionAck", body)
    }
}

public enum AppInfo {
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
