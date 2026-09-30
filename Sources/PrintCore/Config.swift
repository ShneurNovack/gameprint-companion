import Foundation

public enum PaperChoice: String, Codable, CaseIterable, Sendable {
    case job, letter, a4, legal
    public var label: String {
        switch self {
        case .job: return "Use job's size (Letter/A4)"
        case .letter: return "US Letter"
        case .a4: return "A4"
        case .legal: return "US Legal"
        }
    }
}

public enum Orientation: String, Codable, CaseIterable, Sendable { case portrait, landscape }
public enum Scaling: String, Codable, CaseIterable, Sendable {
    case actual, fit
    public var label: String { self == .actual ? "Actual size (100%)" : "Fit to page" }
}
public enum ColorMode: String, Codable, CaseIterable, Sendable {
    case monochrome, color
    public var label: String { self == .monochrome ? "Grayscale" : "Color" }
}

/// Non-secret configuration, stored as JSON next to the database.
public struct CompanionConfig: Codable, Equatable, Sendable {
    public var serverURL: String = "https://game-print-live.base44.app"
    public var deviceName: String = Host.current().localizedName ?? "Mac"
    public var printerName: String? = nil          // nil = macOS default printer
    public var paper: PaperChoice = .job
    public var orientation: Orientation = .portrait
    public var scaling: Scaling = .actual
    public var colorMode: ColorMode = .monochrome
    public var copies: Int = 1
    public var duplex: Bool = false
    public var paused: Bool = false
    public var notifications: Bool = true
    public var retentionDays: Int = 14
    /// 0 = always print, even after a long outage. Otherwise jobs that have
    /// waited longer than this many minutes locally are marked expired.
    public var maxQueueAgeMinutes: Int = 0
    public var autoResumePrinterQueue: Bool = true
    public var maxAutoRetries: Int = 5
    public var pollInterval: Double = 5
    public var heartbeatInterval: Double = 15
    public var setupComplete: Bool = false
    public var menuBarOnly: Bool = true
    /// Hold a no-idle-sleep assertion so the Mac stays awake for games.
    public var keepAwake: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding so new fields never break an existing install.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionConfig()
        serverURL = (try? c.decode(String.self, forKey: .serverURL)) ?? d.serverURL
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? d.deviceName
        printerName = try? c.decodeIfPresent(String.self, forKey: .printerName)
        paper = (try? c.decode(PaperChoice.self, forKey: .paper)) ?? d.paper
        orientation = (try? c.decode(Orientation.self, forKey: .orientation)) ?? d.orientation
        scaling = (try? c.decode(Scaling.self, forKey: .scaling)) ?? d.scaling
        colorMode = (try? c.decode(ColorMode.self, forKey: .colorMode)) ?? d.colorMode
        copies = (try? c.decode(Int.self, forKey: .copies)) ?? d.copies
        duplex = (try? c.decode(Bool.self, forKey: .duplex)) ?? d.duplex
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? d.paused
        notifications = (try? c.decode(Bool.self, forKey: .notifications)) ?? d.notifications
        retentionDays = (try? c.decode(Int.self, forKey: .retentionDays)) ?? d.retentionDays
        maxQueueAgeMinutes = (try? c.decode(Int.self, forKey: .maxQueueAgeMinutes)) ?? d.maxQueueAgeMinutes
        autoResumePrinterQueue = (try? c.decode(Bool.self, forKey: .autoResumePrinterQueue)) ?? d.autoResumePrinterQueue
        maxAutoRetries = (try? c.decode(Int.self, forKey: .maxAutoRetries)) ?? d.maxAutoRetries
        pollInterval = (try? c.decode(Double.self, forKey: .pollInterval)) ?? d.pollInterval
        heartbeatInterval = (try? c.decode(Double.self, forKey: .heartbeatInterval)) ?? d.heartbeatInterval
        setupComplete = (try? c.decode(Bool.self, forKey: .setupComplete)) ?? d.setupComplete
        menuBarOnly = (try? c.decode(Bool.self, forKey: .menuBarOnly)) ?? d.menuBarOnly
        keepAwake = (try? c.decode(Bool.self, forKey: .keepAwake)) ?? d.keepAwake
    }

    public static func load() -> CompanionConfig {
        guard let data = try? Data(contentsOf: AppPaths.config),
              let cfg = try? JSONDecoder().decode(CompanionConfig.self, from: data) else {
            return CompanionConfig()
        }
        return cfg
    }

    public func save() {
        AppPaths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: AppPaths.config, options: .atomic)
        }
    }

    /// Normalised base, e.g. "https://app.example.com" (no trailing slash,
    /// no "/functions").
    public var normalizedServer: String {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/functions") { s.removeLast("/functions".count) }
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        return s
    }
}
