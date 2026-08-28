/**
 * The two-cursor model, and the store that survives a process restart.
 *
 * **This file exists because of a data-loss bug.** Before it, `ImClient` kept one private `Map` of
 * "highest seq I have seen", with no accessor and no persistence. On a cold start that map was
 * empty, `conn.sync` was told nothing, and the server — which only reports a gap for a
 * conversation the client claims a position in (`ConnController.Sync`) — reported none. The client
 * then hit its own first-sight branch, adopted the server's `maxSeq`, and every message that
 * arrived while the app was closed fell behind the cursor: never requested, never delivered, no
 * error, no log line, no later event that corrects it. CONTRACT §5.1.
 *
 * The fix is two cursors, not one, and the distinction is the whole point:
 *
 * - **`deliveredSeq`** — highest seq handed to the application *in this process*. In memory only.
 *   It answers "have I already shown this?" and drives gap detection and dedupe.
 * - **`committedSeq`** — highest seq the application has said it durably stored. Persisted, and
 *   the value reported in `convSeqs`.
 *
 * One cursor cannot be both, because the two answer questions with different consequences. A
 * callback returning means the message reached the app's memory — which is exactly the state a
 * crash loses. Inferring durability from it is how you get a cursor that is confidently wrong, and
 * a cursor that is confidently wrong is indistinguishable from the bug above.
 *
 * 两个游标而不是一个：delivered 只在内存里，回答"这条我展示过了吗"；committed 由应用落库后回调，
 * 是上报给服务端的那个。回调返回 ≠ 已落库，用前者冒充后者就会得到一个自信而错误的游标。
 */

import { ImError, asLong } from './protocol.js';

/**
 * Who a set of cursors belongs to: `(endpoint host, appId, userId)`.
 *
 * Not the device id — the store is already local to the device. `userId` is the part that matters:
 * without it, two accounts on one handset share one set of cursors and the second one to sign in
 * silently inherits the first one's position, skipping whatever the first had already consumed.
 * That is cross-account data loss wearing the costume of a fast login. CONTRACT §5.3.
 *
 * 作用域键必须含 userId：同一台设备换账号时，否则第二个账号会继承第一个账号的游标。
 */
export class ImCursorScope {
  private constructor(
    readonly host: string,
    readonly appId: string,
    readonly userId: string,
  ) {}

  /**
   * The usual construction: the same endpoint the client connects to, reduced to its host.
   *
   * The host, not the whole URL: a deployment that moves between `wss://h/im` and `wss://h/gateway`
   * is the same server holding the same seqs, and re-downloading everything because a path changed
   * is a cost with nothing behind it.
   */
  static of(endpoint: string, appId: string, userId: string): ImCursorScope {
    let host = endpoint;
    try {
      host = new URL(endpoint).host;
    } catch {
      // A caller-supplied string that is not a URL is used verbatim; it still scopes correctly, it
      // just reads less well in a log.
    }
    return new ImCursorScope(host, appId, userId);
  }

  /**
   * The identity stamped into a snapshot and compared on load. Stable across platforms — all five
   * SDKs spell it `host|appId|userId`, so a cursor file written by one is legible to the others.
   */
  get key(): string {
    return `${this.host}|${this.appId}|${this.userId || '*'}`;
  }

  /** The same identity, safe as a file name or a `localStorage` key on every platform. */
  get storageKey(): string {
    return this.key.replace(/[^A-Za-z0-9._-]+/g, '_');
  }

  toString(): string {
    return this.key;
  }
}

/**
 * What survives a restart. `convSeqs` holds **committed** seqs, never delivered ones.
 *
 * Modelled as a plain object rather than a `Map` — the contract writes it `Map<conversationId,
 * long>`, but this is the shape that round-trips through `JSON.stringify` without a custom
 * replacer, and every store an integrator writes will be storing JSON.
 */
export interface ImCursorSnapshot {
  convSeqs: Record<string, number>;
  /** Max `ConversationView.updatedAt` from a `conn.sync` run that ran to completion. */
  conversationCursor: number;

  /**
   * Which {@link ImCursorScope} these cursors belong to, stamped by the SDK on every write.
   *
   * **This field is the account-switch guarantee, and it is here rather than in the store's
   * signature on purpose.** A store is a few lines an integrator writes; a store that keys itself
   * by account is a few lines an integrator *remembers* to write. Carrying the identity in the
   * payload means the SDK can refuse a snapshot that belongs to somebody else even when the store
   * did nothing to keep the two apart — so an app that does nothing special cannot get it wrong.
   *
   * Absent on a snapshot the SDK has never written (a fresh store, or one an application built by
   * hand); the SDK accepts that and stamps it on the next save.
   */
  scope?: string | null;
}

/**
 * Where cursors live between runs.
 *
 * **It is a required constructor argument.** There is no implicit default, and that is a decision
 * rather than an oversight: defaulting to no persistence is what produced the bug, and defaulting
 * to *some* persistence would mean guessing where an app is allowed to write — a wrong guess about
 * that is worse than a compile error. An integrator who genuinely wants no persistence passes
 * {@link ImCursorStore.inMemory}, which says so out loud, once, in the console.
 *
 * `load` and `save` may both be async; the SDK awaits them.
 */
export interface ImCursorStore {
  /** Called once, before the first connect. Throwing is handled — see {@link ImCursors.loadFailed}. */
  load(): ImCursorSnapshot | Promise<ImCursorSnapshot>;

  /** Called by the SDK. May be debounced; see {@link ImCursors.flush} for when it may not. */
  save(snapshot: ImCursorSnapshot): void | Promise<void>;
}

/** An empty snapshot. Also what a store should return for "nothing stored yet". */
export function emptySnapshot(): ImCursorSnapshot {
  return { convSeqs: {}, conversationCursor: 0 };
}

/**
 * Marks the SDK's own {@link ImCursorStore.inMemory} store. Not exported from the package.
 *
 * "Is this store persistent" is answered by the SDK, from the store's identity, and never by the
 * store itself. A declared flag would let *any* store — including one an integrator wrote over a
 * real database — announce itself volatile, and the only thing that answer drives is a warning
 * about losing messages. A store that can lie about that is a store that can silence the one line
 * standing between a misconfigured client and a support ticket about missing history.
 *
 * 「是否持久化」由 SDK 按存储的身份判断，不由存储自己声明：让任意实现自称易失，
 * 等于让它自己关掉那条唯一的告警。
 */
const VOLATILE = Symbol.for('cyaim.im.cursorStore.volatile');

/** True only for the store {@link ImCursorStore.inMemory} builds. */
export function isVolatileCursorStore(store: ImCursorStore): boolean {
  return (store as unknown as Record<symbol, unknown>)[VOLATILE] === true;
}

/**
 * Normalises whatever a store handed back into a snapshot, or throws.
 *
 * Throwing matters: a corrupt file and a fresh install must not look the same, because adopting on
 * a corrupt read destroys history that is sitting intact in the application's own database
 * (CONTRACT §5.8).
 */
function parseSnapshot(raw: unknown): ImCursorSnapshot {
  if (raw === null || typeof raw !== 'object') {
    throw new Error('cursor snapshot is not an object');
  }

  const source = raw as Partial<ImCursorSnapshot>;
  const convSeqs: Record<string, number> = {};

  if (source.convSeqs !== undefined && source.convSeqs !== null) {
    if (typeof source.convSeqs !== 'object') {
      throw new Error('cursor snapshot convSeqs is not an object');
    }
    for (const [conversationId, value] of Object.entries(source.convSeqs)) {
      const seq = asLong(value, Number.NaN);
      if (!Number.isFinite(seq) || seq < 0) {
        throw new Error(`cursor snapshot holds a non-numeric seq for ${conversationId}`);
      }
      convSeqs[conversationId] = seq;
    }
  }

  const conversationCursor = asLong(source.conversationCursor, Number.NaN);
  if (source.conversationCursor !== undefined && !Number.isFinite(conversationCursor)) {
    throw new Error('cursor snapshot holds a non-numeric conversationCursor');
  }

  if (source.scope !== undefined && source.scope !== null && typeof source.scope !== 'string') {
    throw new Error('cursor snapshot holds a non-string scope');
  }

  return {
    convSeqs,
    conversationCursor: Number.isFinite(conversationCursor) ? conversationCursor : 0,
    scope: (source.scope as string | null | undefined) ?? null,
  };
}

/**
 * Loses everything on restart.
 *
 * The warning that goes with it is raised by {@link ImCursors}, not here: a store does not get to
 * decide whether the application is told it is running without persistence.
 */
function inMemoryStore(): ImCursorStore {
  let snapshot = emptySnapshot();

  return {
    [VOLATILE]: true,
    load() {
      return snapshot;
    },
    save(next: ImCursorSnapshot) {
      snapshot = next;
    },
  } as ImCursorStore;
}

/**
 * Browser store. Throws at construction where `localStorage` does not exist rather than degrading
 * to nothing — a store that silently forgets is the bug this whole file is about.
 *
 * `scope` is required because this factory picks the key: the SDK-provided stores that choose
 * their own location scope that location by account, so switching back to an earlier account finds
 * its cursors intact instead of re-baselining. (Where *you* name the location — {@link file} — the
 * name you gave is the scoping, and the snapshot's stamped scope is what stops a shared one from
 * handing over the wrong cursors.)
 */
function localStorageStore(scope: ImCursorScope, keyPrefix = 'im.cursors'): ImCursorStore {
  const storage = globalThis.localStorage;
  if (!storage) {
    throw new Error(
      'ImCursorStore.localStorage() needs globalThis.localStorage, which this host does not have. ' +
        'Use ImCursorStore.file(path) on Node, or supply your own ImCursorStore.',
    );
  }

  const key = `${keyPrefix}:${scope.storageKey}`;

  return {
    load() {
      const raw = storage.getItem(key);
      if (raw === null) return emptySnapshot();
      return parseSnapshot(JSON.parse(raw));
    },
    save(snapshot) {
      // A quota failure must surface: it means the next cold start reads a stale cursor.
      storage.setItem(key, JSON.stringify(snapshot));
    },
  };
}

/**
 * Node/Electron store, one JSON file at the path you name.
 *
 * `node:fs/promises` is imported lazily, and with the bundler ignore hints, so that pulling this
 * module into a browser bundle does not drag a Node builtin in behind it. Nothing here runs until
 * someone actually calls `.file()`.
 *
 * **Put the user id in the path** if two accounts can sign in on one machine. Point both at one
 * file and the SDK notices — the snapshot carries its scope — and starts clean rather than handing
 * the second user the first one's cursors; but the first account's cursors are gone once the
 * second one writes, and it will re-download on its next login.
 * `${dir}/im-${ImCursorScope.of(endpoint, appId, userId).storageKey}.json` is the whole fix.
 */
function fileStore(path: string): ImCursorStore {
  const target = path;

  const fs = () => import(/* webpackIgnore: true */ /* @vite-ignore */ 'node:fs/promises');

  return {
    async load() {
      const { readFile } = await fs();
      try {
        return parseSnapshot(JSON.parse(await readFile(target, 'utf8')));
      } catch (error) {
        // "Not there yet" is a fresh install. Anything else — unreadable, truncated, not JSON — is
        // a load failure and must not be mistaken for one.
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') return emptySnapshot();
        throw error;
      }
    },
    async save(snapshot) {
      const { writeFile, rename } = await fs();
      // Write-then-rename: a process killed mid-write leaves the previous cursors intact instead
      // of a truncated file that fails to load on the next start.
      const temporary = `${target}.tmp`;
      await writeFile(temporary, JSON.stringify(snapshot), 'utf8');
      await rename(temporary, target);
    },
  };
}

export const ImCursorStore = {
  inMemory: inMemoryStore,
  localStorage: localStorageStore,
  file: fileStore,
};

export interface ImCursorsOptions {
  /**
   * Who this session is: `(endpoint host, appId, userId)`. Stamped onto every snapshot written and
   * checked against every snapshot read.
   */
  scope?: ImCursorScope;

  /** Where the two warnings this class raises go. Defaults to `console.warn`. */
  onWarn?: (message: string) => void;

  /**
   * How long an ordinary commit may sit unwritten. Floor 0 (write through), no ceiling.
   *
   * The asymmetry with adoption is deliberate and worth keeping in mind when tuning this:
   * **a lost debounced commit costs one duplicate delivery; a lost adoption write costs silent
   * permanent data loss.** That is why one is allowed to be lossy and the other is flushed
   * synchronously whatever this is set to.
   */
  flushIntervalMs?: number;

  /** Where store failures go. They are surfaced, never swallowed (CONTRACT §5.8). */
  onError?: (error: ImError) => void;
}

/**
 * Holds both cursors for every conversation and owns the write-through to the store.
 *
 * Exposed on `ImClient` so an application can read what the SDK believes — the absence of exactly
 * that accessor is how the original bug went unnoticed in four SDKs at once.
 */
export class ImCursors {
  private readonly delivered = new Map<string, number>();
  private readonly committed = new Map<string, number>();
  private conversationCursorValue = 0;

  private readonly flushIntervalMs: number;
  private readonly onError: (error: ImError) => void;
  private readonly onWarn: (message: string) => void;
  private readonly scopeKey: string | null;

  private dirty = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private writes: Promise<void> = Promise.resolve();

  private loaded = false;
  private failed = false;
  private rejectedForeignScope = false;
  private restoredCount = 0;

  constructor(
    private readonly store: ImCursorStore,
    options: ImCursorsOptions = {},
  ) {
    this.flushIntervalMs = Math.max(0, options.flushIntervalMs ?? 1000);
    this.onError = options.onError ?? (() => {});
    this.onWarn = options.onWarn ?? ((message) => console.warn(message));
    this.scopeKey = options.scope?.key ?? null;
  }

  /**
   * True when the store handed back cursors belonging to a different account and they were
   * discarded. Observable so an application can tell "nothing stored yet" from "stored, but not
   * yours" — and so a test can prove the guarantee still holds.
   */
  get foreignScopeRejected(): boolean {
    return this.rejectedForeignScope;
  }

  /** True once `load()` has run, whether or not it succeeded. */
  get isLoaded(): boolean {
    return this.loaded;
  }

  /**
   * True when the store could not be read. The session then runs in a deliberately degraded mode:
   * nothing is adopted, nothing is committed, nothing is written. See {@link load}.
   */
  get loadFailed(): boolean {
    return this.failed;
  }

  /**
   * How many conversations came back from the store. Zero after a successful load of an empty
   * store is a fresh install; zero after a failed one is not, and the two must not be confused.
   */
  get restoredConversations(): number {
    return this.restoredCount;
  }

  get conversationCursor(): number {
    return this.conversationCursorValue;
  }

  deliveredSeq(conversationId: string): number {
    return this.delivered.get(conversationId) ?? 0;
  }

  committedSeq(conversationId: string): number {
    return this.committed.get(conversationId) ?? 0;
  }

  /**
   * Whether the loaded snapshot has an entry for this conversation — the exact question the
   * adoption branch asks (CONTRACT §5.5).
   *
   * Deliberately committed-only. Answering it from `deliveredSeq` would mean a conversation the
   * application has been shown but has never committed is treated as known, so it is never
   * adopted, its `convSeqs` entry stays absent, and it lands in the one state this whole file
   * exists to prevent: a conversation with no cursor anywhere and a server that therefore reports
   * no gap for it.
   */
  knows(conversationId: string): boolean {
    return this.committed.has(conversationId);
  }

  /** A copy, safe to hand to the application, stamped with whose cursors these are. */
  snapshot(): ImCursorSnapshot {
    return {
      convSeqs: Object.fromEntries(this.committed),
      conversationCursor: this.conversationCursorValue,
      scope: this.scopeKey,
    };
  }

  /**
   * Reads the store once, before the first connect.
   *
   * A throwing or corrupt `load()` is **not** treated as a fresh install. The two are
   * indistinguishable to the adoption branch, and adopting on a failed load destroys history that
   * is sitting intact in the application's own database. Instead the failure is surfaced, and for
   * the rest of the session the SDK refuses to adopt, refuses to advance `committedSeq`, and
   * refuses to write. The application decides whether to re-derive cursors from its own store —
   * the correct fix, and the reason `commit` is monotonic — or to accept a re-download.
   *
   * (`deliveredSeq` still moves in memory. It starts at zero, only ever records what this process
   * actually handed over, and is never written anywhere; keeping it live buys in-session dedupe and
   * ordering at no risk, where freezing it would buy nothing and cost both.)
   */
  async load(): Promise<void> {
    if (this.loaded) return;
    this.loaded = true;

    if (isVolatileCursorStore(this.store)) {
      this.onWarn(
        '[im] ImCursorStore.inMemory(): cursors are not persisted. Every cold start re-baselines ' +
          'to the server position, so messages that arrive while this process is not running are ' +
          'never delivered. Pass ImCursorStore.localStorage(scope) or .file(path) in production. ' +
          'See sdk/CONTRACT.md §5.3.',
      );
    }

    try {
      const snapshot = parseSnapshot(await this.store.load());

      // The account-switch guarantee (CONTRACT §5.3). The snapshot carries the identity the SDK
      // stamped on it, so a store that does nothing to keep two accounts apart still cannot hand
      // one user the other's position — the worst it can do is cost the earlier account a
      // re-download, which is loud in the logs and recoverable, where inherited cursors are
      // silent and permanent.
      // 快照自带身份：即使存储没有按账号隔离，也不会把上一个账号的游标交给下一个账号。
      if (snapshot.scope != null && this.scopeKey != null && snapshot.scope !== this.scopeKey) {
        this.rejectedForeignScope = true;
        this.restoredCount = 0;
        this.onWarn(
          `[im] the cursor store holds cursors for '${snapshot.scope}' but this session is ` +
            `'${this.scopeKey}'; starting clean rather than replaying another account's position. ` +
            'Use one store per account — see sdk/CONTRACT.md §5.3.',
        );
        return;
      }

      for (const [conversationId, seq] of Object.entries(snapshot.convSeqs)) {
        this.committed.set(conversationId, seq);
        this.delivered.set(conversationId, seq);
      }
      this.conversationCursorValue = snapshot.conversationCursor;
      this.restoredCount = this.committed.size;
    } catch (error) {
      this.failed = true;
      this.restoredCount = 0;
      this.onError(
        new ImError(
          1000,
          `cursor store load failed, so this session will neither adopt nor persist any cursor: ${
            error instanceof Error ? error.message : String(error)
          }`,
          null,
          'im.cursorStore.load',
        ),
      );
    }
  }

  /**
   * `deliveredSeq := committedSeq`, for every conversation. Runs on every connect and reconnect,
   * **before** `conn.sync`.
   *
   * Without it the repaired messages are dropped as duplicates by the very cursor that was too far
   * ahead: the server redelivers from the committed position, the client compares against a
   * delivered position beyond it, and the redelivery it just asked for is thrown away.
   */
  resetDeliveredToCommitted(): void {
    this.delivered.clear();
    for (const [conversationId, seq] of this.committed) {
      this.delivered.set(conversationId, seq);
    }
  }

  /** Records that the application has been handed this seq. Memory only; never persisted. */
  markDelivered(conversationId: string, seq: number): void {
    if (seq <= 0) return;
    if (seq > this.deliveredSeq(conversationId)) {
      this.delivered.set(conversationId, seq);
    }
  }

  /**
   * The application says it has durably stored everything up to `seq`.
   *
   * Monotonic: a lower seq is ignored rather than an error, so an app that commits out of order —
   * or re-derives its cursors from its own database on startup, which is the recommended repair
   * after a load failure — cannot walk a cursor backwards.
   */
  commit(conversationId: string, seq: number): void {
    if (seq <= 0 || this.failed) return;
    if (seq <= this.committedSeq(conversationId)) return;

    this.committed.set(conversationId, seq);
    // Invariant: committedSeq <= deliveredSeq. An app that commits ahead of delivery has more than
    // we do; believing it is correct, and keeps the next gap calculation honest.
    this.markDelivered(conversationId, seq);
    this.schedule();
  }

  /**
   * First sight of a conversation: take the server's position rather than replaying a history the
   * UI has never shown.
   *
   * **Adoption is a commit and its write is not debounced.** If an adoption write is lost, the next
   * cold start sees no entry, adopts a *newer* `maxSeq`, and silently drops everything in
   * between — the original bug, re-created by the optimisation. Hence the awaited flush.
   */
  async adopt(conversationId: string, maxSeq: number): Promise<void> {
    if (this.failed) return;

    const seq = Math.max(0, maxSeq);
    this.committed.set(conversationId, seq);
    this.delivered.set(conversationId, seq);
    this.dirty = true;
    await this.flush();
  }

  /**
   * A gap too wide to backfill: take the far end and tell the application to reload.
   *
   * Both halves are mandatory (CONTRACT §5.6 step 5). Skipping the cursor advance makes every later
   * message look like a gap and re-request a range you have already declined; skipping the event
   * leaves a hole in the UI that nothing will ever mention.
   */
  skipTo(conversationId: string, seq: number): void {
    if (this.failed) return;
    if (seq <= 0) return;

    this.delivered.set(conversationId, Math.max(seq, this.deliveredSeq(conversationId)));
    if (seq > this.committedSeq(conversationId)) {
      this.committed.set(conversationId, seq);
      this.schedule();
    }
  }

  /**
   * Moves `conversationCursor` — only ever called once a `conn.sync` run has read every page.
   *
   * The list is sorted by `updatedAt` descending, so page 1 holds the newest timestamp. Taking the
   * maximum from page 1 and stopping pushes the cursor past every conversation on pages 2…N, and
   * `ListUserConversationsAsync` filters `UpdatedAt > updatedAfter` — the server will never return
   * them again. Re-reading a page is free; skipping one is permanent.
   */
  completeRun(maxUpdatedAt: number): void {
    if (this.failed) return;
    if (maxUpdatedAt <= this.conversationCursorValue) return;

    this.conversationCursorValue = maxUpdatedAt;
    this.schedule();
  }

  /**
   * Writes now and waits for it.
   *
   * Called before every `conn.sync`, on adoption, and on the platform's background/suspend signal.
   * Everything else may wait out the debounce.
   */
  async flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    return this.enqueueWrite();
  }

  /** Stops the debounce timer. Does not write — call {@link flush} first if the state matters. */
  dispose(): void {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  private schedule(): void {
    if (this.failed) return;
    this.dirty = true;

    if (this.flushIntervalMs === 0) {
      void this.flush();
      return;
    }

    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.enqueueWrite();
    }, this.flushIntervalMs);
  }

  /**
   * Writes are serialised through one chain, so two flushes racing cannot land out of order and
   * leave the older snapshot on disk.
   */
  private enqueueWrite(): Promise<void> {
    this.writes = this.writes.then(() => this.writeNow());
    return this.writes;
  }

  private async writeNow(): Promise<void> {
    if (!this.dirty || this.failed) return;

    this.dirty = false;
    const snapshot = this.snapshot();

    try {
      await this.store.save(snapshot);
    } catch (error) {
      // Leave it dirty so the next flush retries, and say so — a store that silently stopped
      // saving looks exactly like one that is working until the next cold start.
      this.dirty = true;
      this.onError(
        new ImError(
          1000,
          `cursor store save failed: ${error instanceof Error ? error.message : String(error)}`,
          null,
          'im.cursorStore.save',
        ),
      );
    }
  }
}
