import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { ImConnection, type ConnectionOptions } from '../src/connection.js';
import { ImError, ImErrorCode } from '../src/protocol.js';
import { FakeSocket, until } from './fake-socket.js';
import { closeAll, openClient } from './doubles.js';

/**
 * CONTRACT §7 — errors, classification and cancellation.
 *
 * The envelope has two layers and both matter: `status` says whether the call was delivered,
 * `body.code` says what the business rule decided. Collapsing them loses the difference between
 * "this deployment does not have that endpoint" and "your group does not exist", which is the
 * difference between upgrading the server and filing a bug.
 */

const connections: ImConnection[] = [];

function optionsFor(overrides: Partial<ConnectionOptions> = {}): ConnectionOptions {
  return {
    endpoint: 'wss://im.test',
    appId: 'demo',
    token: 'token-1',
    deviceId: 'device-1',
    platform: 5,
    requestTimeoutMs: 200,
    webSocketImpl: FakeSocket as unknown as typeof WebSocket,
    random: () => 0,
    ...overrides,
  };
}

async function openConnection(options: ConnectionOptions = optionsFor()): Promise<ImConnection> {
  const connection = new ImConnection(options);
  connections.push(connection);
  void connection.connect();
  await until(() => FakeSocket.instances.length > 0);
  FakeSocket.latest.open();
  await until(() => connection.currentState === 'open');
  return connection;
}

function closeConnections(): void {
  while (connections.length) connections.pop()!.close();
  closeAll();
}

describe('error mapping', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeConnections);

  it('maps status 2 to 1008 UnsupportedOperation, not 1002 NotFound', async () => {
    // 1002 means "your group does not exist". 1008 means "this deployment does not have this
    // endpoint" — the signal an SDK newer than a private-deployment server produces, and the one
    // an integrator needs verbatim to know it is a version problem and not a data problem.
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const pending = connection.request('group.setRole', {});
    await until(() => socket.requestsTo('group.setRole').length > 0);

    const request = socket.requestsTo('group.setRole')[0]!;
    socket.deliver({ id: request.id, target: 'group.setRole', status: 2, msg: 'endpoint not found' });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError &&
        error.code === ImErrorCode.UnsupportedOperation &&
        error.target === 'group.setRole',
    );
  });

  it('maps status 1 to 1000 InternalError with the transport message', async () => {
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const pending = connection.request('msg.send', {});
    await until(() => socket.requestsTo('msg.send').length > 0);

    const request = socket.requestsTo('msg.send')[0]!;
    socket.deliver({ id: request.id, target: 'msg.send', status: 1, msg: 'the endpoint threw' });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError && error.code === ImErrorCode.InternalError && error.message === 'the endpoint threw',
    );
  });

  it('carries traceId and target onto a business failure', async () => {
    // Not decoration: a bug report with both is a one-query investigation, and a guess without.
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const pending = connection.request('msg.send', {});
    await until(() => socket.requestsTo('msg.send').length > 0);

    const request = socket.requestsTo('msg.send')[0]!;
    socket.reply(request.id, 'msg.send', null, 1302, { message: 'not friends', traceId: 'trace-9' });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError &&
        error.code === 1302 &&
        error.traceId === 'trace-9' &&
        error.target === 'msg.send' &&
        error.isRetryable === false,
    );
  });

  it('fails an in-flight request 1004, not 1005, when the socket drops', async () => {
    // 1005 claims the call was never delivered, and the SDK does not know that — the request may
    // well have executed. 1004 is the honest answer, and the one that makes a caller reach for
    // clientMsgId idempotency instead of blindly resending.
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const pending = connection.request('msg.send', {});
    await until(() => socket.requestsTo('msg.send').length > 0);
    socket.die();

    await assert.rejects(
      () => pending,
      (error: unknown) => error instanceof ImError && error.code === ImErrorCode.Timeout,
    );
  });

  it('rejects a request issued while offline instead of queueing it', async () => {
    // A chat client that queues a send across a five-minute outage delivers it into a conversation
    // that has moved on. The application knows whether it is still worth sending; the SDK does not.
    const connection = new ImConnection(optionsFor());
    connections.push(connection);

    await assert.rejects(
      () => connection.request('msg.send', {}),
      (error: unknown) => error instanceof ImError && error.code === ImErrorCode.ServiceUnavailable,
    );
  });
});

describe('retry classification', () => {
  it('matches the table in CONTRACT §7.3 exactly', () => {
    // Computed from the code alone and identical in all five SDKs — an SDK that classifies one
    // differently teaches a rule that stops being true the day a second platform is added.
    const retryable = [1000, 1003, 1004, 1005];
    const reauth = [1100, 1101, 1102];
    const terminal = [1001, 1002, 1006, 1007, 1008, 1103, 1104, 1107, 1202, 1203, 1204, 1302, 1503];

    for (const code of retryable) {
      const error = new ImError(code, 'x');
      assert.equal(error.isRetryable, true, `${code} should be retryable`);
      assert.equal(error.requiresReauth, false, `${code} should not require reauth`);
    }

    for (const code of reauth) {
      const error = new ImError(code, 'x');
      assert.equal(error.requiresReauth, true, `${code} should require reauth`);
      assert.equal(error.isRetryable, false, `${code} is fixed by a token, not by a retry`);
    }

    for (const code of terminal) {
      const error = new ImError(code, 'x');
      assert.equal(error.isRetryable, false, `${code} should be terminal`);
      assert.equal(error.requiresReauth, false, `${code} should not require reauth`);
    }
  });
});

describe('cancellation', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeConnections);

  it('raises AbortError and removes the pending entry', async () => {
    // Cancellation is not a server outcome, so it is not an ImError with an invented code. And an
    // entry left in the map is a leak that grows for the life of the connection.
    const connection = await openConnection();
    const socket = FakeSocket.latest;
    const controller = new AbortController();

    const pending = connection.request('msg.send', {}, { signal: controller.signal });
    await until(() => socket.requestsTo('msg.send').length > 0);
    assert.equal(connection.pendingCount, 1);

    controller.abort();

    await assert.rejects(() => pending, (error: unknown) => (error as Error).name === 'AbortError');
    assert.equal(connection.pendingCount, 0);
  });

  it('rejects immediately when the signal is already aborted', async () => {
    const connection = await openConnection();
    const controller = new AbortController();
    controller.abort();

    await assert.rejects(
      () => connection.request('msg.send', {}, { signal: controller.signal }),
      (error: unknown) => (error as Error).name === 'AbortError',
    );
    assert.equal(FakeSocket.latest.requestsTo('msg.send').length, 0);
  });

  it('leaves nothing pending after an ordinary reply', async () => {
    const connection = await openConnection();
    const socket = FakeSocket.latest;
    const controller = new AbortController();

    const pending = connection.request('conv.unreadTotal', {}, { signal: controller.signal });
    await until(() => socket.requestsTo('conv.unreadTotal').length > 0);
    socket.replyLatest('conv.unreadTotal', 3);

    await pending;
    assert.equal(connection.pendingCount, 0);
  });
});

describe('token expiry on a live socket', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeConnections);

  it('reauths on the existing socket and retries the failed request once', async () => {
    // Without conn.reauth a token expiry costs a full reconnect — and on the flaky network where
    // tokens tend to expire unnoticed, a reconnect is exactly what you were trying to avoid.
    let refreshes = 0;
    const connection = await openConnection(
      optionsFor({
        onTokenExpired: async () => {
          refreshes++;
          return 'token-2';
        },
      }),
    );

    const socket = FakeSocket.latest;
    const pending = connection.request<{ ok: boolean }>('conv.list', {});

    await until(() => socket.requestsTo('conv.list').length === 1);
    socket.reply(socket.requestsTo('conv.list')[0]!.id, 'conv.list', null, 1101, {
      message: 'token expired',
    });

    await until(() => socket.requestsTo('conn.reauth').length === 1);
    assert.equal(socket.requestsTo('conn.reauth')[0]!.body.token, 'token-2');
    socket.replyLatest('conn.reauth', null);

    await until(() => socket.requestsTo('conv.list').length === 2);
    socket.reply(socket.requestsTo('conv.list')[1]!.id, 'conv.list', { ok: true });

    assert.deepEqual(await pending, { ok: true });
    assert.equal(refreshes, 1);
    assert.equal(connection.currentToken, 'token-2');
    assert.equal(FakeSocket.instances.length, 1, 'the socket must not have been replaced');
  });

  it('surfaces 1101 with requiresReauth when the host app has no fresh token', async () => {
    const connection = await openConnection(optionsFor({ onTokenExpired: async () => null }));
    const socket = FakeSocket.latest;

    const pending = connection.request('conv.list', {});
    await until(() => socket.requestsTo('conv.list').length === 1);
    socket.reply(socket.requestsTo('conv.list')[0]!.id, 'conv.list', null, 1101, { message: 'token expired' });

    await assert.rejects(
      () => pending,
      (error: unknown) => error instanceof ImError && error.code === 1101 && error.requiresReauth,
    );
  });
});

describe('feature flags and kicks', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeConnections);

  it('does not latch 1203 FeatureNotEnabled locally', async () => {
    // A tenant can flip `EnableTypingIndicator` at runtime. A client that remembers "typing is off"
    // stays broken until the app restarts, which is a support ticket the server already fixed.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    for (let attempt = 1; attempt <= 2; attempt++) {
      const pending = client.msg.typing({ conversationId: 'c1', typing: true });
      await until(() => socket.requestsTo('msg.typing').length === attempt);
      socket.reply(socket.requestsTo('msg.typing')[attempt - 1]!.id, 'msg.typing', null, 1203, {
        message: 'typing indicator is disabled for this app',
      });
      await assert.rejects(() => pending, (error: unknown) => error instanceof ImError && error.code === 1203);
    }

    assert.equal(socket.requestsTo('msg.typing').length, 2, 'both calls must reach the wire');
  });

  it('stops reconnecting after a kick', async () => {
    // Reconnecting into a kick is a loop, and the server will refuse identically every time.
    const connection = await openConnection();
    const kicks: string[] = [];
    connection.on('conn.kick', (frame) => kicks.push((frame.body?.data as { reason: string }).reason));

    FakeSocket.latest.die(1000, 'im-kick:MultiLoginPolicy');
    await until(() => connection.currentState === 'closed');

    assert.deepEqual(kicks, ['MultiLoginPolicy']);
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(FakeSocket.instances.length, 1);
  });
});
