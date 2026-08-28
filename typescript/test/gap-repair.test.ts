import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { FakeSocket, message, until } from './fake-socket.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';

/**
 * Live gap detection and the resume run, from the application's side.
 *
 * The helpers moved to `doubles.ts` when the cursor store arrived, because five files now need the
 * same "open a client and settle its resume" sequence. The teardown note that used to live here
 * still applies and is worth repeating: an open client holds a 30s heartbeat interval, and in Node
 * a live timer keeps the process alive — leaving one behind makes the run wait out the interval
 * before it can exit.
 */

describe('gap repair', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('fetches a skipped range before delivering the message that revealed it', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('s_a_b', 1));
    await until(() => delivered.length === 1);

    // 2 and 3 never arrived.
    socket.push('evt.message', message('s_a_b', 4));
    await until(() => socket.requestsTo('msg.sync').length > 0);

    const repair = socket.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.conversationId, 's_a_b');
    assert.equal(repair.body.fromSeq, 2);
    assert.equal(repair.body.toSeq, 3);

    socket.reply(repair.id, 'msg.sync', {
      conversationId: 's_a_b',
      messages: [message('s_a_b', 2), message('s_a_b', 3)],
      hasMore: false,
    });

    await until(() => delivered.length === 4);
    // The application never sees the conversation jump forward and then fill in behind it.
    assert.deepEqual(delivered.map((m) => m.seq), [1, 2, 3, 4]);
  });

  it('still delivers the triggering message when the repair itself fails', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('s_a_b', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.message', message('s_a_b', 4));
    await until(() => socket.requestsTo('msg.sync').length > 0);

    const repair = socket.requestsTo('msg.sync')[0]!;
    socket.reply(repair.id, 'msg.sync', null, 1000, { message: 'boom' });

    // Stalling the conversation because a backfill failed would be worse than the gap. The gap is
    // not lost: `committedSeq` never moved past it, so the next `conn.sync` reports it again.
    await until(() => delivered.length === 2);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 4]);
  });

  it('drops a duplicate seq silently', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('s_a_b', 1));
    await until(() => delivered.length === 1);

    // Normal after a reconnect replay, and must not reach the application twice.
    socket.push('evt.message', message('s_a_b', 1));
    await new Promise((resolve) => setTimeout(resolve, 60));

    assert.equal(delivered.length, 1);
  });

  it('delivers an unpersisted message (seq 0) without moving the cursor', async () => {
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    // Typing, presence and chat-room traffic are never persisted and carry seq 0. Letting one move
    // the cursor would fabricate a gap for the next real message.
    socket.push('evt.message', message('s_a_b', 0));
    socket.push('evt.message', message('s_a_b', 1));

    await until(() => delivered.length === 2);
    assert.deepEqual(delivered.map((m) => m.seq), [0, 1]);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
  });

  it('accepts the jump and asks for a reload when the gap is larger than the limit', async () => {
    const { delivered, reloads } = await openClient({ maxAutoRepairSeq: 10 });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('s_a_b', 1));
    await until(() => delivered.length === 1);

    // Replaying fifty thousand messages to catch up helps nobody; the app reloads from history —
    // which it can only do because it is told to. Advancing the cursor in silence, as this SDK
    // used to, leaves a hole nothing will ever mention.
    socket.push('evt.message', message('s_a_b', 50_000));
    await until(() => delivered.length === 2);

    assert.equal(socket.requestsTo('msg.sync').length, 0);
    assert.deepEqual(delivered.map((m) => m.seq), [1, 50_000]);
    assert.deepEqual(reloads, ['s_a_b']);
  });
});

describe('resume after reconnect', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('repairs every conversation the server reports in gapsFrom', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 4));
    await until(() => delivered.length === 1);

    // The application stores it, then says so. Until it does, `convSeqs` reports nothing for this
    // conversation — which is the point of the two cursors, not a gap in the test.
    client.commit('c1', 4);
    await client.flushCursors();

    socket.die();
    await until(() => FakeSocket.instances.length >= 2);

    const next = FakeSocket.latest;
    next.open();
    await until(() => next.requestsTo('conn.sync').length > 0);

    // The client reports where it is, per conversation.
    const sync = next.requestsTo('conn.sync')[0]!;
    assert.deepEqual(sync.body.convSeqs, { c1: 4 });

    // gapsFrom carries only the first seq we are missing; the upper bound is that conversation's
    // maxSeq in the same reply (SPEC-02 §3.4).
    next.reply(sync.id, 'conn.sync', {
      conversations: [{ conversationId: 'c1', maxSeq: 6, updatedAt: 1767225600000 }],
      gapsFrom: { c1: 5 },
      hasMore: false,
    });

    await until(() => next.requestsTo('msg.sync').length > 0);
    const repair = next.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.fromSeq, 5);
    assert.equal(repair.body.toSeq, 6);

    next.reply(repair.id, 'msg.sync', {
      conversationId: 'c1',
      messages: [message('c1', 5), message('c1', 6)],
      hasMore: false,
    });

    await until(() => delivered.length === 3);
    assert.deepEqual(delivered.map((m) => m.seq), [4, 5, 6]);
  });

  it('adopts the position of a conversation it is seeing for the first time', async () => {
    // Replaying the whole history of a conversation this device has never opened would be the
    // slowest possible way to show a chat list.
    const { client, delivered } = await openClient(
      {},
      {
        conversations: [{ conversationId: 'brand-new', maxSeq: 812, updatedAt: 1767225600000 }],
        gapsFrom: {},
        hasMore: false,
      },
    );

    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
    assert.deepEqual(delivered, []);

    // And the next real message lands contiguously rather than looking like an 812-wide gap.
    FakeSocket.latest.push('evt.message', message('brand-new', 813));
    await until(() => delivered.length === 1);
    assert.equal(FakeSocket.latest.requestsTo('msg.sync').length, 0);
    assert.equal(client.state, 'open');
  });

  it('leaves cursors untouched when resume fails, so the next message repairs normally', async () => {
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 4));
    await until(() => delivered.length === 1);
    client.commit('c1', 4);
    await client.flushCursors();

    socket.die();
    await until(() => FakeSocket.instances.length >= 2);

    const next = FakeSocket.latest;
    next.open();
    await until(() => next.requestsTo('conn.sync').length > 0);
    next.reply(next.requestsTo('conn.sync')[0]!.id, 'conn.sync', null, 1000, { message: 'boom' });

    // Cursor still at 4, so a message at 7 is still recognised as a gap.
    next.push('evt.message', message('c1', 7));
    await until(() => next.requestsTo('msg.sync').length > 0);

    const repair = next.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.fromSeq, 5);
    assert.equal(repair.body.toSeq, 6);
  });
});

describe('sending', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('generates a clientMsgId so a naive caller still gets exactly-once semantics', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.send({ receiverId: 'bob', content: { text: 'hello' } });
    await until(() => socket.requestsTo('msg.send').length > 0);

    const request = socket.requestsTo('msg.send')[0]!;
    assert.equal(typeof request.body.clientMsgId, 'string');
    assert.ok((request.body.clientMsgId as string).length > 0);
    assert.deepEqual(request.body.content, { text: 'hello' });
    assert.equal(request.body.contentType, 1);

    socket.reply(request.id, 'msg.send', {
      messageId: 9,
      seq: 1,
      conversationId: 's_a_b',
      clientMsgId: request.body.clientMsgId,
      createTime: 1,
    });

    const result = await pending;
    assert.equal(result.seq, 1);
  });

  it('does not redeliver our own message when the server echoes it back', async () => {
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.sendText({ receiverId: 'bob' }, 'hello');
    await until(() => socket.requestsTo('msg.send').length > 0);

    const request = socket.requestsTo('msg.send')[0]!;
    socket.reply(request.id, 'msg.send', {
      messageId: 9,
      seq: 1,
      conversationId: 's_a_b',
      clientMsgId: request.body.clientMsgId,
      createTime: 1,
    });
    await pending;

    // Sending advanced deliveredSeq to 1, so the echo is a duplicate and is dropped. It did *not*
    // advance committedSeq: the application has not stored it yet, and only it knows when it has.
    socket.push('evt.message', message('s_a_b', 1));
    await new Promise((resolve) => setTimeout(resolve, 60));

    assert.deepEqual(delivered, []);
    assert.equal(client.deliveredSeq('s_a_b'), 1);
    assert.equal(client.committedSeq('s_a_b'), 0);
  });
});
