#if canImport(SwiftUI)
import SwiftUI

/// A property wrapper that reads a boolean feature flag reactively in SwiftUI views.
///
/// Usage:
/// ```swift
/// struct MyView: View {
///     @FeatureFlag("dark-mode") var darkMode = false
///
///     var body: some View {
///         Text(darkMode ? "Dark" : "Light")
///     }
/// }
/// ```
///
/// Requires a `FeatureFlagProvider` to be injected via `.environmentObject(client.flagProvider)`.
@propertyWrapper
public struct FeatureFlag: DynamicProperty {
    private let key: String
    private let defaultValue: Bool

    @EnvironmentObject private var provider: FeatureFlagProvider

    public init(wrappedValue defaultValue: Bool, _ key: String) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: Bool {
        provider.boolVariation(key, default: defaultValue)
    }
}
#endif
