using System;
using System.Collections.Generic;
using System.Globalization;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- enums
    //
    // Three enum styles meet in the desk and the difference is on the wire, not a matter of taste:
    // ImDeskSessionState and ImAgentStatus are bare C# enums server-side and travel as integers;
    // the end reason carries its own JsonStringEnumConverter and travels as a string, and so do the
    // disposition, the canned-reply scope and the change on an evt.desk frame. A switch written
    // against the wrong one never matches and never throws.
    // 同一个功能里三种枚举风格并存，区别在线路上：state / status 是整数，其余是字符串。

    /// <summary>Where a desk session is.</summary>
    /// <remarks>
    /// <b><see cref="Bot"/> counts as open</b>: a customer is either with the bot or with people,
    /// never both, so "does this player already have a session" must treat it exactly like
    /// <see cref="Queued"/> and <see cref="Assigned"/>.
    /// </remarks>
    public enum ImDeskSessionState
    {
        /// <summary>Waiting for an agent.</summary>
        Queued = 0,

        /// <summary>An agent holds it.</summary>
        Assigned = 1,

        /// <summary>Finished.</summary>
        Closed = 2,

        /// <summary>Nobody could take it and the desk gave up.</summary>
        Abandoned = 3,

        /// <summary>The AI bot is handling the customer and no human is involved yet.</summary>
        Bot = 4,
    }

    /// <summary>
    /// An agent's declared availability — and, because <c>desk.status</c> is also the heartbeat,
    /// the proof their workbench is still there. An integer on the wire.
    /// </summary>
    public enum ImAgentStatus
    {
        /// <summary>Not taking sessions.</summary>
        Offline = 0,

        /// <summary>Taking sessions.</summary>
        Available = 1,

        /// <summary>At the desk, not taking new sessions.</summary>
        Busy = 2,

        /// <summary>Stepped away.</summary>
        Away = 3,
    }

    /// <summary>
    /// Why a session ended, written by the system and never chosen by an agent. <b>A string on the
    /// wire.</b> Null while open, and null on every session closed before the field existed —
    /// render that as "unknown", not as <see cref="Human"/>.
    /// </summary>
    public static class ImDeskEndReason
    {
        /// <summary>The bot answered and the customer left; nobody human was involved.</summary>
        public const string BotResolved = "bot-resolved";

        /// <summary>The bot handed the customer to a human.</summary>
        public const string BotHandoff = "bot-handoff";

        /// <summary>An agent closed it.</summary>
        public const string Human = "human";

        /// <summary>The customer left the queue before an agent took the session.</summary>
        public const string Abandoned = "abandoned";

        /// <summary>The customer went silent after assignment and the inactivity timer closed it.</summary>
        public const string Timeout = "timeout";
    }

    /// <summary>How a closing agent classified the session. Anything else is refused with <c>1001</c>.</summary>
    public static class ImDeskDisposition
    {
        /// <summary>Resolved.</summary>
        public const string Resolved = "resolved";

        /// <summary>Not resolved.</summary>
        public const string Unresolved = "unresolved";

        /// <summary>Not a real case.</summary>
        public const string Invalid = "invalid";

        /// <summary>Not a support case at all — a sales lead, handed on.</summary>
        public const string ToLead = "to-lead";
    }

    /// <summary>The three tiers of a canned reply: one agent's own, one skill group's, everybody's.</summary>
    public static class ImDeskCannedReplyScope
    {
        /// <summary>One agent's own.</summary>
        public const string Personal = "personal";

        /// <summary>One skill group's.</summary>
        public const string Group = "group";

        /// <summary>Everybody's.</summary>
        public const string All = "all";
    }

    /// <summary>
    /// The <c>change</c> on an <c>evt.desk</c> frame: the thirteen values the server's
    /// <c>DeskSessionChange.All</c> declares, in that order.
    /// </summary>
    /// <remarks>
    /// Strings, and open: a value a newer server adds arrives unchanged in
    /// <see cref="ImDeskEvent.Change"/>, so a <c>switch</c> over these needs a <c>default</c>.
    /// <see cref="All"/> is asserted against <c>endpoint-inventory.json</c>'s <c>deskChanges</c>
    /// (CONTRACT §4.5).
    /// </remarks>
    public static class ImDeskSessionChange
    {
        /// <summary>An agent took the session.</summary>
        public const string Assigned = "assigned";

        /// <summary>The holder let it go, or was forced off. A forced release carries no session.</summary>
        public const string Released = "released";

        /// <summary>Closed.</summary>
        public const string Closed = "closed";

        /// <summary>The model rewrote the handover summary.</summary>
        public const string Summary = "summary";

        /// <summary>The customer sent a message; the frame carries it in <see cref="ImDeskEvent.Message"/>.</summary>
        public const string Message = "message";

        /// <summary>An agent's note.</summary>
        public const string Note = "note";

        /// <summary>Tags changed.</summary>
        public const string Tag = "tag";

        /// <summary>Snoozed.</summary>
        public const string Snooze = "snooze";

        /// <summary>A supervisor whispered to the holding agent. The customer never sees it.</summary>
        public const string Whisper = "whisper";

        /// <summary>Declared by the server and never pushed by it today; listed so it is not a dropped frame.</summary>
        public const string Typing = "typing";

        /// <summary>Both sides have been silent past the centre's timer.</summary>
        public const string Inactive = "inactive";

        /// <summary>The first reply is overdue.</summary>
        public const string Overdue = "overdue";

        /// <summary>Another tab of the same agent took over the workbench. A <c>desk.agent</c> frame.</summary>
        public const string Takeover = "takeover";

        /// <summary>The thirteen, in the server's declaration order.</summary>
        public static readonly IReadOnlyList<string> All = new[]
        {
            Assigned, Released, Closed, Summary, Message, Note, Tag, Snooze, Whisper, Typing, Inactive, Overdue, Takeover,
        };
    }

    // ---------------------------------------------------------------------- requests

    /// <summary>
    /// <c>desk.request</c>: a customer asking for a person. Every member is optional — the plain
    /// "talk to a human" button is <c>im.Desk.RequestAsync()</c>.
    /// </summary>
    /// <remarks>
    /// Idempotent server-side: a customer who already has a session in flight gets that same
    /// session back rather than a second one.
    /// 幂等由服务端保证：已有进行中会话的客户拿回的就是那一个。
    /// </remarks>
    public sealed class ImDeskRequest : IImRequest
    {
        /// <summary>Routing hint the tenant queues on: product line, language, VIP tier.</summary>
        public string Skill { get; set; }

        /// <summary>Higher goes first. Null is the server's default, 0.</summary>
        public long? Priority { get; set; }

        /// <summary>
        /// Opaque context the agent's workbench renders. The engine copies out the keys it
        /// recognises (<see cref="ImDeskContextKeys"/>: <c>desk.channel</c>, <c>desk.visitorId</c>, …)
        /// and leaves the rest untouched.
        /// </summary>
        public JsonValue Context { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("skill", Skill)
                .Set("priority", Priority);

            if (Context != null)
            {
                body.Set("context", Context);
            }

            return body;
        }
    }

    /// <summary>
    /// <c>desk.accept</c>. Leave <see cref="SessionId"/> null to take the next one waiting — the
    /// normal case: agents pull. An empty queue answers <c>1002</c>, not an empty success.
    /// </summary>
    public sealed class ImDeskAcceptRequest : IImRequest
    {
        /// <summary>The session to take, or null for the next one waiting.</summary>
        public string SessionId { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("sessionId", SessionId);
        }
    }

    /// <summary><c>desk.transfer</c>: hands a session on, carrying its whole history with it.</summary>
    /// <remarks>
    /// <b>Exactly one of three targets, and the type enforces it</b>: build one with
    /// <see cref="Agent"/>, <see cref="Skill"/> or <see cref="Queue"/> — there is no
    /// public constructor and no setter. The server checks the same thing and answers <c>1001</c>.
    /// 三个目标恰好一个，由类型保证：只能经三个工厂方法构造。
    /// </remarks>
    public sealed class ImDeskTransferRequest : IImRequest
    {
        private ImDeskTransferRequest(string sessionId, string toAgentId, string toSkill, bool toQueue, string note)
        {
            SessionId = sessionId;
            ToAgentId = toAgentId;
            ToSkill = toSkill;
            ToQueue = toQueue;
            Note = note;
        }

        /// <summary>The session being handed on.</summary>
        public string SessionId { get; private set; }

        /// <summary>A named agent, who must be available and under capacity.</summary>
        public string ToAgentId { get; private set; }

        /// <summary>A skill queue; the session goes to the front of it with its original stamp.</summary>
        public string ToSkill { get; private set; }

        /// <summary>Back to the queue it came from. Sent only when true.</summary>
        public bool ToQueue { get; private set; }

        /// <summary>Handover note for the receiving agent. Internal: never in the customer's 1803 line.</summary>
        public string Note { get; private set; }

        /// <summary>To a named agent.</summary>
        public static ImDeskTransferRequest Agent(string sessionId, string agentId, string note = null)
        {
            return new ImDeskTransferRequest(sessionId, agentId, null, false, note);
        }

        /// <summary>To a skill queue.</summary>
        public static ImDeskTransferRequest Skill(string sessionId, string skill, string note = null)
        {
            return new ImDeskTransferRequest(sessionId, null, skill, false, note);
        }

        /// <summary>Back to its own queue, same stamp, same position — the 1805 requeue, chosen by a person.</summary>
        public static ImDeskTransferRequest Queue(string sessionId, string note = null)
        {
            return new ImDeskTransferRequest(sessionId, null, null, true, note);
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("sessionId", SessionId)
                .Set("toAgentId", ToAgentId)
                .Set("toSkill", ToSkill);

            if (ToQueue)
            {
                body.Set("toQueue", true);
            }

            return body.Set("note", Note);
        }
    }

    /// <summary><c>desk.close</c>: the end-of-session drawer.</summary>
    /// <remarks>
    /// Every member but the id is optional, and an omitted member is not the same as one set to a
    /// value. <b><see cref="InviteRating"/> left null means true</b> — it is a C# property
    /// initialiser server-side, not a nullable — so the only way to close quietly is to set it to
    /// false.
    /// 省略 InviteRating 等于 true：只有显式设 false 才是「不邀评」。
    /// </remarks>
    public sealed class ImDeskCloseRequest : IImRequest
    {
        /// <summary>The session to close. Required.</summary>
        public string SessionId { get; set; }

        /// <summary>Free-text outcome, kept on the record.</summary>
        public string Resolution { get; set; }

        /// <summary>At most 20, each at most 64 characters; over either and the whole call is <c>1001</c>.</summary>
        public List<string> Tags { get; set; }

        /// <summary>One of <see cref="ImDeskDisposition"/>.</summary>
        public string Disposition { get; set; }

        /// <summary>The agent-edited summary, filed as a note. Never shown to the customer.</summary>
        public string Summary { get; set; }

        /// <summary>Null invites (the server's default). False closes quietly.</summary>
        public bool? InviteRating { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("sessionId", SessionId)
                .Set("resolution", Resolution);

            if (Tags != null)
            {
                body.Set("tags", ImJsonArrays.OfStrings(Tags));
            }

            body.Set("disposition", Disposition)
                .Set("summary", Summary);

            if (InviteRating.HasValue)
            {
                body.Set("inviteRating", InviteRating.Value);
            }

            return body;
        }
    }

    /// <summary>
    /// <c>desk.status</c>: availability, and — by the same call — the heartbeat. Send it on a timer,
    /// not only when the agent changes status.
    /// </summary>
    /// <remarks>
    /// <b>The status is a constructor argument, and there is no parameterless form.</b> Its default
    /// would be <see cref="ImAgentStatus.Offline"/> (0), a value the server accepts: a heartbeat
    /// written as <c>new ImDeskStatusRequest { MaxConcurrent = 4 }</c> would take the agent off the
    /// roster on every tick, with no error anywhere. The other four SDKs require it at compile time too.
    /// 状态是构造参数、没有无参构造：默认值 0 是 Offline，服务端照收，心跳会在每一拍把坐席下线而不报任何错。
    /// </remarks>
    public sealed class ImDeskStatusRequest : IImRequest
    {
        /// <inheritdoc cref="ImDeskStatusRequest"/>
        public ImDeskStatusRequest(ImAgentStatus status)
        {
            Status = status;
        }

        /// <summary>Sent as its integer. Outside 0–3 is <c>1001</c>.</summary>
        public ImAgentStatus Status { get; set; }

        /// <summary>Sessions this agent will hold at once. Null keeps the deployment default.</summary>
        public long? MaxConcurrent { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("status", (long)Status)
                .Set("maxConcurrent", MaxConcurrent);
        }
    }

    /// <summary><c>desk.rate</c>: the customer's answer to the rating survey (the 1807 notice).</summary>
    /// <remarks>
    /// Null is meaningful on all three optional members: <see cref="Resolved"/> null means the
    /// survey did not ask, which is not the same as false.
    /// </remarks>
    public sealed class ImDeskRateRequest : IImRequest
    {
        /// <summary>The session being rated. Required.</summary>
        public string SessionId { get; set; }

        /// <summary>1–5. Anything else is <c>1001</c>.</summary>
        public long Score { get; set; }

        /// <summary>"Was your problem solved".</summary>
        public bool? Resolved { get; set; }

        /// <summary>At most 12, each at most 64 characters.</summary>
        public List<string> StarTags { get; set; }

        /// <summary>At most 2000 characters.</summary>
        public string Comment { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("sessionId", SessionId)
                .Set("score", Score);

            if (Resolved.HasValue)
            {
                body.Set("resolved", Resolved.Value);
            }

            if (StarTags != null)
            {
                body.Set("starTags", ImJsonArrays.OfStrings(StarTags));
            }

            return body.Set("comment", Comment);
        }
    }

    /// <summary><c>desk.suggest</c>: the session this agent holds.</summary>
    public sealed class ImDeskSuggestRequest : IImRequest
    {
        /// <summary>The session to draft replies for. Required.</summary>
        public string SessionId { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("sessionId", SessionId);
        }
    }

    /// <summary><c>desk.canned</c>: which canned replies to list.</summary>
    /// <remarks>
    /// All three are filters; leaving all three null lists the whole phrasebook, <b>including every
    /// member's personal entries</b>. <see cref="OwnerMemberId"/> is a filter, not a permission —
    /// pass your own member id for "shared, plus mine".
    /// </remarks>
    public sealed class ImDeskCannedRequest : IImRequest
    {
        /// <summary>Only this skill's entries.</summary>
        public string Skill { get; set; }

        /// <summary>One of <see cref="ImDeskCannedReplyScope"/>. An unrecognised value is <c>1001</c>.</summary>
        public string Scope { get; set; }

        /// <summary>Whose personal entries to include.</summary>
        public string OwnerMemberId { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("skill", Skill)
                .Set("scope", Scope)
                .Set("ownerMemberId", OwnerMemberId);
        }
    }

    // ---------------------------------------------------------------------- payloads

    /// <summary>One "customer asked, agent answered" pair inside a session, unix ms on both sides.</summary>
    public sealed class ImDeskResponseSample : IImJsonPayload
    {
        /// <summary>When the customer asked.</summary>
        public long CustomerAt { get; internal set; }

        /// <summary>When an agent answered.</summary>
        public long AgentAt { get; internal set; }

        /// <summary>Who answered.</summary>
        public string AgentId { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            CustomerAt = json["customerAt"].AsLong();
            AgentAt = json["agentAt"].AsLong();
            AgentId = json["agentId"].AsString();
        }
    }

    /// <summary>The model-written handover summary a receiving agent reads before saying hello.</summary>
    public sealed class ImDeskSessionSummary : IImJsonPayload
    {
        /// <summary>What the customer came about.</summary>
        public string Issue { get; internal set; }

        /// <summary>Where the conversation stands.</summary>
        public string State { get; internal set; }

        /// <summary>What the next agent should do first.</summary>
        public string NextStep { get; internal set; }

        /// <summary>When it was written, unix ms.</summary>
        public long GeneratedAt { get; internal set; }

        /// <summary>Which provider and model wrote it.</summary>
        public string Model { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Issue = json["issue"].AsString(string.Empty);
            State = json["state"].AsString(string.Empty);
            NextStep = json["nextStep"].AsString(string.Empty);
            GeneratedAt = json["generatedAt"].AsLong();
            Model = json["model"].AsString(string.Empty);
        }
    }

    /// <summary>
    /// One desk session, as <c>desk.request</c>, <c>desk.accept</c> and every session-level
    /// <c>evt.desk</c> frame carry it.
    /// </summary>
    /// <remarks>
    /// The product's members from <see cref="Tags"/> on were added after the engine shipped, so a
    /// session opened before they existed reads back as the defaults: null, empty, or false.
    /// </remarks>
    public sealed class ImDeskSession : IImJsonPayload
    {
        /// <summary>The session id.</summary>
        public string SessionId { get; internal set; }

        /// <summary>The tenant.</summary>
        public string AppId { get; internal set; }

        /// <summary>The IM user asking for help. A minted visitor's id is <c>v_…</c>.</summary>
        public string CustomerId { get; internal set; }

        /// <summary>The agent holding it. Null while queued, and null again after a release.</summary>
        public string AgentId { get; internal set; }

        /// <summary>
        /// The ordinary single chat between the customer and the desk account. Everything either side
        /// says is a normal message in it, sent with <c>msg.send</c>.
        /// </summary>
        public string ConversationId { get; internal set; }

        /// <summary>Where it is.</summary>
        public ImDeskSessionState State { get; internal set; }

        /// <summary>The skill it was queued on.</summary>
        public string Skill { get; internal set; }

        /// <summary>Higher goes first.</summary>
        public int Priority { get; internal set; }

        /// <summary>Unix ms. Preserved across a requeue.</summary>
        public long QueuedAt { get; internal set; }

        /// <summary>Unix ms, or null while queued.</summary>
        public long? AssignedAt { get; internal set; }

        /// <summary>Unix ms, or null while open.</summary>
        public long? ClosedAt { get; internal set; }

        /// <summary>Free-text outcome the closing agent typed.</summary>
        public string Resolution { get; internal set; }

        /// <summary>The context the customer's request carried. Null when there was none.</summary>
        public JsonValue Context { get; internal set; }

        /// <summary>Agents who held it before.</summary>
        public List<string> History { get; internal set; }

        /// <summary>When the first agent message reached the customer, unix ms.</summary>
        public long? FirstAgentMessageAt { get; internal set; }

        /// <summary>1–5, null until (and unless) the customer rates.</summary>
        public int? Rating { get; internal set; }

        /// <summary>When the 1807 invitation went out — the CSAT participation denominator.</summary>
        public long? RatingInvitedAt { get; internal set; }

        /// <summary>What the customer wrote with the rating.</summary>
        public string RatingComment { get; internal set; }

        /// <summary>When the customer rated, unix ms.</summary>
        public long? RatedAt { get; internal set; }

        /// <summary>The handover summary, or null when there is none.</summary>
        public ImDeskSessionSummary Summary { get; internal set; }

        /// <summary>Labels the closing agent chose.</summary>
        public List<string> Tags { get; internal set; }

        /// <summary>How the visitor arrived: <c>web</c>, <c>app</c>, <c>api</c>, and the WeChat kinds.</summary>
        public string Channel { get; internal set; }

        /// <summary>The product's visitor record behind <see cref="CustomerId"/>.</summary>
        public string VisitorId { get; internal set; }

        /// <summary>The centre this session belongs to.</summary>
        public string DeskId { get; internal set; }

        /// <summary>The skill group it was routed to.</summary>
        public string GroupId { get; internal set; }

        /// <summary>One of <see cref="ImDeskDisposition"/>.</summary>
        public string Disposition { get; internal set; }

        /// <summary>One of <see cref="ImDeskEndReason"/> — a string. Null while open.</summary>
        public string EndReason { get; internal set; }

        /// <summary>The 1–2 star tags joined.</summary>
        public string RatingReason { get; internal set; }

        /// <summary>Null until rated, and null when the survey did not ask.</summary>
        public bool? RatingResolved { get; internal set; }

        /// <summary>Every per-star tag the customer picked.</summary>
        public List<string> RatingTags { get; internal set; }

        /// <summary>Starred by the holding agent.</summary>
        public bool Star { get; internal set; }

        /// <summary>Unix ms until which the session is snoozed.</summary>
        public long? SnoozedUntil { get; internal set; }

        /// <summary>One sample per customer message that got a reply.</summary>
        public List<ImDeskResponseSample> ResponseSamples { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            SessionId = json["sessionId"].AsString(string.Empty);
            AppId = json["appId"].AsString(string.Empty);
            CustomerId = json["customerId"].AsString(string.Empty);
            AgentId = json["agentId"].AsString();
            ConversationId = json["conversationId"].AsString(string.Empty);
            State = (ImDeskSessionState)json["state"].AsInt();
            Skill = json["skill"].AsString();
            Priority = json["priority"].AsInt();
            QueuedAt = json["queuedAt"].AsLong();
            AssignedAt = ImPayload.OptionalLong(json, "assignedAt");
            ClosedAt = ImPayload.OptionalLong(json, "closedAt");
            Resolution = json["resolution"].AsString();
            Context = json["context"].IsObject ? json["context"] : null;
            History = json["history"].AsStringList();
            FirstAgentMessageAt = ImPayload.OptionalLong(json, "firstAgentMessageAt");
            Rating = json["rating"].IsNull ? (int?)null : json["rating"].AsInt();
            RatingInvitedAt = ImPayload.OptionalLong(json, "ratingInvitedAt");
            RatingComment = json["ratingComment"].AsString();
            RatedAt = ImPayload.OptionalLong(json, "ratedAt");
            Summary = json["summary"].IsObject ? ImPayload.Read<ImDeskSessionSummary>(json["summary"]) : null;
            Tags = json["tags"].AsStringList();
            Channel = json["channel"].AsString();
            VisitorId = json["visitorId"].AsString();
            DeskId = json["deskId"].AsString();
            GroupId = json["groupId"].AsString();
            Disposition = json["disposition"].AsString();
            EndReason = json["endReason"].AsString();
            RatingReason = json["ratingReason"].AsString();
            RatingResolved = json["ratingResolved"].IsNull ? (bool?)null : json["ratingResolved"].AsBool();
            RatingTags = json["ratingTags"].AsStringList();
            Star = json["star"].AsBool();
            SnoozedUntil = ImPayload.OptionalLong(json, "snoozedUntil");
            ResponseSamples = ImPayload.ReadList<ImDeskResponseSample>(json["responseSamples"]);
        }
    }

    /// <summary>The queue as a supervisor watches it (<c>desk.queue</c>).</summary>
    public sealed class ImDeskQueueView : IImJsonPayload
    {
        /// <summary>Sessions waiting.</summary>
        public int Waiting { get; internal set; }

        /// <summary>Sessions an agent holds.</summary>
        public int Assigned { get; internal set; }

        /// <summary>Agents free to take one.</summary>
        public int AvailableAgents { get; internal set; }

        /// <summary>Seconds the head of the queue has been waiting.</summary>
        public long HeadWaitSeconds { get; internal set; }

        /// <summary>
        /// Average seconds from entering the queue to the first agent message, over the last 24
        /// hours. <b>Null means nothing measurable in the window</b> — draw "no data", never 0.
        /// </summary>
        public double? AvgFirstResponseSeconds { get; internal set; }

        /// <summary>Waiting sessions per skill.</summary>
        public Dictionary<string, int> WaitingBySkill { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Waiting = json["waiting"].AsInt();
            Assigned = json["assigned"].AsInt();
            AvailableAgents = json["availableAgents"].AsInt();
            HeadWaitSeconds = json["headWaitSeconds"].AsLong();
            AvgFirstResponseSeconds = json["avgFirstResponseSeconds"].IsNull
                ? (double?)null
                : json["avgFirstResponseSeconds"].AsDouble();

            WaitingBySkill = new Dictionary<string, int>();
            foreach (var entry in json["waitingBySkill"].Members)
            {
                WaitingBySkill[entry.Key] = entry.Value.AsInt();
            }
        }
    }

    /// <summary>One canned reply, as <c>desk.canned</c> lists it.</summary>
    public sealed class ImDeskCannedReply : IImJsonPayload
    {
        /// <summary>The entry's id.</summary>
        public string Id { get; internal set; }

        /// <summary>At most 100 characters.</summary>
        public string Title { get; internal set; }

        /// <summary>At most 4000 characters.</summary>
        public string Content { get; internal set; }

        /// <summary>Null means every agent sees it.</summary>
        public string Skill { get; internal set; }

        /// <summary>One of <see cref="ImDeskCannedReplyScope"/>. An old entry reads back as <c>all</c>.</summary>
        public string Scope { get; internal set; }

        /// <summary>The folder the workbench files it under. Null is the root.</summary>
        public string Folder { get; internal set; }

        /// <summary>The owner of a personal entry.</summary>
        public string OwnerMemberId { get; internal set; }

        /// <summary>Unix ms.</summary>
        public long UpdatedAt { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Id = json["id"].AsString(string.Empty);
            Title = json["title"].AsString(string.Empty);
            Content = json["content"].AsString(string.Empty);
            Skill = json["skill"].AsString();
            Scope = json["scope"].AsString(ImDeskCannedReplyScope.All);
            Folder = json["folder"].AsString();
            OwnerMemberId = json["ownerMemberId"].AsString();
            UpdatedAt = json["updatedAt"].AsLong();
        }
    }

    /// <summary>One <c>evt.desk</c> frame, as <see cref="ImClient.OnDeskEvent"/> delivers it.</summary>
    /// <remarks>
    /// <para>
    /// Two shapes share the target, told apart by <see cref="Event"/>: <c>desk.session</c> —
    /// something happened to one session — and <c>desk.agent</c> — something happened to the agent,
    /// today only <c>takeover</c>, carrying <see cref="ConnectionId"/> and <see cref="MemberId"/>
    /// and no session.
    /// </para>
    /// <para>
    /// <b><see cref="Session"/> is null on a forced <c>released</c></b>, and that is not a decoding
    /// accident: the workbench being told is the one losing the session. The per-change extras are
    /// flat and optional because the wire is; the structured ones are kept as JSON.
    /// 强制释放时 Session 为 null，这不是解码事故。
    /// </para>
    /// </remarks>
    public sealed class ImDeskEvent : IImJsonPayload
    {
        /// <summary><see cref="Event"/> of a frame about one session.</summary>
        public const string SessionEvent = "desk.session";

        /// <summary><see cref="Event"/> of a frame about the agent rather than a session.</summary>
        public const string AgentEvent = "desk.agent";

        /// <summary><see cref="SessionEvent"/> or <see cref="AgentEvent"/>.</summary>
        public string Event { get; internal set; }

        /// <summary>One of <see cref="ImDeskSessionChange"/>, or a value a newer server added.</summary>
        public string Change { get; internal set; }

        /// <summary>Null on a forced <c>released</c> and on every <c>desk.agent</c> frame.</summary>
        public ImDeskSession Session { get; internal set; }

        /// <summary><c>message</c> — the customer's message in the message API's wire shape.</summary>
        public JsonValue Message { get; internal set; }

        /// <summary><c>released</c> (forced) — why the supervisor took them off.</summary>
        public string Reason { get; internal set; }

        /// <summary><c>released</c> (forced) — true when present.</summary>
        public bool? Forced { get; internal set; }

        /// <summary><c>note</c> and <c>whisper</c> — the note itself.</summary>
        public JsonValue Note { get; internal set; }

        /// <summary><c>note</c> and <c>whisper</c> — who wrote it.</summary>
        public JsonValue Author { get; internal set; }

        /// <summary><c>overdue</c> — today always <c>first-response</c>.</summary>
        public string Kind { get; internal set; }

        /// <summary><c>overdue</c> — unix ms the session was assigned.</summary>
        public long? AssignedAt { get; internal set; }

        /// <summary><c>overdue</c> and <c>inactive</c> — the configured threshold in minutes.</summary>
        public long? Minutes { get; internal set; }

        /// <summary><c>inactive</c> — unix ms of the last thing either side said.</summary>
        public long? SilentSince { get; internal set; }

        /// <summary><c>inactive</c> — whether the holder had starred it.</summary>
        public bool? Star { get; internal set; }

        /// <summary><c>desk.agent</c> — the connection that won. If it is not yours, you lost.</summary>
        public string ConnectionId { get; internal set; }

        /// <summary><c>desk.agent</c> — the console member behind the agent.</summary>
        public string MemberId { get; internal set; }

        /// <summary>True for the two events this build knows; anything else is to be ignored.</summary>
        public bool IsKnown
        {
            get { return Event == SessionEvent || Event == AgentEvent; }
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Event = json["event"].AsString(string.Empty);
            Change = json["change"].AsString(string.Empty);
            Session = json["session"].IsObject ? ImPayload.Read<ImDeskSession>(json["session"]) : null;
            Message = json["message"].IsObject ? json["message"] : null;
            Reason = json["reason"].AsString();
            Forced = json["forced"].IsNull ? (bool?)null : json["forced"].AsBool();
            Note = json["note"].IsObject ? json["note"] : null;
            Author = json["author"].IsObject ? json["author"] : null;
            Kind = json["kind"].AsString();
            AssignedAt = ImPayload.OptionalLong(json, "assignedAt");
            Minutes = ImPayload.OptionalLong(json, "minutes");
            SilentSince = ImPayload.OptionalLong(json, "silentSince");
            Star = json["star"].IsNull ? (bool?)null : json["star"].AsBool();
            ConnectionId = json["connectionId"].AsString();
            MemberId = json["memberId"].AsString();
        }
    }

    // ---------------------------------------------------------------------- 1801-1807

    /// <summary>
    /// The seven codes a desk notice carries in its content's <c>code</c>: 1801–1807.
    /// </summary>
    /// <remarks>
    /// <b>The same seven numbers are account error codes elsewhere on this platform</b> — 1801 is
    /// <c>AccountLocked</c> on the server's error table and 1804 <c>PasswordTooWeak</c>. These are
    /// only ever read out of a <see cref="ImMessageContentType.Notification"/> message's content,
    /// never out of an error, which is why <see cref="ImDeskNotification.Read"/> checks both.
    /// 同样七个数字在别处是账号错误码；这里的只从通知消息的 content 里读。
    /// </remarks>
    public static class ImDeskNotificationCode
    {
        /// <summary>The customer is waiting for an agent.</summary>
        public const int Queued = 1801;

        /// <summary>An agent has taken the session.</summary>
        public const int Assigned = 1802;

        /// <summary>Handed to another agent. The handover note is <b>not</b> in this line; it is internal.</summary>
        public const int Transferred = 1803;

        /// <summary>Closed.</summary>
        public const int Closed = 1804;

        /// <summary>
        /// The agent became unreachable and the session went back to the <b>front</b> of the queue.
        /// Its own code rather than a second <see cref="Queued"/>, because "we are finding someone
        /// else for you" is a different sentence from "you are in the queue".
        /// </summary>
        public const int Requeued = 1805;

        /// <summary>Nobody could take the session and the desk gave up on it.</summary>
        public const int Abandoned = 1806;

        /// <summary>Closed, and the customer is being asked to rate it. At most once per session; answer it with <c>desk.rate</c>.</summary>
        public const int RatingRequested = 1807;
    }

    /// <summary>
    /// A desk notice read out of an ordinary message — one of seven sealed subclasses, told apart by
    /// type or by <see cref="Code"/>. <see cref="Read"/> is the reader.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Desk events are messages, not a side channel</b>, which is what makes a transcript explain
    /// itself six months later: "you are in the queue", "Alice is with you now", "closed" sit in
    /// history and in incremental sync, in the right place relative to the conversation around them.
    /// The cost is that <see cref="ImClient.MessageReceived"/> now delivers frames a game must not
    /// draw as chat. Call <see cref="Read"/> first, render a notice when it answers, fall through to
    /// the normal path when it returns null.
    /// </para>
    /// <para>
    /// The members every code carries live here; the extras live on the subclass. A C#
    /// <c>switch</c> over the subclasses is not checked for exhaustiveness, so give it a
    /// <c>default</c> — a newer server may add a code this build does not read, and
    /// <see cref="Read"/> returns null for it today.
    /// 客服事件本身就是消息，所以 MessageReceived 里会看到不能当聊天画的帧——Read 就是那道判断。
    /// </para>
    /// </remarks>
    public abstract class ImDeskNotification
    {
        internal ImDeskNotification()
        {
        }

        /// <summary>One of <see cref="ImDeskNotificationCode"/>; fixed by the subclass.</summary>
        public abstract int Code { get; }

        /// <summary>The desk session. Empty when the notice did not carry one.</summary>
        public string SessionId { get; internal set; }

        /// <summary>The customer the session is for. Empty when the notice did not carry one.</summary>
        public string CustomerId { get; internal set; }

        /// <summary>
        /// The skill it was queued on, or null. The server always writes the key — into a dictionary,
        /// where "omit nulls" does not reach — so null here is a written null, not an absence.
        /// </summary>
        public string Skill { get; internal set; }

        /// <summary>Present once an agent is involved, null before. Never an empty string.</summary>
        public string AgentId { get; internal set; }

        /// <summary>
        /// Reads a desk notice out of a message, or returns null when the message is not one. Never
        /// throws.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Two things it checks together: <see cref="ImMessage.ContentType"/> must be
        /// <see cref="ImMessageContentType.Notification"/> <b>and</b> the content's <c>code</c> must
        /// be 1801–1807, because the same seven numbers are account error codes elsewhere — a bare
        /// <c>code</c> check would one day draw "your account is locked" onto a support transcript.
        /// The content must be a JSON object.
        /// </para>
        /// <para>
        /// A member of the wrong kind reads as its default rather than losing the whole line: an id
        /// that is not a string reads as its literal when it is a number or a boolean and as empty
        /// otherwise; <see cref="Skill"/>, <see cref="AgentId"/> and the closing strings are read only
        /// from a JSON string (an empty <c>agentId</c> is no agent); a count is read from a JSON
        /// number or a string holding one (<c>"903"</c>, <c>"9.03e2"</c>), with a fraction cut off,
        /// and is 0 otherwise; <c>askResolved</c> is true only for the JSON <c>true</c>; a
        /// <c>starTags</c> entry that is not a string is skipped. A <c>code</c> that is not a whole
        /// number is no notice. Member names are matched without regard to case, as everywhere in
        /// this SDK's <see cref="JsonValue"/>.
        /// </para>
        /// 同时查内容类型与码值：光查码值，迟早会把「账号已锁定」画进一段工单记录里。
        /// </remarks>
        public static ImDeskNotification Read(ImMessage message)
        {
            if (message == null || message.ContentType != ImMessageContentType.Notification)
            {
                return null;
            }

            var content = message.Content;
            if (content == null || !content.IsObject)
            {
                return null;
            }

            long code;
            if (!TryReadNumber(content["code"], false, out code)
                || code < ImDeskNotificationCode.Queued
                || code > ImDeskNotificationCode.RatingRequested)
            {
                return null;
            }

            ImDeskNotification notice;
            switch ((int)code)
            {
                case ImDeskNotificationCode.Queued:
                    notice = new ImDeskQueuedNotification();
                    break;

                case ImDeskNotificationCode.Assigned:
                    notice = new ImDeskAssignedNotification();
                    break;

                case ImDeskNotificationCode.Transferred:
                    notice = new ImDeskTransferredNotification { FromAgentId = Id(content["fromAgentId"]) };
                    break;

                case ImDeskNotificationCode.Closed:
                    notice = new ImDeskClosedNotification
                    {
                        Resolution = Text(content["resolution"]),
                        Reason = Text(content["reason"]),
                    };
                    break;

                case ImDeskNotificationCode.Requeued:
                    notice = new ImDeskRequeuedNotification { PreviousAgentId = Id(content["previousAgentId"]) };
                    break;

                case ImDeskNotificationCode.Abandoned:
                    notice = new ImDeskAbandonedNotification { WaitedSeconds = Count(content["waitedSeconds"]) };
                    break;

                default:
                    var askResolved = content["askResolved"];
                    notice = new ImDeskRatingRequestedNotification
                    {
                        WindowHours = Count(content["windowHours"]),
                        AskResolved = askResolved.Kind == JsonKind.Bool && askResolved.AsBool(),
                        StarTags = Strings(content["starTags"]),
                    };
                    break;
            }

            notice.SessionId = Id(content["sessionId"]);
            notice.CustomerId = Id(content["customerId"]);
            notice.Skill = Text(content["skill"]);

            var agentId = Text(content["agentId"]);
            notice.AgentId = string.IsNullOrEmpty(agentId) ? null : agentId;

            return notice;
        }

        // An id: a string as it is, a number or a boolean as its literal (an older server's numeric
        // id), anything else as empty.
        private static string Id(JsonValue value)
        {
            return value.AsString(string.Empty);
        }

        // A string member: a JSON string or null. Stricter than AsString, which would turn 7 into "7".
        private static string Text(JsonValue value)
        {
            return value.Kind == JsonKind.String ? value.AsString() : null;
        }

        private static long Count(JsonValue value)
        {
            long count;
            return TryReadNumber(value, true, out count) ? count : 0;
        }

        // The strings of an array, skipping every entry that is not one. Never null.
        private static List<string> Strings(JsonValue value)
        {
            var result = new List<string>();
            foreach (var item in value.Items)
            {
                if (item.Kind == JsonKind.String)
                {
                    result.Add(item.AsString());
                }
            }

            return result;
        }

        // A JSON number, or a string holding one ("903", " 903 ", "9.03e2"), since the server is free
        // to write a 64-bit value quoted. With truncate a fraction is cut off; without, a value that
        // is not whole is refused. NaN, the infinities and anything outside a long are refused.
        // 服务端可以把 64 位数字写成字符串；码值必须是整数，计数的小数部分截掉。
        private static bool TryReadNumber(JsonValue value, bool truncate, out long result)
        {
            result = 0;
            double real;

            if (value.Kind == JsonKind.Number)
            {
                var integral = value.AsLong();
                real = value.AsDouble();
                if ((double)integral == real && real > -9.2233720368547758E18 && real < 9.2233720368547758E18)
                {
                    result = integral;
                    return true;
                }
            }
            else if (value.Kind == JsonKind.String)
            {
                var text = value.AsString();
                long parsed;
                if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                {
                    result = parsed;
                    return true;
                }

                if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out real))
                {
                    return false;
                }
            }
            else
            {
                return false;
            }

            if (double.IsNaN(real) || double.IsInfinity(real)
                || real <= -9.2233720368547758E18 || real >= 9.2233720368547758E18)
            {
                return false;
            }

            var whole = Math.Truncate(real);
            if (whole != real && !truncate)
            {
                return false;
            }

            result = (long)whole;
            return true;
        }
    }

    /// <summary>1801 — the customer is waiting.</summary>
    public sealed class ImDeskQueuedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Queued; }
        }
    }

    /// <summary>1802 — an agent has taken the session. <see cref="ImDeskNotification.AgentId"/> is who.</summary>
    public sealed class ImDeskAssignedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Assigned; }
        }
    }

    /// <summary>
    /// 1803 — handed to another agent. <see cref="ImDeskNotification.AgentId"/> is the new one,
    /// <see cref="FromAgentId"/> the old.
    /// </summary>
    /// <remarks>
    /// The handover note is deliberately <b>not</b> here: it is internal, and a customer reading
    /// "difficult, check the refund history first" in their own transcript is the failure this
    /// separation prevents.
    /// </remarks>
    public sealed class ImDeskTransferredNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Transferred; }
        }

        /// <summary>The agent who handed it on. Empty when the notice did not carry one.</summary>
        public string FromAgentId { get; internal set; }
    }

    /// <summary>1804 — closed.</summary>
    /// <remarks>
    /// <see cref="Resolution"/> is present only when a person closed it and typed one;
    /// <see cref="Reason"/> <c>"timeout"</c> (<see cref="ImDeskEndReason.Timeout"/>) marks the
    /// inactivity timer closing it instead. Both null means it was closed with nothing filled in.
    /// </remarks>
    public sealed class ImDeskClosedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Closed; }
        }

        /// <summary>What the closing person typed, or null.</summary>
        public string Resolution { get; internal set; }

        /// <summary><c>"timeout"</c> when the inactivity timer closed it, or another value a newer server writes, or null.</summary>
        public string Reason { get; internal set; }
    }

    /// <summary>
    /// 1805 — the agent became unreachable and the session went back to the <b>front</b> of the queue.
    /// </summary>
    /// <remarks>
    /// Its own code rather than a second 1801 so a game can say "we are finding someone else for
    /// you", which is a different sentence from "you are in the queue" — and the difference is the
    /// whole reason the customer is not left in silence.
    /// </remarks>
    public sealed class ImDeskRequeuedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Requeued; }
        }

        /// <summary>The agent who became unreachable. Empty when the notice did not carry one.</summary>
        public string PreviousAgentId { get; internal set; }
    }

    /// <summary>1806 — nobody could take it and the desk gave up.</summary>
    public sealed class ImDeskAbandonedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.Abandoned; }
        }

        /// <summary>How long the customer waited for that answer, in seconds.</summary>
        public long WaitedSeconds { get; internal set; }
    }

    /// <summary>
    /// 1807 — closed, and the customer is being asked to rate it. Answer with
    /// <see cref="ImDeskApi.RateAsync"/>.
    /// </summary>
    /// <remarks>
    /// At most once per session, and only when the deployment's rating window is open.
    /// <see cref="AskResolved"/> says whether to show the "was your problem solved" question — a
    /// survey that asks it when the server will not store the answer wastes the one question a
    /// customer will answer.
    /// </remarks>
    public sealed class ImDeskRatingRequestedNotification : ImDeskNotification
    {
        /// <inheritdoc/>
        public override int Code
        {
            get { return ImDeskNotificationCode.RatingRequested; }
        }

        /// <summary>How long the customer has to answer, in hours.</summary>
        public long WindowHours { get; internal set; }

        /// <summary>Whether to ask "was your problem solved".</summary>
        public bool AskResolved { get; internal set; }

        /// <summary>The tags to offer alongside the stars. Empty when the centre configured none; never null.</summary>
        public List<string> StarTags { get; internal set; }
    }

    // ---------------------------------------------------------------------- context keys

    /// <summary>
    /// The keys the customer-service product recognises inside <see cref="ImDeskRequest.Context"/>.
    /// </summary>
    /// <remarks>
    /// A convention over the context that already crosses every surface untouched, rather than four
    /// more request fields. The engine copies out what it recognises and <b>leaves everything else in
    /// the context</b> for the workbench to render, so a tenant's own keys travel without a schema
    /// change. The <c>desk.</c> prefix is the reserved namespace; <see cref="Origin"/> has none
    /// because it predates the product.
    /// 引擎只抄它认得的键，其余原样留在 context 里给工作台渲染——租户自己的键因此不需要改 schema 就能到达。
    /// </remarks>
    public static class ImDeskContextKeys
    {
        /// <summary>→ <see cref="ImDeskSession.Channel"/>.</summary>
        public const string Channel = "desk.channel";

        /// <summary>→ <see cref="ImDeskSession.VisitorId"/>.</summary>
        public const string VisitorId = "desk.visitorId";

        /// <summary>→ <see cref="ImDeskSession.DeskId"/>.</summary>
        public const string DeskId = "desk.deskId";

        /// <summary>→ <see cref="ImDeskSession.GroupId"/>. The engine still routes on <c>skill</c>.</summary>
        public const string GroupId = "desk.groupId";

        /// <summary><see cref="OriginBot"/> when a bot handed the customer over. No <c>desk.</c> prefix: it predates the product.</summary>
        public const string Origin = "origin";

        /// <summary>The value <see cref="Origin"/> takes for a bot handoff.</summary>
        public const string OriginBot = "bot";

        /// <summary>The page the visitor was on. Rendered by the workbench; nothing is copied out of it.</summary>
        public const string Page = "desk.page";

        /// <summary>What an anonymous visitor typed on the widget's first screen.</summary>
        public const string VisitorName = "desk.visitorName";

        /// <summary>What an anonymous visitor typed on the widget's first screen.</summary>
        public const string VisitorEmail = "desk.visitorEmail";
    }
}
