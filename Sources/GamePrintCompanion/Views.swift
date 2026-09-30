import AppKit
import PrintCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate
    @ObservedObject var ui: UIState

    var body: some View {
        NavigationSplitView {
            List(DashboardTab.allCases, selection: Binding(get: { ui.tab }, set: { if let t = $0 { ui.tab = t } })) { tab in
                Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch ui.tab {
                case .setup: SetupView(engine: engine, delegate: delegate, ui: ui)
                case .status: StatusView(engine: engine)
                case .queue: QueueView(engine: engine)
                case .printer: PrinterView(engine: engine)
                case .general: GeneralView(engine: engine, delegate: delegate, login: delegate.loginItem)
                case .account: AccountView(engine: engine, ui: ui)
                case .advanced: AdvancedView(engine: engine, delegate: delegate)
                case .diagnostics: DiagnosticsView(engine: engine, delegate: delegate, login: delegate.loginItem)
                }
            }
            .frame(minWidth: 620, minHeight: 520)
        }
    }
}

// MARK: - Helpers

func timeString(_ d: Date?) -> String {
    guard let d else { return "never" }
    return DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .medium)
}

func agoString(_ d: Date?) -> String {
    guard let d else { return "never" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h \((s % 3600) / 60)m ago"
}

struct StatusBadge: View {
    let state: OverallState
    var color: Color {
        switch state {
        case .ready: return .green
        case .printing, .jobsQueued: return .blue
        case .paused: return .orange
        case .printerOffline, .disconnected: return .orange
        case .configurationNeeded: return .gray
        case .error: return .red
        }
    }
    var body: some View {
        Label(state.rawValue, systemImage: state.symbol)
            .font(.headline)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Setup

struct SetupView: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate
    @ObservedObject var ui: UIState
    @State private var server = ""
    @State private var deviceId = ""
    @State private var token = ""
    @State private var busy = false
    @State private var pairError: String?
    @State private var testJob: String?

    var paired: Bool { engine.credentials != nil }

    var body: some View {
        Form {
            Section("1. Connect to your GamePrint account") {
                Text("On the GamePrint web app, open the Companion page and click Pair a companion. Copy the Device ID and Auth token here.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Server URL", text: $server, prompt: Text("https://your-app.base44.app"))
                TextField("Device ID", text: $deviceId)
                SecureField("Auth token", text: $token)
                HStack {
                    Button(paired ? "Re-connect" : "Connect") { connect() }
                        .disabled(busy || server.isEmpty || deviceId.isEmpty || token.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                    if paired { Label("Connected as \(engine.credentials!.deviceId)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let pairError { Text(pairError).foregroundStyle(.red).font(.callout) }
            }
            Section("2. Name this Mac") {
                TextField("Device name", text: Binding(get: { engine.config.deviceName }, set: { engine.config.deviceName = $0 }),
                          prompt: Text("Living Room Mac"))
            }
            Section("3. Printer and paper") {
                PrinterPicker(engine: engine)
                PaperSettings(engine: engine)
            }
            Section("4. Test page") {
                HStack {
                    Button("Print Test Page") { testJob = engine.printTestPage() }
                    if let testJob, let rec = engine.jobs.first(where: { $0.jobId == testJob }) {
                        Text(rec.state.label).foregroundStyle(rec.state == .printed ? .green : rec.state == .failed ? .red : .secondary)
                    }
                }
            }
            Section("5. Run unattended") {
                Toggle("Launch at login (and restart automatically after a crash)",
                       isOn: Binding(get: { delegate.loginItem.isEnabled }, set: { delegate.loginItem.set($0) }))
                Toggle("Keep this Mac awake while the app runs",
                       isOn: Binding(get: { engine.config.keepAwake }, set: { engine.config.keepAwake = $0; delegate.applyKeepAwake() }))
                Text(delegate.loginItem.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    StatusBadge(state: engine.status.overall)
                    Spacer()
                    Button("Finish") {
                        engine.config.setupComplete = true
                        if engine.config.notifications { delegate.requestNotificationPermission() }
                        ui.tab = .status
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!paired || engine.status.printer == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            server = engine.config.serverURL
            deviceId = engine.credentials?.deviceId ?? ""
            token = engine.credentials?.authToken ?? ""
        }
    }

    private func connect() {
        busy = true; pairError = nil
        Task {
            do {
                try await engine.pair(server: server, deviceId: deviceId, token: token)
            } catch {
                pairError = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Status

struct StatusView: View {
    @ObservedObject var engine: PrintEngine

    var body: some View {
        let s = engine.status
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    StatusBadge(state: s.overall)
                    Spacer()
                    Button(engine.config.paused ? "Resume Printing" : "Pause Printing") { engine.setPaused(!engine.config.paused) }
                    Button("Print Test Page") { engine.printTestPage() }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Connection", s.connection.label)
                    row("Last heartbeat", agoString(s.lastHeartbeat))
                    row("Printer", s.printer.map { "\($0.displayName): \($0.statusText)" } ?? (s.printerError ?? "none"))
                    row("Waiting", "\(s.counts.queued)")
                    row("Printing now", "\(s.counts.printing)")
                    row("Printed", "\(s.counts.printed)")
                    row("Failed", "\(s.counts.failed)")
                    row("Acks pending", "\(s.counts.acksPending)")
                    row("Duplicates blocked", "\(s.counts.duplicates)")
                    row("Last received", s.lastReceived.map { "\($0.headline) (\(agoString($0.receivedAt)))" } ?? "none")
                    row("Last printed", s.lastPrinted.map { "\($0.headline) (\(agoString($0.finishedAt)))" } ?? "none")
                }
                if let err = s.lastAPIError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                Text("Recent jobs").font(.headline)
                JobTable(engine: engine, jobs: Array(engine.jobs.prefix(12)))
                    .frame(minHeight: 260)
            }
            .padding()
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @ObservedObject var engine: PrintEngine
    @State private var filter = "Pending"
    @State private var confirmDiscard = false

    var filtered: [PrintJobRecord] {
        switch filter {
        case "Pending": return engine.jobs.filter { !$0.state.isTerminal }
        case "Completed": return engine.jobs.filter { $0.state == .printed }
        case "Failed": return engine.jobs.filter { $0.state == .failed || $0.state == .cancelled }
        default: return engine.jobs
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(["Pending", "Completed", "Failed", "All"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 380)
                Spacer()
                Button(engine.config.paused ? "Resume" : "Pause") { engine.setPaused(!engine.config.paused) }
                Button("Discard Queued…", role: .destructive) { confirmDiscard = true }
                    .disabled(engine.status.counts.queued == 0)
            }
            JobTable(engine: engine, jobs: filtered)
        }
        .padding()
        .confirmationDialog("Discard \(engine.status.counts.queued) queued job(s)?", isPresented: $confirmDiscard) {
            Button("Discard queued jobs", role: .destructive) { engine.discardQueued() }
        } message: {
            Text("They will not print and will be reported to the server as cancelled. This cannot be undone.")
        }
    }
}

struct JobTable: View {
    @ObservedObject var engine: PrintEngine
    let jobs: [PrintJobRecord]

    var body: some View {
        Table(jobs) {
            TableColumn("Received") { Text(timeString($0.receivedAt)).font(.caption) }.width(min: 120, ideal: 140)
            TableColumn("Event") { j in
                VStack(alignment: .leading) {
                    Text(j.headline.isEmpty ? j.eventType : j.headline).bold()
                    Text(j.jobId).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.width(min: 180, ideal: 260)
            TableColumn("Status") { j in
                VStack(alignment: .leading) {
                    Text(j.state.label).foregroundStyle(color(j.state))
                    if let e = j.lastError, !j.state.isTerminal || j.state == .failed {
                        Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    } else if let d = j.detail {
                        Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.width(min: 160, ideal: 220)
            TableColumn("") { j in
                HStack(spacing: 6) {
                    if j.state == .failed || j.state == .cancelled { Button("Retry") { engine.retry(j.jobId) } }
                    if !j.state.isTerminal { Button("Cancel") { engine.cancel(j.jobId) } }
                    if j.state.isTerminal { Button("Reprint") { engine.reprint(j.jobId) } }
                }
                .controlSize(.small)
            }.width(min: 120, ideal: 140)
        }
    }

    func color(_ s: JobState) -> Color {
        switch s {
        case .printed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .queued, .received: return .primary
        default: return .blue
        }
    }
}

// MARK: - Printer

struct PrinterPicker: View {
    @ObservedObject var engine: PrintEngine
    var body: some View {
        Picker("Printer", selection: Binding(get: { engine.config.printerName ?? "" },
                                             set: { engine.config.printerName = $0.isEmpty ? nil : $0 })) {
            let def = engine.printers.first(where: { $0.isDefault })
            Text("macOS default\(def.map { " (\($0.displayName))" } ?? "")").tag("")
            ForEach(engine.printers) { p in
                Text("\(p.displayName)\(p.isDefault ? " (default)" : "") - \(p.statusText)").tag(p.name)
            }
        }
        Button("Refresh printer list") { engine.refreshPrinters() }.controlSize(.small)
        if let p = engine.status.printer {
            let sizes = PrinterService.paperSizes(for: p.name)
            Text("\(p.makeModel)\(sizes.isEmpty ? "" : " · Paper: " + sizes.prefix(8).joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
        } else if let e = engine.status.printerError {
            Text(e).foregroundStyle(.red).font(.caption)
        }
    }
}

struct PaperSettings: View {
    @ObservedObject var engine: PrintEngine
    var body: some View {
        Picker("Paper size", selection: Binding(get: { engine.config.paper }, set: { engine.config.paper = $0 })) {
            ForEach(PaperChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Orientation", selection: Binding(get: { engine.config.orientation }, set: { engine.config.orientation = $0 })) {
            ForEach(Orientation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Picker("Scaling", selection: Binding(get: { engine.config.scaling }, set: { engine.config.scaling = $0 })) {
            ForEach(Scaling.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Color", selection: Binding(get: { engine.config.colorMode }, set: { engine.config.colorMode = $0 })) {
            ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Stepper("Copies: \(engine.config.copies)", value: Binding(get: { engine.config.copies }, set: { engine.config.copies = $0 }), in: 1...10)
        Toggle("Two-sided (duplex)", isOn: Binding(get: { engine.config.duplex }, set: { engine.config.duplex = $0 }))
        Text("Margins come from the page itself (0.5 in). Duplex stays off so every game event gets its own sheet.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct PrinterView: View {
    @ObservedObject var engine: PrintEngine
    var body: some View {
        Form {
            Section("Printer") { PrinterPicker(engine: engine) }
            Section("Paper") { PaperSettings(engine: engine) }
            Section {
                Toggle("Automatically resume the macOS print queue if it gets paused",
                       isOn: Binding(get: { engine.config.autoResumePrinterQueue }, set: { engine.config.autoResumePrinterQueue = $0 }))
                Button("Print Test Page") { engine.printTestPage() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralView: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate
    @ObservedObject var login: LoginItem

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login (restarts automatically after a crash)",
                       isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                Text(login.statusText).font(.caption).foregroundStyle(.secondary)
                TextField("Device name", text: Binding(get: { engine.config.deviceName }, set: { engine.config.deviceName = $0 }))
                Toggle("Start in the menu bar only (no window)",
                       isOn: Binding(get: { engine.config.menuBarOnly }, set: { engine.config.menuBarOnly = $0 }))
                Toggle("Notifications for failures and printer problems",
                       isOn: Binding(get: { engine.config.notifications },
                                     set: { engine.config.notifications = $0; if $0 { delegate.requestNotificationPermission() } }))
                Toggle("Keep this Mac awake while the app runs",
                       isOn: Binding(get: { engine.config.keepAwake }, set: { engine.config.keepAwake = $0; delegate.applyKeepAwake() }))
            }
            Section("Queue") {
                Stepper("Keep finished page content for \(engine.config.retentionDays) day(s)",
                        value: Binding(get: { engine.config.retentionDays }, set: { engine.config.retentionDays = $0 }), in: 1...90)
                Picker("After a long outage", selection: Binding(get: { engine.config.maxQueueAgeMinutes },
                                                                 set: { engine.config.maxQueueAgeMinutes = $0 })) {
                    Text("Print everything that was missed").tag(0)
                    Text("Skip pages older than 30 minutes").tag(30)
                    Text("Skip pages older than 2 hours").tag(120)
                    Text("Skip pages older than 12 hours").tag(720)
                }
                Stepper("Automatic retries for print system errors: \(engine.config.maxAutoRetries)",
                        value: Binding(get: { engine.config.maxAutoRetries }, set: { engine.config.maxAutoRetries = $0 }), in: 1...20)
                Text("Job IDs are remembered permanently, so a page can never print twice from a duplicate delivery. Use Reprint for a deliberate extra copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

// MARK: - Account

struct AccountView: View {
    @ObservedObject var engine: PrintEngine
    @ObservedObject var ui: UIState
    @State private var confirm = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Connection", value: engine.status.connection.label)
                LabeledContent("Server", value: engine.config.normalizedServer.isEmpty ? "not set" : engine.config.normalizedServer)
                LabeledContent("Device ID", value: engine.credentials?.deviceId ?? "not paired")
                LabeledContent("Credential storage", value: "macOS Keychain")
                LabeledContent("Last heartbeat", value: agoString(engine.status.lastHeartbeat))
            }
            Section {
                Button("Pair / change credentials…") { ui.tab = .setup }
                Button("Unpair this Mac…", role: .destructive) { confirm = true }.disabled(engine.credentials == nil)
                Text("To revoke this Mac from the web dashboard, pair a new companion there; the old token stops working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unpair this Mac?", isPresented: $confirm) {
            Button("Unpair", role: .destructive) { engine.unpair() }
        } message: {
            Text("The credentials are removed from the Keychain and no new jobs will be fetched.")
        }
    }
}

// MARK: - Advanced

struct AdvancedView: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate
    @State private var server = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("API / server URL", text: $server)
                HStack {
                    Button("Save") { engine.config.serverURL = server }.disabled(server == engine.config.serverURL)
                    Button("Reconnect now") { engine.kickAll() }
                }
                Stepper("Poll every \(Int(engine.config.pollInterval))s",
                        value: Binding(get: { engine.config.pollInterval }, set: { engine.config.pollInterval = $0 }), in: 2...60, step: 1)
            }
            Section("Maintenance") {
                Button("Clear cached page content of finished jobs…") { confirmClear = true }
                Button("Open data folder") { NSWorkspace.shared.open(AppPaths.root) }
                Button("Export Diagnostic Log…") { delegate.exportDiagnostics() }
                Text("Clearing the cache keeps job IDs, so duplicate protection is unaffected.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { server = engine.config.serverURL }
        .confirmationDialog("Clear cached content?", isPresented: $confirmClear) {
            Button("Clear") { _ = try? engine.store.clearHistory(); engine.refresh() }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject var engine: PrintEngine
    let delegate: AppDelegate
    @ObservedObject var login: LoginItem
    @State private var logTail = ""
    @State private var now = Date()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(state: engine.status.overall)
                Spacer()
                Button("Export Diagnostic Log…") { delegate.exportDiagnostics() }
            }
            ScrollView {
                Text(engine.diagnosticsText() + "\nLaunch at login: \(login.statusText)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Text("Recent log").font(.headline)
            ScrollView {
                Text(logTail).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onAppear { load(); login.refresh() }
        .onReceive(timer) { _ in now = Date(); load() }
    }

    private func load() {
        Log.shared.flush()
        guard let data = try? Data(contentsOf: Log.shared.currentFile) else { return }
        let text = String(decoding: data.suffix(40_000), as: UTF8.self)
        logTail = text.split(separator: "\n").suffix(150).reversed().joined(separator: "\n")
    }
}
