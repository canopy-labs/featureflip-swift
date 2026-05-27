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

    /// Whether the client has been initialized.
    public var isInitialized: Bool {
        core.isInitialized
    }

    /// Initializes the client: loads disk cache, fetches flags, starts streaming/polling.
    /// Idempotent on the shared core.
    public func initialize() async {
        await core.initialize()
    }

    /// Flushes pending events and releases this handle's reference to the shared core.
    /// The core shuts down only when the last handle releases.
    public func close() async {
        let alreadyClosed: Bool = closeLock.withLock {
            if closed { return true }
            closed = true
            return false
        }
        guard !alreadyClosed else { return }
        await core.close()
        core.release()
    }

    // MARK: - Variation methods

    public func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        core.boolVariation(key, default: defaultValue)
    }

    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        core.stringVariation(key, default: defaultValue)
    }

    public func numberVariation(_ key: String, default defaultValue: Double) -> Double {
        core.numberVariation(key, default: defaultValue)
    }

    public func jsonVariation(_ key: String, default defaultValue: AnyCodableValue) -> AnyCodableValue {
        core.jsonVariation(key, default: defaultValue)
    }

    /// Returns the full evaluation detail for a flag (value, variation, reason, prerequisiteKey),
    /// or `nil` if the flag is not present in the current snapshot. Mirrors the
    /// `flagDetail` accessor on the browser and Android SDKs.
    public func flagDetail(_ key: String) -> FlagValue? {
        core.getFlag(key)
    }

    // MARK: - Identify

    public func identify(context: [String: String]) async throws {
        try await core.identify(context: context)
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
    public static func forTesting(_ overrides: [String: Any]) -> FeatureflipClient {
        FeatureflipClient(core: SharedFeatureflipCore.createForTestingStub(overrides))
    }

    /// Internal variant for unit testing with a custom HTTP loader.
    internal static func forTesting(_ overrides: [String: Any], loader: HTTPDataLoader) -> FeatureflipClient {
        FeatureflipClient(core: SharedFeatureflipCore.forTesting(overrides, loader: loader))
    }

    // MARK: - Internal

    /// Returns all current flag values.
    internal func allFlags() -> [String: FlagValue] {
        core.allFlags()
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
