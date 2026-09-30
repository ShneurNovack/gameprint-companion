import AppKit
import Combine
import Foundation

public enum ConnectionState: Equatable, Sendable {
    case notPaired
    case connecting
    case connected
    case offline(String)
    case unauthorized(String)

    public var label: String {
        switch self {
        case .notPaired: return "Not paired"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .offline(let m): return "Disconnected (\(m))"
        case .unauthorized: return "Credentials rejected"
        }
    }
}

public enum OverallState: String, Sendable {
    case ready = "Ready"
    case printing = "Printing"
    case jobsQueued = "Jobs Queued"
    case printerOffline = "Printer Offline"
    case disconnected = "Disconnected"
    case configurationNeeded = "Configuration Needed"
    case paused = "Paused"
    case error = "Error"

    public var symbol: String {
        switch self {
        case .ready: return "printer.fill"
        case .printing: return "printer.dotmatrix.fill"
        case .jobsQueued: return "tray.full.fill"
        case .printerOffline: return "exclamationmark.triangle.fill"
        case .disconnected: return "wifi.slash"
        case .configurationNeeded: return "gearshape.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

public struct EngineStatus: Sendable {
    public var overall: OverallState = .configurationNeeded
    public var connection: ConnectionState = .notPaired
    public var lastHeartbeat: Date?
    public var lastAPISuccess: Date?
    public var lastAPIError: String?
    public var serverQueued: Int = 0
    public var printer: PrinterInfo?
    public var printerError: String?
    public var counts = JobStore.Counts()
    public var lastReceived: PrintJobRecord?
    public var lastPrinted: PrintJobRecord?
    public var currentJob: String?
    public var startedAt = Date()
    public var consecutiveNetFailures = 0
}

public enum EngineEvent: Sendable {
    case printed(PrintJobRecord)
    case failed(PrintJobRecord, String)
    case printerProblem(String)
    case printerRecovered(String)
    case connectionLost(String)
    case connectionRestored
    case credentialsRejected
}

/// The whole unattended pipeline: poll -> persist -> render -> CUPS ->
/// verify -> acknowledge, with crash recovery and retry at every step.
@MainActor
public final class PrintEngine: ObservableObject {
    @Published public private(set) var status = EngineStatus()
    @Published public private(set) var jobs: [PrintJobRecord] = []
    @Published public private(set) var printers: [PrinterInfo] = []
    @Published public var config: CompanionConfig {
        didSet { if config != oldValue { config.save(); kickAll(); refresh() } }
    }
    public private(set) var credentials: Credentials?
    public var onEvent: ((EngineEvent) -> Void)?

    public let store: JobStore
    private let api = APIClient()
    private let renderer = HTMLRenderer()
    private var loops: [Task<Void, Never>] = []
    private var kicks: Set<String> = []
    private var lastHeartbeatAttempt = Date.distantPast
    private var lastResumeAttempt = Date.distantPast
    private var lastPrinterProblem: String?
    private var running = false
    private let processingLock = NSLock()

    public init(store: JobStore? = nil, loadCredentials: Bool = true) throws {
        AppPaths.ensure()
        self.store = try store ?? JobStore()
        self.config = CompanionConfig.load()
        if loadCredentials, let c = CredentialStore.load() {
            credentials = c
            Log.shared.registerSecret(c.authToken)
        }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        status.startedAt = Date()
        logInfo("Engine starting (version \(AppInfo.version), server \(config.normalizedServer.isEmpty ? "unset" : config.normalizedServer), device \(credentials?.deviceId ?? "unpaired"))")
        recoverInterruptedJobs()
        refreshPrinters()
        refresh()
        loops = [
            Task { [weak self] in await self?.networkLoop() },
            Task { [weak self] in await self?.printLoop() },
            Task { [weak self] in await self?.monitorLoop() },
            Task { [weak self] in await self?.ackLoop() },
            Task { [weak self] in await self?.housekeepingLoop() },
        ]
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        running = false
        Log.shared.flush()
    }

    /// Called on wake, network change or settings change: skip any backoff.
    public func kickAll() {
        kicks.formUnion(["net", "print", "monitor", "ack"])
        status.consecutiveNetFailures = 0
    }

    private func sleep(_ seconds: Double, key: String) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !Task.isCancelled {
            if kicks.remove(key) != nil { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: Pairing

    public func pair(server: String, deviceId: String, token: String) async throws {
        var cfg = config
        cfg.serverURL = server
        let creds = Credentials(deviceId: deviceId, authToken: token)
        Log.shared.registerSecret(creds.authToken)
        _ = try await api.heartbeat(server: cfg.normalizedServer, creds: creds, printer: currentPrinterLabel())
        try CredentialStore.save(creds)
        credentials = creds
        config = cfg
        status.connection = .connected
        status.lastHeartbeat = Date()
        status.lastAPISuccess = Date()
        logInfo("Paired as device \(creds.deviceId) with \(cfg.normalizedServer)")
        kickAll()
        refresh()
    }

    /// Use credentials without touching the Keychain (headless tools/tests).
    public func useCredentials(_ creds: Credentials) {
        credentials = creds
        Log.shared.registerSecret(creds.authToken)
        refresh()
    }

    public func unpair() {
        CredentialStore.delete()
        credentials = nil
        Log.shared.clearSecrets()
        status.connection = .notPaired
        logInfo("Device unpaired; credentials removed from Keychain")
        refresh()
    }

    // MARK: Network loop (heartbeat + poll)

    private func currentPrinterLabel() -> String? {
        guard let p = try? PrinterService.resolve(config.printerName) else { return config.printerName }
        return p.displayName
    }

    private func networkLoop() async {
        while !Task.isCancelled {
            guard let creds = credentials, !config.normalizedServer.isEmpty else {
                status.connection = .notPaired
                refresh()
                await sleep(2, key: "net")
                continue
            }
            let server = config.normalizedServer
            var delay = config.pollInterval
            do {
                if Date().timeIntervalSince(lastHeartbeatAttempt) >= config.heartbeatInterval {
                    lastHeartbeatAttempt = Date()
                    let hb = try await api.heartbeat(server: server, creds: creds, printer: currentPrinterLabel())
                    status.lastHeartbeat = Date()
                    status.serverQueued = hb.queued
                }
                let batch = try await api.poll(server: server, creds: creds)
                noteAPISuccess()
                if !batch.isEmpty { ingest(batch) }
                if batch.count >= 50 { delay = 0.2 }   // more waiting on the server
            } catch let e as APIError {
                delay = noteAPIFailure(e)
            } catch {
                delay = noteAPIFailure(.network(error.localizedDescription))
            }
            refresh()
            await sleep(delay, key: "net")
        }
    }

    private func noteAPISuccess() {
        let wasDown: Bool
        if case .offline = status.connection { wasDown = true } else { wasDown = false }
        status.lastAPISuccess = Date()
        status.lastAPIError = nil
        status.connection = .connected
        status.consecutiveNetFailures = 0
        if wasDown { logInfo("Connection restored"); onEvent?(.connectionRestored) }
    }

    /// Returns the delay before the next attempt (exponential, capped).
    private func noteAPIFailure(_ e: APIError) -> Double {
        status.lastAPIError = e.localizedDescription
        status.consecutiveNetFailures += 1
        let n = status.consecutiveNetFailures
        switch e {
        case .unauthorized(let m):
            if status.connection != .unauthorized(m) {
                logError("Server rejected this device's credentials: \(m)")
                onEvent?(.credentialsRejected)
            }
            status.connection = .unauthorized(m)
            return 60
        case .notConfigured, .insecureURL:
            status.connection = .offline(e.localizedDescription)
            return 30
        default:
            if n == 1 || n % 10 == 0 { logWarn("API request failed (\(n)x): \(e.localizedDescription)") }
            if n >= 2 {
                if case .offline = status.connection {} else { onEvent?(.connectionLost(e.localizedDescription)) }
                status.connection = .offline(e.localizedDescription)
            }
            return min(60, config.pollInterval * pow(2, Double(min(n - 1, 5))))
        }
    }

    public func ingest(_ batch: [[String: Any]]) {
        for dict in batch {
            let job = RemoteJob(dict: dict)
            do {
                switch try store.ingest(job) {
                case .accepted(let id):
                    logInfo("Received job \(id) [\(job.eventType)] \(job.headline) game=\(job.gameKey)")
                case .duplicate(let id, let state):
                    logWarn("Duplicate delivery of \(id) ignored (already \(state.rawValue)); it will not print again")
                case .malformed(let id, let why):
                    logError("Malformed job \(id ?? "<no id>"): \(why)")
                    if let id, let rec = try? store.fetch(id) { onEvent?(.failed(rec, why)) }
                }
            } catch {
                // Could not persist: this is the one case where the job would be
                // lost, so make it loud. The server keeps it as "delivered".
                logError("FAILED TO PERSIST job \(job.jobId ?? "?"): \(error.localizedDescription)")
                status.lastAPIError = "Local database error: \(error.localizedDescription)"
            }
        }
        kicks.formUnion(["print", "ack"])
        refresh()
    }

    // MARK: Print loop

    private func printLoop() async {
        while !Task.isCancelled {
            refreshPrinters()
            if !config.paused, let job = try? store.nextRunnable() {
                await process(job)
                refresh()
                continue   // go straight to the next one
            }
            await sleep(1.5, key: "print")
        }
    }

    private func spoolURL(for job: PrintJobRecord) -> URL {
        let safe = job.jobId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return AppPaths.spool.appendingPathComponent(String(safe.prefix(150)) + ".pdf")
    }

    private func process(_ job: PrintJobRecord) async {
        status.currentJob = job.jobId
        defer { status.currentJob = nil }

        // Long-outage policy.
        if config.maxQueueAgeMinutes > 0, !job.isLocal,
           Date().timeIntervalSince(job.receivedAt) > Double(config.maxQueueAgeMinutes) * 60 {
            let why = "expired: waited more than \(config.maxQueueAgeMinutes) min (outage policy)"
            try? store.finish(job.jobId, printed: false, reason: why)
            logWarn("Job \(job.jobId) \(why)")
            return
        }

        // Printer availability.
        let printer: PrinterInfo
        do {
            printer = try PrinterService.resolve(config.printerName)
        } catch {
            status.printerError = error.localizedDescription
            try? store.retryLater(job.jobId, delay: 15, error: error.localizedDescription, countAttempt: false)
            reportPrinterProblem(error.localizedDescription)
            return
        }
        if printer.state == .stopped, config.autoResumePrinterQueue, Date().timeIntervalSince(lastResumeAttempt) > 60 {
            lastResumeAttempt = Date()
            PrinterService.resumeQueue(printer.name)
        }
        if !printer.acceptingJobs {
            let why = "printer '\(printer.displayName)' is not accepting jobs"
            try? store.retryLater(job.jobId, delay: 15, error: why, countAttempt: false)
            reportPrinterProblem(why)
            return
        }

        // Render (or reuse an already-validated PDF from an earlier attempt).
        guard let html = job.html else {
            try? store.finish(job.jobId, printed: false, reason: "page content no longer stored")
            return
        }
        let paper = config.paper == .job ? PaperSpec.from(job.paperSize) : PaperSpec.from(config.paper.rawValue)
        let pdf = spoolURL(for: job)
        try? store.setState(job.jobId, .rendering)
        do {
            let expected = paper.oriented(config.orientation)
            if (try? HTMLRenderer.validate(pdf: pdf, expected: expected)) == nil {
                let check = try await renderer.render(html: html, paper: paper, orientation: config.orientation, to: pdf)
                logInfo("Rendered \(job.jobId): \(check.pages) page(s), \(check.bytes) bytes, \(Int(check.pageSize.width))x\(Int(check.pageSize.height))pt")
            }
        } catch {
            let attempts = job.attempts + 1
            let why = error.localizedDescription
            if attempts >= 3 {
                logError("Giving up on \(job.jobId) after \(attempts) render attempts: \(why)")
                try? store.finish(job.jobId, printed: false, reason: "render failed: \(why)")
                if let rec = try? store.fetch(job.jobId) { onEvent?(.failed(rec, why)) }
            } else {
                logWarn("Render attempt \(attempts) failed for \(job.jobId): \(why)")
                try? store.retryLater(job.jobId, delay: Double(5 * attempts), error: why, countAttempt: true)
            }
            return
        }

        // Submit to CUPS. The submitting marker + unique title let a crash
        // right here be resolved on relaunch without printing twice.
        let title = "GamePrint \(job.jobId) #\(job.attempts + 1)"
        do {
            try store.markSubmitting(job.jobId, printer: printer.name, title: title)
        } catch {
            logError("Could not record submission for \(job.jobId): \(error.localizedDescription)")
            try? store.retryLater(job.jobId, delay: 5, error: error.localizedDescription, countAttempt: false)
            return
        }
        do {
            let opts = SubmitOptions(media: paper.cupsMedia, orientation: config.orientation, scaling: config.scaling,
                                     colorMode: config.colorMode, copies: config.copies, duplex: config.duplex)
            let cupsId = try PrinterService.submit(pdf: pdf, printer: printer.name, title: title, options: opts)
            try store.markSubmitted(job.jobId, cupsJobId: cupsId)
            logInfo("Submitted \(job.jobId) to '\(printer.displayName)' as CUPS job \(printer.name)-\(cupsId)")
            kicks.insert("monitor")
        } catch {
            let attempts = job.attempts + 1
            let delay = min(120, 5 * pow(2, Double(min(attempts, 5))))
            logWarn("Submit attempt \(attempts) for \(job.jobId) failed: \(error.localizedDescription); retrying in \(Int(delay))s")
            try? store.retryLater(job.jobId, delay: delay, error: error.localizedDescription, countAttempt: true)
            reportPrinterProblem(error.localizedDescription)
        }
    }

    private func reportPrinterProblem(_ message: String) {
        if lastPrinterProblem != message {
            lastPrinterProblem = message
            onEvent?(.printerProblem(message))
        }
    }

    // MARK: Monitor loop (verify with CUPS)

    private func monitorLoop() async {
        while !Task.isCancelled {
            if let submitted = try? store.submittedJobs(), !submitted.isEmpty {
                let byPrinter = Dictionary(grouping: submitted) { $0.printer ?? "" }
                for (printerName, group) in byPrinter where !printerName.isEmpty {
                    let cupsJobs = PrinterService.jobs(printer: printerName)
                    for job in group { check(job, in: cupsJobs) }
                }
                refresh()
            }
            await sleep(2, key: "monitor")
        }
    }

    private func check(_ job: PrintJobRecord, in cupsJobs: [CupsJob]) {
        guard let cupsId = job.cupsJobId else { return }
        guard let cj = cupsJobs.first(where: { $0.id == cupsId }) else {
            // The list is only trustworthy when CUPS answered with something.
            if !cupsJobs.isEmpty, let at = job.submittedAt, Date().timeIntervalSince(at) > 120 {
                try? store.finish(job.jobId, printed: true, reason: nil,
                                  detail: "CUPS job \(cupsId) no longer in history; last seen accepted by spooler")
                logWarn("CUPS job \(cupsId) for \(job.jobId) vanished from history; treating as printed")
                finished(job.jobId)
            }
            return
        }
        switch cj.status {
        case .completed:
            let when = cj.completedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "now"
            try? store.finish(job.jobId, printed: true, reason: nil, detail: "macOS print system completed CUPS job \(cupsId) at \(when)")
            try? FileManager.default.removeItem(at: spoolURL(for: job))
            logInfo("Printed \(job.jobId) (CUPS job \(cupsId) completed)")
            finished(job.jobId)
        case .cancelled:
            try? store.finish(job.jobId, printed: false, reason: "cancelled in the macOS print queue", cancelled: true)
            logWarn("CUPS job \(cupsId) for \(job.jobId) was cancelled outside the app")
            finished(job.jobId)
        case .aborted:
            if job.attempts + 1 >= config.maxAutoRetries {
                try? store.finish(job.jobId, printed: false, reason: "macOS print system aborted the job \(job.attempts + 1) times")
                logError("Giving up on \(job.jobId): aborted by CUPS \(job.attempts + 1) times")
                finished(job.jobId)
            } else {
                logWarn("CUPS aborted job \(cupsId) for \(job.jobId); resubmitting")
                try? store.retryLater(job.jobId, delay: 20, error: "print system aborted the job", countAttempt: true)
                kicks.insert("print")
            }
        case .pending, .held, .processing, .stopped:
            break
        }
    }

    private func finished(_ jobId: String) {
        kicks.insert("ack")
        guard let rec = try? store.fetch(jobId) else { return }
        if rec.state == .printed { onEvent?(.printed(rec)) }
        if rec.state == .failed { onEvent?(.failed(rec, rec.lastError ?? "failed")) }
    }

    // MARK: Ack loop

    private func ackLoop() async {
        while !Task.isCancelled {
            if let creds = credentials, !config.normalizedServer.isEmpty,
               let due = try? store.pendingAcks(), !due.isEmpty {
                for job in due {
                    let printed = job.ackPrinted ?? false
                    do {
                        try await api.ack(server: config.normalizedServer, creds: creds, jobId: job.jobId,
                                          printed: printed, reason: job.ackReason)
                        try? store.markAcked(job.jobId)
                        noteAPISuccess()
                        logInfo("Acknowledged \(job.jobId) as \(printed ? "printed" : "failed")")
                    } catch APIError.notFound(let m) {
                        try? store.markAcked(job.jobId, note: "server does not know this job (\(m))")
                        logWarn("Server returned 404 acknowledging \(job.jobId); marking settled")
                    } catch {
                        let delay = min(300, 5 * pow(2, Double(min(job.ackAttempts, 6))))
                        try? store.ackFailed(job.jobId, delay: delay)
                        if job.ackAttempts == 0 || job.ackAttempts % 5 == 0 {
                            logWarn("Ack for \(job.jobId) failed (attempt \(job.ackAttempts + 1)): \(error.localizedDescription); retrying in \(Int(delay))s")
                        }
                        if let e = error as? APIError { _ = noteAPIFailure(e) }
                        break
                    }
                }
                refresh()
            }
            await sleep(1.5, key: "ack")
        }
    }

    // MARK: Recovery + housekeeping

    private func recoverInterruptedJobs() {
        guard let items = try? store.interrupted(), !items.isEmpty else { return }
        for item in items {
            if let printer = item.printer, let title = item.title,
               let rec = try? store.fetch(item.jobId), rec.state == .submitting {
                if let cj = PrinterService.findJob(printer: printer, title: title) {
                    try? store.markSubmitted(item.jobId, cupsJobId: cj.id)
                    logWarn("Recovery: \(item.jobId) had reached CUPS before the interruption (job \(cj.id)); not resubmitting")
                    continue
                }
            }
            try? store.retryLater(item.jobId, delay: 0, error: "interrupted by app exit; resuming", countAttempt: false)
            logWarn("Recovery: \(item.jobId) was interrupted before reaching the print system; re-queued")
        }
    }

    private func housekeepingLoop() async {
        while !Task.isCancelled {
            if let n = try? store.purge(olderThanDays: config.retentionDays), n > 0 {
                logInfo("Retention: dropped page content of \(n) old job(s)")
            }
            cleanSpool()
            await sleep(600, key: "housekeeping")
        }
    }

    private func cleanSpool() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.spool, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(mod) > 86400 * 2 { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: User actions

    public func setPaused(_ paused: Bool) {
        config.paused = paused
        logInfo(paused ? "Printing paused by user (jobs keep queueing)" : "Printing resumed by user")
    }

    public func retry(_ jobId: String) {
        try? store.retry(jobId)
        logInfo("User retry: \(jobId)")
        kicks.insert("print"); refresh()
    }

    public func cancel(_ jobId: String) {
        guard let job = try? store.fetch(jobId) else { return }
        if job.state == .submitted, let printer = job.printer, let id = job.cupsJobId {
            PrinterService.cancel(printer: printer, id: id)
        }
        if !job.state.isTerminal {
            try? store.finish(jobId, printed: false, reason: "cancelled by user", cancelled: true)
            logInfo("User cancelled \(jobId)")
        }
        kicks.insert("ack"); refresh()
    }

    public func reprint(_ jobId: String) {
        if let newId = try? store.reprint(jobId) {
            logInfo("User reprint of \(jobId) queued as \(newId) (duplicate protection bypassed on purpose)")
        }
        kicks.insert("print"); refresh()
    }

    public func discardQueued() {
        let ids = (try? store.discardQueued()) ?? []
        logWarn("User discarded \(ids.count) queued job(s)")
        kicks.insert("ack"); refresh()
    }

    @discardableResult
    public func printTestPage() -> String {
        let id = "local-test-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        let printerName = (try? PrinterService.resolve(config.printerName))?.displayName ?? "default printer"
        let html = TestPage.html(deviceName: config.deviceName, printer: printerName, jobId: id)
        _ = try? store.enqueueLocal(jobId: id, html: html, headline: "TEST PAGE", eventType: "test",
                                    paperSize: config.paper == .job ? "letter" : config.paper.rawValue)
        logInfo("Test page queued as \(id)")
        kicks.insert("print"); refresh()
        return id
    }

    // MARK: Status

    public func refreshPrinters() {
        let list = PrinterService.listPrinters()
        if list != printers { printers = list }
        let resolved = try? PrinterService.resolve(config.printerName)
        let before = status.printer?.hasProblem ?? false
        status.printer = resolved
        if let p = resolved {
            status.printerError = p.hasProblem ? p.statusText : nil
            if before && !p.hasProblem { lastPrinterProblem = nil; onEvent?(.printerRecovered(p.displayName)) }
            if !before && p.hasProblem { reportPrinterProblem("\(p.displayName): \(p.statusText)") }
        } else {
            status.printerError = config.printerName.map { "Printer '\($0)' not found" } ?? "No default printer"
        }
    }

    public func refresh() {
        if let c = try? store.counts() { status.counts = c }
        jobs = (try? store.list(limit: 300)) ?? []
        status.lastReceived = try? store.latest(where: "origin = 'server'", order: "received_at")
        status.lastPrinted = try? store.latest(where: "state = 'printed'", order: "finished_at")
        status.overall = computeOverall()
    }

    private func computeOverall() -> OverallState {
        if credentials == nil || config.normalizedServer.isEmpty { return .configurationNeeded }
        if status.printer == nil { return .configurationNeeded }
        if case .unauthorized = status.connection { return .error }
        if config.paused { return .paused }
        if status.printer?.hasProblem == true { return .printerOffline }
        if case .offline = status.connection { return .disconnected }
        if status.counts.printing > 0 { return .printing }
        if status.counts.queued > 0 { return .jobsQueued }
        return .ready
    }

    public func diagnosticsText() -> String {
        let f = ISO8601DateFormatter()
        func d(_ x: Date?) -> String { x.map { f.string(from: $0) } ?? "never" }
        let s = status
        var lines = [
            "GamePrint Companion \(AppInfo.version)",
            "Generated: \(f.string(from: Date()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(s.overall.rawValue)",
            "Server: \(config.normalizedServer.isEmpty ? "unset" : config.normalizedServer)",
            "Device ID: \(credentials?.deviceId ?? "not paired")",
            "Device name: \(config.deviceName)",
            "Connection: \(s.connection.label)",
            "Last heartbeat: \(d(s.lastHeartbeat))",
            "Last successful API call: \(d(s.lastAPISuccess))",
            "Last API error: \(s.lastAPIError ?? "none")",
            "Server queue (last heartbeat): \(s.serverQueued)",
            "Printer: \(s.printer.map { "\($0.displayName) [\($0.name)] \($0.statusText)" } ?? "none (\(s.printerError ?? ""))")",
            "Paper: \(config.paper.rawValue), \(config.orientation.rawValue), \(config.scaling.rawValue), \(config.colorMode.rawValue), copies \(config.copies), duplex \(config.duplex ? "on" : "off")",
            "Paused: \(config.paused)",
            "Queue: queued \(s.counts.queued), printing \(s.counts.printing), printed \(s.counts.printed), failed \(s.counts.failed), cancelled \(s.counts.cancelled), acks pending \(s.counts.acksPending), duplicates blocked \(s.counts.duplicates)",
            "Last received: \(s.lastReceived.map { "\($0.jobId) at \(d($0.receivedAt))" } ?? "none")",
            "Last printed: \(s.lastPrinted.map { "\($0.jobId) at \(d($0.finishedAt))" } ?? "none")",
            "Uptime: \(Int(Date().timeIntervalSince(s.startedAt)))s since \(d(s.startedAt))",
        ]
        lines.append("Installed printers:")
        for p in printers { lines.append("  - \(p.displayName) [\(p.name)]\(p.isDefault ? " (default)" : ""): \(p.statusText)") }
        return lines.joined(separator: "\n")
    }
}
