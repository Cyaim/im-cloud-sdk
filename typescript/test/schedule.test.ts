import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import type {
  ConversationFolder,
  ScheduleRequest,
  ScheduledMessage,
  TranslateRequest,
  TranslatedMessage,
  TranslationResult,
  UpsertFolderRequest,
} from '../src/models.js';
import { ConversationType, ImError, ImErrorCode, MessageContentType } from '../src/protocol.js';
import { RecordingCursorStore, closeAll, openClient } from './doubles.js';
import { FakeSocket, message, until } from './fake-socket.js';
import { loadInventory } from './inventory.js';

/**
 * `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled`, `conv.folders` / `conv.upsertFolder` /
 * `conv.deleteFolder` and `msg.translate` — the seven chat-app calls of T4, typed together.
 *
 * What a signature cannot say and this file pins: each call's exact frame (`msg.schedule` is flat —
 * the send fields and `sendAt` at the top level, no `options`, no `sendTime`, nothing generated;
 * `conv.folders` takes no body); the replies decoded with every field the server declares, held
 * against `endpoint-inventory.json`, numbers and message ids repaired; the outbox states read from
 * `messageId` and `error`, a cancelled entry included; and translation switched off — `1203` and
 * `1204` — reaching the caller as an ordinary readable `ImError`, not a crash or an undecodable reply.
 *
 * 签名说不出来、这里钉住的：每条调用的整帧（msg.schedule 是扁平的，发送字段与 sendAt 在顶层，
 * 没有 options、没有 sendTime、不生成任何东西；conv.folders 不带请求体）；答复每个字段对着清单核，
 * 数字与消息 id 修复；从 messageId 与 error 读出定时条目的状态（含已取消）；以及翻译关闭时的 1203 / 1204
 * 作为普通、可读的 ImError 到达调用方，而不是崩溃或解不开的答复。
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

/** The raw text of the `index`th frame sent to `target`, to check JSON kinds a decoded body hides. */
function rawOf(socket: FakeSocket, target: string, index = 0): string {
  const raw = socket.sent.filter((frame) => JSON.parse(frame).target === target)[index];
  assert.ok(raw, `nothing was sent to ${target}`);
  return raw;
}

/** The server's declared property names for a payload type, in its order. */
function declared(typeName: string): string[] {
  const type = loadInventory().payloadTypes[typeName];
  assert.ok(type, `endpoint-inventory.json has no payload type ${typeName}; regenerate it`);
  return type.properties.map((property) => property.name);
}

/**
 * Every field the server declares, set to a non-default value. `Required<>` makes the compiler insist
 * on every field of this SDK's type; the test below insists the same keys are the server's.
 */
const EVERY_SCHEDULE_FIELD: Required<ScheduleRequest> = {
  sendAt: 1761103600000,
  conversationId: 'c_alice_bob',
  receiverId: 'bob',
  groupId: 'team',
  conversationType: ConversationType.Group,
  clientMsgId: 'sched-1',
  contentType: MessageContentType.Image,
  content: { objectKey: 'demo/alice/a.png', width: 640 },
  mentionAll: true,
  mentionedUserIds: ['bob', 'carol'],
  quoteMessageId: BIG,
  threadRootId: BIG,
  extensions: { campaign: 'birthday' },
};

const EVERY_SCHEDULED_FIELD: Required<ScheduledMessage> = {
  scheduleId: 'sch_7f3a',
  appId: 'demo',
  senderId: 'alice',
  conversationId: 'c_alice_bob',
  sendAt: 1761103600000,
  createdAt: 1761100000000,
  messageId: BIG,
  error: 'send failed',
};

const EVERY_FOLDER_FIELD: Required<ConversationFolder> = {
  folderId: 'f_work',
  name: 'Work',
  order: 2,
  tags: ['work', 'clients'],
  unreadOnly: true,
  types: [ConversationType.Single, ConversationType.Group],
};

const EVERY_UPSERT_FIELD: Required<UpsertFolderRequest> = {
  folderId: 'f_work',
  name: 'Work',
  order: 2,
  tags: ['work', 'clients'],
  unreadOnly: true,
  types: [ConversationType.Single, ConversationType.Group],
};

const EVERY_TRANSLATE_FIELD: Required<TranslateRequest> = {
  conversationId: 'c_alice_bob',
  messageIds: [BIG, '7'],
  targetLanguage: 'zh-CN',
  sourceLanguage: 'en',
};

const EVERY_TRANSLATED_FIELD: Required<TranslatedMessage> = {
  messageId: BIG,
  text: '你好',
  cached: true,
  error: 'quota exhausted after this one',
};

const EVERY_TRANSLATION_FIELD: Required<TranslationResult> = {
  targetLanguage: 'zh-CN',
  items: [EVERY_TRANSLATED_FIELD],
};

describe('the seven calls put exactly this frame on the wire', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('msg.schedule carries every field flat, enums and longs as integers, ids quoted, untouched', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.schedule(EVERY_SCHEDULE_FIELD).catch(() => {});
    await until(() => socket.requestsTo('msg.schedule').length > 0);

    assert.deepEqual(frameOf(socket, 'msg.schedule'), {
      keys: ['id', 'target', 'body'],
      target: 'msg.schedule',
      body: EVERY_SCHEDULE_FIELD,
    });

    const raw = rawOf(socket, 'msg.schedule');
    assert.match(raw, /"sendAt":1761103600000[,}]/);
    assert.match(raw, /"conversationType":2[,}]/);
    assert.match(raw, /"contentType":2[,}]/);
    assert.match(raw, new RegExp(`"quoteMessageId":"${BIG}","threadRootId":"${BIG}"`));
  });

  it('msg.schedule fills in nothing — not a clientMsgId, a contentType, a sendTime or options', async () => {
    // Unlike msg.send. The server derives the key from the schedule id when it is absent, an absent
    // contentType is Text there already, and sendTime / options are not on this wire at all.
    // 与 msg.send 不同：键缺席时服务端从 scheduleId 派生，contentType 缺席即 Text，sendTime / options 根本不在这条线上。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.schedule({ sendAt: 1761103600000, receiverId: 'bob', content: { text: 'later' } }).catch(() => {});
    await until(() => socket.requestsTo('msg.schedule').length > 0);

    assert.deepEqual(frameOf(socket, 'msg.schedule').body, {
      sendAt: 1761103600000,
      receiverId: 'bob',
      content: { text: 'later' },
    });
  });

  it('msg.scheduled sends an empty page request by default, and cursor and limit as given', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.scheduled().catch(() => {});
    void client.msg.scheduled({ cursor: 'sch:2', limit: 50 }).catch(() => {});
    await until(() => socket.requestsTo('msg.scheduled').length > 1);

    assert.deepEqual(frameOf(socket, 'msg.scheduled', 0), { keys: ['id', 'target', 'body'], target: 'msg.scheduled', body: {} });
    assert.deepEqual(frameOf(socket, 'msg.scheduled', 1).body, { cursor: 'sch:2', limit: 50 });
    assert.match(rawOf(socket, 'msg.scheduled', 1), /"limit":50[,}]/);
  });

  it('msg.cancelScheduled and conv.deleteFolder send their one id and nothing else', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.cancelScheduled({ scheduleId: 'sch_7f3a' }).catch(() => {});
    void client.conv.deleteFolder({ folderId: 'f_work' }).catch(() => {});
    await until(() => socket.requestsTo('conv.deleteFolder').length > 0);

    assert.deepEqual(frameOf(socket, 'msg.cancelScheduled'), {
      keys: ['id', 'target', 'body'],
      target: 'msg.cancelScheduled',
      body: { scheduleId: 'sch_7f3a' },
    });
    assert.deepEqual(frameOf(socket, 'conv.deleteFolder'), {
      keys: ['id', 'target', 'body'],
      target: 'conv.deleteFolder',
      body: { folderId: 'f_work' },
    });
  });

  it('conv.folders sends no request fields', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.conv.folders().catch(() => {});
    await until(() => socket.requestsTo('conv.folders').length > 0);

    const { target, body } = frameOf(socket, 'conv.folders');
    assert.equal(target, 'conv.folders');
    assert.deepEqual(body ?? {}, {}, 'conv.folders takes no body; the server binds nothing from one');
  });

  it('conv.upsertFolder carries all six members flat, types as integers; a create sends only what is given', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.conv.upsertFolder(EVERY_UPSERT_FIELD).catch(() => {});
    void client.conv.upsertFolder({ name: 'Work' }).catch(() => {});
    await until(() => socket.requestsTo('conv.upsertFolder').length > 1);

    assert.deepEqual(frameOf(socket, 'conv.upsertFolder', 0), {
      keys: ['id', 'target', 'body'],
      target: 'conv.upsertFolder',
      body: EVERY_UPSERT_FIELD,
    });
    assert.match(rawOf(socket, 'conv.upsertFolder', 0), /"order":2,"tags":\["work","clients"\],"unreadOnly":true,"types":\[1,2\]\}/);
    // No folderId means "create", and the server mints it: nothing is generated here.
    assert.deepEqual(frameOf(socket, 'conv.upsertFolder', 1).body, { name: 'Work' });
  });

  it('msg.translate carries every field, message ids as quoted strings with every digit', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.msg.translate(EVERY_TRANSLATE_FIELD).catch(() => {});
    void client.msg.translate({ conversationId: 'c_alice_bob', messageIds: ['7'], targetLanguage: 'ja' }).catch(() => {});
    await until(() => socket.requestsTo('msg.translate').length > 1);

    assert.deepEqual(frameOf(socket, 'msg.translate', 0), {
      keys: ['id', 'target', 'body'],
      target: 'msg.translate',
      body: EVERY_TRANSLATE_FIELD,
    });
    assert.ok(rawOf(socket, 'msg.translate', 0).includes(`"messageIds":["${BIG}","7"]`));
    assert.deepEqual(frameOf(socket, 'msg.translate', 1).body, {
      conversationId: 'c_alice_bob',
      messageIds: ['7'],
      targetLanguage: 'ja',
    });
  });
});

describe('the seven replies decode with every field the server declares', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('the samples set exactly the fields endpoint-inventory.json declares', () => {
    assert.deepEqual(Object.keys(EVERY_SCHEDULE_FIELD), declared('ScheduleRequest'));
    assert.deepEqual(Object.keys(EVERY_SCHEDULED_FIELD), declared('ScheduledMessage'));
    assert.deepEqual(Object.keys(EVERY_FOLDER_FIELD), declared('ConversationFolder'));
    assert.deepEqual(Object.keys(EVERY_UPSERT_FIELD), declared('UpsertFolderRequest'));
    assert.deepEqual(Object.keys(EVERY_TRANSLATE_FIELD), declared('TranslateRequest'));
    assert.deepEqual(Object.keys(EVERY_TRANSLATION_FIELD), declared('TranslationResult'));
    assert.deepEqual(Object.keys(EVERY_TRANSLATED_FIELD), declared('TranslatedMessage'));

    // The three small request types, as written by a caller.
    assert.deepEqual(declared('ScheduleIdRequest'), ['scheduleId']);
    assert.deepEqual(declared('FolderIdRequest'), ['folderId']);
    assert.deepEqual(declared('PageRequest'), ['cursor', 'limit']);

    // msg.schedule binds the flat type — not ScheduleMessageRequest with a nested message.
    const targets = loadInventory()
      .endpoints.filter((endpoint) =>
        [
          'msg.schedule',
          'msg.scheduled',
          'msg.cancelScheduled',
          'conv.folders',
          'conv.upsertFolder',
          'conv.deleteFolder',
          'msg.translate',
        ].includes(endpoint.target),
      )
      .map((endpoint) => [endpoint.target, endpoint.requestType ?? null]);
    assert.deepEqual(Object.fromEntries(targets), {
      'msg.schedule': 'ScheduleRequest',
      'msg.scheduled': 'PageRequest',
      'msg.cancelScheduled': 'ScheduleIdRequest',
      'conv.folders': null,
      'conv.upsertFolder': 'UpsertFolderRequest',
      'conv.deleteFolder': 'FolderIdRequest',
      'msg.translate': 'TranslateRequest',
    });
  });

  it('msg.schedule returns the outbox entry, timestamps and message id repaired', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.schedule({ sendAt: 1761103600000, receiverId: 'bob', content: { text: 'later' } });
    await until(() => socket.requestsTo('msg.schedule').length > 0);
    socket.replyLatest('msg.schedule', { ...EVERY_SCHEDULED_FIELD, sendAt: '1761103600000', createdAt: '1761100000000' });

    assert.deepEqual(await pending, EVERY_SCHEDULED_FIELD);
  });

  it('a waiting entry has neither messageId nor error — absent, not empty', async () => {
    // The state is read from these two fields, so a decoder that filled in `messageId: ''` would turn
    // "waiting" into "sent".
    // 状态靠这两个字段读出来：解码时补一个 messageId: '' 就会把「等待中」读成「已发出」。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.schedule({ sendAt: 1761103600000, receiverId: 'bob', content: { text: 'later' } });
    await until(() => socket.requestsTo('msg.schedule').length > 0);
    const { messageId: _sent, error: _settled, ...waiting } = EVERY_SCHEDULED_FIELD;
    socket.replyLatest('msg.schedule', waiting);

    const entry = await pending;
    assert.deepEqual(entry, waiting);
    assert.equal('messageId' in entry, false);
    assert.equal('error' in entry, false);
  });

  it('msg.scheduled pages the outbox: waiting, sent, failed and cancelled entries, each repaired', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.scheduled();
    await until(() => socket.requestsTo('msg.scheduled').length > 0);
    const base = { appId: 'demo', senderId: 'alice', conversationId: 'c_alice_bob', createdAt: 1761100000000 };
    socket.replyLatest('msg.scheduled', {
      items: [
        { ...base, scheduleId: 'sch_1', sendAt: 1761103600000 },
        { ...base, scheduleId: 'sch_2', sendAt: '1761103700000', messageId: BIG },
        { ...base, scheduleId: 'sch_3', sendAt: 1761103800000, messageId: 1234 },
        { ...base, scheduleId: 'sch_4', sendAt: 1761103900000, error: 'send failed' },
        { ...base, scheduleId: 'sch_5', sendAt: 1761104000000, error: 'cancelled by sender' },
      ],
      nextCursor: 'sch:6',
      hasMore: true,
    });

    const page = await pending;
    assert.equal(page.hasMore, true);
    assert.equal(page.nextCursor, 'sch:6');
    assert.deepEqual(
      page.items.map((entry) => [entry.scheduleId, entry.sendAt, entry.messageId ?? null, entry.error ?? null]),
      [
        ['sch_1', 1761103600000, null, null],
        ['sch_2', 1761103700000, BIG, null],
        ['sch_3', 1761103800000, '1234', null],
        ['sch_4', 1761103900000, null, 'send failed'],
        ['sch_5', 1761104000000, null, 'cancelled by sender'],
      ],
    );
  });

  it('msg.scheduled with an empty outbox is an empty page', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.scheduled({ limit: 100 });
    await until(() => socket.requestsTo('msg.scheduled').length > 0);
    socket.replyLatest('msg.scheduled', { items: [], hasMore: false });

    assert.deepEqual(await pending, { items: [], hasMore: false });
  });

  it('conv.folders returns the bare array; conv.upsertFolder the saved folder; types absent stays absent', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const listing = client.conv.folders();
    await until(() => socket.requestsTo('conv.folders').length > 0);
    const { types: _all, ...everyType } = { ...EVERY_FOLDER_FIELD, folderId: 'f_all', name: 'All unread', order: 0 };
    socket.replyLatest('conv.folders', [everyType, EVERY_FOLDER_FIELD]);
    const folders = await listing;
    assert.deepEqual(folders, [everyType, EVERY_FOLDER_FIELD]);
    assert.equal('types' in folders[0]!, false);

    const saving = client.conv.upsertFolder(EVERY_UPSERT_FIELD);
    await until(() => socket.requestsTo('conv.upsertFolder').length > 0);
    socket.replyLatest('conv.upsertFolder', EVERY_FOLDER_FIELD);
    assert.deepEqual(await saving, EVERY_FOLDER_FIELD);

    const none = client.conv.folders();
    await until(() => socket.requestsTo('conv.folders').length > 1);
    socket.replyLatest('conv.folders', []);
    assert.deepEqual(await none, []);
  });

  it('msg.translate returns the result with every field, message ids read as strings', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.translate(EVERY_TRANSLATE_FIELD);
    await until(() => socket.requestsTo('msg.translate').length > 0);
    socket.replyLatest('msg.translate', {
      targetLanguage: 'zh-CN',
      items: [EVERY_TRANSLATED_FIELD, { messageId: 7, cached: false, error: 'message was recalled' }],
    });

    const result = await pending;
    assert.deepEqual(result, {
      targetLanguage: 'zh-CN',
      items: [EVERY_TRANSLATED_FIELD, { messageId: '7', cached: false, error: 'message was recalled' }],
    });
    assert.equal('text' in result.items[1]!, false);
  });

  it('cancelScheduled and deleteFolder resolve with nothing', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const cancel = client.msg.cancelScheduled({ scheduleId: 'sch_1' });
    const remove = client.conv.deleteFolder({ folderId: 'f_work' });
    await until(() => socket.requestsTo('conv.deleteFolder').length > 0);
    socket.replyLatest('msg.cancelScheduled', undefined);
    socket.replyLatest('conv.deleteFolder', undefined);

    assert.equal(await cancel, undefined);
    assert.equal(await remove, undefined);
  });
});

describe('translation switched off is an ordinary, readable refusal', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  for (const [code, text, why] of [
    [ImErrorCode.FeatureNotEnabled, 'no translation provider is configured (IM:Translation:Provider)', 'no provider on the deployment'],
    [
      ImErrorCode.PlanExpired,
      'message translation is not included in this plan; start its trial or enable the add-on in the console',
      'the plan lacks the add-on',
    ],
  ] as const) {
    it(`${code} (${why}) rejects with ImError carrying the server's code and message, not retried`, async () => {
      const { client, errors } = await openClient();
      const socket = FakeSocket.latest;

      const pending = client.msg.translate({ conversationId: 'c_alice_bob', messageIds: [BIG], targetLanguage: 'zh-CN' });
      await until(() => socket.requestsTo('msg.translate').length > 0);
      const request = socket.requestsTo('msg.translate')[0]!;
      socket.reply(request.id, 'msg.translate', null, code, { message: text, traceId: `trace-${code}` });

      await assert.rejects(
        () => pending,
        (error: unknown) =>
          error instanceof ImError &&
          error.code === code &&
          error.message === text &&
          error.target === 'msg.translate' &&
          error.traceId === `trace-${code}` &&
          error.isRetryable === false &&
          error.requiresReauth === false,
      );
      assert.equal(socket.requestsTo('msg.translate').length, 1, 'a refusal was retried');
      assert.equal(client.state, 'open', 'a refusal touched the connection');
      assert.deepEqual(errors, [], 'a refusal of one call was reported as a client error');
    });
  }

  it('a refusal whose envelope carries no data at all decodes the same way', async () => {
    // The server omits nulls, so a failed ApiResult arrives with no `data` key. That must still be an
    // ImError, not a TypeError from reading `items` of undefined.
    // 服务端省略 null，失败的答复根本没有 data 键；那也必须是 ImError，而不是读 undefined.items 的 TypeError。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.translate({ conversationId: 'c_alice_bob', messageIds: [BIG], targetLanguage: 'zh-CN' });
    await until(() => socket.requestsTo('msg.translate').length > 0);
    const request = socket.requestsTo('msg.translate')[0]!;
    socket.deliver({
      id: request.id,
      target: 'msg.translate',
      status: 0,
      body: { code: 1203, message: 'message translation is not enabled for this app', serverTime: 1 },
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError && error.code === 1203 && error.message === 'message translation is not enabled for this app',
    );
  });
});

describe('scheduling and folder refusals, and what a schedule does not touch', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('surfaces the server refusals as ImError with their codes, none retried', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const tooSoon = client.msg.schedule({ sendAt: 1, receiverId: 'bob', content: { text: 'now' } });
    const unknown = client.msg.cancelScheduled({ scheduleId: 'sch_nope' });
    const claimed = client.msg.scheduled({ cursor: 'garbage' });
    const untagged = client.conv.upsertFolder({ name: 'Work', tags: ['never-used'] });
    const gone = client.conv.deleteFolder({ folderId: 'f_gone' });
    await until(() => socket.requestsTo('conv.deleteFolder').length > 0);

    const reply = (target: string, code: number, text: string): void => {
      const request = socket.requestsTo(target)[0]!;
      socket.reply(request.id, target, null, code, { message: text, traceId: `trace-${code}` });
    };
    reply('msg.schedule', 1001, 'sendAt must be at least 10 seconds in the future');
    reply('msg.cancelScheduled', 1002, 'no such scheduled message');
    reply('msg.scheduled', 1003, 'too many requests');
    reply('conv.upsertFolder', 1001, 'none of your conversations are tagged never-used; tag them before filing them');
    reply('conv.deleteFolder', 1002, 'no such folder');

    for (const [pending, code, target] of [
      [tooSoon, 1001, 'msg.schedule'],
      [unknown, 1002, 'msg.cancelScheduled'],
      [claimed, 1003, 'msg.scheduled'],
      [untagged, 1001, 'conv.upsertFolder'],
      [gone, 1002, 'conv.deleteFolder'],
    ] as const) {
      await assert.rejects(
        () => pending,
        (error: unknown) =>
          error instanceof ImError && error.code === code && error.target === target && error.traceId === `trace-${code}`,
      );
    }
    assert.equal(socket.requestsTo('msg.schedule').length, 1, 'a refusal was retried');
  });

  it('a cancel the dispatcher has already claimed is 1006, readable as such', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.msg.cancelScheduled({ scheduleId: 'sch_1' });
    await until(() => socket.requestsTo('msg.cancelScheduled').length > 0);
    const request = socket.requestsTo('msg.cancelScheduled')[0]!;
    socket.reply(request.id, 'msg.cancelScheduled', null, 1006, {
      message: 'this message is already being sent and can no longer be cancelled',
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError && error.code === ImErrorCode.Conflict && /already being sent/.test(error.message),
    );
  });

  it('scheduling marks nothing delivered: the message it fires into arrives through onMessage like any other', async () => {
    // A schedule has no seq. When it fires, the message goes out through the ordinary send path with no
    // originating connection, so it reaches this connection on evt.message too — and must not be dropped
    // as a duplicate or skip the cursor.
    // 定时条目没有 seq；发出时走普通发送路径、没有来源连接，所以也会经 evt.message 回到本连接——不能被当成重复丢掉。
    const store = new RecordingCursorStore();
    const { client, delivered } = await openClient({ cursorStore: store });
    const socket = FakeSocket.latest;

    socket.push('evt.message', message('c1', 1));
    await until(() => delivered.length === 1);

    const pending = client.msg.schedule({ sendAt: 1761103600000, conversationId: 'c1', content: { text: 'later' } });
    await until(() => socket.requestsTo('msg.schedule').length > 0);
    socket.replyLatest('msg.schedule', { ...EVERY_SCHEDULED_FIELD, conversationId: 'c1', messageId: undefined, error: undefined });
    await pending;
    assert.equal(client.deliveredSeq('c1'), 1, 'scheduling moved a cursor');

    socket.push('evt.message', { ...message('c1', 2), messageId: BIG, clientMsgId: 'sch-sch_7f3a', content: { text: 'later' } });
    await until(() => delivered.length === 2);
    assert.equal(delivered[1]!.messageId, BIG);
    assert.equal(client.deliveredSeq('c1'), 2);
    assert.equal(socket.requestsTo('msg.sync').length, 0);
  });
});
