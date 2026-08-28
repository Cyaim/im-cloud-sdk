/**
 * The SDK's own runtime log, and where it lives between runs.
 *
 * The decision behind this file is `ADR-003`: **the store belongs to the integrating application**,
 * exactly as {@link ImCursorStore} does. The SDK does not choose a write location, because on
 * Android that is app-private storage, on iOS it is `Documents` or `Library/Caches` — whose backup
 * behaviour differs, and "do chat logs get synced to iCloud" is a question an integrator answers to
 * a regulator — and on the web it is IndexedDB, which an integrator may be obliged to clear on
 * logout and cannot clear if they do not know it exists.
 *
 * 依据 ADR-003：日志存储属于接入方的应用，与游标存储同理。
 * SDK 不替你选写入位置——那个选择的后果由你承担、由你被问责。
 *
 * Supplying none is a complete choice: {@link ImLogStore.inMemory} keeps a bounded ring in memory
 * and says so out loud, once. What that costs is stated plainly rather than hidden: the log then
 * covers this process only, so it answers "what is happening now" completely and "what happened
 * when it crashed" not at all.
 * 不提供也是一个完整的选择：内存环形缓冲，只覆盖本次进程——
 * 它完整地回答「现在正在发生什么」，而对「崩的时候发生了什么」一个字也答不出。
 */

/** One line. `t` is Unix ms; `level` is `debug` | `info` | `warn` | `error`. */
export interface ImLogLine {
  t: number;
  level: string;
  msg: string;
}

/**
 * Where the SDK's log lines are kept.
 *
 * Every method may be synchronous or return a promise, and **every one of them may throw**: a
 * broken store must never take down a client that is otherwise chatting happily. Logging is a
 * diagnostic feature, so its failure has to cost less than the thing it serves.
 * 每个方法都可以抛：坏掉的存储绝不能让一个本来聊得好好的客户端断线。
 */
export interface ImLogStore {
  /** Appends lines. May coalesce, and may drop the oldest to stay within its own bound. */
  append(lines: ImLogLine[]): void | Promise<void>;

  /** Everything currently held, oldest first. */
  read(): ImLogLine[] | Promise<ImLogLine[]>;

  /** Called after a successful upload. A store that ignores this is allowed but will grow. */
  clear(): void | Promise<void>;
}

/**
 * Marks the SDK's own {@link inMemoryLogStore} store. Not exported from the package.
 *
 * "Is this store persistent" is answered by the SDK, from the store's identity, and never by the
 * store itself — the same rule {@link ImCursorStore} follows, and for the same reason. A declared
 * flag would let *any* store announce itself persistent, and the only thing that answer drives is
 * whether a support engineer is told the log they are reading covers three minutes or three weeks.
 * A store that can lie about that is a store that can make somebody conclude nothing went wrong.
 *
 * 「是否持久化」由 SDK 按存储的身份判断，不由存储自己声明：
 * 能自称持久的存储，也能让人得出「什么都没发生」的结论。
 */
const VOLATILE = Symbol.for('cyaim.im.logStore.volatile');

/** True only for the store {@link inMemoryLogStore} builds. */
export function isVolatileLogStore(store: ImLogStore): boolean {
  return (store as unknown as Record<symbol, unknown>)[VOLATILE] === true;
}

/**
 * Loses everything on restart. The default, and an honest one.
 *
 * @param capacity lines kept before the oldest are dropped. The bound is on lines rather than
 * bytes because a line is what a reader counts, and a byte cap would silently truncate the middle
 * of the sentence somebody is trying to read.
 */
export function inMemoryLogStore(capacity = 2000): ImLogStore {
  let lines: ImLogLine[] = [];

  const store: ImLogStore = {
    append(incoming) {
      lines.push(...incoming);
      if (lines.length > capacity) {
        // The newest are what a support engineer needs: the failure is at the end of the log, not
        // at the beginning. 保留最新的：故障在日志末尾而不是开头。
        lines = lines.slice(lines.length - capacity);
      }
    },
    read() {
      return [...lines];
    },
    clear() {
      lines = [];
    },
  };

  (store as unknown as Record<symbol, unknown>)[VOLATILE] = true;
  return store;
}

/**
 * Buffers the SDK's own lines and hands them to the store.
 *
 * **Buffered rather than written through**, because the events worth logging arrive in bursts — a
 * reconnect storm writes a dozen lines in as many milliseconds — and a store backed by a file or by
 * IndexedDB would be asked for a dozen round trips to record one incident.
 * 带缓冲而不是直写：值得记的事件是成串来的（一次重连风暴几毫秒内十几行），
 * 而落在文件或 IndexedDB 上的存储会为记录一次事故被要求往返十几次。
 */
export class ImLog {
  private pending: ImLogLine[] = [];
  private timer: ReturnType<typeof setTimeout> | undefined;
  private failed = false;

  constructor(
    private readonly store: ImLogStore,
    private readonly flushIntervalMs = 2000,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** True when the store is the in-memory one, so the log covers this process only. */
  get isVolatile(): boolean {
    return isVolatileLogStore(this.store);
  }

  /**
   * True once an append or a read has thrown.
   *
   * Surfaced rather than swallowed for the same reason `cursorStoreFailed` is: an integrator whose
   * store is misconfigured otherwise finds out when a support engineer asks for a log and gets an
   * empty one.
   * 与游标存储那一处同理：不然接入方要等到有人来要日志、拿到一份空的，才知道存储配坏了。
   */
  get failedToWrite(): boolean {
    return this.failed;
  }

  write(level: string, msg: string): void {
    this.pending.push({ t: this.now(), level, msg });

    if (this.timer === undefined) {
      this.timer = setTimeout(() => void this.flush(), this.flushIntervalMs);
    }
  }

  debug(msg: string): void {
    this.write('debug', msg);
  }

  info(msg: string): void {
    this.write('info', msg);
  }

  warn(msg: string): void {
    this.write('warn', msg);
  }

  error(msg: string): void {
    this.write('error', msg);
  }

  /** Writes whatever is buffered. Safe to call at any time; called before every read. */
  async flush(): Promise<void> {
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }

    if (this.pending.length === 0) {
      return;
    }

    const batch = this.pending;
    this.pending = [];

    try {
      await this.store.append(batch);
    } catch {
      // Deliberately swallowed. A store that cannot be written to is a diagnostic problem, and
      // raising it here would put a logging failure in the path of whatever was being logged —
      // including, very often, an error the application actually needs to see.
      // 刻意吞掉：写不进去是排障问题，而在这里抛出会把一次日志失败插进正在被记录的那件事的路径上——
      // 那件事往往正是应用真正需要看到的错误。
      this.failed = true;
    }
  }

  /** Everything the store holds, newest last. Flushes first so the tail is not missing. */
  async read(): Promise<ImLogLine[]> {
    await this.flush();

    try {
      return await this.store.read();
    } catch {
      this.failed = true;
      return [];
    }
  }

  async clear(): Promise<void> {
    this.pending = [];
    try {
      await this.store.clear();
    } catch {
      this.failed = true;
    }
  }
}

/**
 * Renders lines as the text file a support engineer opens.
 *
 * Plain text, one line each, ISO timestamps — not JSON. Whoever reads this is reading it in a
 * viewer, often on a phone, and the first thing they do is search it for a word.
 * 纯文本而不是 JSON：读它的人是在查看器里读、常常在手机上，而他做的第一件事是搜一个词。
 */
export function renderLogBundle(lines: ImLogLine[]): string {
  return lines
    .map((line) => `${new Date(line.t).toISOString()} ${line.level.toUpperCase().padEnd(5)} ${line.msg}`)
    .join('\n');
}
