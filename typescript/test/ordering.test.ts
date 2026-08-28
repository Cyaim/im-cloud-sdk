import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { FakeSocket, message, until } from './fake-socket.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';

/**
 * CONTRACT §7.6 — one rule above all others: **for a given conversation, messages reach the
 * application in `seq` order, and never concurrently with each other.**
 *
 * Everything here serves that. In particular a live message that arrives while a repair for the
 * same conversation is in flight is held and delivered after it, in seq order — otherwise the
 * application sees the conversation jump forward and then fill in behind it, which is exactly the
 * artefact the repair existed to prevent.
 *
 * 同一会话内按 seq 有序、不并发。补洞进行中到达的实时消息要排在补洞结果之后，
 * 否则界面会先跳到新消息、再往回填历史。
 */
describe('delivery ordering', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('delivers in seq order across a gap repair', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.message', message('c1', 5));
    await until(() => socket.requestsTo('msg.sync').length === 1);

    const repair = socket.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.fromSeq, 2);
    assert.equal(repair.body.toSeq, 4);
    socket.reply(repair.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 2), message('c1', 3), message('c1', 4)],
      hasMore: false,
    });

    await until(() => delivered.length === 5);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2, 3, 4, 5]);
  });

  it('holds live messages that arrive during a repair and delivers them behind it', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    // Reveals a gap; the repair goes out and stays unanswered for now.
    socket.push('evt.message', message('c1', 5));
    await until(() => socket.requestsTo('msg.sync').length === 1);

    // Two more arrive while the repair is in flight. Neither may overtake it.
    socket.push('evt.message', message('c1', 6));
    socket.push('evt.message', message('c1', 7));
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.deepEqual(delivered.map((m) => m.seq), [1]);

    const repair = socket.requestsTo('msg.sync')[0]!;
    socket.reply(repair.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 2), message('c1', 3), message('c1', 4)],
      hasMore: false,
    });

    await until(() => delivered.length === 7);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2, 3, 4, 5, 6, 7]);

    // And exactly one repair ran: two for one conversation would race each other's cursors.
    assert.equal(socket.requestsTo('msg.sync').length, 1);
  });

  it('does not serialise one conversation behind another', async () => {
    // Ordering is per conversation. A slow repair on `c1` must not stall `c2`.
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.message', message('c1', 9));
    await until(() => socket.requestsTo('msg.sync').length === 1);

    socket.push('evt.message', message('c2', 1));
    await until(() => delivered.length === 2);
    assert.equal(delivered[1]!.conversationId, 'c2');
  });

  it('keeps delivering after a listener throws', async () => {
    // One application bug in one handler must not stop delivery for every conversation, and must
    // never lose a cursor.
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });

    let thrown = 0;
    client.onMessage(() => {
      thrown++;
      throw new Error('the application has a bug');
    });

    const socket = FakeSocket.latest;
    socket.push('evt.message', message('c1', 1));
    socket.push('evt.message', message('c1', 2));

    await until(() => delivered.length === 2);
    assert.equal(thrown, 2);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2]);
    assert.equal(client.deliveredSeq('c1'), 2);
  });

  it('does not deadlock when a listener calls back into the SDK', async () => {
    // Reentrancy is legal. A listener that commits, or fetches a profile, or sends a read receipt
    // is the normal shape of an application, not an abuse of one.
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;

    let reply: Promise<number> | null = null;
    client.onMessage((m) => {
      client.commit(m.conversationId, m.seq);
      reply ??= client.conv.unreadTotal();
    });

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);
    assert.equal(client.committedSeq('c1'), 1);

    await until(() => socket.requestsTo('conv.unreadTotal').length === 1);
    socket.replyLatest('conv.unreadTotal', '12');

    // The server may write a long as a JSON string; the SDK hands back a number either way.
    assert.equal(await reply, 12);
  });

  it('never delivers synchronously inside the call that produced the frame', async () => {
    // Delivery is a microtask. A listener that runs inside `dispatch` would re-enter the socket's
    // own callback, and an application that then called `disconnect()` would be tearing down the
    // stack it is standing on.
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    assert.deepEqual(delivered, []);

    await until(() => delivered.length === 1);
  });
});
