/**
 * A WebSocket the tests drive: it records what was sent, replies on command, and dies on command.
 *
 * A real socket cannot be made to fail on cue, and every behaviour worth testing in this SDK —
 * reconnect policy, kick classification, gap repair — is defined by what happens when one does.
 * `ConnectionOptions.webSocketImpl` exists for hosts without a global WebSocket; it doubles as the
 * seam that makes those behaviours testable at all.
 */
export class FakeSocket {
  static readonly instances: FakeSocket[] = [];

  static reset(): void {
    FakeSocket.instances.length = 0;
  }

  static get latest(): FakeSocket {
    const socket = FakeSocket.instances[FakeSocket.instances.length - 1];
    if (!socket) throw new Error('no socket has been created');
    return socket;
  }

  readonly url: URL;
  readonly sent: string[] = [];

  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: ((event: { code: number; reason: string }) => void) | null = null;
  onerror: (() => void) | null = null;

  closedWith: { code?: number; reason?: string } | null = null;

  constructor(url: string) {
    this.url = new URL(url);
    FakeSocket.instances.push(this);
  }

  send(payload: string): void {
    this.sent.push(payload);
  }

  close(code?: number, reason?: string): void {
    // A close we initiate still surfaces through onclose, exactly as a browser would report it.
    this.closedWith = { code, reason };
    this.onclose?.({ code: code ?? 1000, reason: reason ?? '' });
  }

  /** Completes the handshake. */
  open(): void {
    this.onopen?.();
  }

  /** The peer goes away. `reason` carries `im-kick:{Reason}` when this was a kick. */
  die(code = 1006, reason = ''): void {
    this.onclose?.({ code, reason });
  }

  deliver(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }

  /** The most recent request this socket was asked to send, decoded. */
  get lastRequest(): { id: string; target: string; body: Record<string, unknown> } | null {
    const raw = this.sent[this.sent.length - 1];
    return raw ? JSON.parse(raw) : null;
  }

  requestsTo(target: string): { id: string; target: string; body: Record<string, unknown> }[] {
    return this.sent
      .map((raw) => JSON.parse(raw) as { id: string; target: string; body: Record<string, unknown> })
      .filter((request) => request.target === target);
  }

  /** Answers a request by id, in the envelope shape SPEC-02 §1.2 defines. */
  reply(id: string, target: string, data: unknown, code = 0, extra: Record<string, unknown> = {}): void {
    this.deliver({
      id,
      target,
      status: 0,
      body: { code, serverTime: 1, data, ...extra },
    });
  }

  /** Answers whatever request is currently outstanding for `target`. */
  replyLatest(target: string, data: unknown): void {
    const requests = this.requestsTo(target);
    const request = requests[requests.length - 1];
    if (!request) throw new Error(`no request was sent to ${target}`);
    this.reply(request.id, target, data);
  }

  /** A server-initiated push, which has no request waiting for it. */
  push(target: string, data: unknown): void {
    this.deliver({ id: 'srv-1', target, status: 0, body: { code: 0, serverTime: 1, data } });
  }
}

/** Waits until `condition` holds, or fails the test. Real timers, so real async paths are used. */
export async function until(condition: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('condition not met in time');
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

export function message(conversationId: string, seq: number): Record<string, unknown> {
  return {
    appId: 'demo',
    conversationId,
    conversationType: 1,
    seq,
    messageId: 1000 + seq,
    clientMsgId: `c${seq}`,
    senderId: 'alice',
    senderPlatform: 5,
    contentType: 1,
    content: { text: `m${seq}` },
    sendTime: 1,
    createTime: 1,
  };
}
