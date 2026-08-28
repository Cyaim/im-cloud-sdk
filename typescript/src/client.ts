import {
  ConnApi,
  ConvApi,
  DiagApi,
  FriendApi,
  GroupApi,
  MediaApi,
  ModerationApi,
  MsgApi,
  PushApi,
  UserApi,
} from './api.js';
import {
  ImConnection,
  type ConnectionOptions,
  type ConnectionState,
  type ImRequestOptions,
} from './connection.js';
import { ImCursorScope, ImCursors, type ImCursorSnapshot, type ImCursorStore } from './cursors.js';
import { ImDeviceLogs } from './devicelogs.js';
import { ImLog, inMemoryLogStore, type ImLogStore } from './logs.js';
import type {
  ConversationView,
  ImMessage,
  SendMessageResult,
  SyncMessagesResult,
} from './models.js';
import {
  ImError,
  ImErrorCode,
  type ImFrame,
  type PagedResult,
  PushTarget,
  asId,
  asLong,
} from './protocol.js';

export interface ImClientOptions extends ConnectionOptions {
  /**
   * The signed-in user.
   *
   * Required because the cursor store is scoped `(endpoint host, appId, userId)`: without the user
   * id, account switching on a shared device hands one user the other's cursors, which is silent
   * cross-account data loss wearing the costume of a fast login (CONTRACT §5.3). The token already
   * names this user; the SDK does not parse tokens.
   */
  userId: string;

  /**
   * Where cursors live between runs. **Required, deliberately.**
   *
   * There is no implicit default. Defaulting to no persistence is what produced the cold-start
   * data-loss bug; defaulting to *some* persistence would mean guessing where an app may write, and
   * a wrong guess about that is worse than a compile error. `ImCursorStore.inMemory()` is the
   * explicit way to say "I accept re-downloading", and it says so in the console once.
   */
  cursorStore: ImCursorStore;

  /**
   * Largest gap the client repairs message-by-message. Beyond it the cursor still advances and
   * `conversationNeedsReload` fires, so the application reloads that conversation from history
   * instead — replaying fifty thousand messages to catch up helps nobody.
   *
   * Above 500 this does not buy a bigger `msg.sync` call, because 500 is the server's ceiling. It
   * buys more iterations of the repair loop, which is fine and intended.
   */
  maxAutoRepairSeq?: number;

  /** How long an ordinary commit may sit unwritten, in ms. Floor 0. Adoption ignores it. */
  cursorFlushIntervalMs?: number;

  /** Conversations per `conn.sync` page. The server clamps to 1…500; anything else becomes 200. */
  syncPageLimit?: number;

  /**
   * Where the SDK's own runtime log lives between runs. **Optional, and the default is honest.**
   *
   * Supplying one is what makes "pull a log from that handset" answer questions about anything
   * before the current process — a crash, a night the app was closed, the reconnect storm at 3am.
   * Supplying none keeps a bounded ring in memory, which answers "what is happening now" completely
   * and "what happened when it crashed" not at all; the console shows which of the two a support
   * engineer is looking at, because a three-minute log and a seven-day log are otherwise identical.
   *
   * The SDK does not pick a location for you — see `ADR-003`, and {@link ImCursorStore} for the
   * same rule applied to cursors. On Android that would be app-private storage, on iOS `Documents`
   * or `Library/Caches` (whose backup behaviour differs, and "do chat logs reach iCloud" is a
   * question you answer to a regulator), on the web IndexedDB you may be obliged to clear on logout
   * and cannot clear if you do not know it exists.
   *
   * SDK 不替你选写入位置：那个选择的后果由你承担。不提供也是一个完整的选择——
   * 内存环形缓冲只覆盖本次进程，而控制台会把这个区别显示出来。
   */
  logStore?: ImLogStore;
}

export type MessageListener = (message: ImMessage) => void;
export type EventListener<T = unknown> = (payload: T) => void;

/**
 * A conversation the SDK deliberately did not backfill: the span was wider than
 * `maxAutoRepairSeq`, the cursor has been moved to the far end, and the application should reload
 * this conversation from `msg.history`.
 *
 * Both halves of that are mandatory. Advancing the cursor without the event leaves a hole in the
 * UI that nothing will ever mention; raising the event without advancing makes every later message
 * look like a gap and re-request a range that has already been declined.
 */
export type ConversationReloadListener = (conversationId: string) => void;

/** Repair loops are bounded so a server bug cannot spin a client forever. */
const MAX_REPAIR_ITERATIONS = 64;

/** Same idea for the resume run: 200 conversations a page, so this is 20,000 conversations. */
const MAX_SYNC_PAGES = 100;

/** `MessageService.SyncAsync` clamps to this, so asking for more is asking for silence. */
const SERVER_SYNC_CEILING = 500;

/**
 * The client applications actually use.
 *
 * Beyond wrapping commands, this owns the two things every correct IM client must do and most
 * hand-rolled ones do not:
 *
 * 1. **Gap repair.** It notices when an arriving `seq` skips a number and pulls the missing range
 *    before delivering the message that revealed it, so the application never sees a conversation
 *    jump forward and then fill in behind it.
 * 2. **Cursors that survive the process.** `deliveredSeq` in memory, `committedSeq` in the store
 *    you supplied. The second is what makes a cold start ask for the messages that arrived while
 *    the app was closed instead of quietly adopting the server's position and losing them —
 *    see `cursors.ts` and CONTRACT §5.
 *
 * Delivery is therefore **at-least-once**. Reconnects, repairs and an uncommitted crash all
 * redeliver. **Be idempotent on `messageId`.**
 *
 * 除了包装命令，它做两件多数自研客户端没做的事：跳号补洞，以及跨进程存活的游标。
 * 投递语义是至少一次——重连、补洞、未提交就崩溃都会重复投递，应用必须按 messageId 幂等。
 */
export class ImClient {
  private readonly connection: ImConnection;
  private readonly cursors: ImCursors;

  private readonly messageListeners = new Set<MessageListener>();
  private readonly reloadListeners = new Set<ConversationReloadListener>();
  private readonly errorListeners = new Set<(error: ImError) => void>();

  /**
   * One promise chain per conversation.
   *
   * This is what makes "for a given conversation, messages reach the application in seq order and
   * never concurrently" true rather than aspirational: a live message that arrives during a repair
   * waits behind it instead of overtaking it, and two repairs for one conversation cannot run at
   * once. Different conversations still proceed in parallel.
   */
  private readonly chains = new Map<string, Promise<void>>();

  private readonly maxAutoRepair: number;
  private readonly syncPageLimit: number;

  private prepared: Promise<void> | null = null;
  private resumeGeneration = 0;
  private pushWarned = false;
  private suspendHooked = false;

  private readonly deviceLogs: ImDeviceLogs;

  readonly conn: ConnApi;
  readonly msg: MsgApi;
  readonly conv: ConvApi;
  readonly user: UserApi;
  readonly friend: FriendApi;
  readonly group: GroupApi;
  readonly media: MediaApi;
  readonly push: PushApi;
  readonly moderation: ModerationApi;
  readonly diag: DiagApi;

  /**
   * The SDK's own runtime log. Written by the SDK, read when the server asks for it.
   *
   * Exposed so an application can add its own lines — the ones that explain what the *user* was
   * doing when it went wrong, which the SDK cannot see and which are usually the half that makes a
   * log worth reading.
   * 公开出来是为了让应用写自己的行：SDK 看不见用户当时在做什么，而那往往是让日志值得读的那一半。
   */
  readonly log: ImLog;

  constructor(private readonly options: ImClientOptions) {
    this.connection = new ImConnection(options);
    this.maxAutoRepair = options.maxAutoRepairSeq ?? 500;
    this.syncPageLimit = options.syncPageLimit ?? 200;

    this.cursors = new ImCursors(options.cursorStore, {
      scope: ImCursorScope.of(options.endpoint, options.appId, options.userId),
      flushIntervalMs: options.cursorFlushIntervalMs,
      onError: (error) => this.raise(error),
    });

    const io = {
      request: <T>(target: string, body?: unknown, requestOptions?: ImRequestOptions) =>
        this.connection.request<T>(target, body, requestOptions),
    };

    this.conn = new ConnApi(io);
    this.msg = new MsgApi(io, (result) => this.rememberOwnSend(result), () => this.newClientMsgId());
    this.conv = new ConvApi(io);
    this.user = new UserApi(io);
    this.friend = new FriendApi(io);
    this.group = new GroupApi(io);
    this.media = new MediaApi(io);
    this.push = new PushApi(io, () => this.connection.currentState === 'open');
    this.moderation = new ModerationApi(io);
    this.diag = new DiagApi(io);

    // Defaulted rather than required, unlike the cursor store, and the asymmetry is deliberate:
    // losing cursors loses a user's messages, while losing logs loses a diagnostic. Requiring a
    // store here would make every integration answer a question about a feature most of them will
    // never use, and the honest default says out loud what it costs (ADR-003).
    // 与游标存储不同，这里有默认值，而这个不对称是刻意的：丢游标丢的是用户的消息，
    // 丢日志丢的是一次排障。在这里设成必填，等于让每一次接入回答一个多数人永远用不上的问题。
    this.log = new ImLog(options.logStore ?? inMemoryLogStore());
    this.deviceLogs = new ImDeviceLogs(
      {
        requests: () => this.diag.logRequests(),
        answer: (answer) => this.diag.logUploaded(answer),
      },
      this.log,
    );

    this.connection.on(PushTarget.Message, (frame) => this.handleMessage(frame));

    // A log request arrives inside evt.system rather than on a target of its own, so a client built
    // before this feature existed receives an action it does not recognise and ignores it. A new
    // target would instead be silently dropped by every existing build, and there would be no way
    // to tell that apart from a device that was offline (ADR-003).
    // 日志请求走 evt.system 里的一个 action 而不是新事件名：
    // 本功能出现之前构建的客户端会收到一个不认识的 action 并忽略它，那是正确行为。
    this.connection.on(PushTarget.System, (frame) => {
      void this.deviceLogs.onSystemEvent(frame.body?.data, options.deviceId);
    });

    this.connection.onState((state) => {
      // Every transition, into the log. "Was it even connected at the time" is the first question
      // asked about every report that starts with "the message never arrived", and it is the one
      // question a server-side log cannot answer: a socket this client never opened leaves no
      // trace on the other side.
      // 每一次状态迁移都记：以「消息没到」开头的每一份反馈，第一个问题都是「它当时连上了吗」——
      // 而这恰恰是服务端日志答不了的：一条这个客户端从未打开的连接，在那一侧不留痕迹。
      this.log.info(`connection ${state}`);

      if (state === 'open') {
        void this.onConnected();
      }
    });
  }

  get state(): ConnectionState {
    return this.connection.currentState;
  }

  onState(listener: (state: ConnectionState) => void): () => void {
    return this.connection.onState(listener);
  }

  /** Fires for every message, in seq order per conversation, gaps already repaired. */
  onMessage(listener: MessageListener): () => void {
    this.messageListeners.add(listener);
    return () => this.messageListeners.delete(listener);
  }

  /** Subscribes to any other server event by target name. */
  onEvent<T>(target: string, listener: EventListener<T>): () => void {
    return this.connection.on(target, (frame) => listener(frame.body?.data as T));
  }

  /** A conversation the SDK declined to backfill. Reload it from `msg.history`. */
  onConversationNeedsReload(listener: ConversationReloadListener): () => void {
    this.reloadListeners.add(listener);
    return () => this.reloadListeners.delete(listener);
  }

  /**
   * SDK-level failures that have no caller to reject: a cursor store that will not load or save, a
   * resume run that could not finish. These are surfaced rather than logged, because every one of
   * them changes what the application should do next.
   */
  onError(listener: (error: ImError) => void): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }

  // ------------------------------------------------------------------- lifecycle

  /** Idempotent. Loads the cursor store on the first call, before the socket is opened. */
  async connect(): Promise<void> {
    await this.prepare();
    this.installSuspendHooks();
    await this.connection.connect();
  }

  /**
   * Closes the socket. **Does not unregister the push token** — a dead socket is precisely the
   * state offline push exists to serve. Use {@link logout} when the user is actually leaving.
   */
  disconnect(): void {
    this.removeSuspendHooks();
    // Fire-and-forget, because `disconnect` is synchronous and always has been: a commit that is
    // still inside the debounce window must not die with the socket. Await `flushCursors()` first
    // if you need the write to have landed before you return.
    void this.cursors.flush();
    this.cursors.dispose();
    this.connection.close();
  }

  /**
   * The correct logout order: `push.unregister` on the live socket, **then** close it.
   *
   * After the socket closes the SDK has no authenticated channel and cannot remove the token at
   * all; the user then keeps getting notifications on a device they signed out of. If the
   * unregister fails — or the socket was already gone — only the tenant backend can clean it up,
   * with `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
   *
   * Cursors are flushed but not cleared: the cursor store and your message store have exactly one
   * lifetime, so clear both together or neither. Clearing messages while keeping cursors shows an
   * empty conversation that will never refill; the reverse costs a full re-download.
   */
  async logout(): Promise<void> {
    if (this.push.currentToken && this.connection.currentState === 'open') {
      try {
        await this.push.unregister();
      } catch (error) {
        this.raise(
          error instanceof ImError
            ? error
            : new ImError(ImErrorCode.InternalError, String(error), null, 'push.unregister'),
        );
      }
    }

    this.push.clearToken();
    await this.cursors.flush();
    this.disconnect();
  }

  // ---------------------------------------------------------------------- cursors

  /**
   * The application has durably stored everything up to `seq` in this conversation.
   *
   * Call it after your own write completes, not when the listener returns — a callback returning
   * means the message reached memory, which is exactly the state a crash loses. Monotonic: a lower
   * seq is ignored rather than an error, so re-deriving cursors from your own database on startup
   * is always safe.
   */
  commit(conversationId: string, seq: number): void {
    this.cursors.commit(conversationId, asLong(seq));
  }

  /** Highest seq handed to this process. Memory only; resets to `committedSeq` on every connect. */
  deliveredSeq(conversationId: string): number {
    return this.cursors.deliveredSeq(conversationId);
  }

  /** Highest seq the application has committed. This is what `convSeqs` reports. */
  committedSeq(conversationId: string): number {
    return this.cursors.committedSeq(conversationId);
  }

  /** What would be written to the store right now. A copy. */
  cursorSnapshot(): ImCursorSnapshot {
    return this.cursors.snapshot();
  }

  /**
   * How many conversations came back from the store.
   *
   * Zero after a clean load of an empty store is a fresh install; zero after a failed load is not,
   * and {@link cursorStoreFailed} is how to tell them apart. An application that persists messages
   * should check both on startup.
   */
  get restoredConversations(): number {
    return this.cursors.restoredConversations;
  }

  /** True when the store could not be read. The session then adopts nothing and persists nothing. */
  get cursorStoreFailed(): boolean {
    return this.cursors.loadFailed;
  }

  /**
   * True when the store held cursors belonging to a different `(host, appId, userId)` and the SDK
   * discarded them rather than replaying another account's position (CONTRACT §5.3).
   *
   * Worth surfacing: it means this account will re-download, and it means the store is shared
   * across logins when it should be keyed per account.
   */
  get cursorScopeRejected(): boolean {
    return this.cursors.foreignScopeRejected;
  }

  /** Writes pending commits now. The SDK does this before every `conn.sync` and on suspend. */
  flushCursors(): Promise<void> {
    return this.cursors.flush();
  }

  // ---------------------------------------------------------------- legacy aliases

  /**
   * @deprecated Use `im.msg.send(…)`. Kept because it is in every README and sample; removed in 2.0.
   */
  send(request: Parameters<MsgApi['send']>[0], options?: ImRequestOptions): Promise<SendMessageResult> {
    return this.msg.send(request, options);
  }

  /** @deprecated Use `im.msg.send({ …target, content: { text } })`. Removed in 2.0. */
  sendText(
    target: { receiverId?: string; groupId?: string; conversationId?: string },
    text: string,
  ): Promise<SendMessageResult> {
    return this.msg.send({ ...target, content: { text } });
  }

  /** @deprecated Use `im.msg.history(…)`. Removed in 2.0. */
  history(conversationId: string, beforeSeq?: number, limit = 20): Promise<PagedResult<ImMessage>> {
    return this.msg.history({ conversationId, beforeSeq, limit });
  }

  /** @deprecated Use `im.msg.recall(…)`. Removed in 2.0. */
  recall(conversationId: string, messageId: string, reason?: string): Promise<void> {
    return this.msg.recall({ conversationId, messageId, reason });
  }

  /** @deprecated Use `im.msg.react(…)`. Removed in 2.0. */
  react(conversationId: string, messageId: string, emoji: string, add = true): Promise<void> {
    return this.msg.react({ conversationId, messageId, emoji, add });
  }

  /** @deprecated Use `im.msg.typing(…)` — the endpoint is `msg.typing`. Removed in 2.0. */
  setTyping(conversationId: string, typing = true): Promise<void> {
    return this.msg.typing({ conversationId, typing });
  }

  /** @deprecated Use `im.conv.list(…)` — the endpoint is `conv.list`. Removed in 2.0. */
  conversations(updatedAfter = 0, cursor?: string, limit = 50): Promise<PagedResult<ConversationView>> {
    return this.conv.list({ updatedAfter, cursor, limit });
  }

  /** @deprecated Use `im.conv.read(…)` — the endpoint is `conv.read`. Removed in 2.0. */
  markRead(conversationId: string, readSeq: number): Promise<void> {
    return this.conv.read({ conversationId, readSeq });
  }

  /** @deprecated Use `im.conv.unreadTotal()` — the endpoint is `conv.unreadTotal`. Removed in 2.0. */
  totalUnread(): Promise<number> {
    return this.conv.unreadTotal();
  }

  /**
   * Escape hatch for any endpoint the typed surface does not cover yet — the difference between
   * "wait for the next SDK release" and "ship on Friday".
   *
   * It shares the typed methods' code path exactly, so timeouts, cancellation and error mapping
   * behave identically. It does **not** participate in cursor logic: `invoke('msg.sync', …)`
   * returns messages and moves nothing.
   *
   * ```ts
   * // group.setRole is T3 and not typed yet:
   * await im.invoke<void>('group.setRole', { groupId, userId, role: 2 });
   * ```
   */
  invoke<T>(target: string, body?: unknown, options?: ImRequestOptions): Promise<T> {
    return this.connection.request<T>(target, body, options);
  }

  // --------------------------------------------------------------------- internals

  /**
   * Read the store — once, before the first socket is opened.
   *
   * There is no "tell the store its scope" step any more, and its absence is the point. The store
   * interface is exactly `load()` / `save()` (CONTRACT §5.3); the account identity travels inside
   * the snapshot, stamped by {@link ImCursors}, so the guarantee holds for a store that never
   * heard of scoping.
   */
  private prepare(): Promise<void> {
    this.prepared ??= this.cursors.load();
    return this.prepared;
  }

  private async onConnected(): Promise<void> {
    // Both, concurrently, and neither gates the other.
    //
    // Push registration runs unconditionally on *every* connect: the vendor may have replaced the
    // token while this process was frozen, and the server has no other way to learn that.
    // Re-registering an unchanged token costs no write server-side, so "every connect" is cheaper
    // than it looks (CONTRACT §6.2). But it must not run *before* the resume — a slow or
    // unanswered `push.register` would then delay gap repair by a whole request timeout, which
    // trades a notification problem for a missing-messages problem.
    this.log.info(`connected as ${this.options.userId} on ${this.options.deviceId}`);

    // Three, concurrently, and none gates the others. The log check is last in the list and least
    // urgent of the three: it must never delay gap repair, and its failure is logged rather than
    // raised — a device that cannot answer a log request is still a device that can chat.
    // 三件并发，互不阻塞：日志检查最不紧急，绝不能拖慢补洞，失败只记录不抛出——
    // 一台答不出日志请求的设备，仍然是一台能聊天的设备。
    await Promise.all([this.registerPushOnConnect(), this.resume(), this.deviceLogs.check()]);
  }

  private async registerPushOnConnect(): Promise<void> {
    if (await this.push.registerOnConnect()) return;
    if (this.pushWarned) return;

    this.pushWarned = true;
    this.log.warn('push token held but never registered; offline push will not reach this device');
    console.warn(
      '[im] a push token is held but has never registered successfully. Offline push will not ' +
        'reach this device, and a silently unregistered device looks exactly like a broken push ' +
        'provider. See sdk/CONTRACT.md §6.2.',
    );
  }

  private handleMessage(frame: ImFrame): void {
    const raw = frame.body?.data as ImMessage | undefined;
    if (!raw) return;

    const message = this.normalize(raw);

    // seq 0 means the message was never persisted — typing, presence, chat-room traffic. It
    // bypasses the cursor machinery entirely: it has no position, so it cannot be a duplicate, it
    // cannot reveal a gap, and letting one move a cursor would fabricate a gap for the next real
    // message.
    if (message.seq === 0) {
      this.emit(message);
      return;
    }

    void this.enqueue(message.conversationId, () => this.deliverLive(message));
  }

  /** The live path. Shares its repair with the resume path — see {@link repairRange}. */
  private async deliverLive(message: ImMessage): Promise<void> {
    const conversationId = message.conversationId;
    const delivered = this.cursors.deliveredSeq(conversationId);

    if (message.seq <= delivered) {
      // Already seen. Reconnect replay makes this routine and it must be silent.
      return;
    }

    if (delivered > 0 && message.seq > delivered + 1) {
      await this.repairRange(conversationId, delivered + 1, message.seq - 1);

      // The repair may have skipped past this message (an oversized gap moves the cursor to the far
      // end), in which case it is now a duplicate.
      if (message.seq <= this.cursors.deliveredSeq(conversationId)) return;
    }

    this.cursors.markDelivered(conversationId, message.seq);
    this.emit(message);
  }

  /**
   * Pulls `[fromSeq, toSeq]` and delivers it through the normal path, so gap detection, dedupe and
   * commit all behave identically to a live message.
   *
   * **One implementation, two callers** — the live path and the resume run. They were separate
   * before, which is how the live path came to accept an oversized jump silently while the resume
   * path did not: a hole nobody is told about is the same defect as a hole nobody repairs.
   */
  private async repairRange(conversationId: string, fromSeq: number, toSeq: number): Promise<void> {
    const span = toSeq - fromSeq + 1;
    if (span <= 0) return;

    if (span > this.maxAutoRepair) {
      this.skipAndReload(conversationId, toSeq);
      return;
    }

    let cursor = fromSeq;

    for (let iteration = 0; cursor <= toSeq; iteration++) {
      if (iteration >= MAX_REPAIR_ITERATIONS) {
        // A server that never says `hasMore: false` must not spin a client forever. Falling through
        // to the oversized behaviour keeps the cursor honest and tells the application to reload.
        this.skipAndReload(conversationId, toSeq);
        return;
      }

      let page: SyncMessagesResult;
      try {
        page = await this.msg.sync({
          conversationId,
          fromSeq: cursor,
          toSeq,
          // The server clamps to 500 whatever we ask, so asking for more is asking for silence.
          limit: Math.min(toSeq - cursor + 1, SERVER_SYNC_CEILING),
          ascending: true,
        });
      } catch {
        // Leave the gap rather than stalling the conversation. `committedSeq` has not moved, so the
        // next `conn.sync` reports the same gap and the repair is retried from a clean state — that
        // safety net is the reason the two cursors are separate.
        return;
      }

      let highest = 0;
      for (const candidate of page.messages ?? []) {
        const repaired = this.normalize(candidate);
        if (repaired.seq > highest) highest = repaired.seq;
        if (repaired.seq > this.cursors.deliveredSeq(conversationId)) {
          this.cursors.markDelivered(conversationId, repaired.seq);
          this.emit(repaired);
        }
      }

      // `hasMore` is computed on the raw window before per-user hidden messages are filtered out,
      // so `messages` can be shorter than `limit` — even empty — while the range is not finished.
      // Loop on `hasMore`, never on `messages.length` (CONTRACT §5.9).
      if (!page.hasMore) return;

      const next = (highest > 0 ? highest : asLong(page.maxSeq)) + 1;
      if (next <= cursor) {
        // No forward progress: `hasMore` is true but the page told us nothing new. Same treatment
        // as the iteration cap.
        this.skipAndReload(conversationId, toSeq);
        return;
      }

      cursor = next;
    }
  }

  /**
   * Too far behind to backfill. Move both cursors to the far end, commit, and say so.
   *
   * Both halves are mandatory; see {@link ConversationReloadListener}.
   */
  private skipAndReload(conversationId: string, toSeq: number): void {
    this.cursors.skipTo(conversationId, toSeq);

    for (const listener of this.reloadListeners) {
      try {
        listener(conversationId);
      } catch {
        /* a throwing listener must not stop the others */
      }
    }
  }

  /**
   * Runs after every connect and reconnect: asks the server what changed while we were away and
   * repairs each conversation whose seq has moved past ours.
   *
   * Three things here are easy to get wrong and each is its own silent loss:
   *
   * - **The reset.** `deliveredSeq := committedSeq` first, or the redelivery we are about to ask
   *   for is dropped as duplicate by the very cursor that was too far ahead.
   * - **Paging.** `conn.sync` returns at most 200 conversations per page. Stopping after one page
   *   means a user with more than 200 gets gaps reported only for the first of them.
   * - **When `conversationCursor` moves.** The list is sorted by `updatedAt` **descending**, so
   *   page 1 holds the newest timestamp. Taking the maximum from page 1 and stopping pushes the
   *   cursor past every conversation on pages 2…N, and the server filters `UpdatedAt >
   *   updatedAfter` — it will never return them again. So it moves only when a run completes.
   *   Re-reading a page is free; skipping one is permanent.
   */
  private async resume(): Promise<void> {
    // A failed store load is not a fresh install. Adopting here would destroy history sitting
    // intact in the application's own database, so the session does nothing to any cursor and the
    // application decides how to recover (CONTRACT §5.8).
    if (this.cursors.loadFailed) return;

    const generation = ++this.resumeGeneration;

    this.cursors.resetDeliveredToCommitted();
    // The flush before `conn.sync` is one of the three points a debounced write may not be late for.
    await this.cursors.flush();

    let cursor: string | null | undefined;
    let maxUpdatedAt = 0;
    let completed = false;

    try {
      for (let page = 0; page < MAX_SYNC_PAGES; page++) {
        const snapshot = this.cursors.snapshot();
        const result = await this.conn.sync({
          convSeqs: snapshot.convSeqs,
          conversationCursor: snapshot.conversationCursor,
          cursor,
          limit: this.syncPageLimit,
        });

        // A reconnect that started a newer run while this one was in flight wins; this one must not
        // report a `conversationCursor` derived from a page the newer run has already passed.
        if (generation !== this.resumeGeneration) return;

        const maxSeqs = new Map<string, number>();
        const adoptions: Promise<void>[] = [];

        for (const conversation of result.conversations ?? []) {
          const maxSeq = asLong(conversation.maxSeq);
          maxSeqs.set(conversation.conversationId, maxSeq);
          maxUpdatedAt = Math.max(maxUpdatedAt, asLong(conversation.updatedAt));

          // First sight: adopt rather than replaying a whole history into a UI that has never
          // shown it. Adoption is a commit, and its write is flushed before the next page is
          // requested — a lost adoption write recreates the original bug on the next cold start.
          if (!this.cursors.knows(conversation.conversationId)) {
            adoptions.push(this.cursors.adopt(conversation.conversationId, maxSeq));
          }
        }

        await Promise.all(adoptions);

        // The server already worked out which conversations we are behind on, so a cold device does
        // not have to diff the whole list itself.
        for (const [conversationId, from] of Object.entries(result.gapsFrom ?? {})) {
          const toSeq = maxSeqs.get(conversationId) ?? 0;
          await this.enqueue(conversationId, () => this.repairRange(conversationId, asLong(from), toSeq));
        }

        if (!result.hasMore) {
          completed = true;
          break;
        }

        if (!result.nextCursor) {
          // `hasMore` with nothing to page on. Treat the run as interrupted rather than complete:
          // advancing the cursor here would skip whatever is on the pages we cannot ask for.
          this.raise(
            new ImError(
              ImErrorCode.InternalError,
              'conn.sync reported hasMore with no nextCursor; leaving conversationCursor untouched',
              null,
              'conn.sync',
            ),
          );
          break;
        }

        cursor = result.nextCursor;
      }
    } catch (error) {
      // Resume is best-effort on the wire, but never on the cursor: an interrupted run leaves
      // `conversationCursor` exactly where it was, so the next attempt re-reads the same pages.
      //
      // A run cut short by the socket going away is not worth reporting — it is the ordinary shape
      // of a reconnect and of a clean shutdown, and the run that follows the reconnect repeats it.
      // A failure while the socket is still up is a real answer from the server and is surfaced.
      if (this.connection.currentState === 'open') {
        this.raise(
          error instanceof ImError
            ? error
            : new ImError(ImErrorCode.InternalError, String(error), null, 'conn.sync'),
        );
      }
    }

    if (completed && generation === this.resumeGeneration) {
      this.cursors.completeRun(maxUpdatedAt);
    }
  }

  /**
   * Serialises everything that touches one conversation's cursors.
   *
   * Different conversations run in parallel; the same one never does. That is what keeps seq order
   * true across a repair and stops two repairs for one conversation racing each other.
   */
  private enqueue(conversationId: string, work: () => Promise<void>): Promise<void> {
    const previous = this.chains.get(conversationId) ?? Promise.resolve();
    const next = previous.then(work, work).catch(() => {
      /* a failed step must not poison the chain for every later message */
    });

    this.chains.set(conversationId, next);
    void next.then(() => {
      if (this.chains.get(conversationId) === next) this.chains.delete(conversationId);
    });

    return next;
  }

  /**
   * Our own send advances `deliveredSeq` so the server's echo of it is recognised as a duplicate.
   * It does **not** commit: the application has not stored it yet, and only the application knows
   * when it has.
   */
  private rememberOwnSend(result: SendMessageResult): void {
    if (result.seq > 0) {
      this.cursors.markDelivered(result.conversationId, result.seq);
    }
  }

  /**
   * Repairs the numbers the JSON policy allows to arrive as strings.
   *
   * `NumberHandling.AllowReadingFromString` is set server-side and `JSON.parse` has no schema, so
   * `seq` can legitimately be `"1234"`. Comparisons coerce and hide it; `seq + 1` does not, and
   * produces a repair request for a range that does not exist. Fixed once, here, on the way in.
   */
  private normalize(message: ImMessage): ImMessage {
    message.seq = asLong(message.seq);
    message.messageId = asId(message.messageId);
    message.sendTime = asLong(message.sendTime);
    message.createTime = asLong(message.createTime);
    return message;
  }

  private emit(message: ImMessage): void {
    for (const listener of this.messageListeners) {
      try {
        listener(message);
      } catch {
        // A throwing listener must not stop the others, stop the pump, or lose a cursor. One
        // application bug in one handler cannot be allowed to stop delivery for every conversation.
      }
    }
  }

  private raise(error: ImError): void {
    // Logged whether or not anybody is listening. An application with no error listener is exactly
    // the one whose problems get reported as "it just does not work", and this is the only record
    // that will exist when somebody finally asks.
    // 无论有没有人监听都记下来：没有装错误监听器的应用，正是那种把问题报成「它就是不好使」的应用，
    // 而当终于有人来问的时候，这是唯一存在的记录。
    this.log.error(`${error.target ?? 'sdk'}: ${error.message}`);

    if (this.errorListeners.size === 0) {
      console.warn(`[im] ${error.target ?? 'sdk'}: ${error.message}`);
      return;
    }

    for (const listener of this.errorListeners) {
      try {
        listener(error);
      } catch {
        /* ignore */
      }
    }
  }

  /**
   * Flush on the platform's background signal.
   *
   * A phone backgrounding an app is the most likely moment for the process to be killed without
   * warning, and it is exactly when a debounced commit is still in the air. `visibilitychange` and
   * `pagehide` are the two the browser actually delivers before a tab is discarded.
   */
  private installSuspendHooks(): void {
    if (this.suspendHooked || typeof document === 'undefined' || typeof document.addEventListener !== 'function') {
      return;
    }

    this.suspendHooked = true;
    document.addEventListener('visibilitychange', this.onSuspend);
    globalThis.addEventListener?.('pagehide', this.onSuspend);
  }

  private removeSuspendHooks(): void {
    if (!this.suspendHooked) return;

    this.suspendHooked = false;
    document.removeEventListener('visibilitychange', this.onSuspend);
    globalThis.removeEventListener?.('pagehide', this.onSuspend);
  }

  private readonly onSuspend = (): void => {
    if (typeof document !== 'undefined' && document.visibilityState === 'visible') return;
    void this.cursors.flush();
  };

  private newClientMsgId(): string {
    const random = Math.random().toString(36).slice(2, 10);
    return `${Date.now().toString(36)}-${random}`;
  }
}
