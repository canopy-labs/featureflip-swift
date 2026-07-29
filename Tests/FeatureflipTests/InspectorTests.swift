import XCTest
@testable import Featureflip

/// Thread-safe event collector. `NSLock.withLock` matches the primitive already
/// proven in FeatureflipClientFactoryTests.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EvaluationEvent] = []

    func record(_ event: EvaluationEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [EvaluationEvent] {
        lock.withLock { storage }
    }
}

final class InspectorTests: XCTestCase {

    // MARK: - Event shape

    func testFiresOncePerAccessorWithServedValueAndVerbatimReason() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )

        XCTAssertTrue(client.boolVariation("stub-flag", default: false))

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].flagKey, "stub-flag")
        XCTAssertEqual(events[0].value, .bool(true))
        XCTAssertEqual(events[0].variationKey, "override")
        // The stub snapshot's reason, forwarded verbatim — never rewritten.
        XCTAssertEqual(events[0].reason, "TEST")
        XCTAssertNil(events[0].ruleId)
        XCTAssertNil(events[0].prerequisiteKey)
        XCTAssertFalse(events[0].timestamp.isEmpty)
    }

    func testReportsFlagNotFoundForAbsentFlag() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )

        XCTAssertTrue(client.boolVariation("nope", default: true))

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].reason, "flag-not-found")
        XCTAssertEqual(events[0].value, .bool(true))
        XCTAssertNil(events[0].variationKey)
    }

    func testTypeMismatchReportsDefaultButKeepsServerReason() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )
        client.applyFlagUpdate([
            "stringy": FlagValue(value: .string("blue"), variation: "v2", reason: "fallthrough"),
        ])

        XCTAssertFalse(client.boolVariation("stringy", default: false))

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].value, .bool(false))
        XCTAssertEqual(events[0].reason, "fallthrough")
        XCTAssertEqual(events[0].variationKey, "v2")
    }

    func testParsesRuleIdLeavingReasonVerbatim() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )
        client.applyFlagUpdate([
            "ruled": FlagValue(value: .bool(true), variation: "on", reason: "rule-match:rule-abc-123"),
        ])

        _ = client.boolVariation("ruled", default: false)

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].reason, "rule-match:rule-abc-123")
        XCTAssertEqual(events[0].ruleId, "rule-abc-123")
    }

    func testRuleIdIsNilWhenRuleMatchSuffixIsEmpty() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )
        client.applyFlagUpdate([
            "ruled": FlagValue(value: .bool(true), variation: "on", reason: "rule-match:"),
        ])

        _ = client.boolVariation("ruled", default: false)

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].reason, "rule-match:")
        XCTAssertNil(events[0].ruleId)
    }

    func testRuleIdIsNilForNonRuleMatchReason() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )
        client.applyFlagUpdate([
            "plain": FlagValue(value: .bool(true), variation: "on", reason: "fallthrough"),
        ])

        _ = client.boolVariation("plain", default: false)

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].ruleId)
    }

    func testForwardsPrerequisiteKey() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            [:],
            inspectors: [{ collector.record($0) }]
        )
        client.applyFlagUpdate([
            "gated": FlagValue(
                value: .bool(false),
                variation: "off",
                reason: "prerequisite-failed",
                prerequisiteKey: "billing-enabled"
            ),
        ])

        _ = client.boolVariation("gated", default: true)

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].reason, "prerequisite-failed")
        XCTAssertEqual(events[0].prerequisiteKey, "billing-enabled")
        XCTAssertNil(events[0].ruleId)
    }

    func testEventCarriesTheCurrentContext() {
        let collector = Collector()
        let core = SharedFeatureflipCore.createForTestingStub(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )
        core.currentContext = ["user_id": "user-42", "plan": "pro"]

        _ = core.boolVariation("stub-flag", default: false)

        let events = collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].context, ["user_id": "user-42", "plan": "pro"])
        core.release()
    }

    // MARK: - Accessor coverage

    func testFiresExactlyOncePerAccessorAcrossAllFour() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )

        _ = client.boolVariation("stub-flag", default: false)
        XCTAssertEqual(collector.events.count, 1)
        _ = client.stringVariation("stub-flag", default: "")
        XCTAssertEqual(collector.events.count, 2)
        _ = client.numberVariation("stub-flag", default: 0)
        XCTAssertEqual(collector.events.count, 3)
        _ = client.jsonVariation("stub-flag", default: .bool(false))
        XCTAssertEqual(collector.events.count, 4)

        // Each accessor reports the value it actually returned, coerced.
        XCTAssertEqual(collector.events[0].value, .bool(true))
        XCTAssertEqual(collector.events[1].value, .string(""))
        XCTAssertEqual(collector.events[2].value, .double(0))
        XCTAssertEqual(collector.events[3].value, .bool(true))
    }

    func testDoesNotFireForFlagDetail() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )

        _ = client.flagDetail("stub-flag")

        XCTAssertEqual(collector.events.count, 0)
    }

    func testDoesNotFireForAllFlags() {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )

        _ = client.allFlags()

        XCTAssertEqual(collector.events.count, 0)
    }

    // MARK: - Registration and lifecycle

    /// Swift inspectors are non-throwing by type, so per-inspector error
    /// isolation is structural. What remains testable is that every registered
    /// inspector receives the same event.
    func testEveryRegisteredInspectorReceivesTheEvent() {
        let first = Collector()
        let second = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ first.record($0) }, { second.record($0) }]
        )

        XCTAssertTrue(client.boolVariation("stub-flag", default: false))

        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events[0].flagKey, "stub-flag")
    }

    func testNoEventsAfterClose() async {
        let collector = Collector()
        let client = FeatureflipClient.forTesting(
            ["stub-flag": true],
            inspectors: [{ collector.record($0) }]
        )

        _ = client.boolVariation("stub-flag", default: false)
        XCTAssertEqual(collector.events.count, 1)

        await client.close()

        // The value still resolves; only the inspector goes quiet.
        XCTAssertTrue(client.boolVariation("stub-flag", default: false))
        XCTAssertEqual(collector.events.count, 1)
    }

    func testNoInspectorsConfiguredStillReturnsValues() {
        let client = FeatureflipClient.forTesting(["stub-flag": true])

        XCTAssertTrue(client.boolVariation("stub-flag", default: false))
        XCTAssertFalse(client.boolVariation("missing", default: false))
    }

    func testConfigDefaultsToNoInspectors() {
        let config = FeatureflipConfig(clientKey: "csk_test")
        XCTAssertTrue(config.inspectors.isEmpty)
    }
}
