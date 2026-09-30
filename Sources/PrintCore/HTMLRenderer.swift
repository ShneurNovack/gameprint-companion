import AppKit
import Foundation
import PDFKit
import WebKit

public struct PaperSpec: Sendable {
    public let cupsMedia: String
    public let size: NSSize   // points, portrait
    public static let letter = PaperSpec(cupsMedia: "Letter", size: NSSize(width: 612, height: 792))
    public static let a4 = PaperSpec(cupsMedia: "A4", size: NSSize(width: 595.28, height: 841.89))
    public static let legal = PaperSpec(cupsMedia: "Legal", size: NSSize(width: 612, height: 1008))

    public static func from(_ s: String) -> PaperSpec {
        switch s.lowercased() {
        case "a4": return .a4
        case "legal": return .legal
        default: return .letter
        }
    }

    public func oriented(_ o: Orientation) -> NSSize {
        o == .portrait ? size : NSSize(width: size.height, height: size.width)
    }
}

public enum RenderError: Error, LocalizedError {
    case loadFailed(String)
    case timeout
    case printFailed
    case invalidPDF(String)
    public var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return "Could not load page HTML: \(m)"
        case .timeout: return "Page took too long to load"
        case .printFailed: return "WebKit could not render the page to PDF"
        case .invalidPDF(let m): return "Rendered PDF failed validation: \(m)"
        }
    }
}

public struct PDFCheck: Sendable {
    public let pages: Int
    public let bytes: Int
    public let pageSize: NSSize
    public let textSample: String
}

/// Turns the server's self-contained HTML into a paginated, print-ready PDF
/// using WebKit's own print pipeline (so CSS @page rules apply), without any
/// dialog, browser chrome, URL, date or header/footer.
@MainActor
public final class HTMLRenderer: NSObject, WKNavigationDelegate {
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    public override init() { super.init() }

    /// Margins come from the document's own CSS @page rule (the GamePrint
    /// pages declare 0.5in). `fallbackMargin` is used only when WebKit leaves
    /// page margins to the print info.
    public func render(html: String, paper: PaperSpec, orientation: Orientation,
                       to url: URL, loadTimeout: TimeInterval = 25) async throws -> PDFCheck {
        let pageSize = paper.oriented(orientation)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(origin: .zero, size: pageSize), configuration: config)
        webView.navigationDelegate = self

        // WebKit only paints reliably for print when hosted in a window. The
        // window is never ordered on screen.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: pageSize.width, height: pageSize.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.loadContinuation = c
                    webView.loadHTMLString(html, baseURL: URL(string: "https://gameprint.local/"))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(loadTimeout * 1_000_000_000))
                throw RenderError.timeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                if let c = self.loadContinuation { self.loadContinuation = nil; c.resume(throwing: error) }
                webView.stopLoading()
                throw error
            }
        }
        // Let late images (team logos) decode and layout settle.
        _ = try? await webView.evaluateJavaScript("document.fonts ? document.fonts.ready.then(()=>true) : true")
        try? await Task.sleep(nanoseconds: 400_000_000)

        try? FileManager.default.removeItem(at: url)
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        info.paperSize = pageSize
        info.orientation = orientation == .portrait ? .portrait : .landscape
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1.0
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds

        let ok: Bool = await withCheckedContinuation { c in
            self.printContinuation = c
            op.runModal(for: window, delegate: self,
                        didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok else { throw RenderError.printFailed }
        return try HTMLRenderer.validate(pdf: url, expected: pageSize)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let c = printContinuation
        printContinuation = nil
        c?.resume(returning: success)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let c = loadContinuation; loadContinuation = nil
        c?.resume()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let c = loadContinuation; loadContinuation = nil
        c?.resume(throwing: RenderError.loadFailed(error.localizedDescription))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let c = loadContinuation; loadContinuation = nil
        c?.resume(throwing: RenderError.loadFailed(error.localizedDescription))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let c = loadContinuation; loadContinuation = nil
        c?.resume(throwing: RenderError.loadFailed("web content process terminated"))
    }

    /// Structural checks on the PDF before it goes anywhere near a printer.
    public nonisolated static func validate(pdf url: URL, expected: NSSize) throws -> PDFCheck {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 500 else { throw RenderError.invalidPDF("file missing or empty (\(bytes) bytes)") }
        guard bytes < 40_000_000 else { throw RenderError.invalidPDF("file unreasonably large (\(bytes) bytes)") }
        guard let doc = PDFDocument(url: url) else { throw RenderError.invalidPDF("not a readable PDF") }
        guard doc.pageCount >= 1 else { throw RenderError.invalidPDF("no pages") }
        guard doc.pageCount <= 20 else { throw RenderError.invalidPDF("\(doc.pageCount) pages, expected a short update") }
        guard let first = doc.page(at: 0) else { throw RenderError.invalidPDF("first page unreadable") }
        let box = first.bounds(for: .mediaBox).size
        let matches = abs(box.width - expected.width) < 3 && abs(box.height - expected.height) < 3
        guard matches else {
            throw RenderError.invalidPDF("page is \(Int(box.width))x\(Int(box.height))pt, expected \(Int(expected.width))x\(Int(expected.height))pt")
        }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RenderError.invalidPDF("page rendered blank (no text)") }
        return PDFCheck(pages: doc.pageCount, bytes: bytes, pageSize: box, textSample: String(text.prefix(120)))
    }
}
