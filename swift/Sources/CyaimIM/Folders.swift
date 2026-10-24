import Foundation

// `conv.folders` / `conv.upsertFolder` / `conv.deleteFolder` — the user's own tabs over the
// conversation list, "Work", "Family", "Unread" (T4). The three calls live on ``ImConvNamespace``;
// what they send and get back is here.
//
// **A folder is a saved filter, not a container.** It names tags (set per conversation with
// `conv.setting`'s `tags`), optionally conversation types and "unread only"; the server stores the
// definition and the client applies it to the list it already has. Nothing is moved, and nothing is
// pushed when a folder changes — another device of the user's learns about it only by calling
// `conv.folders` again.
//
// 文件夹是保存下来的过滤条件，不是容器：它点名若干标签（每个会话的标签用 conv.setting 的 tags 设置）、
// 可选的会话类型与「只看未读」；服务端只存定义，由客户端套在已有的会话列表上。改动不推送任何事件，其他设备要重新调用 conv.folders。

// MARK: - Requests

/// `conv.upsertFolder`: creates a folder (no ``folderId``) or replaces one wholesale (its id).
///
/// **Every ``tags`` entry must already be on one of the caller's conversations**, or the call is
/// `1001` — tag a conversation with `conv.setting` first. Other `1001`s: a blank ``name`` or one longer
/// than 64 characters, a ``folderId`` that is not 1–64 letters, digits, `-`, `_` or `.`, more than 16
/// tags (each at most 64 characters). `1006` once the user has 20 folders
/// (`IM:Extras:MaxFoldersPerUser`).
///
/// **Creating is not idempotent**: a retried create whose reply was lost makes a second folder. Take
/// the id from the answer and send it on every later save.
///
/// 每个标签都必须已经挂在调用者的某个会话上，否则 1001——先用 conv.setting 打标签。不带 folderId 是新建，
/// 新建不幂等：丢了答复就重试会多出一个文件夹，之后的每次保存都带上答复里的 id。
public struct UpsertFolderRequest: Encodable, Sendable, Hashable {
    /// Required in practice: blank is `1001`; at most 64 characters.
    public var name: String

    /// `nil` (or empty) creates; an existing id replaces that folder.
    public var folderId: String?

    /// Display order; clients sort by it, then by name. Negative values are stored as 0.
    public var order: Int

    /// Tags this folder gathers; at most 16, each already on one of the caller's conversations.
    public var tags: [String]

    /// Show only conversations with something unread.
    public var unreadOnly: Bool

    /// Conversation types the folder shows, as integers on the wire. `nil` or empty means all of them,
    /// and an empty list is stored as none: it comes back absent.
    public var types: [ConversationType]?

    public init(
        name: String,
        folderId: String? = nil,
        order: Int = 0,
        tags: [String] = [],
        unreadOnly: Bool = false,
        types: [ConversationType]? = nil
    ) {
        self.name = name
        self.folderId = folderId
        self.order = order
        self.tags = tags
        self.unreadOnly = unreadOnly
        self.types = types
    }
}

/// `conv.deleteFolder`. `1002` "no such folder" for an id the caller does not have — including a
/// second delete of the same one. The conversations and their tags are untouched.
public struct FolderIdRequest: Encodable, Sendable, Hashable {
    public var folderId: String

    public init(folderId: String) {
        self.folderId = folderId
    }

    public init(_ folderId: String) {
        self.folderId = folderId
    }
}

// MARK: - Responses

/// One folder, as `conv.folders` lists it and `conv.upsertFolder` answers it.
public struct ConversationFolder: Codable, Sendable, Hashable, Identifiable {
    /// `Identifiable` uses it.
    public let folderId: String

    public let name: String

    /// Sort by this, then by ``name``.
    public let order: Int

    public let tags: [String]

    public let unreadOnly: Bool

    /// `nil` means every conversation type. Integers on the wire; one this build does not name still
    /// decodes, as itself.
    public let types: [ConversationType]?

    public var id: String { folderId }

    enum CodingKeys: String, CodingKey {
        case folderId, name, order, tags, unreadOnly, types
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderId = c.imString(.folderId) ?? ""
        name = c.imString(.name) ?? ""
        order = c.imInt(.order) ?? 0
        tags = c.imStrings(.tags) ?? []
        unreadOnly = c.imBool(.unreadOnly) ?? false

        // Read as integers, a quoted one included, rather than through ConversationType's own strict
        // decoder: one unreadable element must not cost the folder its whole filter.
        types = c.imInt64s(.types).map { codes in
            codes.compactMap { Int(exactly: $0) }.map { ConversationType(rawValue: $0) }
        }
    }
}
