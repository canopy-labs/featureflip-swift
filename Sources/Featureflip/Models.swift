import Foundation

/// A pre-evaluated flag value returned by the server.
public struct FlagValue: Codable, Sendable, Equatable {
    public let value: AnyCodableValue
    public let variation: String
    public let reason: String
    /// Key of the prerequisite flag that caused this flag to serve its off variation.
    /// Populated only when `reason == "prerequisite-failed"`.
    public let prerequisiteKey: String?

    public init(
        value: AnyCodableValue,
        variation: String,
        reason: String,
        prerequisiteKey: String? = nil
    ) {
        self.value = value
        self.variation = variation
        self.reason = reason
        self.prerequisiteKey = prerequisiteKey
    }
}

/// Type-erased Codable value for flag payloads.
public enum AnyCodableValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null
}

extension AnyCodableValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

/// Server response from /v1/client/evaluate and /v1/client/identify.
struct EvaluateResponse: Decodable {
    let flags: [String: FlagValue]
    // The client SSE connect-time snapshot carries `full: true` (#1873); deltas omit it.
    // Absent on /v1/client/evaluate + polling responses (they are always full replaces).
    let full: Bool?
}

/// An analytics event sent to /v1/sdk/events.
struct SdkEvent: Encodable {
    let type: String
    let flagKey: String?
    let userId: String?
    let variation: String?
    let timestamp: String
    let metadata: [String: AnyCodableValue]?
}

/// Wrapper for event batch POST body.
struct RecordEventsRequest: Encodable {
    let events: [SdkEvent]
}

/// Emitted once per variation call. `reason` is the server's kebab-case string
/// forwarded verbatim — client SDKs have no local evaluator, so the engine is
/// their evaluator. The one synthesized value is `flag-not-found`, used when the
/// flag is absent from the snapshot.
public struct EvaluationEvent: Sendable {
    public let flagKey: String
    public let context: [String: String]
    public let value: AnyCodableValue
    /// The served arm. Nil when the flag is absent from the snapshot.
    public let variationKey: String?
    public let reason: String
    /// Parsed from a `rule-match:{id}` reason; nil for every other reason.
    public let ruleId: String?
    /// Set by the server only when `reason == "prerequisite-failed"`.
    public let prerequisiteKey: String?
    /// ISO-8601.
    public let timestamp: String

    public init(
        flagKey: String,
        context: [String: String],
        value: AnyCodableValue,
        variationKey: String? = nil,
        reason: String,
        ruleId: String? = nil,
        prerequisiteKey: String? = nil,
        timestamp: String
    ) {
        self.flagKey = flagKey
        self.context = context
        self.value = value
        self.variationKey = variationKey
        self.reason = reason
        self.ruleId = ruleId
        self.prerequisiteKey = prerequisiteKey
        self.timestamp = timestamp
    }
}

/// An in-process observer invoked on every variation call. Return value ignored.
/// `@Sendable` is required — `FeatureflipConfig` is `Sendable` and stores these.
public typealias EvaluationInspector = @Sendable (EvaluationEvent) -> Void
