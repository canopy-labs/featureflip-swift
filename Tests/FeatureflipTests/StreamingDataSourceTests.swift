import XCTest
@testable import Featureflip

final class StreamingDataSourceTests: XCTestCase {
    func testBuildStreamURL() {
        let url = StreamingDataSource.buildStreamURL(
            baseUrl: "https://eval.example.com",
            clientKey: "csk_abc",
            context: ["user_id": "123"]
        )
        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.hasPrefix("https://eval.example.com/v1/client/stream?"))
        XCTAssertTrue(urlString.contains("authorization=csk_abc"))
        XCTAssertTrue(urlString.contains("context="))
    }

    func testParseSSEEvent() {
        let lines = [
            "event: flags-updated",
            "data: {\"flags\":{\"f1\":{\"value\":true,\"variation\":\"on\",\"reason\":\"Fallthrough\"}}}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "flags-updated")
        XCTAssertNotNil(event?.data)
    }

    func testParseSSEEventIgnoresUnknownType() {
        let lines = [
            "event: ping",
            "data: {\"timestamp\":\"2026-01-01\"}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "ping")
    }

    func testBackoffIncreases() {
        var backoff = StreamingDataSource.initialBackoff
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 2.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 4.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 8.0)
    }

    func testBackoffCapsAtMax() {
        var backoff = 16.0
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 30.0)
        backoff = StreamingDataSource.nextBackoff(backoff)
        XCTAssertEqual(backoff, 30.0)
    }

    func testParseSSEEventNoSpaceAfterColon() {
        let lines = [
            "event:flags-updated",
            "data:{\"flags\":{}}",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "flags-updated")
        XCTAssertEqual(event?.data, "{\"flags\":{}}")
    }

    func testParseSSEEventMultipleDataLines() {
        let lines = [
            "event: message",
            "data: line1",
            "data: line2",
            "data: line3",
        ]
        let event = StreamingDataSource.parseSSEEvent(from: lines)
        XCTAssertEqual(event?.eventType, "message")
        XCTAssertEqual(event?.data, "line1\nline2\nline3")
    }
}
