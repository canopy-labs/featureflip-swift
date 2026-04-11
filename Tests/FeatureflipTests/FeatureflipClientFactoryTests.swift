import XCTest
@testable import Featureflip

final class FeatureflipClientFactoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _resetForTesting()
    }

    override func tearDown() {
        _resetForTesting()
        super.tearDown()
    }

    func testFirstCallReturnsCore() {
        let core = _getOrCreateCoreForTesting(clientKey: "key-first")
        XCTAssertNotNil(core)
        XCTAssertEqual(core.refCount, 1)
        XCTAssertEqual(_liveCoresCount, 1)
        core.release()
    }

    func testSameKeyTwiceSharesOneCore() {
        let c1 = _getOrCreateCoreForTesting(clientKey: "key-same")
        let c2 = _getOrCreateCoreForTesting(clientKey: "key-same")
        XCTAssertTrue(c1 === c2)
        XCTAssertEqual(c1.refCount, 2)
        XCTAssertEqual(_liveCoresCount, 1)
        c1.release()
        c2.release()
    }

    func testDifferentKeysCreateIndependentCores() {
        let c1 = _getOrCreateCoreForTesting(clientKey: "key-a")
        let c2 = _getOrCreateCoreForTesting(clientKey: "key-b")
        XCTAssertFalse(c1 === c2)
        XCTAssertEqual(_liveCoresCount, 2)
        c1.release()
        c2.release()
    }

    func testCloseOnlyHandleRemovesFromCache() {
        let c1 = _getOrCreateCoreForTesting(clientKey: "key-recycle")
        c1.release() // 1->0, shutdown, remove from cache
        XCTAssertEqual(_liveCoresCount, 0)

        let c2 = _getOrCreateCoreForTesting(clientKey: "key-recycle")
        XCTAssertEqual(_liveCoresCount, 1)
        c2.release()
    }

    func testReleaseOneOfTwoKeepsCoreAlive() {
        let c1 = _getOrCreateCoreForTesting(clientKey: "key-two")
        let c2 = _getOrCreateCoreForTesting(clientKey: "key-two")
        c1.release()
        XCTAssertEqual(c2.refCount, 1)
        XCTAssertEqual(_liveCoresCount, 1)
        c2.release()
    }

    func testConcurrentSameKeyAllShareOneCore() {
        let threadCount = 32
        let expectation = XCTestExpectation(description: "All threads complete")
        expectation.expectedFulfillmentCount = threadCount
        let resultsLock = NSLock()
        var results = [SharedFeatureflipCore?](repeating: nil, count: threadCount)

        for i in 0..<threadCount {
            DispatchQueue.global().async {
                let core = _getOrCreateCoreForTesting(clientKey: "key-concurrent")
                resultsLock.withLock {
                    results[i] = core
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(_liveCoresCount, 1)
        let first = results[0]!
        for r in results {
            XCTAssertTrue(r === first)
        }
        XCTAssertEqual(first.refCount, threadCount)

        // Cleanup
        for _ in 0..<threadCount {
            first.release()
        }
    }
}
