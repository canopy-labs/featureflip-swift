import Foundation
#if canImport(Combine)
import Combine
#endif

/// Main public API for the Featureflip SDK.
/// Each instance is a thin handle over a shared, refcounted core.
/// Two clients created with the same `clientKey` share one underlying core.
public final class FeatureflipClient: @unchecked Sendable {
    /// SDK version.
    public static let version = "2.0.0"

    // MARK: - Handle state

    private let core: SharedFeatureflipCore
    private let closeLock = NSLock()
    private var closed = false

    /// SwiftUI integration provider. Created per-handle.
    public private(set) var flagProvider: FeatureFlagProvider!

    // MARK: - Init (via cache)

    /// Creates (or retrieves) a client for the given configuration.
    /// Two calls with the same `clientKey` share one underlying core.
    public init(config: FeatureflipConfig) {
        self.core = _getOrCreateCore(config: config)
        self.flagProvider = FeatureFlagProvider(client: self)
        self.core.onFlagsChanged = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.flagProvider.updateFlags()
            }
        }
    }

    /// Internal init for unit testing with a custom HTTP loader.
    internal init(config: FeatureflipConfig, loader: HTTPDataLoader) {
        self.core = _getOrCreateCore(config: config, loader: loader)
        self.flagProvider = FeatureFlagProvider(client: self)
        self.core.onFlagsChanged = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.flagProvider.updateFlags()
            }
        }
    }

    /// Private init wrapping a standalone core (for test clients).
    private init(core: SharedFeatureflipCore) {
        self.core = core
        self.flagProvider = FeatureFlagProvider(client: self)
    }

    // MARK: - Lifecycle

    /// Whether this handle is closed. Read under `closeLock`, like every other
    /// access to `closed` — `close()` can run concurrently with an evaluation.
    private var isClosed: Bool {
        closeLock.withLock { closed }
    }

    /// Whether the client has been initialized.
    ///
    /// False once this handle is closed: `close()` releases the core, so the handle
    /// can no longer evaluate anything (#2327).
    public var isInitialized: Bool {
        !isClosed && core.isInitialized
    }

    /// Initializes the client: loads disk cache, fetches flags, starts streaming/polling.
    /// Idempotent on the shared core.
    public func initialize() async {
        await core.initialize()
    }

    /// Flushes pending events and releases this handle's reference to the shared core.
    /// The core shuts down only when the last handle releases; other handles on the
    /// same `clientKey` keep updating and reporting reads (#3566).
    public func close() async {
        let alreadyClosed: Bool = closeLock.withLock {
            if closed { return true }
            closed = true
            return false
        }
        guard !alreadyClosed else { return }
        await core.closeHandle()
    }

    // MARK: - Variation methods
    //
    // A closed handle serves the caller's default (#2327, contract from #2313).
    // close() gives up this handle's share of the core, but the core's in-memory
    // snapshot stays readable — frozen for good if this was the last handle — so
    // without these guards a closed handle would keep serving flags.

    public func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        guard !isClosed else { return defaultValue }
        return core.boolVariation(key, default: defaultValue)
    }

    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        guard !isClosed else { return defaultValue }
        return core.stringVariation(key, default: defaultValue)
    }

    public func numberVariation(_ key: String, default defaultValue: Double) -> Double {
        guard !isClosed else { return defaultValue }
        return core.numberVariation(key, default: defaultValue)
    }

    public func jsonVariation(_ key: String, default defaultValue: AnyCodableValue) -> AnyCodableValue {
        guard !isClosed else { return defaultValue }
        return core.jsonVariation(key, default: defaultValue)
    }

    /// Returns the full evaluation detail for a flag (value, variation, reason, prerequisiteKey),
    /// or `nil` if the flag is not present in the current snapshot. Mirrors the
    /// `flagDetail` accessor on the browser and Android SDKs.
    ///
    /// Counts as a read of the flag, like the typed variation methods.
    public func flagDetail(_ key: String) -> FlagValue? {
        guard !isClosed else { return nil }
        return core.flagDetail(key)
    }

    // MARK: - Identify

    public func identify(context: [String: Any]) async throws {
        // Converted at the boundary, like FeatureflipConfig's init (#2293).
        try await core.identify(context: context.mapValues { AnyCodableValue(any: $0) })
    }

    // MARK: - Track

    public func track(_ eventName: String, metadata: [String: AnyCodableValue]? = nil) {
        core.track(eventName, metadata: metadata)
    }

    // MARK: - Flush

    public func flush() async {
        await core.flush()
    }

    // MARK: - Testing

    /// Creates a no-network test client with static flag overrides.
    /// Bypasses the cache — each call returns an independent client.
    /// `inspectors` fire on the stub's variation accessors exactly as they do
    /// on a real client.
    public static func forTesting(
        _ overrides: [String: Any],
        inspectors: [EvaluationInspector] = []
    ) -> FeatureflipClient {
        FeatureflipClient(core: SharedFeatureflipCore.createForTestingStub(overrides, inspectors: inspectors))
    }

    /// Internal variant for unit testing with a custom HTTP loader.
    internal static func forTesting(
        _ overrides: [String: Any],
        loader: HTTPDataLoader,
        inspectors: [EvaluationInspector] = []
    ) -> FeatureflipClient {
        FeatureflipClient(core: SharedFeatureflipCore.forTesting(overrides, loader: loader, inspectors: inspectors))
    }

    // MARK: - Internal

    /// Returns all current flag values, or an empty dictionary once closed — the
    /// bulk-read analogue of a variation falling back to its default.
    ///
    /// Not a read: see `SharedFeatureflipCore.allFlags()`.
    internal func allFlags() -> [String: FlagValue] {
        guard !isClosed else { return [:] }
        return core.allFlags()
    }

    /// Exposed for testing — applies a delta update to the in-memory snapshot.
    internal func applyFlagUpdate(_ flags: [String: FlagValue]) {
        core.applyFlagUpdate(flags)
    }

    /// Exposes startDataSource for tests that need to restart the data source after close.
    internal func startDataSource() {
        core.startDataSource()
    }
}
