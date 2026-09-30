import AppKit
import Network
import PrintCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct GamePrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() { CommandLineTools.handleIfNeeded() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: delegate.engine, delegate: delegate)
        } label: {
            MenuBarLabel(engine: delegate.engine)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var engine: PrintEngine
    var body: some View {
        let s = engine.status.overall
        if s == .ready {
            Image(systemName: s.symbol)
        } else {
            HStack(spacing: 3) {
                Image(systemName: s.symbol)
                if engine.status.counts.queued + engine.status.counts.printing > 0 {
                    Text("\(engine.status.counts.queued + engine.status.counts.printing)")
                }
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate

    var body: some View {
        let s = engine.status
        Text("GamePrint Companion")
        Divider()
        Text("Status: \(s.overall.rawValue)")
        Text(s.connection.label)
        Text("Printer: \(s.printer?.displayName ?? "none")\(s.printer?.hasProblem == true ? " (\(s.printer!.statusText))" : "")")
        Text("Queue: \(s.counts.queued) waiting, \(s.counts.printing) printing")
        if let last = s.lastPrinted {
            Text("Last printed: \(last.headline.isEmpty ? last.eventType : last.headline) at \(last.finishedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "")")
        }
        Divider()
        Button("Open Dashboard") { delegate.showDashboard(.status) }
        Button("Print Test Page") { engine.printTestPage() }
        Button(engine.config.paused ? "Resume Printing" : "Pause Printing") { engine.setPaused(!engine.config.paused) }
        Button("Settings…") { delegate.showDashboard(.printer) }
        Button("Diagnostics") { delegate.showDashboard(.diagnostics) }
        Divider()
        Button("Quit GamePrint Companion") { delegate.quit() }
            .keyboardShortcut("q")
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case setup = "Setup", status = "Status", queue = "Queue", printer = "Printer",
         general = "General", account = "Account", advanced = "Advanced", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .setup: return "wand.and.stars"
        case .status: return "gauge"
        case .queue: return "list.bullet.rectangle"
        case .printer: return "printer"
        case .general: return "gearshape"
        case .account: return "person.crop.circle"
        case .advanced: return "slider.horizontal.3"
        case .diagnostics: return "stethoscope"
        }
    }
}

final class UIState: ObservableObject {
    @Published var tab: DashboardTab = .status
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let engine: PrintEngine
    let ui = UIState()
    let loginItem = LoginItem()
    private var window: NSWindow?
    private var pathMonitor: NWPathMonitor?
    private var activity: NSObjectProtocol?
    private var sleepActivity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    override init() {
        do {
            engine = try PrintEngine()
        } catch {
            let alert = NSAlert()
            alert.messageText = "GamePrint Companion could not open its job database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only one copy may print: a second instance would double-print.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleId = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { $0.processIdentifier != me }
            if !others.isEmpty {
                logWarn("Another instance is already running (pid \(others.map(\.processIdentifier))); exiting")
                exit(0)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Timers must keep firing on schedule while the app sits in the
        // background: opt out of App Nap for the life of the process.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Printing live game updates unattended")
        applyKeepAwake()

        UNUserNotificationCenter.current().delegate = self
        engine.onEvent = { [weak self] e in self?.handle(e) }
        engine.start()
        observeSystem()

        if !engine.config.setupComplete || engine.status.overall == .configurationNeeded || !engine.config.menuBarOnly {
            showDashboard(engine.config.setupComplete ? .status : .setup)
        }
        loginItem.refresh()
        logInfo("Launched. Login item: \(loginItem.statusText)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        logInfo("Quitting")
        engine.stop()
    }

    func quit() {
        let pending = engine.status.counts.queued + engine.status.counts.printing
        if pending > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit GamePrint Companion?"
            alert.informativeText = "\(pending) job(s) are waiting. They stay saved and will print when the app starts again, but nothing prints while it is closed."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Keep Running")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }

    func applyKeepAwake() {
        if engine.config.keepAwake, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                  reason: "Keep the Mac awake to print game updates")
        } else if !engine.config.keepAwake, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                logInfo("System woke from sleep; reconnecting")
                self?.engine.kickAll()
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            logInfo("System going to sleep")
            Log.shared.flush()
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                logInfo("Network path changed: \(path.status == .satisfied ? "online" : "offline")")
                if path.status == .satisfied { self?.engine.kickAll() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "gp.netmonitor"))
        pathMonitor = monitor
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            logInfo("Notification permission \(granted ? "granted" : "denied")")
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard engine.config.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func handle(_ e: EngineEvent) {
        switch e {
        case .failed(let job, let why): notify("Print job failed", "\(job.headline.isEmpty ? job.jobId : job.headline): \(why)")
        case .printerProblem(let m): notify("Printer needs attention", m)
        case .printerRecovered(let p): notify("Printer back online", "\(p) is ready; queued pages will print.")
        case .connectionLost(let m): notify("Lost connection to GamePrint", "Jobs will be fetched when it returns. \(m)")
        case .connectionRestored: break
        case .credentialsRejected: notify("GamePrint rejected this Mac", "Re-pair it from the Companion page in the web app.")
        case .printed: break
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Window

    func showDashboard(_ tab: DashboardTab) {
        ui.tab = tab
        if window == nil {
            let view = DashboardView(engine: engine, delegate: self, ui: ui)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "GamePrint Companion"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("GamePrintDashboard")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Logs

    func exportDiagnostics() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "GamePrint-Diagnostics-\(stamp).zip"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Log.shared.flush()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? engine.diagnosticsText().write(to: tmp.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        let jobs = engine.jobs.map { "\($0.seq)\t\($0.state.rawValue)\t\($0.jobId)\t\($0.gameKey)\t\($0.lastError ?? "")" }
        try? jobs.joined(separator: "\n").write(to: tmp.appendingPathComponent("jobs.tsv"), atomically: true, encoding: .utf8)
        try? FileManager.default.copyItem(at: AppPaths.logs, to: tmp.appendingPathComponent("Logs"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", tmp.path, dest.path]
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}

/// Launch at login + relaunch after a crash, via a LaunchAgent bundled in the
/// app (KeepAlive only when the exit was not clean, so Quit stays quit).
@MainActor
final class LoginItem: ObservableObject {
    static let agentPlist = "com.gameprint.companion.agent.plist"
    @Published var status: SMAppService.Status = .notRegistered
    private var service: SMAppService { SMAppService.agent(plistName: LoginItem.agentPlist) }

    var isEnabled: Bool { status == .enabled }
    var statusText: String {
        switch status {
        case .enabled: return "Enabled (starts at login, restarts after a crash)"
        case .requiresApproval: return "Needs approval in System Settings > General > Login Items"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable (app must run from its .app bundle)"
        @unknown default: return "Unknown"
        }
    }

    func refresh() { status = service.status }

    func set(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            logInfo("Launch at login \(on ? "enabled" : "disabled")")
        } catch {
            logError("Launch at login change failed: \(error.localizedDescription)")
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// `GamePrint Companion --pair <server> <deviceId> <token>` etc., for
/// scripted setup. Runs before any UI and exits.
enum CommandLineTools {
    static func handleIfNeeded() {
        let a = CommandLine.arguments
        guard a.count >= 2, a[1].hasPrefix("--") else { return }
        switch a[1] {
        case "--pair" where a.count >= 5:
            var cfg = CompanionConfig.load()
            cfg.serverURL = a[2]
            cfg.save()
            do {
                try CredentialStore.save(Credentials(deviceId: a[3], authToken: a[4]))
                print("Saved credentials for device \(a[3]) and server \(cfg.normalizedServer)")
                exit(0)
            } catch {
                print("Failed: \(error.localizedDescription)"); exit(1)
            }
        case "--unpair":
            CredentialStore.delete(); print("Credentials removed"); exit(0)
        case "--login-item" where a.count >= 3:
            let svc = SMAppService.agent(plistName: LoginItem.agentPlist)
            do {
                if a[2] == "on" { try svc.register() }
                if a[2] == "off" { try svc.unregister() }
            } catch {
                print("Failed: \(error.localizedDescription)")
            }
            print("login item status: \(svc.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
            exit(0)
        case "--version":
            print(AppInfo.version); exit(0)
        default:
            return
        }
    }
}
