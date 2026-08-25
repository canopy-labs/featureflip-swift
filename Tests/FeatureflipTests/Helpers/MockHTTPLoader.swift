import Foundation
@testable import Featureflip

/// Mock HTTP loader that returns canned responses.
final class MockHTTPLoader: HTTPDataLoader, @unchecked Sendable {
    var responses: [(Data, URLResponse)] = []
    var capturedRequests: [URLRequest] = []

    /// When set, every request gets this status instead of consuming `responses`.
    ///
    /// Lets a test model an endpoint that stays down for the whole test, rather than
    /// queueing one canned response per attempt — which is impossible when the number
    /// of attempts is the thing under test.
    var alwaysStatusCode: Int?

    private let lock = NSLock()

    /// Lock-taking accessors, for tests that touch the loader while it is live.
    ///
    /// The stored properties are read under `lock` inside `data(for:)`, so a test that
    /// writes or reads them directly while a request may be in flight is racing. Only
    /// `@unchecked Sendable` keeps the compiler quiet about it.
    func setAlwaysStatusCode(_ code: Int?) {
        lock.withLock { alwaysStatusCode = code }
    }

    var captured: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func enqueue(statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://test.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        lock.withLock { responses.append((body, response)) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            capturedRequests.append(request)
            if let code = alwaysStatusCode {
                let response = HTTPURLResponse(
                    url: URL(string: "https://test.com")!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return responses.removeFirst()
        }
    }
}
