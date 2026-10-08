import XCTest
@testable import Featureflip

/// A monotonic clock a test moves by hand, so crossing a window needs no sleeping.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 1_000_000_000

    var now: UInt64 { lock.withLock { current } }

    func advance(seconds: Double) {
        lock.withLock { current += UInt64(seconds * 1_000_000_000) }
    }
}

/// A clock that returns a fixed sequence of values, then repeats the last.
final class SampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) { self.values = values }

    func next() -> UInt64 {
        lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
    }
}

/// Collects what a `ReadRecorder` hands its sink.
final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SdkEvent] = []

    func append(_ event: SdkEvent) {
        lock.withLock { events.append(event) }
    }

    var all: [SdkEvent] { lock.withLock { events } }
}

final class ReadRecorderTests: XCTestCase {

    private func makeRecorder(userId: String? = "u-1") -> (ReadRecorder, ManualClock, CapturedEvents) {
        let clock = ManualClock()
        let captured = CapturedEvents()
        let recorder = ReadRecorder(
            userId: userId,
            now: { clock.now },
            sink: { captured.append($0) }
        )
        return (recorder, clock, captured)
    }

    func testTheWindowIsOneHour() {
        XCTAssertEqual(ReadRecorder.defaultWindowNanos, 3_600_000_000_000)
    }

    func testFirstReadQueuesOneEvaluationEventWithTheWireShape() {
        let (recorder, _, captured) = makeRecorder()

        recorder.record(flagKey: "dark-mode", variation: "on")

        XCTAssertEqual(captured.all.count, 1)
        let event = captured.all[0]
        XCTAssertEqual(event.type, "Evaluation")
        XCTAssertEqual(event.flagKey, "dark-mode")
        XCTAssertEqual(event.variation, "on")
        XCTAssertEqual(event.userId, "u-1")
        XCTAssertNil(event.metadata)
        XCTAssertNotNil(SharedFeatureflipCore.isoFormatter.date(from: event.timestamp))
    }

    func testRepeatReadsInsideTheHourAreDropped() {
        let (recorder, clock, captured) = makeRecorder()

        for _ in 0..<50 {
            recorder.record(flagKey: "dark-mode", variation: "on")
        }
        clock.advance(seconds: 3_599.9)
        recorder.record(flagKey: "dark-mode", variation: "on")

        XCTAssertEqual(captured.all.count, 1)
    }

    func testAReaderWithAnEarlierClockSampleDoesNotRestartTheWindow() {
        // Models two racing readers: the one holding the later sample took the lock first.
        let samples = SampleQueue([2_000_000_000, 1_999_999_000, 1_999_999_500, 1_999_999_600])
        let captured = CapturedEvents()
        let recorder = ReadRecorder(userId: "u-1", now: { samples.next() }, sink: { captured.append($0) })

        recorder.record(flagKey: "a", variation: "on")  // starts the window at 2.0s
        recorder.record(flagKey: "a", variation: "on")  // earlier sample: still inside, deduped
        XCTAssertEqual(captured.all.count, 1)

        recorder.record(flagKey: "b", variation: "on")  // earlier sample: new flag, reported
        XCTAssertEqual(captured.all.count, 2)

        recorder.record(flagKey: "a", variation: "on")  // window was not reset: still deduped
        XCTAssertEqual(captured.all.count, 2)
    }

    func testTheFirstReadAfterTheHourStartsANewWindow() {
        let (recorder, clock, captured) = makeRecorder()

        recorder.record(flagKey: "dark-mode", variation: "on")
        clock.advance(seconds: 3_600)
        recorder.record(flagKey: "dark-mode", variation: "on")
        // The new window started at the second read, so this one is inside it.
        clock.advance(seconds: 1_800)
        recorder.record(flagKey: "dark-mode", variation: "on")

        XCTAssertEqual(captured.all.count, 2)
    }

    func testTheWindowIsNotTheFlushInterval() {
        // A 30 s flush must not re-report a read every 30 s: that is what the hourly
        // window exists to prevent.
        let (recorder, clock, captured) = makeRecorder()

        recorder.record(flagKey: "dark-mode", variation: "on")
        clock.advance(seconds: 31)
        recorder.record(flagKey: "dark-mode", variation: "on")

        XCTAssertEqual(captured.all.count, 1)
    }

    func testResetWindowReportsTheNextReadAgainWithoutTheClockMoving() {
        let (recorder, _, captured) = makeRecorder()

        recorder.record(flagKey: "dark-mode", variation: "on")
        recorder.record(flagKey: "dark-mode", variation: "on")
        recorder.resetWindow()
        recorder.record(flagKey: "dark-mode", variation: "on")
        recorder.record(flagKey: "dark-mode", variation: "on")

        XCTAssertEqual(captured.all.count, 2)
    }

    func testADifferentVariationIsASeparateEvent() {
        let (recorder, _, captured) = makeRecorder()

        recorder.record(flagKey: "theme", variation: "dark")
        recorder.record(flagKey: "theme", variation: "light")

        XCTAssertEqual(captured.all.map(\.variation), ["dark", "light"])
    }

    func testANewUserIsASeparateEventAndIsWhatLaterReadsReport() {
        let (recorder, _, captured) = makeRecorder()

        recorder.record(flagKey: "theme", variation: "dark")
        recorder.setUserId("u-2")
        recorder.record(flagKey: "theme", variation: "dark")
        recorder.record(flagKey: "theme", variation: "dark")
        // Switching back inside the window: u-1 already reported this read.
        recorder.setUserId("u-1")
        recorder.record(flagKey: "theme", variation: "dark")

        XCTAssertEqual(captured.all.map(\.userId), ["u-1", "u-2"])
    }

    func testAMissingFlagIsRecordedWithNoVariationAndDeduplicated() {
        let (recorder, _, captured) = makeRecorder()

        recorder.record(flagKey: "gone", variation: nil)
        recorder.record(flagKey: "gone", variation: nil)

        XCTAssertEqual(captured.all.count, 1)
        XCTAssertNil(captured.all[0].variation)
    }

    func testANilUserIsRecordedAsNil() {
        let (recorder, _, captured) = makeRecorder(userId: nil)

        recorder.record(flagKey: "theme", variation: "dark")

        XCTAssertEqual(captured.all.count, 1)
        XCTAssertNil(captured.all[0].userId)
    }

    func testConcurrentReadsQueueExactlyOneEventPerRead() {
        let (recorder, _, captured) = makeRecorder()

        // The variation methods are synchronous and callable from any thread. Without
        // the lock this either crashes on the dictionary or lets several "first" reads through.
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            recorder.record(flagKey: "hot-flag", variation: "on")
            recorder.record(flagKey: "flag-\(i % 10)", variation: "on")
        }

        let events = captured.all
        XCTAssertEqual(events.filter { $0.flagKey == "hot-flag" }.count, 1)
        XCTAssertEqual(Set(events.compactMap(\.flagKey)).count, 11)
        XCTAssertEqual(events.count, 11)
    }

    func testTheProductionClockIsMonotonic() {
        let a = ReadRecorder.monotonicNanos()
        let b = ReadRecorder.monotonicNanos()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertGreaterThan(a, 0)
    }
}
