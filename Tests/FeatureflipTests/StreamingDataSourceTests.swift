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
}
