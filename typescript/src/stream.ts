/**
 * Streaming replies, the half that is not a request: reading `evt.stream`, putting the fragments back
 * together, and a small writer for the producer.
 *
 * Its own file for the reason `room.ts` and `desk.ts` are: the frames arrive **unsolicited**, so
 * nothing rejects when they are misread, and the rules that read them belong beside the shape. What
 * the server guarantees, and therefore what this file relies on:
 *
 * - **A stream is not a message until it completes.** Its `evt.stream` frames go to the members of
 *   the conversation who are online right now — the producer's own connection included — and are
 *   never stored: no seq, no resend, no catch-up, no `msg.sync`. They never touch a cursor or gap
 *   repair, and nothing here lets them.
 * - **Frames are numbered.** The opening frame is index 0 (no delta, maybe a `placeholder`), the
 *   fragments 1, 2, 3 … in the order the server accepted them, and the terminal frame one past the
 *   last fragment, `done: true`. A missing number is a fragment this client will never get:
 *   fragments travel at low priority and a congested connection sheds them, while the opening and
 *   terminal frames do not. A terminal frame can therefore **overtake** fragments still queued
 *   behind it, and a client that connected mid-stream sees fragments with no opening frame.
 * - **The terminal frame says how it ended.** With `messageId` (a quoted id) and `seq`, the stream
 *   completed into one ordinary message — **which arrives separately, on `evt.message`, through the
 *   normal cursor and gap-repair path**, and in either order relative to this frame. Without a
 *   `messageId` it ended with no message, and `abortReason` says why: the producer aborted, it went
 *   quiet for 30 seconds and was reaped, or the server refused the finished text.
 * - **Nothing is repaired.** On a hole, a late join or a reconnect, the stored message is the answer:
 *   it has the full text, and the client gets it like every other message.
 *
 * 流在收尾之前不是消息：evt.stream 帧只推给此刻在线的会话成员（含生产者自己的连接），不落库、
 * 没有 seq、不重发、不补拉，绝不碰游标与补洞。帧有编号：开流 0、分片 1、2、3……、终帧为最后一片加一。
 * 缺号就是永远收不到的分片（分片低优先级、拥塞时被丢弃，开流帧与终帧不会）；终帧可能越过排在它后面的分片。
 * 终帧带 messageId 与 seq 表示收尾成了一条普通消息——它另经 evt.message、走正常的游标与补洞，先后不定；
 * 不带 messageId 表示没有消息，abortReason 说明原因。一律不修复：缺片、中途加入、重连，都等那条存下来的消息。
 */

import type { MsgApi } from './api.js';
import type { ImRequestOptions } from './connection.js';
import type {
  BeginStreamRequest,
  CompleteStreamRequest,
  JsonObject,
  SendMessageResult,
  StreamHandle,
} from './models.js';
import { asId, asLong } from './protocol.js';

// ---------------------------------------------------------------------------- evt.stream

/** Which of the four frames an `evt.stream` push is, read from `done`, `index` and `messageId`. */
export const StreamPhase = {
  /** `done: false`, index 0: a stream opened. Draw the placeholder. */
  Begin: 'begin',
  /** `done: false`, index ≥ 1: the next fragment of text. */
  Delta: 'delta',
  /** `done: true` with a `messageId`: it became an ordinary message, which arrives on `onMessage`. */
  Completed: 'completed',
  /** `done: true`, no `messageId`: it ended without a message. `abortReason` says why. */
  Aborted: 'aborted',
} as const;
export type StreamPhase = (typeof StreamPhase)[keyof typeof StreamPhase];

/**
 * One `evt.stream` frame, decoded and classified.
 *
 * Flat with optional fields rather than a union on `phase`, for the reason `RoomEvent` is: anything a
 * newer server adds is copied through and still reaches the application. Each optional field names
 * the phase that carries it.
 * 扁平可选而不是按 phase 判别的联合：新版服务端加的字段原样透传。
 */
export interface StreamEvent {
  phase: StreamPhase;
  streamId: string;
  conversationId: string;
  /** The producer. Fragments of your own stream come back to you too. */
  senderId: string;
  /** 0 opens; fragments are 1, 2, 3 …; the terminal frame is one past the last fragment. */
  index: number;
  /** True on the terminal frame only. */
  done: boolean;
  /** `delta` only — the text to append. */
  delta?: string;
  /** `begin` only — what the producer asked to have drawn while it runs; absent when it sent none. */
  placeholder?: JsonObject;
  /** `completed` only — the stored message's id, a string like every message id. */
  messageId?: string;
  /** `completed` only — the stored message's seq in its conversation. */
  seq?: number;
  /** `aborted` only — why there is no message. */
  abortReason?: string;
  /** Anything else a newer server put in the frame. */
  [extra: string]: unknown;
}

/**
 * Decodes an `evt.stream` payload, or returns null for something that is not a stream frame — no
 * stream id, no conversation, an index that is not a whole number.
 *
 * Null rather than a throw: this runs in a listener with no caller to catch it.
 * 返回 null 而不是抛异常：它跑在没有调用方可以接住异常的监听器里。
 */
export function readStreamEvent(data: unknown): StreamEvent | null {
  if (!isObject(data)) return null;

  const streamId = data['streamId'];
  const conversationId = data['conversationId'];
  if (typeof streamId !== 'string' || streamId.length === 0) return null;
  if (typeof conversationId !== 'string' || conversationId.length === 0) return null;

  const index = asLong(data['index'], Number.NaN);
  if (!Number.isInteger(index) || index < 0) return null;

  const done = data['done'] === true;

  // The server writes the id quoted (WriteAsString); a bare number is decoded too, with the warning
  // asId gives for every numeric id. Null or absent is what makes a terminal frame an abort.
  // 服务端按字符串写 id；裸数字也照解（asId 会照例告警一次）。null 或缺席才使终帧成为中止。
  const rawMessageId = data['messageId'];
  const messageId = rawMessageId === null || rawMessageId === undefined ? '' : asId(rawMessageId);

  const phase: StreamPhase = done
    ? messageId.length > 0
      ? StreamPhase.Completed
      : StreamPhase.Aborted
    : index === 0
      ? StreamPhase.Begin
      : StreamPhase.Delta;

  const decoded: StreamEvent = {
    ...(data as JsonObject),
    phase,
    streamId,
    conversationId,
    senderId: typeof data['senderId'] === 'string' ? data['senderId'] : '',
    index,
    done,
  };

  // The phase-specific fields are set only on the phase that carries them, so a field's presence can
  // be trusted as much as `phase` can.
  // 各阶段专属字段只出现在它所属的阶段，字段在不在与 phase 一样可信。
  delete decoded.delta;
  delete decoded.placeholder;
  delete decoded.messageId;
  delete decoded.seq;
  delete decoded.abortReason;

  switch (phase) {
    case StreamPhase.Begin:
      if (isObject(data['placeholder'])) decoded.placeholder = data['placeholder'] as JsonObject;
      break;
    case StreamPhase.Delta:
      decoded.delta = typeof data['delta'] === 'string' ? data['delta'] : '';
      break;
    case StreamPhase.Completed: {
      decoded.messageId = messageId;
      const seq = asLong(data['seq'], Number.NaN);
      if (!Number.isNaN(seq)) decoded.seq = seq;
      break;
    }
    case StreamPhase.Aborted:
      if (typeof data['abortReason'] === 'string') decoded.abortReason = data['abortReason'];
      break;
  }

  return decoded;
}

// ---------------------------------------------------------------------------- assembly

/** Where an assembled stream stands. */
export const StreamStatus = {
  Streaming: 'streaming',
  Completed: 'completed',
  Aborted: 'aborted',
} as const;
export type StreamStatus = (typeof StreamStatus)[keyof typeof StreamStatus];

/**
 * A stream as far as this client has seen it. A snapshot: the assembler hands out a fresh object
 * every time, so holding one does not change under you.
 */
export interface AssembledStream {
  streamId: string;
  conversationId: string;
  senderId: string;
  status: StreamStatus;
  /** From the opening frame. Absent when the producer sent none, or this client missed that frame. */
  placeholder?: JsonObject;
  /**
   * The fragments held, joined in index order **up to the first one missing** — so it is always a
   * prefix of what the producer appended, never text with a hole in it. A fragment that arrives late
   * fills its place and the text grows past it.
   */
  text: string;
  /**
   * Whether every fragment so far is held: 1 … the highest index seen, or 1 … the last fragment once
   * the terminal frame has said how many there were. False after a dropped fragment or a late join;
   * true again if the missing one turns up after all.
   *
   * `completed` and `intact` together mean `text` is everything the producer appended — which is the
   * finished message's text **unless the producer completed with explicit content**, which replaces
   * it. Either way the stored message on `onMessage` is the authority; swap it in when it arrives.
   */
  intact: boolean;
  /** `completed` only — match it against `ImMessage.messageId` on `onMessage`. */
  messageId?: string;
  /** `completed` only. */
  seq?: number;
  /** `aborted` only. */
  abortReason?: string;
}

export interface StreamAssemblerOptions {
  /**
   * How many finished streams are remembered (default 256), so a fragment that arrives after its
   * terminal frame is recognised rather than opening a stream of its own. The oldest finished one is
   * forgotten first; open streams are never evicted — `forget` or `clear` those.
   */
  maxFinished?: number;
}

interface StreamState {
  streamId: string;
  conversationId: string;
  senderId: string;
  status: StreamStatus;
  placeholder?: JsonObject;
  fragments: Map<number, string>;
  highestIndex: number;
  /** The terminal frame's index; fragments run 1 … terminalIndex - 1. */
  terminalIndex?: number;
  messageId?: string;
  seq?: number;
  abortReason?: string;
}

/**
 * Puts `evt.stream` fragments back together, by index, exactly as the server numbers them.
 *
 * Feed it every {@link StreamEvent} from `im.onStreamEvent`; each `apply` returns where that stream
 * now stands. It holds to the server's rules and repairs nothing:
 *
 * - fragments are placed by `index`, so one that arrives out of order lands where it belongs and a
 *   repeated index is ignored (the first copy wins);
 * - the terminal frame fixes how many fragments there were; one that arrives after it still fills
 *   its place, and anything numbered at or past it is ignored;
 * - a gap or a late join leaves `intact` false and `text` stopped at the hole — the finished message
 *   on `onMessage`, not this text, is what to show once the stream ends;
 * - `aborted` means there is no message and never will be for this stream.
 *
 * It does not see `evt.message`, and does not need to: the finished message reaches `onMessage`
 * through the ordinary cursor path, and `messageId` on the completed stream is how to pair the two,
 * whichever came first.
 *
 * 按 index 拼回分片，规则与服务端一致、什么都不修：乱序的分片落在自己的位置，重复的 index 只认第一份；
 * 终帧定下分片总数，之后迟到的分片仍补位，编号不小于它的忽略；有洞或中途加入时 intact 为 false、
 * text 停在洞前——流结束后该显示的是 onMessage 上那条存下来的消息。aborted 表示这条流永远没有消息。
 */
export class StreamAssembler {
  private readonly states = new Map<string, StreamState>();
  /** Finished stream ids, oldest first. */
  private readonly finished = new Set<string>();
  private readonly maxFinished: number;

  constructor(options: StreamAssemblerOptions = {}) {
    this.maxFinished = Math.max(0, Math.floor(options.maxFinished ?? 256));
  }

  /** Applies one frame and returns the stream as it now stands. */
  apply(event: StreamEvent): AssembledStream {
    let state = this.states.get(event.streamId);
    if (!state) {
      // The first frame this client has seen of the stream — the opening one, or, after a late join,
      // whatever came first. Nothing is fetched to make up the difference.
      state = {
        streamId: event.streamId,
        conversationId: event.conversationId,
        senderId: event.senderId,
        status: StreamStatus.Streaming,
        fragments: new Map(),
        highestIndex: 0,
      };
      this.states.set(event.streamId, state);
    }

    switch (event.phase) {
      case StreamPhase.Begin:
        if (event.placeholder && !state.placeholder) state.placeholder = event.placeholder;
        break;

      case StreamPhase.Delta: {
        const beyondEnd = state.terminalIndex !== undefined && event.index >= state.terminalIndex;
        if (event.index >= 1 && !beyondEnd && !state.fragments.has(event.index)) {
          state.fragments.set(event.index, event.delta ?? '');
          state.highestIndex = Math.max(state.highestIndex, event.index);
        }
        break;
      }

      case StreamPhase.Completed:
      case StreamPhase.Aborted:
        // The first terminal frame decides. The server sends one per stream; a second is ignored
        // rather than allowed to turn a completed stream into an aborted one.
        // 以第一份终帧为准：服务端每条流只发一份，第二份不许把已完成改成已中止。
        if (state.status !== StreamStatus.Streaming) break;
        state.terminalIndex = event.index;
        for (const index of [...state.fragments.keys()]) {
          if (index >= event.index) state.fragments.delete(index);
        }
        if (event.phase === StreamPhase.Completed) {
          state.status = StreamStatus.Completed;
          state.messageId = event.messageId;
          if (event.seq !== undefined) state.seq = event.seq;
        } else {
          state.status = StreamStatus.Aborted;
          if (event.abortReason !== undefined) state.abortReason = event.abortReason;
        }
        this.retire(state.streamId);
        break;
    }

    return snapshot(state);
  }

  /** The stream as it stands, or undefined if it was never seen or has been forgotten. */
  get(streamId: string): AssembledStream | undefined {
    const state = this.states.get(streamId);
    return state ? snapshot(state) : undefined;
  }

  /**
   * The completed stream that became this message, if this client saw its terminal frame — how a
   * message arriving on `onMessage` finds the placeholder it replaces.
   */
  byMessageId(messageId: string): AssembledStream | undefined {
    for (const state of this.states.values()) {
      if (state.messageId === messageId) return snapshot(state);
    }
    return undefined;
  }

  /** Every stream remembered, open and finished. */
  streams(): AssembledStream[] {
    return [...this.states.values()].map(snapshot);
  }

  /** Drops one stream — typically once its placeholder has been replaced by the stored message. */
  forget(streamId: string): void {
    this.states.delete(streamId);
    this.finished.delete(streamId);
  }

  /**
   * Drops everything. Call it after a reconnect: a stream that was open when the connection dropped
   * will never send this client its terminal frame, and its finished message arrives through resume
   * and gap repair like any other.
   * 重连之后调用：断线时还开着的流不会再给本客户端发终帧，它的最终消息照常经恢复与补洞到达。
   */
  clear(): void {
    this.states.clear();
    this.finished.clear();
  }

  private retire(streamId: string): void {
    this.finished.delete(streamId);
    this.finished.add(streamId);
    while (this.finished.size > this.maxFinished) {
      const oldest = this.finished.values().next().value as string;
      this.finished.delete(oldest);
      this.states.delete(oldest);
    }
  }
}

function snapshot(state: StreamState): AssembledStream {
  // Joined from 1 up to the first index not held: a prefix of what the producer appended.
  // 从 1 拼到第一个缺失的编号为止：永远是生产者所追加内容的前缀。
  let text = '';
  let next = 1;
  while (state.fragments.has(next)) {
    text += state.fragments.get(next);
    next++;
  }

  const last = state.terminalIndex !== undefined ? state.terminalIndex - 1 : state.highestIndex;
  const result: AssembledStream = {
    streamId: state.streamId,
    conversationId: state.conversationId,
    senderId: state.senderId,
    status: state.status,
    text,
    intact: next > last,
  };
  if (state.placeholder) result.placeholder = state.placeholder;
  if (state.messageId !== undefined) result.messageId = state.messageId;
  if (state.seq !== undefined) result.seq = state.seq;
  if (state.abortReason !== undefined) result.abortReason = state.abortReason;
  return result;
}

// ---------------------------------------------------------------------------- the producer

/**
 * One open stream, from the producer's side: the three calls after `msg.streamBegin`, bound to its
 * stream id. A convenience over `im.msg.streamAppend` / `streamComplete` / `streamAbort`, which it
 * calls and nothing more — every refusal is theirs, unchanged.
 *
 * ```ts
 * const writer = await StreamWriter.begin(im.msg, { receiverId: 'bob', clientMsgId, placeholder: { name: 'Assistant' } });
 * for await (const token of generate()) await writer.append(token);
 * const stored = await writer.complete();          // or: await writer.abort('the model timed out')
 * ```
 *
 * 生产者一侧的一条流：把开流之后的三个调用绑在它的 streamId 上，只是转调，拒绝原样上抛。
 */
export class StreamWriter {
  /** Opens a stream with `msg.streamBegin` and returns a writer for it. */
  static async begin(
    msg: Pick<MsgApi, 'streamBegin' | 'streamAppend' | 'streamComplete' | 'streamAbort'>,
    request: BeginStreamRequest,
    options?: ImRequestOptions,
  ): Promise<StreamWriter> {
    return new StreamWriter(msg, await msg.streamBegin(request, options));
  }

  constructor(
    private readonly msg: Pick<MsgApi, 'streamAppend' | 'streamComplete' | 'streamAbort'>,
    /** What `msg.streamBegin` answered. */
    readonly handle: StreamHandle,
  ) {}

  get streamId(): string {
    return this.handle.streamId;
  }

  /** `msg.streamAppend` — the next fragment. */
  append(delta: string, options?: ImRequestOptions): Promise<void> {
    return this.msg.streamAppend({ streamId: this.handle.streamId, delta }, options);
  }

  /** `msg.streamComplete` — finish into one message; without `content`, the appended text. */
  complete(request: Omit<CompleteStreamRequest, 'streamId'> = {}, options?: ImRequestOptions): Promise<SendMessageResult> {
    return this.msg.streamComplete({ streamId: this.handle.streamId, ...request }, options);
  }

  /** `msg.streamAbort` — end with no message. */
  abort(reason?: string, options?: ImRequestOptions): Promise<void> {
    return this.msg.streamAbort(
      reason === undefined ? { streamId: this.handle.streamId } : { streamId: this.handle.streamId, reason },
      options,
    );
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
