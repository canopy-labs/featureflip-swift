import XCTest
@testable import Featureflip

final class HttpClientTests: XCTestCase {
    func testEvaluateSendsCorrectRequest() async throws {
        let loader = MockHTTPLoader()
        let responseBody = """
        {"flags":{"my-flag":{"value":true,"variation":"on","reason":"Fallthrough"}}}
        """.data(using: .utf8)!
        loader.enqueue(statusCode: 200, body: responseBody)

        let client = HttpClient(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_test123",
            loader: loader
        )

        let result = try await client.evaluate(context: ["user_id": "u1"])

        XCTAssertEqual(result.flags.count, 1)
        XCTAssertEqual(result.flags["my-flag"]?.variation, "on")

        let req = loader.capturedRequests[0]
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/client/evaluate")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "csk_test123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testIdentifySendsCorrectRequest() async throws {
        let loader = MockHTTPLoader()
        let responseBody = """
        {"flags":{"flag-a":{"value":"dark","variation":"dark-mode","reason":"RuleMatch"}}}
        """.data(using: .utf8)!
        loader.enqueue(statusCode: 200, body: responseBody)

        let client = HttpClient(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_test123",
            loader: loader
        )

        let result = try await client.identify(context: ["user_id": "u2"])

        XCTAssertEqual(result.flags["flag-a"]?.variation, "dark-mode")

        let req = loader.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/v1/client/identify")
    }

    func testPostEventsSendsCorrectRequest() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 202, body: Data())

        let client = HttpClient(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_test123",
            loader: loader
        )

        let event = SdkEvent(
            type: "Custom",
            flagKey: nil,
            userId: "u1",
            variation: nil,
            timestamp: "2026-03-09T00:00:00Z",
            metadata: nil
        )
        try await client.postEvents([event])

        let req = loader.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/v1/client/events")
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testEvaluateThrowsOnHTTPError() async {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 401, body: Data())

        let client = HttpClient(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_bad",
            loader: loader
        )

        do {
            _ = try await client.evaluate(context: [:])
            XCTFail("Expected error")
        } catch let error as HttpClient.Error {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - X-Featureflip-Reports-Evaluations

    private func makeClient(_ loader: MockHTTPLoader, reportsEvaluations: Bool) -> HttpClient {
        HttpClient(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_test123",
            loader: loader,
            reportsEvaluations: reportsEvaluations
        )
    }

    private let emptyFlags = #"{"flags":{}}"#.data(using: .utf8)!

    func testEvaluateAndIdentifySendTheReportsHeaderWhenReportingIsOn() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: emptyFlags)
        loader.enqueue(statusCode: 200, body: emptyFlags)
        let client = makeClient(loader, reportsEvaluations: true)

        _ = try await client.evaluate(context: ["user_id": "u1"])
        _ = try await client.identify(context: ["user_id": "u1"])

        let requests = loader.captured
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/client/evaluate", "/v1/client/identify"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"), "1")
        }
    }

    func testEvaluateAndIdentifyOmitTheReportsHeaderWhenReportingIsOff() async throws {
        // Off must mean no header: the server then records every flag it serves, which
        // is the only thing keeping a non-reporting client's flags protected.
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: emptyFlags)
        loader.enqueue(statusCode: 200, body: emptyFlags)
        let client = makeClient(loader, reportsEvaluations: false)

        _ = try await client.evaluate(context: ["user_id": "u1"])
        _ = try await client.identify(context: ["user_id": "u1"])

        for request in loader.captured {
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"))
        }
    }

    func testTheReportsHeaderIsOffByDefault() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: emptyFlags)
        let client = HttpClient(baseUrl: "https://eval.example.com", clientKey: "csk_test123", loader: loader)

        _ = try await client.evaluate(context: ["user_id": "u1"])

        XCTAssertNil(loader.captured[0].value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"))
    }

    func testPostEventsNeverSendsTheReportsHeader() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 202, body: Data())
        let client = makeClient(loader, reportsEvaluations: true)

        try await client.postEvents([
            SdkEvent(type: "Evaluation", flagKey: "f", userId: "u1", variation: "on",
                     timestamp: "2026-10-07T00:00:00Z", metadata: nil),
        ])

        XCTAssertEqual(loader.captured[0].url?.path, "/v1/client/events")
        XCTAssertNil(loader.captured[0].value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"))
    }
}
