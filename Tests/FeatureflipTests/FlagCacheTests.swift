import XCTest
@testable import Featureflip

final class FlagCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSetAndGetFlags() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        let flags: [String: FlagValue] = [
            "flag-a": FlagValue(value: .bool(true), variation: "on", reason: "Fallthrough"),
        ]
        await cache.setAll(flags)
        let value = await cache.get("flag-a")
        XCTAssertEqual(value?.variation, "on")
    }

    func testGetReturnsNilForMissing() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        let value = await cache.get("nonexistent")
        XCTAssertNil(value)
    }

    func testPersistsToDisk() async {
        let cache1 = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        let flags: [String: FlagValue] = [
            "persisted": FlagValue(value: .string("hello"), variation: "v1", reason: "RuleMatch"),
        ]
        await cache1.setAll(flags)

        let cache2 = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        await cache2.loadFromDisk()
        let value = await cache2.get("persisted")
        XCTAssertEqual(value?.variation, "v1")
    }

    func testSetAllReplacesExisting() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        await cache.setAll(["a": FlagValue(value: .bool(true), variation: "on", reason: "r")])
        await cache.setAll(["b": FlagValue(value: .bool(false), variation: "off", reason: "r")])

        let a = await cache.get("a")
        let b = await cache.get("b")
        XCTAssertNil(a)
        XCTAssertNotNil(b)
    }

    func testAllFlags() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        let flags: [String: FlagValue] = [
            "a": FlagValue(value: .bool(true), variation: "on", reason: "r"),
            "b": FlagValue(value: .string("x"), variation: "v", reason: "r"),
        ]
        await cache.setAll(flags)
        let all = await cache.all()
        XCTAssertEqual(all.count, 2)
    }

    func testMergeAddsAndUpdatesFlags() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        await cache.setAll([
            "a": FlagValue(value: .bool(true), variation: "on", reason: "r"),
            "b": FlagValue(value: .string("old"), variation: "v1", reason: "r"),
        ])

        await cache.merge([
            "b": FlagValue(value: .string("new"), variation: "v2", reason: "r"),
            "c": FlagValue(value: .int(42), variation: "v1", reason: "r"),
        ])

        let a = await cache.get("a")
        let b = await cache.get("b")
        let c = await cache.get("c")
        XCTAssertNotNil(a)
        XCTAssertEqual(b?.value, .string("new"))
        XCTAssertEqual(c?.value, .int(42))
    }

    func testMergeRemovesFlagWithFlagRemoved() async {
        let cache = FlagCache(clientKey: "test", cacheDirectory: tempDir)
        await cache.setAll([
            "a": FlagValue(value: .bool(true), variation: "on", reason: "r"),
            "b": FlagValue(value: .string("hello"), variation: "v1", reason: "r"),
        ])

        await cache.merge([
            "b": FlagValue(value: .null, variation: "", reason: "FLAG_REMOVED"),
        ])

        let a = await cache.get("a")
        let b = await cache.get("b")
        XCTAssertNotNil(a)
        XCTAssertNil(b)
    }
}
