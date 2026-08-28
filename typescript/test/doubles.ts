/**
 * Test doubles for the cursor store and for opening a client against {@link FakeSocket}.
 *
 * The store double records every write rather than only the last one, because half of what
 * CONTRACT §5 specifies is *when* a write happens — adoption before the next `conn.sync` page,
 * nothing at all after a failed load — and a double that only kept the final state could not tell
 * a correct implementation from one that got there late.
 */

import { ImClient, type ImClientOptions } from '../src/client.js';
import { emptySnapshot, type ImCursorSnapshot, type ImCursorStore } from '../src/cursors.js';
import type { ImMessage } from '../src/models.js';
import { FakeSocket, until } from './fake-socket.js';

export class RecordingCursorStore implements ImCursorStore {
  /** Every snapshot handed to `save`, in order. */
  readonly saves: ImCursorSnapshot[] = [];

  loadCount = 0;

  constructor(
    private readonly initial: ImCursorSnapshot = emptySnapshot(),
    private readonly loadFailure: Error | null = null,
  ) {}

  load(): ImCursorSnapshot {
    this.loadCount++;
    if (this.loadFailure) throw this.loadFailure;
    return structuredClone(this.initial);
  }

  save(snapshot: ImCursorSnapshot): void {
    this.saves.push(structuredClone(snapshot));
  }

  get last(): ImCursorSnapshot | undefined {
    return this.saves[this.saves.length - 1];
  }
}

/** A store whose `save` never settles until released, so a debounce can be observed mid-write. */
export class BlockingCursorStore implements ImCursorStore {
  readonly saves: ImCursorSnapshot[] = [];
  private release: (() => void) | null = null;

  load(): ImCursorSnapshot {
    return emptySnapshot();
  }

  save(snapshot: ImCursorSnapshot): Promise<void> {
    this.saves.push(structuredClone(snapshot));
    return new Promise<void>((resolve) => {
      this.release = resolve;
    });
  }

  finish(): void {
    this.release?.();
    this.release = null;
  }
}

export function clientOptions(overrides: Partial<ImClientOptions> = {}): ImClientOptions {
  return {
    endpoint: 'wss://im.test',
    appId: 'demo',
    userId: 'alice',
    token: 'token-1',
    deviceId: 'device-1',
    platform: 5,
    requestTimeoutMs: 300,
    cursorStore: new RecordingCursorStore(),
    webSocketImpl: FakeSocket as unknown as typeof WebSocket,
    // Write through, so a test asserting "the store has it" is asserting behaviour rather than
    // waiting out a timer. The debounce itself is covered separately.
    cursorFlushIntervalMs: 0,
    random: () => 0,
    ...overrides,
  };
}

/** Every client a test opened, so teardown can close them. See the note in gap-repair.test.ts. */
export const opened: ImClient[] = [];

export function closeAll(): void {
  while (opened.length) opened.pop()!.disconnect();
}

export interface OpenedClient {
  client: ImClient;
  delivered: ImMessage[];
  reloads: string[];
  errors: string[];
}

/**
 * Opens a client and settles the `conn.sync` that fires on every `open`, so a test starts from a
 * known cursor rather than racing the resume protocol.
 *
 * Pass `resume: null` to leave the first `conn.sync` unanswered — useful when the test wants to
 * drive the paging itself.
 */
export async function openClient(
  overrides: Partial<ImClientOptions> = {},
  resume: unknown = { conversations: [], gapsFrom: {}, hasMore: false },
): Promise<OpenedClient> {
  const client = new ImClient(clientOptions(overrides));
  opened.push(client);

  const delivered: ImMessage[] = [];
  const reloads: string[] = [];
  const errors: string[] = [];

  client.onMessage((m) => delivered.push(m));
  client.onConversationNeedsReload((id) => reloads.push(id));
  client.onError((e) => errors.push(`${e.code}:${e.message}`));

  void client.connect();
  await until(() => FakeSocket.instances.length > 0);
  FakeSocket.latest.open();
  await until(() => client.state === 'open');

  if (resume !== null) {
    await until(() => FakeSocket.latest.requestsTo('conn.sync').length > 0);
    FakeSocket.latest.replyLatest('conn.sync', resume);
  }

  return { client, delivered, reloads, errors };
}
