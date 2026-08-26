import Foundation

/// Periodically fetches evaluated flags via HTTP polling.
final class PollingDataSource: @unchecked Sendable {
    private let httpClient: HttpClient
    private var context: [String: AnyCodableValue]
    private let interval: TimeInterval
    private let onChange: @Sendable ([String: FlagValue]) -> Void
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    init(
        httpClient: HttpClient,
        context: [String: AnyCodableValue],
        interval: TimeInterval,
        onChange: @escaping @Sendable ([String: FlagValue]) -> Void
    ) {
        self.httpClient = httpClient
        self.context = context
        self.interval = interval
        self.onChange = onChange
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            // A `Task` body always runs, even when the task was cancelled before it
            // was ever scheduled — so without this check `stop()` cannot prevent the
            // first poll, only the ones after it. `initialize()` then `close()` leaves
            // a cancelled poller that still issues exactly one request at an arbitrary
            // later moment, against the context it was constructed with (#2481).
            //
            // Kotlin's `scope.launch` never invokes a body cancelled before dispatch,
            // so this restores parity with the Android SDK's PollingDataSource rather
            // than inventing new behaviour.
            if Task.isCancelled { return }
            await self.pollOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self.pollOnce()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func updateContext(_ newContext: [String: AnyCodableValue]) {
        lock.lock()
        context = newContext
        lock.unlock()
    }

    func pollOnce() async {
        lock.lock()
        let currentContext = context
        lock.unlock()
        do {
            let result = try await httpClient.evaluate(context: currentContext)
            onChange(result.flags)
        } catch {
            // Silent — don't crash on network errors
        }
    }
}
