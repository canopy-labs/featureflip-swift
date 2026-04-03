import Foundation
#if canImport(Combine)
import Combine
#endif

/// Observable provider for SwiftUI views that need reactive flag updates.
public final class FeatureFlagProvider: ObservableObject {
    @Published public private(set) var revision: UInt = 0
    private let client: FeatureflipClient

    public init(client: FeatureflipClient) {
        self.client = client
    }

    public func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        client.boolVariation(key, default: defaultValue)
    }

    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        client.stringVariation(key, default: defaultValue)
    }

    public func numberVariation(_ key: String, default defaultValue: Double) -> Double {
        client.numberVariation(key, default: defaultValue)
    }

    @MainActor
    func updateFlags() {
        revision += 1
    }
}
