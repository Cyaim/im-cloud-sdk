import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import type { BeginStreamRequest, SendMessageResult, StreamHandle } from '../src/models.js';
import { ImError, MessageContentType, MessagePriority } from '../src/protocol.js';
import {
  StreamAssembler,
  StreamPhase,
  StreamStatus,
  StreamWriter,
  readStreamEvent,
  type StreamEvent,
} from '../src/stream.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';
import { FakeSocket, message, until } from './fake-socket.js';
import { loadInventory } from './inventory.js';

/**
 * `msg.streamBegin` / `streamAppend` / `streamComplete` / `streamAbort` and the `evt.stream` push —
 * streaming replies, T4, typed whole.
 *
 * What a signature cannot say and this file pins: each call's exact frame (begin's `options` is
 * nested and bound by name as spelled, and its `clientMsgId` is the caller's, never generated); the
 * replies decoded with every field the server declares, held against `endpoint-inventory.json`; the
 * four phases of an `evt.stream` frame; putting fragments back together by index under everything the
 * server can do to their order — a shed fragment, a terminal frame that overtakes queued fragments, a
 * late join; and the split an integrator cannot guess: **the fragments are not messages and never
 * touch a cursor, while the message the stream completes into is an ordinary one that goes through
 * gap repair** — to the producer's own connection too, so completing must not mark it delivered.
 *
 * 签名说不出来、这里钉住的：每条调用的整帧（begin 的 options 嵌套、按原样拼写绑定，clientMsgId 由调用方给、
 * 从不生成）；答复每个字段对着清单核；evt.stream 的四个阶段；服务端能造成的各种乱序下按 index 拼回分片；
 * 以及集成方猜不到的那条——分片不是消息、不碰游标，收尾得到的消息是普通消息、要走补洞，
 * 生产者自己的连接也会收到它，所以收尾时不能先把它标成已投递。
 */

/** Above 2^53 and odd, so an id that went through a double on the way is visibly another id. */
const BIG = '360381357961969667';

/** Everything on a frame except its id, which is random. */
function frameOf(socket: FakeSocket, target: string, index = 0): { keys: string[]; target: string; body: unknown } {
  const raw = socket.sent.filter((frame) => JSON.parse(frame).target === target)[index];
  assert.ok(raw, `nothing was sent to ${target}`);
  const frame = JSON.parse(raw) as Record<string, unknown>;
  return { keys: Object.keys(frame), target: frame['target'] as string, body: frame['body'] };
}

/** The server's declared property names for a payload type, in its order. */
function declared(typeName: string): string[] {
  const type = loadInventory().payloadTypes[typeName];
  assert.ok(type, `endpoint-inventory.json has no payload type ${typeName}; regenerate it`);
  return type.properties.map((property) => property.name);
}

/**
 * `evt.stream` frames exactly as the server writes them (StreamBeginFrame / StreamDelta, camelCase,
 * nulls omitted, `done` always present, `messageId` quoted).
 */
const wire = {
  begin: (streamId: string, placeholder?: Record<string, unknown>, conversationId = 'c1'): Record<string, unknown> => ({
    streamId,
    conversationId,
    senderId: 'bot',
    index: 0,
    done: false,
    ...(placeholder ? { placeholder } : {}),
  }),
  delta: (streamId: string, index: number, delta: string, conversationId = 'c1'): Record<string, unknown> => ({
    streamId,
    conversationId,
    senderId: 'bot',
    index,
    delta,
    done: false,
  }),
  completed: (streamId: string, index: number, messageId: unknown, seq: unknown, conversationId = 'c1'): Record<string, unknown> => ({
    streamId,
    conversationId,
    senderId: 'bot',
    index,
    done: true,
    messageId,
    seq,
  }),
  aborted: (streamId: string, index: number, abortReason: string, conversationId = 'c1'): Record<string, unknown> => ({
    streamId,
    conversationId,
    senderId: 'bot',
    index,
    done: true,
    abortReason,
  }),
};

function event(frame: Record<string, unknown>): StreamEvent {
  const decoded = readStreamEvent(frame);
  assert.ok(decoded, `not decoded: ${JSON.stringify(frame)}`);
  return decoded;
}

/** A stored message as evt.message carries the finished stream: real seq, string id, `{ text }`. */
function finishedMessage(conversationId: string, seq: number, text: string, messageId = BIG): Record<string, unknown> {
  return {
    ...message(conversationId, seq),
    messageId,
    clientMsgId: 'stream-1',
    senderId: 'bot',
    content: { text },
  };
}

/**
 * Every field the server declares, set to a non-default value. `Required<>` makes the compiler insist
 * on every field of this SDK's type; the test below insists the same keys are the server's.
 */
const EVERY_HANDLE_FIELD: Required<StreamHandle> = {
  streamId: 'st_7f3a',
  conversationId: 'c_alice_bob',
  startedAt: 1761100000000,
  idleTimeoutSeconds: 30,
};

const EVERY_SEND_RESULT_FIELD: Required<SendMessageResult> = {
  messageId: BIG,
  seq: 42,
  conversationId: 'c_alice_bob',
  clientMsgId: 'stream-1',
  createTime: 1761100004000,
  deduplicated: true,
  contentModified: true,
};

const EVERY_BEGIN_FIELD: Required<BeginStreamRequest> = {
  conversationId: 'c_alice_bob',
  receiverId: 'bob',
  groupId: 'team',
  clientMsgId: 'stream-1',
  contentType: MessageContentType.Text,
  placeholder: { name: 'Assistant', avatar: 'bots/assistant.png' },
  options: {
    persistent: false,
    updateConversation: false,
    countUnread: false,
    offlinePush: false,
    pushConfig: { title: 'A', body: 'B', sound: 'ding.caf', payload: { deepLink: 'app://x' }, badgeCount: false, channelId: 'im' },
    needReceipt: true,
    priority: MessagePriority.High,
    onlineOnly: true,
    noSelfSync: true,
    expireIn: 5000,
    moderationBypass: true,
  },
  extensions: { model: 'house-7b' },
};

describe('the four stream calls put exactly this frame on the wire', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('streamBegin carries every field, options nested in camelCase, untouched', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.streamBegin(EVERY_BEGIN_FIELD).catch(() => {});
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);

    assert.deepEqual(frameOf(socket, 'msg.streamBegin'), {
      keys: ['id', 'target', 'body'],
      target: 'msg.streamBegin',
      body: EVERY_BEGIN_FIELD,
    });

    // contentType and priority are bare C# enums: integers, never names. expireIn is a long.
    const raw = socket.sent.find((frame) => frame.includes('"msg.streamBegin"'))!;
    assert.match(raw, /"contentType":1[,}]/);
    assert.match(raw, /"options":\{"persistent":false,.*"priority":2,.*"expireIn":5000,/);
    assert.match(raw, /"pushConfig":\{"title":"A","body":"B","sound":"ding.caf","payload":\{"deepLink":"app:\/\/x"\},"badgeCount":false,"channelId":"im"\}/);
  });

  it('streamBegin fills in nothing — not a clientMsgId, not a contentType, not a sendTime', async () => {
    // Unlike msg.send. The key is the caller's only handle on the finished message (the reply does
    // not echo it), and an absent contentType is Text on the server already.
    // 与 msg.send 不同：这个键是调用方对最终消息唯一的把手（答复不回显它）；contentType 缺席服务端就当 Text。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.streamBegin({ receiverId: 'bob', clientMsgId: 'stream-2' }).catch(() => {});
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);
    assert.deepEqual(frameOf(socket, 'msg.streamBegin').body, { receiverId: 'bob', clientMsgId: 'stream-2' });
  });

  it('streamBegin without a clientMsgId goes out as it is, for the server to refuse', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.streamBegin({ receiverId: 'bob' } as unknown as BeginStreamRequest);
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);

    const request = socket.requestsTo('msg.streamBegin')[0]!;
    assert.deepEqual(request.body, { receiverId: 'bob' });
    socket.reply(request.id, 'msg.streamBegin', null, 1001, { message: 'clientMsgId is required' });
    await assert.rejects(() => pending, (error: unknown) => error instanceof ImError && error.code === 1001);
  });

  it('streamAppend, streamComplete and streamAbort send their fields and nothing else', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.streamAppend({ streamId: 'st_1', delta: 'Hel' }).catch(() => {});
    void client.msg.streamComplete({ streamId: 'st_1', content: { text: 'Hello.' }, extensions: { tokens: 3 } }).catch(() => {});
    void client.msg.streamComplete({ streamId: 'st_1' }).catch(() => {});
    void client.msg.streamAbort({ streamId: 'st_1', reason: 'the model timed out' }).catch(() => {});
    void client.msg.streamAbort({ streamId: 'st_1' }).catch(() => {});
    await until(() => socket.requestsTo('msg.streamAbort').length > 1);

    assert.deepEqual(frameOf(socket, 'msg.streamAppend'), {
      keys: ['id', 'target', 'body'],
      target: 'msg.streamAppend',
      body: { streamId: 'st_1', delta: 'Hel' },
    });
    assert.deepEqual(frameOf(socket, 'msg.streamComplete', 0).body, {
      streamId: 'st_1',
      content: { text: 'Hello.' },
      extensions: { tokens: 3 },
    });
    // No content means "the appended text": absent, never `{}` or null — either would be read as the
    // same thing only by luck of the server's emptiness check.
    assert.deepEqual(frameOf(socket, 'msg.streamComplete', 1).body, { streamId: 'st_1' });
    assert.deepEqual(frameOf(socket, 'msg.streamAbort', 0).body, { streamId: 'st_1', reason: 'the model timed out' });
    assert.deepEqual(frameOf(socket, 'msg.streamAbort', 1).body, { streamId: 'st_1' });
  });

  it('StreamWriter opens with streamBegin and binds the other three to the stream id', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const opening = StreamWriter.begin(client.msg, { receiverId: 'bob', clientMsgId: 'stream-3' });
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);
    socket.replyLatest('msg.streamBegin', { ...EVERY_HANDLE_FIELD, startedAt: '1761100000000' });
    const writer = await opening;
    assert.deepEqual(writer.handle, EVERY_HANDLE_FIELD);
    assert.equal(writer.streamId, 'st_7f3a');

    void writer.append('Hel').catch(() => {});
    void writer.complete().catch(() => {});
    void writer.complete({ content: { text: 'Hello.' } }).catch(() => {});
    void writer.abort().catch(() => {});
    void writer.abort('stopped').catch(() => {});
    await until(() => socket.requestsTo('msg.streamAbort').length > 1);

    assert.deepEqual(frameOf(socket, 'msg.streamAppend').body, { streamId: 'st_7f3a', delta: 'Hel' });
    assert.deepEqual(frameOf(socket, 'msg.streamComplete', 0).body, { streamId: 'st_7f3a' });
    assert.deepEqual(frameOf(socket, 'msg.streamComplete', 1).body, { streamId: 'st_7f3a', content: { text: 'Hello.' } });
    assert.deepEqual(frameOf(socket, 'msg.streamAbort', 0).body, { streamId: 'st_7f3a' });
    assert.deepEqual(frameOf(socket, 'msg.streamAbort', 1).body, { streamId: 'st_7f3a', reason: 'stopped' });
  });
});

describe('stream replies decode with every field the server declares', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('the samples set exactly the fields endpoint-inventory.json declares', () => {
    assert.deepEqual(Object.keys(EVERY_HANDLE_FIELD), declared('StreamHandle'));
    assert.deepEqual(Object.keys(EVERY_SEND_RESULT_FIELD), declared('SendMessageResult'));
    assert.deepEqual(Object.keys(EVERY_BEGIN_FIELD), declared('BeginStreamRequest'));
    assert.deepEqual(Object.keys(EVERY_BEGIN_FIELD.options), declared('MessageOptions'));
    assert.deepEqual(Object.keys(EVERY_BEGIN_FIELD.options.pushConfig!), declared('PushConfig'));

    // The other three request types, as written by a caller.
    assert.deepEqual(declared('StreamAppendRequest'), ['streamId', 'delta']);
    assert.deepEqual(declared('CompleteStreamRequest'), ['streamId', 'content', 'extensions']);
    assert.deepEqual(declared('StreamAbortRequest'), ['streamId', 'reason']);

    const targets = loadInventory()
      .endpoints.filter((endpoint) => endpoint.target.startsWith('msg.stream'))
      .map((endpoint) => [endpoint.target, endpoint.requestType]);
    assert.deepEqual(Object.fromEntries(targets), {
      'msg.streamBegin': 'BeginStreamRequest',
      'msg.streamAppend': 'StreamAppendRequest',
      'msg.streamComplete': 'CompleteStreamRequest',
      'msg.streamAbort': 'StreamAbortRequest',
    });
  });

  it('streamBegin returns the handle, numbers repaired', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.streamBegin({ receiverId: 'bob', clientMsgId: 'stream-1' });
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);
    socket.replyLatest('msg.streamBegin', { ...EVERY_HANDLE_FIELD, startedAt: '1761100000000', idleTimeoutSeconds: '30' });

    assert.deepEqual(await pending, EVERY_HANDLE_FIELD);
  });

  it('streamComplete returns the stored message with every field, numbers repaired', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.streamComplete({ streamId: 'st_7f3a' });
    await until(() => socket.requestsTo('msg.streamComplete').length > 0);
    socket.replyLatest('msg.streamComplete', { ...EVERY_SEND_RESULT_FIELD, seq: '42', createTime: '1761100004000' });

    assert.deepEqual(await pending, EVERY_SEND_RESULT_FIELD);
  });

  it('streamAppend and streamAbort resolve with nothing', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const append = client.msg.streamAppend({ streamId: 'st_1', delta: 'x' });
    const abort = client.msg.streamAbort({ streamId: 'st_1' });
    await until(() => socket.requestsTo('msg.streamAbort').length > 0);
    socket.replyLatest('msg.streamAppend', undefined);
    socket.replyLatest('msg.streamAbort', undefined);

    assert.equal(await append, undefined);
    assert.equal(await abort, undefined);
  });

  it('surfaces the stream refusals as ImError with their codes, none retried', async () => {
    // 1002 is a stream that finished, was aborted or went idle (and a second complete); 1103 is
    // someone else's stream; 1401 a fragment over budget — the stream stays open after that one.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const append = client.msg.streamAppend({ streamId: 'st_1', delta: 'x'.repeat(4097) });
    const complete = client.msg.streamComplete({ streamId: 'st_1' });
    const abort = client.msg.streamAbort({ streamId: 'st_theirs' });
    const begin = client.msg.streamBegin({ conversationId: 'r_lobby', clientMsgId: 'stream-9' });
    await until(() => socket.requestsTo('msg.streamBegin').length > 0);

    const reply = (target: string, code: number, text: string): void => {
      const request = socket.requestsTo(target)[0]!;
      socket.reply(request.id, target, null, code, { message: text, traceId: `trace-${code}` });
    };
    reply('msg.streamAppend', 1401, 'delta is longer than 4096 characters');
    reply('msg.streamComplete', 1002, 'stream not found; it has finished or expired');
    reply('msg.streamAbort', 1103, 'only the producer that opened a stream may finish it');
    reply('msg.streamBegin', 1008, 'streams are for single and group conversations');

    for (const [pending, code, target] of [
      [append, 1401, 'msg.streamAppend'],
      [complete, 1002, 'msg.streamComplete'],
      [abort, 1103, 'msg.streamAbort'],
      [begin, 1008, 'msg.streamBegin'],
    ] as const) {
      await assert.rejects(
        () => pending,
        (error: unknown) =>
          error instanceof ImError && error.code === code && error.target === target && error.traceId === `trace-${code}`,
      );
    }
    assert.equal(socket.requestsTo('msg.streamAppend').length, 1, 'a refusal was retried');
  });
});

describe('evt.stream frames decode into four phases', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('delivers each phase with every field it carries, through onStreamEvent', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const seen: StreamEvent[] = [];
    client.onStreamEvent((e) => seen.push(e));

    socket.push('evt.stream', wire.begin('st_1', { name: 'Assistant' }));
    socket.push('evt.stream', wire.delta('st_1', 1, 'Hel'));
    socket.push('evt.stream', wire.completed('st_1', 2, BIG, 42));
    socket.push('evt.stream', wire.aborted('st_2', 1, 'aborted by the producer'));
    await until(() => seen.length === 4);

    const common = { conversationId: 'c1', senderId: 'bot' };
    assert.deepEqual(seen, [
      { phase: StreamPhase.Begin, streamId: 'st_1', ...common, index: 0, done: false, placeholder: { name: 'Assistant' } },
      { phase: StreamPhase.Delta, streamId: 'st_1', ...common, index: 1, done: false, delta: 'Hel' },
      { phase: StreamPhase.Completed, streamId: 'st_1', ...common, index: 2, done: true, messageId: BIG, seq: 42 },
      { phase: StreamPhase.Aborted, streamId: 'st_2', ...common, index: 1, done: true, abortReason: 'aborted by the producer' },
    ]);
  });

  it('a begin frame without a placeholder has none, and no delta key', () => {
    assert.deepEqual(event(wire.begin('st_1')), {
      phase: StreamPhase.Begin,
      streamId: 'st_1',
      conversationId: 'c1',
      senderId: 'bot',
      index: 0,
      done: false,
    });
  });

  it('reads the message id quoted, as the server writes it, or bare, and a quoted seq or index', () => {
    const quoted = event({ ...wire.completed('st_1', '3' as unknown as number, BIG, '42') });
    assert.equal(quoted.messageId, BIG);
    assert.equal(quoted.seq, 42);
    assert.equal(quoted.index, 3);

    const bare = event(wire.completed('st_1', 3, 1234, 42));
    assert.equal(bare.phase, StreamPhase.Completed);
    assert.equal(bare.messageId, '1234');
  });

  it('a terminal frame with no message id — absent, null or empty — is an abort', () => {
    // Producer abort, idle reap and a completion the send pipeline refused all look like this.
    assert.equal(event(wire.aborted('st_1', 4, 'the producer stopped sending for 30s')).phase, StreamPhase.Aborted);
    assert.equal(event({ ...wire.aborted('st_1', 4, 'x'), messageId: null }).phase, StreamPhase.Aborted);
    assert.equal(event({ ...wire.aborted('st_1', 4, 'x'), messageId: '' }).phase, StreamPhase.Aborted);

    const silent = event({ streamId: 'st_1', conversationId: 'c1', senderId: 'bot', index: 2, done: true });
    assert.equal(silent.phase, StreamPhase.Aborted);
    assert.equal('abortReason' in silent, false);
  });

  it('copies through what a newer server adds, and keeps each phase field on its own phase', () => {
    const newer = event({ ...wire.delta('st_1', 2, 'lo'), tokenCount: 1, placeholder: { stray: true } });
    assert.equal(newer['tokenCount'], 1);
    assert.equal('placeholder' in newer, false, 'a delta frame does not carry a placeholder');
  });

  it('is not a stream frame without a stream id, a conversation or a whole index', () => {
    assert.equal(readStreamEvent(null), null);
    assert.equal(readStreamEvent([]), null);
    assert.equal(readStreamEvent({ conversationId: 'c1', index: 0, done: false }), null);
    assert.equal(readStreamEvent({ streamId: '', conversationId: 'c1', index: 0, done: false }), null);
    assert.equal(readStreamEvent({ streamId: 'st_1', index: 0, done: false }), null);
    assert.equal(readStreamEvent({ streamId: 'st_1', conversationId: 'c1', done: false }), null);
    assert.equal(readStreamEvent({ streamId: 'st_1', conversationId: 'c1', index: 1.5, done: false }), null);
    assert.equal(readStreamEvent({ streamId: 'st_1', conversationId: 'c1', index: -1, done: false }), null);
  });

  it('drops a frame it cannot read before the listener, and keeps the subscription', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const seen: StreamEvent[] = [];
    const off = client.onStreamEvent((e) => seen.push(e));
    socket.push('evt.stream', { conversationId: 'c1' });
    socket.push('evt.stream', wire.begin('st_1'));
    await until(() => seen.length === 1);
    assert.equal(seen[0]!.streamId, 'st_1');

    off();
    socket.push('evt.stream', wire.begin('st_2'));
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(seen.length, 1, 'unsubscribed and still called');
  });
});

describe('fragments are not messages; the finished message is an ordinary one', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('evt.stream frames reach no cursor, no store, no repair and no onMessage', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered, reloads } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);
    const before = client.cursorSnapshot();
    const savesBefore = store.saves.length;

    const frames: StreamEvent[] = [];
    client.onStreamEvent((e) => frames.push(e));

    // A hole (index 2 never comes), a terminal frame with a seq far ahead: none of it is a position.
    socket.push('evt.stream', wire.begin('st_1'));
    socket.push('evt.stream', wire.delta('st_1', 1, 'Hel'));
    socket.push('evt.stream', wire.delta('st_1', 3, '!'));
    socket.push('evt.stream', wire.completed('st_1', 4, BIG, 9));
    await until(() => frames.length === 4);
    await new Promise((resolve) => setTimeout(resolve, 30));

    assert.equal(delivered.length, 1, 'a stream frame reached onMessage');
    assert.equal(socket.requestsTo('msg.sync').length, 0, 'a stream frame asked for a repair');
    assert.deepEqual(reloads, []);
    assert.deepEqual(client.cursorSnapshot(), before);
    assert.equal(store.saves.length, savesBefore, 'a stream frame caused a cursor write');
  });

  it('the finished evt.message goes through gap repair like any other message', async () => {
    // Its seq is real. If the conversation is missing a message before it, the client repairs — the
    // stream does not get a pass, and its terminal frame's seq does not stand in for the message.
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    socket.push('evt.stream', wire.completed('st_1', 3, BIG, 3));
    socket.push('evt.message', finishedMessage('c1', 3, 'Hello!'));
    await until(() => socket.requestsTo('msg.sync').length > 0);

    const repair = socket.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.conversationId, 'c1');
    assert.equal(repair.body.fromSeq, 2);
    socket.reply(repair.id, 'msg.sync', { conversationId: 'c1', messages: [message('c1', 2)], hasMore: false });

    await until(() => delivered.length === 3);
    assert.deepEqual(delivered.map((m) => `${m.conversationId}:${m.seq}`), ['c1:1', 'c1:2', 'c1:3']);
    assert.equal(delivered[2]!.messageId, BIG);
    assert.equal(client.deliveredSeq('c1'), 3);
  });

  it('streamComplete marks nothing delivered, so the producer still receives its own finished message', async () => {
    // msg.send advances deliveredSeq from its result because the server leaves the sending connection
    // out of the echo. A stream completes with no originating connection, so the finished message
    // comes back here on evt.message — marking it first would make the client drop it as a duplicate.
    // msg.send 用结果推进 deliveredSeq，因为服务端回显时不发给发送连接；流收尾没有来源连接，
    // 最终消息会回到这里——先标记就会被当作重复丢掉。
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    const pending = client.msg.streamComplete({ streamId: 'st_1' });
    await until(() => socket.requestsTo('msg.streamComplete').length > 0);
    socket.replyLatest('msg.streamComplete', { ...EVERY_SEND_RESULT_FIELD, conversationId: 'c1', seq: 2 });
    assert.equal((await pending).seq, 2);
    assert.equal(client.deliveredSeq('c1'), 1, 'completing marked the finished message delivered');

    socket.push('evt.message', finishedMessage('c1', 2, 'Hello.'));
    await until(() => delivered.length === 2);
    assert.equal(delivered[1]!.messageId, BIG);
    assert.equal(socket.requestsTo('msg.sync').length, 0);
    assert.equal(client.deliveredSeq('c1'), 2);
  });

  it('pairs the terminal frame and the finished message on messageId, whichever arrives first', async () => {
    const { client, delivered } = await openClient();
    const socket = FakeSocket.latest;
    const assembler = new StreamAssembler();
    client.onStreamEvent((e) => assembler.apply(e));

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    // Terminal frame first, then the message.
    socket.push('evt.stream', wire.begin('st_1'));
    socket.push('evt.stream', wire.delta('st_1', 1, 'Hello'));
    socket.push('evt.stream', wire.delta('st_1', 2, ', Bob.'));
    socket.push('evt.stream', wire.completed('st_1', 3, BIG, 2));
    socket.push('evt.message', finishedMessage('c1', 2, 'Hello, Bob.'));
    await until(() => delivered.length === 2);

    const stream = assembler.byMessageId(delivered[1]!.messageId);
    assert.ok(stream, 'the finished message did not find its stream');
    assert.equal(stream.streamId, 'st_1');
    assert.equal(stream.status, StreamStatus.Completed);
    assert.equal(stream.intact, true);
    // No explicit content was given at completion, so the stored text is the fragments joined.
    assert.equal(stream.text, delivered[1]!.content['text']);

    // The message first, then the terminal frame.
    const other = '360381357961969669';
    socket.push('evt.stream', wire.begin('st_2'));
    socket.push('evt.stream', wire.delta('st_2', 1, 'Bye.'));
    socket.push('evt.message', finishedMessage('c1', 3, 'Bye.', other));
    await until(() => delivered.length === 3);
    assert.equal(assembler.byMessageId(other), undefined, 'not paired until the terminal frame says so');
    assert.equal(assembler.get('st_2')!.status, StreamStatus.Streaming);

    socket.push('evt.stream', wire.completed('st_2', 2, other, 3));
    await until(() => assembler.get('st_2')!.status === StreamStatus.Completed);
    assert.equal(assembler.get('st_2')!.messageId, delivered[2]!.messageId);
    assert.equal(socket.requestsTo('msg.sync').length, 0);
  });
});

describe('StreamAssembler puts fragments back together by index, as the server numbers them', () => {
  it('joins fragments in order and completes into the message id and seq', () => {
    const a = new StreamAssembler();
    assert.deepEqual(a.apply(event(wire.begin('st_1', { name: 'Assistant' }))), {
      streamId: 'st_1',
      conversationId: 'c1',
      senderId: 'bot',
      status: StreamStatus.Streaming,
      placeholder: { name: 'Assistant' },
      text: '',
      intact: true,
    });
    a.apply(event(wire.delta('st_1', 1, 'Hel')));
    assert.equal(a.apply(event(wire.delta('st_1', 2, 'lo'))).text, 'Hello');

    assert.deepEqual(a.apply(event(wire.completed('st_1', 3, BIG, 42))), {
      streamId: 'st_1',
      conversationId: 'c1',
      senderId: 'bot',
      status: StreamStatus.Completed,
      placeholder: { name: 'Assistant' },
      text: 'Hello',
      intact: true,
      messageId: BIG,
      seq: 42,
    });
  });

  it('places a fragment that arrives out of order, and ignores a repeated index', () => {
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    a.apply(event(wire.delta('st_1', 2, 'B')));
    let now = a.apply(event(wire.delta('st_1', 3, 'C')));
    assert.equal(now.text, '', 'text never runs past a hole');
    assert.equal(now.intact, false);

    now = a.apply(event(wire.delta('st_1', 1, 'A')));
    assert.equal(now.text, 'ABC');
    assert.equal(now.intact, true, 'the late fragment closed the hole');

    now = a.apply(event(wire.delta('st_1', 2, 'X')));
    assert.equal(now.text, 'ABC', 'the first copy of an index wins');
  });

  it('a terminal frame that overtakes queued fragments still lets them fill in, and nothing past it', () => {
    // Fragments go at low priority and the terminal frame at normal, so the terminal frame can arrive
    // first. Its index says how many fragments there were (index - 1).
    // 分片低优先级、终帧普通优先级，终帧可能先到；它的 index 减一就是分片总数。
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    a.apply(event(wire.delta('st_1', 1, 'Hel')));
    let now = a.apply(event(wire.completed('st_1', 4, BIG, 7)));
    assert.equal(now.status, StreamStatus.Completed);
    assert.equal(now.text, 'Hel');
    assert.equal(now.intact, false, 'fragments 2 and 3 have not arrived');

    a.apply(event(wire.delta('st_1', 3, '!')));
    now = a.apply(event(wire.delta('st_1', 2, 'lo')));
    assert.equal(now.text, 'Hello!');
    assert.equal(now.intact, true);

    now = a.apply(event(wire.delta('st_1', 4, 'ghost')));
    assert.equal(now.text, 'Hello!', 'a fragment at or past the terminal index is not part of the stream');
    assert.equal(now.status, StreamStatus.Completed, 'a late fragment does not reopen a finished stream');
  });

  it('a shed fragment leaves the text stopped at the hole and the stream not intact, for good', () => {
    // Nothing is repaired: the finished message on onMessage is what to show.
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    a.apply(event(wire.delta('st_1', 1, 'Hel')));
    a.apply(event(wire.delta('st_1', 3, '!')));
    const now = a.apply(event(wire.completed('st_1', 4, BIG, 7)));
    assert.equal(now.text, 'Hel');
    assert.equal(now.intact, false);
    assert.equal(now.messageId, BIG, 'the message id is how to fetch the whole text: it arrives on onMessage');
  });

  it('a late join starts from whatever arrives first, with no placeholder and not intact', () => {
    const a = new StreamAssembler();
    let now = a.apply(event(wire.delta('st_1', 3, 'world')));
    assert.equal(now.status, StreamStatus.Streaming);
    assert.equal('placeholder' in now, false);
    assert.equal(now.text, '');
    assert.equal(now.intact, false);

    // Joined between the opening frame and the first fragment: nothing of the text was missed.
    now = new StreamAssembler().apply(event(wire.delta('st_2', 1, 'Hi')));
    assert.equal(now.text, 'Hi');
    assert.equal(now.intact, true);

    // Joined just before the end: the terminal frame alone.
    now = new StreamAssembler().apply(event(wire.completed('st_3', 5, BIG, 7)));
    assert.equal(now.status, StreamStatus.Completed);
    assert.equal(now.intact, false);
    assert.equal(now.messageId, BIG);
  });

  it('an abort, an idle reap and a refused completion all end with no message and a reason', () => {
    for (const reason of ['the model timed out', 'the producer stopped sending for 30s', 'content rejected by moderation']) {
      const a = new StreamAssembler();
      a.apply(event(wire.begin('st_1')));
      a.apply(event(wire.delta('st_1', 1, 'partial')));
      const now = a.apply(event(wire.aborted('st_1', 2, reason)));
      assert.equal(now.status, StreamStatus.Aborted);
      assert.equal(now.abortReason, reason);
      assert.equal(now.text, 'partial');
      assert.equal('messageId' in now, false);
      assert.equal('seq' in now, false);
    }
  });

  it('a stream completed with no fragments is intact and empty', () => {
    // No appends: the terminal frame is index 1. Completing with explicit content is the usual reason.
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    const now = a.apply(event(wire.completed('st_1', 1, BIG, 3)));
    assert.equal(now.text, '');
    assert.equal(now.intact, true);
  });

  it('the first terminal frame decides', () => {
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    a.apply(event(wire.completed('st_1', 1, BIG, 3)));
    const now = a.apply(event(wire.aborted('st_1', 1, 'late')));
    assert.equal(now.status, StreamStatus.Completed);
    assert.equal(now.messageId, BIG);
    assert.equal('abortReason' in now, false);

    // A repeated opening frame does not reset anything either.
    const b = new StreamAssembler();
    b.apply(event(wire.begin('st_1', { name: 'A' })));
    b.apply(event(wire.delta('st_1', 1, 'x')));
    const again = b.apply(event(wire.begin('st_1', { name: 'B' })));
    assert.deepEqual(again.placeholder, { name: 'A' });
    assert.equal(again.text, 'x');
  });

  it('keeps streams apart, hands out snapshots, and forgets on request', () => {
    const a = new StreamAssembler();
    a.apply(event(wire.begin('st_1')));
    a.apply(event(wire.begin('st_2', undefined, 'g_team')));
    const held = a.apply(event(wire.delta('st_1', 1, 'one')));
    a.apply(event(wire.delta('st_2', 1, 'two', 'g_team')));
    a.apply(event(wire.delta('st_1', 2, ' more')));

    assert.equal(held.text, 'one', 'a snapshot does not change under its holder');
    assert.equal(a.get('st_1')!.text, 'one more');
    assert.equal(a.get('st_2')!.text, 'two');
    assert.equal(a.get('st_2')!.conversationId, 'g_team');
    assert.deepEqual(a.streams().map((s) => s.streamId), ['st_1', 'st_2']);

    a.forget('st_1');
    assert.equal(a.get('st_1'), undefined);
    a.clear();
    assert.deepEqual(a.streams(), []);
  });

  it('remembers a bounded number of finished streams and never evicts an open one', () => {
    const a = new StreamAssembler({ maxFinished: 2 });
    a.apply(event(wire.begin('open')));
    for (const id of ['st_1', 'st_2', 'st_3']) {
      a.apply(event(wire.begin(id)));
      a.apply(event(wire.aborted(id, 1, 'done')));
    }
    assert.equal(a.get('st_1'), undefined, 'the oldest finished stream was not forgotten');
    assert.ok(a.get('st_2'));
    assert.ok(a.get('st_3'));
    assert.equal(a.get('open')!.status, StreamStatus.Streaming);
  });
});
