import Foundation

/// Batches analytics events and flushes them to the evaluation API.
actor EventProcessor {
    /// Upper bound on buffered events.
    ///
    /// Deliberately lower than the 10,000 the server SDKs use. This is a mobile
    /// client: memory is tighter and event volume is far lower. What matters for
    /// cross-SDK parity is the rule — shed the OLDEST first — not the number.
    static let defaultMaxBufferSize = 1000

    private var buffer: [SdkEvent] = []
    private let httpClient: HttpClient
    private let batchSize: Int
    private let maxBufferSize: Int
    private let flushInterval: TimeInterval
    private var flushTask: Task<Void, Never>?

    /// When the batch-size trigger may next start a flush.
    ///
    /// A re-queued batch leaves the buffer at or above `batchSize`, so without this
    /// gate every subsequent `enqueue` would start another flush — turning a failing
    /// endpoint into one request per recorded event, which is worse for the server
    /// than losing the events. The periodic task is the retry vehicle; this only
    /// suppresses the size trigger between its ticks.
    private var nextAutoFlushAt: Date?

    /// True while a size-triggered flush is running.
    ///
    /// The gate above is only armed once a flush has already FAILED, and the trigger
    /// fires again long before the first round-trip returns — so without this latch a
    /// burst of events still starts a flush each.
    private var autoFlushInFlight = false

    /// How many drain loops are running.
    ///
    /// `autoFlushInFlight` only gates the size trigger; nothing stopped the periodic
    /// task, `SharedFeatureflipCore.flush()` and a background-transition flush from
    /// entering the loop at the same time. Two concurrent drains meant two request
    /// streams against the endpoint the backoff exists to protect — and worse, a
    /// success in one would clear `nextAutoFlushAt` that a failure in the other had
    /// just armed, re-opening the one-request-per-event behaviour outright.
    /// A counter, not a flag, because `stop()` deliberately bypasses the coalescing
    /// guard: with two drains overlapping, whichever finished first would clear a
    /// boolean while the other was still looping, letting a third drain start and
    /// re-opening the very hazard this exists to close.
    private var activeDrains = 0

    /// The drain `flush()` started, while it is still running.
    ///
    /// `activeDrains` can only say THAT a drain is running; a caller that must WAIT for
    /// one needs something to await. Until #2477 `flush()` returned as soon as it saw a
    /// drain in flight, which is a weaker promise than every other SDK makes: js and node
    /// have always returned the in-flight promise, so `await flush()` there resolves only
    /// once the send has settled. A caller that awaited `flush()` is asking for its events
    /// to be sent, and handing back early is a promise the SDK has not kept.
    private var inFlightDrain: Task<Void, Never>?

    private var closed = false

    init(
        httpClient: HttpClient,
        flushInterval: TimeInterval,
        batchSize: Int,
        maxBufferSize: Int = EventProcessor.defaultMaxBufferSize
    ) {
        self.httpClient = httpClient
        self.flushInterval = flushInterval
        // Clamped: `flush` loops on this, so a non-positive value would take nothing
        // per pass and spin on a non-empty buffer.
        self.batchSize = max(1, batchSize)
        self.maxBufferSize = maxBufferSize >= 1 ? maxBufferSize : EventProcessor.defaultMaxBufferSize
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
        // `stop()` cancels the periodic task and nothing restarts it, so accepting
        // events afterwards would strand any tail shorter than `batchSize` — the size
        // trigger never fires for it and no drain ever comes. Rejecting at the door
        // loses the same events far more visibly.
        //
        // This does mean one handle closing silences analytics for other handles
        // sharing the same refcounted core. That is a lifecycle bug in
        // SharedFeatureflipCore.close(), which stops the processor for every handle
        // rather than only at refcount zero, and it is tracked separately.
        guard !closed else { return }

        buffer.append(event)
        trimToBound()

        guard buffer.count >= batchSize, canAutoFlush() else { return }
        autoFlushInFlight = true
        Task { [weak self] in
            await self?.runAutoFlush()
        }
    }

    /// Flushes buffered events, one request per batch.
    ///
    /// Sending the whole buffer at once only became a risk once failures started
    /// being kept: a backlog can now reach `maxBufferSize`, and a body that size
    /// invites a 413 — which is not retryable, so the path meant to preserve the
    /// backlog would be the one that discarded it.
    func flush() async {
        // Coalesce: a drain is already emptying the buffer, and a second one would
        // only duplicate the request stream and let its success clear a backoff the
        // first one's failure just armed. Awaited rather than skipped — see
        // `inFlightDrain`.
        if let existing = inFlightDrain {
            await existing.value
            return
        }

        // `stop()`'s final drain bypasses coalescing and publishes no handle, so there
        // is nothing to await. It is also the last drain there will ever be, which
        // leaves a second one nothing useful to do.
        guard activeDrains == 0 else { return }

        let task = Task { [weak self] in
            await self?.drain()
            await self?.releaseDrainHandle()
        }
        inFlightDrain = task
        await task.value
    }

    /// Clears the coalescing handle once its drain has finished.
    ///
    /// Only the task that set the handle clears it, and a caller arriving in the window
    /// between the drain finishing and this running awaits an already-finished task and
    /// returns — the same harmless window js has between its loop ending and
    /// `flushPromise` being nulled.
    private func releaseDrainHandle() {
        inFlightDrain = nil
    }

    /// The drain loop itself, callable when coalescing must be bypassed.
    private func drain() async {
        activeDrains += 1
        defer { activeDrains -= 1 }

        while !buffer.isEmpty {
            let take = min(batchSize, buffer.count)
            let batch = Array(buffer.prefix(take))
            buffer.removeFirst(take)

            do {
                try await httpClient.postEvents(batch)
                nextAutoFlushAt = nil
            } catch {
                if EventProcessor.isRetryableSendFailure(error) {
                    requeue(batch, error)
                    // Stop here. The batch is back at the head of the buffer this loop
                    // is draining, so continuing would re-send it at once and spin for
                    // as long as the endpoint stayed down.
                    return
                }

                // A 401/403 means the key was rejected and a 400 means the body is
                // malformed; both fail identically next time. Dropping shrinks the
                // buffer, so the loop still ends, and moving on means one poison batch
                // cannot block the backlog queued behind it.
                Diagnostics.log(
                    "dropped \(batch.count) analytics event(s) the events endpoint rejected permanently: \(error)"
                )
                if closed { return }
            }
        }
    }

    func stop() async {
        flushTask?.cancel()
        flushTask = nil
        // Set before the final flush so a failure inside it discards rather than
        // re-queueing into a buffer nothing will ever drain.
        closed = true
        // drain(), not flush(): shutdown must never be the call that gets coalesced
        // away. If a periodic drain happens to be in flight, flush() would return
        // immediately and the buffer below would be discarded unsent. Running two
        // drains concurrently is safe here precisely because `closed` is already set,
        // so neither can re-queue and there is no backoff left to disarm.
        await drain()
        if !buffer.isEmpty {
            // drain() stops at the first retryable failure, so anything still here is
            // being dropped. Say so rather than losing it silently.
            // "at least": a concurrent drain may hold a batch it already removed.
            Diagnostics.log("dropped at least \(buffer.count) further analytics event(s) at shutdown")
        }
        buffer.removeAll()
    }

    // MARK: - Private

    private func runAutoFlush() async {
        await flush()
        autoFlushInFlight = false
    }

    private func canAutoFlush() -> Bool {
        if autoFlushInFlight { return false }
        guard let gate = nextAutoFlushAt else { return true }
        return Date() >= gate
    }

    /// Whether the same batch could succeed if sent again.
    ///
    /// Until #2456 this question was never asked: `try? await httpClient.postEvents`
    /// discarded the error, so every 503, timeout and offline blip silently threw the
    /// batch away — the HTTP layer detected the failure correctly and `try?` dropped
    /// the detection on the floor.
    ///
    /// A 5xx or 429 is the server asking for another attempt. A rejected key, a
    /// malformed body or an encoding failure will fail identically forever, and
    /// keeping those would pin a poison batch at the head of the buffer. Anything
    /// else — `URLError` and friends — is a transport fault a later flush may get
    /// past, so it is kept.
    private static func isRetryableSendFailure(_ error: Swift.Error) -> Bool {
        if let httpError = error as? HttpClient.Error {
            switch httpError {
            case .httpError(let statusCode):
                // 0 is HttpClient's sentinel for a response that was not an
                // HTTPURLResponse at all — transport-shaped, not a rejection.
                return statusCode == 0 || statusCode >= 500 || statusCode == 429
            case .invalidURL:
                return false
            }
        }
        if error is EncodingError { return false }
        return true
    }

    /// Returns a batch that failed to send to the FRONT of the buffer, so the next
    /// flush retries it ahead of newer events and rough chronological order survives.
    ///
    /// Deliberately not an inline retry: the batch is back in the buffer `flush` is
    /// draining, so re-sending here would spin for as long as the outage lasted.
    private func requeue(_ batch: [SdkEvent], _ error: Swift.Error) {
        guard !closed else {
            // Nothing will flush again, so buffering here would only lose them later
            // and less visibly.
            Diagnostics.log(
                "dropped \(batch.count) analytics event(s): shutting down and will not flush again: \(error)"
            )
            return
        }

        nextAutoFlushAt = Date().addingTimeInterval(flushInterval)
        buffer.insert(contentsOf: batch, at: 0)
        // Note the batch just rescued from the wire is now the OLDEST thing here, so
        // if events arrived during the send it is the first thing shed. That is the
        // documented rule working as intended: under sustained failure the stale
        // re-queued batch goes before newly recorded events do.
        trimToBound()
        Diagnostics.log(
            "failed to flush \(batch.count) analytics event(s); re-queued for the next flush: \(error)"
        )
    }

    /// Sheds oldest-first until the buffer fits `maxBufferSize`.
    private func trimToBound() {
        let overflow = buffer.count - maxBufferSize
        guard overflow > 0 else { return }
        buffer.removeFirst(overflow)
        Diagnostics.log("event buffer is full; dropped \(overflow) of the oldest analytics event(s)")
    }

    /// Test-only inspection. The buffer is private, and whether the bound held is only
    /// observable from outside by what it still contains.
    func bufferedEventCount() -> Int { buffer.count }

    /// Test-only inspection: which events survived, so a test can prove the bound
    /// shed the OLDEST rather than merely that it held.
    /// Uses a placeholder rather than `compactMap` so the result always has one entry
    /// per buffered event — a `compactMap` would silently shorten the array for events
    /// with no flag key, letting a future bound test assert against `[]` and pass
    /// vacuously.
    func bufferedFlagKeys() -> [String] { buffer.map { $0.flagKey ?? "<nil>" } }
}
