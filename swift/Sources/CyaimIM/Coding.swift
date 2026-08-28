import Foundation

// Decoding rules the gateway's JSON policy forces on every client. See sdk/CONTRACT.md §2, which
// is itself a transcription of `GatewayRegistration.CreateJsonOptions()`.
//
// Two of those rules have teeth:
//
//   * **Numbers may arrive as JSON strings.** The server is configured with
//     `NumberHandling.AllowReadingFromString`, so a 64-bit `seq` is allowed to come back as
//     `"1234"`. A decoder that only accepts a JSON number throws on it, and because frames are
//     decoded whole, throwing means the message is never delivered at all.
//   * **Nulls are omitted when writing.** A missing field means null/default, so decoding must
//     never fail because a field is absent.
//
// 服务端允许数字以字符串形式出现（AllowReadingFromString），只认 JSON number 的解码器会抛错；
// 而帧是整体解码的，抛错等于这条消息永远不会送达。

extension KeyedDecodingContainer {
    /// A 64-bit integer that may have been written as a number, a string, or not at all.
    func imInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        return nil
    }

    /// An `Int` under the same rules. Separate from ``imInt64(_:)`` only because Swift will not
    /// narrow for you and a silent truncation here would be a bug with a long fuse.
    func imInt(_ key: Key) -> Int? {
        guard let wide = imInt64(key) else { return nil }
        guard let narrow = Int(exactly: wide) else { return nil }
        return narrow
    }

    func imBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Bool(text) }
        if let value = imInt64(key) { return value != 0 }
        return nil
    }

    func imString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    func imStrings(_ key: Key) -> [String]? {
        (try? decodeIfPresent([String].self, forKey: key)) ?? nil
    }

    /// `Dictionary<string, long>` — `convSeqs`, `gapsFrom`. Values obey the string rule too, and
    /// this is the one map where a single unreadable value would cost a whole resume.
    func imInt64Map(_ key: Key) -> [String: Int64]? {
        if let direct = try? decodeIfPresent([String: Int64].self, forKey: key) { return direct }

        guard let loose = try? decodeIfPresent([String: JSONValue].self, forKey: key) else { return nil }

        return loose.reduce(into: [String: Int64]()) { result, pair in
            if let value = pair.value.asInt64 { result[pair.key] = value }
        }
    }

    func imInt64s(_ key: Key) -> [Int64]? {
        if let direct = try? decodeIfPresent([Int64].self, forKey: key) { return direct }
        guard let loose = try? decodeIfPresent([JSONValue].self, forKey: key) else { return nil }
        return loose.compactMap(\.asInt64)
    }

    func imStringMap(_ key: Key) -> [String: String]? {
        (try? decodeIfPresent([String: String].self, forKey: key)) ?? nil
    }

    /// `Dictionary<string, List<string>>` — `Message.reactions`.
    func imStringListMap(_ key: Key) -> [String: [String]]? {
        (try? decodeIfPresent([String: [String]].self, forKey: key)) ?? nil
    }

    func imJSONMap(_ key: Key) -> [String: JSONValue]? {
        (try? decodeIfPresent([String: JSONValue].self, forKey: key)) ?? nil
    }

    /// Any `Decodable` payload type, absent-or-unreadable folded into `nil`.
    func imValue<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func imList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        (try? decodeIfPresent([T].self, forKey: key)) ?? nil
    }
}

extension JSONValue {
    /// This value as a 64-bit integer, accepting the string form the server may send.
    ///
    /// Distinct from ``intValue``, which reports what the JSON actually *was*. This one reports
    /// what the server meant, and is used only where the contract says a number may be a string.
    var asInt64: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        case .string(let text): return Int64(text)
        default: return nil
        }
    }
}

// MARK: - Open enums

/// The shape every enumerated wire value in this SDK has.
///
/// Always a `RawRepresentable` struct, never a Swift `enum`. The server is a moving product and
/// will add a content type, a group role or an error code long before a given app is rebuilt; an
/// unknown raw value has to decode to *itself* rather than throw or collapse into an `.unknown`
/// member that loses which value it was. A shipped client that cannot parse a value added six
/// months after it went to the App Store is a worse outcome than one that ignores it.
///
/// 一律用 RawRepresentable 结构体而不是 Swift enum：服务端会先加值，客户端后重建。
/// 未知值必须解码成它自己，既不能抛错，也不能塌缩成 .unknown 而丢掉原值。
public protocol ImOpenEnum: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible
where RawValue == Int {
    init(rawValue: Int)
}

extension ImOpenEnum {
    public init(_ rawValue: Int) { self.init(rawValue: rawValue) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Int.self) {
            self.init(rawValue: value)
            return
        }

        // The string form again. `Message.contentType` arriving as `"1"` must not cost the message.
        if let text = try? container.decode(String.self), let value = Int(text) {
            self.init(rawValue: value)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "\(Self.self) is not an integer"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { String(rawValue) }
}
