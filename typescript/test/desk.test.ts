import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import {
  DESK_SESSION_CHANGES,
  DeskNotificationCode,
  DeskSessionChange,
  DeskSessionState,
  ImError,
  MessageContentType,
  type DeskSessionChange as DeskSessionChangeName,
} from '../src/protocol.js';
import { readDeskEvent, readDeskNotification } from '../src/desk.js';
import type { DeskCloseRequest, DeskRateRequest, DeskTransferRequest, ImMessage } from '../src/models.js';
import { FakeSocket, until } from './fake-socket.js';
import { closeAll, openClient } from './doubles.js';
import { loadInventory } from './inventory.js';

/**
 * `desk.*` — the customer-service surface, T4, typed because a customer asked.
 *
 * Four properties carry the weight here and not one of them is visible from a method signature:
 * a transfer names exactly one target, an absent optional key is not the same as a null one, a
 * desk notice is a *message* and has to be told apart from chat, and the `change` values are a
 * closed set a workbench can finish switching on — closed against `endpoint-inventory.json`, which
 * the generator fills from the server, rather than against a second hand-written list.
 *
 * 四件签名上看不出来的事：转接恰好一个目标；缺席的可选键不等于 null；
 * 客服通知本身是一条消息，必须与聊天区分开；change 是一个能被 switch 写完的封闭集合——
 * 而「封闭」是对着生成自服务端的 endpoint-inventory.json 说的，不是对着第二份手抄件。
 */

describe('desk.transfer names exactly one target', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('will not compile with two targets, or with none', () => {
    // The failure this replaces is a workbench that ships, and then fails 1001 in front of a
    // customer halfway through a handover — at which point the session is still the sending
    // agent's and they have already said goodbye. A compile error costs nobody anything.
    // 这道断言替下来的失败是：工作台发布了，然后在交接到一半时当着客户的面 1001。

    // @ts-expect-error two targets: the server answers 1001, and the type says so first.
    const both: DeskTransferRequest = { sessionId: 's1', toAgentId: 'a_7', toSkill: 'billing' };

    // @ts-expect-error no target at all is the same refusal from the other side.
    const neither: DeskTransferRequest = { sessionId: 's1', note: 'over to you' };

    // @ts-expect-error an agent *and* the queue is still two.
    const agentAndQueue: DeskTransferRequest = { sessionId: 's1', toAgentId: 'a_7', toQueue: true };

    // Each of the three on its own is fine, and the note travels with any of them.
    const one: DeskTransferRequest[] = [
      { sessionId: 's1', toAgentId: 'a_7' },
      { sessionId: 's1', toSkill: 'billing', note: 'refund, needs a supervisor' },
      { sessionId: 's1', toQueue: true },
    ];

    assert.equal(one.length, 3);
    assert.ok(both && neither && agentAndQueue);
  });

  it('surfaces the server refusal rather than swallowing it', async () => {
    // A JavaScript caller has no compiler, so the round trip is still the last line of defence and
    // its answer has to reach the agent. 1001 is not retryable and the SDK must not retry it.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.transfer({ sessionId: 's1', toQueue: true, note: 'back to queue' });
    await until(() => socket.requestsTo('desk.transfer').length > 0);

    const request = socket.requestsTo('desk.transfer')[0]!;
    assert.deepEqual(Object.keys(request.body).sort(), ['note', 'sessionId', 'toQueue']);

    socket.reply(request.id, 'desk.transfer', null, 1001, {
      message: 'exactly one of toAgentId, toSkill or toQueue is required',
      traceId: 'trace-desk-1',
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError &&
        error.code === 1001 &&
        error.target === 'desk.transfer' &&
        error.traceId === 'trace-desk-1' &&
        error.isRetryable === false,
    );
  });
});

describe('desk.close and desk.rate send only what was filled in', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('omits every key the closing agent left blank', async () => {
    // The server distinguishes absent from null on this body, and the difference is not cosmetic:
    // `inviteRating` is a C# property initialiser set to true, so sending it as null or omitting it
    // both invite — while `disposition: null` and an absent `disposition` mean "not classified" and
    // would be stored identically. An SDK that helpfully filled the blanks in would file a
    // disposition the agent never chose.
    // 服务端在这条请求体上区分「缺席」与「null」。SDK 若「贴心地」把空位填上，
    // 就等于替坐席归了一个他没有选的档。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.desk.close({ sessionId: 's1' }).catch(() => {});
    await until(() => socket.requestsTo('desk.close').length > 0);

    assert.deepEqual(Object.keys(socket.requestsTo('desk.close')[0]!.body), ['sessionId']);
  });

  it('sends inviteRating only when it was said out loud', async () => {
    // Omitted means invite; the only way to close quietly is to say false. Both spellings have to
    // reach the wire unchanged, which is the whole of what this asserts.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const drawer: DeskCloseRequest = {
      sessionId: 's1',
      disposition: 'to-lead',
      tags: ['billing', 'refund'],
      summary: 'wants a refund, passed to sales',
      inviteRating: false,
    };

    void client.desk.close(drawer).catch(() => {});
    await until(() => socket.requestsTo('desk.close').length > 0);

    const body = socket.requestsTo('desk.close')[0]!.body;
    assert.deepEqual(Object.keys(body).sort(), [
      'disposition',
      'inviteRating',
      'sessionId',
      'summary',
      'tags',
    ]);
    assert.equal(body['inviteRating'], false);
    assert.equal(body['resolution'], undefined, 'a field the agent did not fill in must not appear');
  });

  it('omits resolved and starTags when the survey did not ask', async () => {
    // `resolved` absent means the survey never asked the question; `resolved: false` means the
    // customer answered "no". Folding the first into the second turns silence into a complaint,
    // and first-contact resolution is computed from exactly this field.
    // resolved 缺席 = 问卷没问；resolved: false = 客户答了「没解决」。把前者折成后者，
    // 等于把沉默算成一次投诉——而一次解决率正是从这个字段算出来的。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.desk.rate({ sessionId: 's1', score: 5 }).catch(() => {});
    await until(() => socket.requestsTo('desk.rate').length > 0);

    assert.deepEqual(Object.keys(socket.requestsTo('desk.rate')[0]!.body).sort(), ['score', 'sessionId']);
  });

  it('carries the whole survey when it was answered', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const answer: DeskRateRequest = {
      sessionId: 's1',
      score: 2,
      resolved: false,
      starTags: ['slow', 'wrong answer'],
      comment: 'took twenty minutes',
    };

    void client.desk.rate(answer).catch(() => {});
    await until(() => socket.requestsTo('desk.rate').length > 0);

    const body = socket.requestsTo('desk.rate')[0]!.body;
    assert.deepEqual(Object.keys(body).sort(), ['comment', 'resolved', 'score', 'sessionId', 'starTags']);
    assert.equal(body['resolved'], false);
    assert.deepEqual(body['starTags'], ['slow', 'wrong answer']);
  });
});

describe('the desk verbs put the right targets on the wire', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('asks for a person with an empty body, and returns the session rather than the envelope', async () => {
    // `desk.request` is idempotent server-side, which is what makes the bare call safe: a customer
    // who already has a session gets that one back, so a double tap cannot occupy two agents.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.request();
    await until(() => socket.requestsTo('desk.request').length > 0);

    assert.deepEqual(Object.keys(socket.requestsTo('desk.request')[0]!.body), []);
    socket.replyLatest('desk.request', {
      sessionId: 'ds_1',
      appId: 'demo',
      customerId: 'v_01hh',
      conversationId: 'c1',
      state: DeskSessionState.Queued,
      priority: 0,
      queuedAt: 1755000000000,
      history: [],
      tags: [],
      ratingTags: [],
      star: false,
      responseSamples: [],
    });

    const session = await pending;
    assert.equal(session.sessionId, 'ds_1');
    assert.equal(session.state, DeskSessionState.Queued);
    assert.equal(session.agentId, undefined, 'an unassigned session has no agent, not an empty one');
  });

  it('polls the queue with no body at all', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.queue();
    await until(() => socket.requestsTo('desk.queue').length > 0);
    assert.deepEqual(Object.keys(socket.requestsTo('desk.queue')[0]!.body), []);

    socket.replyLatest('desk.queue', {
      waiting: 3,
      assigned: 5,
      availableAgents: 2,
      headWaitSeconds: 91,
      waitingBySkill: { billing: 3 },
    });

    const view = await pending;
    // Not measurable is absent, and a dashboard has to draw that as "no data" — a 0 here would
    // read as instant answers, which is the opposite of an empty window.
    assert.equal(view.avgFirstResponseSeconds, undefined);
    assert.equal(view.headWaitSeconds, 91);
  });

  it('reports an empty queue as 1002, which a workbench polls through', async () => {
    // `desk.accept` on an empty queue is NotFound rather than an empty success, so a workbench
    // that treats every rejection as an error shows a red banner every few seconds all day.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.accept();
    await until(() => socket.requestsTo('desk.accept').length > 0);

    const request = socket.requestsTo('desk.accept')[0]!;
    socket.reply(request.id, 'desk.accept', null, 1002, { message: 'the queue is empty' });

    await assert.rejects(
      () => pending,
      (error: unknown) => error instanceof ImError && error.code === 1002 && error.isRetryable === false,
    );
  });

  it('reports being at capacity as 1205, which is not retryable', async () => {
    // 1205 rather than 1003 RateLimited, and the difference is the fix: finish a session, do not
    // ask again. An SDK that classified it retryable would teach a workbench to spin.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.accept({ sessionId: 'ds_9' });
    await until(() => socket.requestsTo('desk.accept').length > 0);

    const request = socket.requestsTo('desk.accept')[0]!;
    socket.reply(request.id, 'desk.accept', null, 1205, { message: 'you are at your declared capacity' });

    await assert.rejects(
      () => pending,
      (error: unknown) => error instanceof ImError && error.code === 1205 && error.isRetryable === false,
    );
  });

  it('sends the heartbeat status as a number', async () => {
    // AgentStatus is a bare C# enum and travels as a number; a client that sent "available" would
    // be answered 1001 and its agent would silently never appear in the roster.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.desk.status({ status: 1, maxConcurrent: 4 }).catch(() => {});
    await until(() => socket.requestsTo('desk.status').length > 0);

    const raw = socket.sent.find((frame) => frame.includes('desk.status'))!;
    assert.match(raw, /"status":1/);
    assert.equal(socket.requestsTo('desk.status')[0]!.body['maxConcurrent'], 4);
  });

  it('returns the drafts as a bare array, and 1203 when the tenant has no model', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.suggest({ sessionId: 'ds_1' });
    await until(() => socket.requestsTo('desk.suggest').length > 0);
    socket.replyLatest('desk.suggest', ['Sorry about that —', 'Let me check that order.']);
    assert.deepEqual(await pending, ['Sorry about that —', 'Let me check that order.']);

    const refused = client.desk.suggest({ sessionId: 'ds_2' });
    await until(() => socket.requestsTo('desk.suggest').length > 1);
    const request = socket.requestsTo('desk.suggest')[1]!;
    socket.reply(request.id, 'desk.suggest', null, 1203, { message: 'no LLM is configured' });

    await assert.rejects(
      () => refused,
      (error: unknown) => error instanceof ImError && error.code === 1203,
    );
  });

  it('lists canned replies with no filter, and reads scope back', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.desk.canned();
    await until(() => socket.requestsTo('desk.canned').length > 0);
    assert.deepEqual(Object.keys(socket.requestsTo('desk.canned')[0]!.body), []);

    socket.replyLatest('desk.canned', [
      { id: 'cr_1', title: 'Greeting', content: 'Hello!', scope: 'all', updatedAt: 1 },
    ]);

    const replies = await pending;
    assert.equal(replies[0]!.scope, 'all');
  });
});

describe('the evt.desk change values are a closed set the server pins', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  /**
   * The compile-level half. A `Record` over the closed union is exhaustive by construction: leave
   * one out and this does not build, add one the server does not declare and it does not build
   * either. That is the property a workbench needs — a change it drops is a session that stops
   * moving on one screen while every other screen moves on, and nothing anywhere throws.
   * 封闭联合上的 Record 天然是穷举的：少写一个编译不过，多写一个也编译不过。
   */
  const LABEL: Record<DeskSessionChangeName, string> = {
    assigned: 'taken by an agent',
    released: 'let go',
    closed: 'ended',
    summary: 'summary rewritten',
    message: 'the customer said something',
    note: 'an internal note',
    tag: 'labels changed',
    snooze: 'snoozed',
    whisper: 'a supervisor whispered',
    typing: 'typing',
    inactive: 'both sides have gone quiet',
    overdue: 'the first reply is late',
    takeover: 'another tab took the workbench',
  };

  /** The other compile-level half: a switch the compiler proves is finished. */
  function isAboutOneSession(change: DeskSessionChangeName): boolean {
    switch (change) {
      case 'assigned':
      case 'released':
      case 'closed':
      case 'summary':
      case 'message':
      case 'note':
      case 'tag':
      case 'snooze':
      case 'whisper':
      case 'typing':
      case 'inactive':
      case 'overdue':
        return true;
      case 'takeover':
        // The one that is about the agent rather than a session; its frame carries no session.
        return false;
      default: {
        const unreachable: never = change;
        return unreachable;
      }
    }
  }

  it('declares exactly the ones the server declares, in its order', () => {
    // Read off `endpoint-inventory.json`, which the generator fills from
    // `IM.Abstractions.Contracts.DeskSessionChange.All` — not off a second hand-written list.
    //
    // The first version of this test asserted against thirteen literals and a `size === 13`, which
    // proves that this file agrees with this file. Nothing connected the union to the server, and
    // the failure that leaves open is silent on both sides: the server grows a fourteenth value,
    // the platform repository's SPEC guards go red and get fixed, and this SDK stays one short
    // forever — `knownDeskChange` returns null for a value that is now live and the workbench drops
    // the frame, which is the exact failure this module's header warns about.
    //
    // The chain that closes it: the generator reads the server and runs in `-Check` mode on every
    // platform PR, so the commit that adds a value has to regenerate the inventory; the inventory
    // is in this repository; this assertion reads it. Drift becomes visible on the commit that
    // causes it rather than on the day somebody notices a missing frame.
    //
    // 从 endpoint-inventory.json 读，而不是再抄一份：第一版对着十三个字面量断言，
    // 证明的是「本文件与本文件一致」。生成器读服务端、每个平台 PR 都跑 -Check，
    // 所以加第十四个值的那个提交必须重新生成清单，而清单就在这个仓库里、被这条断言读着。
    const fromServer = Object.values(loadInventory().deskChanges);

    assert.ok(
      fromServer.length > 0,
      'endpoint-inventory.json has no deskChanges block — regenerate it with SDK/tools/Build-EndpointInventory.ps1',
    );
    assert.deepEqual([...DESK_SESSION_CHANGES], fromServer);
    assert.equal(new Set(DESK_SESSION_CHANGES).size, fromServer.length);
    assert.deepEqual(Object.keys(LABEL).sort(), [...DESK_SESSION_CHANGES].sort());
    assert.equal(isAboutOneSession(DeskSessionChange.Takeover), false);
    assert.equal(isAboutOneSession(DeskSessionChange.Assigned), true);
  });

  it('decodes a session frame and keeps extras the decoder was not told about', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const seen: unknown[] = [];
    client.onDeskEvent((event) => seen.push(event));

    socket.push('evt.desk', {
      event: 'desk.session',
      change: 'overdue',
      session: { sessionId: 'ds_1', appId: 'demo', customerId: 'v_1', conversationId: 'c1', state: 1, priority: 0, queuedAt: 1 },
      kind: 'first-response',
      assignedAt: 1755000000000,
      minutes: 5,
      somethingNewer: 'kept',
    });
    await until(() => seen.length > 0);

    const event = seen[0] as { event: string; change: string; minutes: number; somethingNewer: string };
    assert.equal(event.event, 'desk.session');
    assert.equal(event.change, 'overdue');
    assert.equal(event.minutes, 5);
    // A field a newer server adds reaches the application rather than being dropped by a decoder
    // that only knows today's list.
    assert.equal(event.somethingNewer, 'kept');
  });

  it('accepts a released frame with no session, and an agent frame with none either', async () => {
    // Two shapes that a decoder assuming `session` is always there would crash on, and both are
    // exactly the frames an agent most needs: the supervisor took them off, or another of their own
    // tabs did. 两种「没有 session」的帧，恰恰是坐席最需要收到的两种。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const seen: unknown[] = [];
    client.onDeskEvent((event) => seen.push(event));

    socket.push('evt.desk', { event: 'desk.session', change: 'released', session: null, reason: 'shift ended', forced: true });
    socket.push('evt.desk', { event: 'desk.agent', change: 'takeover', connectionId: 'cn_2', memberId: 'm_7' });
    await until(() => seen.length > 1);

    const released = seen[0] as { session: unknown; forced: boolean };
    assert.equal(released.session, null);
    assert.equal(released.forced, true);

    const takeover = seen[1] as { event: string; change: string; connectionId: string; session?: unknown };
    assert.equal(takeover.event, 'desk.agent');
    assert.equal(takeover.change, 'takeover');
    assert.equal(takeover.connectionId, 'cn_2');
    assert.equal(takeover.session, undefined, 'the agent frame carries no session at all');
  });

  it('drops a frame it cannot make sense of instead of handing up a half-built one', () => {
    assert.equal(readDeskEvent(null), null);
    assert.equal(readDeskEvent({ change: 'assigned' }), null, 'no discriminator is not a desk event');
    assert.equal(readDeskEvent({ event: 'desk.session' }), null, 'a session frame without a change is not one');
  });
});

describe('the 1801-1807 notices are messages and have to be read as such', () => {
  /** A desk notice, as it arrives inside an ordinary message on the customer's transcript. */
  function notice(content: Record<string, unknown>): ImMessage {
    return {
      appId: 'demo',
      conversationId: 'c1',
      conversationType: 1,
      seq: 4,
      messageId: '350598345233801216',
      clientMsgId: 'desk-1801-x',
      senderId: 'desk',
      senderPlatform: 100,
      contentType: MessageContentType.Notification,
      content,
      sendTime: 1755000000000,
      createTime: 1755000000000,
    } as ImMessage;
  }

  it('reads all seven codes with the extras each one carries', () => {
    const queued = readDeskNotification(notice({ code: 1801, sessionId: 'ds_1', customerId: 'v_1', skill: 'billing' }));
    assert.deepEqual(queued, {
      code: DeskNotificationCode.Queued,
      sessionId: 'ds_1',
      customerId: 'v_1',
      skill: 'billing',
    });

    const assigned = readDeskNotification(
      notice({ code: 1802, sessionId: 'ds_1', customerId: 'v_1', skill: null, agentId: 'a_7' }),
    );
    assert.equal(assigned?.code, DeskNotificationCode.Assigned);
    assert.equal(assigned?.agentId, 'a_7');
    // `skill` is written into a dictionary, where "omit nulls" does not reach, so the key is there
    // and the value is null. `agentId` is only written when there is one. Two different absences.
    // skill 是写进字典的，「省略 null」管不到它：键在、值是 null。agentId 则是有才写。两种不同的「没有」。
    assert.equal(assigned?.skill, null);

    const transferred = readDeskNotification(
      notice({ code: 1803, sessionId: 'ds_1', customerId: 'v_1', skill: null, agentId: 'a_8', fromAgentId: 'a_7' }),
    );
    assert.equal(transferred?.code, DeskNotificationCode.Transferred);
    assert.equal(transferred && 'fromAgentId' in transferred ? transferred.fromAgentId : null, 'a_7');

    const closed = readDeskNotification(
      notice({ code: 1804, sessionId: 'ds_1', customerId: 'v_1', skill: null, reason: 'timeout' }),
    );
    assert.equal(closed?.code, DeskNotificationCode.Closed);
    assert.equal(closed && 'reason' in closed ? closed.reason : null, 'timeout');
    assert.equal(closed && 'resolution' in closed ? closed.resolution : undefined, undefined);

    const requeued = readDeskNotification(
      notice({ code: 1805, sessionId: 'ds_1', customerId: 'v_1', skill: null, previousAgentId: 'a_7' }),
    );
    assert.equal(requeued && 'previousAgentId' in requeued ? requeued.previousAgentId : null, 'a_7');

    const abandoned = readDeskNotification(
      notice({ code: 1806, sessionId: 'ds_1', customerId: 'v_1', skill: null, waitedSeconds: 903 }),
    );
    assert.equal(abandoned && 'waitedSeconds' in abandoned ? abandoned.waitedSeconds : null, 903);

    const rating = readDeskNotification(
      notice({
        code: 1807,
        sessionId: 'ds_1',
        customerId: 'v_1',
        skill: null,
        windowHours: 24,
        askResolved: true,
        starTags: ['slow', 'wrong answer'],
      }),
    );
    assert.equal(rating?.code, DeskNotificationCode.RatingRequested);
    assert.deepEqual(rating && 'starTags' in rating ? rating.starTags : null, ['slow', 'wrong answer']);
    assert.equal(rating && 'askResolved' in rating ? rating.askResolved : null, true);
    assert.equal(rating && 'windowHours' in rating ? rating.windowHours : null, 24);
  });

  it('coerces the counts the server may have written as strings', () => {
    // `NumberHandling.AllowReadingFromString` runs in both directions in practice: a 64-bit value
    // can arrive quoted. `waitedSeconds + 1` on a string concatenates and nothing throws.
    const abandoned = readDeskNotification(
      notice({ code: 1806, sessionId: 'ds_1', customerId: 'v_1', skill: null, waitedSeconds: '903' }),
    );
    assert.equal(abandoned && 'waitedSeconds' in abandoned ? abandoned.waitedSeconds : null, 903);
  });

  it('leaves an ordinary chat message alone', () => {
    // The reason this matters: desk notices travel down the same `onMessage` path as chat, so the
    // handler asks this first and falls through. A reader keyed on `code` alone would eventually
    // hit a tenant's own notification and draw a support line into the wrong conversation.
    const chat = notice({ text: 'hello' });
    chat.contentType = MessageContentType.Text;
    assert.equal(readDeskNotification(chat), null);
    assert.equal(readDeskNotification(notice({ text: 'hello' })), null, 'a notification with no code is not a desk notice');
    assert.equal(readDeskNotification(null), null);
  });

  it('refuses the account error codes that share these seven numbers', () => {
    // 1801 is `AccountLocked` on the server's own error table and 1804 is `PasswordTooWeak`. They
    // never appear in `message.content`, and this is the assertion that keeps the two tables apart:
    // a code outside the band is not a desk notice however plausible it looks.
    // 1801 在服务端错误码表里是「账号已锁定」。这条断言守住的就是「两张表不能合并」。
    assert.equal(readDeskNotification(notice({ code: 1800, sessionId: 'ds_1', customerId: 'v_1' })), null);
    assert.equal(readDeskNotification(notice({ code: 1808, sessionId: 'ds_1', customerId: 'v_1' })), null);
    assert.equal(readDeskNotification(notice({ code: 1500, sessionId: 'ds_1', customerId: 'v_1' })), null);
  });
});
