import { fullJitterDelay } from './backoff.js';
import type { HeartbeatResult } from './models.js';
import { ImError, ImErrorCode, abortError, type ImFrame, type ImRequest } from './protocol.js';
import { SDK_CLIENT_VERSION } from './version.js';

export interface ConnectionOptions {
  /** Base URL, e.g. wss://im.example.com. The channel path is appended. */
  endpoint: string;
  channel?: string;
  appId: string;
  /** User token issued by the tenant backend. Never an app secret. */
  token: string;
  deviceId: string;
  platform: number;
  clientVersion?: string;
  language?: string;
  /** Milliseconds before an unanswered request rejects. */
  requestTimeoutMs?: number;
  /**
   * Supply a token when the current one expires. Return null to stop reconnecting.
   *
   * Called on two paths: a socket closed with `im-kick:TokenExpired`, and a live request answered
   * `1101 TokenExpired` — the second is repaired with `conn.reauth` on the socket that is already
   * open, so a token expiring mid-session costs one round trip instead of a reconnect.
   */
  onTokenExpired?: () => Promise<string | null>;
  /** Injectable for Node/React Native, where WebSocket is not global. */
  webSocketImpl?: typeof WebSocket;
  /**
   * Source of randomness for the reconnect jitter. Injectable only so tests can be deterministic;
   * production has no reason to pass it.
   */
  random?: () => number;
}

/** Trailing options bag on every typed call. Cancellation is the reason it exists. */
export interface ImRequestOptions {
  /**
   * Abandons the reply.
   *
   * It does **not** cancel the server-side effect: a cancelled `msg.send` may well have sent the
   * message. That is what `clientMsgId` idempotency is for — reissue with the same one and the
   * server returns the original result rather than a second message (CONTRACT §7.5).
   */
  signal?: AbortSignal;

  /** Overrides `ConnectionOptions.requestTimeoutMs` for this call. */
  timeoutMs?: number;
}

export type ConnectionState = 'idle' | 'connecting' | 'open' | 'reconnecting' | 'closed';

interface Pending {
  resolve: (frame: ImFrame) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  target: string;
  /** Detaches the abort listener; a pending entry that outlived its signal is a leak. */
  release: () => void;
}

/**
 * One multiplexed WebSocket to the gateway, with the reconnect behaviour a production client
 * actually needs.
 *
 * Reconnecting is not an optional extra here. A gateway holds sockets and therefore deploys
 * rarely, but when it does deploy — or when a node fails, or a phone changes network — every
 * client on that node reconnects at once. Without jittered backoff those clients arrive as a
 * synchronised thundering herd against the very service that just came back up. Every delay below
 * is jittered for that reason.
 *
 * 重连不是可选项：网关一次滚动更新会让该节点上所有客户端同时重连。没有带抖动的退避，
 * 这些客户端会变成打向刚恢复的服务的同步洪峰。
 */
export class ImConnection {
  private socket: WebSocket | null = null;
  private state: ConnectionState = 'idle';
  private readonly pending = new Map<string, Pending>();
  private readonly listeners = new Map<string, Set<(frame: ImFrame) => void>>();
  private readonly stateListeners = new Set<(state: ConnectionState) => void>();

  private attempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatSeconds = 30;
  private sequence = 0;
  private stopped = false;
  private token: string;

  /** One reauth at a time: twenty requests failing 1101 together must not fetch twenty tokens. */
  private reauthInFlight: Promise<boolean> | null = null;

  /** Reasons that mean "do not come back": reconnecting would fail identically, forever. */
  private static readonly TerminalKicks = new Set([
    'MultiLoginPolicy',
    'TokenRevoked',
    'UserBanned',
    'AppDisabled',
    'AdminKick',
  ]);

  private readonly random: () => number;

  constructor(private readonly options: ConnectionOptions) {
    this.token = options.token;
    this.random = options.random ?? Math.random;
  }

  get currentState(): ConnectionState {
    return this.state;
  }

  /** The token this connection will hand over on its next handshake. Moves on a successful reauth. */
  get currentToken(): string {
    return this.token;
  }

  /** Requests still waiting for a reply. Exposed so a leak is testable rather than inferred. */
  get pendingCount(): number {
    return this.pending.size;
  }

  onState(listener: (state: ConnectionState) => void): () => void {
    this.stateListeners.add(listener);
    return () => this.stateListeners.delete(listener);
  }

  /** Subscribes to a server push target. Returns an unsubscribe function. */
  on(target: string, listener: (frame: ImFrame) => void): () => void {
    let set = this.listeners.get(target);
    if (!set) {
      set = new Set();
      this.listeners.set(target, set);
    }
    set.add(listener);
    return () => set!.delete(listener);
  }

  /** Idempotent: connecting an already-connecting or already-open connection is a no-op. */
  async connect(): Promise<void> {
    this.stopped = false;
    if (this.state === 'open' || this.state === 'connecting' || this.state === 'reconnecting') {
      return;
    }
    await this.open();
  }

  /** Idempotent, and safe to call from a listener. */
  close(): void {
    this.stopped = true;
    this.clearTimers();
    this.socket?.close(1000, 'client-close');
    this.socket = null;
    this.setState('closed');
    this.failAllPending(new ImError(ImErrorCode.Timeout, 'connection closed'));
  }

  /**
   * Sends a request and resolves with its business payload, throwing ImError on a non-zero code.
   *
   * Requests issued while offline reject immediately rather than queueing — a chat client that
   * silently buffers sends produces messages that arrive minutes late into a conversation that has
   * moved on. The application knows whether the message is still worth sending; the SDK does not.
   *
   * Both layers of the envelope are mapped, and never collapsed into one: `status` says whether the
   * call was delivered, `body.code` says what the business rule decided (CONTRACT §7.2).
   */
  async request<T>(target: string, body?: unknown, options?: ImRequestOptions): Promise<T> {
    try {
      return this.unwrap<T>(target, await this.send(target, body, options));
    } catch (error) {
      // A token that expired mid-session is repairable on the socket that is already open: swap it
      // with conn.reauth and reissue once. Only if that fails does the session drop (CONTRACT §7.4).
      if (this.shouldReauth(error, target) && (await this.reauth())) {
        return this.unwrap<T>(target, await this.send(target, body, options));
      }
      throw error;
    }
  }

  private unwrap<T>(target: string, frame: ImFrame): T {
    // status 2 is "this deployment does not have this endpoint" — the exact signal an SDK newer
    // than a private-deployment server produces. 1008 says that; 1002 NotFound would be read as
    // "your group does not exist" and send the integrator looking in the wrong place.
    if (frame.status === 2) {
      throw new ImError(
        ImErrorCode.UnsupportedOperation,
        frame.msg ?? `endpoint not found on this deployment: ${target}`,
        frame.body?.traceId,
        target,
      );
    }

    if (frame.status !== 0) {
      throw new ImError(
        ImErrorCode.InternalError,
        frame.msg ?? 'the endpoint threw',
        frame.body?.traceId,
        target,
      );
    }

    const result = frame.body;
    if (!result || result.code !== 0) {
      throw new ImError(
        result?.code ?? ImErrorCode.InternalError,
        result?.message ?? 'request failed',
        result?.traceId,
        target,
      );
    }

    return result.data as T;
  }

  private shouldReauth(error: unknown, target: string): boolean {
    return (
      error instanceof ImError &&
      error.code === ImErrorCode.TokenExpired &&
      target !== 'conn.reauth' &&
      this.options.onTokenExpired !== undefined
    );
  }

  /** Swaps the token on the live socket. Shared, so concurrent 1101s cost one token fetch. */
  private reauth(): Promise<boolean> {
    this.reauthInFlight ??= (async () => {
      try {
        const next = await this.options.onTokenExpired?.();
        if (!next) return false;

        this.unwrap<void>('conn.reauth', await this.send('conn.reauth', { token: next }));
        this.token = next;
        return true;
      } catch {
        // The session drops the ordinary way: the server closes the socket, or the next request
        // fails again and the caller sees 1101 with requiresReauth set.
        return false;
      } finally {
        this.reauthInFlight = null;
      }
    })();

    return this.reauthInFlight;
  }

  private send(target: string, body?: unknown, options?: ImRequestOptions): Promise<ImFrame> {
    if (options?.signal?.aborted) {
      return Promise.reject(abortError(`cancelled before sending: ${target}`));
    }

    if (!this.socket || this.state !== 'open') {
      return Promise.reject(new ImError(ImErrorCode.ServiceUnavailable, 'not connected', null, target));
    }

    const id = `c${++this.sequence}-${Date.now().toString(36)}`;
    const payload: ImRequest = { id, target, body: body ?? {} };
    const timeoutMs = options?.timeoutMs ?? this.options.requestTimeoutMs ?? 15000;

    return new Promise<ImFrame>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.settle(id);
        reject(new ImError(ImErrorCode.Timeout, `request timed out: ${target}`, null, target));
      }, timeoutMs);

      const signal = options?.signal;
      const onAbort = () => {
        // Removing the entry is the whole job here: a cancellation path that leaves it behind is a
        // leak that grows for the life of the connection.
        this.settle(id);
        reject(abortError(`cancelled: ${target}`));
      };

      signal?.addEventListener('abort', onAbort, { once: true });

      this.pending.set(id, {
        resolve,
        reject,
        timer,
        target,
        release: () => signal?.removeEventListener('abort', onAbort),
      });

      try {
        this.socket!.send(JSON.stringify(payload));
      } catch (error) {
        this.settle(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  /** Clears one pending entry and everything hanging off it. */
  private settle(id: string): Pending | undefined {
    const entry = this.pending.get(id);
    if (!entry) return undefined;

    clearTimeout(entry.timer);
    entry.release();
    this.pending.delete(id);
    return entry;
  }

  private async open(): Promise<void> {
    this.setState(this.attempt === 0 ? 'connecting' : 'reconnecting');

    const Impl = this.options.webSocketImpl ?? globalThis.WebSocket;
    if (!Impl) {
      throw new Error('No WebSocket implementation available. Pass options.webSocketImpl.');
    }

    const socket = new Impl(this.buildUrl());
    this.socket = socket;

    socket.onopen = () => {
      this.attempt = 0;
      this.setState('open');
      this.startHeartbeat();
    };

    socket.onmessage = (event: MessageEvent) => this.dispatch(event.data);

    socket.onclose = (event: CloseEvent) => {
      this.clearTimers();

      // 1004 Timeout, not 1005 ServiceUnavailable: 1005 claims the call was never delivered, and
      // the SDK does not know that — the request may well have executed. 1004 is the honest
      // answer, and it is the one that makes a caller reach for clientMsgId idempotency instead of
      // blindly resending (CONTRACT §7.2).
      this.failAllPending(new ImError(ImErrorCode.Timeout, 'connection lost with the request in flight'));

      if (this.stopped) {
        this.setState('closed');
        return;
      }

      // The close reason is the only signal that separates "you were kicked" from "the network
      // died", and the two need opposite responses.
      const kick = this.parseKick(event.reason);
      if (kick && ImConnection.TerminalKicks.has(kick)) {
        this.emitKick(kick);
        this.setState('closed');
        return;
      }

      if (kick === 'TokenExpired') {
        void this.refreshTokenAndReconnect();
        return;
      }

      this.scheduleReconnect();
    };

    socket.onerror = () => {
      // onclose always follows; reconnect logic lives there so it runs exactly once.
    };
  }

  private buildUrl(): string {
    const base = this.options.endpoint.replace(/\/+$/, '');
    const channel = this.options.channel ?? '/im';
    const params = new URLSearchParams({
      appId: this.options.appId,
      token: this.token,
      deviceId: this.options.deviceId,
      platform: String(this.options.platform),
      v: '1',
    });

    // `cv` defaults to this SDK's own version so a support ticket carries it without anyone having
    // to ask. An application that wants to report its own build overrides it.
    params.set('cv', this.options.clientVersion || SDK_CLIENT_VERSION);
    if (this.options.language) params.set('lang', this.options.language);

    return `${base}${channel}?${params.toString()}`;
  }

  private dispatch(raw: unknown): void {
    if (typeof raw !== 'string') {
      return;
    }

    let frame: ImFrame;
    try {
      frame = JSON.parse(raw) as ImFrame;
    } catch {
      return;
    }

    const waiting = frame.id ? this.settle(frame.id) : undefined;
    if (waiting) {
      waiting.resolve(frame);
      return;
    }

    const listeners = this.listeners.get(frame.target);
    if (listeners) {
      for (const listener of listeners) {
        try {
          listener(frame);
        } catch {
          // A throwing listener must not stop the others or the receive loop.
        }
      }
    }
  }

  private scheduleReconnect(): void {
    this.setState('reconnecting');
    this.attempt += 1;

    // Full jitter — a uniform draw from 0..ceiling, not the ceiling and not ceiling±10%. See
    // backoff.ts for why that distinction is the difference between a ramp and a second outage.
    const delay = fullJitterDelay(this.attempt, this.random);

    this.reconnectTimer = setTimeout(() => void this.open(), delay);
  }

  private async refreshTokenAndReconnect(): Promise<void> {
    const next = await this.options.onTokenExpired?.();
    if (!next) {
      this.setState('closed');
      this.emitKick('TokenExpired');
      return;
    }

    this.token = next;
    this.scheduleReconnect();
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      this.request<HeartbeatResult>('conn.heartbeat')
        .then((result) => {
          // The server owns the cadence; adopt whatever it reports.
          if (result.intervalSeconds > 0 && result.intervalSeconds !== this.heartbeatSeconds) {
            this.heartbeatSeconds = result.intervalSeconds;
            this.startHeartbeat();
          }
        })
        .catch(() => {
          // A missed beat on a socket the OS still thinks is open is exactly the half-open
          // connection case: force a close so reconnect logic takes over.
          this.socket?.close(4000, 'heartbeat-failed');
        });
    }, this.heartbeatSeconds * 1000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private clearTimers(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private failAllPending(error: Error): void {
    for (const id of [...this.pending.keys()]) {
      const entry = this.settle(id);
      entry?.reject(error);
    }
    this.pending.clear();
  }

  private parseKick(reason: string | undefined): string | null {
    if (!reason || !reason.startsWith('im-kick:')) {
      return null;
    }
    return reason.slice('im-kick:'.length);
  }

  private emitKick(reason: string): void {
    const listeners = this.listeners.get('conn.kick');
    if (!listeners) return;

    const frame: ImFrame = {
      id: '',
      target: 'conn.kick',
      status: 0,
      body: { code: 0, serverTime: Date.now(), data: { reason } },
    };

    for (const listener of listeners) {
      try {
        listener(frame);
      } catch {
        /* ignore */
      }
    }
  }

  private setState(state: ConnectionState): void {
    if (this.state === state) return;
    this.state = state;
    for (const listener of this.stateListeners) {
      try {
        listener(state);
      } catch {
        /* ignore */
      }
    }
  }
}
