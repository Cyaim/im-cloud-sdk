/**
 * Wire protocol types. These mirror docs/SPEC-02-protocol.md and sdk/CONTRACT.md §2, and are the
 * only place the shape of a frame is described on the client side.
 *
 * Payload types — the things that travel inside `body.data` — live in `models.ts`. The split is
 * deliberate: this file changes when the transport changes, which is almost never; that one changes
 * every time a tier is typed.
 */

/** A request the client sends. `id` is mandatory: it is how a reply finds its caller. */
export interface ImRequest {
  id: string;
  target: string;
  body?: unknown;
}

/**
 * A frame the server sends. Replies and server-initiated pushes are structurally identical, which
 * is deliberate: one decoder handles both, and a push can be correlated exactly like a reply.
 */
export interface ImFrame<T = unknown> {
  id: string;
  target: string;
  /** Transport-level outcome: 0 routed, 1 endpoint threw, 2 endpoint not found. */
  status: number;
  msg?: string | null;
  requestTime?: number;
  completeTime?: number;
  body?: ImBody<T>;
}

/** Business-level result, nested inside the transport frame. */
export interface ImBody<T = unknown> {
  code: number;
  message?: string | null;
  traceId?: string | null;
  serverTime: number;
  data?: T;
}

/**
 * One page of a cursor-paged list.
 *
 * Returned whole rather than flattened to `items`, because `nextCursor` is the only correct way to
 * ask for the next page and an SDK that hides it forces the application into a wrong loop —
 * notably "stop when `items.length < limit`", which is wrong here: the server computes the cursor
 * on the raw page, before rows the caller may not see are filtered out, so a short page with
 * `hasMore: true` is normal. CONTRACT §4.4, §5.6.
 */
export interface PagedResult<T> {
  items: T[];
  /** Opaque; pass back verbatim. Null when exhausted. */
  nextCursor?: string | null;
  hasMore: boolean;
  /** Only when the store can answer it cheaply; absent otherwise. */
  total?: number | null;
}

/**
 * Business result codes, from `IM.Abstractions/Errors/ImErrorCode.cs`. These are published API and
 * are never renumbered, so branching on the number is safe — branching on the message is not.
 */
export const ImErrorCode = {
  Ok: 0,

  // 1000-1099 generic
  InternalError: 1000,
  InvalidArgument: 1001,
  NotFound: 1002,
  RateLimited: 1003,
  Timeout: 1004,
  ServiceUnavailable: 1005,
  Conflict: 1006,
  PayloadTooLarge: 1007,
  UnsupportedOperation: 1008,

  // 1100-1199 auth
  Unauthorized: 1100,
  TokenExpired: 1101,
  TokenInvalid: 1102,
  Forbidden: 1103,
  UserBanned: 1104,
  SignatureInvalid: 1105,
  ReplayDetected: 1106,
  KickedByOtherDevice: 1107,

  /**
   * The page's origin is not on the app's web allowlist. A tenant sets that list in the console; it does not vary by user, so retrying or re-authenticating will not help and the SDK must not.
   *
   * 页面来源不在该应用的 Web 安全域名表里。这张表由租户在控制台设置、与用户无关——重试或重新登录都没有用，SDK 也不该那么做。
   */
  OriginNotAllowed: 1109,

  // 1200-1299 tenant & quota
  AppNotFound: 1200,
  AppDisabled: 1201,
  QuotaExceeded: 1202,
  FeatureNotEnabled: 1203,
  PlanExpired: 1204,
  ConcurrencyLimitExceeded: 1205,

  // 1300-1399 user & relationship
  UserNotFound: 1300,
  UserAlreadyExists: 1301,
  NotFriend: 1302,
  BlockedByPeer: 1303,
  BlockedPeer: 1304,
  FriendRequestNotFound: 1305,
  FriendLimitExceeded: 1306,
  CannotAddSelf: 1307,

  // 1400-1499 message
  MessageNotFound: 1400,
  MessageTooLong: 1401,
  ModerationRejected: 1402,
  RecallWindowExpired: 1403,
  RecallForbidden: 1404,
  EditWindowExpired: 1405,
  DuplicateClientMessageId: 1406,
  ConversationNotFound: 1407,
  SenderMuted: 1408,
  UnsupportedContentType: 1409,
  ReceiptDisabled: 1410,

  // 1500-1599 group
  GroupNotFound: 1500,
  GroupDismissed: 1501,
  GroupFull: 1502,
  NotGroupMember: 1503,
  NoGroupPermission: 1504,
  GroupMuted: 1505,
  MemberMuted: 1506,
  AlreadyGroupMember: 1507,
  JoinNeedsApproval: 1508,
  JoinForbidden: 1509,
  InviteForbidden: 1510,
  CannotOperateOwner: 1511,
  ApplicationNotFound: 1512,

  // 1600-1699 chat room
  RoomNotFound: 1600,
  RoomFull: 1601,
  NotInRoom: 1602,
  RoomMuted: 1603,

  // 1700-1799 media & storage
  UploadFailed: 1700,
  FileTypeNotAllowed: 1701,
  FileTooLarge: 1702,
  StorageQuotaExceeded: 1703,

  /**
   * No delivery record matches. The row is kept seven days, or the notification did not come from this platform at all. `clicked` swallows it: a click count one short is not an application's problem, and there is nothing a user could do about it.
   *
   * 没有匹配的投递记录：记录只保留七天，或者这条通知根本不是本平台发的。
   * `clicked` 会吞掉它——点击数少一次不是应用要处理的问题，用户也无从处理。
   */
  PushDeliveryNotFound: 2401,

  // 2500-2599 customer-service desk (SPEC-06 §14.7)
  //
  // **None of these can come back from a `desk.*` socket call.** The nine socket verbs answer the
  // generic band — 1001 for a malformed body, 1002 for a session or a queue that is not there,
  // 1006 for a session in the wrong state, 1103 for the wrong caller, 1203 when the tenant has no
  // LLM or no rating survey, 1205 when the agent is already at the capacity they declared. This
  // band belongs to the surfaces around the socket: the console's `/console/v1`, the visitor
  // widget's `/widget/v1`, operations' `/admin/v1`. They are declared here because the same
  // package is what a widget bundles, and because a name is what makes a support ticket
  // searchable — an integrator reading `2508` off a network tab has nothing to grep.
  //
  // 这一段没有一个会从 desk.* 的套接字调用回来：九个动词答的是通用码段。
  // 它属于套接字周围的那些面（控制台 / 访客插件 / 运维），列在这里是因为插件打包的就是本包，
  // 而且一个只有数字没有名字的码，在工单里是搜不到的。

  /** No such customer-service centre in this organisation — the same answer as "it is not yours", deliberately. */
  DeskNotFound: 2500,

  /** The organisation already has as many centres as its stage allows (one, at P0). Buying capacity is the fix; retrying is not. */
  DeskLimitReached: 2501,

  /** Enabling this agent would exceed the seats the organisation has bought. Somebody has to be disabled, or seats added. */
  SeatExhausted: 2502,

  /**
   * The caller neither holds this session nor has `desk.supervise`, and tried to reply, note or close it. Not a token problem: a fresh login answers the same.
   *
   * 调用方既不是这条会话的持有者、也没有 desk.supervise，却要回复 / 备注 / 关闭。
   * 这不是令牌的问题——重新登录得到的是同一个答案。
   */
  NotSessionHolder: 2503,

  /**
   * No such skill group in this centre. Named `DeskGroupNotFound` rather than SPEC-06 §14.7's `GroupNotFound` because 1500 already carries that name here and two constants cannot share it; the number is what travels, and it is unchanged.
   *
   * SPEC-06 §14.7 里叫 GroupNotFound，这里叫 DeskGroupNotFound：1500 已经占用了那个名字。
   * 线上传的是号码，号码没变。
   */
  DeskGroupNotFound: 2504,

  /** The centre is in a read-only phase of its lifecycle: its data still reads, and every write is refused. */
  DeskReadonly: 2505,

  /** That application is already bound to another centre. One application, one centre. */
  BindingConflict: 2506,

  /** The visitor token's `userHash` did not verify, or it has expired. A new one has to be minted server-side; there is nothing the browser can do about it. */
  VisitorTokenInvalid: 2507,

  /** The request's `Origin` is not on the channel's allowlist. Like {@link ImErrorCode.OriginNotAllowed} a tenant setting rather than a user one, so retrying and re-authenticating both fail the same way. */
  WidgetOriginDenied: 2508,

  /** The agent's profile was disabled since they last signed in. Their workbench must send them away rather than retry. */
  AgentNotEnabled: 2509,

  /** The channel's reply window has closed (WeChat's 48 hours). A template message is the only way left to reach that customer. */
  ChannelWindowExhausted: 2510,

  /** The receiving agent declined a transfer that needed their confirmation. The session stays where it is. */
  TransferDeclined: 2511,
} as const;

/**
 * Codes worth retrying. Exactly four, and the list is the same in all five SDKs (CONTRACT §7.3) —
 * an SDK that classifies one differently teaches an integrator a rule that stops being true the
 * moment they add a second platform.
 */
const RETRYABLE = new Set<number>([
  ImErrorCode.InternalError,
  ImErrorCode.RateLimited,
  ImErrorCode.Timeout,
  ImErrorCode.ServiceUnavailable,
]);

/** Codes that mean "the token is the problem", not "the request was". */
const REQUIRES_REAUTH = new Set<number>([
  ImErrorCode.Unauthorized,
  ImErrorCode.TokenExpired,
  ImErrorCode.TokenInvalid,
]);

export function isRetryableCode(code: number): boolean {
  return RETRYABLE.has(code);
}

export function requiresReauthCode(code: number): boolean {
  return REQUIRES_REAUTH.has(code);
}

/** Server-initiated event names. */
export const PushTarget = {
  Message: 'evt.message',
  MessageUpdate: 'evt.messageUpdate',
  ConversationUpdate: 'evt.conversationUpdate',
  Read: 'evt.read',
  Typing: 'evt.typing',
  Presence: 'evt.presence',
  Friend: 'evt.friend',
  Group: 'evt.group',
  System: 'evt.system',
  Stream: 'evt.stream',
  Desk: 'evt.desk',
  Kick: 'conn.kick',
} as const;

export type PushTargetName = (typeof PushTarget)[keyof typeof PushTarget];

/**
 * Enums are **open** (CONTRACT §4.5): an unknown member keeps its raw value instead of being
 * coerced to a default or throwing. The server ships new content types and new platforms without
 * waiting for the app, and a client that turned `contentType: 13` into `Text` would render the
 * wrong thing rather than falling back to "something I do not know how to draw".
 *
 * `| (number & {})` is what makes that a type rather than a comment: the named members still
 * autocomplete, and any other number is still assignable.
 *
 * 枚举是开放的：未知值原样保留。服务端会在客户端更新之前上线新的内容类型，
 * 把未知值折叠成默认成员等于把"我不认识这条消息"变成"我认错了这条消息"。
 */
export const Platform = {
  Unknown: 0,
  iOS: 1,
  Android: 2,
  Windows: 3,
  macOS: 4,
  Web: 5,
  MiniProgram: 6,
  Linux: 7,
  /** Only ever seen on messages the tenant backend sent through the server API. */
  Server: 100,
} as const;
export type Platform = (typeof Platform)[keyof typeof Platform] | (number & {});

export const ConversationType = {
  Single: 1,
  Group: 2,
  ChatRoom: 3,
  System: 4,
  Assistant: 5,
} as const;
export type ConversationType = (typeof ConversationType)[keyof typeof ConversationType] | (number & {});

export const MessageContentType = {
  Text: 1,
  Image: 2,
  Voice: 3,
  Video: 4,
  File: 5,
  Location: 6,
  Card: 7,
  Merged: 8,
  Notification: 9,
  Tip: 10,
  Recall: 11,
  Stream: 12,
  Custom: 100,
} as const;
export type MessageContentType = (typeof MessageContentType)[keyof typeof MessageContentType] | (number & {});

export const MessageStatus = {
  Sending: 0,
  Sent: 1,
  Delivered: 2,
  Read: 3,
  Failed: 4,
} as const;
export type MessageStatus = (typeof MessageStatus)[keyof typeof MessageStatus] | (number & {});

export const MessagePriority = {
  Low: 0,
  Normal: 1,
  High: 2,
} as const;
export type MessagePriority = (typeof MessagePriority)[keyof typeof MessagePriority] | (number & {});

export const MuteMode = {
  Normal: 0,
  NoPush: 1,
  Silent: 2,
} as const;
export type MuteMode = (typeof MuteMode)[keyof typeof MuteMode] | (number & {});

export const MultiLoginPolicy = {
  AllowAll: 0,
  OnePerPlatform: 1,
  OneMobileOneDesktopOneWeb: 2,
  SingleDevice: 3,
} as const;
export type MultiLoginPolicy = (typeof MultiLoginPolicy)[keyof typeof MultiLoginPolicy] | (number & {});

export const GroupType = {
  Normal: 1,
  Super: 2,
  ChatRoom: 3,
} as const;
export type GroupType = (typeof GroupType)[keyof typeof GroupType] | (number & {});

export const GroupRole = {
  Member: 1,
  Admin: 2,
  Owner: 3,
} as const;
export type GroupRole = (typeof GroupRole)[keyof typeof GroupRole] | (number & {});

export const GroupJoinMode = {
  FreeAccess: 0,
  NeedApproval: 1,
  Forbidden: 2,
} as const;
export type GroupJoinMode = (typeof GroupJoinMode)[keyof typeof GroupJoinMode] | (number & {});

export const GroupInviteMode = {
  AllMembers: 0,
  AdminsOnly: 1,
  Forbidden: 2,
} as const;
export type GroupInviteMode = (typeof GroupInviteMode)[keyof typeof GroupInviteMode] | (number & {});

export const ApplicationStatus = {
  Pending: 0,
  Accepted: 1,
  Rejected: 2,
  Expired: 3,
} as const;
export type ApplicationStatus = (typeof ApplicationStatus)[keyof typeof ApplicationStatus] | (number & {});

// ---------------------------------------------------------------------------- desk (T4)
//
// Three enum styles meet in one feature and the difference is on the wire, not a matter of taste:
// `DeskSessionState` and `AgentStatus` are bare C# enums and travel as **numbers**, while
// `DeskEndReason` carries its own `JsonStringEnumConverter` and travels as a **string**. A
// `switch` written against the wrong one never matches and never throws — the branch is simply
// dead — so both spellings are declared here rather than left to a reader's assumption.
// 同一个功能里三种枚举风格并存，而区别在线路上：state / status 是数字，endReason 是字符串。
// 对错了的 switch 不会报错，只是永远不命中——所以两种拼法都写在这里。

/**
 * Where a desk session is. **`Bot` counts as open**: a customer is either with the bot or with
 * people, never both, so a workbench asking "does this customer already have a session" must treat
 * `Bot` exactly like `Queued` and `Assigned`. The queue sweeps read only `Queued`.
 *
 * `Bot` 算「进行中」：一个客户要么在机器人手里、要么在人手里。查「这位客户是不是已经有会话」时，
 * 它必须与 Queued / Assigned 同等对待。
 */
export const DeskSessionState = {
  Queued: 0,
  Assigned: 1,
  Closed: 2,
  Abandoned: 3,
  /** The AI bot is handling the customer and no human is involved yet. */
  Bot: 4,
} as const;
export type DeskSessionState = (typeof DeskSessionState)[keyof typeof DeskSessionState] | (number & {});

/**
 * An agent's declared availability, and — because `desk.status` is also the heartbeat — the proof
 * their workbench is still there. Sending it is what keeps them in the roster; a console that stops
 * calling is reclaimed and its sessions requeued.
 */
export const AgentStatus = {
  Offline: 0,
  Available: 1,
  Busy: 2,
  Away: 3,
} as const;
export type AgentStatus = (typeof AgentStatus)[keyof typeof AgentStatus] | (number & {});

/**
 * Why a session ended, written by the system and never chosen by an agent. **A string on the
 * wire**, unlike its two neighbours above — the server puts a `JsonStringEnumConverter` on this one
 * enum precisely so that a workbench and a report compare against `"bot-resolved"` rather than `1`.
 *
 * Null while the session is open, and null on every session closed before the field existed, so a
 * report renders "unknown" rather than folding those into `human`.
 * 线上是字符串而不是数字。会话开着时为 null，字段出现之前关闭的会话也是 null——报表要画「未知」，
 * 不能把它们并进「human」。
 */
export const DeskEndReason = {
  /** The bot answered and the customer left; nobody human was involved. */
  BotResolved: 'bot-resolved',
  /** The bot handed the customer to a human. The session that followed has its own reason. */
  BotHandoff: 'bot-handoff',
  /** An agent closed it. */
  Human: 'human',
  /** The customer left the queue before an agent took the session. */
  Abandoned: 'abandoned',
  /** The customer went silent after assignment and the inactivity timer closed it. */
  Timeout: 'timeout',
} as const;
export type DeskEndReason = (typeof DeskEndReason)[keyof typeof DeskEndReason] | (string & {});

/**
 * The `change` on an `evt.desk` frame: the thirteen values `DeskSessionChange.All` declares
 * server-side, in that order.
 *
 * **This union is deliberately closed, and it is the only closed one in the file.** Everything else
 * here is `| (string & {})` so that a value the server adds tomorrow survives the trip; here the
 * point is the opposite — a workbench must be able to write a `switch` the compiler proves it has
 * finished, because a change silently dropped is a session that stops updating on one screen while
 * every other screen moves on. The openness is not lost, it is moved one level out: the frame's own
 * field is {@link DeskChange}, which admits an unfamiliar string, so a decoder widens once at the
 * edge and switches exhaustively inside.
 *
 * 这个联合刻意是封闭的，也是本文件里唯一封闭的一个：工作台要能写一个编译器能证明写完了的 switch——
 * 被悄悄丢掉的 change，表现为「一块屏幕上的会话不再更新，而别的屏幕都在动」。
 * 开放性没有丢，只是挪到外面一层：帧上的字段是 DeskChange，它接受陌生字符串。
 */
export const DeskSessionChange = {
  /** An agent took the session. */
  Assigned: 'assigned',
  /** The holder let it go, or was forced off. On a forced release the frame carries **no session**. */
  Released: 'released',
  Closed: 'closed',
  /** The model rewrote the handover summary. */
  Summary: 'summary',
  /** The customer sent a message; the frame carries it, so a workbench renders without a history round trip. */
  Message: 'message',
  Note: 'note',
  Tag: 'tag',
  Snooze: 'snooze',
  /** A supervisor whispered to the holding agent. The customer never sees it. */
  Whisper: 'whisper',
  /**
   * Declared by the server and **never pushed by it today** — there is no push site for this value
   * anywhere in the server tree. It is listed because a value that arrives and is not in the union
   * is a dropped frame; it is not something to build a feature on receiving.
   * 服务端声明了它，但今天没有任何推送点。列在这里是因为「收到了却不在联合里」等于丢帧；别指望能收到。
   */
  Typing: 'typing',
  /** Both sides have been silent past the centre's timer. Pushed by the product's timer worker, never by the engine. */
  Inactive: 'inactive',
  /** The first reply is overdue: once per session, to the holder and to every supervisor of the centre. */
  Overdue: 'overdue',
  /** Another tab of the same agent took over the workbench. Carries the winning `connectionId` and no session. */
  Takeover: 'takeover',
} as const;
export type DeskSessionChange = (typeof DeskSessionChange)[keyof typeof DeskSessionChange];

/**
 * The thirteen in the order `DeskSessionChange.All` declares them, so a guard can compare one list
 * against the server's rather than thirteen members one at a time.
 */
export const DESK_SESSION_CHANGES: readonly DeskSessionChange[] = [
  DeskSessionChange.Assigned,
  DeskSessionChange.Released,
  DeskSessionChange.Closed,
  DeskSessionChange.Summary,
  DeskSessionChange.Message,
  DeskSessionChange.Note,
  DeskSessionChange.Tag,
  DeskSessionChange.Snooze,
  DeskSessionChange.Whisper,
  DeskSessionChange.Typing,
  DeskSessionChange.Inactive,
  DeskSessionChange.Overdue,
  DeskSessionChange.Takeover,
];

/** What a frame's `change` may actually hold: one of the thirteen, or a value a newer server added. */
export type DeskChange = DeskSessionChange | (string & {});

/**
 * How a closing agent classified the session (SPEC-06 §4.9). The reports group on these exact
 * strings, and the server refuses anything else with `1001` rather than storing it.
 */
export const DeskDisposition = {
  Resolved: 'resolved',
  Unresolved: 'unresolved',
  Invalid: 'invalid',
  /** Not a support case at all — a sales lead, handed on. */
  ToLead: 'to-lead',
} as const;
export type DeskDisposition = (typeof DeskDisposition)[keyof typeof DeskDisposition] | (string & {});

/** The three tiers of a canned reply: one agent's own, one skill group's, everybody's. */
export const DeskCannedReplyScope = {
  Personal: 'personal',
  Group: 'group',
  All: 'all',
} as const;
export type DeskCannedReplyScope =
  | (typeof DeskCannedReplyScope)[keyof typeof DeskCannedReplyScope]
  | (string & {});

/** Whether a knowledge-base article is live. Only a published article grounds the bot or the copilot. */
export const KbArticleState = {
  Draft: 'draft',
  Published: 'published',
} as const;
export type KbArticleState = (typeof KbArticleState)[keyof typeof KbArticleState] | (string & {});

/** What kind of internal note this is (SPEC-06 §4.5). Doubles as the `change` on the frame that announces it. */
export const DeskNoteKind = {
  /** An agent's own remark on the session. */
  Note: 'note',
  /** The handover text written at a transfer. Never enters the customer-visible 1803 line. */
  Transfer: 'transfer',
  /** The model-written summary. */
  Summary: 'summary',
  /** A supervisor's whisper to the holding agent. */
  Whisper: 'whisper',
} as const;
export type DeskNoteKind = (typeof DeskNoteKind)[keyof typeof DeskNoteKind] | (string & {});

/**
 * Notification codes carried **inside a message**, not business result codes.
 *
 * **The same seven numbers are account error codes elsewhere on this platform** — 1801 is
 * `AccountLocked` on the server's own `ImErrorCode`, 1804 is `PasswordTooWeak` — and the two never
 * meet, because these live in `message.content.code` and those live in `body.code`. They are two
 * tables and have to stay two tables: merged, a client renders "your account is locked" at the
 * moment a customer reaches the front of a support queue.
 *
 * 同样的七个数字在别处是账号面的错误码。两者从不出现在同一个位置——这些在 message.content.code 里，
 * 那些在 body.code 里。必须是两张表：合并的结果，是客户排到队首时界面告诉他「账号已锁定」。
 */
export const DeskNotificationCode = {
  /** The customer is waiting for an agent. */
  Queued: 1801,
  /** An agent has taken the session. */
  Assigned: 1802,
  /** Handed to another agent. The handover note is **not** in this line; it is internal. */
  Transferred: 1803,
  Closed: 1804,
  /** The agent became unreachable and the session went back to the **front** of the queue. Its own code rather than a second `Queued`, because "we are finding someone else for you" is a different sentence from "you are in the queue". */
  Requeued: 1805,
  /** Nobody could take the session and the desk gave up on it. */
  Abandoned: 1806,
  /** Closed, and the customer is being asked to rate it. At most once per session; answer it with `desk.rate`. */
  RatingRequested: 1807,
} as const;
export type DeskNotificationCode = (typeof DeskNotificationCode)[keyof typeof DeskNotificationCode];

/**
 * Coerces a wire number that may have arrived as a JSON string.
 *
 * `GatewayRegistration.CreateJsonOptions()` sets `NumberHandling.AllowReadingFromString`, and the
 * server's own writers are free to emit a 64-bit value as `"1234"`. `JSON.parse` hands that back as
 * a string, and TypeScript's structural typing will not notice — `seq` is declared `number` and is
 * a string at runtime. Comparisons still coerce, so the bug hides; `seq + 1` produces `"12341"`
 * and the next gap calculation asks for a range that does not exist.
 *
 * Every value this SDK does arithmetic on goes through here. CONTRACT §2.
 * 服务端允许把 64 位数字写成 JSON 字符串；比较运算会隐式转换所以看不出问题，
 * 直到 seq + 1 变成字符串拼接。所有参与运算的数值都从这里过一遍。
 */
/**
 * Normalises a message id to its wire form: a string.
 *
 * Ids are snowflakes around 2^58, far beyond the 2^53 a JavaScript number can hold exactly, so
 * they travel as strings and must stay strings inside this SDK. Two failure modes made that
 * necessary and they act in opposite directions: an id whose sequence bits are zero parses
 * exactly but is *printed* as a different integer on the way back out, and an id whose sequence
 * bits are not zero is rounded on the way in. Either way a number cannot be handed back to the
 * server.
 *
 * Receiving a number here therefore means the server is older than this SDK. Nothing can be
 * recovered at that point — `JSON.parse` has already run and whatever precision was going to be
 * lost is lost — so this converts on a best-effort basis and says so once, loudly, rather than
 * pretending the value is sound.
 * id 是约 2^58 的雪花，远超 JavaScript number 能精确表示的 2^53，因此在线路上是字符串，
 * 在本 SDK 内部也必须保持字符串。这里收到 number 只意味着服务端比本 SDK 旧；
 * 到这一步已经无可挽回（JSON.parse 早已跑完），所以尽力转换并**明确报告一次**，而不是假装它没问题。
 */
let warnedAboutNumericId = false;

export function asId(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '';

  if (typeof value === 'number' && !warnedAboutNumericId) {
    warnedAboutNumericId = true;
    // Once per process: a repeated warning in a message loop is noise nobody reads.
    // 每个进程只报一次：在消息循环里反复告警只会变成没人看的噪音。
    console.warn(
      '[im-sdk] the server sent a numeric message id. Ids must arrive as strings; a number has ' +
        'already lost precision by the time this SDK sees it, so calls that send this id back ' +
        'may fail. This means the server is older than this SDK.',
    );
  }

  return String(value);
}

export function asLong(value: unknown, fallback = 0): number {
  if (typeof value === 'number') return Number.isFinite(value) ? value : fallback;
  if (typeof value === 'string' && value.length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

/**
 * Thrown for any non-zero business code and for every transport failure, so callers `catch` once
 * instead of checking every result.
 *
 * `traceId` and `target` are not decoration: a bug report carrying both is a one-query
 * investigation on the server side, and a guess without them.
 */
export class ImError extends Error {
  /**
   * True for exactly the four codes in CONTRACT §7.3. The SDK never acts on it — it retries the
   * *connection* and its own gap repair, never a business call — because a silent re-send hides
   * rate limiting from the UI that has to explain it, and turns a visible failure into an
   * invisible delay. The application decides.
   */
  readonly isRetryable: boolean;

  /** 1100/1101/1102. A fresh token, not a fresh request, is what fixes these. */
  readonly requiresReauth: boolean;

  constructor(
    readonly code: number,
    message: string,
    readonly traceId?: string | null,
    readonly target?: string,
  ) {
    super(message);
    this.name = 'ImError';
    this.isRetryable = isRetryableCode(code);
    this.requiresReauth = requiresReauthCode(code);
  }
}

/**
 * The rejection for a cancelled call.
 *
 * Cancellation is not a server outcome, so it is deliberately **not** an `ImError` with an invented
 * code (CONTRACT §7.5). It is the platform's own cancellation type — `DOMException('AbortError')`
 * where one exists, which is what `AbortSignal.throwIfAborted()` and `fetch` both produce, so a
 * caller's existing `err.name === 'AbortError'` check keeps working.
 *
 * Note what cancelling does *not* do: it abandons the reply, it does not undo the server-side
 * effect. A cancelled `msg.send` may well have sent the message — reissue with the same
 * `clientMsgId` and the server returns the original result instead of a second message.
 */
export function abortError(message = 'the request was cancelled'): Error {
  if (typeof DOMException === 'function') {
    return new DOMException(message, 'AbortError');
  }
  const error = new Error(message);
  error.name = 'AbortError';
  return error;
}
