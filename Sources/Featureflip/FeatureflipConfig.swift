import Foundation

/// Configuration for the Featureflip client.
public struct FeatureflipConfig: Sendable {
    public let clientKey: String
    public let baseUrl: String
    public var context: [String: String]
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
        context: [String: String] = [:],
        streaming: Bool = true,
        pollInterval: TimeInterval = 30,
        flushInterval: TimeInterval = 30,
        flushBatchSize: Int = 100,
        initTimeout: TimeInterval = 10,
        inspectors: [EvaluationInspector] = []
    ) {
        self.clientKey = clientKey
        self.baseUrl = baseUrl
        self.context = context
        self.streaming = streaming
        self.pollInterval = pollInterval
        self.flushInterval = flushInterval
        self.flushBatchSize = flushBatchSize
        self.initTimeout = initTimeout
        self.inspectors = inspectors
    }
}
