import Foundation

private let anonymousStorageKey = "featureflip.anonymous_id"

/// Persistence seam for the generated anonymous user id. Injectable so tests can
/// supply an in-memory implementation instead of `UserDefaults`.
protocol AnonymousKeyStore: Sendable {
    func read() -> String?
    func write(_ value: String)
}

/// `UserDefaults`-backed store (default for production clients). Holds no state
/// — references the shared `UserDefaults.standard` directly — so it is trivially
/// `Sendable`.
struct UserDefaultsAnonymousKeyStore: AnonymousKeyStore {
    func read() -> String? {
        UserDefaults.standard.string(forKey: anonymousStorageKey)
    }

    func write(_ value: String) {
        UserDefaults.standard.set(value, forKey: anonymousStorageKey)
    }
}

private func isNonBlank(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespaces).isEmpty
}

/// Returns a context guaranteed to carry a non-blank `user_id`. A real caller id
/// (either the canonical `user_id` or its accepted `userId` alias, mirroring the
/// engine's ClientContextMapper) is returned unchanged so a real user always
/// wins. Otherwise a persisted anonymous id is read — or generated and persisted
/// once — and injected under `user_id`, giving anonymous users sticky
/// percentage-rollout bucketing.
func resolveAnonymousContext(_ context: [String: String], store: AnonymousKeyStore) -> [String: String] {
    if isNonBlank(context["user_id"]) || isNonBlank(context["userId"]) {
        return context
    }
    let key: String
    if let existing = store.read(), isNonBlank(existing) {
        key = existing
    } else {
        key = UUID().uuidString
        store.write(key)
    }
    var copy = context
    copy["user_id"] = key
    return copy
}
