import XCTest
@testable import Featureflip

/// Thread-safe collector so the @Sendable stream callbacks can record what they received.
private final class FlagsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: FlagValue]] = []
    func add(_ flags: [String: FlagValue]) { lock.withLock { items.append(flags) } }
    var all: [[String: FlagValue]] { lock.withLock { items } }
}

final class StreamingDataSourceTests: XCTestCase {
    func testBuildStreamURL() {
        let url = StreamingDataSource.buildStreamURL(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_abc",
            context: ["user_id": "123"]
        )
        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.hasPrefix("https://eval.example.com/v1/client/stream?"))
        XCTAssertTrue(urlString.contains("authorization=csk_abc"))
        XCTAssertTrue(urlString.contains("context="))
    }

    func testParseSSEEvent() {
        let lines = [
            "event: flags-updated",
            "data: {\"flags\":{\"f1\":{\"value\":true,\"variation\":\"on\",\"reason\":\"Fallthrough\"}}}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "flags-updated")
        XCTAssertNotNil(event?.data)
    }

    func testParseSSEEventIgnoresUnknownType() {
        let lines = [
            "event: ping",
            "data: {\"timestamp\":\"2026-01-01\"}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "ping")
    }

    func testBackoffIncreases() {
        var backoff = StreamingDataSource.initialBackoff
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 2.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 4.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 8.0)
    }

    func testBackoffCapsAtMax() {
        var backoff = 16.0
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 30.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 30.0)
    }

    func testParseSSEEventNoSpaceAfterColon() {
        let lines = [
            "event:flags-updated",
            "data:{\"flags\":{}}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "flags-updated")
        XCTAssertEqual(event?.data, "{\"flags\":{}}")
    }

    func testParseSSEEventMultipleDataLines() {
        let lines = [
            "event: message",
            "data: line1",
            "data: line2",
            "data: line3",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "message")
        XCTAssertEqual(event?.data, "line1\nline2\nline3")
    }

    func testFullMarkerReplacesWithoutFullMerges() {
        let snapshots = FlagsCollector()
        let deltas = FlagsCollector()

        let ds = StreamingDataSource(
            baseUrl: "https://eval.example.com",
            clientKey: "key",
            context: ["user_id": "u1"],
            onChange: { deltas.add($0) },
            onSnapshot: { snapshots.add($0) }
        )

        func flag(_ key: String) -> String {
            "\"\(key)\":{\"value\":true,\"variation\":\"on\",\"reason\":\"Fallthrough\"}"
        }
        // The connect-time snapshot carries `full: true` (#1873); deltas omit it. The
        // replace decision is keyed off the marker, not event order.
        ds.handleEvent(SSEEvent(eventType: "flags-updated", data: "{\"full\":true,\"flags\":{\(flag("flag-a"))}}"))
        ds.handleEvent(SSEEvent(eventType: "flags-updated", data: "{\"flags\":{\(flag("flag-b"))}}"))

        XCTAssertEqual(snapshots.all.count, 1)
        XCTAssertTrue(snapshots.all.first?.keys.contains("flag-a") ?? false)
        XCTAssertEqual(deltas.all.count, 1)
        XCTAssertTrue(deltas.all.first?.keys.contains("flag-b") ?? false)
    }

    // GAP-A: a stream that stays down must exhaust its retries and hand off to the
    // polling fallback rather than giving up. This drives the real connect loop to
    // the cap — the wiring the core relies on to call handleStreamingFallback().
    // Port 1 is never listening, so every attempt fails fast (connection refused),
    // which is the swift analogue of the android test's repeated 500s.
    func testStreamThatStaysDownReachesRetryCapAndSignalsFallback() {
        // DispatchSemaphore is Sendable, so it can be signalled from the source's
        // @Sendable callback without an unchecked-Sendable box.
        let reachedCap = DispatchSemaphore(value: 0)

        let ds = StreamingDataSource(
            baseUrl: "http://127.0.0.1:1",
            clientKey: "key",
            context: ["user_id": "u1"],
            onChange: { _ in },
            onSnapshot: { _ in },
            onMaxRetriesReached: { reachedCap.signal() },
            // Keep the 5-retry schedule but collapse its wall-clock.
            initialBackoff: 0.01
        )
        ds.start()

        XCTAssertEqual(
            reachedCap.wait(timeout: .now() + 10),
            .success,
            "onMaxRetriesReached should fire so the core can fall back to polling"
        )
        XCTAssertTrue(ds.isMaxRetriesReached)
        ds.stop()
    }
}
