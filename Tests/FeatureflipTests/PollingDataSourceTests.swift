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
}
