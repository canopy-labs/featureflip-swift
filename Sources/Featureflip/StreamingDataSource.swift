import Foundation

/// Parsed SSE event.
struct SSEEvent {
    let eventType: String
    let data: String
}

/// Connects to the evaluation API SSE stream for real-time flag updates.
final class StreamingDataSource: @unchecked Sendable {
    static let initialBackoff: TimeInterval = 1.0
    static let maxBackoff: TimeInterval = 30.0
    static let maxRetries = 5

    private let baseUrl: String
    private let clientKey: String
    private var context: [String: String]
    private let onChange: @Sendable ([String: FlagValue]) -> Void
    // Full snapshot the server sends first on every (re)connect -> apply as a REPLACE.
    private let onSnapshot: (@Sendable ([String: FlagValue]) -> Void)?
    // Invoked when the stream has failed maxRetries times so the core can fall back
    // to polling (which retries forever). Never a terminal give-up.
    private let onMaxRetriesReached: (@Sendable () -> Void)?
    private var task: Task<Void, Never>?
    // The delay the first reconnect waits, and the value backoff resets to. Held as
    // an instance property (rather than reading the static directly) so tests can
    // drive the retry cap without waiting out the real 1s-and-doubling schedule —
    // mirrors the android source's `initialBackoffMs` parameter.
    private let baseBackoff: TimeInterval
    private var backoff: TimeInterval
    private var retryCount = 0
    private let lock = NSLock()

    init(
        baseUrl: String,
        clientKey: String,
        context: [String: String],
        onChange: @escaping @Sendable ([String: FlagValue]) -> Void,
        onSnapshot: (@Sendable ([String: FlagValue]) -> Void)? = nil,
        onMaxRetriesReached: (@Sendable () -> Void)? = nil,
        initialBackoff: TimeInterval = StreamingDataSource.initialBackoff
    ) {
        self.baseUrl = baseUrl
        self.clientKey = clientKey
        self.context = context
        self.onChange = onChange
        self.onSnapshot = onSnapshot
        self.onMaxRetriesReached = onMaxRetriesReached
        self.baseBackoff = initialBackoff
        self.backoff = initialBackoff
    }

    func start() {
        task?.cancel()
        // Reset retry state for fresh connection attempt
        lock.lock()
        retryCount = 0
        backoff = baseBackoff
        lock.unlock()

        task = Task { [weak self] in
            await self?.connectLoop()
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
        stop()
        start()
    }

    var isMaxRetriesReached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retryCount >= Self.maxRetries
    }

    // MARK: - Internal (visible for testing)

    static func buildStreamURL(
        baseUrl: String,
        clientKey: String,
        context: [String: String]
    ) -> URL? {
        guard var components = URLComponents(string: baseUrl + "/v1/client/stream") else { return nil }
        let contextJSON = (try? JSONSerialization.data(withJSONObject: context)) ?? Data()
        let encodedContext = contextJSON.base64EncodedString()
        components.queryItems = [
            URLQueryItem(name: "authorization", value: clientKey),
            URLQueryItem(name: "context", value: encodedContext),
        ]
        return components.url
    }

    static func parseSSEEvent(from lines: [String]) -> SSEEvent? {
        var eventType: String?
        var data: String?
        for line in lines {
            if line.hasPrefix("event:") {
                let value = line.dropFirst(6)
                eventType = String(value.hasPrefix(" ") ? value.dropFirst() : value)
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5)
                let parsed = String(value.hasPrefix(" ") ? value.dropFirst() : value)
                // SSE spec: multiple data lines are joined with newlines
                if let existing = data {
                    data = existing + "\n" + parsed
                } else {
                    data = parsed
                }
            }
        }
        guard let eventType else { return nil }
        return SSEEvent(eventType: eventType, data: data ?? "")
    }

    static func nextBackoff(_ current: TimeInterval) -> TimeInterval {
        min(current * 2, maxBackoff)
    }

    // MARK: - Private

    private func connectLoop() async {
        while !Task.isCancelled {
            lock.lock()
            let currentRetryCount = retryCount
            let currentBackoff = backoff
            lock.unlock()

            guard currentRetryCount < Self.maxRetries else {
                // Not terminal: hand off to the polling fallback (retries forever).
                onMaxRetriesReached?()
                return
            }

            do {
                try await connect()
            } catch {
                if Task.isCancelled { return }
            }

            lock.lock()
            retryCount += 1
            lock.unlock()

            try? await Task.sleep(nanoseconds: UInt64(currentBackoff * 1_000_000_000))

            lock.lock()
            backoff = Self.nextBackoff(backoff)
            lock.unlock()
        }
    }

    private func connect() async throws {
        lock.lock()
        let currentContext = context
        lock.unlock()

        guard let url = Self.buildStreamURL(baseUrl: baseUrl, clientKey: clientKey, context: currentContext) else { return }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

        // Reset backoff on successful connection.
        lock.lock()
        backoff = baseBackoff
        retryCount = 0
        lock.unlock()

        var lineBuffer: [String] = []
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if line.isEmpty {
                if let event = Self.parseSSEEvent(from: lineBuffer) {
                    handleEvent(event)
                }
                lineBuffer = []
            } else {
                lineBuffer.append(line)
            }
        }
    }

    func handleEvent(_ event: SSEEvent) {
        // connection-ready carries only the connectionId (unused here) — ignore it.
        guard event.eventType == "flags-updated" else { return }
        guard let data = event.data.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(EvaluateResponse.self, from: data)
            // The connect-time snapshot is marked `full: true` (#1873) -> REPLACE the
            // store (drops flags deleted during the outage). Deltas omit it -> MERGE.
            // Keyed off the explicit marker, not event order, so a delta racing ahead
            // of the snapshot can't be mistaken for a full replace.
            if response.full == true {
                (onSnapshot ?? onChange)(response.flags)
            } else {
                onChange(response.flags)
            }
        } catch {
            // Ignore parse errors
        }
    }
}
