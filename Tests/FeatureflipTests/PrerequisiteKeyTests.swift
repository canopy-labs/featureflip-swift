import XCTest
@testable import Featureflip

final class PrerequisiteKeyTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Decode

    func testDecodesPrerequisiteKeyWhenPresent() throws {
        let json = #"""
        {
          "value": false,
          "variation": "off",
          "reason": "prerequisite-failed",
          "prerequisiteKey": "billing-enabled"
        }
        """#.data(using: .utf8)!

        let flag = try decoder.decode(FlagValue.self, from: json)

        XCTAssertEqual(flag.variation, "off")
        XCTAssertEqual(flag.reason, "prerequisite-failed")
        XCTAssertEqual(flag.prerequisiteKey, "billing-enabled")
    }

    func testPrerequisiteKeyIsNilWhenAbsent() throws {
        let json = #"""
        {
          "value": true,
          "variation": "on",
          "reason": "fallthrough"
        }
        """#.data(using: .utf8)!

        let flag = try decoder.decode(FlagValue.self, from: json)

        XCTAssertNil(flag.prerequisiteKey)
    }

    func testPrerequisiteKeyIsNilWhenServerSendsNull() throws {
        let json = #"""
        {
          "value": true,
          "variation": "on",
          "reason": "fallthrough",
          "prerequisiteKey": null
        }
        """#.data(using: .utf8)!

        let flag = try decoder.decode(FlagValue.self, from: json)

        XCTAssertNil(flag.prerequisiteKey)
    }

    // MARK: - Decode from EvaluateResponse envelope

    func testDecodesPrerequisiteKeyFromClientEvaluateEnvelope() throws {
        let json = #"""
        {
          "flags": {
            "premium-feature": {
              "value": false,
              "variation": "off",
              "reason": "prerequisite-failed",
              "prerequisiteKey": "subscription-active"
            },
            "dark-mode": {
              "value": true,
              "variation": "on",
              "reason": "fallthrough"
            }
          }
        }
        """#.data(using: .utf8)!

        let response = try decoder.decode(EvaluateResponse.self, from: json)

        XCTAssertEqual(response.flags["premium-feature"]?.prerequisiteKey, "subscription-active")
        XCTAssertNil(response.flags["dark-mode"]?.prerequisiteKey)
    }

    // MARK: - Encode roundtrip

    func testEncodeRoundtripPreservesPrerequisiteKey() throws {
        let original = FlagValue(
            value: .bool(false),
            variation: "off",
            reason: "prerequisite-failed",
            prerequisiteKey: "parent-flag"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(FlagValue.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.prerequisiteKey, "parent-flag")
    }

    func testEncodeRoundtripWithoutPrerequisiteKey() throws {
        let original = FlagValue(
            value: .bool(true),
            variation: "on",
            reason: "fallthrough"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(FlagValue.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.prerequisiteKey)
    }

    // MARK: - Equatable

    func testFlagValuesDifferingOnlyInPrerequisiteKeyAreNotEqual() {
        let a = FlagValue(value: .bool(false), variation: "off", reason: "prerequisite-failed", prerequisiteKey: "alpha")
        let b = FlagValue(value: .bool(false), variation: "off", reason: "prerequisite-failed", prerequisiteKey: "beta")
        let c = FlagValue(value: .bool(false), variation: "off", reason: "prerequisite-failed")

        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Public accessor

    func testFlagDetailReturnsNilForUnknownKey() {
        let client = FeatureflipClient.forTesting(["known": true])
        XCTAssertNil(client.flagDetail("unknown"))
    }

    func testFlagDetailReturnsValueForKnownKey() {
        let client = FeatureflipClient.forTesting(["known": true])

        let detail = client.flagDetail("known")
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.value, .bool(true))
    }

    func testFlagDetailSurfacesPrerequisiteKey() {
        let client = FeatureflipClient.forTesting([:])
        client.applyFlagUpdate([
            "gated": FlagValue(
                value: .bool(false),
                variation: "false",
                reason: "prerequisite-failed",
                prerequisiteKey: "parent-flag"
            ),
        ])

        let detail = client.flagDetail("gated")
        XCTAssertEqual(detail?.reason, "prerequisite-failed")
        XCTAssertEqual(detail?.prerequisiteKey, "parent-flag")
    }

    // MARK: - FlagCache persistence

    func testFlagCachePersistsPrerequisiteKeyAcrossReload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("featureflip-prereq-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = FlagCache(clientKey: "test-key", cacheDirectory: tempDir)
        let flags: [String: FlagValue] = [
            "premium": FlagValue(
                value: .bool(false),
                variation: "off",
                reason: "prerequisite-failed",
                prerequisiteKey: "subscription"
            ),
            "vanilla": FlagValue(value: .bool(true), variation: "on", reason: "fallthrough"),
        ]
        await cache.setAll(flags)

        let reloaded = FlagCache(clientKey: "test-key", cacheDirectory: tempDir)
        await reloaded.loadFromDisk()
        let result = await reloaded.all()

        XCTAssertEqual(result["premium"]?.prerequisiteKey, "subscription")
        XCTAssertNil(result["vanilla"]?.prerequisiteKey)
    }
}
