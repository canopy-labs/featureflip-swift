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
    private let reportsEvaluations: Bool

    /// Tells the server this client reports the flags it reads as `Evaluation` events,
    /// so it stops recording every flag it serves on the client's behalf. Sent only on
    /// evaluate and identify, and only when read reporting is on.
    static let reportsEvaluationsHeader = "X-Featureflip-Reports-Evaluations"

    /// - Parameter reportsEvaluations: the core passes `config.sendEvaluationEvents`, the
    ///   same setting that decides whether it creates a `ReadRecorder`, so the header can
    ///   never be sent by a client that is not reporting its reads.
    init(
        baseUrl: String,
        clientKey: String,
        loader: HTTPDataLoader = URLSession.shared,
        reportsEvaluations: Bool = false
    ) {
        self.baseUrl = baseUrl
        self.clientKey = clientKey
        self.loader = loader
        self.reportsEvaluations = reportsEvaluations
    }

    func evaluate(context: [String: AnyCodableValue], timeout: TimeInterval? = nil) async throws -> EvaluateResponse {
        try await post(
            path: "/v1/client/evaluate",
            body: ["context": context],
            timeout: timeout,
            reportsEvaluations: reportsEvaluations
        )
    }

    func identify(context: [String: AnyCodableValue]) async throws -> EvaluateResponse {
        try await post(
            path: "/v1/client/identify",
            body: ["context": context],
            reportsEvaluations: reportsEvaluations
        )
    }

    func postEvents(_ events: [SdkEvent]) async throws {
        let body = RecordEventsRequest(events: events)
        let data = try JSONEncoder().encode(body)
        // The CLIENT surface, like every other call this SDK makes. /v1/sdk/events accepts
        // server keys only, so it answered this one with a 401 — which the event processor
        // classifies as permanent, discarding every batch (#3069).
        var request = try makeRequest(path: "/v1/client/events", method: "POST")
        request.httpBody = data
        let (_, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Error.httpError(statusCode: code)
        }
    }

    // MARK: - Private

    private func post<T: Decodable>(
        path: String,
        body: some Encodable,
        timeout: TimeInterval? = nil,
        reportsEvaluations: Bool = false
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        var request = try makeRequest(path: path, method: "POST", reportsEvaluations: reportsEvaluations)
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

    private func makeRequest(path: String, method: String, reportsEvaluations: Bool = false) throws -> URLRequest {
        guard let url = URL(string: baseUrl + path) else { throw Error.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientKey, forHTTPHeaderField: "Authorization")
        if reportsEvaluations {
            request.setValue("1", forHTTPHeaderField: Self.reportsEvaluationsHeader)
        }
        return request
    }
}
