import Foundation

/// Configuration for the Featureflip client.
public struct FeatureflipConfig: Sendable {
    public let clientKey: String
    public let baseUrl: String
    /// `private(set)`: the initializer takes `[String: Any]` and converts, so a
    /// settable property of the converted type would be an asymmetry callers
    /// could not satisfy (`config.context = myAnyDict` would not compile).
    public private(set) var context: [String: AnyCodableValue]
    public let streaming: Bool
    public let pollInterval: TimeInterval
    public let flushInterval: TimeInterval
    public let flushBatchSize: Int
    public let initTimeout: TimeInterval
    /// In-process observers fired on every variation call. Honored on the first
    /// client created per `clientKey` — later clients share that core's config,
    /// like every other option.
    public let inspectors: [EvaluationInspector]

    public init(
        clientKey: String,
        baseUrl: String = "https://eval.featureflip.io",
        context: [String: Any] = [:],
        streaming: Bool = true,
        pollInterval: TimeInterval = 30,
        flushInterval: TimeInterval = 30,
        flushBatchSize: Int = 100,
        initTimeout: TimeInterval = 10,
        inspectors: [EvaluationInspector] = []
    ) {
        self.clientKey = clientKey
        self.baseUrl = baseUrl
        // Converted once at the boundary: the stored property is AnyCodableValue so
        // FeatureflipConfig stays Sendable and encodable (#2293).
        self.context = context.mapValues { AnyCodableValue(any: $0) }
        self.streaming = streaming
        self.pollInterval = pollInterval
        self.flushInterval = flushInterval
        self.flushBatchSize = flushBatchSize
        self.initTimeout = initTimeout
        self.inspectors = inspectors
    }
}
