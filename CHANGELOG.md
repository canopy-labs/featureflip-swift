# Changelog

## 2.4.0 — 2026-07-29

### Added

- **`onEvaluation` inspector callback.** `inspectors` config option registering in-process observers fired on every evaluation. Notified from the four variation accessors after type coercion — `flagDetail()` and all-flags accessors stay silent so one decision is never double-counted. `reason` is the engine's kebab-case string forwarded verbatim; a flag absent from the snapshot synthesizes `flag-not-found`. Also threaded through the public `forTesting` stub factory (#1914).

## 2.3.0 — 2026-07-13

### Fixed

- Outage-recovery hardening: reconnect-forever fallback and replace-on-reconnect (#1884).
- The connect-snapshot store replacement is keyed off the explicit `full: true` marker rather than event order, which was ambiguous when a delta arrived first (#1888).
- The SSE stream is stopped when falling back to polling, instead of being left open alongside it (#1902).

## 2.2.0 — 2026-06-19

### Added

- A generated anonymous `user_id` is persisted in `UserDefaults` and injected at every evaluate/identify/SSE call, so anonymous users bucket consistently across sessions (#1467).

## 2.1.0 — 2026-05-27

### Added

- **`FlagValue.prerequisiteKey`.** Optional `String?` on the public `FlagValue` carrying the key of the prerequisite flag that caused this flag to serve its off variation. Populated by the server on the `/v1/client/evaluate` and `/v1/client/identify` responses when `reason == "prerequisite-failed"`. Nil for all other reasons. Adding the field is backward-compatible with cache files written by 2.0.0 — old cached snapshots decode with `prerequisiteKey == nil` (#1113).
- `flagValue(_:)` accessor, later consolidated as `flagDetail(key)` across the client SDKs (#1131, #1165).

## 2.0.0 — 2026-04-09

### BREAKING

- **`configure(config:)` and `.shared` removed.** Use `FeatureflipClient(config:)` directly and hold your own reference.

  Before:
  ```swift
  FeatureflipClient.configure(config: config)
  let client = FeatureflipClient.shared
  await client.initialize()
  ```

  After:
  ```swift
  let client = FeatureflipClient(config: config)
  await client.initialize()
  ```

- **Singleton-by-construction.** Two `FeatureflipClient(config:)` calls with the same `clientKey` return distinct handle objects sharing one underlying refcounted core. `close()` is refcounted — only the last handle triggers real shutdown.

### Added

- Internal `SharedFeatureflipCore` separating expensive resources from the public handle.
- `initialize()` is now idempotent on the shared core — first call does real work, subsequent calls return immediately.

### Changed

- `FeatureflipClient` is now a thin handle (~120 lines, down from ~417).
- `forTesting(_:)` still bypasses the cache entirely.

## 1.0.1

Previous release.
