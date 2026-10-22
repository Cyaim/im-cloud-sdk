/**
 * What a chat room pushes that is not a reply: its events on `evt.system`, and the test for telling
 * a room message apart on `evt.message`.
 *
 * Its own file for the reason `desk.ts` is: both arrive **unsolicited**, so nothing rejects when they
 * are misread, and the few lines that read them belong beside the shape. Two things make rooms worth
 * the care:
 *
 * - **A room message is a message with `seq: 0`.** Rooms trade persistence for scale — nothing is
 *   stored, nothing is delivered per user, and there is no range to ask for — so the number that
 *   drives ordering, dedupe and gap repair everywhere else is deliberately absent. `ImClient` hands a
 *   seq-0 message straight to `onMessage` and never lets it near a cursor; a room message that went
 *   through gap repair would either request a range that does not exist on every arrival or move a
 *   conversation's cursor and fabricate a gap for the next real message.
 * - **Room events share `evt.system` with other actions** (a device log request rides there too), so
 *   the reader below keeps only `room.*` and leaves everything else to whoever else is listening.
 *
 * The request and response types the seven verbs take stay in `models.ts` with every other payload;
 * `RoomApi` in `api.ts` is the surface that calls them.
 *
 * 聊天室消息就是 seq 为 0 的消息：不存储、不按人投递、没有可补拉的区间，所以 ImClient 把它直接交给
 * onMessage，绝不让它碰游标——走进补洞逻辑的聊天室消息要么每来一条就请求一个不存在的区间，
 * 要么挪动游标、给下一条真消息凭空造出一个洞。房间事件与别的动作共用 evt.system，所以这里只认 room.*。
 */

import type { ImMessage, JsonObject } from './models.js';
import { ConversationType, asLong } from './protocol.js';

// ---------------------------------------------------------------------------- evt.system room.*

/** The three room events the server sends today. */
export const RoomEventName = {
  /** A member, or the whole room, was muted or unmuted. Read {@link RoomEvent.untilMs} to tell which. */
  Muted: 'room.muted',
  /** A member was removed. Their sends now fail `1602 NotInRoom` until they join again. */
  Kicked: 'room.kicked',
  /** The tenant backend deleted the room. Every call on it now fails `1600 RoomNotFound`. */
  Destroyed: 'room.destroyed',
} as const;

/** One of the three, or a `room.*` name a newer server added — kept raw rather than dropped. */
export type RoomEventName = (typeof RoomEventName)[keyof typeof RoomEventName] | (string & {});

/**
 * A room event, flattened out of its `{ event, body }` envelope.
 *
 * **Flat and optional rather than a union keyed on `event`, for the reason `DeskSessionEvent` is:**
 * an event name this build has never heard of must still reach the application with whatever it
 * carried, and a union closed over today's three would have nowhere to put it. Each optional field
 * names the event that carries it; extras a newer server adds are copied through.
 *
 * It is broadcast to everyone in the room, the person it is about included — so a client that sees
 * `room.kicked` with its own user id is the one that was removed, and should stop offering to send.
 * 扁平可选而不是按 event 判别的联合：本构建不认识的事件名也要带着它的内容到达应用。
 * 事件广播给房间里的每个人，包括被处置的那个人——看到自己 userId 的 room.kicked，就是自己被踢了。
 */
export interface RoomEvent {
  event: RoomEventName;
  roomId: string;
  /** Who did it: the owner, an admin, or — when the tenant backend acted — whatever operator it named. */
  operatorId: string;
  /**
   * `room.muted` — the member muted or unmuted; **absent means the whole room**.
   * `room.kicked` — the member removed.
   */
  userId?: string;
  /**
   * `room.muted` only — unix ms the mute lasts until. **Absent, or already past, means this was an
   * unmute**: one server call does both, and this field is the only thing that says which.
   */
  untilMs?: number;
  /** Anything else a newer server put in the body. */
  [extra: string]: unknown;
}

/**
 * Decodes an `evt.system` payload into a room event, or returns null for anything that is not one —
 * a device log request, a frame from a newer server about something else, a malformed body.
 *
 * Null rather than a throw: this runs in a listener with no caller to catch, and `evt.system` is a
 * shared channel, so most frames on it are legitimately somebody else's.
 * 返回 null 而不是抛异常：evt.system 是共享通道，上面的大多数帧本来就是别人的。
 */
export function readRoomEvent(data: unknown): RoomEvent | null {
  if (!isObject(data)) return null;

  const event = data['event'];
  if (typeof event !== 'string' || !event.startsWith('room.')) return null;

  const body = isObject(data['body']) ? data['body'] : {};
  if (typeof body['roomId'] !== 'string' || body['roomId'].length === 0) return null;

  // Copied through rather than rebuilt field by field, so an extra the server adds tomorrow reaches
  // the application. The named fields are then set from the body with their kinds repaired.
  // 原样透传，服务端明天加的字段也能到达应用；具名字段再按类型修正一遍。
  const decoded: RoomEvent = {
    ...(body as JsonObject),
    event,
    roomId: body['roomId'],
    operatorId: typeof body['operatorId'] === 'string' ? body['operatorId'] : '',
  };

  delete decoded.userId;
  if (typeof body['userId'] === 'string' && body['userId'].length > 0) decoded.userId = body['userId'];

  // A 64-bit value may arrive quoted (CONTRACT §2), and `untilMs > Date.now()` on a string compares
  // as text. Null or absent stays absent: that absence is what says "unmute".
  // 64 位数值可能以字符串到达；null 或缺席保持缺席——正是这个缺席表示「解禁」。
  delete decoded.untilMs;
  if (body['untilMs'] !== null && body['untilMs'] !== undefined) {
    const untilMs = asLong(body['untilMs'], Number.NaN);
    if (!Number.isNaN(untilMs)) decoded.untilMs = untilMs;
  }

  return decoded;
}

/**
 * Whether a `room.muted` event leaves its target muted at `now` — false for an unmute.
 *
 * The server sends one event name for both directions, and the difference is entirely in
 * {@link RoomEvent.untilMs}: present and in the future is a mute, anything else lifted one. A client
 * that read the name alone would grey out the input box on every unmute.
 * 服务端两个方向用同一个事件名，区别全在 untilMs：只看事件名，每次解禁都会把输入框置灰。
 */
export function isRoomMuteActive(event: RoomEvent, now: number = Date.now()): boolean {
  return event.event === RoomEventName.Muted && event.untilMs !== undefined && event.untilMs > now;
}

// ---------------------------------------------------------------------------- evt.message

/** The prefix the server puts on a room's conversation id: room `lobby` is conversation `r_lobby`. */
export const ROOM_CONVERSATION_PREFIX = 'r_';

/**
 * The room a message was said in, or null when it is not a room message.
 *
 * Room messages arrive on `onMessage` with every other message — seq 0, never repaired, never
 * committed — and this is how a handler routes them to the room screen rather than a conversation
 * list. It checks the conversation type **and** the `r_` prefix together, because either alone is a
 * guess.
 * 聊天室消息与其他消息一起从 onMessage 到达；用它把消息分流到房间界面。类型与 r_ 前缀同时判断。
 */
export function roomIdOf(message: Pick<ImMessage, 'conversationId' | 'conversationType'> | null | undefined): string | null {
  if (!message || message.conversationType !== ConversationType.ChatRoom) return null;

  const conversationId = message.conversationId;
  if (typeof conversationId !== 'string' || !conversationId.startsWith(ROOM_CONVERSATION_PREFIX)) return null;

  const roomId = conversationId.slice(ROOM_CONVERSATION_PREFIX.length);
  return roomId.length > 0 ? roomId : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
