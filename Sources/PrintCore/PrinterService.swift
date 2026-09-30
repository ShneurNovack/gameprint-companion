import Foundation
import CCups

public struct PrinterInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String            // CUPS queue name
    public var displayName: String     // printer-info (what System Settings shows)
    public var isDefault: Bool
    public var state: PrinterState
    public var reasons: [String]
    public var acceptingJobs: Bool
    public var makeModel: String
    public var location: String

    public var statusText: String {
        var s = state.label
        let r = reasons.filter { $0 != "none" }
        if !r.isEmpty { s += " (" + r.joined(separator: ", ") + ")" }
        if !acceptingJobs { s += ", not accepting jobs" }
        return s
    }

    /// Anything that would stop paper coming out.
    public var hasProblem: Bool {
        state == .stopped || !acceptingJobs || reasons.contains { r in
            r.hasSuffix("-error") || r.contains("offline") || r.contains("media-empty") ||
            r.contains("media-jam") || r.contains("toner-empty") || r.contains("door-open") ||
            r.contains("paused")
        }
    }
}

public enum PrinterState: String, Sendable {
    case idle, printing, stopped, unknown
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .printing: return "Printing"
        case .stopped: return "Paused/Stopped"
        case .unknown: return "Unknown"
        }
    }
}

/// Status of one CUPS job, from cupsGetJobs2.
public enum CupsJobStatus: Sendable, Equatable {
    case pending, held, processing, stopped, cancelled, aborted, completed
    init(_ raw: UInt32) {
        switch raw {
        case 3: self = .pending
        case 4: self = .held
        case 5: self = .processing
        case 6: self = .stopped
        case 7: self = .cancelled
        case 8: self = .aborted
        case 9: self = .completed
        default: self = .pending
        }
    }
}

public struct CupsJob: Sendable {
    public let id: Int
    public let title: String
    public let status: CupsJobStatus
    public let completedAt: Date?
}

public struct SubmitOptions: Sendable {
    public var media: String          // "Letter", "A4", "Legal"
    public var orientation: Orientation
    public var scaling: Scaling
    public var colorMode: ColorMode
    public var copies: Int
    public var duplex: Bool
}

public enum PrinterError: Error, LocalizedError {
    case noPrinter
    case printerNotFound(String)
    case submitFailed(String)
    public var errorDescription: String? {
        switch self {
        case .noPrinter: return "No printer configured and macOS has no default printer"
        case .printerNotFound(let n): return "Printer '\(n)' is not installed on this Mac"
        case .submitFailed(let m): return "macOS print system refused the job: \(m)"
        }
    }
}

/// Thin layer over the macOS print system (CUPS). No print dialogs are ever
/// involved: jobs go straight to the spooler, which is the same path the
/// Print dialog ends in.
public enum PrinterService {
    private static let lock = NSLock()

    public static func listPrinters() -> [PrinterInfo] {
        lock.lock(); defer { lock.unlock() }
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests(&dests)
        defer { cupsFreeDests(count, dests) }
        guard let dests, count > 0 else { return [] }
        var result: [PrinterInfo] = []
        for i in 0..<Int(count) {
            let d = dests[i]
            if d.instance != nil { continue }
            let name = String(cString: d.name)
            func opt(_ key: String) -> String? {
                guard let p = cupsGetOption(key, d.num_options, d.options) else { return nil }
                return String(cString: p)
            }
            let stateRaw = Int(opt("printer-state") ?? "") ?? 0
            let state: PrinterState = stateRaw == 3 ? .idle : stateRaw == 4 ? .printing : stateRaw == 5 ? .stopped : .unknown
            let reasons = (opt("printer-state-reasons") ?? "none").split(separator: ",").map { String($0) }
            result.append(PrinterInfo(
                name: name,
                displayName: opt("printer-info") ?? name,
                isDefault: d.is_default != 0,
                state: state,
                reasons: reasons,
                acceptingJobs: (opt("printer-is-accepting-jobs") ?? "true") != "false",
                makeModel: opt("printer-make-and-model") ?? "",
                location: opt("printer-location") ?? ""
            ))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func defaultPrinterName() -> String? {
        listPrinters().first(where: { $0.isDefault })?.name
    }

    public static func info(for name: String) -> PrinterInfo? {
        listPrinters().first { $0.name == name }
    }

    /// Resolve the configured printer (nil means "macOS default").
    public static func resolve(_ configured: String?) throws -> PrinterInfo {
        let all = listPrinters()
        if let configured {
            guard let p = all.first(where: { $0.name == configured }) else { throw PrinterError.printerNotFound(configured) }
            return p
        }
        guard let p = all.first(where: { $0.isDefault }) else { throw PrinterError.noPrinter }
        return p
    }

    /// Paper sizes the driver advertises (from its PPD), e.g. ["Letter","A4"].
    public static func paperSizes(for name: String) -> [String] {
        let out = run("/usr/bin/lpoptions", ["-p", name, "-l"])
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("PageSize") || $0.hasPrefix("media") }) else { return [] }
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...].split(separator: " ").map {
            String($0).replacingOccurrences(of: "*", with: "")
        }
    }

    /// Hand a PDF to CUPS. Returns the CUPS job id (> 0) on acceptance.
    public static func submit(pdf: URL, printer: String, title: String, options o: SubmitOptions) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var num: Int32 = 0
        var opts: UnsafeMutablePointer<cups_option_t>?
        func add(_ k: String, _ v: String) { num = cupsAddOption(k, v, num, &opts) }
        add("media", o.media)
        add("PageSize", o.media)
        add("orientation-requested", o.orientation == .portrait ? "3" : "4")
        add("print-scaling", o.scaling == .actual ? "none" : "fit")
        if o.scaling == .fit { add("fit-to-page", "true") }
        add("print-color-mode", o.colorMode == .monochrome ? "monochrome" : "color")
        if o.colorMode == .monochrome { add("ColorModel", "Gray") }
        add("sides", o.duplex ? "two-sided-long-edge" : "one-sided")
        add("Duplex", o.duplex ? "DuplexNoTumble" : "None")
        add("copies", String(max(1, min(o.copies, 99))))
        add("job-hold-until", "no-hold")
        defer { cupsFreeOptions(num, opts) }
        let id = cupsPrintFile2(nil, printer, pdf.path, title, num, opts)
        if id <= 0 {
            throw PrinterError.submitFailed(String(cString: cupsLastErrorString()))
        }
        return Int(id)
    }

    /// Jobs (all states, this user) on a queue.
    public static func jobs(printer: String) -> [CupsJob] {
        lock.lock(); defer { lock.unlock() }
        var jobs: UnsafeMutablePointer<cups_job_t>?
        let n = cupsGetJobs2(nil, &jobs, printer, 1, -1)
        defer { cupsFreeJobs(n, jobs) }
        guard let jobs, n > 0 else { return [] }
        return (0..<Int(n)).map { i in
            let j = jobs[i]
            let completed = j.completed_time > 0 ? Date(timeIntervalSince1970: TimeInterval(j.completed_time)) : nil
            return CupsJob(id: Int(j.id), title: j.title.map { String(cString: $0) } ?? "",
                           status: CupsJobStatus(UInt32(j.state.rawValue)), completedAt: completed)
        }
    }

    public static func job(printer: String, id: Int) -> CupsJob? {
        jobs(printer: printer).first { $0.id == id }
    }

    public static func findJob(printer: String, title: String) -> CupsJob? {
        jobs(printer: printer).filter { $0.title == title }.max { $0.id < $1.id }
    }

    @discardableResult
    public static func cancel(printer: String, id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cupsCancelJob2(nil, printer, Int32(id), 0).rawValue == 0
    }

    /// Try to resume a queue macOS paused after an error. Works when the user
    /// is allowed to administer printers; failures are only logged.
    @discardableResult
    public static func resumeQueue(_ printer: String) -> Bool {
        let out = run("/usr/sbin/cupsenable", [printer], captureStatus: true)
        let ok = out.hasPrefix("exit:0")
        logInfo("cupsenable \(printer): \(ok ? "ok" : out)")
        return ok
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], captureStatus: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "exit:-1 \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return captureStatus ? "exit:\(p.terminationStatus) \(text)" : text
    }
}
