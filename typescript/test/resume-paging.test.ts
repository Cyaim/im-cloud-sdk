import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { FakeSocket, until } from './fake-socket.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';

/**
 * CONTRACT §5.6 — the `conn.sync` run pages, and `conversationCursor` moves only when it finishes.
 *
 * Both halves were missing from all five SDKs, and each is its own silent loss. `conn.sync` returns
 * at most 200 conversations a page, so a user with more than that got gaps reported only for the
 * first page. And the list is sorted by `updatedAt` **descending** — page 1 holds the newest
 * timestamp — so a client that takes the maximum from page 1 and stops has pushed the cursor past
 * every conversation on pages 2…N, which `ListUserConversationsAsync` then filters out for good.
 *
 * 会话列表按 updatedAt 倒序分页：只读第一页就把游标推到最新，后面几页的会话服务端再也不会返回。
 * 重读一页是免费的，跳过一页是永久的。
 */

function conversation(id: string, maxSeq: number, updatedAt: number) {
  return { conversationId: id, maxSeq, updatedAt };
}

describe('conn.sync paging', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('keeps paging until hasMore is false, and repairs gaps from every page', async () => {
    const store = new RecordingCursorStore({
      convSeqs: { c1: 10, c2: 20, c3: 30 },
      conversationCursor: 1,
    });
    await openClient({ cursorStore: store }, null);
    const socket = FakeSocket.latest;

    // Page 1 — newest updatedAt, because the server sorts descending.
    await until(() => socket.requestsTo('conn.sync').length === 1);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c1', 12, 3000)],
      gapsFrom: { c1: 11 },
      hasMore: true,
      nextCursor: 'p2',
    });

    await until(() => socket.requestsTo('conn.sync').length === 2);
    assert.equal(socket.requestsTo('conn.sync')[1]!.body.cursor, 'p2');
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c2', 22, 2000)],
      gapsFrom: { c2: 21 },
      hasMore: true,
      nextCursor: 'p3',
    });

    await until(() => socket.requestsTo('conn.sync').length === 3);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c3', 32, 1000)],
      gapsFrom: { c3: 31 },
      hasMore: false,
    });

    // A gap from every page, not just the first.
    await until(() => socket.requestsTo('msg.sync').length === 3);
    assert.deepEqual(
      socket.requestsTo('msg.sync').map((r) => r.body.conversationId),
      ['c1', 'c2', 'c3'],
    );
  });

  it('does not stop paging because a page returned fewer items than the limit', async () => {
    // `ConversationService.ListAsync` computes the paging cursor on the raw page, *before* deleted
    // conversations are filtered out. A short page with hasMore: true is therefore normal, and a
    // client that stops on `items.length < limit` stops early on a perfectly healthy response.
    const store = new RecordingCursorStore({ convSeqs: { c9: 1 }, conversationCursor: 0 });
    await openClient({ cursorStore: store, syncPageLimit: 200 }, null);
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('conn.sync').length === 1);
    assert.equal(socket.requestsTo('conn.sync')[0]!.body.limit, 200);

    socket.replyLatest('conn.sync', {
      conversations: [conversation('c9', 5, 9000)],
      gapsFrom: {},
      hasMore: true,
      nextCursor: 'p2',
    });

    await until(() => socket.requestsTo('conn.sync').length === 2);
  });

  it('advances conversationCursor to the maximum across the whole run, once it completes', async () => {
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store }, null);
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('conn.sync').length === 1);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c1', 1, 3000)],
      gapsFrom: {},
      hasMore: true,
      nextCursor: 'p2',
    });

    await until(() => socket.requestsTo('conn.sync').length === 2);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c2', 1, 2000)],
      gapsFrom: {},
      hasMore: false,
    });

    await until(() => client.cursorSnapshot().conversationCursor === 3000);
    assert.equal(store.last?.conversationCursor, 3000);
  });

  it('leaves conversationCursor untouched when a run is interrupted', async () => {
    // Page 1 carries the newest timestamp. Taking it and stopping would tell the server "I have
    // seen everything up to 3000", and pages 2…N — all older — would never be returned again.
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store }, null);
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('conn.sync').length === 1);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c1', 1, 3000)],
      gapsFrom: {},
      hasMore: true,
      nextCursor: 'p2',
    });

    await until(() => socket.requestsTo('conn.sync').length === 2);
    const second = socket.requestsTo('conn.sync')[1]!;
    socket.reply(second.id, 'conn.sync', null, 1000, { message: 'boom' });

    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(client.cursorSnapshot().conversationCursor, 0);

    // The adoption from page 1 was written; the cursor was not. Re-reading page 1 next time is
    // free, and it is the only way pages 2…N are ever seen.
    assert.equal(store.last?.convSeqs['c1'], 1);
    assert.equal(store.last?.conversationCursor, 0);
  });

  it('refuses to complete a run the server said had more pages but gave no cursor', async () => {
    const store = new RecordingCursorStore();
    const { client, errors } = await openClient({ cursorStore: store }, null);
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('conn.sync').length === 1);
    socket.replyLatest('conn.sync', {
      conversations: [conversation('c1', 1, 3000)],
      gapsFrom: {},
      hasMore: true,
    });

    await until(() => errors.length > 0);
    assert.match(errors[0]!, /hasMore with no nextCursor/);
    assert.equal(client.cursorSnapshot().conversationCursor, 0);
  });

  it('sends the cursors it has adopted so far on each subsequent page', async () => {
    // Each page's gaps are computed server-side from the convSeqs in *that* request, so a
    // conversation adopted on page 1 must be reported as known on page 2 or the server will offer
    // to repair a range the client has already declined to need.
    const store = new RecordingCursorStore();
    await openClient({ cursorStore: store }, null);
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('conn.sync').length === 1);
    assert.deepEqual(socket.requestsTo('conn.sync')[0]!.body.convSeqs, {});

    socket.replyLatest('conn.sync', {
      conversations: [conversation('c1', 77, 3000)],
      gapsFrom: {},
      hasMore: true,
      nextCursor: 'p2',
    });

    await until(() => socket.requestsTo('conn.sync').length === 2);
    assert.deepEqual(socket.requestsTo('conn.sync')[1]!.body.convSeqs, { c1: 77 });
  });
});
