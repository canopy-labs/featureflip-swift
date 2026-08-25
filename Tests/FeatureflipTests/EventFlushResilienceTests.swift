import XCTest
@testable import Featureflip

/// Regression guards for #2456.
///
/// `flush` emptied the buffer and then called `try? await httpClient.postEvents`,
/// so every 503, timeout and offline blip discarded that batch outright. The HTTP
/// layer detected the failure correctly — `try?` dropped the detection on the
/// floor. In production the public edge answers this endpoint with a 503 at a low
/// but constant rate, so analytics were being lost steadily.
final class EventFlushResilienceTests: XCTestCase {

    private func makeEvent(_ key: String) -> SdkEvent {
        SdkEvent(
            type: "Custom",
            flagKey: key,
            userId: "u1",
            variation: nil,
            timestamp: "2025-01-01T00:00:00Z",
            metadata: nil
        )
    }

    private func makeProcessor(
        loader: MockHTTPLoader,
        batchSize: Int = 100,
        maxBufferSize: Int = EventProcessor.defaultMaxBufferSize
    ) -> EventProcessor {
        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        return EventProcessor(
            httpClient: httpClient,
            flushInterval: 300,
            batchSize: batchSize,
            maxBufferSize: maxBufferSize
        )
    }

    /// Number of events carried by a captured request.
    private func eventCount(_ request: URLRequest) -> Int {
        guard let body = request.httpBody else { return 0 }
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return 0 }
        guard let json = object as? [String: Any] else { return 0 }
        guard let events = json["events"] as? [Any] else { return 0 }
        return events.count
    }

    func testA503KeepsTheBatchForTheNextFlush() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 503, body: Data())
        loader.enqueue(statusCode: 202, body: Data())

        let processor = makeProcessor(loader: loader)
        await processor.enqueue(makeEvent("flag-a"))

        await processor.flush()
        await processor.flush()

        XCTAssertEqual(loader.captured.count, 2)
        // The retried request must still carry the event the 503 rejected.
        XCTAssertEqual(eventCount(loader.captured[1]), 1)
    }

    func testATransportFailureKeepsTheBatch() async throws {
        // With no canned responses and no always-status, the loader throws URLError —
        // a transport fault, which must be treated as transient.
        let loader = MockHTTPLoader()
        let processor = makeProcessor(loader: loader)
        await processor.enqueue(makeEvent("flag-a"))

        await processor.flush()
        loader.enqueue(statusCode: 202, body: Data())
        await processor.flush()

        XCTAssertEqual(loader.captured.count, 2)
        XCTAssertEqual(eventCount(loader.captured[1]), 1)
    }

    func testARejectedKeyDropsTheBatchWithoutRetrying() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(401)

        let processor = makeProcessor(loader: loader)
        await processor.enqueue(makeEvent("flag-a"))

        await processor.flush()
        await processor.flush()

        // Retrying a rejected SDK key forever would pin the buffer at its bound and
        // starve every later event.
        XCTAssertEqual(loader.captured.count, 1)
    }

    func testAFailingEndpointDoesNotGetOneRequestPerRecordedEvent() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(503)

        // A batch size of 1 means every enqueue trips the size trigger.
        let processor = makeProcessor(loader: loader, batchSize: 1)
        for index in 0..<10 {
            await processor.enqueue(makeEvent("flag-\(index)"))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // The re-queued batch leaves the buffer at the batch size, so without a
        // backoff on the size trigger each later event would start its own flush.
        XCTAssertEqual(loader.captured.count, 1)
    }

    func testNeverPutsMoreThanABatchInOneRequest() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(503)

        // Every send fails while the backlog builds; the first failure arms the
        // backoff gate, so the rest simply pile up behind it.
        let processor = makeProcessor(loader: loader, batchSize: 2)
        for index in 0..<5 {
            await processor.enqueue(makeEvent("flag-\(index)"))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let attemptsWhileFailing = loader.captured.count
        loader.setAlwaysStatusCode(202)
        await processor.flush()

        let delivered = loader.captured.suffix(from: attemptsWhileFailing)
        // A backlog must never go out as one oversized request: a 413 is not
        // retryable, so the path meant to preserve it would be the one that
        // discarded it.
        for request in loader.captured {
            XCTAssertLessThanOrEqual(eventCount(request), 2)
        }
        XCTAssertEqual(delivered.reduce(0) { $0 + eventCount($1) }, 5)
    }

    func testTheBufferIsBoundedAndShedsTheOldestEvents() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(503)

        // Batch size above the bound, so nothing auto-flushes and the bound is what
        // has to hold.
        let processor = makeProcessor(loader: loader, batchSize: 100, maxBufferSize: 3)
        for index in 0..<5 {
            await processor.enqueue(makeEvent("flag-\(index)"))
        }

        let buffered = await processor.bufferedEventCount()
        XCTAssertEqual(buffered, 3)
        // Asserting the count alone would still pass if the bound shed the NEWEST,
        // which is the exact inversion of the documented cross-SDK rule.
        let keys = await processor.bufferedFlagKeys()
        XCTAssertEqual(keys, ["flag-2", "flag-3", "flag-4"])
    }

    func testStopReturnsWhileTheEndpointIsDown() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(503)

        let processor = makeProcessor(loader: loader)
        await processor.enqueue(makeEvent("flag-a"))

        // Nothing flushes after stop, so a still-failing endpoint must not hang
        // shutdown by looping until the buffer empties.
        await processor.stop()

        let buffered = await processor.bufferedEventCount()
        XCTAssertEqual(buffered, 0)
    }
}
