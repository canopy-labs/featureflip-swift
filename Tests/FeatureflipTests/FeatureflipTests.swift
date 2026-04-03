import XCTest
@testable import Featureflip

final class FeatureflipTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(FeatureflipClient.version, "0.1.0")
    }
}
