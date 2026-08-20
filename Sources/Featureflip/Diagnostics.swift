import os

/// The SDK's diagnostic sink.
///
/// Swift had no logging facility at all, which is why a failed initial flag fetch
/// could be swallowed with only a comment to show for it — an SDK author standing at
/// an error boundary had a choice between rethrowing (which takes the host app down
/// at startup over a transient blip) and silence. See #2322.
///
/// `os.Logger` rather than `print` on purpose: it is the platform-idiomatic sink and
/// is captured by Console.app and `log collect` without the host wiring anything up.
/// Available unconditionally at this package's deployment targets (iOS 15 / macOS 13
/// / tvOS 15 / watchOS 8), so no availability gate is needed.
///
/// Note the message is built eagerly by the caller, so this is not free — fine at the
/// once-per-init call sites it has today, worth revisiting if it ever moves onto a hot
/// path.
///
/// A host-supplied handler on `FeatureflipConfig` is the eventual goal (#2322); this
/// is the floor, not the ceiling.
enum Diagnostics {
    private static let logger = Logger(
        subsystem: "io.featureflip.sdk",
        category: "Featureflip"
    )

    /// Logs a non-fatal problem the caller would want to know about.
    ///
    /// `.public` is deliberate: these messages describe SDK-internal failures
    /// (unreachable host, rejected key, decode failure), never end-user data, and a
    /// redacted `<private>` diagnostic would defeat the entire purpose.
    static func log(_ message: String) {
        logger.warning("[featureflip] \(message, privacy: .public)")
    }
}
