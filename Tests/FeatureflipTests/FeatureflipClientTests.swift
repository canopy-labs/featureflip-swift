import XCTest
@testable import Featureflip

final class FeatureflipClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _resetForTesting()
    }

    override func tearDown() {
        _resetForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEvaluateResponseData(flags: [String: FlagValue]) -> Data {
        let response = ["flags": flags]
        return try! JSONEncoder().encode(response)
    }

    private func makeFlagValue(bool value: Bool) -> FlagValue {
        FlagValue(value: .bool(value), variation: "v1", reason: "RULE")
    }

    private func makeFlagValue(string value: String) -> FlagValue {
        FlagValue(value: .string(value), variation: "v1", reason: "RULE")
    }

    private func makeFlagValue(int value: Int) -> FlagValue {
        FlagValue(value: .int(value), variation: "v1", reason: "RULE")
    }

    private func makeFlagValue(double value: Double) -> FlagValue {
        FlagValue(value: .double(value), variation: "v1", reason: "RULE")
    }

    /// Waits until the loader has captured at least `count` requests.
    ///
    /// Lets a test order itself against the poller's immediate first poll instead of
    /// hoping that poll lands early. It is a live poller here — nothing cancels it —
    /// so the poll is guaranteed, but its timing is not (#2481).
    private func waitForRequestCount(
        _ loader: MockHTTPLoader,
        atLeast count: Int,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while loader.captured.count < count && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            loader.captured.count,
            count,
            "timed out waiting for \(count) captured requests",
            file: file,
            line: line
        )
    }

    /// Waits until the loader has seen no new request for `quietFor`.
    ///
    /// `close()` cancels the poller, but it cannot unmake a poll that was already in
    /// flight when it ran — so a test that queues a response immediately after
    /// close() can have that response consumed by the poll instead, leaving its own
    /// call to throw -1011 against an empty queue. Waiting for quiet makes the
    /// ordering explicit instead of probable (#2481).
    private func waitForQuiescence(
        _ loader: MockHTTPLoader,
        quietFor: TimeInterval = 0.2,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var quietSince = Date()
        while Date() < deadline {
            let count = loader.captured.count
            if count != lastCount {
                lastCount = count
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietFor {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Tests

    func testInitializeFetchesFlags() async {
        let loader = MockHTTPLoader()
        let flags: [String: FlagValue] = [
            "dark-mode": makeFlagValue(bool: true),
        ]
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        // Enqueue a second response for the polling data source's initial pollOnce
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))

        await client.initialize()

        XCTAssertEqual(client.boolVariation("dark-mode", default: false), true)

        await client.close()
    }

    func testBoolVariationReturnsDefault() {
        let client = FeatureflipClient.forTesting([:])
        XCTAssertEqual(client.boolVariation("nonexistent", default: false), false)
        XCTAssertEqual(client.boolVariation("nonexistent", default: true), true)
    }

    func testStringVariation() {
        let client = FeatureflipClient.forTesting(["greeting": "hello"])
        XCTAssertEqual(client.stringVariation("greeting", default: "bye"), "hello")
        XCTAssertEqual(client.stringVariation("missing", default: "bye"), "bye")
    }

    func testNumberVariation() {
        let client = FeatureflipClient.forTesting(["rate-limit": 42])
        XCTAssertEqual(client.numberVariation("rate-limit", default: 0.0), 42.0)
        XCTAssertEqual(client.numberVariation("missing", default: 5.0), 5.0)
    }

    func testForTesting() {
        let client = FeatureflipClient.forTesting([
            "bool-flag": true,
            "string-flag": "value",
            "int-flag": 99,
            "double-flag": 3.14,
        ])

        XCTAssertEqual(client.boolVariation("bool-flag", default: false), true)
        XCTAssertEqual(client.stringVariation("string-flag", default: "default"), "value")
        XCTAssertEqual(client.numberVariation("int-flag", default: 0.0), 99.0)
        XCTAssertEqual(client.numberVariation("double-flag", default: 0.0), 3.14)
        XCTAssertEqual(client.boolVariation("missing", default: false), false)
    }

    func testIdentifyRefetchesFlags() async throws {
        let loader = MockHTTPLoader()

        let initialFlags: [String: FlagValue] = [
            "feature": makeFlagValue(bool: false),
        ]
        // For initialize() evaluate call
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: initialFlags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        // Don't enqueue a response for the poller — its pollOnce() will fail
        // silently, avoiding a race where the poller's unconsumed response gets
        // picked up by identify() instead.

        await client.initialize()

        XCTAssertEqual(client.boolVariation("feature", default: true), false)

        // Wait for the poller's immediate first poll before queueing identify's
        // response. Enqueueing while that poll is still pending is a coin flip: the
        // poller consumes the response and identify() throws -1011 against an empty
        // queue instead (#2481).
        try await waitForRequestCount(loader, atLeast: 2)

        // NOT closed here. This used to close the handle to quiet the background
        // poller and then keep using it, which depended on a closed client still
        // evaluating — the bug #2327 fixes. What kept identify() the only consumer of
        // the mock response was then left to chance; the wait above is what actually
        // establishes it.

        // Identify with new context — returns updated flags
        let updatedFlags: [String: FlagValue] = [
            "feature": makeFlagValue(bool: true),
        ]
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: updatedFlags))

        try await client.identify(context: ["user_id": "new-user"])

        XCTAssertEqual(client.boolVariation("feature", default: false), true)

        await client.close()
    }

    func testAllFlags() {
        let client = FeatureflipClient.forTesting([
            "a": true,
            "b": "hello",
        ])

        let flags = client.allFlags()
        XCTAssertEqual(flags.count, 2)
        XCTAssertNotNil(flags["a"])
        XCTAssertNotNil(flags["b"])
    }

    func testJsonVariation() {
        let client = FeatureflipClient.forTesting(["key": "value"])
        let result = client.jsonVariation("key", default: .null)
        XCTAssertEqual(result, .string("value"))

        let missing = client.jsonVariation("missing", default: .bool(false))
        XCTAssertEqual(missing, .bool(false))
    }

    func testTrackSendsCustomTypeAndFlagKey() async throws {
        let loader = MockHTTPLoader()
        let flags: [String: FlagValue] = [
            "test-flag": makeFlagValue(bool: true),
        ]
        // For initialize() evaluate call
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))
        // For polling data source initial poll
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            context: ["user_id": "user-123"],
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)
        await client.initialize()

        // Enqueue response for events POST
        loader.enqueue(statusCode: 202, body: Data())

        // track() enqueues via a detached Task, so yield to let it run before flushing
        client.track("checkout-completed")
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.flush()

        // close() also flushes, ensuring the POST completes
        await client.close()

        // Poll for the events request with a timeout
        let deadline = Date().addingTimeInterval(2.0)
        var eventsRequest: URLRequest?
        while eventsRequest == nil && Date() < deadline {
            eventsRequest = loader.captured.first { req in
                req.url?.path.contains("events") == true
            }
            if eventsRequest == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let request = try XCTUnwrap(eventsRequest, "Expected an events POST request")
        let body = try XCTUnwrap(request.httpBody, "Expected request body")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)

        let event = events[0]
        XCTAssertEqual(event["type"] as? String, "Custom", "type must be 'Custom', not the event name")
        XCTAssertEqual(event["flagKey"] as? String, "checkout-completed", "flagKey must be the event name")
        XCTAssertEqual(event["userId"] as? String, "user-123")
    }

    // MARK: - SSE Delta Merge Tests

    func testHandleFlagUpdateMergesDeltaIntoSnapshot() async {
        let loader = MockHTTPLoader()

        let initialFlags: [String: FlagValue] = [
            "flag-a": makeFlagValue(bool: true),
            "flag-b": makeFlagValue(string: "hello"),
        ]
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: initialFlags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        // Don't enqueue a response for the poller — its pollOnce() will fail
        // silently, avoiding a race where it fires after applyFlagUpdate() and
        // overwrites the merged snapshot via handleFullUpdate().

        await client.initialize()
        // Not closed here — see testIdentifyRefetchesFlags (#2327).

        // Simulate SSE delta: only flag-b changed
        let delta: [String: FlagValue] = [
            "flag-b": makeFlagValue(string: "world"),
        ]
        client.applyFlagUpdate(delta)

        // flag-a should still exist (unchanged), flag-b should be updated
        XCTAssertEqual(client.boolVariation("flag-a", default: false), true)
        XCTAssertEqual(client.stringVariation("flag-b", default: ""), "world")

        await client.close()
    }

    func testHandleFlagUpdateRemovesFlagWithFlagRemoved() async {
        let loader = MockHTTPLoader()

        let initialFlags: [String: FlagValue] = [
            "flag-a": makeFlagValue(bool: true),
            "flag-b": makeFlagValue(string: "hello"),
        ]
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: initialFlags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        await client.initialize()
        // Not closed here — see testIdentifyRefetchesFlags (#2327).

        // Simulate SSE delta: flag-b removed
        let delta: [String: FlagValue] = [
            "flag-b": FlagValue(value: .null, variation: "", reason: "FLAG_REMOVED"),
        ]
        client.applyFlagUpdate(delta)

        // flag-a should still exist, flag-b should be gone
        XCTAssertEqual(client.boolVariation("flag-a", default: false), true)
        XCTAssertEqual(client.stringVariation("flag-b", default: "gone"), "gone")

        await client.close()
    }

    func testHandleFlagUpdateAddsNewFlags() async {
        let loader = MockHTTPLoader()

        let initialFlags: [String: FlagValue] = [
            "flag-a": makeFlagValue(bool: true),
        ]
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: initialFlags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        await client.initialize()
        // Not closed here — see testIdentifyRefetchesFlags (#2327).

        // Simulate SSE delta: new flag added
        let delta: [String: FlagValue] = [
            "flag-b": makeFlagValue(string: "new"),
        ]
        client.applyFlagUpdate(delta)

        XCTAssertEqual(client.boolVariation("flag-a", default: false), true)
        XCTAssertEqual(client.stringVariation("flag-b", default: ""), "new")

        await client.close()
    }

    // MARK: - Test client network guard tests (#276)

    func testTestClientIdentifyDoesNotMakeNetworkCall() async throws {
        let loader = MockHTTPLoader()
        let client = FeatureflipClient.forTesting(["flag": true], loader: loader)

        try await client.identify(context: ["user_id": "test-user"])

        XCTAssertTrue(loader.captured.isEmpty, "identify() on test client should not make network calls")
        XCTAssertEqual(client.boolVariation("flag", default: false), true)
    }

    func testTestClientFlushDoesNotMakeNetworkCall() async {
        let loader = MockHTTPLoader()
        let client = FeatureflipClient.forTesting(["flag": true], loader: loader)

        // Manually enqueue an event via track() on a non-test client would add to buffer,
        // but on a test client track() is also guarded — so flush has nothing to send.
        // The key assertion: even after flush(), no HTTP requests were made.
        await client.flush()

        XCTAssertTrue(loader.captured.isEmpty, "flush() on test client should not make network calls")
    }

    func testStartDataSourceUsesCurrentContextAfterIdentify() async throws {
        let loader = MockHTTPLoader()
        let flags: [String: FlagValue] = [
            "feature": makeFlagValue(bool: true),
        ]

        // For initialize() evaluate call
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))

        let config = FeatureflipConfig(
            clientKey: "test-key",
            baseUrl: "https://test.example.com",
            context: ["user_id": "user-a"],
            streaming: false
        )
        let client = FeatureflipClient(config: config, loader: loader)

        await client.initialize()
        await client.close()

        // Let any poll that was already in flight when close() ran land before
        // queueing identify's response — otherwise that poll consumes it (#2481).
        try await waitForQuiescence(loader)

        // Identify with new context
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))
        try await client.identify(context: ["user_id": "user-b"])

        // Call startDataSource — should create a poller with "user-b" context
        loader.enqueue(statusCode: 200, body: makeEvaluateResponseData(flags: flags))
        client.startDataSource()

        // Assert on what was polled, not on which request happened to arrive last.
        // Reading `capturedRequests.last` made the outcome depend on where a stray
        // poll landed rather than on the context the new poller was built with — the
        // thing under test (#2481). identify() posts to /identify, so filtering on
        // /evaluate leaves only polls.
        let deadline = Date().addingTimeInterval(2.0)
        var polledForUserB = false
        while !polledForUserB && Date() < deadline {
            polledForUserB = loader.captured.contains { request in
                guard request.url?.path.hasSuffix("/evaluate") == true,
                      let body = request.httpBody,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let context = json["context"] as? [String: String]
                else { return false }
                return context["user_id"] == "user-b"
            }
            if !polledForUserB {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        XCTAssertTrue(
            polledForUserB,
            "startDataSource() must poll with the context identify() set, not the one the client was configured with"
        )

        await client.close()
    }

    func testTestClientTrackDoesNotMakeNetworkCall() async throws {
        let loader = MockHTTPLoader()
        let client = FeatureflipClient.forTesting(["flag": true], loader: loader)

        client.track("test-event", metadata: ["key": .string("value")])

        // Give any fire-and-forget Task a chance to execute
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(loader.captured.isEmpty, "track() on test client should not enqueue or send events")
    }
}
