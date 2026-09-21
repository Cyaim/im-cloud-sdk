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
 *
 * **Each field leaves as the JSON kind of the server property it binds to**, and that is a hard
 * rule rather than a tidiness one. The socket binds a request body field by field with the C# type
 * of each property and none of the serializer's number handling: a C# `string` refuses a JSON
 * number, a `long` refuses a quoted one, an enum refuses its name, and each refusal is the whole
 * call failing with `1000` before the endpoint runs. So a message id — a `string` on every request
 * that carries one — is a `Long` here (it is what [ImMessage.messageId] holds) and is written with
 * [LongAsStringSerializer]; list elements the same way. `RequestWireKindTest` checks every field of
 * every typed endpoint against the server types in `endpoint-inventory.json`.
 *
 * 每个字段按它所绑定的服务端属性的 JSON 类型发出：socket 按 C# 类型逐字段绑定，不走序列化器的
 * 数字处理——string 拒收数字，long 拒收带引号的数字，枚举拒收名字，拒收就是整次调用 1000。
 * 所以消息 id 在这里是 Long（与 ImMessage.messageId 同型），线路上用 LongAsStringSerializer 写成字符串。
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
    /** Quoted on the wire: the server's field is a `string`. */
    @Serializable(with = LongAsStringSerializer::class)
    public val quoteMessageId: Long? = null,
    /** Quoted on the wire: the server's field is a `string`. */
    @Serializable(with = LongAsStringSerializer::class)
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

/**
 * `msg.recall`. Admin recall is a server-API capability and is refused on this path.
 *
 * [messageId] is quoted on the wire: the server's field is a `string`, and a JSON number there is
 * refused with `1000` before the endpoint runs.
 */
@Serializable
public data class RecallMessageRequest(
    public val conversationId: String,
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long,
    public val reason: String? = null,
)

/**
 * `msg.edit`. [content] replaces the old content wholesale; it is not a patch.
 * [messageId] is quoted on the wire (the server's field is a `string`).
 */
@Serializable
public data class EditMessageRequest(
    public val conversationId: String,
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long,
    public val content: JsonObject,
)

/**
 * `msg.delete`.
 *
 * [forEveryone] is the difference between hiding a message from your own device and destroying
 * other people's copy of it, so it defaults to false and the server checks whether you may.
 *
 * Each of [messageIds] is quoted on the wire: the server's field is a `List<string>`.
 */
@Serializable
public data class DeleteMessagesRequest(
    public val conversationId: String,
    public val messageIds: List<@Serializable(with = LongAsStringSerializer::class) Long>,
    public val forEveryone: Boolean = false,
)

/**
 * `msg.forward`. One call per fan-out; the reply is one result per target conversation.
 * Each of [messageIds] is quoted on the wire (the server's field is a `List<string>`).
 */
@Serializable
public data class ForwardMessagesRequest(
    public val sourceConversationId: String,
    public val messageIds: List<@Serializable(with = LongAsStringSerializer::class) Long>,
    public val targetConversationIds: List<String>,
    /** True bundles them into one `Merged` message instead of forwarding each separately. */
    public val merge: Boolean = false,
    public val mergeTitle: String? = null,
    /** Idempotency key for the whole fan-out. [ImClient] fills it in when left blank. */
    public val clientMsgId: String = "",
)

/** `msg.react`. [add] false removes the reaction. [messageId] is quoted on the wire. */
@Serializable
public data class ReactRequest(
    public val conversationId: String,
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long,
    public val emoji: String,
    public val add: Boolean = true,
)

/**
 * `msg.receipt`. Per-message read acknowledgement, distinct from the conversation read cursor.
 * Each of [messageIds] is quoted on the wire (the server's field is a `List<string>`).
 */
@Serializable
public data class ReceiptRequest(
    public val conversationId: String,
    public val messageIds: List<@Serializable(with = LongAsStringSerializer::class) Long>,
)

/** `msg.typing`. Never stored, never counted, and dropped first when a connection is behind. */
@Serializable
public data class TypingRequest(
    public val conversationId: String,
    public val typing: Boolean = true,
)

/**
 * `msg.pin`, `msg.unpin`, `msg.favourite`, `msg.unfavourite`, `msg.burn` — one message, named by
 * its conversation and its id.
 *
 * **[messageId] leaves quoted, and here that is the server's requirement rather than only this
 * SDK's caution.** The server's DTO declares it a `string`, and the socket binds request fields one
 * by one without the serializer's number handling, so a JSON number in that position is not read
 * as an id at all: the call comes back `1000 InternalError`. The field stays a `Long` so that
 * [ImMessage.messageId] goes straight in; what has to be a string is the JSON, not the field — the
 * same arrangement as [SubmitReportRequest.messageId].
 *
 * 消息 id 在线路上加引号，而这里不只是 SDK 的谨慎：服务端 DTO 就是 string，socket 逐字段绑定、
 * 不走序列化器的数字处理，给数字会直接回 1000。字段仍是 Long，好让 ImMessage.messageId 直接传进来。
 */
@Serializable
public data class ConversationMessageRequest(
    public val conversationId: String,
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long,
)

/**
 * `msg.receiptDetail`. Quoted on the wire for the reason [ConversationMessageRequest] gives: the
 * server's field is a `string`, and a JSON number there is refused with `1000`.
 */
@Serializable
public data class ReceiptDetailRequest(
    public val conversationId: String,
    @Serializable(with = LongAsStringSerializer::class)
    public val messageId: Long,
)

/**
 * `msg.favourites`. The server treats 0 (or an absent limit) as 20 and caps a page at 100; 20 is
 * sent explicitly so the default reads at the call site. A malformed [cursor] restarts at page one.
 */
@Serializable
public data class PageRequest(
    public val cursor: String? = null,
    public val limit: Int = 20,
)

/**
 * `msg.search`.
 *
 * [keyword] is required in practice — null or blank is `1001` — and one made only of punctuation or
 * emoji returns an empty page rather than an error.
 *
 * [contentTypes], [senderId], [startTime] and [endTime] are applied **after** the index has
 * produced its page, inclusively and against the server's `createTime`. A narrow filter therefore
 * produces short, even empty, pages with `hasMore = true`: keep paging on [Page.hasMore].
 *
 * Without a [conversationId] only the caller's 200 most recently updated conversations are
 * searched (`IM:Search:MaxConversationsPerQuery`); pass one to reach an older chat. A
 * [conversationId] the caller cannot see is `1103`, a group they are not in included.
 *
 * `msg.search` 的过滤条件是在索引出页之后才施加的，短页乃至空页而 hasMore 为真是常态；
 * 不给 conversationId 时只搜最近更新的 200 个会话。
 */
@Serializable
public data class SearchMessagesRequest(
    public val keyword: String,
    public val conversationId: String? = null,
    /** Sent as the integer codes the server's enum binds from; an unknown one is kept as it is. */
    public val contentTypes: List<MessageContentType>? = null,
    public val senderId: String? = null,
    /** Unix ms, inclusive, against the server's `createTime`. */
    public val startTime: Long? = null,
    /** Unix ms, inclusive, against the server's `createTime`. */
    public val endTime: Long? = null,
    public val cursor: String? = null,
    /** 0 or less becomes 20; capped server-side at 100. */
    public val limit: Int = 20,
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

/** `conv.get`, `conv.delete`, `conv.clear`, `msg.pins`. */
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

/**
 * `conv.markUnread`. [unread] false clears the mark.
 *
 * The default is the server's own — an absent `unread` means **true** — and it is sent explicitly
 * so that the call site and the wire say the same thing.
 */
@Serializable
public data class MarkUnreadRequest(
    public val conversationId: String,
    public val unread: Boolean = true,
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

/**
 * `user.setStatus`. A free-text custom status, trimmed server-side; longer than 64 characters is
 * `1001`. **Null or blank clears it**, so `SetStatusRequest()` is the "clear my status" call.
 */
@Serializable
public data class SetStatusRequest(
    public val status: String? = null,
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

/**
 * `friend.setRemark`. **The two optional fields do not mean the same thing when left null** (a null
 * is omitted from the frame, and the server reads the two absences differently).
 *
 * - [remark] null or blank **clears** the remark. To change only the tags, send the current remark
 *   back with them. Longer than 64 characters is `1001`; it is not truncated.
 * - [tags] null leaves the tags alone; an empty list clears them. More than 20, or any tag blank or
 *   longer than 32 characters, is `1001`.
 *
 * remark 为空即清除（只改 tags 时要把当前 remark 一并带上）；tags 为 null 不动、空列表清空。
 */
@Serializable
public data class SetRemarkRequest(
    public val userId: String,
    public val remark: String? = null,
    public val tags: List<String>? = null,
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

/**
 * `group.memberList`, `group.applicationList`. Always paged: a super group holds 100 000 members.
 *
 * [groupId] is required by `group.memberList`. For `group.applicationList` an empty one means
 * "every group I manage", which is why [GroupApi.applicationList] defaults to `""`.
 */
@Serializable
public data class GroupCursorRequest(
    public val groupId: String,
    public val cursor: String? = null,
    /** 1…200 is kept as sent; anything else — 0, negative or over 200 — becomes 50 server-side. */
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

/**
 * `group.transfer`. [newOwnerId] must already be a member (`1503` otherwise) and must not be you
 * (`1001`). The outgoing owner becomes a plain **member**, not an admin.
 */
@Serializable
public data class TransferOwnerRequest(
    public val groupId: String,
    public val newOwnerId: String,
)

/**
 * `group.handleApplication`.
 *
 * [accept] has no default here, although the server has one: an absent `accept` is read as
 * **false**, which rejects the application. A decision that important should be written down at
 * the call site rather than inherited from a missing field.
 * [reason] is kept on a rejection as `handleReason`; nobody is notified of a rejection.
 */
@Serializable
public data class HandleApplicationRequest(
    public val groupId: String,
    public val applicantId: String,
    public val accept: Boolean,
    public val reason: String? = null,
)

/**
 * `group.setRole`. Only [GroupRole.Member] and [GroupRole.Admin] are meaningful, and
 * [GroupApi.setRole] refuses anything else before it is sent.
 *
 * [role] has no default for the reason [HandleApplicationRequest.accept] has none: the server reads
 * an absent role as `Member`, which **demotes**. [GroupRole.Owner] is `1008` — ownership moves with
 * `group.transfer`. And the server stores any other integer it is given: `0` escapes a group-wide
 * mute (which only silences `Member`), and `4` or more is treated as a manager that outranks the
 * admins. That is why the method refuses them rather than trusting the server to.
 *
 * role 不设默认值：服务端把缺省读成 Member，等于降级。Owner 会被拒（1008，要用 group.transfer）；
 * 其他整数服务端照单全收——0 能逃过全员禁言，≥4 会比管理员还大——所以方法在发出前就拒掉它们。
 */
@Serializable
public data class SetRoleRequest(
    public val groupId: String,
    public val userId: String,
    public val role: GroupRole,
)

/**
 * `group.mute` — the whole group. [mute] false unmutes and ignores [untilMs].
 *
 * With [mute] true: no [untilMs] is **indefinite**; a future one lasts until then; and **a past one
 * is indefinite too, not an unmute** — the server keeps the mute and drops the end time. Compute
 * [untilMs] from the server clock where you can, in **milliseconds**: a seconds value is a moment in
 * January 1970 and so mutes the group forever.
 *
 * 过去的 untilMs 不是「解除」而是「无限期」；untilMs 是毫秒，填成秒就是 1970 年，同样是永久禁言。
 */
@Serializable
public data class MuteGroupRequest(
    public val groupId: String,
    /** The server's own default, sent explicitly. */
    public val mute: Boolean = true,
    /** Unix ms. */
    public val untilMs: Long? = null,
)

/**
 * `group.muteMember` — one member.
 *
 * **The opposite reading from [MuteGroupRequest]:** a future [untilMs] mutes until then, and a null
 * or past one **unmutes**. There is no indefinite member mute; send a far-future timestamp for one.
 *
 * 与 MuteGroupRequest 相反：null 或过去的 untilMs 表示解除；没有「无限期」，要就给一个很远的时间。
 */
@Serializable
public data class MuteMemberRequest(
    public val groupId: String,
    public val userId: String,
    /** Unix ms. */
    public val untilMs: Long? = null,
)

/**
 * `group.setNickname`. Null, empty or your own [userId] sets **your** nickname, which any member may
 * do; somebody else's needs owner or admin and outranking them.
 *
 * [nickname] is trimmed; null or blank clears it; past 64 characters it is **silently truncated**.
 */
@Serializable
public data class SetGroupNicknameRequest(
    public val groupId: String,
    public val userId: String? = null,
    public val nickname: String? = null,
)

/**
 * `group.announcement`. Null or blank clears it. Trimmed, and past 4096 characters **silently
 * truncated**.
 */
@Serializable
public data class AnnouncementRequest(
    public val groupId: String,
    public val announcement: String? = null,
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
     * **Quoted on the wire.** The server's `SubmitReportRequest.MessageId` is a string (since
     * 2026-09-21): absent, blank or `"0"` reports the account, digits name that message, and
     * anything else is refused with 1001. A JSON number is refused with 1000 — the socket binder
     * does not read a string field from a number (CONTRACT.md §2). A JVM `Long` holds the value
     * exactly, which is why the type here is still a number; what has to be a string is the JSON,
     * not the field, and the default 0 goes out as `"0"`, the account.
     * 线路上加引号：服务端这个字段是字符串——缺省、空白或 "0" 表示举报账号，纯数字是那条消息，其余回 1001；
     * 发 JSON 数字会被绑定器拒成 1000。JVM 的 Long 放得下，所以类型仍是数字，必须是字符串的是 JSON。
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
