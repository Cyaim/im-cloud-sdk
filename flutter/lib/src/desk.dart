/// `desk.*` — the customer-service desk (T4): its requests, what it answers, its enumerations and
/// the `evt.desk` frame. [ImDeskApi] is the surface that sends them.
///
/// In a file of its own because the family is typed whole or not at all (`sdk/CONTRACT.md` §3), and
/// a reader looking for "what does the desk send and get back" should find one place.
///
/// **Three enum styles meet in this feature and the difference is on the wire.**
/// [ImDeskSessionState] and [ImAgentStatus] are bare C# enums and travel as **integers**;
/// [ImDeskEndReason] carries its own `JsonStringEnumConverter` server-side and travels as a
/// **string**, and so do [ImDeskDisposition], [ImDeskCannedReplyScope] and the `change` on an
/// `evt.desk` frame. A `switch` written against the wrong one never matches and never throws.
///
/// 同一个功能里三种枚举风格并存，区别在线路上：state / status 是整数，endReason、disposition、
/// scope 与 change 是字符串。
library;

import 'api.dart' show ImDeskApi;
import 'json.dart';
import 'requests.dart';

// ---------------------------------------------------------------------------- enumerations

/// Where a desk session is. **`bot` counts as open**: a customer is either with the bot or with
/// people, never both, so "does this customer already have a session" must treat [bot] exactly
/// like [queued] and [assigned].
extension type const ImDeskSessionState(int wireValue) {
  static const ImDeskSessionState queued = ImDeskSessionState(0);
  static const ImDeskSessionState assigned = ImDeskSessionState(1);
  static const ImDeskSessionState closed = ImDeskSessionState(2);
  static const ImDeskSessionState abandoned = ImDeskSessionState(3);

  /// The AI bot is handling the customer and no human is involved yet.
  static const ImDeskSessionState bot = ImDeskSessionState(4);

  static const List<ImDeskSessionState> values = <ImDeskSessionState>[
    queued,
    assigned,
    closed,
    abandoned,
    bot,
  ];

  static ImDeskSessionState fromWire(Object? value) => ImDeskSessionState(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'queued',
        1 => 'assigned',
        2 => 'closed',
        3 => 'abandoned',
        4 => 'bot',
        _ => 'deskSessionState($wireValue)',
      };
}

/// An agent's declared availability — and, because `desk.status` is also the heartbeat, the proof
/// their workbench is still there. **An integer on the wire**: the server refuses a name with
/// `1000` and a number outside 0–3 with `1001`.
extension type const ImAgentStatus(int wireValue) {
  static const ImAgentStatus offline = ImAgentStatus(0);
  static const ImAgentStatus available = ImAgentStatus(1);
  static const ImAgentStatus busy = ImAgentStatus(2);
  static const ImAgentStatus away = ImAgentStatus(3);

  static const List<ImAgentStatus> values = <ImAgentStatus>[offline, available, busy, away];

  static ImAgentStatus fromWire(Object? value) => ImAgentStatus(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'offline',
        1 => 'available',
        2 => 'busy',
        3 => 'away',
        _ => 'agentStatus($wireValue)',
      };
}

/// Why a session ended, written by the system and never chosen by an agent. **A string on the
/// wire**. Null while the session is open, and null on every session closed before the field
/// existed — render that as "unknown", not as [human].
abstract final class ImDeskEndReason {
  /// The bot answered and the customer left; nobody human was involved.
  static const String botResolved = 'bot-resolved';

  /// The bot handed the customer to a human. The session that followed has its own reason.
  static const String botHandoff = 'bot-handoff';

  /// An agent closed it.
  static const String human = 'human';

  /// The customer left the queue before an agent took the session.
  static const String abandoned = 'abandoned';

  /// The customer went silent after assignment and the inactivity timer closed it.
  static const String timeout = 'timeout';
}

/// How a closing agent classified the session. The server refuses anything else with `1001`.
abstract final class ImDeskDisposition {
  static const String resolved = 'resolved';
  static const String unresolved = 'unresolved';
  static const String invalid = 'invalid';

  /// Not a support case at all — a sales lead, handed on.
  static const String toLead = 'to-lead';
}

/// The three tiers of a canned reply: one agent's own, one skill group's, everybody's.
abstract final class ImDeskCannedReplyScope {
  static const String personal = 'personal';
  static const String group = 'group';
  static const String all = 'all';
}

/// The `change` on an `evt.desk` frame: the thirteen values the server's `DeskSessionChange.All`
/// declares, in that order. **Strings, and open**: a value a newer server adds arrives unchanged in
/// [ImDeskEvent.change], so a `switch` over these needs a default branch. [all] is asserted against
/// `endpoint-inventory.json`'s `deskChanges` (`sdk/CONTRACT.md` §4.5).
abstract final class ImDeskSessionChange {
  /// An agent took the session.
  static const String assigned = 'assigned';

  /// The holder let it go, or was forced off. On a forced release the frame carries **no session**.
  static const String released = 'released';
  static const String closed = 'closed';

  /// The model rewrote the handover summary.
  static const String summary = 'summary';

  /// The customer sent a message; the frame carries it in [ImDeskEvent.message].
  static const String message = 'message';
  static const String note = 'note';
  static const String tag = 'tag';
  static const String snooze = 'snooze';

  /// A supervisor whispered to the holding agent. The customer never sees it.
  static const String whisper = 'whisper';

  /// Declared by the server and **never pushed by it today**; listed so it is not a dropped frame.
  static const String typing = 'typing';

  /// Both sides have been silent past the centre's timer.
  static const String inactive = 'inactive';

  /// The first reply is overdue: once per session, to the holder and to every supervisor.
  static const String overdue = 'overdue';

  /// Another tab of the same agent took over the workbench. A `desk.agent` frame; no session.
  static const String takeover = 'takeover';

  /// The thirteen, in the server's declaration order.
  static const List<String> all = <String>[
    assigned,
    released,
    closed,
    summary,
    message,
    note,
    tag,
    snooze,
    whisper,
    typing,
    inactive,
    overdue,
    takeover,
  ];
}

// ---------------------------------------------------------------------------- requests

/// `desk.request`. A customer asking for a person. **Every field is optional** — `im.desk.request()`
/// is the plain "talk to a human" button.
///
/// Idempotent server-side: a customer who already has a session in flight — queued, assigned, or
/// still with the bot — gets that same session back rather than a second one.
///
/// 幂等由服务端保证：已有进行中会话的客户拿回的就是那一个。
class ImDeskRequest implements ImRequestBody {
  const ImDeskRequest({this.skill, this.priority, this.context});

  /// Routing hint the tenant queues on: product line, language, VIP tier.
  final String? skill;

  /// Higher goes first. Null is the server's default, 0.
  final int? priority;

  /// Opaque context the agent's workbench renders. The engine copies out the keys it recognises
  /// (`desk.channel`, `desk.visitorId`, …) and leaves everything else untouched.
  final Map<String, Object?>? context;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'skill': skill,
        'priority': priority,
        'context': context,
      });
}

/// `desk.accept`. **Leave [sessionId] null to take the next one waiting** — the normal case: agents
/// pull. An empty queue answers `1002`, not an empty success.
class ImDeskAcceptRequest implements ImRequestBody {
  const ImDeskAcceptRequest({this.sessionId});

  final String? sessionId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{'sessionId': sessionId});
}

/// `desk.transfer`. Hands a session on, carrying its whole history with it.
///
/// **Exactly one of three targets, and the type enforces it**: build one with
/// [ImDeskTransferRequest.agent], [ImDeskTransferRequest.skill] or [ImDeskTransferRequest.queue] —
/// there is no constructor that takes two. The server checks the same thing and answers `1001`.
///
/// 三个目标恰好一个，由类型保证：只有 agent / skill / queue 三个构造函数。
class ImDeskTransferRequest implements ImRequestBody {
  /// To a named agent, who must be available and under capacity.
  const ImDeskTransferRequest.agent({required this.sessionId, required String agentId, this.note})
      : toAgentId = agentId,
        toSkill = null,
        toQueue = null;

  /// To a skill queue; the session goes to the front of it with its original `queuedAt` stamp.
  const ImDeskTransferRequest.skill({required this.sessionId, required String skill, this.note})
      : toAgentId = null,
        toSkill = skill,
        toQueue = null;

  /// Back to its own queue, same stamp, same position — the 1805 requeue, chosen by a person.
  const ImDeskTransferRequest.queue({required this.sessionId, this.note})
      : toAgentId = null,
        toSkill = null,
        toQueue = true;

  final String sessionId;
  final String? toAgentId;
  final String? toSkill;

  /// Sent only as `true`; null means another target was named.
  final bool? toQueue;

  /// Handover note for the receiving agent. **Internal**: never part of the customer-visible 1803
  /// line.
  final String? note;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'sessionId': sessionId,
        'toAgentId': toAgentId,
        'toSkill': toSkill,
        'toQueue': toQueue,
        'note': note,
      });
}

/// `desk.close`. The end-of-session drawer; every field but the id is optional, and **an omitted
/// field is not the same as one set to a value**.
///
/// **[inviteRating] left null means `true`** — it is a C# property initialiser, not a nullable — so
/// the only way to close without asking for a rating is to pass `false` explicitly.
///
/// 省略 inviteRating 等于 true：只有显式传 false 才是「不邀评」。
class ImDeskCloseRequest implements ImRequestBody {
  const ImDeskCloseRequest({
    required this.sessionId,
    this.resolution,
    this.tags,
    this.disposition,
    this.summary,
    this.inviteRating,
  });

  final String sessionId;

  /// Free-text outcome, kept on the record.
  final String? resolution;

  /// At most 20, each at most 64 characters; over either and the whole call is `1001`.
  final List<String>? tags;

  /// One of [ImDeskDisposition].
  final String? disposition;

  /// The agent-edited summary, filed as a note. Never shown to the customer.
  final String? summary;

  /// Null invites (the server's default). Pass `false` to close quietly.
  final bool? inviteRating;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'sessionId': sessionId,
        'resolution': resolution,
        'tags': tags,
        'disposition': disposition,
        'summary': summary,
        'inviteRating': inviteRating,
      });
}

/// `desk.status`. Availability, and — by the same call — the heartbeat that proves this workbench is
/// still there. **Send it on a timer**, not only when the agent changes status.
class ImDeskStatusRequest implements ImRequestBody {
  const ImDeskStatusRequest({required this.status, this.maxConcurrent});

  /// Sent as its integer. Outside 0–3 is `1001`.
  final ImAgentStatus status;

  /// Sessions this agent will hold at once. Null keeps the deployment default.
  final int? maxConcurrent;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'status': status.wireValue,
        'maxConcurrent': maxConcurrent,
      });
}

/// `desk.rate`. The customer's answer to the rating survey, in reply to the 1807 notice.
///
/// Null is meaningful on all three optional members: [resolved] null means the survey did not ask,
/// which is not the same as `false`.
class ImDeskRateRequest implements ImRequestBody {
  const ImDeskRateRequest({
    required this.sessionId,
    required this.score,
    this.resolved,
    this.starTags,
    this.comment,
  });

  final String sessionId;

  /// 1–5. Anything else is `1001`.
  final int score;

  /// "Was your problem solved".
  final bool? resolved;

  /// At most 12, each at most 64 characters.
  final List<String>? starTags;

  /// At most 2000 characters.
  final String? comment;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'sessionId': sessionId,
        'score': score,
        'resolved': resolved,
        'starTags': starTags,
        'comment': comment,
      });
}

/// `desk.suggest`: the session this agent holds.
class ImDeskSuggestRequest implements ImRequestBody {
  const ImDeskSuggestRequest({required this.sessionId});

  final String sessionId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{'sessionId': sessionId});
}

/// `desk.canned`. All three are filters; leaving all three null lists the whole centre's
/// phrasebook, **including every member's `personal` entries**.
///
/// **[ownerMemberId] is a filter, not a permission: the server does not narrow it to the caller.**
/// Pass your own member id for "shared, plus mine".
class ImDeskCannedRequest implements ImRequestBody {
  const ImDeskCannedRequest({this.skill, this.scope, this.ownerMemberId});

  final String? skill;

  /// One of [ImDeskCannedReplyScope]. An unrecognised value is `1001`.
  final String? scope;
  final String? ownerMemberId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'skill': skill,
        'scope': scope,
        'ownerMemberId': ownerMemberId,
      });
}

// ---------------------------------------------------------------------------- responses

/// One "customer asked, agent answered" pair inside a session, unix ms on both sides.
class ImDeskResponseSample {
  const ImDeskResponseSample({this.customerAt = 0, this.agentAt = 0, this.agentId});

  factory ImDeskResponseSample.fromJson(Map<String, dynamic> json) => ImDeskResponseSample(
        customerAt: imIntOr(json['customerAt']),
        agentAt: imIntOr(json['agentAt']),
        agentId: imString(json['agentId']),
      );

  final int customerAt;
  final int agentAt;
  final String? agentId;
}

/// The model-written handover summary a receiving agent reads before saying hello.
class ImDeskSessionSummary {
  const ImDeskSessionSummary({
    this.issue = '',
    this.state = '',
    this.nextStep = '',
    this.generatedAt = 0,
    this.model = '',
  });

  factory ImDeskSessionSummary.fromJson(Map<String, dynamic> json) => ImDeskSessionSummary(
        issue: imStringOr(json['issue']),
        state: imStringOr(json['state']),
        nextStep: imStringOr(json['nextStep']),
        generatedAt: imIntOr(json['generatedAt']),
        model: imStringOr(json['model']),
      );

  final String issue;
  final String state;
  final String nextStep;
  final int generatedAt;

  /// Which provider and model wrote it.
  final String model;
}

/// One desk session, as `desk.request`, `desk.accept` and every session-level `evt.desk` frame
/// carry it.
///
/// The product's fields from [tags] on were added after the engine shipped, so a session opened
/// before they existed reads back as the defaults here: null, empty, or false.
class ImDeskSession {
  const ImDeskSession({
    required this.sessionId,
    this.appId = '',
    this.customerId = '',
    this.agentId,
    this.conversationId = '',
    this.state = ImDeskSessionState.queued,
    this.skill,
    this.priority = 0,
    this.queuedAt = 0,
    this.assignedAt,
    this.closedAt,
    this.resolution,
    this.context,
    this.history = const <String>[],
    this.firstAgentMessageAt,
    this.rating,
    this.ratingInvitedAt,
    this.ratingComment,
    this.ratedAt,
    this.summary,
    this.tags = const <String>[],
    this.channel,
    this.visitorId,
    this.deskId,
    this.groupId,
    this.disposition,
    this.endReason,
    this.ratingReason,
    this.ratingResolved,
    this.ratingTags = const <String>[],
    this.star = false,
    this.snoozedUntil,
    this.responseSamples = const <ImDeskResponseSample>[],
  });

  factory ImDeskSession.fromJson(Map<String, dynamic> json) => ImDeskSession(
        sessionId: imStringOr(json['sessionId']),
        appId: imStringOr(json['appId']),
        customerId: imStringOr(json['customerId']),
        agentId: imString(json['agentId']),
        conversationId: imStringOr(json['conversationId']),
        state: ImDeskSessionState.fromWire(json['state']),
        skill: imString(json['skill']),
        priority: imIntOr(json['priority']),
        queuedAt: imIntOr(json['queuedAt']),
        assignedAt: imInt(json['assignedAt']),
        closedAt: imInt(json['closedAt']),
        resolution: imString(json['resolution']),
        context: imMapOrNull(json['context']),
        history: imStringList(json['history']),
        firstAgentMessageAt: imInt(json['firstAgentMessageAt']),
        rating: imInt(json['rating']),
        ratingInvitedAt: imInt(json['ratingInvitedAt']),
        ratingComment: imString(json['ratingComment']),
        ratedAt: imInt(json['ratedAt']),
        summary: switch (imMapOrNull(json['summary'])) {
          final Map<String, dynamic> summary => ImDeskSessionSummary.fromJson(summary),
          null => null,
        },
        tags: imStringList(json['tags']),
        channel: imString(json['channel']),
        visitorId: imString(json['visitorId']),
        deskId: imString(json['deskId']),
        groupId: imString(json['groupId']),
        disposition: imString(json['disposition']),
        endReason: imString(json['endReason']),
        ratingReason: imString(json['ratingReason']),
        ratingResolved: json['ratingResolved'] == null ? null : imBool(json['ratingResolved']),
        ratingTags: imStringList(json['ratingTags']),
        star: imBool(json['star']),
        snoozedUntil: imInt(json['snoozedUntil']),
        responseSamples: imList(json['responseSamples'], ImDeskResponseSample.fromJson),
      );

  final String sessionId;
  final String appId;

  /// The IM user asking for help. A minted visitor's id is `v_…`.
  final String customerId;

  /// The agent holding it. Null while queued, and null again after a release.
  final String? agentId;

  /// The ordinary single chat between the customer and the desk account. Everything either side
  /// says is a normal message in it, sent with `msg.send`.
  final String conversationId;
  final ImDeskSessionState state;
  final String? skill;
  final int priority;

  /// Unix ms. Preserved across a requeue.
  final int queuedAt;
  final int? assignedAt;
  final int? closedAt;
  final String? resolution;
  final Map<String, dynamic>? context;

  /// Agents who held it before.
  final List<String> history;
  final int? firstAgentMessageAt;

  /// 1–5, null until (and unless) the customer rates.
  final int? rating;

  /// When the 1807 invitation went out — the CSAT participation denominator.
  final int? ratingInvitedAt;
  final String? ratingComment;
  final int? ratedAt;
  final ImDeskSessionSummary? summary;
  final List<String> tags;

  /// How the visitor arrived: `web`, `app`, `api`, and the WeChat kinds.
  final String? channel;
  final String? visitorId;
  final String? deskId;
  final String? groupId;

  /// One of [ImDeskDisposition].
  final String? disposition;

  /// One of [ImDeskEndReason] — a **string**. Null while open.
  final String? endReason;
  final String? ratingReason;

  /// Null until rated, and null when the survey did not ask.
  final bool? ratingResolved;
  final List<String> ratingTags;
  final bool star;
  final int? snoozedUntil;
  final List<ImDeskResponseSample> responseSamples;
}

/// The queue as a supervisor watches it (`desk.queue`).
class ImDeskQueueView {
  const ImDeskQueueView({
    this.waiting = 0,
    this.assigned = 0,
    this.availableAgents = 0,
    this.headWaitSeconds = 0,
    this.avgFirstResponseSeconds,
    this.waitingBySkill = const <String, int>{},
  });

  factory ImDeskQueueView.fromJson(Map<String, dynamic> json) => ImDeskQueueView(
        waiting: imIntOr(json['waiting']),
        assigned: imIntOr(json['assigned']),
        availableAgents: imIntOr(json['availableAgents']),
        headWaitSeconds: imIntOr(json['headWaitSeconds']),
        avgFirstResponseSeconds: imDouble(json['avgFirstResponseSeconds']),
        waitingBySkill: imIntMap(json['waitingBySkill']),
      );

  final int waiting;
  final int assigned;
  final int availableAgents;

  /// Seconds the head of the queue has been waiting.
  final int headWaitSeconds;

  /// Average seconds from entering the queue to the first agent message, over the last 24 hours.
  /// **Null means nothing measurable in the window** — draw "no data", never 0.
  final double? avgFirstResponseSeconds;
  final Map<String, int> waitingBySkill;
}

/// One canned reply, as `desk.canned` lists it.
class ImDeskCannedReply {
  const ImDeskCannedReply({
    required this.id,
    this.title = '',
    this.content = '',
    this.skill,
    this.scope = ImDeskCannedReplyScope.all,
    this.folder,
    this.ownerMemberId,
    this.updatedAt = 0,
  });

  factory ImDeskCannedReply.fromJson(Map<String, dynamic> json) => ImDeskCannedReply(
        id: imStringOr(json['id']),
        title: imStringOr(json['title']),
        content: imStringOr(json['content']),
        skill: imString(json['skill']),
        scope: imStringOr(json['scope'], ImDeskCannedReplyScope.all),
        folder: imString(json['folder']),
        ownerMemberId: imString(json['ownerMemberId']),
        updatedAt: imIntOr(json['updatedAt']),
      );

  final String id;
  final String title;
  final String content;

  /// Null means every agent sees it.
  final String? skill;

  /// One of [ImDeskCannedReplyScope]. An entry stored before the field existed reads back as `all`.
  final String scope;
  final String? folder;
  final String? ownerMemberId;
  final int updatedAt;
}

// ---------------------------------------------------------------------------- evt.desk

/// One `evt.desk` frame, as `ImClient.deskEvents` delivers it.
///
/// Two shapes share the target, told apart by [event]: **`desk.session`** — something happened to
/// one session ([change] is one of [ImDeskSessionChange]) — and **`desk.agent`** — something
/// happened to the agent, today only `takeover`, carrying [connectionId] and [memberId] and no
/// session.
///
/// **[session] is null on a forced `released`, and that is not a decoding accident**: the workbench
/// being told is the one losing the session. The per-change extras are flat and optional because
/// the wire is; the three structured ones ([message], [note], [author]) are kept as JSON maps.
///
/// 同一个 target 上有两种帧，用 event 区分。强制释放时 session 为 null，这不是解码事故。
class ImDeskEvent {
  const ImDeskEvent({
    required this.event,
    required this.change,
    this.session,
    this.message,
    this.reason,
    this.forced,
    this.note,
    this.author,
    this.kind,
    this.assignedAt,
    this.minutes,
    this.silentSince,
    this.star,
    this.connectionId,
    this.memberId,
  });

  /// [event] of a frame about one session.
  static const String sessionEvent = 'desk.session';

  /// [event] of a frame about the agent rather than a session.
  static const String agentEvent = 'desk.agent';

  /// Decodes an `evt.desk` payload, or returns null for anything that is not one — a frame from a
  /// server newer than this build is a thing to ignore, not an exception to crash a workbench with.
  static ImDeskEvent? tryParse(Object? data) {
    final Map<String, dynamic>? json = imMapOrNull(data);
    if (json == null) return null;

    final String? event = imString(json['event']);
    if (event != sessionEvent && event != agentEvent) return null;

    return ImDeskEvent(
      event: event!,
      change: imStringOr(json['change']),
      session: switch (imMapOrNull(json['session'])) {
        final Map<String, dynamic> session => ImDeskSession.fromJson(session),
        null => null,
      },
      message: imMapOrNull(json['message']),
      reason: imString(json['reason']),
      forced: json['forced'] == null ? null : imBool(json['forced']),
      note: imMapOrNull(json['note']),
      author: imMapOrNull(json['author']),
      kind: imString(json['kind']),
      assignedAt: imInt(json['assignedAt']),
      minutes: imInt(json['minutes']),
      silentSince: imInt(json['silentSince']),
      star: json['star'] == null ? null : imBool(json['star']),
      connectionId: imString(json['connectionId']),
      memberId: imString(json['memberId']),
    );
  }

  /// [sessionEvent] or [agentEvent].
  final String event;

  /// One of [ImDeskSessionChange], or a value a newer server added.
  final String change;

  /// Null on a forced `released` and on every `desk.agent` frame.
  final ImDeskSession? session;

  /// `message` — the customer's message, in the message API's wire shape (`messageId` a string).
  final Map<String, dynamic>? message;

  /// `released` (forced) — why the supervisor took them off.
  final String? reason;

  /// `released` (forced) — true when present.
  final bool? forced;

  /// `note` and `whisper` — the note itself.
  final Map<String, dynamic>? note;

  /// `note` and `whisper` — who wrote it (`memberId`, `name`, `avatar`).
  final Map<String, dynamic>? author;

  /// `overdue` — today always `first-response`.
  final String? kind;

  /// `overdue` — unix ms the session was assigned.
  final int? assignedAt;

  /// `overdue` and `inactive` — the configured threshold in minutes.
  final int? minutes;

  /// `inactive` — unix ms of the last thing either side said.
  final int? silentSince;

  /// `inactive` — whether the holder had starred it.
  final bool? star;

  /// `desk.agent` — the connection that won. Compare it with your own; if it is not yours, you
  /// lost.
  final String? connectionId;

  /// `desk.agent` — the console member behind the agent.
  final String? memberId;
}
