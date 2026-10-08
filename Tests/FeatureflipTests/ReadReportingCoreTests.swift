import XCTest
@testable import Featureflip

/// In-memory `AnonymousKeyStore`, so these tests never touch `UserDefaults`.
private final class InMemoryAnonymousKeyStore: AnonymousKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String? = nil) { value = initial }
    func read() -> String? { lock.withLock { value } }
    func write(_ v: String) { lock.withLock { value = v } }
}

/// The core reports what app code reads, and nothing else (#3545).
final class ReadReportingCoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _resetForTesting()
    }

    override func tearDown() {
        _resetForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    private let flags: [String: FlagValue] = [
        "bool-flag": FlagValue(value: .bool(true), variation: "on", reason: "fallthrough"),
        "string-flag": FlagValue(value: .string("dark"), variation: "dark-arm", reason: "fallthrough"),
        "number-flag": FlagValue(value: .int(7), variation: "seven", reason: "fallthrough"),
        "json-flag": FlagValue(value: .dictionary(["a": .int(1)]), variation: "obj", reason: "fallthrough"),
        "detail-flag": FlagValue(value: .bool(false), variation: "off", reason: "flag-disabled"),
    ]

    private func flagsBody(_ flags: [String: FlagValue]) -> Data {
        try! JSONEncoder().encode(["flags": flags])
    }

    private func makeCore(
        _ loader: MockHTTPLoader = MockHTTPLoader(),
        context: [String: Any] = ["user_id": "u-1"],
        store: InMemoryAnonymousKeyStore = InMemoryAnonymousKeyStore(),
        sendEvaluationEvents: Bool = true,
        captured: CapturedEvents?
    ) -> SharedFeatureflipCore {
        let config = FeatureflipConfig(
            clientKey: "rr-core",
            baseUrl: "https://test.example.com",
            context: context,
            streaming: false,
            sendEvaluationEvents: sendEvaluationEvents
        )
        return SharedFeatureflipCore(
            config: config,
            loader: loader,
            anonymousKeyStore: store,
            readSink: captured.map { sink in { sink.append($0) } }
        )
    }

    private func summary(_ events: [SdkEvent]) -> [String] {
        events.map { "\($0.type) \($0.flagKey ?? "<nil>") \($0.variation ?? "<nil>") \($0.userId ?? "<nil>")" }
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func eventsRequests(_ loader: MockHTTPLoader) -> [URLRequest] {
        loader.captured.filter { $0.url?.path == "/v1/client/events" }
    }

    // MARK: - What counts as a read

    func testEveryTypedVariationAndFlagDetailReportTheServedVariation() {
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        _ = core.boolVariation("bool-flag", default: false)
        _ = core.stringVariation("string-flag", default: "")
        _ = core.numberVariation("number-flag", default: 0)
        _ = core.jsonVariation("json-flag", default: .null)
        _ = core.flagDetail("detail-flag")

        XCTAssertEqual(summary(captured.all), [
            "Evaluation bool-flag on u-1",
            "Evaluation string-flag dark-arm u-1",
            "Evaluation number-flag seven u-1",
            "Evaluation json-flag obj u-1",
            "Evaluation detail-flag off u-1",
        ])
        core.release()
    }

    func testAReadOfAMissingKeyIsReportedWithNoVariation() {
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        XCTAssertEqual(core.boolVariation("removed-flag", default: true), true)
        XCTAssertNil(core.flagDetail("other-removed-flag"))

        XCTAssertEqual(summary(captured.all), [
            "Evaluation removed-flag <nil> u-1",
            "Evaluation other-removed-flag <nil> u-1",
        ])
        core.release()
    }

    func testAReadWhoseTypeDoesNotMatchStillReportsTheServedVariation() {
        // The caller gets its default back, but the flag WAS read, so it is still in use.
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        XCTAssertEqual(core.stringVariation("bool-flag", default: "fallback"), "fallback")

        XCTAssertEqual(summary(captured.all), ["Evaluation bool-flag on u-1"])
        core.release()
    }

    func testAllFlagsNeverReports() {
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        XCTAssertEqual(core.allFlags().count, flags.count)

        XCTAssertTrue(captured.all.isEmpty, "allFlags() must not mark every served flag as read")
        core.release()
    }

    func testRepeatReadsAcrossAccessorsAreDeduplicated() {
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        for _ in 0..<20 {
            _ = core.boolVariation("bool-flag", default: false)
            _ = core.flagDetail("bool-flag")
        }

        XCTAssertEqual(summary(captured.all), ["Evaluation bool-flag on u-1"])
        core.release()
    }

    func testConcurrentReadsFromManyThreadsReportOnce() {
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        DispatchQueue.concurrentPerform(iterations: 500) { i in
            _ = core.boolVariation("bool-flag", default: false)
            if i % 2 == 0 {
                core.updateSnapshot(self.flags) // a stream update landing mid-read
            }
        }

        XCTAssertEqual(summary(captured.all), ["Evaluation bool-flag on u-1"])
        core.release()
    }

    func testReturningToTheForegroundStartsANewWindow() {
        // The clock is not advanced: the foreground transition alone must reset the
        // window, as a defence against a platform clock that paused while the app slept.
        let captured = CapturedEvents()
        let core = makeCore(captured: captured)
        core.updateSnapshot(flags)

        _ = core.boolVariation("bool-flag", default: false)
        _ = core.boolVariation("bool-flag", default: false)
        core.handleBackground()
        core.handleForeground()
        _ = core.boolVariation("bool-flag", default: false)
        _ = core.boolVariation("bool-flag", default: false)

        XCTAssertEqual(summary(captured.all), [
            "Evaluation bool-flag on u-1",
            "Evaluation bool-flag on u-1",
        ])
        core.release()
    }

    // MARK: - Who the read is reported for

    func testReadsBeforeInitializationAreReportedForTheResolvedAnonymousUser() {
        let captured = CapturedEvents()
        let core = makeCore(context: [:], store: InMemoryAnonymousKeyStore("anon-42"), captured: captured)

        // Nothing fetched yet: the snapshot is empty, so the read serves the default.
        XCTAssertEqual(core.boolVariation("bool-flag", default: false), false)
        // The fetch lands; the same flag now has a variation, which is a separate read.
        core.updateSnapshot(flags)
        XCTAssertEqual(core.boolVariation("bool-flag", default: false), true)

        XCTAssertEqual(summary(captured.all), [
            "Evaluation bool-flag <nil> anon-42",
            "Evaluation bool-flag on anon-42",
        ])
        core.release()
    }

    func testIdentifyMidWindowReportsTheNewUsersFirstRead() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: flagsBody(flags))
        let captured = CapturedEvents()
        let core = makeCore(loader, captured: captured)
        core.updateSnapshot(flags)

        _ = core.boolVariation("bool-flag", default: false)
        try await core.identify(context: ["user_id": "u-2"])
        _ = core.boolVariation("bool-flag", default: false)
        _ = core.boolVariation("bool-flag", default: false)

        XCTAssertEqual(summary(captured.all), [
            "Evaluation bool-flag on u-1",
            "Evaluation bool-flag on u-2",
        ])
        core.release()
    }

    // MARK: - The option

    func testReportingOffCreatesNoRecorderAndReportsNothing() {
        let captured = CapturedEvents()
        let core = makeCore(sendEvaluationEvents: false, captured: captured)
        core.updateSnapshot(flags)

        _ = core.boolVariation("bool-flag", default: false)
        _ = core.flagDetail("detail-flag")
        _ = core.boolVariation("removed-flag", default: false)

        XCTAssertNil(core.readRecorder)
        XCTAssertTrue(captured.all.isEmpty)
        core.release()
    }

    func testTestClientsNeverReport() {
        XCTAssertNil(SharedFeatureflipCore.createForTestingStub(["f": true]).readRecorder)
        XCTAssertNil(SharedFeatureflipCore.createForTestingSkeleton().readRecorder)
    }

    func testEveryEvaluateRequestCarriesTheHeaderWhenReportingIsOn() async throws {
        // Initial fetch plus the poller's immediate first poll: both are /v1/client/evaluate,
        // and a poll without the header would have the server record every flag again.
        try await assertEvaluateHeaders(sendEvaluationEvents: true, expected: "1")
    }

    func testNoEvaluateRequestCarriesTheHeaderWhenReportingIsOff() async throws {
        try await assertEvaluateHeaders(sendEvaluationEvents: false, expected: nil)
    }

    private func assertEvaluateHeaders(
        sendEvaluationEvents: Bool,
        expected: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: flagsBody(flags))
        loader.enqueue(statusCode: 200, body: flagsBody(flags))
        let core = makeCore(loader, sendEvaluationEvents: sendEvaluationEvents, captured: nil)

        await core.initialize()
        let sawPoll = try await waitUntil { loader.captured.count >= 2 }
        XCTAssertTrue(sawPoll, "timed out waiting for the poller's first poll", file: file, line: line)
        await core.close()

        let evaluates = loader.captured.filter { $0.url?.path == "/v1/client/evaluate" }
        XCTAssertEqual(evaluates.count, 2, file: file, line: line)
        for request in evaluates {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"),
                expected,
                file: file,
                line: line
            )
        }
        core.release()
    }

    func testASecondClientWithTheOptionOffSharesTheFirstCoresSetting() {
        // Same as every other option: the first config per clientKey wins, silently.
        let loader = MockHTTPLoader()
        let on = FeatureflipConfig(
            clientKey: "rr-mismatch-on", baseUrl: "https://test.example.com",
            context: ["user_id": "u-1"], streaming: false
        )
        let off = FeatureflipConfig(
            clientKey: "rr-mismatch-on", baseUrl: "https://test.example.com",
            context: ["user_id": "u-1"], streaming: false, sendEvaluationEvents: false
        )

        let first = _getOrCreateCore(config: on, loader: loader)
        let second = _getOrCreateCore(config: off, loader: loader)

        XCTAssertTrue(first === second)
        XCTAssertTrue(second.config.sendEvaluationEvents)
        XCTAssertNotNil(second.readRecorder)
        first.release()
        second.release()
    }

    func testASecondClientWithTheOptionOnSharesTheFirstCoresSetting() {
        let loader = MockHTTPLoader()
        let off = FeatureflipConfig(
            clientKey: "rr-mismatch-off", baseUrl: "https://test.example.com",
            context: ["user_id": "u-1"], streaming: false, sendEvaluationEvents: false
        )
        let on = FeatureflipConfig(
            clientKey: "rr-mismatch-off", baseUrl: "https://test.example.com",
            context: ["user_id": "u-1"], streaming: false
        )

        let first = _getOrCreateCore(config: off, loader: loader)
        let second = _getOrCreateCore(config: on, loader: loader)

        XCTAssertTrue(first === second)
        XCTAssertFalse(second.config.sendEvaluationEvents)
        XCTAssertNil(second.readRecorder)
        first.release()
        second.release()
    }

    // MARK: - Through the real event processor

    func testFlagDetailThroughTheClientReachesTheEventsEndpoint() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(202)
        let client = FeatureflipClient(
            config: FeatureflipConfig(
                clientKey: "rr-wire",
                baseUrl: "https://test.example.com",
                context: ["user_id": "u-1"],
                streaming: false
            ),
            loader: loader
        )
        client.applyFlagUpdate(["detail-flag": FlagValue(value: .bool(true), variation: "on", reason: "fallthrough")])

        XCTAssertEqual(client.flagDetail("detail-flag")?.variation, "on")
        _ = client.allFlags()

        // The read reaches the processor through a Task, so flush until it has been sent.
        let sent = try await waitUntil {
            await client.flush()
            return !self.eventsRequests(loader).isEmpty
        }
        XCTAssertTrue(sent, "the read never reached /v1/client/events")

        let body = try XCTUnwrap(eventsRequests(loader).first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1, "allFlags() must not add events")
        XCTAssertEqual(events[0]["type"] as? String, "Evaluation")
        XCTAssertEqual(events[0]["flagKey"] as? String, "detail-flag")
        XCTAssertEqual(events[0]["variation"] as? String, "on")
        XCTAssertEqual(events[0]["userId"] as? String, "u-1")
        XCTAssertNotNil(events[0]["timestamp"] as? String)
        XCTAssertNil(
            eventsRequests(loader)[0].value(forHTTPHeaderField: "X-Featureflip-Reports-Evaluations"),
            "the header belongs on evaluate and identify only"
        )
        await client.close()
    }

    func testClosingOneOfTwoHandlesKeepsTheOtherHandlesReadsReported() async throws {
        // Two handles on one clientKey share a core. Closing one used to stop the shared
        // event processor, which then rejected every read the other handle made, so
        // flags it still used looked unread from this device (#3566).
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(202)
        let config = FeatureflipConfig(
            clientKey: "rr-close-one-of-two",
            baseUrl: "https://test.example.com",
            context: ["user_id": "u-1"],
            streaming: false
        )
        let first = FeatureflipClient(config: config, loader: loader)
        let second = FeatureflipClient(config: config, loader: loader)
        second.applyFlagUpdate(flags)

        await first.close()
        XCTAssertTrue(second.boolVariation("bool-flag", default: false))

        let sent = try await waitUntil {
            await second.flush()
            return !self.eventsRequests(loader).isEmpty
        }
        XCTAssertTrue(sent, "the surviving handle's read never reached /v1/client/events")
        let body = try XCTUnwrap(eventsRequests(loader).first?.httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""flagKey":"bool-flag""#))
        await second.close()
    }

    func testAReadBeforeBackgroundingIsSentByTheBackgroundFlush() async throws {
        let loader = MockHTTPLoader()
        loader.setAlwaysStatusCode(202)
        let core = makeCore(loader, captured: nil)
        core.updateSnapshot(flags)

        _ = core.boolVariation("bool-flag", default: false)
        let queued = try await waitUntil { await core.eventProcessor.bufferedEventCount() == 1 }
        XCTAssertTrue(queued, "the read never reached the event processor")

        core.handleBackground()

        let sent = try await waitUntil { !self.eventsRequests(loader).isEmpty }
        XCTAssertTrue(sent, "backgrounding must flush pending Evaluation events")
        let body = try XCTUnwrap(eventsRequests(loader).first?.httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""type":"Evaluation""#))
        core.release()
    }
}
