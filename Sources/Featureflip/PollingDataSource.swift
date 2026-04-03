import Foundation

/// Periodically fetches evaluated flags via HTTP polling.
final class PollingDataSource: @unchecked Sendable {
    private let httpClient: HttpClient
    private var context: [String: String]
    private let interval: TimeInterval
    private let onChange: @Sendable ([String: FlagValue]) -> Void
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    init(
        httpClient: HttpClient,
        context: [String: String],
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

    func updateContext(_ newContext: [String: String]) {
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
