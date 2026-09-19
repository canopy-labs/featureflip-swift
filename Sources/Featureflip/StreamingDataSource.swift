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
    private var context: [String: AnyCodableValue]
    private let onChange: @Sendable ([String: FlagValue]) -> Void
    // Full snapshot the server sends first on every (re)connect -> apply as a REPLACE.
    // Required, not optional-defaulting-to-onChange: an omitted snapshot handler would
    // silently merge the connect snapshot and resurrect flags deleted during the outage
    // (#1873), and no dispatch test can see that -- they all pass it explicitly.
    private let onSnapshot: @Sendable ([String: FlagValue]) -> Void
    // Invoked ONCE per outage, when the stream has failed maxRetries times, so the
    // core can start polling ALONGSIDE this still-retrying stream. Never a terminal
    // give-up: the connect loop keeps going at the capped backoff (#3075).
    private let onFallbackToPolling: (@Sendable () -> Void)?
    // Invoked when a stream that had fallen back delivers a frame again, so the core
    // can retire the fallback poller.
    private let onStreamRecovered: (@Sendable () -> Void)?
    private var task: Task<Void, Never>?
    // The delay the first reconnect waits, and the value backoff resets to. Held as
    // an instance property (rather than reading the static directly) so tests can
    // drive the retry cap without waiting out the real 1s-and-doubling schedule —
    // mirrors the android source's `initialBackoffMs` parameter.
    private let baseBackoff: TimeInterval
    private var backoff: TimeInterval
    private var retryCount = 0
    // True between arming the polling fallback and the next delivered frame. Gates
    // both callbacks so each fires once per outage rather than once per retry.
    //
    // Deliberately NOT cleared by `start()`: that is reachable from
    // `handleForeground()` and `updateContext()` while a fallback poller is live, and
    // clearing it there would lose the only record that a poller is waiting to be
    // retired — leaving it running beside a recovered stream forever, which is the
    // defect this fixes.
    private var fallbackActive = false
    private let lock = NSLock()

    init(
        baseUrl: String,
        clientKey: String,
        context: [String: AnyCodableValue],
        onChange: @escaping @Sendable ([String: FlagValue]) -> Void,
        onSnapshot: @escaping @Sendable ([String: FlagValue]) -> Void,
        onFallbackToPolling: (@Sendable () -> Void)? = nil,
        onStreamRecovered: (@Sendable () -> Void)? = nil,
        initialBackoff: TimeInterval = StreamingDataSource.initialBackoff
    ) {
        self.baseUrl = baseUrl
        self.clientKey = clientKey
        self.context = context
        self.onChange = onChange
        self.onSnapshot = onSnapshot
        self.onFallbackToPolling = onFallbackToPolling
        self.onStreamRecovered = onStreamRecovered
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

    func updateContext(_ newContext: [String: AnyCodableValue]) {
        lock.lock()
        context = newContext
        lock.unlock()
        stop()
        start()
    }

    /// Whether the polling fallback is currently armed — i.e. the stream has
    /// exhausted its retry budget and has not delivered a frame since. Visible for
    /// testing; the stream keeps retrying regardless.
    var hasFallenBackToPolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fallbackActive
    }

    /// Consecutive failed connect attempts. Visible for testing, so a test can show
    /// the loop still reconnecting past `maxRetries`.
    var retryAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return retryCount
    }

    // MARK: - Internal (visible for testing)

    static func buildStreamURL(
        baseUrl: String,
        clientKey: String,
        context: [String: AnyCodableValue]
    ) -> URL? {
        guard var components = URLComponents(string: baseUrl + "/v1/client/stream") else { return nil }
        // JSONEncoder, not JSONSerialization: context values are AnyCodableValue
        // (Codable) since #2293, not plist types.
        //
        // This encode can now actually fail — JSONEncoder throws on a non-finite
        // Double, which context could not express while it was [String: String].
        // Swallowing that would connect the stream with an EMPTY context, silently
        // evaluating every user as anonymous with no signal anywhere (#2322).
        let contextJSON: Data
        do {
            contextJSON = try JSONEncoder().encode(context)
        } catch {
            Diagnostics.log(
                "could not encode context for the stream URL, connecting without it: \(error)"
            )
            contextJSON = Data()
        }
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

    /// Returns a value in [d/2, d] to de-correlate reconnects across many SDK
    /// instances (thundering-herd avoidance after a shared outage).
    ///
    /// Applied to EVERY reconnect, including the first. The drops this absorbs are
    /// fleet-wide — one edge event severs every stream at once (#2457) — so every
    /// client re-enters the backoff together. Sleeping the raw ladder value there
    /// republished the drop's own synchronisation as a reconnect spike one backoff
    /// later (#2508). The band stays strictly positive, so a stream that fails
    /// immediately still cannot busy-loop.
    static func withJitter(_ delay: TimeInterval) -> TimeInterval {
        guard delay > 0 else { return delay }
        let half = delay / 2
        return half + TimeInterval.random(in: 0...half)
    }

    // MARK: - Private

    private func connectLoop() async {
        while !Task.isCancelled {
            do {
                try await connect()
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }

            // Read the ladder AFTER connect(), not before: a healthy connection can
            // last hours and resets the ladder from inside, so a value captured up
            // front would make the first reconnect after it sleep the pre-outage
            // delay — up to the 30s cap — instead of the base.
            lock.lock()
            retryCount += 1
            let armFallback = retryCount >= Self.maxRetries && !fallbackActive
            if armFallback { fallbackActive = true }
            // The ladder state (backoff) stays un-jittered so the doubling is exact;
            // only the scheduled wait is scattered.
            let currentBackoff = backoff
            backoff = Self.nextBackoff(backoff)
            lock.unlock()

            // The fallback is ADDITIVE, never terminal (#3075). Polling covers the
            // outage while this loop keeps retrying the stream underneath at the
            // capped backoff, and the next config frame retires the poller. Returning
            // here instead left the app polling — and blind to real-time updates, kill
            // switches included — until it was restarted, after only ~31s of
            // unreachability.
            //
            // Armed on the failure itself rather than at the top of the next
            // iteration, so the poller starts covering the outage ~15s in rather than
            // after the fifth backoff has also elapsed (~31s) — matching flutter and
            // the js core.
            if armFallback { onFallbackToPolling?() }

            try? await Task.sleep(nanoseconds: UInt64(Self.withJitter(currentBackoff) * 1_000_000_000))
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

        var lineBuffer: [String] = []
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if line.isEmpty {
                if let event = Self.parseSSEEvent(from: lineBuffer) {
                    handleEvent(event)
                    // AFTER the store has been updated, never before: retiring the
                    // fallback poller is what this signals, and a poller retired one
                    // frame early can still land an older whole-store replace on top
                    // of the snapshot just applied.
                    if event.eventType == "flags-updated" { configDelivered() }
                }
                lineBuffer = []
            } else {
                lineBuffer.append(line)
            }
        }
    }

    /// DELIVERED CONFIG — not merely an accepted socket — is what proves the stream
    /// healthy, and it is the condition the rest of the fleet resets on (js and java
    /// on `sync`, go on its first complete frame, which for the server stream *is*
    /// `sync`). Resetting on the 200 instead let an accept-then-close server clear the
    /// counter every cycle, so the retry budget was never exhausted, the polling
    /// fallback could never arm, and the app saw nothing at all for the duration of
    /// such an outage (#3074).
    ///
    /// Keyed on `flags-updated` rather than on any frame because the client stream's
    /// FIRST frame is `connection-ready`, a ~40-byte handshake carrying no config: a
    /// server that accepts, greets and dies would otherwise reset the budget forever
    /// and re-open exactly the hole above. Deliberately still counted when the payload
    /// fails to parse — the stream itself is demonstrably up, the store keeps its
    /// last-known-good, and the parse failure is reported on its own path.
    ///
    /// Recovery is signalled from HERE rather than from `connectLoop()`: `connect()`
    /// blocks reading lines for the whole lifetime of a healthy stream, so a reap on
    /// its return would leave the poller alive that entire time, its periodic
    /// whole-store replaces reverting the deltas this stream applies.
    func configDelivered() {
        lock.lock()
        retryCount = 0
        backoff = baseBackoff
        let recovered = fallbackActive
        fallbackActive = false
        lock.unlock()

        if recovered { onStreamRecovered?() }
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
                onSnapshot(response.flags)
            } else {
                onChange(response.flags)
            }
        } catch {
            // Ignore parse errors
        }
    }
}
