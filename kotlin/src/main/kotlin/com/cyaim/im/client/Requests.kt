package com.cyaim.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.LongAsStringSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement

/*
 * Request objects: one per endpoint, named for the server DTO in sdk/endpoint-inventory.json
 * (`requestType`), field names as the JSON names.
 *
 * Every typed method takes exactly one of these and nothing else (CONTRACT.md §4.3). That is not a
 * style preference: with positional parameters, the server adding one optional field is a
 * source-breaking change in five languages at once; with a request object it is additive
 * everywhere. Kotlin's default arguments then give back the ergonomics a positional signature
 * would have had — `HistoryRequest("c1")` is as short as `history("c1")` ever was.
 *
 * 每个端点一个请求对象，名字与服务端 DTO 一致。服务端加一个可选字段时，位置参数会同时
 * 打断五种语言的源码兼容性，请求对象则是纯增量。
 */

// ------------------------------------------------------------------------------ conn.*

/**
 * `conn.sync`. **Do not build this by hand for a normal resume** — [ImClient] issues it with the
 * durable cursors from its [ImCursorStore], and a hand-built one reporting in-memory seqs is the
 * data-loss bug CONTRACT.md §5.1 describes.
 */
@Serializable
public data class ResumeRequest(
    /** Per conversation, the highest seq the **application has durably stored** — not received. */
    public val convSeqs: Map<String, Long> = emptyMap(),
    /** Highest `ConversationView.updatedAt` fully consumed by a completed run. */
    public val conversationCursor: Long = 0,
    public val cursor: String? = null,
    /** Server clamps to 1…500; anything outside becomes 200. */
    public val limit: Int = 200,
)

/** `conn.reauth`. The token must belong to the identity already on this socket. */
@Serializable
public data class ReauthRequest(
    public val token: String,
)

// ------------------------------------------------------------------------------- msg.*

/**
 * `msg.send`, in the wire shape.
 *
 * Exactly one of [conversationId], [receiverId] and [groupId] is set. [SendRequest] is the
 * overload that makes the compiler enforce that; this one is here because it is the shape the
 * server documents and the one an integrator reading the inventory will look for.
 */
@Serializable
public data class SendMessageRequest(
    public val clientMsgId: String,
    public val contentType: MessageContentType,
    public val content: JsonObject,
    public val conversationId: String? = null,
    public val receiverId: String? = null,
    public val groupId: String? = null,
    public val conversationType: ConversationType? = null,
    public val mentionAll: Boolean = false,
    public val mentionedUserIds: List<String> = emptyList(),
    public val quoteMessageId: Long? = null,
    public val threadRootId: Long? = null,
    public val options: MessageOptions? = null,
    /** Client clock, unix ms. Advisory only: the server stamps `createTime` itself. */
    public val sendTime: Long = 0,
    public val extensions: JsonObject? = null,
)

/**
 * `msg.sync`. Gap repair, not paging: the server honours the window to the number.
 *
 * [limit] is clamped server-side to 500, so a range wider than that comes back with
 * `hasMore = true` and has to be requested again from where it stopped. [ImClient] does this for
 * you on the delivery path; a direct caller must loop on `hasMore` itself.
 */
@Serializable
public data class SyncMessagesRequest(
    public val conversationId: String,
    public val fromSeq: Long,
    public val toSeq: Long,
    public val limit: Int = 500,
    public val ascending: Boolean = true,
)

/** `msg.history`. [beforeSeq] is exclusive: pass the oldest seq you already hold. */
@Serializable
public data class HistoryRequest(
    public val conversationId: String,
    public val beforeSeq: Long? = null,
    /** Clamped server-side to 200. */
    public val limit: Int = 20,
)

/** `msg.recall`. Admin recall is a server-API capability and is refused on this path. */
@Serializable
public data class RecallMessageRequest(
    public val conversationId: String,
    public val messageId: Long,
    public val reason: String? = null,
)

/** `msg.edit`. [content] replaces the old content wholesale; it is not a patch. */
@Serializable
public data class EditMessageRequest(
    public val conversationId: String,
    public val messageId: Long,
    public val content: JsonObject,
)

/**
 * `msg.delete`.
 *
 * [forEveryone] is the difference between hiding a message from your own device and destroying
 * other people's copy of it, so it defaults to false and the server checks whether you may.
 */
@Serializable
public data class DeleteMessagesRequest(
    public val conversationId: String,
    public val messageIds: List<Long>,
    public val forEveryone: Boolean = false,
)

/** `msg.forward`. One call per fan-out; the reply is one result per target conversation. */
@Serializable
public data class ForwardMessagesRequest(
    public val sourceConversationId: String,
    public val messageIds: List<Long>,
    public val targetConversationIds: List<String>,
    /** True bundles them into one `Merged` message instead of forwarding each separately. */
    public val merge: Boolean = false,
    public val mergeTitle: String? = null,
    /** Idempotency key for the whole fan-out. [ImClient] fills it in when left blank. */
    public val clientMsgId: String = "",
)

/** `msg.react`. [add] false removes the reaction. */
@Serializable
public data class ReactRequest(
    public val conversationId: String,
    public val messageId: Long,
    public val emoji: String,
    public val add: Boolean = true,
)

/** `msg.receipt`. Per-message read acknowledgement, distinct from the conversation read cursor. */
@Serializable
public data class ReceiptRequest(
    public val conversationId: String,
    public val messageIds: List<Long>,
)

/** `msg.typing`. Never stored, never counted, and dropped first when a connection is behind. */
@Serializable
public data class TypingRequest(
    public val conversationId: String,
    public val typing: Boolean = true,
)

// ------------------------------------------------------------------------------ conv.*

/**
 * `conv.list`. Pass the largest `updatedAt` you already hold in [updatedAfter] and you download
 * the delta; pass 0 and you download everything. That is the difference between a one-second cold
 * start and a thirty-second one for a heavy user.
 */
@Serializable
public data class ListConversationsRequest(
    public val updatedAfter: Long = 0,
    public val cursor: String? = null,
    /** Clamped server-side to 200. */
    public val limit: Int = 50,
)

/** `conv.get`, `conv.delete`, `conv.clear`. */
@Serializable
public data class ConversationIdRequest(
    public val conversationId: String,
)

/** `conv.read`. Unread everywhere else is derived from this, on every device. */
@Serializable
public data class ReadRequest(
    public val conversationId: String,
    public val readSeq: Long,
)

/** `conv.setting`. Every field of [setting] is a patch: null leaves that one alone. */
@Serializable
public data class UpdateConversationSettingRequest(
    public val conversationId: String,
    public val setting: ConversationSetting? = null,
)

// ------------------------------------------------------------------------------ user.*

/** `user.profile`, `friend.delete`, `friend.unblock`. */
@Serializable
public data class UserIdRequest(
    public val userId: String,
)

/** `user.batchProfile`, `user.presence`, `user.unsubscribePresence`. At most 200 ids. */
@Serializable
public data class UserIdsRequest(
    public val userIds: List<String>,
)

/**
 * `user.updateProfile`. A sparse patch of your **own** profile — a client can never edit another
 * user, whatever it puts in here.
 *
 * The server drops `appId`, `userId`, `banned`, `silencedUntil`, `createdAt` and
 * `multiLoginOverride` from the patch before applying it, so a client cannot unban itself.
 */
@Serializable
public data class UpdateProfileRequest(
    public val patch: JsonObject,
)

/**
 * `user.subscribePresence`.
 *
 * Subscriptions carry a TTL rather than living until an explicit unsubscribe, because a client
 * that crashes never sends one. Re-subscribe while the screen is open; do not treat it as a
 * one-off. [ttlSeconds] is clamped server-side to 1…3600 and defaults to 600.
 *
 * One asymmetry worth knowing: `user.presence` checks the tenant's `EnablePresence` flag and this
 * call does **not**. A subscribe against a presence-disabled app succeeds and then never fires, so
 * do not infer the flag from a successful subscribe.
 */
@Serializable
public data class SubscribePresenceRequest(
    public val userIds: List<String>,
    public val ttlSeconds: Int = 600,
)

// ---------------------------------------------------------------------------- friend.*

/** `friend.list`, `friend.blockList`, `group.joined`. Clamped server-side to 200. */
@Serializable
public data class CursorRequest(
    public val cursor: String? = null,
    public val limit: Int = 50,
)

/** `friend.add`. Sends a request; it is not a friendship until the other side handles it. */
@Serializable
public data class AddFriendRequest(
    public val userId: String,
    public val greeting: String? = null,
    public val source: String? = null,
)

/** `friend.handleRequest`. [accept] false rejects it; [reason] is shown to the sender. */
@Serializable
public data class HandleFriendRequest(
    public val fromUserId: String,
    public val accept: Boolean,
    public val reason: String? = null,
)

/** `friend.requestList`. [incoming] true lists requests sent to me, false the ones I sent. */
@Serializable
public data class FriendRequestListRequest(
    public val incoming: Boolean = true,
    public val cursor: String? = null,
    public val limit: Int = 50,
)

/**
 * `friend.block`.
 *
 * Not optional in a shipped product: app-store review treats user blocking as mandatory for any
 * app carrying user-generated content.
 */
@Serializable
public data class BlockRequest(
    public val userId: String,
    public val reason: String? = null,
)

// ----------------------------------------------------------------------------- group.*

/**
 * `group.create`. The caller is always added as a member and always becomes the owner, whatever
 * [memberIds] says.
 */
@Serializable
public data class CreateGroupRequest(
    public val name: String,
    public val memberIds: List<String> = emptyList(),
    /** Leave null and the server allocates one. */
    public val groupId: String? = null,
    public val avatar: String? = null,
    public val introduction: String? = null,
    public val type: GroupType = GroupType.Normal,
    public val joinMode: GroupJoinMode = GroupJoinMode.FreeAccess,
    public val inviteMode: GroupInviteMode = GroupInviteMode.AllMembers,
    public val maxMemberCount: Int? = null,
    public val extensions: JsonObject? = null,
)

/** `group.info`, `group.dismiss`, `group.quit`. */
@Serializable
public data class GroupIdRequest(
    public val groupId: String,
)

/** The patch half of `group.update`. Null fields are left alone. */
@Serializable
public data class UpdateGroupRequest(
    public val name: String? = null,
    public val avatar: String? = null,
    public val introduction: String? = null,
    public val joinMode: GroupJoinMode? = null,
    public val inviteMode: GroupInviteMode? = null,
    public val maxMemberCount: Int? = null,
    public val extensions: JsonObject? = null,
)

/** `group.update`. The nesting is the server's shape, not a wrapper this SDK added. */
@Serializable
public data class UpdateGroupCommand(
    public val groupId: String,
    public val update: UpdateGroupRequest? = null,
)

/** `group.memberList`, `group.applicationList`. Always paged: a super group holds 100 000 members. */
@Serializable
public data class GroupCursorRequest(
    public val groupId: String,
    public val cursor: String? = null,
    /** Clamped server-side to 100. */
    public val limit: Int = 50,
)

/** `group.invite`, `group.kick`. */
@Serializable
public data class GroupMembersRequest(
    public val groupId: String,
    public val userIds: List<String>,
    public val reason: String? = null,
)

/**
 * `group.join`.
 *
 * Succeeding does not always mean joining: a group whose `joinMode` is `NeedApproval` answers
 * `1508 JoinNeedsApproval`, which is a refusal for now and an application on file.
 */
@Serializable
public data class JoinGroupRequest(
    public val groupId: String,
    public val reason: String? = null,
)

// ----------------------------------------------------------------------------- media.*

/**
 * `media.uploadTicket`.
 *
 * [size] in bytes, so the server can refuse an oversized upload before the device spends the
 * bandwidth rather than after.
 */
@Serializable
public data class UploadTicketRequest(
    public val fileName: String,
    public val contentType: String,
    public val size: Long,
)

/**
 * `media.downloadUrl`. [lifetimeSeconds] is clamped server-side to 1…86400 and defaults to 3600.
 *
 * Sign a link when the user is about to look at the file, not when the message arrives: a URL
 * signed at receive time is usually expired by the time anyone taps it.
 */
@Serializable
public data class DownloadUrlRequest(
    public val objectKey: String,
    public val lifetimeSeconds: Int = 3600,
)

// ------------------------------------------------------------------------------ push.*

/**
 * `push.register`.
 *
 * Identity comes from the socket: there is deliberately no `userId` or `deviceId` field here, so
 * "register a token against someone else's device" is not merely forbidden — it is unsayable.
 *
 * [provider] must be one of [PushProvider]'s values. Empty falls back to the platform default,
 * which is only reliable on iOS: **an Android client must always send it explicitly**, because
 * Android fragments across five OEM channels and the server cannot guess which one a token came
 * from. [language] is BCP-47 and defaults to the socket's `lang`.
 */
@Serializable
public data class RegisterPushTokenRequest(
    public val provider: String,
    public val token: String,
    public val language: String? = null,
)

/**
 * The vendor channels `push.register` routes through.
 *
 * Constants rather than an enum for the same reason [ImErrorCode] is: the server folds a set of
 * aliases (`ios`, `firebase`, `hms`, …) and may add a channel before this artifact is rebuilt. An
 * unknown value is rejected by the server with the legal list, which is a far better failure than
 * a token stored under a channel nothing can route.
 */
public object PushProvider {
    public const val Apns: String = "apns"
    public const val Fcm: String = "fcm"
    public const val Huawei: String = "huawei"
    public const val Xiaomi: String = "xiaomi"
    public const val Oppo: String = "oppo"
    public const val Vivo: String = "vivo"
    public const val Honor: String = "honor"
}

/**
 * `push.clicked`.
 *
 * Both fields are optional and neither carries identity. The delivery row is located from the
 * socket: a [pushId] is believed only when the row it names belongs to this user and this device,
 * and with neither field the server takes this device's newest delivery — which is the right answer
 * for a tap that opened the app without naming a message. So there is no way to mark somebody
 * else's notification clicked, and no way to probe which `pu_…` ids exist.
 *
 * 两个字段都可选，且都不承载身份：行由连接定位，pushId 只在指向本用户本设备时才采信。
 */
@Serializable
public data class PushClickedRequest(
    /** The delivery's `pu_…` id, when the notification payload carried one. */
    public val pushId: String? = null,
    /**
     * The notification payload's `msgId`, verbatim.
     *
     * A `String` rather than a `Long` because the server's field is one: it takes the id out of the
     * text, so an id that has already survived a vendor's payload never has to survive a numeric
     * round trip on the way back. Pass what the payload gave you and do not parse it first.
     */
    public val messageId: String? = null,
)

// ------------------------------------------------------------------------ moderation.*

/**
 * `moderation.report`.
 *
 * **The reporter is the connection.** There is deliberately no `reporterId` here, the same way
 * [RegisterPushTokenRequest] has no `deviceId`: filing a report in somebody else's name is not
 * merely forbidden, there is no field in which to say it. That matters more here than elsewhere —
 * a spoofable report is both a way to get an innocent account banned and a way to poison the count
 * a moderator decides on.
 *
 * Nothing is validated but "not yourself" and the category. In particular the server does not check
 * that the message still exists: a report about a message that was already deleted is exactly the
 * report a moderator most wants, and refusing it would turn the platform's own retention into a way
 * to escape moderation. Do not pre-filter those in your UI either.
 *
 * 举报人来自连接，这里没有、也不能有 reporterId。服务端只校验「不是自己」和分类：
 * 关于「已被删掉的消息」的举报恰恰是审核员最想要的那条，客户端也不要替它筛掉。
 */
@Serializable
public data class SubmitReportRequest(
    public val targetUserId: String,
    public val conversationId: String? = null,
    /**
     * The message being reported. Zero reports the account rather than one message.
     *
     * **Quoted on the wire.** Message ids are snowflakes around 2^58 — 38 times past the largest
     * integer a JavaScript client holds exactly — so the platform writes every one of them as a
     * string and reads both forms back (CONTRACT.md §4.5). A JVM `Long` holds the value exactly,
     * which is why the type here is still a number; what has to be a string is the JSON, not the
     * field.
     * 线路上加引号：消息 id 是雪花值，约 2^58，超出 JS 能精确表示的整数 38 倍，
     * 平台一律以字符串写出、两种形态都能读回。JVM 的 Long 本身放得下，
     * 所以这里的类型仍是数字——必须是字符串的是 JSON，不是字段。
     */
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long = 0,
    /** One of [ReportCategory]'s values. An unknown one is refused, not filed under `other`. */
    public val category: String = ReportCategory.Other,
    /** What the reporter typed. Usually the most useful field on the row a moderator reads. */
    public val note: String? = null,
)

/**
 * The categories `moderation.report` accepts.
 *
 * Constants rather than an enum for the same reason [PushProvider] is: the list is the server's and
 * it may grow before this artifact is rebuilt. An unknown value is refused with `1001` and the legal
 * list, which is a better failure than a report filed under a category no moderator screen shows.
 */
public object ReportCategory {
    public const val Spam: String = "spam"
    public const val Harassment: String = "harassment"
    public const val Fraud: String = "fraud"
    public const val Pornography: String = "pornography"
    public const val Violence: String = "violence"
    public const val Other: String = "other"
}

/**
 * Encodes a request object into the frame's `body`.
 *
 * One place, so that every typed method and `invoke()` put the same JSON on the wire — CONTRACT.md
 * §8 rule 1. A typed method that serialised its own body would drift from the escape hatch on
 * exactly the fields nobody tests.
 */
internal inline fun <reified T> T.asBody(): JsonElement = ImJson.encodeToJsonElement(this)
