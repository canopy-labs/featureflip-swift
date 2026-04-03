import XCTest
@testable import Featureflip

final class SwiftUITests: XCTestCase {

    @MainActor
    func testFeatureFlagProviderReturnsDefaults() {
        let client = FeatureflipClient.forTesting([
            "dark-mode": true,
            "greeting": "hello",
            "rate": 42,
        ])
        let provider = FeatureFlagProvider(client: client)

        XCTAssertEqual(provider.boolVariation("dark-mode", default: false), true)
        XCTAssertEqual(provider.boolVariation("missing", default: false), false)
        XCTAssertEqual(provider.stringVariation("greeting", default: "bye"), "hello")
        XCTAssertEqual(provider.stringVariation("missing", default: "bye"), "bye")
        XCTAssertEqual(provider.numberVariation("rate", default: 0.0), 42.0)
        XCTAssertEqual(provider.numberVariation("missing", default: 5.0), 5.0)
    }

    @MainActor
    func testFeatureFlagProviderRevisionIncrementsOnUpdate() {
        let client = FeatureflipClient.forTesting([:])
        let provider = FeatureFlagProvider(client: client)

        XCTAssertEqual(provider.revision, 0)
        provider.updateFlags()
        XCTAssertEqual(provider.revision, 1)
        provider.updateFlags()
        XCTAssertEqual(provider.revision, 2)
    }
}
