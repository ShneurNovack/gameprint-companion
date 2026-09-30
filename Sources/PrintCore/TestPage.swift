import Foundation

enum TestPage {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(deviceName: String, printer: String, jobId: String) -> String {
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>GamePrint Test Page</title>
        <style>
          @page { size: letter portrait; margin: 0.5in; }
          html, body { margin: 0; padding: 0; background: #fff; color: #000; }
          body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
          .headline { font-size: 64pt; font-weight: 900; text-align: center; letter-spacing: 2pt; margin: 0.2in 0 0.1in; }
          .rule { border-top: 6pt solid #000; margin: 0.15in 0; }
          .sub { text-align: center; font-size: 16pt; }
          table { width: 100%; border-collapse: collapse; margin-top: 0.3in; font-size: 13pt; }
          td { border-bottom: 1pt solid #000; padding: 8pt 4pt; }
          td:first-child { font-weight: 700; width: 35%; }
          .box { margin-top: 0.4in; border: 2pt solid #000; padding: 12pt; font-size: 12pt; }
          .corner { position: fixed; width: 0.3in; height: 0.3in; border: 0 solid #000; }
        </style></head>
        <body>
          <div class="rule"></div>
          <div class="headline">TEST PAGE</div>
          <div class="sub">GamePrint Mac Companion</div>
          <div class="rule"></div>
          <table>
            <tr><td>Device</td><td>\(esc(deviceName))</td></tr>
            <tr><td>Printer</td><td>\(esc(printer))</td></tr>
            <tr><td>Job ID</td><td>\(esc(jobId))</td></tr>
            <tr><td>Printed</td><td>\(esc(when))</td></tr>
          </table>
          <div class="box">If you can read this page cleanly, with the heavy rules above
          reaching close to both side margins and nothing clipped, silent printing is set up
          correctly. Live game updates will print on this printer automatically, one event per sheet.</div>
        </body></html>
        """
    }
}
