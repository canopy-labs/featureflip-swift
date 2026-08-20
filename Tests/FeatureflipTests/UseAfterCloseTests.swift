import XCTest
@testable import Featureflip

/// `close()` releases the core — stopping streaming/polling and flushing events —
/// but the in-memory snapshot stays readable, so a closed handle kept evaluating
/// against a frozen snapshot that can never update again, and reported
/// `isInitialized == true` while doing it (#2327).
///
/// The contract settled in #2313 and applied to flutter/android in #2326: a closed
/// handle returns the caller's default and reports not-initialized.
///
/// The fixture seeds real values via `forTesting` on purpose. A client whose fetch
/// failed has an empty snapshot and would return defaults either way, so the stale
/// value has to exist for these assertions to mean anything.
final class UseAfterCloseTests: XCTestCase {

    private func seededClient() -> FeatureflipClient {
        FeatureflipClient.forTesting([
            "bool-flag": true,
            "string-flag": "served",
            "number-flag": 42.0,
        ])
    }

    func testServesRealValuesWhileOpen() async {
        let client = seededClient()

        XCTAssertTrue(client.boolVariation("bool-flag", default: false))
        XCTAssertEqual(client.stringVariation("string-flag", default: "fallback"), "served")
        XCTAssertEqual(client.numberVariation("number-flag", default: 0.0), 42.0)
        XCTAssertEqual(client.jsonVariation("string-flag", default: .null), .string("served"))
        XCTAssertTrue(client.isInitialized)
        XCTAssertNotNil(client.flagDetail("bool-flag"))

        await client.close()
    }

    func testClosedHandleServesCallerDefault() async {
        let client = seededClient()
        await client.close()

        // Each default is deliberately the opposite of the cached value, so a stale
        // read is distinguishable from a correct default.
        XCTAssertFalse(client.boolVariation("bool-flag", default: false))
        XCTAssertEqual(client.stringVariation("string-flag", default: "fallback"), "fallback")
        XCTAssertEqual(client.numberVariation("number-flag", default: 0.0), 0.0)
        XCTAssertEqual(client.jsonVariation("string-flag", default: .bool(false)), .bool(false))
    }

    func testClosedHandleReportsNotInitialized() async {
        let client = seededClient()
        XCTAssertTrue(client.isInitialized)

        await client.close()

        XCTAssertFalse(client.isInitialized)
    }

    func testClosedHandleExposesNoFlagDetail() async {
        let client = seededClient()
        XCTAssertNotNil(client.flagDetail("bool-flag"))

        await client.close()

        XCTAssertNil(client.flagDetail("bool-flag"))
        XCTAssertTrue(client.allFlags().isEmpty)
    }

    func testCloseStaysIdempotent() async {
        let client = seededClient()

        await client.close()
        await client.close()

        XCTAssertFalse(client.boolVariation("bool-flag", default: false))
    }
}
