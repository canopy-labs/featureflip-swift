import Foundation

/// Reports the flags application code actually reads, as `Evaluation` events.
///
/// The server refuses to archive a flag that was evaluated in the last 24 hours, and
/// for a client SDK only the client can say "code still reads this flag": flag values
/// arrive pre-evaluated in one batch, so being *sent* a flag says nothing about
/// whether anything *reads* it. Each core owns one of these in front of its event
/// processor.
///
/// Deduplicated per window: the first read of a `(flagKey, variation, userId)` in a
/// window queues one event and repeats are dropped, so a view that reads a flag on
/// every render costs about one event an hour (plus one per return to the foreground,
/// which resets the window), not one per render. The guard only needs
/// "was read", so per-read counts are deliberately not kept. A window is a fixed hour:
/// the rollups are hourly and the guard looks back 24 hours, so reporting more often
/// would buy nothing. The first read after the hour clears the set and starts a new one.
///
/// Performance is the constraint here, because this sits on every variation call. A
/// REPEAT read is O(1), allocates nothing, does no I/O and no logging, and takes one
/// uncontended lock:
/// - a class with a lock, not an actor: the variation methods are synchronous, and an
///   actor would cost a `Task` per read. Only a first-in-window read creates a `Task`,
///   to hand its event to the `EventProcessor` actor.
/// - nested lookups `userId → flagKey → variations`, so no key struct, tuple or string
///   is built per read. The current user's branch is held apart from the rest, so a
///   repeat read hashes only the flag key and compares the variation against the one
///   or two already seen, never hashing the user id.
/// - the user id is cached here and changed only by `setUserId` (init and identify),
///   so a read never touches the core's context lock.
/// - `NSLock`, because `OSAllocatedUnfairLock` needs iOS 16 / tvOS 16 / watchOS 9 and
///   this package supports iOS 15 / tvOS 15 / watchOS 8.
final class ReadRecorder: @unchecked Sendable {
    /// One hour, in nanoseconds.
    static let defaultWindowNanos: UInt64 = 3_600 * 1_000_000_000

    /// Monotonic nanoseconds that keep counting while the device sleeps.
    ///
    /// Not `DispatchTime`: on Apple platforms it is `mach_absolute_time`, which stops
    /// while the device sleeps. A phone that sleeps most of the night would then stretch
    /// one "hour" of window across more than the guard's 24 hours, and a flag the app
    /// still reads would go unreported long enough to be archived. Darwin's
    /// `CLOCK_MONOTONIC` keeps counting through sleep and never goes backwards.
    static func monotonicNanos() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_MONOTONIC)
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif
    }

    private let windowNanos: UInt64
    private let now: @Sendable () -> UInt64
    private let sink: @Sendable (SdkEvent) -> Void

    private let lock = NSLock()
    private var userId: String?
    /// flagKey → variation keys (`""` for a missing flag) the CURRENT user has read
    /// this window. An array, not a set: a flag serves a user one or two variations in
    /// an hour, and comparing against those is cheaper than hashing.
    private var currentUserReads: [String: [String]] = [:]
    /// The same, for users this recorder has switched away from this window, keyed by
    /// user id (`""` for none). Only `setUserId` and the window reset touch it.
    private var otherUsersReads: [String: [String: [String]]] = [:]
    private var windowStart: UInt64?

    /// - Parameters:
    ///   - userId: the context's resolved `user_id` at the time the core is built.
    ///   - windowNanos: how long a read stays deduplicated. Production uses one hour.
    ///   - now: a monotonic clock in nanoseconds. Injectable so tests can cross a window
    ///     without sleeping.
    ///   - sink: receives each event to report. Called outside the lock.
    init(
        userId: String?,
        windowNanos: UInt64 = ReadRecorder.defaultWindowNanos,
        now: @escaping @Sendable () -> UInt64 = { ReadRecorder.monotonicNanos() },
        sink: @escaping @Sendable (SdkEvent) -> Void
    ) {
        self.userId = userId
        self.windowNanos = windowNanos
        self.now = now
        self.sink = sink
    }

    /// Changes the user that later reads are reported for. The core calls this when
    /// its context changes, which is the only time the resolved `user_id` can change.
    func setUserId(_ userId: String?) {
        lock.withLock {
            guard userId != self.userId else { return }
            otherUsersReads[self.userId ?? ""] = currentUserReads
            currentUserReads = otherUsersReads.removeValue(forKey: userId ?? "") ?? [:]
            self.userId = userId
        }
    }

    /// Starts a fresh window: the next read of every flag is reported again.
    ///
    /// The core calls this when the app returns to the foreground. `CLOCK_MONOTONIC`
    /// already counts through sleep on Darwin, so this is a second line of defence for a
    /// platform whose clock pauses, and it keeps the four client SDKs alike. Off the hot
    /// path: one call per foreground transition.
    func resetWindow() {
        lock.withLock {
            currentUserReads.removeAll()
            otherUsersReads.removeAll()
            windowStart = nil
        }
    }

    /// Records one read. `variation` is nil when the flag is absent from the snapshot,
    /// which is still a read: an old build reading an archived flag must stay visible.
    func record(flagKey: String, variation: String?) {
        let at = now()
        let variationKey = variation ?? ""

        let (isFirstInWindow, reportedUserId): (Bool, String?) = lock.withLock {
            // A `now` earlier than the window start is a reader that sampled the clock
            // before a racing reader (holding a later sample) took the lock first and started
            // the window. The production clocks never go backwards, so it counts as inside
            // that window and must not restart it.
            if let start = windowStart, at < start || at - start < windowNanos {
                // Inside the current window. The repeat path is this one lookup.
                if let seen = currentUserReads[flagKey], seen.contains(variationKey) {
                    return (false, nil)
                }
            } else {
                currentUserReads.removeAll()
                otherUsersReads.removeAll()
                windowStart = at
            }
            currentUserReads[flagKey, default: []].append(variationKey)
            return (true, userId)
        }
        guard isFirstInWindow else { return }

        sink(SdkEvent(
            type: "Evaluation",
            flagKey: flagKey,
            userId: reportedUserId,
            variation: variation,
            timestamp: SharedFeatureflipCore.isoFormatter.string(from: Date()),
            metadata: nil
        ))
    }
}
