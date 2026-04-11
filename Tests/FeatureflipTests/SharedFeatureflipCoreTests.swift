import XCTest
@testable import Featureflip

final class SharedFeatureflipCoreTests: XCTestCase {

    func testNewCoreStartsAtRefcountOne() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertEqual(core.refCount, 1)
        core.release()
    }

    func testAcquireIncrementsRefcount() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertTrue(core.acquire())
        XCTAssertEqual(core.refCount, 2)
        core.release()
        core.release()
    }

    func testReleaseDecrementsRefcount() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        _ = core.acquire() // 2
        core.release()     // 1
        XCTAssertEqual(core.refCount, 1)
        core.release()     // 0, shut down
    }

    func testReleaseAtZeroMarksCoreShutDown() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release()
        XCTAssertTrue(core.isShutDown)
    }

    func testAcquireAfterShutdownReturnsFalse() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release()
        XCTAssertFalse(core.acquire())
        XCTAssertEqual(core.refCount, 0)
    }

    func testAcquireAfterOverReleaseReturnsFalse() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        core.release() // 1->0
        core.release() // over-release, no-op
        XCTAssertFalse(core.acquire())
        XCTAssertTrue(core.isShutDown)
    }

    func testGetFlagReturnsNilForMissingKey() {
        let core = SharedFeatureflipCore.createForTestingSkeleton()
        XCTAssertNil(core.getFlag("nonexistent"))
        core.release()
    }

    func testForTestingOverridesReturnFixedValues() {
        let core = SharedFeatureflipCore.createForTestingStub(["dark-mode": true, "theme": "blue"])
        XCTAssertEqual(core.boolVariation("dark-mode", default: false), true)
        XCTAssertEqual(core.stringVariation("theme", default: "default"), "blue")
        XCTAssertEqual(core.boolVariation("missing", default: false), false)
        core.release()
    }
}
