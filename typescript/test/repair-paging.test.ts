import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { FakeSocket, message, until } from './fake-socket.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';

/**
 * CONTRACT §5.9 — `msg.sync` pages too, and the repair loop must page with it.
 *
 * `MessageService.SyncAsync` clamps `limit` to 500, so a 1,200-seq repair asked for in one call
 * silently returns 500 messages and leaves 700 as a permanent hole — the exact failure the repair
 * existed to prevent. And `hasMore` is computed on the **raw** window, before per-user hidden
 * messages are filtered out, so `messages` can be shorter than `limit` — even empty — while the
 * range is not finished. Loop on `hasMore`, never on `messages.length`.
 *
 * 服务端把 limit 夹到 500，并且 hasMore 是在过滤"对本人隐藏的消息"之前算的：
 * 返回条数少于 limit 完全正常。按 hasMore 循环，不要按 messages.length。
 */

function range(conversationId: string, from: number, to: number): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (let seq = from; seq <= to; seq++) out.push(message(conversationId, seq));
  return out;
}

describe('gap repair paging', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('keeps calling msg.sync until hasMore is false, respecting the 500 server ceiling', async () => {
    const store = new RecordingCursorStore({ convSeqs: { c1: 100 }, conversationCursor: 0 });
    const { delivered } = await openClient({ cursorStore: store, maxAutoRepairSeq: 2000 }, {
      conversations: [{ conversationId: 'c1', maxSeq: 1300, updatedAt: 1 }],
      gapsFrom: { c1: 101 },
      hasMore: false,
    });

    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('msg.sync').length === 1);
    let request = socket.requestsTo('msg.sync')[0]!;
    assert.equal(request.body.fromSeq, 101);
    assert.equal(request.body.toSeq, 1300);
    // 1200 remaining, but the server would clamp anything above 500 and return 500 anyway.
    assert.equal(request.body.limit, 500);
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: range('c1', 101, 600),
      maxSeq: 1300,
      hasMore: true,
    });

    await until(() => socket.requestsTo('msg.sync').length === 2);
    request = socket.requestsTo('msg.sync')[1]!;
    assert.equal(request.body.fromSeq, 601);
    assert.equal(request.body.limit, 500);
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: range('c1', 601, 1100),
      maxSeq: 1300,
      hasMore: true,
    });

    await until(() => socket.requestsTo('msg.sync').length === 3);
    request = socket.requestsTo('msg.sync')[2]!;
    assert.equal(request.body.fromSeq, 1101);
    assert.equal(request.body.limit, 200);
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: range('c1', 1101, 1300),
      maxSeq: 1300,
      hasMore: false,
    });

    await until(() => delivered.length === 1200);
    assert.equal(delivered[0]!.seq, 101);
    assert.equal(delivered[delivered.length - 1]!.seq, 1300);
    assert.equal(socket.requestsTo('msg.sync').length, 3);
  });

  it('does not end the repair because a page held fewer messages than the limit', async () => {
    const store = new RecordingCursorStore({ convSeqs: { c1: 0 }, conversationCursor: 0 });
    const { delivered } = await openClient({ cursorStore: store }, {
      conversations: [{ conversationId: 'c1', maxSeq: 10, updatedAt: 1 }],
      gapsFrom: { c1: 1 },
      hasMore: false,
    });

    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('msg.sync').length === 1);
    let request = socket.requestsTo('msg.sync')[0]!;
    assert.equal(request.body.limit, 10);

    // Two of ten. The other eight in this window were hidden for this user, and hasMore says so.
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 1), message('c1', 2)],
      maxSeq: 10,
      hasMore: true,
    });

    await until(() => socket.requestsTo('msg.sync').length === 2);
    request = socket.requestsTo('msg.sync')[1]!;
    assert.equal(request.body.fromSeq, 3);
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: range('c1', 3, 10),
      maxSeq: 10,
      hasMore: false,
    });

    await until(() => delivered.length === 10);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  it('gives up and asks for a reload rather than spinning on a server that never says hasMore false', async () => {
    // A guard, not a feature. The alternative is a client that burns a phone's battery on a bug it
    // cannot fix, and never tells anyone.
    const store = new RecordingCursorStore({ convSeqs: { c1: 0 }, conversationCursor: 0 });
    const { client, reloads } = await openClient({ cursorStore: store }, {
      conversations: [{ conversationId: 'c1', maxSeq: 400, updatedAt: 1 }],
      gapsFrom: { c1: 1 },
      hasMore: false,
    });

    const socket = FakeSocket.latest;

    // Always "there is more", never any progress. One page is enough: the loop detects that the
    // next cursor would not move and stops immediately.
    await until(() => socket.requestsTo('msg.sync').length === 1);
    const request = socket.requestsTo('msg.sync')[0]!;
    socket.reply(request.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [],
      maxSeq: 0,
      hasMore: true,
    });

    await until(() => reloads.length === 1);
    assert.deepEqual(reloads, ['c1']);
    assert.equal(client.committedSeq('c1'), 400);
  });

  it('leaves the gap for the next conn.sync when a repair call fails outright', async () => {
    // The repair is best effort; the cursor is not. `committedSeq` has not moved, so the next
    // `conn.sync` reports the same gap and the repair runs again from a clean state. That safety
    // net is the reason the two cursors are separate.
    const store = new RecordingCursorStore({ convSeqs: { c1: 100 }, conversationCursor: 0 });
    const { client } = await openClient({ cursorStore: store }, {
      conversations: [{ conversationId: 'c1', maxSeq: 105, updatedAt: 1 }],
      gapsFrom: { c1: 101 },
      hasMore: false,
    });

    const socket = FakeSocket.latest;
    await until(() => socket.requestsTo('msg.sync').length === 1);
    const request = socket.requestsTo('msg.sync')[0]!;
    socket.reply(request.id, 'msg.sync', null, 1000, { message: 'boom' });

    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(client.committedSeq('c1'), 100);
    assert.equal(client.deliveredSeq('c1'), 100);
  });
});
