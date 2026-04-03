# Featureflip Swift SDK

Swift SDK for [Featureflip](https://featureflip.io) - evaluate feature flags in iOS, macOS, tvOS, and watchOS apps.

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/canopy-labs/featureflip-swift", from: "1.0.0")
]
```

Or in Xcode: File > Add Package Dependencies, then enter the repository URL.

## Quick Start

```swift
import Featureflip

let config = FeatureflipConfig(clientKey: "your-client-sdk-key")
let client = FeatureflipClient(config: config)

await client.initialize()

let enabled = client.boolVariation("my-feature", default: false)

if enabled {
    print("Feature is enabled!")
}

await client.close()
```

## Configuration

```swift
let config = FeatureflipConfig(
    clientKey: "your-client-sdk-key",
    baseUrl: "https://eval.featureflip.io",      // Evaluation API URL (default)
    context: ["user_id": "123"],                   // Initial evaluation context
    streaming: true,                               // SSE for real-time updates (default)
    pollInterval: 30,                              // Polling interval in seconds
    flushInterval: 30,                             // Event flush interval in seconds
    flushBatchSize: 100,                           // Events per batch
    initTimeout: 10                                // Max seconds to wait for initialization
)
```

## Singleton Pattern

```swift
FeatureflipClient.configure(config: config)

// Access from anywhere
let enabled = FeatureflipClient.shared.boolVariation("my-feature", default: false)
```

## Evaluation

```swift
// Boolean flag
let enabled = client.boolVariation("feature-key", default: false)

// String flag
let tier = client.stringVariation("pricing-tier", default: "free")

// Number flag
let limit = client.numberVariation("rate-limit", default: 100.0)

// JSON flag
let config = client.jsonVariation("ui-config", default: .object(["theme": .string("light")]))
```

## Identify

Re-evaluate all flags with a new context (e.g., after login):

```swift
try await client.identify(context: ["user_id": "123", "plan": "pro"])
```

## Event Tracking

```swift
// Track custom events
await client.track("checkout-completed", metadata: ["total": .number(99.99)])

// Force flush pending events
await client.flush()
```

## SwiftUI Integration

```swift
import Featureflip

struct ContentView: View {
    @EnvironmentObject var flagProvider: FeatureFlagProvider

    var body: some View {
        if flagProvider.boolVariation("show-banner", default: false) {
            BannerView()
        }
    }
}
```

## Testing

Use `forTesting()` to create a client with predetermined flag values -- no network calls.

```swift
let client = FeatureflipClient.forTesting([
    "my-feature": true,
    "pricing-tier": "pro",
])

client.boolVariation("my-feature", default: false)     // true
client.stringVariation("pricing-tier", default: "free") // "pro"
client.boolVariation("unknown", default: false)         // false (default)
```

## Features

- **Client-side evaluation** - Flags evaluated server-side, only values returned
- **Real-time updates** - SSE streaming with automatic polling fallback
- **Event tracking** - Automatic batching and background flushing
- **Test support** - `forTesting()` factory for deterministic unit tests
- **SwiftUI support** - `FeatureFlagProvider` for reactive flag values
- **Singleton or instance** - `configure`/`shared` pattern or manual instantiation

## Platforms

- iOS 15+
- macOS 13+
- tvOS 15+
- watchOS 8+

## Requirements

- Swift 5.9+

## License

MIT
