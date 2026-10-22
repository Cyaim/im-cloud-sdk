import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { RoomApi } from '../src/api.js';
import type { ChatRoom, ImMessage, RoomJoinResult, SendMessageResult } from '../src/models.js';
import { ConversationType, ImError, MessageContentType, MessagePriority } from '../src/protocol.js';
import { RoomEventName, isRoomMuteActive, readRoomEvent, roomIdOf, type RoomEvent } from '../src/room.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';
import { FakeSocket, message, until } from './fake-socket.js';
import { loadInventory } from './inventory.js';

/**
 * `room.*` — chat rooms, T4, typed whole.
 *
 * What a signature cannot say and this file pins: each verb's exact frame (the message half of a send
 * is nested, and the server binds nested keys only as spelled); a reply decoded with every field the
 * server declares, held against `endpoint-inventory.json` rather than against this file's own idea of
 * the shape; the events that share `evt.system` with the device log request; and — the one an
 * integrator cannot guess — **a room message carries `seq: 0` and must never reach gap repair or a
 * cursor**. A client that fed one into repair would request a range that does not exist on every
 * arrival, or move a cursor and fabricate a gap for the next real message.
 *
 * 签名说不出来、这里钉住的：每个动词的整帧（send 的 message 是嵌套的，服务端只认原样拼写的键）；
 * 每个字段都填满的答复，对着生成自服务端的清单核；与设备日志请求共用 evt.system 的房间事件；
 * 以及集成方猜不到的那条——聊天室消息 seq 为 0，绝不能进补洞、绝不能碰游标。
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

/** A room message as `evt.message` carries it: seq 0, conversation `r_{roomId}`, type ChatRoom. */
function roomMessage(roomId: string, text: string, seq: unknown = 0): Record<string, unknown> {
  return {
    appId: 'demo',
    conversationId: `r_${roomId}`,
    conversationType: ConversationType.ChatRoom,
    seq,
    messageId: BIG,
    clientMsgId: `room-${text}`,
    senderId: 'bob',
    senderPlatform: 5,
    contentType: MessageContentType.Text,
    content: { text },
    options: { persistent: false, updateConversation: false, countUnread: false, offlinePush: false, onlineOnly: true, priority: 1 },
    status: 1,
    sendTime: 1761100000000,
    createTime: 1761100000001,
  };
}

/** The server's declared property names for a payload type, in its order. */
function declared(typeName: string): string[] {
  const type = loadInventory().payloadTypes[typeName];
  assert.ok(type, `endpoint-inventory.json has no payload type ${typeName}; regenerate it`);
  return type.properties.map((property) => property.name);
}

/**
 * A room with every field the server declares set to a non-default value. `Required<>` makes the
 * compiler insist on every field of this SDK's type; the test below insists the same keys are the
 * server's. Between them the type and the server cannot drift apart unnoticed.
 */
const EVERY_ROOM_FIELD: Required<ChatRoom> = {
  appId: 'demo',
  roomId: 'lobby',
  name: 'Friday launch',
  avatar: 'rooms/lobby.png',
  ownerId: 'alice',
  admins: ['carol'],
  maxOnline: 5000,
  historyBufferSize: 20,
  rateLimitPerSecond: 150,
  muteAll: true,
  destroyed: false,
  createdAt: 1761000000000,
  extensions: { theme: 'dark' },
};

const EVERY_SEND_RESULT_FIELD: Required<SendMessageResult> = {
  messageId: BIG,
  seq: 0,
  conversationId: 'r_lobby',
  clientMsgId: 'room-1',
  createTime: 1761100000001,
  deduplicated: true,
  contentModified: true,
};

describe('the seven room verbs put exactly this frame on the wire', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('join, quit and onlineCount send the room id and nothing else', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.room.join({ roomId: 'lobby' }).catch(() => {});
    void client.room.quit({ roomId: 'lobby' }).catch(() => {});
    void client.room.onlineCount({ roomId: 'lobby' }).catch(() => {});
    await until(() => socket.requestsTo('room.onlineCount').length > 0);

    for (const target of ['room.join', 'room.quit', 'room.onlineCount']) {
      assert.deepEqual(frameOf(socket, target), {
        keys: ['id', 'target', 'body'],
        target,
        body: { roomId: 'lobby' },
      });
    }
  });

  it('memberList sends its cursor and limit only when given', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.room.memberList({ roomId: 'lobby' }).catch(() => {});
    void client.room.memberList({ roomId: 'lobby', cursor: 'members:2', limit: 20 }).catch(() => {});
    await until(() => socket.requestsTo('room.memberList').length > 1);

    // Absent, not 0 or null: the server reads an absent limit as 50, while a 0 would be clamped to
    // the same 50 only by luck of the clamp's lower bound.
    assert.deepEqual(frameOf(socket, 'room.memberList', 0).body, { roomId: 'lobby' });
    assert.deepEqual(frameOf(socket, 'room.memberList', 1), {
      keys: ['id', 'target', 'body'],
      target: 'room.memberList',
      body: { roomId: 'lobby', cursor: 'members:2', limit: 20 },
    });
  });

  it('mute is unmute when untilMs is left out, and room-wide when userId is', async () => {
    // One verb, two directions, two scopes. Absent is the whole meaning here: a client that sent
    // `userId: null` or `untilMs: 0` "to be explicit" would be saying the same thing by accident, and
    // one that filled in a default until-time would mute when it meant to unmute.
    // 一个动词、两个方向、两种范围；缺席本身就是语义——替调用方补一个默认时刻，就把解禁变成了禁言。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.room.mute({ roomId: 'lobby', userId: 'bob', untilMs: 1761103600000 }).catch(() => {});
    void client.room.mute({ roomId: 'lobby' }).catch(() => {});
    await until(() => socket.requestsTo('room.mute').length > 1);

    assert.deepEqual(frameOf(socket, 'room.mute', 0), {
      keys: ['id', 'target', 'body'],
      target: 'room.mute',
      body: { roomId: 'lobby', userId: 'bob', untilMs: 1761103600000 },
    });
    assert.deepEqual(frameOf(socket, 'room.mute', 1).body, { roomId: 'lobby' });

    const raw = socket.sent.find((frame) => frame.includes('"untilMs"'))!;
    assert.match(raw, /"untilMs":1761103600000[,}]/, 'a long goes out as a bare integer, never quoted');
  });

  it('kick names the room and the member', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.room.kick({ roomId: 'lobby', userId: 'bob' }).catch(() => {});
    await until(() => socket.requestsTo('room.kick').length > 0);

    assert.deepEqual(frameOf(socket, 'room.kick'), {
      keys: ['id', 'target', 'body'],
      target: 'room.kick',
      body: { roomId: 'lobby', userId: 'bob' },
    });
  });

  it('send carries every message field nested, in camelCase, untouched', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const message = {
      clientMsgId: 'room-1',
      contentType: MessageContentType.Custom,
      content: { gift: 'rocket', count: 3 },
      mentionAll: true,
      mentionedUserIds: ['alice'],
      options: { priority: MessagePriority.Low },
      sendTime: 1761100000000,
      extensions: { combo: 7 },
    };

    void client.room.send({ roomId: 'lobby', message }).catch(() => {});
    await until(() => socket.requestsTo('room.send').length > 0);

    assert.deepEqual(frameOf(socket, 'room.send'), {
      keys: ['id', 'target', 'body'],
      target: 'room.send',
      body: { roomId: 'lobby', message },
    });

    // The nested keys are bound by an options-less Deserialize, which matches names exactly: a
    // `ClientMsgId` here would be dropped without a word and the send would fail 1001.
    const raw = socket.sent.find((frame) => frame.includes('"room.send"'))!;
    assert.match(raw, /"message":\{"clientMsgId":"room-1","contentType":\d+,"content":\{/);
  });

  it('send fills in the three fields msg.send fills in, and nothing that would name a conversation', async () => {
    // clientMsgId is required server-side (1001 without one) and is the idempotency key, so a
    // caller who never thought about retries still gets a safe one. The room is the target, so no
    // conversationId / receiverId / groupId is invented around it.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.room.send({ roomId: 'lobby', message: { content: { text: 'hi' } } }).catch(() => {});
    await until(() => socket.requestsTo('room.send').length > 0);

    const body = frameOf(socket, 'room.send').body as { roomId: string; message: Record<string, unknown> };
    assert.deepEqual(Object.keys(body), ['roomId', 'message']);
    assert.deepEqual(Object.keys(body.message).sort(), ['clientMsgId', 'content', 'contentType', 'sendTime']);
    assert.equal(typeof body.message['clientMsgId'], 'string');
    assert.ok((body.message['clientMsgId'] as string).length > 0);
    assert.equal(body.message['contentType'], MessageContentType.Text);
    assert.ok(Number.isInteger(body.message['sendTime']));
    assert.deepEqual(body.message['content'], { text: 'hi' });
  });

  it('send without a message goes out as it is, for the server to refuse', async () => {
    // A JavaScript caller has no compiler. Wrapping an id and a type around nothing would turn the
    // bug into an empty message in front of the whole room; the server's 1001 says what is missing.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.room.send({ roomId: 'lobby' } as unknown as Parameters<RoomApi['send']>[0]);
    await until(() => socket.requestsTo('room.send').length > 0);

    const request = socket.requestsTo('room.send')[0]!;
    assert.deepEqual(request.body, { roomId: 'lobby' });
    socket.reply(request.id, 'room.send', null, 1001, { message: 'roomId and message are required' });

    await assert.rejects(() => pending, (error: unknown) => error instanceof ImError && error.code === 1001);
  });
});

describe('room replies decode with every field the server declares', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('the samples below set exactly the fields endpoint-inventory.json declares', () => {
    // Read off the generated inventory, not a second hand-written list: a field the server grows
    // turns this red on the commit that regenerates it, and the `Required<>` samples then do not
    // compile until the type has it too.
    // 对着清单核，而不是再抄一份：服务端加字段，重新生成清单的那个提交就会让这里变红。
    assert.deepEqual(Object.keys(EVERY_ROOM_FIELD), declared('ChatRoom'));
    assert.deepEqual(Object.keys(EVERY_SEND_RESULT_FIELD), declared('SendMessageResult'));
    assert.deepEqual(['room', 'onlineCount', 'recent'], declared('RoomJoinResult'));

    // And the request types: the field names a caller can write are the ones the server binds.
    assert.deepEqual(declared('RoomIdRequest'), ['roomId']);
    assert.deepEqual(declared('RoomCursorRequest'), ['roomId', 'cursor', 'limit']);
    assert.deepEqual(declared('RoomMuteRequest'), ['roomId', 'userId', 'untilMs']);
    assert.deepEqual(declared('RoomKickRequest'), ['roomId', 'userId']);
    assert.deepEqual(declared('RoomSendRequest'), ['roomId', 'message']);

    const roomTargets = loadInventory()
      .endpoints.filter((endpoint) => endpoint.target.startsWith('room.'))
      .map((endpoint) => [endpoint.target, endpoint.requestType]);
    assert.deepEqual(Object.fromEntries(roomTargets), {
      'room.join': 'RoomIdRequest',
      'room.quit': 'RoomIdRequest',
      'room.send': 'RoomSendRequest',
      'room.onlineCount': 'RoomIdRequest',
      'room.memberList': 'RoomCursorRequest',
      'room.mute': 'RoomMuteRequest',
      'room.kick': 'RoomKickRequest',
    });
  });

  it('join returns the room, the count and the recent buffer, numbers repaired, and moves nothing', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;
    const before = client.cursorSnapshot();
    const savesBefore = store.saves.length;

    const pending = client.room.join({ roomId: 'lobby' });
    await until(() => socket.requestsTo('room.join').length > 0);

    // 64-bit values may arrive quoted (CONTRACT §2); every one of them comes out a number.
    const reply: Record<string, unknown> = {
      room: { ...EVERY_ROOM_FIELD, maxOnline: '5000', createdAt: '1761000000000' },
      onlineCount: '1234',
      recent: [roomMessage('lobby', 'earlier', '0'), roomMessage('lobby', 'just now')],
    };
    socket.replyLatest('room.join', reply);

    const joined: RoomJoinResult = await pending;
    assert.deepEqual(joined.room, EVERY_ROOM_FIELD);
    assert.equal(joined.onlineCount, 1234);
    assert.equal(joined.recent.length, 2);
    assert.deepEqual(joined.recent.map((m) => m.seq), [0, 0]);
    assert.deepEqual(joined.recent.map((m) => m.content['text']), ['earlier', 'just now']);
    assert.equal(joined.recent[0]!.messageId, BIG);
    assert.equal(joined.recent[0]!.conversationId, 'r_lobby');
    assert.equal(roomIdOf(joined.recent[0]), 'lobby');

    // The buffer is the caller's to draw. It is not replayed through onMessage, and nothing about it
    // reaches a cursor or the store.
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(delivered.length, 0);
    assert.deepEqual(client.cursorSnapshot(), before);
    assert.equal(store.saves.length, savesBefore);
  });

  it('send returns the result with every field, and records no cursor from its seq 0', async () => {
    // msg.send advances deliveredSeq from its result so the echo reads as a duplicate. room.send must
    // not: its seq is 0 by design, and `r_lobby` is not a conversation this client keeps a position in.
    // msg.send 会用结果推进 deliveredSeq；room.send 不能——它的 seq 恒为 0，r_lobby 也不是有位置的会话。
    const store = new RecordingCursorStore();
    const { client } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;
    const before = client.cursorSnapshot();
    const savesBefore = store.saves.length;

    const pending = client.room.send({ roomId: 'lobby', message: { clientMsgId: 'room-1', content: { text: 'hi' } } });
    await until(() => socket.requestsTo('room.send').length > 0);
    socket.replyLatest('room.send', { ...EVERY_SEND_RESULT_FIELD, seq: '0', createTime: '1761100000001' });

    const result = await pending;
    assert.deepEqual(result, EVERY_SEND_RESULT_FIELD);

    assert.equal(client.deliveredSeq('r_lobby'), 0);
    assert.equal(client.committedSeq('r_lobby'), 0);
    assert.deepEqual(client.cursorSnapshot(), before);
    assert.equal(store.saves.length, savesBefore);
  });

  it('send records no cursor even if a server ever answered with a seq', async () => {
    // Not a shape today's server sends. It pins that the room path has no cursor hook at all, rather
    // than one guarded by `seq > 0` — the guard that keeps msg.send honest would let this through.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.room.send({ roomId: 'lobby', message: { content: { text: 'hi' } } });
    await until(() => socket.requestsTo('room.send').length > 0);
    socket.replyLatest('room.send', { ...EVERY_SEND_RESULT_FIELD, seq: 9 });

    assert.equal((await pending).seq, 9);
    assert.equal(client.deliveredSeq('r_lobby'), 0);
  });

  it('onlineCount answers a bare number, quoted or not', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const first = client.room.onlineCount({ roomId: 'lobby' });
    await until(() => socket.requestsTo('room.onlineCount').length > 0);
    socket.replyLatest('room.onlineCount', 42);
    assert.equal(await first, 42);

    const second = client.room.onlineCount({ roomId: 'lobby' });
    await until(() => socket.requestsTo('room.onlineCount').length > 1);
    socket.replyLatest('room.onlineCount', '9007199254740');
    assert.equal(await second, 9007199254740);
  });

  it('memberList answers a page of user ids', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.room.memberList({ roomId: 'lobby', limit: 2 });
    await until(() => socket.requestsTo('room.memberList').length > 0);
    socket.replyLatest('room.memberList', { items: ['alice', 'bob'], nextCursor: 'members:2', hasMore: true, total: 1234 });

    assert.deepEqual(await pending, { items: ['alice', 'bob'], nextCursor: 'members:2', hasMore: true, total: 1234 });
  });

  it('quit, mute and kick resolve with nothing', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const quit = client.room.quit({ roomId: 'lobby' });
    const mute = client.room.mute({ roomId: 'lobby' });
    const kick = client.room.kick({ roomId: 'lobby', userId: 'bob' });
    await until(() => socket.requestsTo('room.kick').length > 0);

    socket.replyLatest('room.quit', undefined);
    socket.replyLatest('room.mute', undefined);
    socket.replyLatest('room.kick', undefined);

    assert.equal(await quit, undefined);
    assert.equal(await mute, undefined);
    assert.equal(await kick, undefined);
  });

  it('surfaces the room refusals as ImError with their codes', async () => {
    // 1602 after a kick is how a kicked client on another node learns it is out; 1511 is a mute aimed
    // at the owner. Neither is retryable, and the SDK must not retry them.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const send = client.room.send({ roomId: 'lobby', message: { content: { text: 'hi' } } });
    const mute = client.room.mute({ roomId: 'lobby', userId: 'alice', untilMs: 1761103600000 });
    const join = client.room.join({ roomId: 'gone' });
    await until(() => socket.requestsTo('room.join').length > 0);

    const reply = (target: string, code: number, text: string): void => {
      const request = socket.requestsTo(target)[0]!;
      socket.reply(request.id, target, null, code, { message: text, traceId: `trace-${code}` });
    };
    reply('room.send', 1602, 'join the room before sending to it');
    reply('room.mute', 1511, 'the room owner cannot be muted');
    reply('room.join', 1600, 'room not found');

    for (const [pending, code, target] of [
      [send, 1602, 'room.send'],
      [mute, 1511, 'room.mute'],
      [join, 1600, 'room.join'],
    ] as const) {
      await assert.rejects(
        () => pending,
        (error: unknown) =>
          error instanceof ImError &&
          error.code === code &&
          error.target === target &&
          error.traceId === `trace-${code}` &&
          error.isRetryable === false,
      );
    }
  });
});

describe('room events arrive on evt.system and are read as such', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('decodes the three events with every field each one carries', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const seen: RoomEvent[] = [];
    client.onRoomEvent((event) => seen.push(event));

    socket.push('evt.system', {
      event: 'room.muted',
      body: { roomId: 'lobby', operatorId: 'alice', userId: 'bob', untilMs: 1761103600000 },
    });
    // Room-wide unmute: no userId (whole room) and no untilMs (unmute) — nulls are omitted on the wire.
    socket.push('evt.system', { event: 'room.muted', body: { roomId: 'lobby', operatorId: 'alice' } });
    socket.push('evt.system', { event: 'room.kicked', body: { roomId: 'lobby', operatorId: 'carol', userId: 'bob' } });
    socket.push('evt.system', { event: 'room.destroyed', body: { roomId: 'lobby', operatorId: 'tenant-ops' } });
    await until(() => seen.length === 4);

    assert.deepEqual(seen, [
      { event: RoomEventName.Muted, roomId: 'lobby', operatorId: 'alice', userId: 'bob', untilMs: 1761103600000 },
      { event: RoomEventName.Muted, roomId: 'lobby', operatorId: 'alice' },
      { event: RoomEventName.Kicked, roomId: 'lobby', operatorId: 'carol', userId: 'bob' },
      { event: RoomEventName.Destroyed, roomId: 'lobby', operatorId: 'tenant-ops' },
    ]);

    // One event name, two directions: the until-time is the only thing that says which.
    const now = 1761100000000;
    assert.equal(isRoomMuteActive(seen[0]!, now), true);
    assert.equal(isRoomMuteActive(seen[1]!, now), false, 'no untilMs is an unmute');
    assert.equal(isRoomMuteActive(seen[0]!, 1761103600001), false, 'a mute that has run out is not active');
    assert.equal(isRoomMuteActive(seen[2]!, now), false, 'a kick is not a mute');
  });

  it('repairs a quoted until-time and keeps a room.* name it does not know, with its extras', () => {
    const quoted = readRoomEvent({ event: 'room.muted', body: { roomId: 'lobby', operatorId: 'alice', untilMs: '1761103600000' } });
    assert.equal(quoted?.untilMs, 1761103600000);

    const explicitNull = readRoomEvent({ event: 'room.muted', body: { roomId: 'lobby', operatorId: 'alice', userId: null, untilMs: null } });
    assert.deepEqual(explicitNull, { event: 'room.muted', roomId: 'lobby', operatorId: 'alice' });

    // A name a newer server added reaches the application rather than being dropped by a decoder
    // that only knows today's three.
    const newer = readRoomEvent({ event: 'room.renamed', body: { roomId: 'lobby', operatorId: 'alice', name: 'After party' } });
    assert.deepEqual(newer, { event: 'room.renamed', roomId: 'lobby', operatorId: 'alice', name: 'After party' });
  });

  it('ignores every evt.system frame that is not a room event', () => {
    assert.equal(readRoomEvent(null), null);
    assert.equal(readRoomEvent({ event: 'device.logRequest', body: { requestId: 'r1', roomId: 'lobby' } }), null);
    assert.equal(readRoomEvent({ event: 'roomy', body: { roomId: 'lobby' } }), null, 'the prefix is "room." with the dot');
    assert.equal(readRoomEvent({ event: 'room.kicked' }), null, 'an event that names no room is not one this build can route');
    assert.equal(readRoomEvent({ event: 'room.kicked', body: { roomId: '' } }), null);
  });

  it('leaves the device log request to its own handler, and other evt.system listeners alone', async () => {
    // evt.system is shared. The room stream is an extra subscriber: it must not swallow the device
    // log request the client answers on its own subscription, nor stop an application's own listener
    // from seeing the frames it sees.
    // evt.system 是共享的：房间事件流只是多挂的一个订阅者，不能吞掉设备日志请求，也不能挡住应用自己的监听者。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const rooms: RoomEvent[] = [];
    const raw: unknown[] = [];
    client.onRoomEvent((event) => rooms.push(event));
    client.onEvent('evt.system', (data) => raw.push(data));

    // Expired on arrival, so the device-log handler answers it with a log line and no upload — which
    // is the evidence that it still ran.
    socket.push('evt.system', {
      event: 'device.logRequest',
      body: { requestId: 'dl-1', deviceId: 'device-1', uploadUrl: 'https://upload.test', objectKey: 'k', expiresAt: 1, maxBytes: 1000 },
    });
    socket.push('evt.system', { event: 'room.kicked', body: { roomId: 'lobby', operatorId: 'alice', userId: 'bob' } });
    await until(() => raw.length === 2 && rooms.length === 1);

    assert.equal(rooms[0]!.event, 'room.kicked');

    const deadline = Date.now() + 3000;
    let answered = false;
    while (!answered && Date.now() < deadline) {
      const lines = await client.log.read();
      answered = lines.some((line) => line.msg.includes('dl-1') && line.msg.includes('window closed'));
      if (!answered) await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.ok(answered, 'the device-log handler never saw its request');
  });
});

describe('a room message never enters gap repair or seq tracking', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('is delivered at once, requests no repair, and moves no cursor', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered, reloads } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);
    client.commit('c1', 1);
    await client.flushCursors();
    const before = client.cursorSnapshot();
    const savesBefore = store.saves.length;

    // A burst, one of them with its seq quoted the way a 64-bit value may arrive. Any one of these
    // reaching the repair path would ask for seqs 1…-1 of `r_lobby`, or set its cursor and make the
    // next real message there look like a gap.
    for (const [index, seq] of [0, '0', 0, 0].entries()) {
      socket.push('evt.message', roomMessage('lobby', `m${index}`, seq));
    }
    await until(() => delivered.length === 5);

    assert.deepEqual(delivered.slice(1).map((m) => [m.conversationId, m.seq, roomIdOf(m)]), [
      ['r_lobby', 0, 'lobby'],
      ['r_lobby', 0, 'lobby'],
      ['r_lobby', 0, 'lobby'],
      ['r_lobby', 0, 'lobby'],
    ]);
    assert.equal(socket.requestsTo('msg.sync').length, 0, 'a room message asked for a repair');
    assert.deepEqual(reloads, []);
    assert.equal(client.deliveredSeq('r_lobby'), 0);
    assert.equal(client.committedSeq('r_lobby'), 0);
    assert.deepEqual(client.cursorSnapshot(), before);
    assert.equal(store.saves.length, savesBefore, 'a room message caused a cursor write');

    // The conversation it arrived beside is untouched: its next message is the next one, not a gap.
    socket.push('evt.message', message('c1', 2));
    await until(() => delivered.length === 6);
    assert.equal(socket.requestsTo('msg.sync').length, 0);
    assert.equal(client.deliveredSeq('c1'), 2);
  });

  it('is not held behind a repair that is still in flight', async () => {
    // The seq-0 path sits before the per-conversation ordering chain. A room does not wait for a
    // backfill of some other conversation, or of anything, to finish.
    const { delivered } = await openClient();
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);
    socket.push('evt.message', message('c1', 4));
    await until(() => socket.requestsTo('msg.sync').length > 0);

    // The repair for 2…3 is outstanding and stays unanswered while the room speaks.
    socket.push('evt.message', roomMessage('lobby', 'during repair'));
    await until(() => delivered.length === 2);
    assert.equal(delivered[1]!.conversationId, 'r_lobby');
    assert.equal(socket.requestsTo('msg.sync').length, 1, 'only the real gap was repaired');

    const repair = socket.requestsTo('msg.sync')[0]!;
    assert.equal(repair.body.conversationId, 'c1');
    socket.reply(repair.id, 'msg.sync', { conversationId: 'c1', messages: [message('c1', 2), message('c1', 3)], hasMore: false });
    await until(() => delivered.length === 5);
    assert.deepEqual(delivered.map((m) => `${m.conversationId}:${m.seq}`), ['c1:1', 'r_lobby:0', 'c1:2', 'c1:3', 'c1:4']);
  });

  it('is not reported to the server as a position after a reconnect', async () => {
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', roomMessage('lobby', 'hello'));
    await until(() => delivered.length === 1);
    // An application that commits everything it stores, room messages included, must not create a
    // room position either: commit is monotonic from 0, so a 0 is no position at all.
    client.commit(delivered[0]!.conversationId, delivered[0]!.seq);
    await client.flushCursors();

    socket.die();
    await until(() => FakeSocket.instances.length >= 2);
    const next = FakeSocket.latest;
    next.open();
    await until(() => next.requestsTo('conn.sync').length > 0);

    const sync = next.requestsTo('conn.sync')[0]!;
    assert.equal((sync.body.convSeqs as Record<string, unknown>)['r_lobby'], undefined);
    next.reply(sync.id, 'conn.sync', { conversations: [], gapsFrom: {}, hasMore: false });
  });
});

describe('roomIdOf tells a room message apart', () => {
  it('needs the ChatRoom type and the r_ prefix together', () => {
    const base = roomMessage('lobby', 'x') as unknown as ImMessage;
    assert.equal(roomIdOf(base), 'lobby');
    assert.equal(roomIdOf({ ...base, conversationType: ConversationType.Group }), null, 'the prefix alone is a guess');
    assert.equal(roomIdOf({ ...base, conversationId: 'g_lobby' }), null, 'the type alone is a guess');
    assert.equal(roomIdOf({ ...base, conversationId: 'r_' }), null);
    assert.equal(roomIdOf(null), null);
  });
});
