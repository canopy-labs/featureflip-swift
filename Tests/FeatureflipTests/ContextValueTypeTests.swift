import XCTest
@testable import Featureflip

/// In-memory `AnonymousKeyStore` — the sibling suite's copy is file-private.
private final class MemoryStore: AnonymousKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() -> String? { lock.withLock { value } }
    func write(_ v: String) { lock.withLock { value = v } }
}

/// Context was `[String: String]`, so this SDK could not send a JSON number — and
/// the #1458 equality contract ("`Equals`/`In` coerce by attribute *type*, not
/// stringification") only engages when the attribute arrives as a JSON number. A
/// rule like `age Equals ["25.0"]` therefore matched on browser and flutter and
/// silently no-opped on iOS (#2293).
///
/// These assert on the ENCODED FORM rather than an evaluation result: the coercion
/// lives in the engine, so the only thing this SDK can get wrong — and the only
/// thing worth pinning here — is whether the type survives serialization.
final class ContextValueTypeTests: XCTestCase {

    private func encodedContext(_ context: [String: AnyCodableValue]) throws -> String {
        let data = try JSONEncoder().encode(context)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testNumericValuesEncodeAsJSONNumbers() throws {
        let json = try encodedContext(["age": 25, "score": 1.5, "premium": true, "plan": "pro"])

        // The whole point: unquoted on the wire. `"age":"25"` is the bug.
        XCTAssertTrue(json.contains("\"age\":25"), json)
        XCTAssertTrue(json.contains("\"score\":1.5"), json)
        XCTAssertTrue(json.contains("\"premium\":true"), json)
        // Strings must still be quoted — widening must not unquote what was correct.
        XCTAssertTrue(json.contains("\"plan\":\"pro\""), json)
    }

    func testConfigConvertsUntypedContextAtTheBoundary() throws {
        let config = FeatureflipConfig(
            clientKey: "k",
            context: ["age": 25, "plan": "pro", "premium": true]
        )

        XCTAssertEqual(config.context["age"], .int(25))
        XCTAssertEqual(config.context["plan"], .string("pro"))
        XCTAssertEqual(config.context["premium"], .bool(true))
    }

    func testBridgeMapsBoolBeforeInt() {
        // Native Swift primitives, where the case ORDER is irrelevant: `1 as Any as?
        // Bool` is nil and `true as Any as? Int` is nil — Swift requires exact type
        // identity, with no Bool/Int bridging.
        XCTAssertEqual(AnyCodableValue(any: true), .bool(true))
        XCTAssertEqual(AnyCodableValue(any: false), .bool(false))
        XCTAssertEqual(AnyCodableValue(any: 1), .int(1))
        XCTAssertEqual(AnyCodableValue(any: 0), .int(0))

        // These are the values the ordering actually exists for. A single NSNumber
        // can satisfy both bridges, so Bool-first keeps a real boolean from
        // degrading to .int(1) on the wire.
        XCTAssertEqual(AnyCodableValue(any: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(AnyCodableValue(any: NSNumber(value: 1)), .int(1))
    }

    func testOptionalsBoxedInAnyDoNotBecomeTheStringNil() {
        // The public entry points take [String: Any], so `["email": user.email]`
        // with an optional email boxes the OPTIONAL. Without unwrapping, a nil
        // arrives as the literal attribute value "nil" and targeting sees it.
        let absent: String? = nil
        let present: String? = "a@b.com"

        XCTAssertEqual(AnyCodableValue(any: absent as Any), .null)
        XCTAssertEqual(AnyCodableValue(any: present as Any), .string("a@b.com"))

        let config = FeatureflipConfig(clientKey: "k", context: ["email": absent as Any])
        XCTAssertEqual(config.context["email"], .null)
    }

    func testWiderNumericTypesStayNumbers() {
        // Int64/Int32/UInt/CGFloat/Decimal satisfy none of the native casts and
        // would stringify — the #2293 bug again for a narrower set of callers.
        XCTAssertEqual(AnyCodableValue(any: Int64(5)), .int(5))
        XCTAssertEqual(AnyCodableValue(any: Int32(5)), .int(5))
        XCTAssertEqual(AnyCodableValue(any: UInt(5)), .int(5))
        XCTAssertEqual(AnyCodableValue(any: Float(1.5)), .double(1.5))
    }

    func testBridgeHandlesNilAndNested() {
        XCTAssertEqual(AnyCodableValue(any: nil), .null)
        XCTAssertEqual(AnyCodableValue(any: ["a", "b"]), .array([.string("a"), .string("b")]))
        XCTAssertEqual(AnyCodableValue(any: ["k": 1]), .dictionary(["k": .int(1)]))
    }

    func testNumericUserIdIsTreatedAsARealCallerId() {
        // resolveAnonymousContext tested blankness on a String. A numeric id must not
        // be mistaken for an absent one and overwritten with a generated anon key.
        let store = MemoryStore()

        let resolved = resolveAnonymousContext(["user_id": 4242], store: store)

        XCTAssertEqual(resolved["user_id"], .int(4242))
        XCTAssertNil(store.read())
    }

    func testStreamURLEncodesContextWithTypesPreserved() throws {
        let url = StreamingDataSource.buildStreamURL(
            baseUrl: "https://example.com",
            clientKey: "k",
            context: ["age": 25]
        )

        let encoded = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "context" })?.value
        )
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let json = String(data: decoded, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"age\":25"), json)
    }
}
