/**
 * The two desk payloads that are not a request or a response: the `evt.desk` frame, and the
 * 1801–1807 notice that rides inside an ordinary message.
 *
 * They live here rather than in `models.ts` for the reason `devicelogs.ts` and `cursors.ts` are
 * their own files: the shape alone is not enough to use either of them safely, and the few lines
 * that read them belong beside it. Both arrive **unsolicited** — nobody awaited them, so nothing
 * rejects when they are misread. A desk notice mistaken for a chat message is drawn as one; a
 * `change` value that falls off the end of a switch is a session that stops updating on one screen
 * while every other screen moves on. Neither failure produces an error anywhere.
 *
 * The request and response types the nine verbs take stay in `models.ts` with every other payload;
 * `DeskApi` in `api.ts` is the surface that calls them.
 *
 * 这里放的是「不是请求也不是响应」的两种客服载荷：evt.desk 帧，和藏在普通消息里的 1801–1807 通知。
 * 两者都是**没人在等**的：读错了不会有任何一处 reject——把客服通知画成聊天消息，
 * 或者让一个 change 从 switch 末尾掉下去，都是无声的。
 */

import type { DeskNote, DeskNoteAuthor, DeskSession, ImMessage, JsonObject } from './models.js';
import {
  DeskNotificationCode,
  MessageContentType,
  asId,
  asLong,
  type DeskChange,
  type DeskSessionChange,
} from './protocol.js';

// ---------------------------------------------------------------------------- evt.desk

/**
 * The customer's message, as a session-level frame carries it when `change` is `message`.
 *
 * Carried inline so a workbench can render the line without a `msg.history` round trip per
 * arrival — the difference between a busy agent's list updating instantly and updating a request
 * later. It is the message API's wire shape, not the domain object: **`messageId` is a string**,
 * because a snowflake near 2^58 does not survive a JavaScript number in either direction.
 */
export interface DeskEventMessage {
  messageId: string;
  seq: number;
  conversationId: string;
  senderId: string;
  contentType: MessageContentType;
  content: JsonObject;
  sendTime: number;
  extensions?: JsonObject | null;
}

/**
 * A session-level `evt.desk` frame: something happened to one session.
 *
 * **`session` is nullable and the null is not a decoding accident.** A supervisor forcing an agent
 * offline pushes `released` with no session at all — the workbench being told is the one losing the
 * session, and there is nothing left to describe. Every other change carries it.
 *
 * **The extras are flat and optional rather than a union keyed on `change`, because the wire is.**
 * The server builds one dictionary and merges the per-change extras into it, and one value —
 * `summary` — genuinely arrives in two shapes: the engine pushes it when the model rewrites the
 * handover summary (no note), and it is also the kind of a filed summary note. A union keyed on
 * `change` would have to lie about one of them. Each field below names the change that carries it;
 * everything else is absent.
 *
 * 附加字段是扁平可选的，因为线上就是扁平的：服务端把每种 change 的附加项合并进同一个字典。
 * 而且 summary 确实有两种形状——按 change 判别的联合必然要对其中一种说谎。
 */
export interface DeskSessionEvent {
  event: 'desk.session';
  /** One of the thirteen, or a value a newer server added. Narrow it before switching. */
  change: DeskChange;
  /** Null only on a forced `released`. */
  session: DeskSession | null;
  /** `message` only. */
  message?: DeskEventMessage | null;
  /** `released` (forced) — why the supervisor took them off. */
  reason?: string;
  /** `released` (forced) — always true when present; a voluntary release has no extras. */
  forced?: boolean;
  /** `note` and `whisper` — the two note kinds a person may write. Transfer and summary notes are filed by the system and never announced. */
  note?: DeskNote;
  /** `note` and `whisper`. */
  author?: DeskNoteAuthor;
  /** `overdue` — today always `first-response`. */
  kind?: string;
  /** `overdue` — unix ms the session was assigned, so a workbench can show how long it has been. */
  assignedAt?: number;
  /** `overdue` and `inactive` — the configured threshold in minutes, not the elapsed time. */
  minutes?: number;
  /** `inactive` — unix ms of the last thing either side said. */
  silentSince?: number;
  /** `inactive` — whether the holder had starred it, so a dimmed row keeps its star. */
  star?: boolean;
}

/**
 * An agent-level `evt.desk` frame: something happened to the *agent*, not to a session.
 *
 * Today there is exactly one, `takeover`: another tab of the same agent has claimed the workbench.
 * **The frame names the winner, so the loser is whoever's own connection id is not the one here** —
 * that tab stops heart-beating and says so, rather than two tabs fighting over one roster entry.
 * There is no `session` on this frame at all, which is why `event` and not `change` is the
 * discriminator.
 */
export interface DeskAgentEvent {
  event: 'desk.agent';
  change: 'takeover' | (string & {});
  /** The connection that won. Compare it with your own; if it is not yours, you lost. */
  connectionId: string;
  /** The console member behind the agent, for the message shown to the tab that lost. */
  memberId: string;
}

/** Everything that arrives on `evt.desk`. Split on `event` first — `session` does not exist on the agent frame. */
export type DeskEvent = DeskSessionEvent | DeskAgentEvent;

/**
 * Decodes an `evt.desk` payload, or returns null for anything that is not one.
 *
 * Null rather than a throw, and null rather than a half-built object: this runs in an event
 * listener with no caller to catch, and a frame from a server newer than this build is a thing to
 * ignore, not an exception to crash a workbench with.
 */
export function readDeskEvent(data: unknown): DeskEvent | null {
  if (!isObject(data)) return null;

  const event = data['event'];
  if (event === 'desk.agent') {
    return {
      event: 'desk.agent',
      change: typeof data['change'] === 'string' ? data['change'] : '',
      connectionId: typeof data['connectionId'] === 'string' ? data['connectionId'] : '',
      memberId: typeof data['memberId'] === 'string' ? data['memberId'] : '',
    };
  }

  if (event !== 'desk.session' || typeof data['change'] !== 'string') return null;

  // Copied through rather than rebuilt field by field: an extra the server adds tomorrow reaches
  // the application instead of being dropped by a decoder that knows only today's list.
  // 原样透传而不是逐字段重建：服务端明天新增的附加字段能到达应用，而不是被只认识今天这张表的解码器丢掉。
  return { ...(data as unknown as DeskSessionEvent), event: 'desk.session', change: data['change'] };
}

/**
 * Narrows a frame's `change` to the thirteen this build knows, or null for one it does not.
 *
 * This is the seam the exhaustiveness of a workbench's switch rests on: narrow once here, and the
 * compiler can then prove the switch is finished, because {@link DeskSessionChange} is closed.
 * The null branch is the price and it is the honest one — a value this build has never heard of
 * has no correct rendering, and guessing is how a screen shows the wrong thing confidently.
 */
export function knownDeskChange(change: DeskChange): DeskSessionChange | null {
  return KNOWN_CHANGES.has(change as DeskSessionChange) ? (change as DeskSessionChange) : null;
}

const KNOWN_CHANGES = new Set<string>([
  'assigned',
  'released',
  'closed',
  'summary',
  'message',
  'note',
  'tag',
  'snooze',
  'whisper',
  'typing',
  'inactive',
  'overdue',
  'takeover',
]);

// ---------------------------------------------------------------------------- 1801-1807

/** What every desk notice carries, whatever its code. */
export interface DeskNotificationBase {
  sessionId: string;
  customerId: string;
  /**
   * The skill it was queued on. **Always present as a key and may be null**, unlike `agentId`,
   * because the server writes it into a dictionary — where "omit nulls" does not reach — while
   * `agentId` is only written when there is one.
   */
  skill: string | null;
  /** Present once an agent is involved. */
  agentId?: string;
}

/** 1801 — the customer is waiting. */
export interface DeskQueuedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Queued;
}

/** 1802 — an agent has taken the session. `agentId` is who. */
export interface DeskAssignedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Assigned;
}

/**
 * 1803 — handed to another agent. `agentId` is the new one, `fromAgentId` the old.
 *
 * The handover note is deliberately **not** here: it is internal, and a customer reading "difficult,
 * check the refund history first" in their own transcript is the failure this separation prevents.
 */
export interface DeskTransferredNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Transferred;
  fromAgentId: string;
}

/**
 * 1804 — closed.
 *
 * `resolution` is present only when a person closed it and typed one; `reason: 'timeout'` marks the
 * inactivity timer closing it instead. Both absent means it was closed with nothing filled in.
 */
export interface DeskClosedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Closed;
  resolution?: string;
  reason?: 'timeout' | (string & {});
}

/**
 * 1805 — the agent became unreachable and the session went back to the **front** of the queue.
 *
 * Its own code rather than a second 1801 so a client can say "we are finding someone else for you",
 * which is a different sentence from "you are in the queue" — and the difference is the whole
 * reason the customer is not left in silence.
 */
export interface DeskRequeuedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Requeued;
  previousAgentId: string;
}

/** 1806 — nobody could take it and the desk gave up. `waitedSeconds` is how long they waited for that answer. */
export interface DeskAbandonedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.Abandoned;
  waitedSeconds: number;
}

/**
 * 1807 — closed, and the customer is being asked to rate it. Answer with `desk.rate`.
 *
 * At most once per session, and only when the deployment's rating window is open. `askResolved`
 * says whether to show the "was your problem solved" question — a survey that asks it when the
 * server will not store the answer wastes the one question a customer will answer.
 */
export interface DeskRatingRequestedNotification extends DeskNotificationBase {
  code: typeof DeskNotificationCode.RatingRequested;
  /** How long the customer has to answer. */
  windowHours: number;
  askResolved: boolean;
  /** The tags to offer alongside the stars. Empty when the centre configured none. */
  starTags: string[];
}

/** Every desk notice, discriminated by `code`. */
export type DeskNotification =
  | DeskQueuedNotification
  | DeskAssignedNotification
  | DeskTransferredNotification
  | DeskClosedNotification
  | DeskRequeuedNotification
  | DeskAbandonedNotification
  | DeskRatingRequestedNotification;

/**
 * Reads a desk notice out of a message, or returns null when the message is not one.
 *
 * **Desk events are messages, not a side channel**, which is what makes a transcript explain itself
 * six months later: "you are in the queue", "Alice is with you now", "closed" sit in history and in
 * incremental sync, in the right place relative to the conversation around them. The cost is that
 * an application's `onMessage` handler now sees frames it must not draw as chat, and this is the
 * test for them: call it first, render a notice when it answers, fall through to the normal path
 * when it does not.
 *
 * Two things it deliberately checks together. The content type must be `Notification` **and** the
 * code must be in 1801–1807, because the same seven numbers are account error codes elsewhere on
 * this platform — a bare `code` check would eventually draw "your account is locked" onto a support
 * transcript. And the numeric fields go through `asLong`, because the server is free to write a
 * 64-bit value as a JSON string and `waitedSeconds + 1` would otherwise concatenate.
 *
 * 客服事件本身就是消息，所以 onMessage 里会看到不能当聊天画的帧——这个函数就是那道判断。
 * 它同时查内容类型与码值：光查码值，迟早会把「账号已锁定」画进一段工单记录里。
 */
export function readDeskNotification(message: ImMessage | null | undefined): DeskNotification | null {
  if (!message || message.contentType !== MessageContentType.Notification) return null;

  const content = message.content;
  if (!isObject(content)) return null;

  const code = asLong(content['code'], -1);
  if (code < DeskNotificationCode.Queued || code > DeskNotificationCode.RatingRequested) return null;

  const base: DeskNotificationBase = {
    sessionId: asId(content['sessionId']),
    customerId: asId(content['customerId']),
    skill: typeof content['skill'] === 'string' ? content['skill'] : null,
  };

  if (typeof content['agentId'] === 'string' && content['agentId'].length > 0) {
    base.agentId = content['agentId'];
  }

  switch (code) {
    case DeskNotificationCode.Queued:
      return { ...base, code: DeskNotificationCode.Queued };

    case DeskNotificationCode.Assigned:
      return { ...base, code: DeskNotificationCode.Assigned };

    case DeskNotificationCode.Transferred:
      return {
        ...base,
        code: DeskNotificationCode.Transferred,
        fromAgentId: asId(content['fromAgentId']),
      };

    case DeskNotificationCode.Closed: {
      const closed: DeskClosedNotification = { ...base, code: DeskNotificationCode.Closed };
      if (typeof content['resolution'] === 'string') closed.resolution = content['resolution'];
      if (typeof content['reason'] === 'string') closed.reason = content['reason'];
      return closed;
    }

    case DeskNotificationCode.Requeued:
      return {
        ...base,
        code: DeskNotificationCode.Requeued,
        previousAgentId: asId(content['previousAgentId']),
      };

    case DeskNotificationCode.Abandoned:
      return {
        ...base,
        code: DeskNotificationCode.Abandoned,
        waitedSeconds: asLong(content['waitedSeconds']),
      };

    default:
      return {
        ...base,
        code: DeskNotificationCode.RatingRequested,
        windowHours: asLong(content['windowHours']),
        askResolved: content['askResolved'] === true,
        starTags: Array.isArray(content['starTags'])
          ? (content['starTags'] as unknown[]).filter((tag): tag is string => typeof tag === 'string')
          : [],
      };
  }
}

// ---------------------------------------------------------------------------- context keys

/**
 * The keys the customer-service product recognises inside {@link DeskRequest.context}.
 *
 * A convention over the context that already crosses every surface untouched, rather than four
 * more request fields. The engine copies out what it recognises and **leaves everything else in the
 * context** for the workbench to render, so a tenant's own keys travel without a schema change. The
 * `desk.` prefix is the reserved namespace; `origin` has none because it predates the product.
 *
 * 引擎只抄它认得的键，其余原样留在 context 里给工作台渲染——租户自己的键因此不需要改 schema 就能到达。
 */
export const DeskContextKeys = {
  /** → `session.channel`. */
  Channel: 'desk.channel',
  /** → `session.visitorId`. */
  VisitorId: 'desk.visitorId',
  /** → `session.deskId`. */
  DeskId: 'desk.deskId',
  /** → `session.groupId`. The engine still routes on `skill`. */
  GroupId: 'desk.groupId',
  /** `'bot'` when a bot handed the customer over. No `desk.` prefix: it predates the product. */
  Origin: 'origin',
  /** The value {@link DeskContextKeys.Origin} takes for a bot handoff. */
  OriginBot: 'bot',
  /** The page the visitor was on. Rendered by the workbench; nothing is copied out of it. */
  Page: 'desk.page',
  /** What an anonymous visitor typed on the widget's first screen. */
  VisitorName: 'desk.visitorName',
  /** What an anonymous visitor typed on the widget's first screen. */
  VisitorEmail: 'desk.visitorEmail',
} as const;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
