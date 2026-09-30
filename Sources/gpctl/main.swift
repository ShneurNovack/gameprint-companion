import AppKit
import Foundation
import PrintCore

// Headless companion + diagnostics tool. `gpctl run` drives exactly the same
// PrintEngine as the menu bar app, which is what the automated tests use.

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

func usage() -> Never {
    print("""
    gpctl printers                       list macOS printers and their state
    gpctl render <in.html> <out.pdf>     render HTML through the print pipeline and validate
    gpctl submit <file.pdf> <printer>    submit a PDF to CUPS and wait for completion
    gpctl run [--seconds N]              run the engine headless (GP_SERVER, GP_DEVICE_ID, GP_AUTH_TOKEN,
                                         GP_PRINTER, GP_HOME)
    gpctl status                         print the job table
    gpctl testpage                       queue a local test page (then `run` prints it)
    """)
    exit(2)
}

guard let cmd = args.first else { usage() }

@MainActor func runMain(_ body: @escaping @MainActor () async -> Void) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        await body()
        exit(0)
    }
    app.run()
    exit(0)
}

Log.shared.echoToStdout = env["GP_QUIET"] == nil

switch cmd {
case "printers":
    for p in PrinterService.listPrinters() {
        print("\(p.isDefault ? "*" : " ") \(p.name) | \(p.displayName) | \(p.statusText) | \(p.makeModel)")
        let sizes = PrinterService.paperSizes(for: p.name)
        if !sizes.isEmpty { print("    paper: \(sizes.prefix(12).joined(separator: ", "))") }
    }
case "render":
    guard args.count >= 3 else { usage() }
    let html = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
    let paper = PaperSpec.from(env["GP_PAPER"] ?? "letter")
    runMain {
        do {
            let r = HTMLRenderer()
            let check = try await r.render(html: html, paper: paper, orientation: .portrait, to: URL(fileURLWithPath: args[2]))
            print("OK pages=\(check.pages) bytes=\(check.bytes) size=\(Int(check.pageSize.width))x\(Int(check.pageSize.height)) text=\(check.textSample.replacingOccurrences(of: "\n", with: " | "))")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
case "submit":
    guard args.count >= 3 else { usage() }
    do {
        let id = try PrinterService.submit(pdf: URL(fileURLWithPath: args[1]), printer: args[2], title: "gpctl submit",
                                           options: SubmitOptions(media: "Letter", orientation: .portrait, scaling: .actual,
                                                                  colorMode: .monochrome, copies: 1, duplex: false))
        print("submitted CUPS job \(id)")
        for _ in 0..<60 {
            if let j = PrinterService.job(printer: args[2], id: id) {
                print("state: \(j.status)")
                if j.status == .completed || j.status == .aborted || j.status == .cancelled { break }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
    }
case "status":
    let store = try JobStore()
    let c = try store.counts()
    print("queued=\(c.queued) printing=\(c.printing) printed=\(c.printed) failed=\(c.failed) cancelled=\(c.cancelled) acksPending=\(c.acksPending) duplicates=\(c.duplicates)")
    for j in try store.list(limit: 1000).reversed() {
        print("\(j.seq)\t\(j.state.rawValue)\t\(j.jobId)\tgame=\(j.gameKey)\tcups=\(j.cupsJobId.map(String.init) ?? "-")\tattempts=\(j.attempts)\tack=\(j.ackNeeded ? "pending" : (j.ackedAt != nil ? "done" : "-"))\tdup=\(j.duplicateCount)\terr=\(j.lastError ?? "")")
    }
case "testpage":
    runMain {
        let engine = try! PrintEngine(loadCredentials: false)
        print(engine.printTestPage())
    }
case "run":
    var seconds: Double = .infinity
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Double(args[i + 1]) { seconds = s }
    runMain {
        let engine = try! PrintEngine(loadCredentials: env["GP_DEVICE_ID"] == nil)
        if let server = env["GP_SERVER"] { engine.config.serverURL = server }
        if let printer = env["GP_PRINTER"] { engine.config.printerName = printer }
        if let poll = env["GP_POLL"], let p = Double(poll) { engine.config.pollInterval = p }
        if let d = env["GP_DEVICE_ID"], let t = env["GP_AUTH_TOKEN"] {
            engine.useCredentials(Credentials(deviceId: d, authToken: t))
        }
        engine.start()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        engine.stop()
        print(engine.diagnosticsText())
    }
default:
    usage()
}
