# GamePrint Companion (macOS)

A native menu bar app that receives print jobs from the GamePrint web app and
prints them silently on a printer you pick, with no dialogs, no browser and no
button presses. It is built for unattended use: configure it before kickoff and
walk away.

## Install

```bash
git clone https://github.com/ShneurNovack/gameprint-companion
cd gameprint-companion
scripts/build-app.sh --install     # builds, signs, copies to /Applications, launches
```

Requires macOS 13+ and Xcode (or the Command Line Tools with Swift 5.9+).

## First run

The setup window opens automatically:

1. **Connect**: paste the Server URL (your published GamePrint domain), the
   Device ID and the Auth token from the web app's Companion page. The app
   verifies them with a heartbeat and stores them in the macOS Keychain.
2. **Name** this Mac (e.g. "Living Room Mac").
3. **Printer and paper**: pick a printer (or follow the macOS default), paper,
   orientation, scaling, grayscale/color, copies. Duplex is off by default so
   each game event is its own sheet.
4. **Print Test Page**: goes through the exact same pipeline as game events.
5. **Launch at login**: registers a LaunchAgent that starts the app at login
   and relaunches it if it ever crashes (a normal Quit stays quit). macOS may
   ask you to allow it under System Settings > General > Login Items.
6. **Finish** shows "Ready".

## How a job flows

```
poll ─► SQLite (job_id UNIQUE) ─► validate ─► render HTML → PDF (WebKit print path)
     ─► validate PDF ─► CUPS submit (silent) ─► wait for CUPS "completed" ─► ack "printed"
```

* **Exactly once.** Every job id is written to a local SQLite database (WAL,
  full sync) in the same transaction that validates it. A job id that already
  exists is never inserted again, so server retries and duplicate deliveries
  cannot print twice. Ids are kept forever; only page bodies are purged after
  the retention period.
* **Crash windows.** Before handing a PDF to CUPS the job is marked
  `submitting` with a unique CUPS title. If the app dies between CUPS accepting
  the job and the database recording it, the next launch finds the job in CUPS
  by title and does not resubmit.
* **"Printed" means printed.** The server is only told `printed` when the
  macOS print system reports the CUPS job `completed` (fully delivered to the
  printer). "Submitted to spooler" is shown separately as *Printing (in macOS
  queue)*. A CUPS job that is aborted is resubmitted (up to the retry limit);
  one cancelled in the macOS queue is reported `failed`.
* **Nothing is dropped.** Printer missing/offline, printer paused, spooler
  refusal, render failure, network loss and server errors all keep the job and
  retry with backoff. Acks are retried until the server confirms.
* **Ordering.** Jobs print oldest-first. A job never jumps ahead of an
  unfinished earlier job from the same game, while other games keep flowing.
* **Pause** keeps accepting and storing jobs; Resume prints them in order.
  "Discard queued" asks for confirmation and reports them as cancelled.
* **Reprint** is an explicit extra copy and deliberately bypasses duplicate
  protection (it is never acknowledged to the server).

## Unattended behaviour

* Menu bar only (no Dock icon); keeps running with no window open.
* Opts out of App Nap so polling is never throttled, and by default holds a
  "no idle sleep" assertion so the Mac stays awake (the display can still sleep).
* Reconnects immediately on wake from sleep and on network changes; backs off
  exponentially (max 60s) while the server is unreachable.
* Optionally resumes a macOS print queue that paused itself after an error.
* Notifications for failed jobs, printer problems and lost connection.

## Diagnostics

The Diagnostics tab shows connection, last heartbeat, last API success, printer
state, last received / printed job, queue counts, uptime and login-item state,
plus the live log. **Export Diagnostic Log** writes a zip with the rotating logs
(`~/Library/Application Support/GamePrintCompanion/Logs`, 5 × 2 MB), a job
table and a status snapshot. The auth token is scrubbed from every log line.

## Command line

```bash
"/Applications/GamePrint Companion.app/Contents/MacOS/GamePrintCompanion" --pair https://your-app.base44.app DEVICEID TOKEN
"/Applications/GamePrint Companion.app/Contents/MacOS/gpctl" printers   # list printers + state
"/Applications/GamePrint Companion.app/Contents/MacOS/gpctl" status     # job table
```

## Tests

```bash
swift test                                   # job store: dedupe, ordering, recovery
python3 testing/fake_printer.py &            # raw socket "printer" on :19100
python3 testing/mock_server.py &             # companion API with fault injection
lpadmin -p GamePrint_Fake -E -v socket://127.0.0.1:19100 \
  -P /System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Versions/A/Resources/Generic.ppd
python3 testing/e2e.py                       # full pipeline through real CUPS
```

The end-to-end suite drives the real engine through real CUPS into a fake
network printer and checks what physically arrived: basic flow, duplicate
re-delivery, duplicates inside one poll, malformed jobs, 60 pages across three
simultaneous games, backend outage, lost and failed acks, SIGKILL mid-queue,
a crash inside the submit window, pause/resume, and printer offline/online.
