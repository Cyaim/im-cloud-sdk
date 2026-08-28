import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { ImClient } from '../src/client.js';
import { ImCursorScope, ImCursorStore } from '../src/cursors.js';
import { FakeSocket, message, until } from './fake-socket.js';
import {
  BlockingCursorStore,
  RecordingCursorStore,
  clientOptions,
  closeAll,
  openClient,
  opened,
} from './doubles.js';

/**
 * CONTRACT §5 — the cold-start cursor model.
 *
 * Every test here is a shape of the same bug: a client that reports the wrong position, or no
 * position at all, gets no gap from the server (`ConnController.Sync` only emits a gap for a
 * conversation the client claims a seq in) and then adopts the server's `maxSeq` on its own
 * first-sight branch. Everything in between is behind the cursor forever, with no error, no log
 * line and no later event that corrects it.
 *
 * 每个用例都是同一个 bug 的不同形状：客户端不报位置 → 服务端不报缺口 → 客户端自己采纳
 * 服务端的 maxSeq → 中间那段永远拿不回来，而且没有任何报错。
 */
describe('cold start', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('restores cursors from the store and reports them in the first conn.sync', async () => {
    // THE regression test. Before the cursor store existed, `maxSeq` was a private Map with no
    // accessor and no persistence, so this body was `{}` on every launch.
    const store = new RecordingCursorStore({ convSeqs: { c1: 100 }, conversationCursor: 1767225600000 });
    await openClient({ cursorStore: store });

    const sync = FakeSocket.latest.requestsTo('conn.sync')[0]!;
    assert.deepEqual(sync.body.convSeqs, { c1: 100 });
    assert.equal(sync.body.conversationCursor, 1767225600000);
  });

  it('stamps every snapshot it writes with (host, appId, userId)', async () => {
    // Not the device id — the store is already local to the device. `userId` is the part that
    // stops account switching on a shared handset handing one user the other's cursors, and it
    // travels in the snapshot rather than through a hook on the store, so a store that never
    // heard of scoping still cannot defeat it.
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store, userId: 'bob' });

    assert.equal(store.loadCount, 1);
    await client.commit('c1', 5);
    await client.flushCursors();

    assert.equal(store.last?.scope, 'im.test|demo|bob');
  });

  it('refuses cursors belonging to a different account on the same store', async () => {
    // The account-switch guarantee, CONTRACT §5.3. Alice signed out, Bob signed in, and the app
    // pointed both at one store. Replaying Alice's position into Bob's client would mark messages
    // Bob has never seen as already consumed — one person's cursors replaying into another
    // person's client, silently and permanently.
    const warnings: string[] = [];
    const original = console.warn;
    console.warn = (...args: unknown[]) => void warnings.push(args.join(' '));

    try {
      const store = new RecordingCursorStore({
        convSeqs: { c1: 100 },
        conversationCursor: 1767225600000,
        scope: 'im.test|demo|alice',
      });

      const { client } = await openClient({ cursorStore: store, userId: 'bob' });

      const sync = FakeSocket.latest.requestsTo('conn.sync')[0]!;
      assert.deepEqual(sync.body.convSeqs, {}, "Bob must not report Alice's position");
      assert.equal(sync.body.conversationCursor, 0);
      assert.equal(client.restoredConversations, 0);
      assert.equal(client.cursorScopeRejected, true);
      assert.equal(client.cursorStoreFailed, false);
      assert.ok(warnings.some((line) => /im.test\|demo\|alice/.test(line) && /§5\.3/.test(line)));
    } finally {
      console.warn = original;
    }
  });

  it('accepts a snapshot stamped with this session own scope', async () => {
    const store = new RecordingCursorStore({
      convSeqs: { c1: 100 },
      conversationCursor: 7,
      scope: 'im.test|demo|bob',
    });

    const { client } = await openClient({ cursorStore: store, userId: 'bob' });

    const sync = FakeSocket.latest.requestsTo('conn.sync')[0]!;
    assert.deepEqual(sync.body.convSeqs, { c1: 100 });
    assert.equal(client.cursorScopeRejected, false);
  });

  it('reads the store exactly once, however many times connect is called', async () => {
    const store = new RecordingCursorStore({ convSeqs: { c1: 7 }, conversationCursor: 0 });
    const { client } = await openClient({ cursorStore: store });

    await client.connect();
    await client.connect();

    assert.equal(store.loadCount, 1);
  });

  it('warns once and reports nothing restored when the store is the in-memory one', async () => {
    const warnings: string[] = [];
    const original = console.warn;
    console.warn = (...args: unknown[]) => void warnings.push(args.join(' '));

    try {
      const { client } = await openClient({ cursorStore: ImCursorStore.inMemory() });

      // The application can see that it started from nothing, which is the difference between
      // "fresh install" and "we quietly lost your cursors".
      assert.equal(client.restoredConversations, 0);
      assert.equal(client.cursorStoreFailed, false);
      assert.equal(warnings.length, 1);
      assert.match(warnings[0]!, /not persisted/);
      assert.match(warnings[0]!, /§5\.3/);
    } finally {
      console.warn = original;
    }
  });

  it('does not adopt anything when the store fails to load', async () => {
    // A failed load and a fresh install are indistinguishable to the adoption branch, and adopting
    // on a failed load destroys history sitting intact in the application's own database.
    const store = new RecordingCursorStore(undefined, new Error('disk on fire'));
    const { client, errors } = await openClient({ cursorStore: store }, null);

    await until(() => errors.length > 0);
    assert.match(errors[0]!, /cursor store load failed/);
    assert.equal(client.cursorStoreFailed, true);

    // Nothing is asked for, nothing is adopted, nothing is written. The application decides
    // whether to re-derive its cursors (the correct fix) or accept a re-download.
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(FakeSocket.latest.requestsTo('conn.sync').length, 0);
    assert.deepEqual(store.saves, []);

    // And a live message still reaches the application — degraded means no cursors, not no chat.
    FakeSocket.latest.push('evt.message', message('c1', 9));
    await until(() => client.deliveredSeq('c1') === 9);
    assert.equal(client.committedSeq('c1'), 0);
  });

  it('refuses to persist a cursor for the rest of a session whose load failed', async () => {
    const store = new RecordingCursorStore(undefined, new Error('disk on fire'));
    const { client } = await openClient({ cursorStore: store }, null);

    client.commit('c1', 42);
    await client.flushCursors();

    assert.deepEqual(store.saves, []);
    assert.equal(client.committedSeq('c1'), 0);
  });
});

describe('adoption', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('flushes the adoption write before requesting the next conn.sync page', async () => {
    // Adoption is the one commit that may not be debounced. If its write is lost, the next cold
    // start sees no entry, adopts a *newer* maxSeq, and silently drops everything in between —
    // the original bug, recreated by the optimisation.
    //
    // The store below blocks inside `save`, so "the next page did not go out yet" is observable
    // rather than inferred from an ordering that a poll could never see.
    const store = new BlockingCursorStore();
    await openClient({ cursorStore: store }, null);

    const socket = FakeSocket.latest;
    await until(() => socket.requestsTo('conn.sync').length === 1);

    socket.replyLatest('conn.sync', {
      conversations: [{ conversationId: 'brand-new', maxSeq: 812, updatedAt: 1767225600000 }],
      gapsFrom: {},
      hasMore: true,
      nextCursor: 'page-2',
    });

    await until(() => store.saves.length === 1);
    assert.equal(store.saves[0]!.convSeqs['brand-new'], 812);

    // Still one request: the run is parked on the adoption write.
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(socket.requestsTo('conn.sync').length, 1);

    store.finish();
    await until(() => socket.requestsTo('conn.sync').length === 2);
    assert.equal(socket.requestsTo('conn.sync')[1]!.body.cursor, 'page-2');
  });

  it('adopts a first-sight conversation instead of replaying its whole history', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store }, {
      conversations: [{ conversationId: 'brand-new', maxSeq: 812, updatedAt: 1767225600000 }],
      gapsFrom: {},
      hasMore: false,
    });

    await until(() => client.committedSeq('brand-new') === 812);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
    assert.deepEqual(delivered, []);

    // The next real message lands contiguously rather than looking like an 812-wide gap.
    FakeSocket.latest.push('evt.message', message('brand-new', 813));
    await until(() => delivered.length === 1);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
  });

  it('does not re-adopt a conversation the store already knows, whatever the server reports', async () => {
    const store = new RecordingCursorStore({ convSeqs: { c1: 4 }, conversationCursor: 0 });
    const { client } = await openClient({ cursorStore: store }, {
      conversations: [{ conversationId: 'c1', maxSeq: 6, updatedAt: 1767225600000 }],
      gapsFrom: {},
      hasMore: false,
    });

    // Adopting here would jump the cursor to 6 and lose 5 and 6 — the bug, arriving through the
    // branch that is supposed to be the *safe* one.
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(client.committedSeq('c1'), 4);
  });
});

describe('the two cursors', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('reports committedSeq in convSeqs, never deliveredSeq', async () => {
    // `docs/SPEC-02-protocol.md` §3.3: convSeqs 报的是已落库的 seq，不是收到过的 seq.
    const store = new RecordingCursorStore({ convSeqs: { c1: 3 }, conversationCursor: 0 });
    const { client, delivered } = await openClient({ cursorStore: store });

    FakeSocket.latest.push('evt.message', message('c1', 4));
    FakeSocket.latest.push('evt.message', message('c1', 5));
    await until(() => delivered.length === 2);

    assert.equal(client.deliveredSeq('c1'), 5);
    assert.equal(client.committedSeq('c1'), 3);

    FakeSocket.latest.die();
    await until(() => FakeSocket.instances.length >= 2);
    const next = FakeSocket.latest;
    next.open();
    await until(() => next.requestsTo('conn.sync').length > 0);

    assert.deepEqual(next.requestsTo('conn.sync')[0]!.body.convSeqs, { c1: 3 });
  });

  it('resets delivered to committed on reconnect, so an uncommitted message is delivered again', async () => {
    // Without the reset the redelivery we just asked for is dropped as a duplicate by the very
    // cursor that was too far ahead.
    const store = new RecordingCursorStore({ convSeqs: { c1: 3 }, conversationCursor: 0 });
    const { client, delivered } = await openClient({ cursorStore: store });

    FakeSocket.latest.push('evt.message', message('c1', 4));
    FakeSocket.latest.push('evt.message', message('c1', 5));
    await until(() => delivered.length === 2);

    FakeSocket.latest.die();
    await until(() => FakeSocket.instances.length >= 2);
    const next = FakeSocket.latest;
    next.open();
    await until(() => next.requestsTo('conn.sync').length > 0);

    assert.equal(client.deliveredSeq('c1'), 3);

    next.replyLatest('conn.sync', {
      conversations: [{ conversationId: 'c1', maxSeq: 5, updatedAt: 1767225600000 }],
      gapsFrom: { c1: 4 },
      hasMore: false,
    });

    await until(() => next.requestsTo('msg.sync').length > 0);
    const repair = next.requestsTo('msg.sync')[0]!;
    next.reply(repair.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 4), message('c1', 5)],
      maxSeq: 5,
      hasMore: false,
    });

    await until(() => delivered.length === 4);
    assert.deepEqual(delivered.map((m) => m.seq), [4, 5, 4, 5]);
  });

  it('ignores a commit that would walk a cursor backwards', async () => {
    // Monotonic, and not an error: an app re-deriving its cursors from its own database on startup
    // is the recommended repair after a load failure, and it must be safe to run unconditionally.
    const { client } = await openClient();

    client.commit('c1', 10);
    client.commit('c1', 4);
    assert.equal(client.committedSeq('c1'), 10);
  });

  it('never lets a seq-0 message touch either cursor', async () => {
    // Typing, presence and chat-room traffic are never persisted. Letting one move a cursor would
    // fabricate a gap for the next real message.
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });

    FakeSocket.latest.push('evt.message', message('room-1', 0));
    FakeSocket.latest.push('evt.message', message('room-1', 0));
    await until(() => delivered.length === 2);

    assert.equal(client.deliveredSeq('room-1'), 0);
    assert.equal(client.committedSeq('room-1'), 0);
    assert.deepEqual(store.saves, []);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
  });

  it('persists a commit through the store', async () => {
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store });

    client.commit('c1', 12);
    await client.flushCursors();

    assert.equal(store.last?.convSeqs['c1'], 12);
    assert.deepEqual(client.cursorSnapshot().convSeqs, { c1: 12 });
  });

  it('coalesces commits behind the debounce and still flushes before conn.sync', async () => {
    // A lost debounced commit costs one duplicate delivery; a lost adoption write costs silent
    // permanent data loss. That asymmetry is why one of these is allowed to be late.
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store, cursorFlushIntervalMs: 50 });

    client.commit('c1', 1);
    client.commit('c1', 2);
    client.commit('c1', 3);
    assert.deepEqual(store.saves, [], 'three commits inside the window must not be three writes');

    FakeSocket.latest.die();
    await until(() => FakeSocket.instances.length >= 2);
    FakeSocket.latest.open();
    await until(() => FakeSocket.latest.requestsTo('conn.sync').length > 0);

    // The flush before conn.sync is one of the three points a debounced write may not be late for.
    assert.equal(store.last?.convSeqs['c1'], 3);
    assert.deepEqual(FakeSocket.latest.requestsTo('conn.sync')[0]!.body.convSeqs, { c1: 3 });
  });
});

describe('oversized gaps', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('advances the cursor and raises conversationNeedsReload on the resume path', async () => {
    const store = new RecordingCursorStore({ convSeqs: { c1: 4 }, conversationCursor: 0 });
    const { client, reloads } = await openClient({ cursorStore: store, maxAutoRepairSeq: 10 }, {
      conversations: [{ conversationId: 'c1', maxSeq: 100_000, updatedAt: 1767225600000 }],
      gapsFrom: { c1: 5 },
      hasMore: false,
    });

    await until(() => reloads.length === 1);
    assert.deepEqual(reloads, ['c1']);

    // Both halves are mandatory: without the cursor advance every later message looks like a gap
    // and re-requests a range that has already been declined.
    assert.equal(client.committedSeq('c1'), 100_000);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
    assert.equal(store.last?.convSeqs['c1'], 100_000);
  });

  it('raises conversationNeedsReload on the live path too', async () => {
    // All five SDKs accepted this jump silently: the cursor stayed honest, but nothing ever told
    // the application that a stretch of the conversation had been skipped, so nothing reloaded it.
    // A hole nobody is told about is the same defect as a hole nobody repairs.
    const { client, delivered, reloads } = await openClient({ maxAutoRepairSeq: 10 });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.message', message('c1', 50_000));
    await until(() => delivered.length === 2);

    assert.deepEqual(reloads, ['c1']);
    assert.equal(socket.requestsTo('msg.sync').length, 0);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 50_000]);
    assert.equal(client.committedSeq('c1'), 49_999);
  });
});

describe('numbers that arrive as strings', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('treats a seq sent as a JSON string as a number', async () => {
    // `NumberHandling.AllowReadingFromString` is set server-side and JSON.parse has no schema, so
    // `seq` can legitimately be "4". Comparisons coerce and hide it; `seq + 1` produces "41" and
    // asks the server to repair a range that does not exist.
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.message', { ...message('c1', 4), seq: '4', messageId: '1004' });
    await until(() => socket.requestsTo('msg.sync').length > 0);

    const repair = socket.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.fromSeq, 2);
    assert.equal(repair.body.toSeq, 3);

    socket.reply(repair.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 2), message('c1', 3)],
      hasMore: false,
    });

    await until(() => delivered.length === 4);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2, 3, 4]);
    assert.equal(client.deliveredSeq('c1'), 4);
  });

  it('restores a cursor stored as a string rather than refusing to load', async () => {
    const store = new RecordingCursorStore({
      convSeqs: { c1: '100' as unknown as number },
      conversationCursor: '1767225600000' as unknown as number,
    });
    const { client } = await openClient({ cursorStore: store });

    assert.equal(client.committedSeq('c1'), 100);
    assert.deepEqual(FakeSocket.latest.requestsTo('conn.sync')[0]!.body.convSeqs, { c1: 100 });
  });
});

describe('cursor store factories', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('refuses to build a localStorage store where there is no localStorage', () => {
    // Degrading to nothing here would be the bug this file is about, wearing a helpful face.
    assert.equal(globalThis.localStorage, undefined, 'this test only means something under Node');
    assert.throws(
      () => ImCursorStore.localStorage(ImCursorScope.of('wss://im.test', 'demo', 'alice')),
      /needs globalThis.localStorage/,
    );
  });

  it('round-trips a snapshot through a file store', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');

    const directory = await mkdtemp(join(tmpdir(), 'im-cursors-'));
    try {
      const store = ImCursorStore.file(join(directory, 'cursors.json'));

      assert.deepEqual(await store.load(), { convSeqs: {}, conversationCursor: 0 });

      await store.save({ convSeqs: { c1: 42 }, conversationCursor: 7, scope: 'im.test|demo|alice' });
      assert.deepEqual(await store.load(), {
        convSeqs: { c1: 42 },
        conversationCursor: 7,
        scope: 'im.test|demo|alice',
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('carries a file store cursor across a client restart', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');

    const directory = await mkdtemp(join(tmpdir(), 'im-cursors-'));
    const path = join(directory, 'cursors.json');

    try {
      const first = new ImClient(clientOptions({ cursorStore: ImCursorStore.file(path) }));
      opened.push(first);
      void first.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.open();
      await until(() => FakeSocket.latest.requestsTo('conn.sync').length > 0);
      FakeSocket.latest.replyLatest('conn.sync', { conversations: [], gapsFrom: {}, hasMore: false });

      first.commit('c1', 250);
      await first.flushCursors();
      first.disconnect();

      // A whole new process, as far as the SDK is concerned.
      FakeSocket.reset();
      const second = new ImClient(clientOptions({ cursorStore: ImCursorStore.file(path) }));
      opened.push(second);
      void second.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.open();
      await until(() => FakeSocket.latest.requestsTo('conn.sync').length > 0);

      assert.deepEqual(FakeSocket.latest.requestsTo('conn.sync')[0]!.body.convSeqs, { c1: 250 });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
