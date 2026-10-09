package com.cyaim.im.client

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/*
 * `desk.*` — the customer-service desk (T4): its requests, what it answers, its enumerations and
 * the `evt.desk` frame. [DeskApi] is the surface that sends them.
 *
 * In a file of its own rather than spread through Requests.kt and Models.kt because the family is
 * typed whole or not at all (CONTRACT.md §3), and a reader looking for "what does the desk send and
 * get back" should find one place.
 *
 * **Three enum styles meet in this feature and the difference is on the wire.** [DeskSessionState]
 * and [AgentStatus] are bare C# enums and travel as **integers**; [DeskEndReason] carries its own
 * `JsonStringEnumConverter` server-side and travels as a **string**, and so do [DeskDisposition],
 * [DeskCannedReplyScope] and the `change` on an `evt.desk` frame. A `when` written against the wrong
 * one never matches and never throws.
 *
 * 同一个功能里三种枚举风格并存，区别在线路上：state / status 是整数，endReason、disposition、
 * scope 与 change 是字符串。对错了的 when 不会报错，只是永远不命中。
 */

// ------------------------------------------------------------------------------- enumerations

/**
 * Where a desk session is. **`Bot` counts as open**: a customer is either with the bot or with
 * people, never both, so "does this customer already have a session" must treat [Bot] exactly like
 * [Queued] and [Assigned].
 *
 * `Bot` 算「进行中」：查「这位客户是否已有会话」时，必须与 Queued / Assigned 同等对待。
 */
@JvmInline
@Serializable(with = DeskSessionStateSerializer::class)
public value class DeskSessionState(public val code: Int) {
    override fun toString(): String = openEnumName("DeskSessionState", code, NAMES)

    public companion object {
        public val Queued: DeskSessionState = DeskSessionState(0)
        public val Assigned: DeskSessionState = DeskSessionState(1)
        public val Closed: DeskSessionState = DeskSessionState(2)
        public val Abandoned: DeskSessionState = DeskSessionState(3)

        /** The AI bot is handling the customer and no human is involved yet. */
        public val Bot: DeskSessionState = DeskSessionState(4)

        private val NAMES = mapOf(0 to "Queued", 1 to "Assigned", 2 to "Closed", 3 to "Abandoned", 4 to "Bot")
    }
}

public object DeskSessionStateSerializer : KSerializer<DeskSessionState> by IntCodeSerializer<DeskSessionState>(
    "DeskSessionState",
    { it.code },
    { DeskSessionState(it) },
)

/**
 * An agent's declared availability — and, because `desk.status` is also the heartbeat, the proof
 * their workbench is still there. **An integer on the wire**: the server refuses a name with `1000`
 * and a number outside 0–3 with `1001`.
 */
@JvmInline
@Serializable(with = AgentStatusSerializer::class)
public value class AgentStatus(public val code: Int) {
    override fun toString(): String = openEnumName("AgentStatus", code, NAMES)

    public companion object {
        public val Offline: AgentStatus = AgentStatus(0)
        public val Available: AgentStatus = AgentStatus(1)
        public val Busy: AgentStatus = AgentStatus(2)
        public val Away: AgentStatus = AgentStatus(3)

        private val NAMES = mapOf(0 to "Offline", 1 to "Available", 2 to "Busy", 3 to "Away")
    }
}

public object AgentStatusSerializer : KSerializer<AgentStatus> by IntCodeSerializer<AgentStatus>(
    "AgentStatus",
    { it.code },
    { AgentStatus(it) },
)

/**
 * Why a session ended, written by the system and never chosen by an agent. **A string on the wire**,
 * unlike [DeskSessionState]. Null while the session is open, and null on every session closed before
 * the field existed — render that as "unknown", not as [Human].
 *
 * 线上是字符串。会话开着时为 null，字段出现之前关闭的会话也是 null——报表要画「未知」。
 */
public object DeskEndReason {
    /** The bot answered and the customer left; nobody human was involved. */
    public const val BotResolved: String = "bot-resolved"

    /** The bot handed the customer to a human. The session that followed has its own reason. */
    public const val BotHandoff: String = "bot-handoff"

    /** An agent closed it. */
    public const val Human: String = "human"

    /** The customer left the queue before an agent took the session. */
    public const val Abandoned: String = "abandoned"

    /** The customer went silent after assignment and the inactivity timer closed it. */
    public const val Timeout: String = "timeout"
}

/**
 * How a closing agent classified the session. The reports group on these exact strings, and the
 * server refuses anything else with `1001` rather than storing it.
 */
public object DeskDisposition {
    public const val Resolved: String = "resolved"
    public const val Unresolved: String = "unresolved"
    public const val Invalid: String = "invalid"

    /** Not a support case at all — a sales lead, handed on. */
    public const val ToLead: String = "to-lead"
}

/** The three tiers of a canned reply: one agent's own, one skill group's, everybody's. */
public object DeskCannedReplyScope {
    public const val Personal: String = "personal"
    public const val Group: String = "group"
    public const val All: String = "all"
}

/**
 * The `change` on an `evt.desk` frame: the thirteen values the server's `DeskSessionChange.All`
 * declares, in that order. **Strings, and open**: a value a newer server adds arrives unchanged in
 * [DeskEvent.change], so a `when` over these needs an `else` — and the branch it forces you to write
 * is the one that handles a server newer than your build. [All] is asserted against
 * `endpoint-inventory.json`'s `deskChanges` (CONTRACT.md §4.5).
 *
 * 字符串，且是开放的：服务端新增的值原样到达 DeskEvent.change，所以 when 需要 else。
 */
public object DeskSessionChange {
    /** An agent took the session. */
    public const val Assigned: String = "assigned"

    /** The holder let it go, or was forced off. On a forced release the frame carries **no session**. */
    public const val Released: String = "released"
    public const val Closed: String = "closed"

    /** The model rewrote the handover summary. */
    public const val Summary: String = "summary"

    /** The customer sent a message; the frame carries it in [DeskEvent.message]. */
    public const val Message: String = "message"
    public const val Note: String = "note"
    public const val Tag: String = "tag"
    public const val Snooze: String = "snooze"

    /** A supervisor whispered to the holding agent. The customer never sees it. */
    public const val Whisper: String = "whisper"

    /** Declared by the server and **never pushed by it today**; listed so it is not a dropped frame. */
    public const val Typing: String = "typing"

    /** Both sides have been silent past the centre's timer. */
    public const val Inactive: String = "inactive"

    /** The first reply is overdue: once per session, to the holder and to every supervisor. */
    public const val Overdue: String = "overdue"

    /** Another tab of the same agent took over the workbench. A `desk.agent` frame; no session. */
    public const val Takeover: String = "takeover"

    /** The thirteen, in the server's declaration order. */
    public val All: List<String> = listOf(
        Assigned, Released, Closed, Summary, Message, Note, Tag, Snooze, Whisper, Typing, Inactive, Overdue, Takeover,
    )
}

// ---------------------------------------------------------------------------------- requests

/**
 * `desk.request`. A customer asking for a person. **Every field is optional and the whole body may
 * be left at its defaults** — `im.desk.request()` is the plain "talk to a human" button.
 *
 * Idempotent server-side: a customer who already has a session in flight — queued, assigned, or still
 * with the bot — gets that same session back rather than a second one.
 *
 * 幂等由服务端保证：已有进行中会话的客户拿回的就是那一个，不会占住第二个坐席。
 */
@Serializable
public data class DeskRequest(
    /** Routing hint the tenant queues on: product line, language, VIP tier. */
    public val skill: String? = null,
    /** Higher goes first. Absent is the server's default, 0. */
    public val priority: Int? = null,
    /**
     * Opaque context the agent's workbench renders: order id, the page they were on. The engine
     * copies out the keys it recognises (`desk.channel`, `desk.visitorId`, …) and leaves everything
     * else here untouched.
     */
    public val context: JsonObject? = null,
)

/**
 * `desk.accept`. **Leave [sessionId] null to take the next one waiting** — the normal case: agents
 * pull, nothing is ever pushed at them. An empty queue answers `1002 NotFound`, not an empty success.
 */
@Serializable
public data class DeskAcceptRequest(
    public val sessionId: String? = null,
)

/**
 * `desk.transfer`. Hands a session on, carrying its whole history with it.
 *
 * **Exactly one of three targets, and the type enforces it**: build one with [agent], [skill] or
 * [queue] — the constructor is not public. The server checks the same thing and answers `1001
 * "exactly one of toAgentId, toSkill or toQueue is required"`; a factory per target means a
 * workbench that names two, or none, does not compile instead of failing in front of a customer
 * mid-handover.
 *
 * 三个目标恰好一个，由类型保证：只能经 agent / skill / queue 三个工厂构造。
 */
@Serializable
public class DeskTransferRequest internal constructor(
    public val sessionId: String,
    /** A named agent, who must be available and under capacity. */
    public val toAgentId: String? = null,
    /** A skill queue; the session goes to the front of it with its original `queuedAt` stamp. */
    public val toSkill: String? = null,
    /** Back to the queue it came from. Sent only as `true`; absent means another target was named. */
    public val toQueue: Boolean? = null,
    /**
     * Handover note for the receiving agent. **Internal**: filed as a note and never part of the
     * customer-visible 1803 line.
     */
    public val note: String? = null,
) {
    override fun equals(other: Any?): Boolean =
        other is DeskTransferRequest && other.sessionId == sessionId && other.toAgentId == toAgentId &&
            other.toSkill == toSkill && other.toQueue == toQueue && other.note == note

    override fun hashCode(): Int = listOf(sessionId, toAgentId, toSkill, toQueue, note).hashCode()

    override fun toString(): String =
        "DeskTransferRequest(sessionId=$sessionId, toAgentId=$toAgentId, toSkill=$toSkill, toQueue=$toQueue, note=$note)"

    public companion object {
        /** To a named agent. */
        public fun agent(sessionId: String, agentId: String, note: String? = null): DeskTransferRequest =
            DeskTransferRequest(sessionId = sessionId, toAgentId = agentId, note = note)

        /** To a skill queue. */
        public fun skill(sessionId: String, skill: String, note: String? = null): DeskTransferRequest =
            DeskTransferRequest(sessionId = sessionId, toSkill = skill, note = note)

        /** Back to its own queue, same stamp, same position — the 1805 requeue, chosen by a person. */
        public fun queue(sessionId: String, note: String? = null): DeskTransferRequest =
            DeskTransferRequest(sessionId = sessionId, toQueue = true, note = note)
    }
}

/**
 * `desk.close`. The end-of-session drawer; every field but the id is optional, and **an omitted
 * field is not the same as a field set to a value**: the server reads "absent" as "the agent did not
 * fill this in".
 *
 * **[inviteRating] left null means `true`** — it is a C# property initialiser, not a nullable — so
 * the only way to close without asking for a rating is to pass `false` explicitly.
 *
 * 省略 inviteRating 等于 true：只有显式传 false 才是「不邀评」。
 */
@Serializable
public data class DeskCloseRequest(
    public val sessionId: String,
    /** Free-text outcome, kept on the record. */
    public val resolution: String? = null,
    /** At most 20, each at most 64 characters; over either and the whole call is `1001`. */
    public val tags: List<String>? = null,
    /** One of [DeskDisposition]. */
    public val disposition: String? = null,
    /** The agent-edited summary, filed as a note. Never shown to the customer. */
    public val summary: String? = null,
    /** Null invites (the server's default). Pass `false` to close quietly. */
    public val inviteRating: Boolean? = null,
)

/**
 * `desk.status`. Availability, and — by the same call — the heartbeat that proves this workbench is
 * still there. **Send it on a timer**, not only when the agent changes status: the roster reclaims an
 * agent whose console has stopped talking and requeues their sessions.
 */
@Serializable
public data class DeskStatusRequest(
    /** An integer on the wire. Outside 0–3 is `1001`. */
    public val status: AgentStatus,
    /** Sessions this agent will hold at once. Null keeps the deployment default; the server clamps it. */
    public val maxConcurrent: Int? = null,
)

/**
 * `desk.rate`. The customer's answer to the rating survey, in reply to the 1807 notice.
 *
 * Null is meaningful on all three optional members: [resolved] null means the survey did not ask,
 * which is not the same as `false` ("no, it was not solved").
 */
@Serializable
public data class DeskRateRequest(
    public val sessionId: String,
    /** 1–5. Anything else is `1001`. */
    public val score: Int,
    /** "Was your problem solved". */
    public val resolved: Boolean? = null,
    /** At most 12, each at most 64 characters. */
    public val starTags: List<String>? = null,
    /** At most 2000 characters. */
    public val comment: String? = null,
)

/** `desk.suggest`: the session this agent holds. */
@Serializable
public data class DeskSuggestRequest(
    public val sessionId: String,
)

/**
 * `desk.canned`. All three are filters; leaving all three null lists the whole centre's phrasebook,
 * **including every member's `personal` entries**.
 *
 * **[ownerMemberId] is a filter, not a permission: the server does not narrow it to the caller.**
 * Pass your own member id for "shared, plus mine"; null returns everyone's personal entries.
 *
 * ownerMemberId 是过滤参数而非权限：服务端不按调用方收窄，省略即返回所有人的 personal 条目。
 */
@Serializable
public data class DeskCannedRequest(
    public val skill: String? = null,
    /** One of [DeskCannedReplyScope]. An unrecognised value is `1001`. */
    public val scope: String? = null,
    public val ownerMemberId: String? = null,
)

// --------------------------------------------------------------------------------- responses

/** One "customer asked, agent answered" pair inside a session, unix ms on both sides. */
@Serializable
public data class DeskResponseSample(
    public val customerAt: Long = 0,
    public val agentAt: Long = 0,
    public val agentId: String? = null,
)

/** The model-written handover summary a receiving agent reads before saying hello. */
@Serializable
public data class DeskSessionSummary(
    public val issue: String = "",
    public val state: String = "",
    public val nextStep: String = "",
    public val generatedAt: Long = 0,
    /** Which provider and model wrote it. */
    public val model: String = "",
)

/**
 * One desk session, as `desk.request`, `desk.accept` and every session-level `evt.desk` frame carry
 * it.
 *
 * The product's fields from [tags] on were added after the engine shipped, so a session opened
 * before they existed reads back as the defaults here: null, empty, or false.
 */
@Serializable
public data class DeskSession(
    public val sessionId: String = "",
    public val appId: String = "",
    /** The IM user asking for help. A minted visitor's id is `v_…`. */
    public val customerId: String = "",
    /** The agent holding it. Null while queued, and null again after a release. */
    public val agentId: String? = null,
    /**
     * The ordinary single chat between the customer and the desk account. Everything either side says
     * is a normal message in it, sent with `msg.send`.
     */
    public val conversationId: String = "",
    public val state: DeskSessionState = DeskSessionState.Queued,
    public val skill: String? = null,
    public val priority: Int = 0,
    /** Unix ms. Preserved across a requeue. */
    public val queuedAt: Long = 0,
    public val assignedAt: Long? = null,
    public val closedAt: Long? = null,
    public val resolution: String? = null,
    public val context: JsonObject? = null,
    /** Agents who held it before. */
    public val history: List<String> = emptyList(),
    public val firstAgentMessageAt: Long? = null,
    /** 1–5, null until (and unless) the customer rates. */
    public val rating: Int? = null,
    /** When the 1807 invitation went out — the CSAT participation denominator. */
    public val ratingInvitedAt: Long? = null,
    public val ratingComment: String? = null,
    public val ratedAt: Long? = null,
    public val summary: DeskSessionSummary? = null,
    public val tags: List<String> = emptyList(),
    /** How the visitor arrived: `web`, `app`, `api`, and the WeChat kinds. */
    public val channel: String? = null,
    public val visitorId: String? = null,
    public val deskId: String? = null,
    public val groupId: String? = null,
    /** One of [DeskDisposition]. */
    public val disposition: String? = null,
    /** One of [DeskEndReason] — a **string**. Null while open. */
    public val endReason: String? = null,
    public val ratingReason: String? = null,
    /** Null until rated, and null when the survey did not ask. */
    public val ratingResolved: Boolean? = null,
    public val ratingTags: List<String> = emptyList(),
    public val star: Boolean = false,
    public val snoozedUntil: Long? = null,
    public val responseSamples: List<DeskResponseSample> = emptyList(),
)

/** The queue as a supervisor watches it (`desk.queue`). */
@Serializable
public data class DeskQueueView(
    public val waiting: Int = 0,
    public val assigned: Int = 0,
    public val availableAgents: Int = 0,
    /** Seconds the head of the queue has been waiting. */
    public val headWaitSeconds: Long = 0,
    /**
     * Average seconds from entering the queue to the first agent message, over the last 24 hours.
     * **Null means nothing measurable in the window** — draw "no data", never 0.
     */
    public val avgFirstResponseSeconds: Double? = null,
    public val waitingBySkill: Map<String, Int> = emptyMap(),
)

/** One canned reply, as `desk.canned` lists it. */
@Serializable
public data class DeskCannedReply(
    public val id: String = "",
    public val title: String = "",
    public val content: String = "",
    /** Null means every agent sees it. */
    public val skill: String? = null,
    /** One of [DeskCannedReplyScope]. Never absent from a current server: an old entry reads back as `all`. */
    public val scope: String = DeskCannedReplyScope.All,
    public val folder: String? = null,
    public val ownerMemberId: String? = null,
    public val updatedAt: Long = 0,
)

// ----------------------------------------------------------------------------------- evt.desk

/**
 * One `evt.desk` frame, as [ImClient.deskEvents] delivers it.
 *
 * Two shapes share the target, told apart by [event]: **`desk.session`** — something happened to one
 * session ([change] is one of [DeskSessionChange]) — and **`desk.agent`** — something happened to the
 * agent, today only `takeover`, carrying [connectionId] and [memberId] and no session.
 *
 * **[session] is null on a forced `released`, and that is not a decoding accident**: the workbench
 * being told is the one losing the session. The per-change extras are flat and optional because the
 * wire is — the server merges them into one object. The three structured ones ([message], [note],
 * [author]) are kept as JSON objects.
 *
 * Frames arrive for **agents**. A customer's half of the desk comes through [ImClient.messages] as
 * the 1801–1807 notices.
 *
 * 同一个 target 上有两种帧，用 event 区分。强制释放时 session 为 null，这不是解码事故。
 */
@Serializable
public data class DeskEvent(
    /** [SESSION] or [AGENT]. */
    public val event: String = "",
    /** One of [DeskSessionChange], or a value a newer server added. */
    public val change: String = "",
    /** Null on a forced `released` and on every `desk.agent` frame. */
    public val session: DeskSession? = null,
    /** `message` — the customer's message, in the message API's wire shape (`messageId` a string). */
    public val message: JsonObject? = null,
    /** `released` (forced) — why the supervisor took them off. */
    public val reason: String? = null,
    /** `released` (forced) — true when present. */
    public val forced: Boolean? = null,
    /** `note` and `whisper` — the note itself. */
    public val note: JsonObject? = null,
    /** `note` and `whisper` — who wrote it (`memberId`, `name`, `avatar`). */
    public val author: JsonObject? = null,
    /** `overdue` — today always `first-response`. */
    public val kind: String? = null,
    /** `overdue` — unix ms the session was assigned. */
    public val assignedAt: Long? = null,
    /** `overdue` and `inactive` — the configured threshold in minutes. */
    public val minutes: Int? = null,
    /** `inactive` — unix ms of the last thing either side said. */
    public val silentSince: Long? = null,
    /** `inactive` — whether the holder had starred it. */
    public val star: Boolean? = null,
    /** `desk.agent` — the connection that won. Compare it with your own; if it is not yours, you lost. */
    public val connectionId: String? = null,
    /** `desk.agent` — the console member behind the agent. */
    public val memberId: String? = null,
) {
    public companion object {
        /** [event] of a frame about one session. */
        public const val SESSION: String = "desk.session"

        /** [event] of a frame about the agent rather than a session. */
        public const val AGENT: String = "desk.agent"
    }
}
