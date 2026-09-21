import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import type { ImClient } from '../src/client.js';
import type {
  GroupApplication,
  ImMessage,
  MessageReceipt,
  PinnedMessage,
  SetRoleRequest,
} from '../src/models.js';
import { ApplicationStatus, GroupRole, ImError, MessageContentType, type PagedResult } from '../src/protocol.js';
import { FakeSocket, until } from './fake-socket.js';
import { closeAll, openClient } from './doubles.js';

/**
 * Tier T3 — competitive parity, typed whole: twenty endpoints, asserted on the wire.
 *
 * `coverage.test.ts` proves each method names the right target. That is not the half that breaks.
 * What breaks is the *body*: the socket binder on the server does not go through the JSON options
 * the rest of the platform uses, so a field of the wrong JSON kind is not coerced — it throws, and
 * the caller gets `1000 internal error` with nothing to say which field. A message id sent as a
 * number, an `untilMs` sent as a string, a role sent as `"Admin"`: all three are that same opaque
 * 1000. So every case below pins the exact body — key set, values, and the JSON kind of each value —
 * and every payload endpoint pins what comes back.
 *
 * T3 的二十个端点逐一断言线上的请求体：服务端套接字绑定器不走平台的 JSON 选项，
 * 字段类型不对不会被转换，而是直接抛、回一个说不出是哪个字段的 1000。
 * 所以每条都钉住键集合、取值与 JSON 类型；有载荷的端点再钉住解出来的结果。
 */

/**
 * A real snowflake from a live server: about 2^58, far past what a JavaScript number holds exactly.
 * `Number(SNOWFLAKE)` prints back as a different integer, which is the whole reason ids are strings.
 */
const SNOWFLAKE = '360306324097966080';

type WireRequest = { id: string; target: string; body: Record<string, unknown> };

/**
 * Starts one typed call and waits for its frame. The call is left pending so the test decides how
 * the server answers it — or leaves it, in which case teardown fails it.
 */
async function call<T>(
  client: ImClient,
  target: string,
  invoke: (client: ImClient) => Promise<T>,
): Promise<{ pending: Promise<T>; request: WireRequest; raw: string; socket: FakeSocket }> {
  const socket = FakeSocket.latest;
  const before = socket.requestsTo(target).length;
  const pending = invoke(client);
  // A rejection nobody is awaiting yet must not become an unhandled one; each test awaits
  // `pending` itself when it cares about the outcome.
  pending.catch(() => {});

  await until(() => socket.requestsTo(target).length > before);
  const request = socket.requestsTo(target)[before]!;
  const raw = socket.sent.find((frame) => JSON.parse(frame).id === request.id)!;
  return { pending, request, raw, socket };
}

/** The server's plain acknowledgement: `code: 0` and no `data` at all — it omits the key. */
function ack(socket: FakeSocket, request: WireRequest): void {
  socket.reply(request.id, request.target, undefined);
}

describe('T3 acknowledgements: the body that leaves, field by field', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  /**
   * The fifteen T3 endpoints that answer with a bare acknowledgement. Each row is the call, the
   * target it must name, and the exact body the server will bind. `deepEqual` here is strict, so a
   * `"1758499200000"` where `1758499200000` belongs fails exactly as the server would.
   */
  const cases: Array<{
    target: string;
    invoke: (client: ImClient) => Promise<void>;
    body: Record<string, unknown>;
  }> = [
    {
      target: 'msg.pin',
      invoke: (c) => c.msg.pin({ conversationId: 'g_team', messageId: SNOWFLAKE }),
      body: { conversationId: 'g_team', messageId: SNOWFLAKE },
    },
    {
      target: 'msg.unpin',
      invoke: (c) => c.msg.unpin({ conversationId: 'g_team', messageId: SNOWFLAKE }),
      body: { conversationId: 'g_team', messageId: SNOWFLAKE },
    },
    {
      target: 'msg.favourite',
      invoke: (c) => c.msg.favourite({ conversationId: 's_alice_bob', messageId: SNOWFLAKE }),
      body: { conversationId: 's_alice_bob', messageId: SNOWFLAKE },
    },
    {
      target: 'msg.unfavourite',
      invoke: (c) => c.msg.unfavourite({ conversationId: 's_alice_bob', messageId: SNOWFLAKE }),
      body: { conversationId: 's_alice_bob', messageId: SNOWFLAKE },
    },
    {
      target: 'msg.burn',
      invoke: (c) => c.msg.burn({ conversationId: 's_alice_bob', messageId: SNOWFLAKE }),
      body: { conversationId: 's_alice_bob', messageId: SNOWFLAKE },
    },
    {
      target: 'friend.setRemark',
      invoke: (c) => c.friend.setRemark({ userId: 'bob', remark: 'Bob (finance)', tags: ['work', 'vip'] }),
      body: { userId: 'bob', remark: 'Bob (finance)', tags: ['work', 'vip'] },
    },
    {
      target: 'user.setStatus',
      invoke: (c) => c.user.setStatus({ status: 'in a meeting' }),
      body: { status: 'in a meeting' },
    },
    {
      target: 'conv.markUnread',
      invoke: (c) => c.conv.markUnread({ conversationId: 's_alice_bob', unread: false }),
      body: { conversationId: 's_alice_bob', unread: false },
    },
    {
      target: 'group.transfer',
      invoke: (c) => c.group.transfer({ groupId: 'team', newOwnerId: 'u7' }),
      body: { groupId: 'team', newOwnerId: 'u7' },
    },
    {
      target: 'group.handleApplication',
      invoke: (c) => c.group.handleApplication({ groupId: 'team', applicantId: 'u9', accept: false, reason: 'full' }),
      body: { groupId: 'team', applicantId: 'u9', accept: false, reason: 'full' },
    },
    {
      target: 'group.setRole',
      invoke: (c) => c.group.setRole({ groupId: 'team', userId: 'u7', role: GroupRole.Admin }),
      body: { groupId: 'team', userId: 'u7', role: 2 },
    },
    {
      target: 'group.mute',
      invoke: (c) => c.group.mute({ groupId: 'team', mute: true, untilMs: 1758499200000 }),
      body: { groupId: 'team', mute: true, untilMs: 1758499200000 },
    },
    {
      target: 'group.muteMember',
      invoke: (c) => c.group.muteMember({ groupId: 'team', userId: 'u7', untilMs: 1758499200000 }),
      body: { groupId: 'team', userId: 'u7', untilMs: 1758499200000 },
    },
    {
      target: 'group.setNickname',
      invoke: (c) => c.group.setNickname({ groupId: 'team', nickname: 'Al' }),
      body: { groupId: 'team', nickname: 'Al' },
    },
    {
      target: 'group.announcement',
      invoke: (c) => c.group.announcement({ groupId: 'team', announcement: 'Standup moves to 10:00' }),
      body: { groupId: 'team', announcement: 'Standup moves to 10:00' },
    },
  ];

  it('covers all fifteen acknowledgement endpoints of T3', () => {
    // Fifteen here and five payload endpoints below are the twenty. A row lost in an edit would
    // otherwise shrink the table without failing anything.
    assert.equal(new Set(cases.map((c) => c.target)).size, 15);
  });

  for (const { target, invoke, body } of cases) {
    it(`${target} sends exactly its body and resolves on the bare acknowledgement`, async () => {
      const { client } = await openClient();
      const { pending, request, socket } = await call(client, target, invoke);

      assert.equal(request.target, target);
      assert.deepEqual(request.body, body);

      ack(socket, request);
      assert.equal(await pending, undefined);
    });
  }

  it('sends every message id as a quoted string, digits intact', async () => {
    // The five message-addressing verbs share one DTO whose `messageId` is C# `string`. A JSON
    // number there is not rounded or coerced server-side — the binder throws and the caller reads
    // `1000`. And were it accepted, the number would already be a different id: near 2^58 doubles
    // are 64 apart and print back as the shortest decimal for the double, not the one issued.
    const { client } = await openClient();

    for (const target of ['msg.pin', 'msg.unpin', 'msg.favourite', 'msg.unfavourite', 'msg.burn']) {
      const invoke = cases.find((c) => c.target === target)!.invoke;
      const { raw, request, socket } = await call(client, target, invoke);

      assert.match(raw, new RegExp(`"messageId":"${SNOWFLAKE}"`), `${target} must quote the id`);
      assert.equal(typeof request.body.messageId, 'string');
      ack(socket, request);
    }
  });

  it('leaves out what the caller left out, rather than sending a default the server reads differently', async () => {
    // Four of these fields change meaning when present: `unread` and `mute` default to true
    // server-side, an absent `remark` clears it while absent `tags` keep them, and an absent
    // nickname `userId` means "me". The SDK must not fill any of them in.
    const { client } = await openClient();

    const markUnread = await call(client, 'conv.markUnread', (c) => c.conv.markUnread({ conversationId: 'c1' }));
    assert.deepEqual(markUnread.request.body, { conversationId: 'c1' });
    ack(markUnread.socket, markUnread.request);

    const mute = await call(client, 'group.mute', (c) => c.group.mute({ groupId: 'team' }));
    assert.deepEqual(mute.request.body, { groupId: 'team' });
    ack(mute.socket, mute.request);

    const remark = await call(client, 'friend.setRemark', (c) => c.friend.setRemark({ userId: 'bob' }));
    assert.deepEqual(remark.request.body, { userId: 'bob' });
    ack(remark.socket, remark.request);

    const status = await call(client, 'user.setStatus', (c) => c.user.setStatus({}));
    assert.deepEqual(status.request.body, {});
    ack(status.socket, status.request);
  });

  it('sends the group role as an integer, and will not compile Owner or an invented role', async () => {
    // The binder refuses `"Admin"`; the server stores any integer but Owner. Both halves of that are
    // closed here — the number on the wire, and the type that stops 0, 3 and 4 before they leave.
    // @ts-expect-error Owner moves only with group.transfer; the server answers 1008.
    const owner: SetRoleRequest = { groupId: 'team', userId: 'u7', role: GroupRole.Owner };
    // @ts-expect-error 0 is not a role, and the server would store it — escaping a group-wide mute.
    const zero: SetRoleRequest = { groupId: 'team', userId: 'u7', role: 0 };
    // @ts-expect-error 4 is not a role either, and would outrank every admin.
    const four: SetRoleRequest = { groupId: 'team', userId: 'u7', role: 4 };
    assert.ok(owner && zero && four);

    const { client } = await openClient();
    const { raw, request, socket } = await call(client, 'group.setRole', (c) =>
      c.group.setRole({ groupId: 'team', userId: 'u7', role: GroupRole.Member }),
    );
    assert.match(raw, /"role":1[,}]/);
    ack(socket, request);
  });

  it('surfaces a refusal as ImError, never as a silent success', async () => {
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'msg.pin', (c) =>
      c.msg.pin({ conversationId: 'g_team', messageId: SNOWFLAKE }),
    );

    socket.reply(request.id, 'msg.pin', null, 1006, {
      message: 'this conversation already has 20 pinned messages; unpin one first',
      traceId: 'trace-pin',
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError &&
        error.code === 1006 &&
        error.target === 'msg.pin' &&
        error.traceId === 'trace-pin' &&
        error.isRetryable === false,
    );
  });
});

describe('T3 payloads: what comes back, decoded', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  /** A message as `msg.favourites` and `msg.search` return it — ids quoted, as the server writes them. */
  function wireMessage(messageId: string, seq: number, extra: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      appId: 'demo',
      conversationId: 'g_team',
      conversationType: 2,
      seq,
      messageId,
      clientMsgId: `c${seq}`,
      senderId: 'bob',
      senderPlatform: 1,
      contentType: 1,
      content: { text: `invoice ${seq}` },
      options: { needReceipt: true },
      sendTime: 1756684800000 + seq,
      createTime: 1756684800000 + seq,
      ...extra,
    };
  }

  it('msg.pins sends the conversation and returns the plain array, ids intact', async () => {
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'msg.pins', (c) => c.msg.pins({ conversationId: 'g_team' }));

    assert.deepEqual(request.body, { conversationId: 'g_team' });

    socket.reply(request.id, 'msg.pins', [
      {
        messageId: SNOWFLAKE,
        seq: 42,
        pinnedBy: 'alice',
        pinnedAt: 1758412790000,
        brief: {
          messageId: SNOWFLAKE,
          seq: 42,
          senderId: 'bob',
          contentType: 2,
          digest: '[Image]',
          createTime: 1758412700000,
          recalled: false,
        },
      },
    ]);

    const pins: PinnedMessage[] = await pending;
    assert.ok(Array.isArray(pins), 'msg.pins is a plain array, not a page');
    assert.equal(pins.length, 1);
    assert.equal(pins[0]!.messageId, SNOWFLAKE);
    assert.equal(pins[0]!.brief!.messageId, SNOWFLAKE);
    assert.equal(pins[0]!.pinnedAt, 1758412790000);
    assert.equal(pins[0]!.brief!.digest, '[Image]');
  });

  it('msg.favourites sends an empty body when called bare and returns the page whole', async () => {
    // The page is returned whole because `nextCursor` is the only correct way to continue: a short
    // page — here, one item — with more behind it is normal for this endpoint.
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'msg.favourites', (c) => c.msg.favourites());

    assert.deepEqual(request.body, {});

    socket.reply(request.id, 'msg.favourites', {
      items: [wireMessage(SNOWFLAKE, 7, { recalled: { operatorId: 'bob', recallTime: 1, byAdmin: false } })],
      nextCursor: 'fav:2',
      hasMore: true,
    });

    const page: PagedResult<ImMessage> = await pending;
    assert.equal(page.items.length, 1);
    assert.equal(page.items[0]!.messageId, SNOWFLAKE);
    assert.equal(page.items[0]!.recalled?.operatorId, 'bob', 'recalled favourites are listed, with recalled set');
    assert.equal(page.nextCursor, 'fav:2');
    assert.equal(page.hasMore, true);
    assert.equal(page.total, undefined, 'the server never counts favourites');
  });

  it('msg.favourites passes the cursor and limit through as a string and a number', async () => {
    const { client } = await openClient();
    const { request, socket } = await call(client, 'msg.favourites', (c) =>
      c.msg.favourites({ cursor: 'fav:2', limit: 50 }),
    );

    assert.deepEqual(request.body, { cursor: 'fav:2', limit: 50 });
    socket.reply(request.id, 'msg.favourites', { items: [], hasMore: false });
  });

  it('msg.search sends every filter in the JSON kind the binder accepts', async () => {
    // contentTypes as integers, times as unix-ms numbers, limit a number. Any of them quoted is a
    // `1000` from the binder, not a 1001 naming the field.
    const { client } = await openClient();
    const { pending, request, raw, socket } = await call(client, 'msg.search', (c) =>
      c.msg.search({
        keyword: 'invoice',
        conversationId: 'g_team',
        contentTypes: [MessageContentType.Text, MessageContentType.File],
        senderId: 'bob',
        startTime: 1756684800000,
        endTime: 1759276800000,
        limit: 20,
      }),
    );

    assert.deepEqual(request.body, {
      keyword: 'invoice',
      conversationId: 'g_team',
      contentTypes: [1, 5],
      senderId: 'bob',
      startTime: 1756684800000,
      endTime: 1759276800000,
      limit: 20,
    });
    assert.match(raw, /"contentTypes":\[1,5\]/);

    socket.reply(request.id, 'msg.search', {
      items: [wireMessage(SNOWFLAKE, 9)],
      nextCursor: 'search:2',
      hasMore: true,
    });

    const page = await pending;
    assert.equal(page.items[0]!.messageId, SNOWFLAKE);
    assert.equal(page.items[0]!.content['text'], 'invoice 9');
    assert.equal(page.nextCursor, 'search:2');
  });

  it('msg.search reports search being off as 1203, not retryable, and the rate limit as a retryable 1003', async () => {
    const { client } = await openClient();

    const off = await call(client, 'msg.search', (c) => c.msg.search({ keyword: 'invoice' }));
    assert.deepEqual(off.request.body, { keyword: 'invoice' });
    off.socket.reply(off.request.id, 'msg.search', null, 1203, { message: 'search is not enabled' });
    await assert.rejects(
      () => off.pending,
      (error: unknown) => error instanceof ImError && error.code === 1203 && error.isRetryable === false,
    );

    const limited = await call(client, 'msg.search', (c) => c.msg.search({ keyword: 'invoice' }));
    limited.socket.reply(limited.request.id, 'msg.search', null, 1003, { message: 'search rate limit exceeded' });
    await assert.rejects(
      () => limited.pending,
      (error: unknown) => error instanceof ImError && error.code === 1003 && error.isRetryable === true,
    );
  });

  it('msg.search maps an index timeout — status 1 — to a retryable 1000', async () => {
    // A search that outlives the server's five-second deadline throws inside the endpoint, so the
    // frame says `status: 1` rather than carrying a 1004. It is still worth retrying.
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'msg.search', (c) => c.msg.search({ keyword: 'invoice' }));

    socket.deliver({
      id: request.id,
      target: 'msg.search',
      status: 1,
      body: { code: 1000, message: 'internal error', traceId: 'trace-search', serverTime: 1 },
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError && error.code === 1000 && error.isRetryable === true && error.traceId === 'trace-search',
    );
  });

  it('msg.receiptDetail sends the id quoted and returns the receipt, sender excluded from the readers', async () => {
    const { client } = await openClient();
    const { pending, request, raw, socket } = await call(client, 'msg.receiptDetail', (c) =>
      c.msg.receiptDetail({ conversationId: 'g_team', messageId: SNOWFLAKE }),
    );

    assert.deepEqual(request.body, { conversationId: 'g_team', messageId: SNOWFLAKE });
    assert.match(raw, new RegExp(`"messageId":"${SNOWFLAKE}"`));

    socket.reply(request.id, 'msg.receiptDetail', {
      appId: 'demo',
      conversationId: 'g_team',
      messageId: SNOWFLAKE,
      readUserIds: ['u2'],
      readCount: 1,
      totalCount: 8,
      updatedAt: 1758412790000,
    });

    const receipt: MessageReceipt = await pending;
    assert.deepEqual(receipt, {
      appId: 'demo',
      conversationId: 'g_team',
      messageId: SNOWFLAKE,
      readUserIds: ['u2'],
      readCount: 1,
      totalCount: 8,
      updatedAt: 1758412790000,
    });
  });

  it('msg.receiptDetail rejects a message sent without needReceipt as 1410', async () => {
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'msg.receiptDetail', (c) =>
      c.msg.receiptDetail({ conversationId: 'g_team', messageId: SNOWFLAKE }),
    );

    socket.reply(request.id, 'msg.receiptDetail', null, 1410, { message: 'this message does not track read receipts' });
    await assert.rejects(() => pending, (error: unknown) => error instanceof ImError && error.code === 1410);
  });

  it('group.applicationList called bare lists across every group, and returns every status', async () => {
    // An empty groupId is the server's "every group I manage". Every status comes back, including
    // values this SDK has no name for — enums are open, so they arrive untouched.
    const { client } = await openClient();
    const { pending, request, socket } = await call(client, 'group.applicationList', (c) => c.group.applicationList());

    assert.deepEqual(request.body, { groupId: '' });

    socket.reply(request.id, 'group.applicationList', {
      items: [
        {
          appId: 'demo',
          groupId: 'team',
          applicantId: 'u9',
          inviterId: 'u3',
          reason: 'colleague',
          status: ApplicationStatus.Pending,
          createdAt: 1758412700000,
        },
        {
          appId: 'demo',
          groupId: 'ops',
          applicantId: 'u5',
          status: ApplicationStatus.Rejected,
          handlerId: 'alice',
          handleReason: 'full',
          createdAt: 1758412600000,
          handledAt: 1758412650000,
        },
        { appId: 'demo', groupId: 'ops', applicantId: 'u6', status: 7, createdAt: 1758412500000 },
      ],
      hasMore: false,
    });

    const page: PagedResult<GroupApplication> = await pending;
    assert.equal(page.items.length, 3);
    assert.equal(page.items[0]!.inviterId, 'u3');
    assert.equal(page.items[1]!.handledAt, 1758412650000);
    assert.equal(page.items[2]!.status, 7, 'an unknown status is kept, not folded into a known one');
    assert.deepEqual(
      page.items.filter((a) => a.status === ApplicationStatus.Pending).map((a) => a.applicantId),
      ['u9'],
    );
  });

  it('group.applicationList passes a group, a cursor and a limit through', async () => {
    const { client } = await openClient();
    const { request, socket } = await call(client, 'group.applicationList', (c) =>
      c.group.applicationList({ groupId: 'team', cursor: 'app:2', limit: 100 }),
    );

    assert.deepEqual(request.body, { groupId: 'team', cursor: 'app:2', limit: 100 });
    socket.reply(request.id, 'group.applicationList', { items: [], hasMore: false });
  });
});
