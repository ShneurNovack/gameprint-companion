import XCTest
@testable import PrintCore

final class JobStoreTests: XCTestCase {
    var store: JobStore!
    var path: URL!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("gp-test-\(UUID().uuidString).sqlite")
        store = try! JobStore(path: path)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: path) }

    func job(_ id: String?, game: String = "401", html: String? = "<!doctype html><html><body>X</body></html>") -> RemoteJob {
        var d: [String: Any] = ["event_type": "touchdown", "headline": "TOUCHDOWN", "paper_size": "letter",
                                "event_data": ["espnEventId": game]]
        if let id { d["job_id"] = id }
        if let html { d["rendered_html"] = html }
        return RemoteJob(dict: d)
    }

    func testDuplicateDeliveryIsStoredOnce() throws {
        XCTAssertEqual(try store.ingest(job("j1")), .accepted("j1"))
        for _ in 0..<4 { XCTAssertEqual(try store.ingest(job("j1")), .duplicate("j1", .queued)) }
        XCTAssertEqual(try store.counts().queued, 1)
        XCTAssertEqual(try store.fetch("j1")?.duplicateCount, 4)
    }

    func testDuplicateAfterFinishReAcks() throws {
        _ = try store.ingest(job("j1"))
        try store.finish("j1", printed: true, reason: nil)
        try store.markAcked("j1")
        _ = try store.ingest(job("j1"))
        let r = try XCTUnwrap(store.fetch("j1"))
        XCTAssertEqual(r.state, .printed)
        XCTAssertTrue(r.ackNeeded, "a re-delivered finished job should be re-acknowledged, not reprinted")
    }

    func testMalformedJobsFailAndAck() throws {
        if case .malformed(let id, _) = try store.ingest(job("bad", html: nil)) {
            XCTAssertEqual(id, "bad")
        } else { XCTFail() }
        let r = try XCTUnwrap(store.fetch("bad"))
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.ackNeeded)
        XCTAssertEqual(r.ackPrinted, false)
        if case .malformed(nil, _) = try store.ingest(job(nil)) {} else { XCTFail() }
        XCTAssertNil(try store.nextRunnable())
    }

    func testPerGameOrderingSurvivesFailure() throws {
        _ = try store.ingest(job("a1", game: "A"))
        _ = try store.ingest(job("b1", game: "B"))
        _ = try store.ingest(job("a2", game: "A"))
        XCTAssertEqual(try store.nextRunnable()?.jobId, "a1")
        // a1 fails temporarily: a2 must wait, B may proceed.
        try store.retryLater("a1", delay: 60, error: "printer offline", countAttempt: true)
        XCTAssertEqual(try store.nextRunnable()?.jobId, "b1")
        try store.markSubmitting("b1", printer: "P", title: "t")
        try store.markSubmitted("b1", cupsJobId: 1)
        XCTAssertNil(try store.nextRunnable(), "a2 must not jump ahead of a1")
        XCTAssertEqual(try store.nextRunnable(at: Date().addingTimeInterval(61))?.jobId, "a1")
    }

    func testReprintBypassesDuplicateProtection() throws {
        _ = try store.ingest(job("j1"))
        try store.finish("j1", printed: true, reason: nil)
        let newId = try XCTUnwrap(store.reprint("j1"))
        XCTAssertEqual(newId, "j1#reprint-1")
        XCTAssertEqual(try store.fetch(newId)?.state, .queued)
        XCTAssertEqual(try store.fetch(newId)?.isLocal, true)
        XCTAssertEqual(try store.reprint("j1"), "j1#reprint-2")
    }

    func testSurvivesReopen() throws {
        _ = try store.ingest(job("j1"))
        try store.markSubmitting("j1", printer: "P", title: "GamePrint j1 #1")
        store = nil
        let reopened = try JobStore(path: path)
        XCTAssertEqual(try reopened.interrupted().map(\.jobId), ["j1"])
        XCTAssertEqual(try reopened.ingest(job("j1")), .duplicate("j1", .submitting))
    }
}
