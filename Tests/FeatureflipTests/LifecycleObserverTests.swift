import XCTest
@testable import Featureflip

private final class Flag: @unchecked Sendable {
    var value = false
}

final class LifecycleObserverTests: XCTestCase {
    func testForegroundCallsHandler() {
        let foregroundCalled = Flag()
        let backgroundCalled = Flag()
        let observer = LifecycleObserver(
            onForeground: { foregroundCalled.value = true },
            onBackground: { backgroundCalled.value = true }
        )
        observer.simulateForeground()
        XCTAssertTrue(foregroundCalled.value)
        XCTAssertFalse(backgroundCalled.value)
    }

    func testBackgroundCallsHandler() {
        let foregroundCalled = Flag()
        let backgroundCalled = Flag()
        let observer = LifecycleObserver(
            onForeground: { foregroundCalled.value = true },
            onBackground: { backgroundCalled.value = true }
        )
        observer.simulateBackground()
        XCTAssertFalse(foregroundCalled.value)
        XCTAssertTrue(backgroundCalled.value)
    }
}
