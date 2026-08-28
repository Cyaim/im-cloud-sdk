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
  Call: 'evt.call',
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
