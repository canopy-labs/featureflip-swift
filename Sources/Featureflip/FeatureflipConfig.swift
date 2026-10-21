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
    /// Report the flags this app reads (the typed variation methods and `flagDetail`),
    /// so the server can tell which client-side flags are still in use and refuses to
    /// archive them. On by default. Each flag, variation and user is reported about
    /// once an hour per device, and again each time the app returns to the foreground.
    ///
    /// When off, no reads are reported and the server instead records every flag it
    /// sends this client as evaluated, so no client-side flag served to it ever looks
    /// unused.
    ///
    /// Honored on the first client created per `clientKey`, like every other option.
    public let sendEvaluationEvents: Bool
    /// Name of a library that wraps this SDK (a React Native or Flutter bridge, an
    /// internal platform client). Sent after the SDK's own token in the User-Agent
    /// (`featureflip-swift/<version> my-wrapper/1.0.0`) so usage through the wrapper can
    /// be counted. Must be a valid HTTP product token; an invalid one is ignored with a
    /// diagnostic. Leave unset when calling the SDK directly.
    public let wrapperName: String?
    /// Version of the wrapper named by `wrapperName`. Optional.
    public let wrapperVersion: String?

    public init(
        clientKey: String,
        baseUrl: String = "https://eval.featureflip.io",
        context: [String: Any] = [:],
        streaming: Bool = true,
        pollInterval: TimeInterval = 30,
        flushInterval: TimeInterval = 30,
        flushBatchSize: Int = 100,
        initTimeout: TimeInterval = 10,
        inspectors: [EvaluationInspector] = [],
        sendEvaluationEvents: Bool = true,
        wrapperName: String? = nil,
        wrapperVersion: String? = nil
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
        self.sendEvaluationEvents = sendEvaluationEvents
        self.wrapperName = wrapperName
        self.wrapperVersion = wrapperVersion
    }
}
