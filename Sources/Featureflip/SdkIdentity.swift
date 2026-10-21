import Foundation

/// The `featureflip-swift/<version>` User-Agent every request carries, so the
/// Evaluation API can count SDK usage by name and version (#4142, contract in #4138).
enum SdkIdentity {
    /// SwiftPM carries no manifest version (the git tag is the version), so this is
    /// maintained by hand and held equal to CHANGELOG.md's newest heading by
    /// tools/check-sdk-versions (CI workflow sdk-version-consistency.yml). Bump both
    /// together, as with the Go and PHP SDKs.
    static let version = "3.4.0"

    /// The SDK token, then the wrapper's token when one is configured. A wrapper that is
    /// not a valid product token is dropped with a diagnostic rather than thrown, because
    /// identity metadata must never stop the client starting.
    static func userAgent(wrapperName: String? = nil, wrapperVersion: String? = nil) -> String {
        let sdk = "featureflip-swift/\(version)"
        guard let name = wrapperName, !name.isEmpty else { return sdk }
        guard isToken(name), wrapperVersion.map(isToken) ?? true else {
            Diagnostics.log("ignoring wrapper '\(name)/\(wrapperVersion ?? "")': not a valid User-Agent product token")
            return sdk
        }
        return wrapperVersion.map { "\(sdk) \(name)/\($0)" } ?? "\(sdk) \(name)"
    }

    // RFC 9110 product token: one or more tchars.
    private static let tchars = Set("!#$%&'*+.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-")

    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { tchars.contains($0) }
    }
}
