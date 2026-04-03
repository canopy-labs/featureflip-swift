import Foundation

/// Batches analytics events and flushes them to the evaluation API.
actor EventProcessor {
    private var buffer: [SdkEvent] = []
    private let httpClient: HttpClient
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private var flushTask: Task<Void, Never>?

    init(httpClient: HttpClient, flushInterval: TimeInterval, batchSize: Int) {
        self.httpClient = httpClient
        self.flushInterval = flushInterval
        self.batchSize = batchSize
    }

    func start() {
        flushTask = Task { [weak self, flushInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                    await self?.flush()
                } catch {
                    break
                }
            }
        }
    }

    func enqueue(_ event: SdkEvent) {
        buffer.append(event)
        if buffer.count >= batchSize {
            // Fire-and-forget flush when batch size reached.
            // We don't await here to avoid blocking the caller; the actor
            // serialises access so the buffer swap is still safe.
            let events = buffer
            buffer = []
            Task { [httpClient] in
                try? await httpClient.postEvents(events)
            }
        }
    }

    func flush() async {
        guard !buffer.isEmpty else { return }
        let events = buffer
        buffer = []
        try? await httpClient.postEvents(events)
    }

    func stop() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }
}
