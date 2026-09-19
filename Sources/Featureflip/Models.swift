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

extension AnyCodableValue {
    /// Bridges an untyped value from the public context API into the Codable,
    /// Sendable representation used for storage and on the wire.
    ///
    /// Context accepts `Any` for ergonomics (matching browser and flutter), but
    /// `[String: Any]` is neither `Codable` nor `Sendable`, and `FeatureflipConfig`
    /// and `EvaluationEvent` are both `Sendable` — so the conversion happens once,
    /// at the boundary, and everything downstream stays typed. See #2293.
    ///
    /// `Bool` is matched BEFORE the integer cases on purpose: an `NSNumber`-backed
    /// value satisfies both, and mapping `true` to `.int(1)` would send `1` where
    /// the engine expects a JSON boolean.
    public init(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let v as NSNumber:
            // Handled BEFORE the native cases, and case order alone is not enough:
            // `NSNumber(value: 1) as? Bool` returns TRUE on Darwin, so a `case let v
            // as Bool` placed first would turn the number 1 into `true` on the wire —
            // the #2293 failure mode again. Only CFBoolean identity separates a real
            // boolean from a numeric 1. Every native Bool/Int/Double also bridges to
            // NSNumber, so this one case covers them plus Int64/Int32/UInt/CGFloat/
            // Decimal, which satisfy none of the native casts and would stringify.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if let i = v as? Int {
                self = .int(i)
            } else {
                self = .double(v.doubleValue)
            }
        case let v as Bool:
            self = .bool(v)
        case let v as Int:
            self = .int(v)
        case let v as Double:
            self = .double(v)
        case let v as Float:
            self = .double(Double(v))
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            self = .array(v.map { AnyCodableValue(any: $0) })
        case let v as [String: Any]:
            self = .dictionary(v.mapValues { AnyCodableValue(any: $0) })
        case let v as AnyCodableValue:
            self = v
        default:
            // `x as Any` where x is Optional boxes the OPTIONAL, so a nil reaches
            // here as .some(Optional.none) and no case above sees it. Left to
            // String(describing:) it becomes the literal "nil" — and since the
            // public entry points take [String: Any], `identify(["email": user.email])`
            // with an optional email is the common case. Unwrap and recurse.
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                self = AnyCodableValue(any: mirror.children.first?.value)
            } else {
                self = .string(String(describing: value))
            }
        }
    }

    /// The value rendered as a string. Public because `EvaluationEvent.context` is
    /// public and is `[String: AnyCodableValue]` since #2293 — without this an
    /// inspector would have to hand-roll a switch to read its own event.
    /// Nil for `.null` and for the container cases.
    public var displayString: String? {
        switch self {
        case .null: return nil
        case .string(let v): return v
        case .bool(let v): return String(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .array, .dictionary: return nil
        }
    }
}

// Literal conformances so a context reads naturally at the call site —
// `["age": 25, "plan": "pro"]` types as [String: AnyCodableValue] directly, with no
// wrapping. Purely additive, and it keeps the stored/Sendable representation
// ergonomic now that context is no longer [String: String] (#2293).
extension AnyCodableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AnyCodableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension AnyCodableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension AnyCodableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AnyCodableValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
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

/// An analytics event sent to /v1/client/events.
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
    public let context: [String: AnyCodableValue]
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
        context: [String: AnyCodableValue],
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
