import XCTest
@testable import Featureflip

final class LifecycleObserverTests: XCTestCase {
    func testForegroundCallsHandler() {
        var foregroundCalled = false
        var backgroundCalled = false
        let observer = LifecycleObserver(
            onForeground: { foregroundCalled = true },
            onBackground: { backgroundCalled = true }
        )
        observer.simulateForeground()
        XCTAssertTrue(foregroundCalled)
        XCTAssertFalse(backgroundCalled)
    }

    func testBackgroundCallsHandler() {
        var foregroundCalled = false
        var backgroundCalled = false
        let observer = LifecycleObserver(
            onForeground: { foregroundCalled = true },
            onBackground: { backgroundCalled = true }
        )
        observer.simulateBackground()
        XCTAssertFalse(foregroundCalled)
        XCTAssertTrue(backgroundCalled)
    }
}
