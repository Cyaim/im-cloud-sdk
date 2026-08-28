package com.cyaim.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.put

/*
 * Payload models: the `data` half of an `ApiResult`, one Kotlin type per entry in
 * sdk/endpoint-inventory.json's `payloadTypes` that tiers T0–T2 reach.
 *
 * Two rules run through all of it, both from CONTRACT.md §4.5 and both learned the hard way:
 *
 * 1. Every field the server may omit is nullable or has an empty default. Only the ones the server
 *    marks required are non-optional. A decoder that insists on a field the server stopped sending
 *    is an app that stops receiving messages after a gateway deploy.
 * 2. Every `seq`, `messageId` and unix-ms timestamp is a `Long`. A 32-bit `Int` for a seq is a bug
 *    with a two-year fuse — it works right up to the tenant whose busiest conversation passes two
 *    billion messages.
 */

// ------------------------------------------------------------------------------- paging

/**
 * Cursor-paged result — the shape every list endpoint returns (SPEC-02 §5).
 *
 * Not flattened to a bare `List`, deliberately. [nextCursor] is the only correct way to page, and
 * an SDK that hides it forces the application into the wrong loop: stopping when a page comes back
 * shorter than the limit. That is wrong here — the server computes its cursor on the raw page
 * *before* filtering rows the caller may not see, so a short page with `hasMore = true` is normal.
 * **Page on [hasMore] / [nextCursor], never on `items.size`.**
 *
 * 不要把它压扁成 List：服务端的游标是在过滤不可见行之前算的，"这一页比 limit 短"完全正常，
 * 据此停止分页会漏数据。只能看 hasMore / nextCursor。
 */
@Serializable
public data class Page<T>(
    public val items: List<T> = emptyList(),
    /** Opaque; pass it back verbatim. Null when the server has nothing more to give. */
    public val nextCursor: String? = null,
    public val hasMore: Boolean = false,
    /** Only when the store can count cheaply. Null is common and is not an error. */
    public val total: Long? = null,
)

// ----------------------------------------------------------------------------- messages

@Serializable
public data class RecallInfo(
    public val operatorId: String = "",
    public val recallTime: Long = 0,
    public val byAdmin: Boolean = false,
    public val reason: String? = null,
)

@Serializable
public data class EditInfo(
    public val operatorId: String = "",
    public val editTime: Long = 0,
    public val version: Int = 0,
)

/** Per-message delivery switches. Everything here is decided by the sender, not the reader. */
@Serializable
public data class MessageOptions(
    /** False for online-only traffic: no row, no seq, no history. */
    public val persistent: Boolean = true,
    public val updateConversation: Boolean = true,
    public val countUnread: Boolean = true,
    public val offlinePush: Boolean = true,
    public val pushConfig: PushConfig? = null,
    public val needReceipt: Boolean = false,
    public val priority: MessagePriority = MessagePriority.Normal,
    /** Delivered only to peers who are connected right now; nobody else ever learns of it. */
    public val onlineOnly: Boolean = false,
    /** Suppresses the echo to the sender's own other devices. */
    public val noSelfSync: Boolean = false,
    /** Time to live in milliseconds; the server deletes it afterwards. */
    public val expireIn: Long? = null,
    public val moderationBypass: Boolean = false,
)

/** Overrides for the offline notification this message produces. */
@Serializable
public data class PushConfig(
    public val title: String? = null,
    public val body: String? = null,
    public val sound: String? = null,
    public val payload: Map<String, String>? = null,
    public val badgeCount: Boolean = true,
    /** Android notification channel id; ignored by APNs. */
    public val channelId: String? = null,
)

@Serializable
public data class ImMessage(
    public val conversationId: String,
    /** Gap-free position inside the conversation. Ordering and gap repair both key off this. */
    public val seq: Long = 0,
    public val appId: String = "",
    public val conversationType: ConversationType = ConversationType.Unknown,
    public val messageId: Long = 0,
    public val clientMsgId: String = "",
    public val senderId: String = "",
    public val senderPlatform: Platform = Platform.Unknown,
    public val contentType: MessageContentType = MessageContentType.Unknown,
    /**
     * Left as raw JSON: its shape depends entirely on [contentType], and for `Custom` messages it
     * is whatever the tenant decided. Decode it with [contentAs].
     */
    public val content: JsonObject = JsonObject(emptyMap()),
    public val mentionAll: Boolean = false,
    public val mentionedUserIds: List<String> = emptyList(),
    public val quoteMessageId: Long? = null,
    /** Root of a thread, when the tenant uses threading. */
    public val threadRootId: Long? = null,
    public val options: MessageOptions? = null,
    public val status: MessageStatus = MessageStatus.Sent,
    public val reactions: Map<String, List<String>> = emptyMap(),
    public val recalled: RecallInfo? = null,
    public val edited: EditInfo? = null,
    /** Users who deleted this message for themselves only. Usually absent for a normal reader. */
    public val deletedForUsers: List<String> = emptyList(),
    public val sendTime: Long = 0,
    /** Authoritative server clock, unix ms. The only timestamp here worth trusting. */
    public val createTime: Long = 0,
    /** Unix ms after which the server removes it, for a message sent with `expireIn`. */
    public val expireAt: Long? = null,
    public val extensions: JsonObject? = null,
)

/** The body of a text message, or null for every other content type. */
public val ImMessage.text: String?
    get() = (content["text"] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** Decodes [ImMessage.content] into your own `@Serializable` payload class. */
public inline fun <reified T> ImMessage.contentAs(): T = ImJson.decodeFromJsonElement<T>(content)

@Serializable
public data class SendMessageResult(
    public val messageId: Long = 0,
    public val seq: Long = 0,
    public val conversationId: String = "",
    public val clientMsgId: String = "",
    public val createTime: Long = 0,
    /** True when the server matched an earlier send and returned the original result. */
    public val deduplicated: Boolean = false,
    /** True when moderation rewrote the content before storing it. */
    public val contentModified: Boolean = false,
)

/**
 * Reply to `msg.sync`.
 *
 * [hasMore] is computed on the **raw** seq window, before messages hidden from this reader are
 * filtered out, so [messages] can be shorter than the requested limit — even empty — while
 * [hasMore] is true. Loop on [hasMore], never on `messages.size`; see CONTRACT.md §5.9.
 */
@Serializable
public data class SyncMessagesResult(
    public val conversationId: String = "",
    public val messages: List<ImMessage> = emptyList(),
    /** Newest seq that exists in this conversation right now. */
    public val maxSeq: Long = 0,
    /** Oldest seq this reader may see — history clears and join-time floors both raise it. */
    public val minSeq: Long = 0,
    public val hasMore: Boolean = false,
)

/** The one-line summary a conversation row shows. */
@Serializable
public data class MessageBrief(
    public val messageId: Long = 0,
    public val seq: Long = 0,
    public val senderId: String = "",
    public val contentType: MessageContentType = MessageContentType.Unknown,
    /** Server-rendered preview text; already localised and already truncated. */
    public val digest: String = "",
    public val createTime: Long = 0,
    public val recalled: Boolean = false,
)

/** The name this type carried before it was aligned with the server DTO. */
@Deprecated("Renamed to MessageBrief to match the server payload type", ReplaceWith("MessageBrief"))
public typealias ConversationDigest = MessageBrief

// ------------------------------------------------------------------------- conversations

@Serializable
public data class ConversationView(
    public val conversationId: String,
    public val type: ConversationType = ConversationType.Unknown,
    public val lastMessage: MessageBrief? = null,
    public val maxSeq: Long = 0,
    public val readSeq: Long = 0,
    /** Derived server-side from `maxSeq - readSeq`, which is why it cannot drift between devices. */
    public val unreadCount: Long = 0,
    public val pinned: Boolean = false,
    public val muted: MuteMode = MuteMode.Normal,
    public val draft: String? = null,
    public val tags: List<String> = emptyList(),
    /** The user marked it unread by hand; the badge shows even though [unreadCount] is 0. */
    public val manuallyUnread: Boolean = false,
    public val updatedAt: Long = 0,
    /** Present on a `Single` conversation, so a list can render without a profile round trip. */
    public val peer: UserProfile? = null,
    /** Present on a `Group` conversation, for the same reason. */
    public val group: Group? = null,
    public val extensions: JsonObject? = null,
)

/** The per-user settings on one conversation. Every field is a patch: null leaves it alone. */
@Serializable
public data class ConversationSetting(
    public val pinned: Boolean? = null,
    public val muted: MuteMode? = null,
    public val draft: String? = null,
    public val tags: List<String>? = null,
    public val extensions: JsonObject? = null,
)

// ------------------------------------------------------------------------------ session

/** Reply to `conn.heartbeat`. */
@Serializable
public data class HeartbeatResult(
    public val serverTime: Long = 0,
    /** How often to beat, in seconds. The server owns this cadence and the SDK adopts it. */
    public val intervalSeconds: Int = 0,
    /** True when this beat rebuilt a routing entry that had gone missing server-side. */
    public val healed: Boolean = false,
    /** This socket's cluster-unique id. Worth quoting in a support ticket. */
    public val connectionId: String = "",
    /** The gateway node holding this socket. */
    public val nodeId: String = "",
)

/**
 * Reply to `conn.sync`.
 *
 * `gapsFrom[convId]` is the *first seq we are missing*; the upper bound comes from that
 * conversation's `maxSeq` in the same reply. The server sends only the lower bound because the
 * upper one is already on the wire, and repeating it invites the two to disagree.
 *
 * Only conversations the client already knew about — it reported a non-zero seq for them in
 * `convSeqs` — get an entry. A conversation the client did not report produces **no gap at all**,
 * which is exactly why `convSeqs` has to be built from durable cursors and not from whatever
 * happens to be in memory. See CONTRACT.md §5.1.
 */
@Serializable
public data class ResumeResult(
    public val conversations: List<ConversationView> = emptyList(),
    public val nextCursor: String? = null,
    /** Sorted by `updatedAt` **descending**, so page 1 holds the newest timestamps. */
    public val hasMore: Boolean = false,
    public val gapsFrom: Map<String, Long> = emptyMap(),
    public val serverTime: Long = 0,
)

// -------------------------------------------------------------------------------- users

@Serializable
public data class UserProfile(
    public val userId: String = "",
    public val appId: String = "",
    public val nickname: String? = null,
    public val avatar: String? = null,
    public val gender: Int = 0,
    public val birthday: String? = null,
    public val signature: String? = null,
    /** Hashed server-side; the plaintext never leaves the tenant's own backend. */
    public val phoneHash: String? = null,
    public val emailHash: String? = null,
    public val silencedUntil: Long? = null,
    public val banned: Boolean = false,
    public val multiLoginOverride: MultiLoginPolicy? = null,
    public val createdAt: Long = 0,
    public val updatedAt: Long = 0,
    public val extensions: JsonObject? = null,
)

@Serializable
public data class PresenceState(
    public val userId: String = "",
    public val online: Boolean = false,
    /** Every platform this user is currently connected from. Empty when offline. */
    public val platforms: List<Platform> = emptyList(),
    public val lastSeen: Long = 0,
    public val customStatus: String? = null,
)

// ------------------------------------------------------------------------ relationships

@Serializable
public data class Friend(
    public val userId: String = "",
    public val friendUserId: String = "",
    public val appId: String = "",
    public val remark: String? = null,
    public val tags: List<String> = emptyList(),
    public val source: String? = null,
    public val addTime: Long = 0,
    public val extensions: JsonObject? = null,
)

@Serializable
public data class FriendRequest(
    public val fromUserId: String = "",
    public val toUserId: String = "",
    public val appId: String = "",
    public val greeting: String? = null,
    public val source: String? = null,
    public val status: ApplicationStatus = ApplicationStatus.Pending,
    public val handleReason: String? = null,
    public val createdAt: Long = 0,
    public val handledAt: Long? = null,
)

@Serializable
public data class BlockEntry(
    public val userId: String = "",
    public val blockedUserId: String = "",
    public val appId: String = "",
    public val createdAt: Long = 0,
    public val reason: String? = null,
)

// ------------------------------------------------------------------------------- groups

@Serializable
public data class Group(
    public val groupId: String = "",
    public val appId: String = "",
    public val type: GroupType = GroupType.Normal,
    public val name: String = "",
    public val avatar: String? = null,
    public val introduction: String? = null,
    public val announcement: String? = null,
    public val announcementUpdatedAt: Long? = null,
    public val ownerId: String = "",
    public val memberCount: Int = 0,
    public val maxMemberCount: Int = 0,
    public val joinMode: GroupJoinMode = GroupJoinMode.FreeAccess,
    public val inviteMode: GroupInviteMode = GroupInviteMode.AllMembers,
    public val muteAll: Boolean = false,
    public val muteEndTime: Long? = null,
    public val dismissed: Boolean = false,
    public val createdAt: Long = 0,
    public val updatedAt: Long = 0,
    public val extensions: JsonObject? = null,
)

@Serializable
public data class GroupMember(
    public val groupId: String = "",
    public val userId: String = "",
    public val appId: String = "",
    public val role: GroupRole = GroupRole.Member,
    /** In-group display name. Falls back to the user's profile nickname when null. */
    public val nickname: String? = null,
    public val muteEndTime: Long? = null,
    public val joinTime: Long = 0,
    public val joinSource: String? = null,
    public val extensions: JsonObject? = null,
)

// -------------------------------------------------------------------------------- media

/**
 * A short-lived presigned upload.
 *
 * The bytes go straight from the device to object storage — never through the gateway — and the
 * message then carries [objectKey], never a URL. Every reader signs their own download link with
 * `media.downloadUrl`, which is what makes expiry and revocation possible at all: a URL baked into
 * a message is public forever the moment it leaks.
 */
@Serializable
public data class MediaUploadTicket(
    /** Put this in the message content. The server chose it; a client cannot write outside it. */
    public val objectKey: String = "",
    public val uploadUrl: String = "",
    /** Only useful for an immediate local preview; it expires like any other signed link. */
    public val downloadUrl: String = "",
    /** Present when the deployment signs POST form uploads instead of PUT. Send them verbatim. */
    public val formFields: Map<String, String>? = null,
    public val expiresAt: Long = 0,
)

// ------------------------------------------------------------------------------- sending

/**
 * Where a message is going. A sealed type rather than three nullable strings, because "set exactly
 * one of receiverId / groupId / conversationId" is a rule the compiler can enforce and a comment
 * cannot.
 */
public sealed interface SendTarget {
    /** A one-to-one chat with a user id; the server resolves or creates the conversation. */
    public data class User(public val userId: String) : SendTarget

    /** A group, by id. */
    public data class Group(public val groupId: String) : SendTarget

    /** An existing conversation id, whatever its type. */
    public data class Conversation(public val conversationId: String) : SendTarget
}

/**
 * One outbound message, in the ergonomic shape.
 *
 * [SendMessageRequest] is the wire shape and the one CONTRACT.md §4.3 names; this is the overload
 * that makes the "exactly one target" rule a compile error instead of a runtime one. Both go
 * through `msg.send` and share a code path.
 *
 * [clientMsgId] is the idempotency key: `(appId, conversationId, senderId, clientMsgId)` is unique
 * server-side, so a resend after a timeout returns the first result with `deduplicated = true`
 * instead of posting twice. Leave it null and the SDK generates one, so a caller who never thinks
 * about idempotency gets it anyway.
 */
public data class SendRequest(
    public val target: SendTarget,
    public val content: JsonObject,
    public val contentType: MessageContentType = MessageContentType.Text,
    public val clientMsgId: String? = null,
    public val mentionedUserIds: List<String> = emptyList(),
    public val mentionAll: Boolean = false,
    public val quoteMessageId: Long? = null,
    /** `offlinePush`, `pushConfig`, `countUnread`, … Null means the server's defaults. */
    public val options: MessageOptions? = null,
    public val extensions: JsonObject? = null,
)

/** Builds the content payload of a plain text message. */
public fun textContent(text: String): JsonObject = buildJsonObject { put("text", text) }

/** Turns the sealed target into the three nullable wire fields, exactly one of them set. */
internal fun SendRequest.toWire(clientMsgId: String, sendTime: Long): SendMessageRequest =
    SendMessageRequest(
        conversationId = (target as? SendTarget.Conversation)?.conversationId,
        receiverId = (target as? SendTarget.User)?.userId,
        groupId = (target as? SendTarget.Group)?.groupId,
        clientMsgId = clientMsgId,
        contentType = contentType,
        content = content,
        mentionAll = mentionAll,
        mentionedUserIds = mentionedUserIds,
        quoteMessageId = quoteMessageId,
        options = options,
        extensions = extensions,
        sendTime = sendTime,
    )
