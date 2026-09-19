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

    // The SSE drops this backoff absorbs are fleet-wide: one edge event severs every
    // stream at once (#2457 — measured at a 2.5-3.0ms spread across both eval-api
    // pods), so every client re-enters the backoff together. A constant delay there
    // republishes the drop's own synchronisation as a reconnect spike one backoff
    // later (#2508).
    func testWithJitterScattersTheDelay() {
        let base = StreamingDataSource.initialBackoff
        var samples = Set<TimeInterval>()
        for _ in 0..<200 {
            samples.insert(StreamingDataSource.withJitter(base))
        }

        XCTAssertGreaterThan(
            samples.count, 1,
            "reconnect delay is deterministic — a fleet-wide drop reconnects in lockstep"
        )
        for delay in samples {
            XCTAssertGreaterThanOrEqual(delay, base / 2)
            XCTAssertLessThanOrEqual(delay, base)
            XCTAssertGreaterThan(delay, 0)  // anti-busy-loop on an immediate failure
        }
    }

    func testWithJitterBoundsEveryLadderLevel() {
        for base in [StreamingDataSource.initialBackoff, 4.0, StreamingDataSource.maxBackoff] {
            for _ in 0..<50 {
                let delay = StreamingDataSource.withJitter(base)
                XCTAssertGreaterThanOrEqual(delay, base / 2)
                XCTAssertLessThanOrEqual(delay, base)
            }
        }
    }

    func testWithJitterPassesThroughNonPositive() {
        XCTAssertEqual(StreamingDataSource.withJitter(0), 0)
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

    // GAP-A: a stream that stays down must exhaust its retry budget and hand off to
    // the polling fallback — and then KEEP RETRYING underneath it (#3075). Returning
    // out of the connect loop at the cap left the app blind to real-time updates,
    // kill switches included, until it was restarted. This drives the real connect
    // loop: port 1 is never listening, so every attempt fails fast (connection
    // refused), the swift analogue of the android test's repeated 500s.
    func testStreamThatStaysDownArmsTheFallbackOnceAndKeepsRetrying() {
        // DispatchSemaphore is Sendable, so it can be signalled from the source's
        // @Sendable callback without an unchecked-Sendable box.
        let reachedCap = DispatchSemaphore(value: 0)
        let armings = Counter()

        let ds = StreamingDataSource(
            baseUrl: "http://127.0.0.1:1",
            clientKey: "key",
            context: ["user_id": "u1"],
            onChange: { _ in },
            onSnapshot: { _ in },
            onFallbackToPolling: { armings.increment(); reachedCap.signal() },
            // Keep the 5-retry schedule but collapse its wall-clock.
            initialBackoff: 0.01
        )
        ds.start()

        XCTAssertEqual(
            reachedCap.wait(timeout: .now() + 10),
            .success,
            "onFallbackToPolling should fire so the core can start polling"
        )
        XCTAssertTrue(ds.hasFallenBackToPolling)

        // The loop must still be reconnecting well past the cap.
        let target = StreamingDataSource.maxRetries + 3
        let deadline = Date().addingTimeInterval(10)
        while ds.retryAttempts < target && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let attempts = ds.retryAttempts
        ds.stop()

        XCTAssertGreaterThan(
            attempts,
            StreamingDataSource.maxRetries,
            "the stream must keep retrying past the cap, not give up"
        )
        XCTAssertEqual(
            armings.value,
            1,
            "the fallback arms once per outage, not once per retry"
        )
    }

    // The other half of #3075: a stream that comes back must RETIRE the poller that
    // was covering for it. Signalled off a delivered CONFIG frame rather than a 200 —
    // the client stream's first frame is `connection-ready`, which carries none — and
    // from inside the read loop rather than on its return: `connect()` blocks for the
    // whole lifetime of a healthy stream, so a reap on return would leave the poller
    // running beside it the entire time, its periodic whole-store replaces reverting
    // the deltas the stream applies.
    func testDeliveredConfigRetiresTheFallbackExactlyOnce() {
        let reachedCap = DispatchSemaphore(value: 0)
        let recovered = DispatchSemaphore(value: 0)
        let recoveries = Counter()

        let ds = StreamingDataSource(
            baseUrl: "http://127.0.0.1:1",
            clientKey: "key",
            context: ["user_id": "u1"],
            onChange: { _ in },
            onSnapshot: { _ in },
            onFallbackToPolling: { reachedCap.signal() },
            onStreamRecovered: { recoveries.increment(); recovered.signal() },
            initialBackoff: 0.01
        )
        ds.start()

        XCTAssertEqual(reachedCap.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(ds.hasFallenBackToPolling)

        // What `connect()` calls on each `flags-updated` frame it reads, after
        // applying it. Driven directly here because URLSession.bytes(for:) cannot be
        // mocked — macOS CI compiles the call site, this asserts the state machine
        // behind it.
        ds.configDelivered()

        XCTAssertEqual(
            recovered.wait(timeout: .now() + 5),
            .success,
            "a delivered config frame must retire the fallback poller"
        )
        XCTAssertFalse(ds.hasFallenBackToPolling)
        XCTAssertEqual(ds.retryAttempts, 0, "a delivered config frame resets the retry budget")

        // Every subsequent config frame on the same healthy stream must stay quiet.
        ds.configDelivered()
        ds.configDelivered()
        ds.stop()

        XCTAssertEqual(
            recoveries.value,
            1,
            "recovery is signalled once per outage, not once per config frame"
        )
    }
}

/// Minimal thread-safe counter. `NSLock` + a boxed `Int` rather than an actor: the
/// callbacks under test are synchronous and `@Sendable`, so they cannot await.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
