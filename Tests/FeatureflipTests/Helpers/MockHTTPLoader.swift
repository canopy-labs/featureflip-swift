import Foundation
@testable import Featureflip

/// Mock HTTP loader that returns canned responses.
final class MockHTTPLoader: HTTPDataLoader, @unchecked Sendable {
    var responses: [(Data, URLResponse)] = []
    var capturedRequests: [URLRequest] = []
    private let lock = NSLock()

    func enqueue(statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://test.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        responses.append((body, response))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        lock.unlock()
        return response
    }
}
