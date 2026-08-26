import XCTest
@testable import Featureflip

/// Regression guards for #2477: a concurrent `flush()` must WAIT for the drain
/// already running, not return while it is still in flight.
///
/// #2456 gave this actor a `draining` guard, which closed the two-request-streams
/// half of the problem but settled the caller-facing question the other way from
/// every other SDK: js and node have always returned the in-flight promise, so
/// `await flush()` there resolves only once the send has settled. A caller that
/// awaited `flush()` is asking for its events to be sent, and returning early is a
/// promise the SDK has not kept.
final class EventFlushCoalescingTests: XCTestCase {

    /// An async gate, so parking a request never blocks a cooperative thread.
    ///
    /// A `DispatchSemaphore` here would block one of the pool's threads for the
    /// duration of the park, which can wedge the very tasks the test is waiting on.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    /// Records whether the test had released the gate by the time a task observed it.
    private actor ReleaseFlag {
        private var released = false
        func markReleased() { released = true }
        func value() -> Bool { released }
    }

    /// A loader that parks its FIRST request until the gate opens, and records the
    /// greatest number of requests ever in flight at the same moment.
    private final class ParkingHTTPLoader: HTTPDataLoader, @unchecked Sendable {
        let gate = Gate()
        let arrived = Gate()

        private let lock = NSLock()
        private var inFlight = 0
        private var peakInFlight = 0
        private var parked = false
        private var deliveredCount = 0

        var peak: Int { lock.withLock { peakInFlight } }
        var delivered: Int { lock.withLock { deliveredCount } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let hold: Bool = lock.withLock {
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
                // Only the very FIRST request is parked; re-parking a later one would
                // wait on a gate nothing opens again and hang the test.
                let first = !parked
                parked = true
                return first
            }

            if hold {
                await arrived.open()
                await gate.wait()
            }

            lock.withLock {
                inFlight -= 1
                deliveredCount += 1
            }

            let response = HTTPURLResponse(
                url: URL(string: "https://test.com")!,
                statusCode: 202,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    private func makeEvent(_ key: String) -> SdkEvent {
        SdkEvent(
            type: "Custom",
            flagKey: key,
            userId: "u1",
            variation: nil,
            timestamp: "2025-01-01T00:00:00Z",
            metadata: nil
        )
    }

    /// A batch size above what the test enqueues, so the size trigger never fires and
    /// every drain under test is one the test started deliberately.
    private func makeProcessor(loader: ParkingHTTPLoader) -> EventProcessor {
        let httpClient = HttpClient(baseUrl: "https://test.com", clientKey: "csk_t", loader: loader)
        return EventProcessor(
            httpClient: httpClient,
            flushInterval: 3600,
            batchSize: 100,
            maxBufferSize: EventProcessor.defaultMaxBufferSize
        )
    }

    func testAConcurrentFlushWaitsForTheInFlightDrain() async {
        let loader = ParkingHTTPLoader()
        let processor = makeProcessor(loader: loader)
        for index in 0..<6 {
            await processor.enqueue(makeEvent("flag-\(index)"))
        }

        let first = Task { await processor.flush() }
        // The first request is parked inside the loader, so the drain is provably
        // mid-flight and anything arriving next came from a second one.
        await loader.arrived.wait()

        let releaseFlag = ReleaseFlag()
        let second = Task { () -> Bool in
            await processor.flush()
            return await releaseFlag.value()
        }

        // Room for the second caller to return early if it is going to.
        try? await Task.sleep(nanoseconds: 200_000_000)

        await releaseFlag.markReleased()
        await loader.gate.open()

        let secondSawRelease = await second.value
        await first.value

        XCTAssertEqual(loader.peak, 1, "a second drain loop ran alongside the first")
        XCTAssertTrue(
            secondSawRelease,
            "flush() returned before the in-flight drain finished; a caller that awaited it is asking for its events to be sent"
        )
        let remaining = await processor.bufferedEventCount()
        XCTAssertEqual(remaining, 0)
    }

    /// `stop()` is the last drain there will ever be, so it must keep bypassing
    /// coalescing: awaiting an in-flight drain and returning would discard the buffer
    /// unsent.
    func testStopStillDrainsWhileAFlushIsInFlight() async {
        let loader = ParkingHTTPLoader()
        let processor = makeProcessor(loader: loader)
        await processor.enqueue(makeEvent("flag-1"))

        let first = Task { await processor.flush() }
        // flag-1 is now parked on the wire, so the drain is provably mid-flight.
        await loader.arrived.wait()

        // Queued behind the parked request, so only a drain that actually runs during
        // shutdown can deliver it.
        await processor.enqueue(makeEvent("flag-2"))

        // Released while stop() runs, so stop() genuinely overlaps the in-flight drain
        // rather than waiting it out first.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await loader.gate.open()
        }

        await processor.stop()
        // Awaited before asserting: the parked request completes on its own task, so
        // counting deliveries the moment stop() returns would be a race, not a check.
        await first.value

        XCTAssertEqual(loader.delivered, 2, "stop() lost events to coalescing")
    }
}
