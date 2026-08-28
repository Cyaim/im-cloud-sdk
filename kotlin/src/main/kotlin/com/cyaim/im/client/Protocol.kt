@file:OptIn(ExperimentalSerializationApi::class)

package com.cyaim.im.client

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

/*
 * Wire protocol types. These mirror docs/SPEC-02-protocol.md and sdk/CONTRACT.md §2, and are the
 * only place the shape of a frame is described on the client side. Payload models live in
 * Models.kt, request objects in Requests.kt, enumerations in Enums.kt.
 */

/**
 * The exact codec the SDK uses on the socket. It is public because your own payloads travel inside
 * [ImMessage.content] and [ImBody.data] as raw [JsonElement]s — decode them with this instance and
 * they get the same leniency the SDK gives itself.
 *
 * The four settings are CONTRACT.md §2's JSON policy, one for one:
 *
 * - `ignoreUnknownKeys` — the gateway is deployed far more often than the app on a user's phone,
 *   so every field the server adds after a release has to be invisible to clients built before it.
 *   A strict decoder turns "the server added a field" into "the app stopped receiving messages".
 * - `explicitNulls = false` — nulls are omitted when writing; an explicit null read into a
 *   non-nullable field falls back to its default rather than throwing.
 * - `isLenient` — `NumberHandling.AllowReadingFromString` on the server means a 64-bit `seq` can
 *   arrive as `"1234"`. Lenient parsing is what stops that from being an exception.
 * - `coerceInputValues` — the same forgiveness for a null where a default will do.
 */
public val ImJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
    explicitNulls = false
    coerceInputValues = true
    encodeDefaults = true
}

/** A request the client sends. `id` is mandatory: it is how a reply finds its caller. */
@Serializable
public data class ImRequest(
    public val id: String,
    public val target: String,
    public val body: JsonElement = JsonObject(emptyMap()),
)

/**
 * A frame the server sends. Replies and server-initiated pushes are structurally identical, which
 * is deliberate: one decoder handles both, and a push can be correlated exactly like a reply.
 *
 * Every field carries a PascalCase alternate. SPEC-02 §1.2 writes the envelope as
 * `Id`/`Target`/`Status`/`Body` while the gateway's JSON options emit camelCase, and a Kotlin
 * decoder — unlike a structurally typed one — quietly produces an all-defaults object when it
 * recognises none of the keys. That failure mode is a client which connects, receives frames and
 * delivers nothing, so we accept both spellings rather than bet on one.
 */
@Serializable
public data class ImFrame(
    @JsonNames("Id") public val id: String = "",
    @JsonNames("Target") public val target: String = "",
    /** Transport-level outcome: 0 routed, 1 endpoint threw, 2 endpoint not found. */
    @JsonNames("Status") public val status: Int = 0,
    @JsonNames("Msg") public val msg: String? = null,
    @JsonNames("RequestTime") public val requestTime: Long? = null,
    @JsonNames("CompleteTime") public val completeTime: Long? = null,
    @JsonNames("Body") public val body: ImBody? = null,
)

/**
 * Business-level result, nested inside the transport frame.
 *
 * The nesting is deliberate on the server side too: [ImFrame.status] is the transport outcome
 * (did the frame reach an endpoint at all) and [code] is the business outcome. Collapsing them
 * would lose the difference between "the gateway could not route this" and "the endpoint ran and
 * said no".
 */
@Serializable
public data class ImBody(
    @JsonNames("Code") public val code: Int = 0,
    @JsonNames("Message") public val message: String? = null,
    @JsonNames("TraceId") public val traceId: String? = null,
    @JsonNames("ServerTime") public val serverTime: Long = 0,
    @JsonNames("Data") public val data: JsonElement? = null,
)

/**
 * Business error codes (SPEC-02 §4, CONTRACT.md §7).
 *
 * Constants rather than an enum, on purpose: codes arrive off the wire from a server that is
 * newer than this artifact, and an enum would have to either fail to decode or fold the unknown
 * value into an `Unknown` member — throwing away the exact number the support ticket needs.
 *
 * The list is the server's `ImErrorCode` in full rather than the handful this SDK happens to
 * raise. A tenant branching on `1703 StorageQuotaExceeded` should not have to hard-code the
 * number because the SDK only bothered to name the codes it produces itself.
 */
public object ImErrorCode {
    public const val Ok: Int = 0

    // ---- 1000: transport and generic ----
    public const val InternalError: Int = 1000
    public const val InvalidArgument: Int = 1001
    public const val NotFound: Int = 1002

    /** Per-tenant API quota, or an endpoint's own limiter. Back off and surface it; see §7.4. */
    public const val RateLimited: Int = 1003
    public const val Timeout: Int = 1004

    /**
     * Also what a call made while the socket is down raises, client-side, without leaving the
     * device. CONTRACT.md §7.2 fixes this code for that case rather than inventing a local one.
     */
    public const val ServiceUnavailable: Int = 1005
    public const val Conflict: Int = 1006
    public const val PayloadTooLarge: Int = 1007

    /**
     * The deployment does not have this endpoint — an SDK newer than a private-deployment server.
     * Deliberately not [NotFound]: 1002 means "your group does not exist".
     */
    public const val UnsupportedOperation: Int = 1008

    /** Kept for source compatibility. [ServiceUnavailable] is the contract name for 1005. */
    @Deprecated("Renamed to ServiceUnavailable to match the server enum", ReplaceWith("ImErrorCode.ServiceUnavailable"))
    public const val NotConnected: Int = 1005

    // ---- 1100: authentication ----
    public const val Unauthorized: Int = 1100
    public const val TokenExpired: Int = 1101
    public const val TokenInvalid: Int = 1102
    public const val Forbidden: Int = 1103
    public const val UserBanned: Int = 1104
    public const val SignatureInvalid: Int = 1105
    public const val ReplayDetected: Int = 1106

    /** Arrives both as a `conn.kick` push and as a close reason. Never reconnect into it. */
    public const val KickedByOtherDevice: Int = 1107

    // ---- 1200: tenant and plan ----
    public const val AppNotFound: Int = 1200
    public const val AppDisabled: Int = 1201
    public const val QuotaExceeded: Int = 1202

    /**
     * The tenant has the feature switched off, or the module is not deployed.
     * **Never latch this locally** — a tenant can flip the flag at runtime and a client that
     * remembers "typing is off" stays broken until the app restarts.
     */
    public const val FeatureNotEnabled: Int = 1203
    public const val PlanExpired: Int = 1204
    public const val ConcurrencyLimitExceeded: Int = 1205

    // ---- 1300: users and relationships ----
    public const val UserNotFound: Int = 1300
    public const val UserAlreadyExists: Int = 1301
    public const val NotFriend: Int = 1302
    public const val BlockedByPeer: Int = 1303
    public const val BlockedPeer: Int = 1304
    public const val FriendRequestNotFound: Int = 1305
    public const val FriendLimitExceeded: Int = 1306
    public const val CannotAddSelf: Int = 1307

    // ---- 1400: messages ----
    public const val MessageNotFound: Int = 1400
    public const val MessageTooLong: Int = 1401
    public const val ModerationRejected: Int = 1402
    public const val RecallWindowExpired: Int = 1403
    public const val RecallForbidden: Int = 1404
    public const val EditWindowExpired: Int = 1405
    public const val DuplicateClientMessageId: Int = 1406
    public const val ConversationNotFound: Int = 1407
    public const val SenderMuted: Int = 1408
    public const val UnsupportedContentType: Int = 1409
    public const val ReceiptDisabled: Int = 1410

    // ---- 1500: groups ----
    public const val GroupNotFound: Int = 1500
    public const val GroupDismissed: Int = 1501
    public const val GroupFull: Int = 1502
    public const val NotGroupMember: Int = 1503
    public const val NoGroupPermission: Int = 1504
    public const val GroupMuted: Int = 1505
    public const val MemberMuted: Int = 1506
    public const val AlreadyGroupMember: Int = 1507
    public const val JoinNeedsApproval: Int = 1508
    public const val JoinForbidden: Int = 1509
    public const val InviteForbidden: Int = 1510
    public const val CannotOperateOwner: Int = 1511
    public const val ApplicationNotFound: Int = 1512

    // ---- 1600: chat rooms ----
    public const val RoomNotFound: Int = 1600
    public const val RoomFull: Int = 1601
    public const val NotInRoom: Int = 1602
    public const val RoomMuted: Int = 1603

    // ---- 1700: media ----
    public const val UploadFailed: Int = 1700
    public const val FileTypeNotAllowed: Int = 1701
    public const val FileTooLarge: Int = 1702
    public const val StorageQuotaExceeded: Int = 1703

    // ---- 2400: push delivery ----

    /**
     * A click named a delivery row this tenant does not have: it aged out after seven days, or the
     * notification was never sent by this platform.
     *
     * The one code of the 2400 band a device ever sees — the rest of it belongs to the console
     * plane, where a signed-in member reads their own push records. [PushApi.clicked] does not
     * raise it; see there for why a click count that is one short is not an application's problem.
     */
    public const val PushDeliveryNotFound: Int = 2401

    /**
     * Codes worth trying again, unchanged, later. Computed from the code alone so that all five
     * SDKs agree (CONTRACT.md §7.3) — note that nothing outside this set is retryable, including
     * every 1100 and 1200 code: retrying those produces the same answer.
     */
    public fun isRetryable(code: Int): Boolean =
        code == InternalError || code == RateLimited || code == Timeout || code == ServiceUnavailable

    /**
     * Codes that mean "the token, not the request, is what was rejected".
     *
     * Narrower than the whole 1100 band on purpose: [Forbidden] and [UserBanned] also live there
     * and a fresh token fixes neither.
     */
    public fun requiresReauth(code: Int): Boolean =
        code == Unauthorized || code == TokenExpired || code == TokenInvalid
}

/** Server-initiated event names (SPEC-02 §2.7). */
public object PushTarget {
    public const val Message: String = "evt.message"
    public const val MessageUpdate: String = "evt.messageUpdate"
    public const val ConversationUpdate: String = "evt.conversationUpdate"
    public const val Read: String = "evt.read"
    public const val Typing: String = "evt.typing"
    public const val Presence: String = "evt.presence"
    public const val Friend: String = "evt.friend"
    public const val Group: String = "evt.group"
    public const val System: String = "evt.system"
    public const val Stream: String = "evt.stream"
    public const val Call: String = "evt.call"
    public const val Desk: String = "evt.desk"
    public const val Kick: String = "conn.kick"
}

/**
 * Maps an open enum to its wire integer and back. Unlike a generated enum serializer it cannot
 * fail: every integer is a legal value, and an unrecognised one keeps its number (see Enums.kt).
 */
public class IntCodeSerializer<T>(
    serialName: String,
    private val encode: (T) -> Int,
    private val decode: (Int) -> T,
) : KSerializer<T> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(serialName, PrimitiveKind.INT)
    override fun serialize(encoder: Encoder, value: T): Unit = encoder.encodeInt(encode(value))
    override fun deserialize(decoder: Decoder): T = decode(decoder.decodeInt())
}

/**
 * Every non-zero business code becomes one of these, so callers can `try`/`catch` instead of
 * inspecting each result.
 *
 * Named `Exception` rather than `Error` (the TypeScript SDK's `ImError`) because on the JVM
 * `Error` means "the runtime is broken, do not catch this", and every one of these is catchable
 * and usually recoverable.
 */
public class ImException(
    /** A value from [ImErrorCode]. Branch on the constants, never on the message text. */
    public val code: Int,
    message: String,
    /** Server-side correlation id. Quote it in a support ticket and the server logs line up. */
    public val traceId: String? = null,
    /** The endpoint that failed, e.g. `msg.send`. */
    public val target: String? = null,
    cause: Throwable? = null,
) : Exception(message, cause) {

    /**
     * True when retrying the identical call could succeed. See [ImErrorCode.isRetryable].
     *
     * The SDK never acts on this by itself: it retries the *connection* and its own gap repair,
     * and nothing else. An SDK that silently re-sends on `1003` hides rate limiting from the UI
     * that has to explain it, and one that silently retries a send turns a visible failure into
     * an invisible delay.
     */
    public val isRetryable: Boolean get() = ImErrorCode.isRetryable(code)

    /** True when a fresh token would fix this. See [ImErrorCode.requiresReauth]. */
    public val requiresReauth: Boolean get() = ImErrorCode.requiresReauth(code)

    /** The whole 1100–1199 band. [requiresReauth] is the narrower question and usually the one you want. */
    public val isAuthFailure: Boolean get() = code in 1100..1199

    override fun toString(): String = buildString {
        append("ImException(code=").append(code)
        target?.let { append(", target=").append(it) }
        traceId?.let { append(", traceId=").append(it) }
        append("): ").append(message)
    }
}

/** Lifecycle of the socket, published as a `StateFlow` so UI can bind to it directly. */
public enum class ConnectionState {
    Idle,
    Connecting,
    Open,
    Reconnecting,
    Closed,
}

/**
 * Why the server hung up on us.
 *
 * The server closes with reason `im-kick:{Reason}`. Terminal reasons are the ones where coming
 * back would fail identically, forever — retrying them is how you ship a client that hammers the
 * gateway with a revoked token until the battery is flat.
 */
public enum class KickReason {
    /** Another device of the same user took the slot the multi-login policy allows. */
    MultiLoginPolicy,

    /** The token was invalidated server-side: logout elsewhere, key rotation. */
    TokenRevoked,

    /** The account is banned. */
    UserBanned,

    /** The tenant application was disabled — usually billing. */
    AppDisabled,

    /** A console operator forced this session off. */
    AdminKick,

    /** Recoverable: ask the host app for a fresh token, then come back. */
    TokenExpired,

    /** A reason this SDK version does not know. Treated as recoverable; see [isTerminal]. */
    Unknown,
    ;

    /** Terminal reasons must not reconnect. */
    public val isTerminal: Boolean
        get() = this == MultiLoginPolicy ||
            this == TokenRevoked ||
            this == UserBanned ||
            this == AppDisabled ||
            this == AdminKick

    public companion object {
        /** Prefix of the WebSocket close reason that marks a kick rather than a network failure. */
        public const val ClosePrefix: String = "im-kick:"

        public fun fromWire(name: String): KickReason =
            entries.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: Unknown
    }
}

/** A kick, as delivered on [ImClient.kicks]. */
public data class KickEvent(
    public val reason: KickReason,
    /** The raw text after `im-kick:`, kept so an unrecognised reason is still reportable. */
    public val raw: String,
)

/**
 * Collapses "absent" and "JSON null" into an empty object.
 *
 * Endpoints that return nothing send no `data` at all, and decoding `Unit` — or anything else —
 * from an empty object succeeds where decoding from null throws. One coercion here removes a
 * special case from every call site.
 */
internal fun JsonElement?.orEmptyObject(): JsonElement =
    if (this == null || this is JsonNull) JsonObject(emptyMap()) else this
