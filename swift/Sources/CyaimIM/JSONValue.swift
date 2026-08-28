import Foundation

/// A decoded JSON value.
///
/// Message content is open by design — `{"text": "hi"}`, `{"url": ..., "width": ...}`, or whatever
/// a tenant invents for `contentType: 100`. Swift has no `Any` that survives strict concurrency, so
/// the SDK models that openness explicitly instead of leaking `[String: Any]` (not `Sendable`) or
/// forcing every app to declare a type for content it may only want to forward.
///
/// Literals work, so building content reads like a dictionary:
/// ```swift
/// let content: [String: JSONValue] = ["url": key, "width": 1080, "height": 1920]
/// ```
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup on an object, `nil` for every other case.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    /// Element lookup on an array, `nil` for every other case or an out-of-range index.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral pairs: (String, JSONValue)...) {
        self = .object(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Order matters: a JSON `true` decodes as a number on some platforms if Bool is tried
        // after Int, and an integral value must not silently become a Double — `seq` and
        // `messageId` are 64-bit ids where a Double round-trip loses precision above 2^53.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not valid JSON"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Bridging to concrete types

/// The single-key box `decoded(as:)` wraps a payload in. File scope rather than nested inside the
/// generic method: a generic type declared inside a generic function is rejected outright by the
/// Swift 6 frontend on the corelibs platforms.
private struct SingleValueWrapper<Value: Decodable>: Decodable {
    let value: Value
}

extension JSONValue {
    /// Re-decodes this value as `T`.
    ///
    /// Frames are decoded once into `JSONValue` so that one receive loop can route replies and
    /// pushes without knowing their payload types, and the payload is converted here when a caller
    /// finally names a type. The value is wrapped in a single-key object first because
    /// `JSONEncoder` and `JSONDecoder` disagree about top-level fragments across OS versions, and
    /// `conv.unreadTotal` returns a bare number.
    public func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONValue.encoder.encode(JSONValue.object(["value": self]))
        return try JSONValue.decoder.decode(SingleValueWrapper<T>.self, from: data).value
    }

    // One shared coder rather than a fresh one per call: neither instance is ever mutated after
    // creation, and encoding a payload is on the path of every single message. Both are `Sendable`,
    // so no unsafe opt-out is needed to say so.
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}
