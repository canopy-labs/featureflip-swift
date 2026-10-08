import XCTest
@testable import Featureflip

final class ConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = FeatureflipConfig(clientKey: "csk_test")
        XCTAssertEqual(config.baseUrl, "https://eval.featureflip.io")
        XCTAssertTrue(config.streaming)
        XCTAssertEqual(config.pollInterval, 30)
        XCTAssertEqual(config.flushInterval, 30)
        XCTAssertEqual(config.flushBatchSize, 100)
        XCTAssertEqual(config.initTimeout, 10)
        XCTAssertTrue(config.context.isEmpty)
        XCTAssertTrue(config.sendEvaluationEvents, "read reporting is on unless the app turns it off")
    }

    func testCustomValues() {
        let config = FeatureflipConfig(
            clientKey: "csk_test",
            baseUrl: "https://custom.example.com",
            context: ["user_id": "123"],
            streaming: false,
            pollInterval: 60,
            flushInterval: 15,
            flushBatchSize: 50,
            initTimeout: 5,
            sendEvaluationEvents: false
        )
        XCTAssertEqual(config.baseUrl, "https://custom.example.com")
        XCTAssertFalse(config.streaming)
        XCTAssertEqual(config.pollInterval, 60)
        XCTAssertFalse(config.sendEvaluationEvents)
    }
}
