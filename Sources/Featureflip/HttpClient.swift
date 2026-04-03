import Foundation

/// HTTP client for evaluation API requests.
final class HttpClient: Sendable {
    enum Error: Swift.Error {
        case httpError(statusCode: Int)
        case invalidURL
    }

    private let baseUrl: String
    private let clientKey: String
    private let loader: HTTPDataLoader

    init(baseUrl: String, clientKey: String, loader: HTTPDataLoader = URLSession.shared) {
        self.baseUrl = baseUrl
        self.clientKey = clientKey
        self.loader = loader
    }

    func evaluate(context: [String: String], timeout: TimeInterval? = nil) async throws -> EvaluateResponse {
        try await post(path: "/v1/client/evaluate", body: ["context": context], timeout: timeout)
    }

    func identify(context: [String: String]) async throws -> EvaluateResponse {
        try await post(path: "/v1/client/identify", body: ["context": context])
    }

    func postEvents(_ events: [SdkEvent]) async throws {
        let body = RecordEventsRequest(events: events)
        let data = try JSONEncoder().encode(body)
        var request = try makeRequest(path: "/v1/sdk/events", method: "POST")
        request.httpBody = data
        let (_, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Error.httpError(statusCode: code)
        }
    }

    // MARK: - Private

    private func post<T: Decodable>(path: String, body: some Encodable, timeout: TimeInterval? = nil) async throws -> T {
        let data = try JSONEncoder().encode(body)
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = data
        if let timeout {
            request.timeoutInterval = timeout
        }
        let (responseData, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Error.httpError(statusCode: code)
        }
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseUrl + path) else { throw Error.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientKey, forHTTPHeaderField: "Authorization")
        return request
    }
}
