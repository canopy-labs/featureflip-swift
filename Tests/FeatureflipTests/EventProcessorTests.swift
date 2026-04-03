import XCTest
@testable import Featureflip

final class EventProcessorTests: XCTestCase {
    func testEnqueueAndFlush() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 202, body: Data())

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        let processor = EventProcessor(httpClient: httpClient, flushInterval: 300, batchSize: 100)

        await processor.enqueue(SdkEvent(
            type: "Custom",
            flagKey: nil,
            userId: "u1",
            variation: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            metadata: nil
        ))

        await processor.flush()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(loader.capturedRequests.count, 1)
    }

    func testFlushOnBatchSize() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 202, body: Data())

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        let processor = EventProcessor(httpClient: httpClient, flushInterval: 300, batchSize: 2)

        let event = SdkEvent(
            type: "Custom",
            flagKey: nil,
            userId: "u1",
            variation: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            metadata: nil
        )

        await processor.enqueue(event)
        await processor.enqueue(event)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(loader.capturedRequests.count, 1)
    }

    func testFlushWithNoEventsDoesNothing() async throws {
        let loader = MockHTTPLoader()
        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        let processor = EventProcessor(httpClient: httpClient, flushInterval: 300, batchSize: 100)

        await processor.flush()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(loader.capturedRequests.count, 0)
    }
}
