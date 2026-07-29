import Foundation

/// The engine embeds the matched rule id in the reason as `rule-match:{id}`.
private let ruleMatchPrefix = "rule-match:"

/// Internal shared core that owns expensive resources (HTTP client, cache, event processor,
/// data sources). Refcounted — when the last handle releases, the core shuts down.
internal final class SharedFeatureflipCore: @unchecked Sendable {

    // MARK: - Refcount

    private let refcountLock = NSLock()
    private var _refCount = 1
    private var _isShutDown = false

    /// Current reference count (read under lock).
    var refCount: Int {
        refcountLock.withLock { _refCount }
    }

    /// Whether shutdown() has been called (read under lock).
    var isShutDown: Bool {
        refcountLock.withLock { _isShutDown }
    }

    /// Increments the reference count if the core is still alive.
    /// - Returns: `true` if successfully acquired, `false` if already shut down.
    @discardableResult
    func acquire() -> Bool {
        refcountLock.withLock {
            guard _refCount > 0 else { return false }
            _refCount += 1
            return true
        }
    }

    /// Decrements the reference count. Calls shutdown() exactly once when it hits zero.
    func release() {
        let shouldShutDown: Bool = refcountLock.withLock {
            guard _refCount > 0 else { return false }
            _refCount -= 1
            if _refCount == 0 && !_isShutDown {
                _isShutDown = true
                return true
            }
            return false
        }
        if shouldShutDown {
            shutdown()
        }
    }

    // MARK: - Properties

    let config: FeatureflipConfig
    let isTestClient: Bool

    private let snapshotLock = NSLock()
    private var flagSnapshot: [String: FlagValue] = [:]

    private let lock = NSLock()
    private var _initialized = false
    private var _initTask: Task<Void, Never>?

    /// Mutable context updated by identify(), protected by `lock`.
    var currentContext: [String: String] {
        get { lock.withLock { _currentContext } }
        set { lock.withLock { _currentContext = newValue } }
    }
    private var _currentContext: [String: String]

    /// Whether the core has been initialized.
    var isInitialized: Bool {
        lock.withLock { _initialized }
    }

    /// Callback invoked when flags change (stream or poll update).
    /// The FeatureflipClient handle sets this to update its own FeatureFlagProvider.
    var onFlagsChanged: (() -> Void)?

    /// Shared date formatter for event timestamps.
    static let isoFormatter = ISO8601DateFormatter()

    // MARK: - HTTP / Lifecycle

    private let httpClient: HttpClient
    private let cache: FlagCache
    let eventProcessor: EventProcessor
    private var streamingDataSource: StreamingDataSource?
    private var pollingDataSource: PollingDataSource?
    private var lifecycleObserver: LifecycleObserver?
    private let anonymousKeyStore: AnonymousKeyStore

    // MARK: - Production Init

    /// Creates a new core with real HTTP transport.
    init(config: FeatureflipConfig, anonymousKeyStore: AnonymousKeyStore = UserDefaultsAnonymousKeyStore()) {
        self.config = config
        self.httpClient = HttpClient(baseUrl: config.baseUrl, clientKey: config.clientKey)
        self.cache = FlagCache(clientKey: config.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: config.flushInterval,
            batchSize: config.flushBatchSize
        )
        self.isTestClient = false
        self.anonymousKeyStore = anonymousKeyStore
        self._currentContext = resolveAnonymousContext(config.context, store: anonymousKeyStore)
    }

    /// Internal init for unit testing with a custom HTTP loader.
    init(config: FeatureflipConfig, loader: HTTPDataLoader, anonymousKeyStore: AnonymousKeyStore = UserDefaultsAnonymousKeyStore()) {
        self.config = config
        self.httpClient = HttpClient(baseUrl: config.baseUrl, clientKey: config.clientKey, loader: loader)
        self.cache = FlagCache(clientKey: config.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: config.flushInterval,
            batchSize: config.flushBatchSize
        )
        self.isTestClient = false
        self.anonymousKeyStore = anonymousKeyStore
        self._currentContext = resolveAnonymousContext(config.context, store: anonymousKeyStore)
    }

    /// Private init for test clients with static overrides.
    /// `inspectors` is threaded through so a stub client honors them exactly
    /// like a real one — a test-only client that silently dropped them would
    /// make inspector code untestable.
    private init(overrides: [String: Any], loader: HTTPDataLoader? = nil, inspectors: [EvaluationInspector] = []) {
        let dummyConfig = FeatureflipConfig(clientKey: "test-key", baseUrl: "https://localhost", inspectors: inspectors)
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
        self.anonymousKeyStore = UserDefaultsAnonymousKeyStore()
        self._currentContext = dummyConfig.context

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
        snapshotLock.withLock {
            flagSnapshot = snapshot
        }
        lock.withLock {
            _initialized = true
        }
    }

    /// Private init for test skeletons (refcount tests) — no resources.
    private init(skeletonConfig: FeatureflipConfig) {
        self.config = skeletonConfig
        self.httpClient = HttpClient(baseUrl: skeletonConfig.baseUrl, clientKey: skeletonConfig.clientKey)
        self.cache = FlagCache(clientKey: skeletonConfig.clientKey)
        self.eventProcessor = EventProcessor(
            httpClient: httpClient,
            flushInterval: skeletonConfig.flushInterval,
            batchSize: skeletonConfig.flushBatchSize
        )
        self.isTestClient = true
        self.anonymousKeyStore = UserDefaultsAnonymousKeyStore()
        self._currentContext = skeletonConfig.context
        lock.withLock {
            _initialized = true
        }
    }

    // MARK: - Lifecycle

    /// Initializes the core: loads disk cache, fetches flags, starts streaming/polling.
    /// Idempotent — first call does real work, concurrent/subsequent callers await
    /// the same Task (CountDownLatch equivalent per CLAUDE.md).
    func initialize() async {
        guard !isTestClient else { return }

        let task: Task<Void, Never> = lock.withLock {
            if let existing = _initTask { return existing }
            let t = Task {
                await self.doInitialize()
            }
            _initTask = t
            return t
        }
        await task.value
    }

    private func doInitialize() async {
        // Load persisted cache
        await cache.loadFromDisk()
        let cached = await cache.all()
        if !cached.isEmpty {
            updateSnapshot(cached)
        }

        // Fetch initial flags with initTimeout applied. Use currentContext (not
        // config.context) so the persisted anonymous user_id resolved at init is
        // sent on the first evaluate.
        do {
            let response = try await httpClient.evaluate(context: currentContext, timeout: config.initTimeout)
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
        lock.withLock {
            lifecycleObserver = observer
            _initialized = true
        }
    }

    /// Stops streaming/polling and flushes pending events.
    func close() async {
        let (stream, poller): (StreamingDataSource?, PollingDataSource?) = lock.withLock {
            let s = streamingDataSource
            let p = pollingDataSource
            streamingDataSource = nil
            pollingDataSource = nil
            lifecycleObserver = nil
            return (s, p)
        }

        stream?.stop()
        poller?.stop()
        await eventProcessor.stop()
    }

    // MARK: - Variation methods (synchronous)

    /// Returns a boolean flag value, or the default if the flag is missing or not a boolean.
    func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        let flag = getFlag(key)
        var value = defaultValue
        if let flag = flag, case .bool(let v) = flag.value {
            value = v
        }
        notifyInspectors(key, flag, .bool(value))
        return value
    }

    /// Returns a string flag value, or the default if the flag is missing or not a string.
    func stringVariation(_ key: String, default defaultValue: String) -> String {
        let flag = getFlag(key)
        var value = defaultValue
        if let flag = flag, case .string(let v) = flag.value {
            value = v
        }
        notifyInspectors(key, flag, .string(value))
        return value
    }

    /// Returns a numeric flag value as Double, or the default if the flag is missing or not numeric.
    func numberVariation(_ key: String, default defaultValue: Double) -> Double {
        let flag = getFlag(key)
        var value = defaultValue
        if let flag = flag {
            switch flag.value {
            case .double(let v): value = v
            case .int(let v): value = Double(v)
            default: break
            }
        }
        notifyInspectors(key, flag, .double(value))
        return value
    }

    /// Returns the raw flag value, or the default if the flag is missing.
    func jsonVariation(_ key: String, default defaultValue: AnyCodableValue) -> AnyCodableValue {
        let flag = getFlag(key)
        let value = flag?.value ?? defaultValue
        notifyInspectors(key, flag, value)
        return value
    }

    /// Fire the registered inspectors. Called once per variation call, after
    /// type coercion, so `value` is exactly what the accessor returns.
    ///
    /// Per-inspector error isolation is structural here: `EvaluationInspector`
    /// is a non-throwing function type, so an inspector cannot break the
    /// returned value or stop its siblings — there is nothing to catch.
    private func notifyInspectors(_ key: String, _ flag: FlagValue?, _ value: AnyCodableValue) {
        let inspectors = config.inspectors
        guard !inspectors.isEmpty, !isShutDown else { return }

        // The flag is absent from the snapshot (unknown key, not yet
        // initialized, or not clientSideVisible). The server never sent a reason
        // for it, so synthesize one in the same kebab-case as the rest.
        let reason = flag?.reason ?? "flag-not-found"
        var ruleId: String?
        if reason.hasPrefix(ruleMatchPrefix) {
            let suffix = String(reason.dropFirst(ruleMatchPrefix.count))
            ruleId = suffix.isEmpty ? nil : suffix
        }

        let event = EvaluationEvent(
            flagKey: key,
            // Value-type copy — Swift dictionaries are copy-on-write, so a
            // buggy inspector cannot mutate core state. Uses the same
            // anon-id-resolved context the flags were evaluated against.
            context: currentContext,
            value: value,
            variationKey: flag?.variation,
            reason: reason,
            ruleId: ruleId,
            prerequisiteKey: flag?.prerequisiteKey,
            timestamp: Self.isoFormatter.string(from: Date())
        )

        for inspector in inspectors {
            inspector(event)
        }
    }

    // MARK: - Identify

    /// Re-evaluates flags for a new user context.
    func identify(context: [String: String]) async throws {
        guard !isTestClient else { return }

        let resolved = resolveAnonymousContext(context, store: anonymousKeyStore)
        let response = try await httpClient.identify(context: resolved)
        await cache.setAll(response.flags)
        updateSnapshot(response.flags)

        // Update current context and data sources
        let (stream, poller): (StreamingDataSource?, PollingDataSource?) = lock.withLock {
            _currentContext = resolved
            return (streamingDataSource, pollingDataSource)
        }
        stream?.updateContext(resolved)
        poller?.updateContext(resolved)
    }

    // MARK: - Track

    /// Enqueues a custom analytics event.
    func track(_ eventName: String, metadata: [String: AnyCodableValue]? = nil) {
        guard !isTestClient else { return }

        let userId = lock.withLock { _currentContext["user_id"] }

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
    func flush() async {
        guard !isTestClient else { return }
        await eventProcessor.flush()
    }

    // MARK: - Snapshot accessors

    /// Returns a single flag value by key.
    func getFlag(_ key: String) -> FlagValue? {
        snapshotLock.withLock { flagSnapshot[key] }
    }

    /// Returns all current flag values.
    func allFlags() -> [String: FlagValue] {
        snapshotLock.withLock { flagSnapshot }
    }

    /// Replaces the entire snapshot.
    func updateSnapshot(_ flags: [String: FlagValue]) {
        snapshotLock.withLock {
            flagSnapshot = flags
        }
    }

    /// Merges a delta into the snapshot, removing FLAG_REMOVED entries.
    func mergeSnapshot(_ delta: [String: FlagValue]) {
        snapshotLock.withLock {
            for (key, value) in delta {
                if value.reason == "FLAG_REMOVED" && value.value == .null {
                    flagSnapshot.removeValue(forKey: key)
                } else {
                    flagSnapshot[key] = value
                }
            }
        }
    }

    /// Applies a delta update: merges into snapshot, merges into cache, notifies listeners.
    func applyFlagUpdate(_ flags: [String: FlagValue]) {
        handleStreamUpdate(flags)
    }

    // MARK: - Data source management

    func startDataSource() {
        let ctx = lock.withLock { _currentContext }

        if config.streaming {
            let source = StreamingDataSource(
                baseUrl: config.baseUrl,
                clientKey: config.clientKey,
                context: ctx,
                onChange: { [weak self] flags in
                    self?.handleStreamUpdate(flags)
                },
                // First flags-updated after (re)connect is the full snapshot -> REPLACE.
                onSnapshot: { [weak self] flags in
                    self?.handleFullUpdate(flags)
                },
                // Stream exhausted its retries -> fall back to polling (retries forever).
                onMaxRetriesReached: { [weak self] in
                    self?.handleStreamingFallback()
                }
            )
            source.start()
            lock.withLock {
                streamingDataSource = source
            }
        } else {
            startPolling()
        }
    }

    func startPolling() {
        // Idempotent: a stream->polling fallback must start at most one poller.
        if lock.withLock({ pollingDataSource != nil }) { return }
        let ctx = lock.withLock { _currentContext }

        let source = PollingDataSource(
            httpClient: httpClient,
            context: ctx,
            interval: config.pollInterval,
            onChange: { [weak self] flags in
                self?.handleFullUpdate(flags)
            }
        )
        source.start()
        lock.withLock {
            pollingDataSource = source
        }
    }

    /// Streaming exhausted its retries: tear down the dormant streaming source
    /// before falling back to polling (which retries forever). Stopping and
    /// nulling the stream keeps a later `handleForeground()`/`identify()` from
    /// resurrecting it alongside the poller — two live sources racing stale
    /// deltas over fresh poll snapshots. Mirrors Flutter's
    /// `_handleStreamingFallback`. Safe to call from within the stream's
    /// `onMaxRetriesReached` callback: `stop()` only cancels the Task, not join.
    func handleStreamingFallback() {
        let stream: StreamingDataSource? = lock.withLock {
            let s = streamingDataSource
            streamingDataSource = nil
            return s
        }
        stream?.stop()
        startPolling()
    }

    /// Test-only: whether a streaming source is currently held.
    var hasStreamingSource: Bool { lock.withLock { streamingDataSource != nil } }

    /// Test-only: whether a polling source is currently held.
    var hasPollingSource: Bool { lock.withLock { pollingDataSource != nil } }

    private func handleStreamUpdate(_ flags: [String: FlagValue]) {
        mergeSnapshot(flags)
        Task {
            await cache.merge(flags)
        }
        onFlagsChanged?()
    }

    private func handleFullUpdate(_ flags: [String: FlagValue]) {
        updateSnapshot(flags)
        Task {
            await cache.setAll(flags)
        }
        onFlagsChanged?()
    }

    func handleForeground() {
        let (stream, poller): (StreamingDataSource?, PollingDataSource?) = lock.withLock {
            (streamingDataSource, pollingDataSource)
        }
        stream?.start()
        poller?.start()
    }

    func handleBackground() {
        let (stream, poller): (StreamingDataSource?, PollingDataSource?) = lock.withLock {
            (streamingDataSource, pollingDataSource)
        }
        stream?.stop()
        poller?.stop()
        Task {
            await eventProcessor.flush()
        }
    }

    // MARK: - Shutdown (called by release() at refcount zero)

    private func shutdown() {
        // Remove from cache
        _liveCoresLock.withLock {
            if _liveCores[config.clientKey] === self {
                _liveCores.removeValue(forKey: config.clientKey)
            }
        }
        // Stop data sources (idempotent if close() already called)
        lock.withLock {
            streamingDataSource?.stop()
            pollingDataSource?.stop()
            streamingDataSource = nil
            pollingDataSource = nil
            lifecycleObserver = nil
        }
        Task {
            await eventProcessor.stop()
        }
    }

    // MARK: - Test support factories

    /// Creates a minimal core for refcount tests — no real resources.
    static func createForTestingSkeleton(config: FeatureflipConfig? = nil) -> SharedFeatureflipCore {
        let cfg = config ?? FeatureflipConfig(clientKey: "test-key", baseUrl: "https://localhost")
        return SharedFeatureflipCore(skeletonConfig: cfg)
    }

    /// Creates a test core with static flag overrides — NOT via cache.
    static func createForTestingStub(
        _ overrides: [String: Any],
        inspectors: [EvaluationInspector] = []
    ) -> SharedFeatureflipCore {
        SharedFeatureflipCore(overrides: overrides, inspectors: inspectors)
    }

    /// Internal variant for unit testing with a custom HTTP loader.
    static func forTesting(
        _ overrides: [String: Any],
        loader: HTTPDataLoader,
        inspectors: [EvaluationInspector] = []
    ) -> SharedFeatureflipCore {
        SharedFeatureflipCore(overrides: overrides, loader: loader, inspectors: inspectors)
    }
}

// MARK: - Module-level cache

private var _liveCores: [String: SharedFeatureflipCore] = [:]
private let _liveCoresLock = NSLock()

internal func _getOrCreateCore(config: FeatureflipConfig) -> SharedFeatureflipCore {
    _liveCoresLock.withLock {
        if let existing = _liveCores[config.clientKey], existing.acquire() {
            return existing
        }
        let newCore = SharedFeatureflipCore(config: config)
        _liveCores[config.clientKey] = newCore
        return newCore
    }
}

internal func _getOrCreateCore(config: FeatureflipConfig, loader: HTTPDataLoader) -> SharedFeatureflipCore {
    _liveCoresLock.withLock {
        if let existing = _liveCores[config.clientKey], existing.acquire() {
            return existing
        }
        let newCore = SharedFeatureflipCore(config: config, loader: loader)
        _liveCores[config.clientKey] = newCore
        return newCore
    }
}

internal func _getOrCreateCoreForTesting(clientKey: String) -> SharedFeatureflipCore {
    let config = FeatureflipConfig(clientKey: clientKey, baseUrl: "https://localhost")
    return _liveCoresLock.withLock {
        if let existing = _liveCores[clientKey], existing.acquire() {
            return existing
        }
        let newCore = SharedFeatureflipCore.createForTestingSkeleton(config: config)
        _liveCores[clientKey] = newCore
        return newCore
    }
}

internal var _liveCoresCount: Int {
    _liveCoresLock.withLock { _liveCores.count }
}

internal func _resetForTesting() {
    let cores: [SharedFeatureflipCore] = _liveCoresLock.withLock {
        let c = Array(_liveCores.values)
        _liveCores.removeAll()
        return c
    }
    for core in cores {
        core.release()
    }
}
