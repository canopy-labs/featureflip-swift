# Changelog

## 3.2.0 — 2026-08-26

### Changed

- `flush()` now waits for a drain already in progress instead of returning straight away. The coalescing guard added for [#2456](https://github.com/canopy-labs/featureflip/issues/2456) already stopped a second drain from starting, but it answered the caller-facing half of the question differently from every other SDK: a caller that awaited `flush()` is asking for its events to be sent, and js and node have always resolved only once the send has settled. Shutdown still bypasses coalescing, because it is the last drain there will ever be. ([#2477](https://github.com/canopy-labs/featureflip/issues/2477))

### Fixed

- Stopping the polling data source before its first poll no longer leaks that poll. A Swift `Task` body runs even when the task was cancelled before it was ever scheduled, and `start()` only checked for cancellation *after* the first `pollOnce()` — so an `initialize()` immediately followed by `close()` left a cancelled poller that still issued exactly one evaluate request, at an arbitrary later moment, carrying the context it was constructed with. Kotlin's `scope.launch` never invokes a body cancelled before dispatch, so this restores parity with the Android SDK rather than changing the shared data-source contract; a poller that is not stopped still polls once immediately and then on interval. ([#2481](https://github.com/canopy-labs/featureflip/issues/2481))

- The first SSE reconnect after a healthy stream drops is now jittered to `[d/2, d]`, like every other backoff level. The drops this absorbs are fleet-wide — a single edge event severs every stream at once — so every client re-entered the backoff together and waited an identical delay, republishing the drop's own synchronisation as a reconnect spike one backoff later. Measured in production: a drop spread across 2.5–3.0 ms produced a reconnect spread of 26–46 ms. The delay never exceeds the previous one and stays strictly positive, so a stream that fails immediately still cannot busy-loop. ([#2508](https://github.com/canopy-labs/featureflip/issues/2508))

## 3.1.0 — 2026-08-24

### Fixed

- Analytics events now survive a transient failure of the events endpoint. The flush emptied the buffer and then called `try? await httpClient.postEvents`, so every 503, timeout and offline blip discarded that batch outright — the HTTP layer detected the failure correctly and `try?` threw the detection away. The public edge answers this endpoint with a 503 at a low but constant rate, so events were being lost steadily. A retryable failure (5xx, 429, transport fault) now returns the batch to the front of the buffer for the next flush; a permanent one (401/403, a malformed body, an encoding failure) is dropped, because retrying those forever would pin a poison batch at the head of the buffer. ([#2456](https://github.com/canopy-labs/featureflip/issues/2456))
- Flush failures are now reported through `Diagnostics` instead of being silently discarded. ([#2456](https://github.com/canopy-labs/featureflip/issues/2456))
- `stop()` makes a single final attempt and discards the remainder, rather than restoring a batch into a buffer nothing will ever drain again. ([#2456](https://github.com/canopy-labs/featureflip/issues/2456))

### Added

- The event buffer is now bounded, at 1000 events, shedding the oldest first. It previously had no bound, which only became reachable now that failed batches are kept. The bound is lower than the server SDKs' 10,000 because this is a mobile client. ([#2456](https://github.com/canopy-labs/featureflip/issues/2456))

### Changed

- A flush sends one request per batch instead of one for the whole buffer, and the batch-size trigger backs off while the endpoint is failing. A restored batch leaves the buffer at or above the batch size, so without the backoff every later event would start another flush — one request per recorded event. The periodic task remains the retry vehicle. ([#2456](https://github.com/canopy-labs/featureflip/issues/2456))

## 3.0.0 — 2026-08-20

### Fixed

- A closed handle serves the caller's default from every accessor and reports not-initialized. `close()` releases the shared core — stopping streaming and polling, shutting down the event processor — but the in-memory snapshot stayed readable, so a closed client kept evaluating against a frozen snapshot that could never update again while still reporting itself initialized. ([#2327](https://github.com/canopy-labs/featureflip/issues/2327))

- A failed initial flag fetch is now diagnosable rather than swallowed by a bare `catch`. ([#2322](https://github.com/canopy-labs/featureflip/issues/2322))
### Changed

- **BREAKING:** the evaluation context now accepts any JSON value, not just strings. It was typed `[String: String]`, so this SDK could not send a JSON number — and the engine's equality coercion only engages for numbers, so a rule like `age Equals ["25.0"]` matched on web and Flutter and silently no-opped here ([#2293](https://github.com/canopy-labs/featureflip/issues/2293)).

  `FeatureflipConfig(context:)` and `identify(context:)` now take `[String: Any]`; both are source-compatible at the call site (`[String: String]` upcasts implicitly). What breaks is **reading**: `FeatureflipConfig.context` and `EvaluationEvent.context` are now `[String: AnyCodableValue]`, so an inspector doing `event.context["user_id"]` as a `String?` must use `.displayString`. `[String: Any]` could not be used for storage — both types are `Sendable`, and `Any` is not.

  `AnyCodableValue` gains `init(any:)`, a public `displayString`, and `ExpressibleBy{String,Integer,Float,Boolean,Nil}Literal`, so `["age": 25, "plan": "pro"]` reads naturally.

## 2.4.1 — 2026-08-05

### Fixed

- `LICENSE` is now the verbatim Apache-2.0 text. Three phrases in the operative sections had been reworded and the appendix dropped, which left automated license scanners unable to identify it. The license itself is unchanged; the file now says what it always claimed to.
- The README's License section said MIT. The `LICENSE` file has always been Apache-2.0, which is the actual license.

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
