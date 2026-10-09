import Foundation

// `desk.*` — the customer-service desk (T4): its requests, what it answers, its enumerations and
// the `evt.desk` frame. ``ImDeskNamespace`` is the surface that sends them.
//
// In a file of its own because the family is typed whole or not at all (CONTRACT.md §3), and a
// reader looking for "what does the desk send and get back" should find one place. The namespace
// itself lives in Namespaces.swift with the other ten, where `NamespacedSurfaceTests` reads it.
//
// **Three enum styles meet in this feature and the difference is on the wire.** ``DeskSessionState``
// and ``AgentStatus`` are bare C# enums and travel as **integers**; the end reason carries its own
// `JsonStringEnumConverter` server-side and travels as a **string**, and so do the disposition, the
// canned-reply scope and the `change` on an `evt.desk` frame. A `switch` written against the wrong
// one never matches and never throws.
//
// 同一个功能里三种枚举风格并存，区别在线路上：state / status 是整数，其余是字符串。

// MARK: - Enumerations

/// Where a desk session is. **`bot` counts as open**: a customer is either with the bot or with
/// people, never both, so "does this customer already have a session" must treat ``bot`` exactly
/// like ``queued`` and ``assigned``.
public struct DeskSessionState: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let queued = DeskSessionState(0)
    public static let assigned = DeskSessionState(1)
    public static let closed = DeskSessionState(2)
    public static let abandoned = DeskSessionState(3)
    /// The AI bot is handling the customer and no human is involved yet.
    public static let bot = DeskSessionState(4)
}

/// An agent's declared availability — and, because `desk.status` is also the heartbeat, the proof
/// their workbench is still there. **An integer on the wire**: the server refuses a name with `1000`
/// and a number outside 0–3 with `1001`.
public struct AgentStatus: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let offline = AgentStatus(0)
    public static let available = AgentStatus(1)
    public static let busy = AgentStatus(2)
    public static let away = AgentStatus(3)
}

/// Why a session ended, written by the system and never chosen by an agent. **A string on the
/// wire.** `nil` while the session is open, and `nil` on every session closed before the field
/// existed — render that as "unknown", not as ``human``.
public enum ImDeskEndReason {
    /// The bot answered and the customer left; nobody human was involved.
    public static let botResolved = "bot-resolved"
    /// The bot handed the customer to a human. The session that followed has its own reason.
    public static let botHandoff = "bot-handoff"
    /// An agent closed it.
    public static let human = "human"
    /// The customer left the queue before an agent took the session.
    public static let abandoned = "abandoned"
    /// The customer went silent after assignment and the inactivity timer closed it.
    public static let timeout = "timeout"
}

/// How a closing agent classified the session. The server refuses anything else with `1001`.
public enum ImDeskDisposition {
    public static let resolved = "resolved"
    public static let unresolved = "unresolved"
    public static let invalid = "invalid"
    /// Not a support case at all — a sales lead, handed on.
    public static let toLead = "to-lead"
}

/// The three tiers of a canned reply: one agent's own, one skill group's, everybody's.
public enum ImDeskCannedReplyScope {
    public static let personal = "personal"
    public static let group = "group"
    public static let all = "all"
}

/// The `change` on an `evt.desk` frame: the thirteen values the server's `DeskSessionChange.All`
/// declares, in that order.
///
/// **Strings, and open**: a value a newer server adds arrives unchanged in ``DeskEvent/change``, so a
/// `switch` over these needs a `default`. ``all`` is asserted against `endpoint-inventory.json`'s
/// `deskChanges` (CONTRACT.md §4.5).
public enum ImDeskSessionChange {
    /// An agent took the session.
    public static let assigned = "assigned"
    /// The holder let it go, or was forced off. On a forced release the frame carries **no session**.
    public static let released = "released"
    public static let closed = "closed"
    /// The model rewrote the handover summary.
    public static let summary = "summary"
    /// The customer sent a message; the frame carries it in ``DeskEvent/message``.
    public static let message = "message"
    public static let note = "note"
    public static let tag = "tag"
    public static let snooze = "snooze"
    /// A supervisor whispered to the holding agent. The customer never sees it.
    public static let whisper = "whisper"
    /// Declared by the server and **never pushed by it today**; listed so it is not a dropped frame.
    public static let typing = "typing"
    /// Both sides have been silent past the centre's timer.
    public static let inactive = "inactive"
    /// The first reply is overdue: once per session, to the holder and to every supervisor.
    public static let overdue = "overdue"
    /// Another tab of the same agent took over the workbench. A `desk.agent` frame; no session.
    public static let takeover = "takeover"

    /// The thirteen, in the server's declaration order.
    public static let all: [String] = [
        assigned, released, closed, summary, message, note, tag, snooze, whisper, typing, inactive, overdue,
        takeover,
    ]
}

// MARK: - Requests

/// `desk.request` — a customer asking for a person. **Every field is optional**: `im.desk.request()`
/// is the plain "talk to a human" button.
///
/// Idempotent server-side: a customer who already has a session in flight — queued, assigned, or
/// still with the bot — gets that same session back rather than a second one.
///
/// 幂等由服务端保证：已有进行中会话的客户拿回的就是那一个。
public struct DeskRequest: Encodable, Sendable, Hashable {
    /// Routing hint the tenant queues on: product line, language, VIP tier.
    public var skill: String?

    /// Higher goes first. `nil` is the server's default, 0.
    public var priority: Int?

    /// Opaque context the agent's workbench renders. The engine copies out the keys it recognises
    /// (`desk.channel`, `desk.visitorId`, …) and leaves everything else untouched.
    public var context: [String: JSONValue]?

    public init(skill: String? = nil, priority: Int? = nil, context: [String: JSONValue]? = nil) {
        self.skill = skill
        self.priority = priority
        self.context = context
    }
}

/// `desk.accept`. **Leave ``sessionId`` `nil` to take the next one waiting** — the normal case:
/// agents pull. An empty queue answers `1002`, not an empty success.
public struct DeskAcceptRequest: Encodable, Sendable, Hashable {
    public var sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

/// `desk.transfer` — hands a session on, carrying its whole history with it.
///
/// **Exactly one of three targets, and the type enforces it**: build one with
/// ``agent(sessionId:agentId:note:)``, ``skill(sessionId:skill:note:)`` or
/// ``queue(sessionId:note:)``; the memberwise initialiser is not public and the targets are not
/// settable. The server checks the same thing and answers `1001`.
///
/// 三个目标恰好一个，由类型保证：只能经三个工厂方法构造。
public struct DeskTransferRequest: Encodable, Sendable, Hashable {
    public let sessionId: String

    /// A named agent, who must be available and under capacity.
    public let toAgentId: String?

    /// A skill queue; the session goes to the front of it with its original `queuedAt` stamp.
    public let toSkill: String?

    /// Back to the queue it came from. Sent only as `true`; `nil` means another target was named.
    public let toQueue: Bool?

    /// Handover note for the receiving agent. **Internal**: never part of the customer-visible
    /// 1803 line.
    public var note: String?

    /// Every member, unchecked. Internal on purpose: the factories are the public way in.
    init(sessionId: String, toAgentId: String? = nil, toSkill: String? = nil, toQueue: Bool? = nil, note: String? = nil) {
        self.sessionId = sessionId
        self.toAgentId = toAgentId
        self.toSkill = toSkill
        self.toQueue = toQueue
        self.note = note
    }

    /// To a named agent.
    public static func agent(sessionId: String, agentId: String, note: String? = nil) -> DeskTransferRequest {
        DeskTransferRequest(sessionId: sessionId, toAgentId: agentId, note: note)
    }

    /// To a skill queue.
    public static func skill(sessionId: String, skill: String, note: String? = nil) -> DeskTransferRequest {
        DeskTransferRequest(sessionId: sessionId, toSkill: skill, note: note)
    }

    /// Back to its own queue, same stamp, same position — the 1805 requeue, chosen by a person.
    public static func queue(sessionId: String, note: String? = nil) -> DeskTransferRequest {
        DeskTransferRequest(sessionId: sessionId, toQueue: true, note: note)
    }
}

/// `desk.close` — the end-of-session drawer. Every field but the id is optional, and **an omitted
/// field is not the same as one set to a value**.
///
/// **``inviteRating`` left `nil` means `true`** — it is a C# property initialiser server-side, not
/// a nullable — so the only way to close without asking for a rating is to pass `false`.
///
/// 省略 inviteRating 等于 true：只有显式传 false 才是「不邀评」。
public struct DeskCloseRequest: Encodable, Sendable, Hashable {
    public var sessionId: String
    /// Free-text outcome, kept on the record.
    public var resolution: String?
    /// At most 20, each at most 64 characters; over either and the whole call is `1001`.
    public var tags: [String]?
    /// One of ``ImDeskDisposition``.
    public var disposition: String?
    /// The agent-edited summary, filed as a note. Never shown to the customer.
    public var summary: String?
    /// `nil` invites (the server's default). Pass `false` to close quietly.
    public var inviteRating: Bool?

    public init(
        sessionId: String,
        resolution: String? = nil,
        tags: [String]? = nil,
        disposition: String? = nil,
        summary: String? = nil,
        inviteRating: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.resolution = resolution
        self.tags = tags
        self.disposition = disposition
        self.summary = summary
        self.inviteRating = inviteRating
    }
}

/// `desk.status` — availability, and by the same call the heartbeat that proves this workbench is
/// still there. **Send it on a timer**, not only when the agent changes status.
public struct DeskStatusRequest: Encodable, Sendable, Hashable {
    /// Sent as its integer. Outside 0–3 is `1001`.
    public var status: AgentStatus
    /// Sessions this agent will hold at once. `nil` keeps the deployment default.
    public var maxConcurrent: Int?

    public init(status: AgentStatus, maxConcurrent: Int? = nil) {
        self.status = status
        self.maxConcurrent = maxConcurrent
    }
}

/// `desk.rate` — the customer's answer to the rating survey, in reply to the 1807 notice.
///
/// `nil` is meaningful on all three optional members: ``resolved`` `nil` means the survey did not
/// ask, which is not the same as `false`.
public struct DeskRateRequest: Encodable, Sendable, Hashable {
    public var sessionId: String
    /// 1–5. Anything else is `1001`.
    public var score: Int
    /// "Was your problem solved".
    public var resolved: Bool?
    /// At most 12, each at most 64 characters.
    public var starTags: [String]?
    /// At most 2000 characters.
    public var comment: String?

    public init(sessionId: String, score: Int, resolved: Bool? = nil, starTags: [String]? = nil, comment: String? = nil) {
        self.sessionId = sessionId
        self.score = score
        self.resolved = resolved
        self.starTags = starTags
        self.comment = comment
    }
}

/// `desk.suggest` — the session this agent holds.
public struct DeskSuggestRequest: Encodable, Sendable, Hashable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// `desk.canned`. All three are filters; leaving all three `nil` lists the whole centre's
/// phrasebook, **including every member's `personal` entries**.
///
/// **``ownerMemberId`` is a filter, not a permission: the server does not narrow it to the caller.**
/// Pass your own member id for "shared, plus mine".
public struct DeskCannedRequest: Encodable, Sendable, Hashable {
    public var skill: String?
    /// One of ``ImDeskCannedReplyScope``. An unrecognised value is `1001`.
    public var scope: String?
    public var ownerMemberId: String?

    public init(skill: String? = nil, scope: String? = nil, ownerMemberId: String? = nil) {
        self.skill = skill
        self.scope = scope
        self.ownerMemberId = ownerMemberId
    }
}

// MARK: - Payloads

/// One "customer asked, agent answered" pair inside a session, unix ms on both sides.
public struct DeskResponseSample: Decodable, Sendable, Hashable {
    public let customerAt: Int64
    public let agentAt: Int64
    public let agentId: String?

    enum CodingKeys: String, CodingKey {
        case customerAt, agentAt, agentId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customerAt = c.imInt64(.customerAt) ?? 0
        agentAt = c.imInt64(.agentAt) ?? 0
        agentId = c.imString(.agentId)
    }
}

/// The model-written handover summary a receiving agent reads before saying hello.
public struct DeskSessionSummary: Decodable, Sendable, Hashable {
    public let issue: String
    public let state: String
    public let nextStep: String
    public let generatedAt: Int64
    /// Which provider and model wrote it.
    public let model: String

    enum CodingKeys: String, CodingKey {
        case issue, state, nextStep, generatedAt, model
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issue = c.imString(.issue) ?? ""
        state = c.imString(.state) ?? ""
        nextStep = c.imString(.nextStep) ?? ""
        generatedAt = c.imInt64(.generatedAt) ?? 0
        model = c.imString(.model) ?? ""
    }
}

/// One desk session, as `desk.request`, `desk.accept` and every session-level `evt.desk` frame carry
/// it.
///
/// The product's fields from ``tags`` on were added after the engine shipped, so a session opened
/// before they existed reads back as the defaults here: `nil`, empty, or `false`.
public struct DeskSession: Decodable, Sendable, Hashable, Identifiable {
    public let sessionId: String
    public let appId: String
    /// The IM user asking for help. A minted visitor's id is `v_…`.
    public let customerId: String
    /// The agent holding it. `nil` while queued, and `nil` again after a release.
    public let agentId: String?
    /// The ordinary single chat between the customer and the desk account. Everything either side
    /// says is a normal message in it, sent with `msg.send`.
    public let conversationId: String
    public let state: DeskSessionState
    public let skill: String?
    public let priority: Int
    /// Unix ms. Preserved across a requeue.
    public let queuedAt: Int64
    public let assignedAt: Int64?
    public let closedAt: Int64?
    public let resolution: String?
    public let context: [String: JSONValue]?
    /// Agents who held it before.
    public let history: [String]
    public let firstAgentMessageAt: Int64?
    /// 1–5, `nil` until (and unless) the customer rates.
    public let rating: Int?
    /// When the 1807 invitation went out — the CSAT participation denominator.
    public let ratingInvitedAt: Int64?
    public let ratingComment: String?
    public let ratedAt: Int64?
    public let summary: DeskSessionSummary?
    public let tags: [String]
    /// How the visitor arrived: `web`, `app`, `api`, and the WeChat kinds.
    public let channel: String?
    public let visitorId: String?
    public let deskId: String?
    public let groupId: String?
    /// One of ``ImDeskDisposition``.
    public let disposition: String?
    /// One of ``ImDeskEndReason`` — a **string**. `nil` while open.
    public let endReason: String?
    public let ratingReason: String?
    /// `nil` until rated, and `nil` when the survey did not ask.
    public let ratingResolved: Bool?
    public let ratingTags: [String]
    public let star: Bool
    public let snoozedUntil: Int64?
    public let responseSamples: [DeskResponseSample]

    public var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId, appId, customerId, agentId, conversationId, state, skill, priority, queuedAt
        case assignedAt, closedAt, resolution, context, history, firstAgentMessageAt, rating
        case ratingInvitedAt, ratingComment, ratedAt, summary, tags, channel, visitorId, deskId
        case groupId, disposition, endReason, ratingReason, ratingResolved, ratingTags, star
        case snoozedUntil, responseSamples
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = c.imString(.sessionId) ?? ""
        appId = c.imString(.appId) ?? ""
        customerId = c.imString(.customerId) ?? ""
        agentId = c.imString(.agentId)
        conversationId = c.imString(.conversationId) ?? ""
        state = c.imValue(DeskSessionState.self, .state) ?? .queued
        skill = c.imString(.skill)
        priority = c.imInt(.priority) ?? 0
        queuedAt = c.imInt64(.queuedAt) ?? 0
        assignedAt = c.imInt64(.assignedAt)
        closedAt = c.imInt64(.closedAt)
        resolution = c.imString(.resolution)
        context = c.imJSONMap(.context)
        history = c.imStrings(.history) ?? []
        firstAgentMessageAt = c.imInt64(.firstAgentMessageAt)
        rating = c.imInt(.rating)
        ratingInvitedAt = c.imInt64(.ratingInvitedAt)
        ratingComment = c.imString(.ratingComment)
        ratedAt = c.imInt64(.ratedAt)
        summary = c.imValue(DeskSessionSummary.self, .summary)
        tags = c.imStrings(.tags) ?? []
        channel = c.imString(.channel)
        visitorId = c.imString(.visitorId)
        deskId = c.imString(.deskId)
        groupId = c.imString(.groupId)
        disposition = c.imString(.disposition)
        endReason = c.imString(.endReason)
        ratingReason = c.imString(.ratingReason)
        ratingResolved = c.imBool(.ratingResolved)
        ratingTags = c.imStrings(.ratingTags) ?? []
        star = c.imBool(.star) ?? false
        snoozedUntil = c.imInt64(.snoozedUntil)
        responseSamples = c.imList(DeskResponseSample.self, .responseSamples) ?? []
    }
}

/// The queue as a supervisor watches it (`desk.queue`).
public struct DeskQueueView: Decodable, Sendable, Hashable {
    public let waiting: Int
    public let assigned: Int
    public let availableAgents: Int
    /// Seconds the head of the queue has been waiting.
    public let headWaitSeconds: Int64
    /// Average seconds from entering the queue to the first agent message, over the last 24 hours.
    /// **`nil` means nothing measurable in the window** — draw "no data", never 0.
    public let avgFirstResponseSeconds: Double?
    public let waitingBySkill: [String: Int]

    enum CodingKeys: String, CodingKey {
        case waiting, assigned, availableAgents, headWaitSeconds, avgFirstResponseSeconds, waitingBySkill
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waiting = c.imInt(.waiting) ?? 0
        assigned = c.imInt(.assigned) ?? 0
        availableAgents = c.imInt(.availableAgents) ?? 0
        headWaitSeconds = c.imInt64(.headWaitSeconds) ?? 0
        avgFirstResponseSeconds = (try? c.decodeIfPresent(Double.self, forKey: .avgFirstResponseSeconds)) ?? nil
        waitingBySkill = (c.imInt64Map(.waitingBySkill) ?? [:]).compactMapValues { Int(exactly: $0) }
    }
}

/// One canned reply, as `desk.canned` lists it.
public struct DeskCannedReply: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let content: String
    /// `nil` means every agent sees it.
    public let skill: String?
    /// One of ``ImDeskCannedReplyScope``. An entry stored before the field existed reads back as `all`.
    public let scope: String
    public let folder: String?
    public let ownerMemberId: String?
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, content, skill, scope, folder, ownerMemberId, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.imString(.id) ?? ""
        title = c.imString(.title) ?? ""
        content = c.imString(.content) ?? ""
        skill = c.imString(.skill)
        scope = c.imString(.scope) ?? ImDeskCannedReplyScope.all
        folder = c.imString(.folder)
        ownerMemberId = c.imString(.ownerMemberId)
        updatedAt = c.imInt64(.updatedAt) ?? 0
    }
}

// MARK: - evt.desk

/// One `evt.desk` frame, as ``ImClient/deskEvents()`` delivers it.
///
/// Two shapes share the target, told apart by ``event``: **`desk.session`** — something happened to
/// one session (``change`` is one of ``ImDeskSessionChange``) — and **`desk.agent`** — something
/// happened to the agent, today only `takeover`, carrying ``connectionId`` and ``memberId`` and no
/// session.
///
/// **``session`` is `nil` on a forced `released`, and that is not a decoding accident**: the
/// workbench being told is the one losing the session. The per-change extras are flat and optional
/// because the wire is; the structured ones (``message``, ``note``, ``author``) are kept as JSON.
///
/// **A frame whose `event` this build does not know does not decode** — it throws, so
/// ``ImClient/events(_:as:)`` skips it rather than delivering it half-built.
///
/// 同一个 target 上有两种帧，用 event 区分。强制释放时 session 为 nil，这不是解码事故。
public struct DeskEvent: Decodable, Sendable, Hashable {
    /// ``event`` of a frame about one session.
    public static let sessionEvent = "desk.session"
    /// ``event`` of a frame about the agent rather than a session.
    public static let agentEvent = "desk.agent"

    /// ``sessionEvent`` or ``agentEvent``.
    public let event: String
    /// One of ``ImDeskSessionChange``, or a value a newer server added.
    public let change: String
    /// `nil` on a forced `released` and on every `desk.agent` frame.
    public let session: DeskSession?
    /// `message` — the customer's message, in the message API's wire shape (`messageId` a string).
    public let message: [String: JSONValue]?
    /// `released` (forced) — why the supervisor took them off.
    public let reason: String?
    /// `released` (forced) — true when present.
    public let forced: Bool?
    /// `note` and `whisper` — the note itself.
    public let note: [String: JSONValue]?
    /// `note` and `whisper` — who wrote it (`memberId`, `name`, `avatar`).
    public let author: [String: JSONValue]?
    /// `overdue` — today always `first-response`.
    public let kind: String?
    /// `overdue` — unix ms the session was assigned.
    public let assignedAt: Int64?
    /// `overdue` and `inactive` — the configured threshold in minutes.
    public let minutes: Int?
    /// `inactive` — unix ms of the last thing either side said.
    public let silentSince: Int64?
    /// `inactive` — whether the holder had starred it.
    public let star: Bool?
    /// `desk.agent` — the connection that won. Compare it with your own; if it is not yours, you lost.
    public let connectionId: String?
    /// `desk.agent` — the console member behind the agent.
    public let memberId: String?

    enum CodingKeys: String, CodingKey {
        case event, change, session, message, reason, forced, note, author, kind, assignedAt, minutes
        case silentSince, star, connectionId, memberId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = c.imString(.event) ?? ""
        guard event == Self.sessionEvent || event == Self.agentEvent else {
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: c,
                debugDescription: "'\(event)' is not an evt.desk event this build knows"
            )
        }

        self.event = event
        change = c.imString(.change) ?? ""
        session = c.imValue(DeskSession.self, .session)
        message = c.imJSONMap(.message)
        reason = c.imString(.reason)
        forced = c.imBool(.forced)
        note = c.imJSONMap(.note)
        author = c.imJSONMap(.author)
        kind = c.imString(.kind)
        assignedAt = c.imInt64(.assignedAt)
        minutes = c.imInt(.minutes)
        silentSince = c.imInt64(.silentSince)
        star = c.imBool(.star)
        connectionId = c.imString(.connectionId)
        memberId = c.imString(.memberId)
    }
}
