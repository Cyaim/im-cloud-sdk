import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { ImConnection, type ConnectionOptions } from '../src/connection.js';
import { ImError } from '../src/protocol.js';
import { SDK_VERSION } from '../src/version.js';
import { FakeSocket, until } from './fake-socket.js';

function optionsFor(overrides: Partial<ConnectionOptions> = {}): ConnectionOptions {
  return {
    endpoint: 'wss://im.test',
    appId: 'demo',
    token: 'token-1',
    deviceId: 'device-1',
    platform: 5,
    requestTimeoutMs: 200,
    webSocketImpl: FakeSocket as unknown as typeof WebSocket,
    // Zero jitter keeps reconnect timing out of the assertions; the distribution itself is tested
    // in backoff.test.ts, where it belongs.
    random: () => 0,
    ...overrides,
  };
}

/**
 * Every connection opened by a test, so teardown can close them.
 *
 * Not tidiness: an open connection holds a 30s heartbeat interval, and in Node a live timer keeps
 * the process alive. Leaving one behind makes the whole run wait out the interval before exiting.
 */
const opened: ImConnection[] = [];

async function openConnection(options: ConnectionOptions = optionsFor()): Promise<ImConnection> {
  const connection = new ImConnection(options);
  opened.push(connection);
  void connection.connect();
  await until(() => FakeSocket.instances.length > 0);
  FakeSocket.latest.open();
  await until(() => connection.currentState === 'open');
  return connection;
}

function closeAll(): void {
  while (opened.length) opened.pop()!.close();
}

describe('connection', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('puts the handshake credentials in the query string', async () => {
    await openConnection(optionsFor({ clientVersion: '1.2.3', language: 'zh-CN' }));

    const url = FakeSocket.latest.url;
    assert.equal(url.pathname, '/im');
    assert.equal(url.searchParams.get('appId'), 'demo');
    assert.equal(url.searchParams.get('token'), 'token-1');
    assert.equal(url.searchParams.get('deviceId'), 'device-1');
    assert.equal(url.searchParams.get('cv'), '1.2.3');
    assert.equal(url.searchParams.get('lang'), 'zh-CN');
  });

  it('reports its own version as cv when the application does not set one', async () => {
    // A support ticket then carries the SDK build without anyone having to ask for it.
    await openConnection();

    assert.equal(FakeSocket.latest.url.searchParams.get('cv'), `im-ts/${SDK_VERSION}`);
  });

  it('rejects a request issued while offline instead of queueing it', async () => {
    const connection = new ImConnection(optionsFor());

    await assert.rejects(
      () => connection.request('msg.send', {}),
      (error: unknown) => error instanceof ImError && error.code === 1005,
    );
  });

  it('turns a non-zero business code into an ImError carrying the trace id', async () => {
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
        error.target === 'msg.send',
    );
  });

  it('rejects in-flight requests when the socket dies, rather than leaving them hanging', async () => {
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const pending = connection.request('msg.send', {});
    await until(() => socket.requestsTo('msg.send').length > 0);

    socket.die();

    // 1004 Timeout rather than 1005 ServiceUnavailable, and the difference is a claim about what
    // happened: 1005 says the call was never delivered, which the SDK does not know — the request
    // may well have executed. This SDK used to answer 1005 here and 1004 on the client-initiated
    // close path; CONTRACT §7.2 settles it as 1004 on both.
    await assert.rejects(
      () => pending,
      (error: unknown) => error instanceof ImError && error.code === 1004,
    );
  });

  it('times out a request the server never answers', async () => {
    const connection = await openConnection();

    await assert.rejects(
      () => connection.request('msg.send', {}),
      (error: unknown) => error instanceof ImError && error.code === 1004,
    );
  });

  it('multiplexes: a reply finds the caller waiting for it, not the other one', async () => {
    const connection = await openConnection();
    const socket = FakeSocket.latest;

    const first = connection.request<{ n: number }>('conv.list', { page: 1 });
    const second = connection.request<{ n: number }>('conv.list', { page: 2 });
    await until(() => socket.requestsTo('conv.list').length === 2);

    const [a, b] = socket.requestsTo('conv.list');
    // Answered out of order on purpose: the id is the only thing that correlates them.
    socket.reply(b!.id, 'conv.list', { n: 2 });
    socket.reply(a!.id, 'conv.list', { n: 1 });

    assert.deepEqual(await first, { n: 1 });
    assert.deepEqual(await second, { n: 2 });
  });
});

describe('kick handling', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('stops reconnecting after a terminal kick', async () => {
    const connection = await openConnection();

    const kicks: string[] = [];
    connection.on('conn.kick', (frame) => {
      kicks.push((frame.body?.data as { reason: string }).reason);
    });

    FakeSocket.latest.die(1000, 'im-kick:MultiLoginPolicy');
    await until(() => connection.currentState === 'closed');

    assert.deepEqual(kicks, ['MultiLoginPolicy']);

    // Reconnecting would be refused identically, forever.
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(FakeSocket.instances.length, 1);
  });

  it('reconnects after an ordinary network death', async () => {
    const connection = await openConnection();

    FakeSocket.latest.die();
    await until(() => FakeSocket.instances.length >= 2);

    assert.notEqual(connection.currentState, 'closed');
  });

  it('refreshes the token before reconnecting when it expired', async () => {
    let refreshes = 0;
    const connection = await openConnection(
      optionsFor({
        onTokenExpired: async () => {
          refreshes++;
          return 'token-2';
        },
      }),
    );

    FakeSocket.latest.die(1000, 'im-kick:TokenExpired');
    await until(() => FakeSocket.instances.length >= 2);

    assert.equal(refreshes, 1);
    assert.equal(FakeSocket.latest.url.searchParams.get('token'), 'token-2');
    assert.notEqual(connection.currentState, 'closed');
  });

  it('closes instead of looping when the host app refuses a fresh token', async () => {
    const connection = await openConnection(optionsFor({ onTokenExpired: async () => null }));

    FakeSocket.latest.die(1000, 'im-kick:TokenExpired');
    await until(() => connection.currentState === 'closed');

    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(FakeSocket.instances.length, 1);
  });

  describe('connect() resolves once the connection is open (2026-09-28)', () => {
    // Until 2026-09-28 connect() resolved as soon as the socket was created, and the README's first two
    // lines — await connect(), then send — failed the send with 1005 against a real server.

    it('does not resolve before the socket opens', async () => {
      const connection = new ImConnection(optionsFor());
      opened.push(connection);

      let settled = false;
      const connecting = connection.connect().then(() => { settled = true; });
      await until(() => FakeSocket.instances.length > 0);
      await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(settled, false, 'resolved while the socket was still connecting');

      FakeSocket.latest.open();
      await connecting;
      assert.equal(connection.currentState, 'open');
    });

    it('lets a request made straight after it go out, instead of refusing it as offline', async () => {
      const connection = new ImConnection(optionsFor());
      opened.push(connection);

      const connecting = connection.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.open();
      await connecting;

      const heartbeat = connection.request('conn.heartbeat');
      const request = FakeSocket.latest.lastRequest!;
      assert.equal(request.target, 'conn.heartbeat');
      FakeSocket.latest.reply(request.id, request.target, { heartbeat: 30 });
      await heartbeat;
    });

    it('waits out a failed first attempt and resolves on the reconnect', async () => {
      const connection = new ImConnection(optionsFor());
      opened.push(connection);

      let settled = false;
      const connecting = connection.connect().then(() => { settled = true; });
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.die();

      await until(() => FakeSocket.instances.length >= 2);
      assert.equal(settled, false, 'a gateway mid-restart is waited out, not reported as connected');

      FakeSocket.latest.open();
      await connecting;
      assert.equal(connection.currentState, 'open');
    });

    it('a second call while connecting waits for the same socket', async () => {
      const connection = new ImConnection(optionsFor());
      opened.push(connection);

      const first = connection.connect();
      const second = connection.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.open();
      await Promise.all([first, second]);
      assert.equal(FakeSocket.instances.length, 1);
    });

    it('rejects when a terminal kick closes the socket before it opens', async () => {
      const connection = new ImConnection(optionsFor());
      opened.push(connection);

      const connecting = connection.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.die(1000, 'im-kick:UserBanned');

      await assert.rejects(connecting, (error: unknown) =>
        error instanceof ImError && error.code === 1100 && /UserBanned/.test(error.message));
    });

    it('rejects with 1101 when the token expired and the host app has no fresh one', async () => {
      const connection = new ImConnection(optionsFor({ onTokenExpired: async () => null }));
      opened.push(connection);

      const connecting = connection.connect();
      await until(() => FakeSocket.instances.length > 0);
      FakeSocket.latest.die(1000, 'im-kick:TokenExpired');

      await assert.rejects(connecting, (error: unknown) => error instanceof ImError && error.code === 1101);
    });

    it('rejects when close() is called before the socket opens', async () => {
      const connection = new ImConnection(optionsFor());

      const connecting = connection.connect();
      await until(() => FakeSocket.instances.length > 0);
      connection.close();

      await assert.rejects(connecting, (error: unknown) => error instanceof ImError);
    });
  });

  it('reconnects on an unrecognised kick reason, rather than stranding the client', async () => {
    // A reason added server-side after this SDK shipped must not be treated as terminal, or every
    // deployed client strands itself the day the server grows a new one.
    const connection = await openConnection();

    FakeSocket.latest.die(1000, 'im-kick:SomethingNewInV2');
    await until(() => FakeSocket.instances.length >= 2);

    assert.notEqual(connection.currentState, 'closed');
  });
});
