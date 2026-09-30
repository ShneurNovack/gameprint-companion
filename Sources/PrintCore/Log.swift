import Foundation
import os

/// Filesystem locations. `GP_HOME` overrides the root so tests and a second
/// instance can run against an isolated sandbox.
public enum AppPaths {
    public static var root: URL = {
        if let custom = ProcessInfo.processInfo.environment["GP_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GamePrintCompanion", isDirectory: true)
    }()

    public static var database: URL { root.appendingPathComponent("jobs.sqlite") }
    public static var config: URL { root.appendingPathComponent("config.json") }
    public static var spool: URL { root.appendingPathComponent("spool", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    public static func ensure() {
        for dir in [root, spool, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum LogLevel: String {
    case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
}

/// Rotating file logger. Everything written passes through `scrub`, which
/// removes any registered secret (the auth token) before it touches disk.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "com.gameprint.companion.log")
    private let osLog = Logger(subsystem: "com.gameprint.companion", category: "companion")
    private let maxBytes: UInt64 = 2_000_000
    private let keepFiles = 5
    private var handle: FileHandle?
    private var secrets: [String] = []
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    public var echoToStdout = false

    public var currentFile: URL { AppPaths.logs.appendingPathComponent("companion.log") }

    private init() {}

    public func registerSecret(_ secret: String) {
        guard secret.count >= 6 else { return }
        queue.sync { if !secrets.contains(secret) { secrets.append(secret) } }
    }

    public func clearSecrets() { queue.sync { secrets.removeAll() } }

    public func write(_ level: LogLevel, _ message: String) {
        queue.async { [self] in
            var line = message
            for s in secrets { line = line.replacingOccurrences(of: s, with: "[REDACTED]") }
            let text = "\(stamp.string(from: Date())) [\(level.rawValue)] \(line)\n"
            switch level {
            case .error: osLog.error("\(line, privacy: .public)")
            case .warn: osLog.warning("\(line, privacy: .public)")
            default: osLog.info("\(line, privacy: .public)")
            }
            if echoToStdout { FileHandle.standardOutput.write(text.data(using: .utf8)!) }
            append(text)
        }
    }

    public func flush() { queue.sync { try? handle?.synchronize() } }

    private func append(_ text: String) {
        AppPaths.ensure()
        if handle == nil {
            if !FileManager.default.fileExists(atPath: currentFile.path) {
                FileManager.default.createFile(atPath: currentFile.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: currentFile)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle, let data = text.data(using: .utf8) else { return }
        h.write(data)
        if let size = try? h.offset(), size > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let base = currentFile.path
        try? fm.removeItem(atPath: "\(base).\(keepFiles)")
        for i in stride(from: keepFiles - 1, through: 1, by: -1) {
            if fm.fileExists(atPath: "\(base).\(i)") {
                try? fm.moveItem(atPath: "\(base).\(i)", toPath: "\(base).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
    }
}

public func logDebug(_ m: String) { Log.shared.write(.debug, m) }
public func logInfo(_ m: String) { Log.shared.write(.info, m) }
public func logWarn(_ m: String) { Log.shared.write(.warn, m) }
public func logError(_ m: String) { Log.shared.write(.error, m) }
