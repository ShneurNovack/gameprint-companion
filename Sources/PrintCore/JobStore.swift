import Foundation

/// Lifecycle of one print job on this Mac.
///
/// received  -> row exists, not yet validated (only transient inside ingest)
/// queued    -> validated, waiting for its turn (or for a retry time)
/// rendering -> HTML is being turned into a PDF
/// submitting-> about to hand the PDF to CUPS (crash window, see recover())
/// submitted -> CUPS accepted it; waiting for CUPS to report completion
/// printed   -> CUPS reports the job completed (sent to the printer)
/// failed    -> terminal failure (malformed, render failure, retries used up)
/// cancelled -> user cancelled or discarded it
public enum JobState: String, Codable, CaseIterable, Sendable {
    case received, queued, rendering, submitting, submitted, printed, failed, cancelled

    public var isTerminal: Bool { self == .printed || self == .failed || self == .cancelled }
    public var isActive: Bool { self == .rendering || self == .submitting || self == .submitted }
    public var label: String {
        switch self {
        case .received: return "Received"
        case .queued: return "Queued"
        case .rendering: return "Printing (rendering)"
        case .submitting: return "Printing (submitting)"
        case .submitted: return "Printing (in macOS queue)"
        case .printed: return "Printed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct PrintJobRecord: Identifiable, Hashable, Sendable {
    public var id: String { jobId }
    public var seq: Int
    public var jobId: String
    public var origin: String            // "server" or "local"
    public var gameKey: String
    public var eventType: String
    public var headline: String
    public var paperSize: String
    public var html: String?
    public var receivedAt: Date
    public var state: JobState
    public var attempts: Int
    public var nextAttemptAt: Date
    public var printer: String?
    public var cupsJobId: Int?
    public var cupsTitle: String?
    public var submittedAt: Date?
    public var finishedAt: Date?
    public var lastError: String?
    public var detail: String?
    public var ackNeeded: Bool
    public var ackPrinted: Bool?
    public var ackReason: String?
    public var ackAttempts: Int
    public var ackedAt: Date?
    public var duplicateCount: Int

    public var isLocal: Bool { origin == "local" }
}

public enum IngestResult: Equatable, Sendable {
    case accepted(String)
    case duplicate(String, JobState)
    case malformed(String?, String)
}

public final class JobStore: @unchecked Sendable {
    let db: SQLite

    public init(path: URL = AppPaths.database) throws {
        AppPaths.ensure()
        db = try SQLite(path: path.path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS jobs(
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          job_id TEXT NOT NULL UNIQUE,
          origin TEXT NOT NULL,
          game_key TEXT NOT NULL,
          event_type TEXT NOT NULL DEFAULT '',
          headline TEXT NOT NULL DEFAULT '',
          paper_size TEXT NOT NULL DEFAULT 'letter',
          html TEXT,
          event_data TEXT,
          received_at REAL NOT NULL,
          state TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at REAL NOT NULL DEFAULT 0,
          printer TEXT,
          cups_job_id INTEGER,
          cups_title TEXT,
          submitted_at REAL,
          finished_at REAL,
          last_error TEXT,
          detail TEXT,
          ack_needed INTEGER NOT NULL DEFAULT 0,
          ack_printed INTEGER,
          ack_reason TEXT,
          ack_attempts INTEGER NOT NULL DEFAULT 0,
          ack_next_at REAL NOT NULL DEFAULT 0,
          acked_at REAL,
          duplicate_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state);
        CREATE INDEX IF NOT EXISTS jobs_game ON jobs(game_key, seq);
        CREATE INDEX IF NOT EXISTS jobs_ack ON jobs(ack_needed, ack_next_at);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Ingest

    /// Step 1-5 of the pipeline in one transaction: check the local record,
    /// validate, persist, mark queued. A job id that already exists is never
    /// inserted again, which is what makes duplicate server delivery safe.
    public func ingest(_ job: RemoteJob) throws -> IngestResult {
        guard let jobId = job.jobId else {
            return .malformed(nil, job.problems.joined(separator: ", "))
        }
        return try db.transaction {
            if let existing = try fetch(jobId) {
                // Server re-sent a job we already hold. If we had already
                // finished it, re-send the outcome so the server settles.
                var sql = "UPDATE jobs SET duplicate_count = duplicate_count + 1"
                if existing.state.isTerminal && existing.origin == "server" && existing.ackedAt != nil {
                    sql += ", ack_needed = 1, acked_at = NULL, ack_next_at = 0"
                }
                try db.run(sql + " WHERE job_id = ?", [.text(jobId)])
                return .duplicate(jobId, existing.state)
            }
            let problem = JobStore.validate(job)
            let state: JobState = problem == nil ? .queued : .failed
            try db.run("""
            INSERT INTO jobs(job_id, origin, game_key, event_type, headline, paper_size, html, event_data,
                             received_at, state, last_error, ack_needed, ack_printed, ack_reason, finished_at)
            VALUES(?, 'server', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(jobId), .text(job.gameKey), .text(job.eventType), .text(job.headline),
                .text(job.paperSize), problem == nil ? job.html.sql : .null, job.eventDataJSON.sql,
                .real(now), .text(state.rawValue), problem.sql,
                .int(problem == nil ? 0 : 1), problem == nil ? .null : .int(0), problem.sql,
                problem == nil ? .null : .real(now),
            ])
            if let problem { return .malformed(jobId, problem) }
            return .accepted(jobId)
        }
    }

    static func validate(_ job: RemoteJob) -> String? {
        if !job.problems.isEmpty { return job.problems.joined(separator: ", ") }
        guard let id = job.jobId, id.count <= 512 else { return "job_id too long" }
        guard let html = job.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "malformed job: rendered_html missing or empty"
        }
        if html.utf8.count > 8_000_000 { return "malformed job: rendered_html larger than 8 MB" }
        let lower = html.prefix(4096).lowercased()
        if !(lower.contains("<html") || lower.contains("<!doctype") || lower.contains("<body")) {
            return "malformed job: rendered_html is not an HTML document"
        }
        if !["letter", "a4", "legal"].contains(job.paperSize) {
            return "malformed job: unsupported paper_size '\(job.paperSize)'"
        }
        return nil
    }

    /// Local jobs (test pages, reprints) use the same pipeline but are never
    /// acknowledged to the server.
    @discardableResult
    public func enqueueLocal(jobId: String, html: String, headline: String, eventType: String,
                             paperSize: String, gameKey: String? = nil) throws -> String {
        try db.run("""
        INSERT INTO jobs(job_id, origin, game_key, event_type, headline, paper_size, html, received_at, state)
        VALUES(?, 'local', ?, ?, ?, ?, ?, ?, 'queued')
        """, [.text(jobId), .text(gameKey ?? "local:\(jobId)"), .text(eventType), .text(headline),
              .text(paperSize), .text(html), .real(now)])
        return jobId
    }

    // MARK: Scheduling

    /// Oldest runnable job, never jumping ahead of an unfinished earlier job
    /// from the same game. Jobs from different games do not block each other.
    public func nextRunnable(at date: Date = Date()) throws -> PrintJobRecord? {
        let rows = try db.query("""
        SELECT * FROM jobs j
        WHERE j.state = 'queued' AND j.next_attempt_at <= ?
          AND NOT EXISTS (
            SELECT 1 FROM jobs e
            WHERE e.game_key = j.game_key AND e.seq < j.seq
              AND e.state IN ('received','queued','rendering','submitting'))
        ORDER BY j.seq LIMIT 1
        """, [.real(date.timeIntervalSince1970)])
        return rows.first.map(JobStore.record)
    }

    public func setState(_ jobId: String, _ state: JobState, error: String? = nil, detail: String? = nil) throws {
        try db.run("UPDATE jobs SET state = ?, last_error = COALESCE(?, last_error), detail = COALESCE(?, detail) WHERE job_id = ?",
                   [.text(state.rawValue), error.sql, detail.sql, .text(jobId)])
    }

    /// Put a job back in line for a later attempt.
    public func retryLater(_ jobId: String, delay: TimeInterval, error: String, countAttempt: Bool) throws {
        try db.run("""
        UPDATE jobs SET state = 'queued', next_attempt_at = ?, last_error = ?,
          attempts = attempts + ?, cups_job_id = NULL, cups_title = NULL, submitted_at = NULL
        WHERE job_id = ?
        """, [.real(now + delay), .text(error), .int(countAttempt ? 1 : 0), .text(jobId)])
    }

    /// Recorded right before calling CUPS so that a crash in the gap can be
    /// resolved on relaunch by looking the title up in CUPS.
    public func markSubmitting(_ jobId: String, printer: String, title: String) throws {
        try db.run("UPDATE jobs SET state = 'submitting', printer = ?, cups_title = ? WHERE job_id = ?",
                   [.text(printer), .text(title), .text(jobId)])
    }

    public func markSubmitted(_ jobId: String, cupsJobId: Int) throws {
        try db.run("UPDATE jobs SET state = 'submitted', cups_job_id = ?, submitted_at = ?, last_error = NULL WHERE job_id = ?",
                   [.int(Int64(cupsJobId)), .real(now), .text(jobId)])
    }

    /// Terminal outcome plus a queued acknowledgment (server jobs only).
    public func finish(_ jobId: String, printed: Bool, reason: String?, cancelled: Bool = false, detail: String? = nil) throws {
        guard let job = try fetch(jobId) else { return }
        let state: JobState = printed ? .printed : (cancelled ? .cancelled : .failed)
        let needsAck = job.origin == "server"
        try db.run("""
        UPDATE jobs SET state = ?, finished_at = ?, last_error = ?, detail = COALESCE(?, detail),
          ack_needed = ?, ack_printed = ?, ack_reason = ?, ack_next_at = 0, acked_at = NULL
        WHERE job_id = ?
        """, [.text(state.rawValue), .real(now), printed ? .null : reason.sql, detail.sql,
              .int(needsAck ? 1 : 0), .int(printed ? 1 : 0), printed ? .null : reason.sql, .text(jobId)])
    }

    // MARK: Crash recovery

    public struct RecoveryItem: Sendable { public let jobId: String; public let printer: String?; public let title: String? }

    /// Jobs caught mid-flight by a crash or reboot.
    public func interrupted() throws -> [RecoveryItem] {
        try db.query("SELECT job_id, printer, cups_title FROM jobs WHERE state IN ('rendering','submitting','received')").map {
            RecoveryItem(jobId: $0["job_id"]?.string ?? "", printer: $0["printer"]?.string, title: $0["cups_title"]?.string)
        }
    }

    public func submittedJobs() throws -> [PrintJobRecord] {
        try db.query("SELECT * FROM jobs WHERE state = 'submitted' ORDER BY seq").map(JobStore.record)
    }

    // MARK: Acks

    public func pendingAcks(at date: Date = Date(), limit: Int = 20) throws -> [PrintJobRecord] {
        try db.query("SELECT * FROM jobs WHERE ack_needed = 1 AND ack_next_at <= ? ORDER BY seq LIMIT ?",
                     [.real(date.timeIntervalSince1970), .int(Int64(limit))]).map(JobStore.record)
    }

    public func markAcked(_ jobId: String, note: String? = nil) throws {
        try db.run("UPDATE jobs SET ack_needed = 0, acked_at = ?, detail = COALESCE(?, detail) WHERE job_id = ?",
                   [.real(now), note.sql, .text(jobId)])
    }

    public func ackFailed(_ jobId: String, delay: TimeInterval) throws {
        try db.run("UPDATE jobs SET ack_attempts = ack_attempts + 1, ack_next_at = ? WHERE job_id = ?",
                   [.real(now + delay), .text(jobId)])
    }

    // MARK: User actions

    public func retry(_ jobId: String) throws {
        try db.run("""
        UPDATE jobs SET state = 'queued', next_attempt_at = 0, attempts = 0, last_error = NULL,
          cups_job_id = NULL, cups_title = NULL, submitted_at = NULL, finished_at = NULL
        WHERE job_id = ? AND state IN ('failed','queued','cancelled') AND html IS NOT NULL
        """, [.text(jobId)])
    }

    /// Explicit reprint: a brand-new local job that deliberately bypasses the
    /// duplicate check. Never acknowledged to the server.
    public func reprint(_ jobId: String) throws -> String? {
        guard let j = try fetch(jobId), let html = j.html else { return nil }
        let n = (try db.query("SELECT COUNT(*) AS c FROM jobs WHERE job_id LIKE ?", [.text("\(jobId)#reprint-%")]).first?["c"]?.int ?? 0) + 1
        let newId = "\(jobId)#reprint-\(n)"
        try enqueueLocal(jobId: newId, html: html, headline: j.headline, eventType: j.eventType,
                         paperSize: j.paperSize)
        return newId
    }

    public func discardQueued() throws -> [String] {
        let ids = try db.query("SELECT job_id FROM jobs WHERE state = 'queued'").compactMap { $0["job_id"]?.string }
        for id in ids { try finish(id, printed: false, reason: "discarded by user", cancelled: true) }
        return ids
    }

    // MARK: Reading

    public func fetch(_ jobId: String) throws -> PrintJobRecord? {
        try db.query("SELECT * FROM jobs WHERE job_id = ?", [.text(jobId)]).first.map(JobStore.record)
    }

    public func list(states: [JobState]? = nil, limit: Int = 200) throws -> [PrintJobRecord] {
        var sql = "SELECT seq, job_id, origin, game_key, event_type, headline, paper_size, NULL AS html, received_at, state, attempts, next_attempt_at, printer, cups_job_id, cups_title, submitted_at, finished_at, last_error, detail, ack_needed, ack_printed, ack_reason, ack_attempts, acked_at, duplicate_count FROM jobs"
        if let states, !states.isEmpty {
            sql += " WHERE state IN (" + states.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"
        }
        sql += " ORDER BY seq DESC LIMIT \(limit)"
        return try db.query(sql).map(JobStore.record)
    }

    public struct Counts: Equatable, Sendable {
        public var queued = 0, printing = 0, printed = 0, failed = 0, cancelled = 0, acksPending = 0, duplicates = 0
        public init() {}
    }

    public func counts() throws -> Counts {
        var c = Counts()
        for row in try db.query("SELECT state, COUNT(*) AS n FROM jobs GROUP BY state") {
            let n = row["n"]?.int ?? 0
            switch JobState(rawValue: row["state"]?.string ?? "") {
            case .queued, .received: c.queued += n
            case .rendering, .submitting, .submitted: c.printing += n
            case .printed: c.printed += n
            case .failed: c.failed += n
            case .cancelled: c.cancelled += n
            case .none: break
            }
        }
        c.acksPending = try db.query("SELECT COUNT(*) AS n FROM jobs WHERE ack_needed = 1").first?["n"]?.int ?? 0
        c.duplicates = try db.query("SELECT COALESCE(SUM(duplicate_count),0) AS n FROM jobs").first?["n"]?.int ?? 0
        return c
    }

    public func latest(where clause: String, order: String) throws -> PrintJobRecord? {
        try db.query("SELECT * FROM jobs WHERE \(clause) ORDER BY \(order) DESC LIMIT 1").first.map(JobStore.record)
    }

    /// Drops page bodies of old finished jobs but keeps the id row forever,
    /// so a very late duplicate still cannot print twice.
    public func purge(olderThanDays days: Int) throws -> Int {
        let cutoff = now - Double(max(days, 1)) * 86400
        return try db.run("""
        UPDATE jobs SET html = NULL, event_data = NULL
        WHERE html IS NOT NULL AND state IN ('printed','failed','cancelled') AND ack_needed = 0 AND finished_at < ?
        """, [.real(cutoff)])
    }

    public func clearHistory() throws -> Int {
        try db.run("UPDATE jobs SET html = NULL, event_data = NULL WHERE state IN ('printed','failed','cancelled') AND ack_needed = 0")
    }

    public func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.string) ?? nil
    }

    public func setMeta(_ key: String, _ value: String) {
        _ = try? db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        [.text(key), .text(value)])
    }

    static func record(_ r: SQLite.Row) -> PrintJobRecord {
        func d(_ k: String) -> Date? { r[k]?.double.map { Date(timeIntervalSince1970: $0) } }
        return PrintJobRecord(
            seq: r["seq"]?.int ?? 0,
            jobId: r["job_id"]?.string ?? "",
            origin: r["origin"]?.string ?? "server",
            gameKey: r["game_key"]?.string ?? "",
            eventType: r["event_type"]?.string ?? "",
            headline: r["headline"]?.string ?? "",
            paperSize: r["paper_size"]?.string ?? "letter",
            html: r["html"]?.string,
            receivedAt: d("received_at") ?? Date(),
            state: JobState(rawValue: r["state"]?.string ?? "") ?? .failed,
            attempts: r["attempts"]?.int ?? 0,
            nextAttemptAt: d("next_attempt_at") ?? Date(timeIntervalSince1970: 0),
            printer: r["printer"]?.string,
            cupsJobId: r["cups_job_id"]?.int,
            cupsTitle: r["cups_title"]?.string,
            submittedAt: d("submitted_at"),
            finishedAt: d("finished_at"),
            lastError: r["last_error"]?.string,
            detail: r["detail"]?.string,
            ackNeeded: (r["ack_needed"]?.int ?? 0) == 1,
            ackPrinted: r["ack_printed"]?.int.map { $0 == 1 },
            ackReason: r["ack_reason"]?.string,
            ackAttempts: r["ack_attempts"]?.int ?? 0,
            ackedAt: d("acked_at"),
            duplicateCount: r["duplicate_count"]?.int ?? 0
        )
    }
}
