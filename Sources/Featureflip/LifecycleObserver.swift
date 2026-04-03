import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif

/// Observes app lifecycle events and calls handlers for foreground/background transitions.
final class LifecycleObserver: @unchecked Sendable {
    private let onForeground: @Sendable () -> Void
    private let onBackground: @Sendable () -> Void
    private var observers: [Any] = []

    init(
        onForeground: @escaping @Sendable () -> Void,
        onBackground: @escaping @Sendable () -> Void
    ) {
        self.onForeground = onForeground
        self.onBackground = onBackground
        registerNotifications()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func simulateForeground() {
        onForeground()
    }

    func simulateBackground() {
        onBackground()
    }

    private func registerNotifications() {
        #if os(iOS) || os(tvOS)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [onForeground] _ in onForeground() }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [onBackground] _ in onBackground() }
        )
        #elseif os(macOS)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [onForeground] _ in onForeground() }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { [onBackground] _ in onBackground() }
        )
        #elseif os(watchOS)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: WKApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [onForeground] _ in onForeground() }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: WKApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [onBackground] _ in onBackground() }
        )
        #endif
    }
}
