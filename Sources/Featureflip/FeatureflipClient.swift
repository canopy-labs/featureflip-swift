import Foundation
#if canImport(Combine)
import Combine
#endif

/// Main public API for the Featureflip SDK.
public final class FeatureflipClient: @unchecked Sendable {
    /// SDK version.
    public static let version = "0.1.0"

    // MARK: - Singleton

    internal static var _shared: FeatureflipClient?

    /// The shared singleton client. Must call `configure(config:)` first.
    public static var shared: FeatureflipClient {
        guard let client = _shared else {
            fatalError("FeatureflipClient.configure(config:) must be called before accessing .shared")
        }
        return client
    }

    /// Configures the shared singleton client.
    public static func configure(config: FeatureflipConfig) {
        _shared = FeatureflipClient(config: config)
    }

    // MARK: - Properties

    private let config: FeatureflipConfig
    private let httpClient: HttpClient
    private let cache: FlagCache
    private let eventProcessor: EventProcessor
    private var streamingDataSource: StreamingDataSource?
    private var pollingDataSource: PollingDataSource?
    private var lifecycleObserver: LifecycleObserver?

    /// NSLock-protected snapshot for synchronous reads.
    private let snapshotLock = NSLock()
    private var flagSnapshot: [String: FlagValue] = [:]

    /// General-purpose lock for mutable properties (stream, poller, lifecycleObserver, _initialized).
    private let lock = NSLock()

    /// Whether this is a test-only client (no network).
    private let isTestClient: Bool

    /// Mutable context updated by identify(), protected by `lock`.
    private var currentContext: [String: String]

    /// Shared date formatter for event timestamps.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Whether the client has been initialized (or is a test client with static overrides).
    public var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _initialized
    }
    private var _initialized = false

    /// SwiftUI integration provider.
    public private(set) var flagProvider: FeatureFlagProvider!

    // MARK: - Init

    /// Creates a new client instance.
    /// - Parameter config: SDK configuration.
    public init(config: FeatureflipConfig) {
        self.config = config
        self.httpClient = HttpClient(baseUrl: config.baseUrl, clientKey: config.clientKey)
        self.cache = FlagCache(clientKey: config.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: config.flushInterval,
            batchSize: config.flushBatchSize
        )
        self.isTestClient = false
        self.currentContext = config.context
        self.flagProvider = FeatureFlagProvider(client: self)
    }

    /// Internal init for unit testing with a custom HTTP loader.
    internal init(config: FeatureflipConfig, loader: HTTPDataLoader) {
        self.config = config
        self.httpClient = HttpClient(baseUrl: config.baseUrl, clientKey: config.clientKey, loader: loader)
        self.cache = FlagCache(clientKey: config.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: config.flushInterval,
            batchSize: config.flushBatchSize
        )
        self.isTestClient = false
        self.currentContext = config.context
        self.flagProvider = FeatureFlagProvider(client: self)
    }

    /// Private init for test clients with static overrides.
    private init(overrides: [String: Any], loader: HTTPDataLoader? = nil) {
        let dummyConfig = FeatureflipConfig(clientKey: "test-key", baseUrl: "https://localhost")
        self.config = dummyConfig
        if let loader = loader {
            self.httpClient = HttpClient(baseUrl: dummyConfig.baseUrl, clientKey: dummyConfig.clientKey, loader: loader)
        } else {
            self.httpClient = HttpClient(baseUrl: dummyConfig.baseUrl, clientKey: dummyConfig.clientKey)
        }
        self.cache = FlagCache(clientKey: dummyConfig.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: dummyConfig.flushInterval,
            batchSize: dummyConfig.flushBatchSize
        )
        self.isTestClient = true
        self.currentContext = dummyConfig.context
        self.flagProvider = FeatureFlagProvider(client: self)

        // Convert overrides to FlagValue snapshot
        var snapshot: [String: FlagValue] = [:]
        for (key, value) in overrides {
            let codableValue: AnyCodableValue
            switch value {
            case let b as Bool:
                codableValue = .bool(b)
            case let s as String:
                codableValue = .string(s)
            case let i as Int:
                codableValue = .int(i)
            case let d as Double:
                codableValue = .double(d)
            default:
                codableValue = .string(String(describing: value))
            }
            snapshot[key] = FlagValue(value: codableValue, variation: "override", reason: "TEST")
        }
        snapshotLock.lock()
        flagSnapshot = snapshot
        snapshotLock.unlock()

        lock.lock()
        _initialized = true
        lock.unlock()
    }

    // MARK: - Lifecycle

    /// Initializes the client: loads disk cache, fetches flags, starts streaming/polling and lifecycle observer.
    public func initialize() async {
        guard !isTestClient else { return }

        // Load persisted cache
        await cache.loadFromDisk()
        let cached = await cache.all()
        if !cached.isEmpty {
            updateSnapshot(cached)
        }

        // Fetch initial flags with initTimeout applied
        do {
            let response = try await httpClient.evaluate(context: config.context, timeout: config.initTimeout)
            await cache.setAll(response.flags)
            updateSnapshot(response.flags)
        } catch {
            // Use cached flags if available
        }

        // Start data source
        startDataSource()

        // Start event processor
        await eventProcessor.start()

        // Start lifecycle observer
        let observer = LifecycleObserver(
            onForeground: { [weak self] in self?.handleForeground() },
            onBackground: { [weak self] in self?.handleBackground() }
        )
        lock.lock()
        lifecycleObserver = observer
        _initialized = true
        lock.unlock()
    }

    /// Stops streaming/polling and flushes pending events.
    public func close() async {
        lock.lock()
        let stream = streamingDataSource
        let poller = pollingDataSource
        streamingDataSource = nil
        pollingDataSource = nil
        lifecycleObserver = nil
        lock.unlock()

        stream?.stop()
        poller?.stop()
        await eventProcessor.stop()
    }

    // MARK: - Variation methods (synchronous)

    /// Returns a boolean flag value, or the default if the flag is missing or not a boolean.
    public func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        guard let flag = getFlag(key), case .bool(let v) = flag.value else {
            return defaultValue
        }
        return v
    }

    /// Returns a string flag value, or the default if the flag is missing or not a string.
    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        guard let flag = getFlag(key), case .string(let v) = flag.value else {
            return defaultValue
        }
        return v
    }

    /// Returns a numeric flag value as Double, or the default if the flag is missing or not numeric.
    public func numberVariation(_ key: String, default defaultValue: Double) -> Double {
        guard let flag = getFlag(key) else { return defaultValue }
        switch flag.value {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return defaultValue
        }
    }

    /// Returns the raw flag value, or the default if the flag is missing.
    public func jsonVariation(_ key: String, default defaultValue: AnyCodableValue) -> AnyCodableValue {
        guard let flag = getFlag(key) else { return defaultValue }
        return flag.value
    }

    // MARK: - Identify

    /// Re-evaluates flags for a new user context.
    public func identify(context: [String: String]) async throws {
        guard !isTestClient else { return }

        let response = try await httpClient.identify(context: context)
        await cache.setAll(response.flags)
        updateSnapshot(response.flags)

        // Update current context and data sources
        lock.lock()
        currentContext = context
        let stream = streamingDataSource
        let poller = pollingDataSource
        lock.unlock()
        stream?.updateContext(context)
        poller?.updateContext(context)
    }

    // MARK: - Track

    /// Enqueues a custom analytics event.
    public func track(_ eventName: String, metadata: [String: AnyCodableValue]? = nil) {
        guard !isTestClient else { return }

        lock.lock()
        let userId = currentContext["user_id"]
        lock.unlock()

        let event = SdkEvent(
            type: "Custom",
            flagKey: eventName,
            userId: userId,
            variation: nil,
            timestamp: Self.isoFormatter.string(from: Date()),
            metadata: metadata
        )
        Task {
            await eventProcessor.enqueue(event)
        }
    }

    // MARK: - Flush

    /// Force-flushes pending analytics events.
    public func flush() async {
        guard !isTestClient else { return }
        await eventProcessor.flush()
    }

    // MARK: - Testing

    /// Creates a no-network test client with static flag overrides.
    public static func forTesting(_ overrides: [String: Any]) -> FeatureflipClient {
        FeatureflipClient(overrides: overrides)
    }

    /// Internal variant for unit testing with a custom HTTP loader.
    internal static func forTesting(_ overrides: [String: Any], loader: HTTPDataLoader) -> FeatureflipClient {
        FeatureflipClient(overrides: overrides, loader: loader)
    }

    // MARK: - Internal

    /// Returns all current flag values.
    internal func allFlags() -> [String: FlagValue] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return flagSnapshot
    }

    // MARK: - Private

    private func getFlag(_ key: String) -> FlagValue? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return flagSnapshot[key]
    }

    private func updateSnapshot(_ flags: [String: FlagValue]) {
        snapshotLock.lock()
        flagSnapshot = flags
        snapshotLock.unlock()
    }

    private func mergeSnapshot(_ delta: [String: FlagValue]) {
        snapshotLock.lock()
        for (key, value) in delta {
            if value.reason == "FLAG_REMOVED" && value.value == .null {
                flagSnapshot.removeValue(forKey: key)
            } else {
                flagSnapshot[key] = value
            }
        }
        snapshotLock.unlock()
    }

    internal func startDataSource() {
        lock.lock()
        let ctx = currentContext
        lock.unlock()

        if config.streaming {
            let source = StreamingDataSource(
                baseUrl: config.baseUrl,
                clientKey: config.clientKey,
                context: ctx,
                onChange: { [weak self] flags in
                    self?.handleStreamUpdate(flags)
                }
            )
            source.start()
            lock.lock()
            streamingDataSource = source
            lock.unlock()
        } else {
            startPolling()
        }
    }

    internal func startPolling() {
        lock.lock()
        let ctx = currentContext
        lock.unlock()

        let source = PollingDataSource(
            httpClient: httpClient,
            context: ctx,
            interval: config.pollInterval,
            onChange: { [weak self] flags in
                self?.handleFullUpdate(flags)
            }
        )
        source.start()
        lock.lock()
        pollingDataSource = source
        lock.unlock()
    }

    private func handleStreamUpdate(_ flags: [String: FlagValue]) {
        mergeSnapshot(flags)
        Task {
            await cache.merge(flags)
        }
        Task { @MainActor in
            self.flagProvider.updateFlags()
        }
    }

    private func handleFullUpdate(_ flags: [String: FlagValue]) {
        updateSnapshot(flags)
        Task {
            await cache.setAll(flags)
        }
        Task { @MainActor in
            self.flagProvider.updateFlags()
        }
    }

    /// Exposed for testing — applies a delta update to the in-memory snapshot.
    internal func applyFlagUpdate(_ flags: [String: FlagValue]) {
        handleStreamUpdate(flags)
    }

    private func handleForeground() {
        lock.lock()
        let stream = streamingDataSource
        let poller = pollingDataSource
        lock.unlock()
        stream?.start()
        poller?.start()
    }

    private func handleBackground() {
        lock.lock()
        let stream = streamingDataSource
        let poller = pollingDataSource
        lock.unlock()
        stream?.stop()
        poller?.stop()
        Task {
            await eventProcessor.flush()
        }
    }
}
