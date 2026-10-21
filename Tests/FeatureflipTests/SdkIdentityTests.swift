import XCTest
@testable import Featureflip

private final class IdentityKeyStore: AnonymousKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "anon"
    func read() -> String? { lock.withLock { value } }
    func write(_ v: String) { lock.withLock { value = v } }
}

/// Every request names the SDK and its version so the Evaluation API can count usage
/// (#4142, contract in #4138). Before this the SDK sent URLSession's default
/// `<App>/<build> CFNetwork/<x> Darwin/<y>`, which names the host app, not us.
///
/// Set per request rather than through `httpAdditionalHeaders`, which Apple documents
/// as not guaranteed for User-Agent.
final class SdkIdentityTests: XCTestCase {
    private let sdkToken = "featureflip-swift/\(SdkIdentity.version)"

    private func flags() -> Data {
        #"{"flags":{"f":{"value":true,"variation":"on","reason":"Fallthrough"}}}"#.data(using: .utf8)!
    }

    func testVersionIsTheNewestChangelogHeading() throws {
        // SwiftPM carries no manifest version (the git tag is the version), so the
        // constant is hand-maintained; check_sdk_versions.py pins it to the CHANGELOG in
        // CI. Asserted here too, so a local `swift test` catches the drift (#2141).
        let changelog = try String(contentsOfFile: "CHANGELOG.md", encoding: .utf8)
        let newest = changelog
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("## ") && $0.dropFirst(3).first?.isNumber == true }
        let heading = try XCTUnwrap(newest)

        XCTAssertTrue(heading.hasPrefix("## \(SdkIdentity.version) "), "\(heading) vs \(SdkIdentity.version)")
    }

    func testEvaluateIdentifyAndEventsCarryTheSdkTokenByDefault() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: flags())
        loader.enqueue(statusCode: 200, body: flags())
        loader.enqueue(statusCode: 202, body: Data())
        let client = HttpClient(baseUrl: "https://eval.example.com", clientKey: "k", loader: loader)

        _ = try await client.evaluate(context: ["user_id": "u"])
        _ = try await client.identify(context: ["user_id": "u"])
        try await client.postEvents([SdkEvent(type: "Custom", flagKey: "f", userId: nil, variation: nil, timestamp: "2026-10-20T00:00:00Z", metadata: nil)])

        XCTAssertEqual(loader.captured.map { $0.value(forHTTPHeaderField: "User-Agent") },
                       [sdkToken, sdkToken, sdkToken])
    }

    func testTheStreamRequestCarriesTheUserAgentItWasGiven() throws {
        let source = StreamingDataSource(
            baseUrl: "https://eval.example.com",
            clientKey: "k",
            context: [:],
            onChange: { _ in },
            onSnapshot: { _ in },
            userAgent: "\(sdkToken) my-wrapper/1.0"
        )

        let request = try XCTUnwrap(source.makeStreamRequest())

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "\(sdkToken) my-wrapper/1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testAConfiguredWrapperReachesTheWireThroughTheCore() async throws {
        let loader = MockHTTPLoader()
        loader.enqueue(statusCode: 200, body: flags())
        let config = FeatureflipConfig(
            clientKey: "identity-key",
            baseUrl: "https://eval.example.com",
            streaming: false,
            sendEvaluationEvents: false,
            wrapperName: "featureflip-react-native",
            wrapperVersion: "0.1.0"
        )
        let core = SharedFeatureflipCore(config: config, loader: loader, anonymousKeyStore: IdentityKeyStore())

        await core.initialize()
        await core.close()

        XCTAssertEqual(loader.captured.first?.value(forHTTPHeaderField: "User-Agent"),
                       "\(sdkToken) featureflip-react-native/0.1.0")
    }

    func testAWrapperWithoutAVersionIsABareName() {
        XCTAssertEqual(SdkIdentity.userAgent(wrapperName: "my-wrapper"), "\(sdkToken) my-wrapper")
    }

    func testAnInvalidWrapperIsDropped() {
        // A space is not a legal product-token character, and URLRequest would send it
        // inside the header value regardless. Identity metadata must never stop the client
        // starting, so the wrapper is dropped (with a Diagnostics line).
        XCTAssertEqual(SdkIdentity.userAgent(wrapperName: "bad name", wrapperVersion: "1.0"), sdkToken)
        XCTAssertEqual(SdkIdentity.userAgent(wrapperName: "ok", wrapperVersion: "bad version"), sdkToken)
    }
}
