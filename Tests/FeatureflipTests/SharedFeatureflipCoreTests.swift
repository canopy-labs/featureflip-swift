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

    // MARK: - Streaming -> polling fallback is additive, and retired on recovery

    func testStreamingFallbackKeepsTheStreamAndIsRetiredOnRecovery() {
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

        // Simulate the stream exhausting its retries (the onFallbackToPolling callback).
        core.handleStreamingFallback()

        // The stream is KEPT: it is still retrying underneath, and polling only covers
        // the outage until it comes back. Nulling it here is what used to make the
        // fallback permanent — nothing would ever have restarted streaming (#3075).
        XCTAssertTrue(
            core.hasStreamingSource,
            "streaming source must survive the fallback so it can still recover"
        )
        XCTAssertTrue(core.hasPollingSource, "polling should cover the outage")

        // A second arming must not leak a second poller.
        core.handleStreamingFallback()
        XCTAssertTrue(core.hasPollingSource)

        // Simulate the stream delivering a frame again (the onStreamRecovered callback).
        core.stopFallbackPolling()

        XCTAssertFalse(
            core.hasPollingSource,
            "the fallback poller must be retired once the stream recovers"
        )
        XCTAssertTrue(core.hasStreamingSource)

        // The reference is cleared too, so a later outage falls back again rather than
        // finding a dead poller parked there.
        loader.enqueue(statusCode: 200, body: #"{"flags":{}}"#.data(using: .utf8)!)
        core.handleStreamingFallback()
        XCTAssertTrue(
            core.hasPollingSource,
            "a second outage must be covered by a fresh poller"
        )

        core.release()
    }

    func testClosingOneOfTwoHandlesKeepsTheSharedDataSourceRunning() async {
        let loader = MockHTTPLoader()
        // The poller's immediate first poll.
        loader.enqueue(statusCode: 200, body: #"{"flags":{}}"#.data(using: .utf8)!)
        let config = FeatureflipConfig(
            clientKey: "close-one-of-two",
            baseUrl: "https://localhost",
            streaming: false,
            pollInterval: 300
        )
        let first = _getOrCreateCore(config: config, loader: loader)
        let second = _getOrCreateCore(config: config, loader: loader)
        XCTAssertTrue(first === second)
        first.startDataSource()
        XCTAssertTrue(first.hasPollingSource)

        await first.closeHandle()

        XCTAssertTrue(
            second.hasPollingSource,
            "closing one handle must not stop the data source the other still uses (#3566)"
        )
        XCTAssertFalse(second.isShutDown)
        XCTAssertEqual(second.refCount, 1)
        let third = _getOrCreateCore(config: config, loader: loader)
        XCTAssertTrue(third === second, "the core must stay cached while a handle holds it")
        third.release()

        await second.closeHandle()

        XCTAssertFalse(second.hasPollingSource, "the last handle stops the data source")
        XCTAssertTrue(second.isShutDown)
        let fresh = _getOrCreateCore(config: config, loader: loader)
        XCTAssertFalse(fresh === second, "a shut-down core must leave the cache")
        fresh.release()
    }
}
