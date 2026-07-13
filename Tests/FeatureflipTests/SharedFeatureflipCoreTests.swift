import XCTest
@testable import Featureflip

/// In-memory `AnonymousKeyStore` for tests — avoids touching `UserDefaults`.
private final class MemoryAnonymousKeyStore: AnonymousKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String? = nil) { self.value = initial }
    func read() -> String? { lock.withLock { value } }
    func write(_ v: String) { lock.withLock { value = v } }
}

final class SharedFeatureflipCoreTests: XCTestCase {

    func testNewCoreStartsAtRefcountOne() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertEqual(core.refCount, 1)
        core.release()
    }

    func testAcquireIncrementsRefcount() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertTrue(core.acquire())
        XCTAssertEqual(core.refCount, 2)
        core.release()
        core.release()
    }

    func testReleaseDecrementsRefcount() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        _ = core.acquire() // 2
        core.release()     // 1
        XCTAssertEqual(core.refCount, 1)
        core.release()     // 0, shut down
    }

    func testReleaseAtZeroMarksCoreShutDown() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release()
        XCTAssertTrue(core.isShutDown)
    }

    func testAcquireAfterShutdownReturnsFalse() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release()
        XCTAssertFalse(core.acquire())
        XCTAssertEqual(core.refCount, 0)
    }

    func testAcquireAfterOverReleaseReturnsFalse() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release() // 1->0
        core.release() // over-release, no-op
        XCTAssertFalse(core.acquire())
        XCTAssertTrue(core.isShutDown)
    }

    func testGetFlagReturnsNilForMissingKey() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertNil(core.getFlag("nonexistent"))
        core.release()
    }

    func testForTestingOverridesReturnFixedValues() {
        let core = SharedFeatureflipCore.createForTestingStub(["dark-mode": true, "theme": "blue"])
        XCTAssertEqual(core.boolVariation("dark-mode", default: false), true)
        XCTAssertEqual(core.stringVariation("theme", default: "default"), "blue")
        XCTAssertEqual(core.boolVariation("missing", default: false), false)
        core.release()
    }

    // MARK: - Streaming -> polling fallback tears down the dormant stream

    func testStreamingFallbackStopsAndNullsStreamThenStartsPolling() {
        let loader = MockHTTPLoader()
        // The fallback poller's immediate poll returns an empty snapshot.
        loader.enqueue(statusCode: 200, body: #"{"flags":{}}"#.data(using: .utf8)!)

        let config = FeatureflipConfig(
            clientKey: "fallback-key",
            baseUrl: "https://localhost",
            streaming: true,
            pollInterval: 300
        )
        let core = SharedFeatureflipCore(
            config: config,
            loader: loader,
            anonymousKeyStore: MemoryAnonymousKeyStore()
        )

        // streaming = true creates and starts a live SSE source.
        core.startDataSource()
        XCTAssertTrue(core.hasStreamingSource)

        // Simulate the stream exhausting its retries (the onMaxRetriesReached callback).
        core.handleStreamingFallback()

        // The dormant stream must be torn down so a later foreground/identify cannot
        // resurrect it alongside the poller (both live -> stale-overwrite flicker).
        XCTAssertFalse(core.hasStreamingSource, "streaming source should be stopped and nulled on fallback")
        XCTAssertTrue(core.hasPollingSource, "polling should take over after fallback")

        core.release()
    }
}
