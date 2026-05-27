# Changelog

## Unreleased

### Added

- **`FlagValue.prerequisiteKey`.** Optional `String?` on the public `FlagValue` carrying the key of the prerequisite flag that caused this flag to serve its off variation. Populated by the server on the `/v1/client/evaluate` and `/v1/client/identify` responses when `reason == "prerequisite-failed"`. Nil for all other reasons. Adding the field is backward-compatible with cache files written by 2.0.0 — old cached snapshots decode with `prerequisiteKey == nil`.

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
