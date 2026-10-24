import Foundation

// `msg.translate` — machine translation of messages already in a conversation (T4). The call lives on
// ``ImMsgNamespace``; what it sends and gets back is here.
//
// **The platform calls no model of its own.** A deployment translates only when the operator has
// configured a provider (`IM:Translation:Provider`) and the tenant's plan includes the translation
// add-on, and the two refusals are ordinary ``ImError``s, checked in this order before anything else
// about the request:
//
//   * `1204 PlanExpired` — the plan does not include translation (Enterprise and above, or a trial);
//   * `1203 FeatureNotEnabled` — the plan includes it but this app or deployment has no provider.
//
// Neither is something to retry (``ImError/isRetryable`` is false for both), and neither should be
// latched for the life of the process: both are runtime settings. Show the server's message and hide
// the action until the next start.
//
// 平台自己不调用任何模型：部署配置了翻译服务商、且租户套餐包含翻译增值项时才能翻译。两种拒绝都是普通的 ImError，
// 在检查请求本身之前按此顺序判定：套餐不含翻译回 1204；含翻译但没有服务商回 1203。都不该重试，也不要在进程生命期内锁死。

/// `msg.translate`: up to 50 messages of one conversation into ``targetLanguage``.
///
/// Each of ``messageIds`` is quoted on the wire (the server's field is a `List<string>`); an empty list
/// or more than 50 is `1001`. **A message that cannot be translated does not fail the call**: it comes
/// back with ``TranslatedMessage/error`` set, and the rest are translated.
///
/// 每次至多 50 条，空列表回 1001。单条翻译失败不会让整次调用失败，而是在那一条的 error 里说明。
public struct TranslateRequest: Encodable, Sendable, Hashable {
    public var conversationId: String

    /// ``ImMessage/messageId`` values; each leaves as a quoted string. See ``encode(to:)``.
    public var messageIds: [Int64]

    /// BCP-47, e.g. `"zh-CN"`, `"en"`, `"ja"`.
    public var targetLanguage: String

    /// A hint; `nil` lets the provider detect the source language.
    public var sourceLanguage: String?

    public init(conversationId: String, messageIds: [Int64], targetLanguage: String, sourceLanguage: String? = nil) {
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
    }

    enum CodingKeys: String, CodingKey {
        case conversationId, messageIds, targetLanguage, sourceLanguage
    }

    /// Written by hand for one field: every element of `messageIds` leaves quoted, as
    /// ``DeleteMessagesRequest`` writes its own — one JSON number in the array fails the whole call
    /// with `1000`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(messageIds.map { String($0) }, forKey: .messageIds)
        try container.encode(targetLanguage, forKey: .targetLanguage)
        try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
    }
}

/// What `msg.translate` answers: one item per message asked for.
public struct TranslationResult: Codable, Sendable, Hashable {
    public let targetLanguage: String
    public let items: [TranslatedMessage]

    enum CodingKeys: String, CodingKey {
        case targetLanguage, items
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetLanguage = c.imString(.targetLanguage) ?? ""
        items = c.imList(TranslatedMessage.self, .items) ?? []
    }
}

/// One message's translation, or why there is none.
public struct TranslatedMessage: Codable, Sendable, Hashable, Identifiable {
    /// Arrives as a JSON string and decodes with every digit. `Identifiable` uses it.
    public let messageId: Int64

    /// The translation; `nil` when ``error`` is set.
    public let text: String?

    /// True when it came from the server's cache rather than a provider call.
    public let cached: Bool

    /// Why this one message was not translated; the rest of the call still succeeded.
    public let error: String?

    public var id: Int64 { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId, text, cached, error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = c.imInt64(.messageId) ?? 0
        text = c.imString(.text)
        cached = c.imBool(.cached) ?? false
        error = c.imString(.error)
    }
}
