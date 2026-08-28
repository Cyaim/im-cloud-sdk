import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { ImClient } from '../src/client.js';
import { FakeSocket, until } from './fake-socket.js';
import { clientOptions, closeAll, opened } from './doubles.js';

/**
 * CONTRACT §6 — push registration.
 *
 * The server side shipped and **no SDK called it**, so offline push — which every mobile deal
 * turns on — was unreachable from any official client. Three rules carry the weight:
 *
 * - Register on **every** connect, not once at install. A vendor may replace the token while the
 *   process is frozen and the server has no other way to learn it. Re-registering an unchanged
 *   token costs no write; the server debounces it.
 * - Unregister **before** `disconnect()`. After the socket closes there is no authenticated
 *   channel and the token cannot be removed at all.
 * - Disconnecting never unregisters. A dead socket is precisely the state offline push exists for.
 *
 * 断线绝不注销——连接断开正是离线推送存在的理由；而注销必须赶在关闭套接字之前，
 * 因为套接字一关就没有可鉴权的通道了。
 */

/** Opens a client without the shared helper, so the token can be set before the first connect. */
async function openWithToken(
  provider = 'fcm',
  token = 'vendor-token-1',
): Promise<{ client: ImClient }> {
  const client = new ImClient(clientOptions());
  opened.push(client);

  // Offline: cached, not sent. Registration is a normal request and is never queued.
  await client.push.setToken(provider, token);
  assert.equal(FakeSocket.instances.length, 0);

  void client.connect();
  await until(() => FakeSocket.instances.length > 0);
  FakeSocket.latest.open();
  await until(() => client.state === 'open');

  return { client };
}

/** Answers the register the client sends on connect, then the resume behind it. */
async function settleConnect(socket: FakeSocket): Promise<void> {
  await until(() => socket.requestsTo('push.register').length > 0);
  socket.replyLatest('push.register', null);
  await until(() => socket.requestsTo('conn.sync').length > 0);
  socket.replyLatest('conn.sync', { conversations: [], gapsFrom: {}, hasMore: false });
}

describe('push registration', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('registers on every connect, not once at install', async () => {
    const { client } = await openWithToken();
    await settleConnect(FakeSocket.latest);

    for (let reconnect = 0; reconnect < 2; reconnect++) {
      FakeSocket.latest.die();
      await until(() => FakeSocket.instances.length === reconnect + 2);
      FakeSocket.latest.open();
      await settleConnect(FakeSocket.latest);
    }

    const registrations = FakeSocket.instances.flatMap((socket) => socket.requestsTo('push.register'));
    assert.equal(registrations.length, 3);
    assert.equal(client.push.isRegistered, true);
  });

  it('never puts an identity in the body — the socket already carries one', async () => {
    // There is no field in which to say "register a token against someone else's device", and the
    // server ignores one if a client invents it. Sending it anyway would teach the wrong model.
    await openWithToken('apns', 'apns-token');
    const socket = FakeSocket.latest;

    await until(() => socket.requestsTo('push.register').length > 0);
    const body = socket.requestsTo('push.register')[0]!.body;

    assert.deepEqual(Object.keys(body).sort(), ['provider', 'token']);
    assert.equal(body.provider, 'apns');
    assert.equal(body.token, 'apns-token');
  });

  it('sends a token that arrived while offline on the next connect', async () => {
    const client = new ImClient(clientOptions());
    opened.push(client);

    void client.connect();
    await until(() => FakeSocket.instances.length > 0);
    FakeSocket.latest.open();
    await until(() => client.state === 'open');
    await until(() => FakeSocket.latest.requestsTo('conn.sync').length > 0);
    FakeSocket.latest.replyLatest('conn.sync', { conversations: [], gapsFrom: {}, hasMore: false });

    // No token yet, so nothing was registered.
    assert.equal(FakeSocket.latest.requestsTo('push.register').length, 0);

    FakeSocket.latest.die();
    await until(() => FakeSocket.instances.length >= 2);

    // The vendor hands the app a token while the socket is down.
    await client.push.setToken('fcm', 'late-token');
    assert.equal(FakeSocket.latest.requestsTo('push.register').length, 0);

    FakeSocket.latest.open();
    await until(() => FakeSocket.latest.requestsTo('push.register').length === 1);
    assert.equal(FakeSocket.latest.requestsTo('push.register')[0]!.body.token, 'late-token');
  });

  it('registers a refreshed token immediately when the socket is up', async () => {
    const { client } = await openWithToken();
    const socket = FakeSocket.latest;
    await settleConnect(socket);

    await client.push.setToken('fcm', 'vendor-token-2').catch(() => {});
    await until(() => socket.requestsTo('push.register').length === 2);
    assert.equal(socket.requestsTo('push.register')[1]!.body.token, 'vendor-token-2');
  });

  it('unregisters before the socket closes, on logout', async () => {
    const { client } = await openWithToken();
    const socket = FakeSocket.latest;
    await settleConnect(socket);

    const done = client.logout();
    await until(() => socket.requestsTo('push.unregister').length === 1);

    // Still open: the unregister has to be answered on a live socket, which is the whole point.
    assert.equal(socket.closedWith, null);
    socket.replyLatest('push.unregister', null);

    await done;
    assert.notEqual(socket.closedWith, null);

    // Order, stated as the frames a network trace would show.
    const frames = socket.sent.map((raw) => (JSON.parse(raw) as { target: string }).target);
    assert.equal(frames[frames.length - 1], 'push.unregister');
    assert.equal(client.state, 'closed');
  });

  it('does not unregister on an ordinary disconnect', async () => {
    // A dead socket is precisely the state offline push exists to serve.
    const { client } = await openWithToken();
    const socket = FakeSocket.latest;
    await settleConnect(socket);

    client.disconnect();
    assert.equal(socket.requestsTo('push.unregister').length, 0);
  });

  it('warns once when a held token has never registered successfully', async () => {
    // Only the push warning; the client also logs unrelated SDK notices through console.warn when
    // no onError listener is attached, and those are not what this test is about.
    const warnings: string[] = [];
    const original = console.warn;
    console.warn = (...args: unknown[]) => {
      const line = args.join(' ');
      if (line.includes('push token')) warnings.push(line);
    };

    try {
      const { client } = await openWithToken();
      const socket = FakeSocket.latest;

      await until(() => socket.requestsTo('push.register').length === 1);
      socket.reply(socket.requestsTo('push.register')[0]!.id, 'push.register', null, 1203, {
        message: 'offline push is disabled for this app',
      });

      await until(() => warnings.length === 1);
      assert.match(warnings[0]!, /§6\.2/);
      assert.equal(client.push.isRegistered, false);

      // Once, not on every connect: a warning that repeats is a warning that gets filtered out.
      socket.die();
      await until(() => FakeSocket.instances.length >= 2);
      FakeSocket.latest.open();
      await until(() => FakeSocket.latest.requestsTo('push.register').length === 1);
      FakeSocket.latest.reply(
        FakeSocket.latest.requestsTo('push.register')[0]!.id,
        'push.register',
        null,
        1203,
        { message: 'still disabled' },
      );

      await new Promise((resolve) => setTimeout(resolve, 60));
      assert.equal(warnings.length, 1);
    } finally {
      console.warn = original;
    }
  });
});
