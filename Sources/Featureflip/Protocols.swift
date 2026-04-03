import Foundation

/// Abstraction over URLSession for testability.
protocol HTTPDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoader {}
