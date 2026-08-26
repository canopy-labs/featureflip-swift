import XCTest
@testable import Featureflip

final class PollingDataSourceTests: XCTestCase {
    func testPollFetchesFlags() async throws {
        let loader = MockHTTPLoader()
        let body = """
        {"flags":{"f1":{"value":true,"variation":"on","reason":"Fallthrough"}}}
        """.data(using: .utf8)!
        loader.enqueue(statusCode: 200, body: body)

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        var receivedFlags: [String: FlagValue]?
        let poller = PollingDataSource(
            httpClient: httpClient,
            context: ["user_id": "u1"],
            interval: 300,
            onChange: { flags in receivedFlags = flags }
        )

        await poller.pollOnce()
        XCTAssertNotNil(receivedFlags)
        XCTAssertEqual(receivedFlags?["f1"]?.variation, "on")
    }

    func testPollSilentlyHandlesErrors() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 500, body: Data())

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        var called = false
        let poller = PollingDataSource(
            httpClient: httpClient,
            context: ["user_id": "u1"],
            interval: 300,
            onChange: { _ in called = true }
        )

        await poller.pollOnce()
        XCTAssertFalse(called)
    }

    /// A `Task` body runs even when the task was cancelled before it was ever
    /// scheduled, so `start()` used to leak exactly one request past `stop()` — an
    /// `initialize()`/`close()` pair left a poll pending that fired at an arbitrary
    /// later moment carrying the context the poller was built with (#2481).
    func testStopBeforeFirstPollMakesNoRequest() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: Data(#"{"flags":{}}"#.utf8))

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        let poller = PollingDataSource(
            httpClient: httpClient,
            context: ["user_id": "u1"],
            interval: 300,
            onChange: { _ in }
        )

        poller.start()
        poller.stop()

        // Ample opportunity for a leaked task body to run.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(
            loader.captured.isEmpty,
            "a poller stopped before its first poll must not issue a request; got \(loader.captured.count)"
        )
    }

    /// The other half of the contract above: cancellation is the only thing that
    /// suppresses the immediate first poll. "Polls once immediately, then on
    /// interval" is the shared data-source behaviour across the client SDKs.
    func testStartPollsImmediatelyWhenNotStopped() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: Data(#"{"flags":{}}"#.utf8))

        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        let poller = PollingDataSource(
            httpClient: httpClient,
            context: ["user_id": "u1"],
            interval: 300,
            onChange: { _ in }
        )

        poller.start()

        let deadline = Date().addingTimeInterval(2.0)
        while loader.captured.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        poller.stop()

        XCTAssertEqual(loader.captured.count, 1, "start() must make exactly one immediate poll")
    }
}
