import XCTest
@testable import Featureflip

/// In-memory `AnonymousKeyStore` for tests — avoids touching `UserDefaults`.
private final class MemoryAnonymousKeyStore: AnonymousKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String? = nil) { self.value = initial }
    func read() -> String? { lock.withLock { value } }
    func write(_ v: String) { lock.withLock { value = v } }
}

final class AnonymousKeyTests: XCTestCase {

    // MARK: - Pure resolver

    func testInjectsAndPersistsAnonymousUserId() {
        let store = MemoryAnonymousKeyStore()
        let first = resolveAnonymousContext(["plan": "pro"], store: store)
        let id = first["user_id"]
        XCTAssertNotNil(id)
        XCTAssertFalse(id!.isEmpty)
        XCTAssertEqual(first["plan"], "pro")

        // Second call reads the SAME persisted key.
        let second = resolveAnonymousContext(["plan": "pro"], store: store)
        XCTAssertEqual(second["user_id"], id)
    }

    func testRealUserIdWins() {
        let store = MemoryAnonymousKeyStore()
        let out = resolveAnonymousContext(["user_id": "real-1"], store: store)
        XCTAssertEqual(out["user_id"], "real-1")
        XCTAssertNil(store.read()) // never generated
    }

    func testCamelCaseUserIdAliasWins() {
        let store = MemoryAnonymousKeyStore()
        let out = resolveAnonymousContext(["userId": "alice"], store: store)
        XCTAssertEqual(out, ["userId": "alice"])
        XCTAssertNil(store.read())
    }

    func testBlankUserIdTreatedAsAnonymous() {
        let store = MemoryAnonymousKeyStore()
        let out = resolveAnonymousContext(["user_id": "   "], store: store)
        let resolved = out["user_id"] ?? ""
        XCTAssertFalse(resolved.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertNotEqual(resolved, "   ")
    }

    // MARK: - Core wiring

    func testEvaluateSendsPersistedAnonymousUserId() async throws {
        let loader = MockHTTPLoader()
        let body = #"{"flags":{}}"#.data(using: .utf8)!
        loader.enqueue(statusCode: 200, body: body) // initial evaluate
        loader.enqueue(statusCode: 200, body: body) // poller's immediate poll

        let store = MemoryAnonymousKeyStore()
        let config = FeatureflipConfig(
            clientKey: "anon-wiring-key",
            baseUrl: "https://eval.example.com",
            streaming: false
        )
        let core = SharedFeatureflipCore(config: config, loader: loader, anonymousKeyStore: store)

        await core.initialize()
        await core.close()

        let req = loader.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/v1/client/evaluate")
        let bodyData = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let ctx = try XCTUnwrap(json?["context"] as? [String: Any])
        let userId = try XCTUnwrap(ctx["user_id"] as? String)
        XCTAssertFalse(userId.isEmpty)
        XCTAssertEqual(userId, store.read())
    }
}
