import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import type {
  ClaimBundleRequest,
  DeviceKeyInfo,
  DeviceKeysRequest,
  OneTimePreKey,
  PreKeyBundle,
  PublishKeysRequest,
  RemainingKeysRequest,
  RevokeDeviceRequest,
  SafetyNumberRequest,
  SignedPreKey,
  UploadOneTimeKeysRequest,
} from '../src/models.js';
import { ImError, ImErrorCode, Platform } from '../src/protocol.js';
import { closeAll, openClient } from './doubles.js';
import { FakeSocket, until } from './fake-socket.js';
import { loadInventory } from './inventory.js';

/**
 * `keys.publish` / `upload` / `remaining` / `claim` / `devices` / `revoke` / `safetyNumber` — the
 * end-to-end encryption key directory of T4, typed whole.
 *
 * What a signature cannot say and this file pins: each call's exact frame, the nested
 * `signedPreKey` / `oneTimePreKeys[]` / `keys[]` members under their exact camelCase names (the server
 * binds those case-sensitively, and a miss is `1000` for the whole call), `keys.publish` carrying no
 * `deviceId` or `platform`, and **key material passing through byte for byte** — the SDK performs no
 * cryptography and re-encodes nothing. Replies decode with every field the server declares, held
 * against `endpoint-inventory.json`: the three bare replies (a number, an array, a string), and a
 * claim from an empty pool, which has no `oneTimePreKey` and must not throw. `claim` consumes a key,
 * so it is never sent twice; the directory's refusals reach the caller as ordinary `ImError`s.
 *
 * 签名说不出来、这里钉住的：每条调用的整帧；signedPreKey / oneTimePreKeys[] / keys[] 的成员名一字不差
 * （服务端对嵌套对象按大小写绑定，错一个整个调用就是 1000）；keys.publish 不带 deviceId 与 platform；
 * 密钥材料逐字节原样透传——SDK 不做加密运算、不重新编码。答复每个字段对着清单核：三个裸答复（数字、数组、字符串），
 * 以及池空时没有 oneTimePreKey 的领取结果不能抛异常。claim 会消耗密钥，所以绝不发第二次；目录的拒绝是普通的 ImError。
 */

// Standard base64 with every character a re-encoder would touch — `+`, `/` and `=` padding — so a
// value that went through base64url, a decode/encode round trip or a trim is visibly another value.
// 带 + / = 的标准 base64：经过 base64url、解码再编码或 trim 的值一眼就能看出不同。
const IDENTITY = 'BQ+/ra7fXd3Mu8zN3u/wESIzRFVmd4iZqrvM3e7/ABEi';
const SPK_PUBLIC = 'q83vASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4k=';
const SPK_SIGNATURE = 'c2lnbmF0dXJlLW92ZXItdGhlLWRlY29kZWQtc3BrLWJ5dGVzLW5vdC10aGUta2V5SWQ+/w==';
const OTK_1 = 'b3RrLW9uZS1wdWJsaWMta2V5LWJ5dGVzLTMyLWxvbmc+/w==';
const OTK_2 = 'b3RrLXR3by1wdWJsaWMta2V5LWJ5dGVzLTMyLWxvbmc+/w==';

/** Everything on a frame except its id, which is random. */
function frameOf(socket: FakeSocket, target: string, index = 0): { keys: string[]; target: string; body: unknown } {
  const raw = socket.sent.filter((frame) => JSON.parse(frame).target === target)[index];
  assert.ok(raw, `nothing was sent to ${target}`);
  const frame = JSON.parse(raw) as Record<string, unknown>;
  return { keys: Object.keys(frame), target: frame['target'] as string, body: frame['body'] };
}

/** The raw text of the `index`th frame sent to `target`, to check names and kinds a decoded body hides. */
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
const EVERY_SIGNED_FIELD: Required<SignedPreKey> = {
  keyId: 'spk-7',
  publicKey: SPK_PUBLIC,
  signature: SPK_SIGNATURE,
  createdAt: 1761100000000,
};

const EVERY_ONE_TIME_FIELD: Required<OneTimePreKey> = { keyId: 'otk-1', publicKey: OTK_1 };

const EVERY_PUBLISH_FIELD: Required<PublishKeysRequest> = {
  identityKey: IDENTITY,
  signedPreKey: EVERY_SIGNED_FIELD,
  oneTimePreKeys: [EVERY_ONE_TIME_FIELD, { keyId: 'otk-2', publicKey: OTK_2 }],
  algorithm: 'x3dh-ed25519-aes256gcm-v1',
};

const EVERY_UPLOAD_FIELD: Required<UploadOneTimeKeysRequest> = {
  keys: [EVERY_ONE_TIME_FIELD, { keyId: 'otk-2', publicKey: OTK_2 }],
};

const EVERY_REMAINING_FIELD: Required<RemainingKeysRequest> = { deviceId: 'device-2' };
const EVERY_CLAIM_FIELD: Required<ClaimBundleRequest> = { userId: 'bob', deviceId: 'bob-phone' };
const EVERY_DEVICES_FIELD: Required<DeviceKeysRequest> = { userId: 'bob' };
const EVERY_REVOKE_FIELD: Required<RevokeDeviceRequest> = { deviceId: 'old-laptop' };
const EVERY_SAFETY_FIELD: Required<SafetyNumberRequest> = { peerUserId: 'bob' };

const EVERY_BUNDLE_FIELD: Required<PreKeyBundle> = {
  userId: 'bob',
  deviceId: 'bob-phone',
  identityKey: IDENTITY,
  signedPreKey: EVERY_SIGNED_FIELD,
  oneTimePreKey: EVERY_ONE_TIME_FIELD,
  algorithm: 'x3dh-ed25519-aes256gcm-v1',
};

const EVERY_DEVICE_FIELD: Required<DeviceKeyInfo> = {
  deviceId: 'bob-phone',
  platform: Platform.Android,
  identityKey: IDENTITY,
  publishedAt: 1761100000000,
  remainingOneTimeKeys: 42,
};

const SAFETY_NUMBER = '12345 67890 13579 24680 11223 34455 66778 89900 10293 84756 56473 82910';

describe('the seven keys.* calls put exactly this frame on the wire', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('keys.publish carries every field, the nested members under their exact names, key material untouched', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.keys.publish(EVERY_PUBLISH_FIELD).catch(() => {});
    await until(() => socket.requestsTo('keys.publish').length > 0);

    assert.deepEqual(frameOf(socket, 'keys.publish'), {
      keys: ['id', 'target', 'body'],
      target: 'keys.publish',
      body: EVERY_PUBLISH_FIELD,
    });

    // The binder matches nested members case-sensitively and keyId / publicKey / signature are
    // required there: these names, exactly, or the whole call is 1000. createdAt is a bare integer.
    // 嵌套成员按大小写绑定，三个必填成员名必须一字不差，否则整个调用就是 1000。createdAt 是裸整数。
    const raw = rawOf(socket, 'keys.publish');
    assert.ok(
      raw.includes(
        `"signedPreKey":{"keyId":"spk-7","publicKey":"${SPK_PUBLIC}","signature":"${SPK_SIGNATURE}","createdAt":1761100000000}`,
      ),
      raw,
    );
    assert.ok(raw.includes(`"oneTimePreKeys":[{"keyId":"otk-1","publicKey":"${OTK_1}"},{"keyId":"otk-2","publicKey":"${OTK_2}"}]`));
    // Byte for byte: `+`, `/` and `=` are not escaped, swapped for base64url or stripped.
    assert.ok(raw.includes(`"identityKey":"${IDENTITY}"`));
  });

  it('keys.publish names no device and no platform — the server takes both from the connection', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.keys
      .publish({ identityKey: IDENTITY, signedPreKey: { keyId: 'spk-1', publicKey: SPK_PUBLIC, signature: SPK_SIGNATURE } })
      .catch(() => {});
    await until(() => socket.requestsTo('keys.publish').length > 0);

    // A minimal publish adds nothing: no createdAt (absent is "now"), no algorithm (the server's
    // default), no empty pool, no deviceId and no platform.
    // 最小发布不补任何东西：没有 createdAt（缺席即现在）、没有 algorithm（服务端默认）、没有空池、没有 deviceId 与 platform。
    assert.deepEqual(frameOf(socket, 'keys.publish').body, {
      identityKey: IDENTITY,
      signedPreKey: { keyId: 'spk-1', publicKey: SPK_PUBLIC, signature: SPK_SIGNATURE },
    });
    const raw = rawOf(socket, 'keys.publish');
    assert.doesNotMatch(raw, /"deviceId"|"platform"/);
  });

  it('keys.upload carries its keys under "keys", each with exactly keyId and publicKey', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.keys.upload(EVERY_UPLOAD_FIELD).catch(() => {});
    await until(() => socket.requestsTo('keys.upload').length > 0);

    assert.deepEqual(frameOf(socket, 'keys.upload'), {
      keys: ['id', 'target', 'body'],
      target: 'keys.upload',
      body: EVERY_UPLOAD_FIELD,
    });
    assert.ok(
      rawOf(socket, 'keys.upload').includes(
        `"body":{"keys":[{"keyId":"otk-1","publicKey":"${OTK_1}"},{"keyId":"otk-2","publicKey":"${OTK_2}"}]}`,
      ),
    );
  });

  it('keys.remaining and keys.devices send an empty body by default, and the id as given', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.keys.remaining().catch(() => {});
    void client.keys.remaining(EVERY_REMAINING_FIELD).catch(() => {});
    void client.keys.devices().catch(() => {});
    void client.keys.devices(EVERY_DEVICES_FIELD).catch(() => {});
    await until(() => socket.requestsTo('keys.devices').length > 1);

    assert.deepEqual(frameOf(socket, 'keys.remaining', 0), { keys: ['id', 'target', 'body'], target: 'keys.remaining', body: {} });
    assert.deepEqual(frameOf(socket, 'keys.remaining', 1).body, { deviceId: 'device-2' });
    assert.deepEqual(frameOf(socket, 'keys.devices', 0), { keys: ['id', 'target', 'body'], target: 'keys.devices', body: {} });
    assert.deepEqual(frameOf(socket, 'keys.devices', 1).body, { userId: 'bob' });
  });

  it('keys.claim, keys.revoke and keys.safetyNumber send their ids and nothing else', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.keys.claim(EVERY_CLAIM_FIELD).catch(() => {});
    void client.keys.revoke(EVERY_REVOKE_FIELD).catch(() => {});
    void client.keys.safetyNumber(EVERY_SAFETY_FIELD).catch(() => {});
    await until(() => socket.requestsTo('keys.safetyNumber').length > 0);

    assert.deepEqual(frameOf(socket, 'keys.claim'), {
      keys: ['id', 'target', 'body'],
      target: 'keys.claim',
      body: { userId: 'bob', deviceId: 'bob-phone' },
    });
    assert.deepEqual(frameOf(socket, 'keys.revoke'), {
      keys: ['id', 'target', 'body'],
      target: 'keys.revoke',
      body: { deviceId: 'old-laptop' },
    });
    assert.deepEqual(frameOf(socket, 'keys.safetyNumber'), {
      keys: ['id', 'target', 'body'],
      target: 'keys.safetyNumber',
      body: { peerUserId: 'bob' },
    });
  });
});

describe('the seven replies decode with every field the server declares', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('the samples set exactly the fields endpoint-inventory.json declares', () => {
    assert.deepEqual(Object.keys(EVERY_SIGNED_FIELD), declared('SignedPreKey'));
    assert.deepEqual(Object.keys(EVERY_ONE_TIME_FIELD), declared('OneTimePreKey'));
    assert.deepEqual(Object.keys(EVERY_BUNDLE_FIELD), declared('PreKeyBundle'));
    assert.deepEqual(Object.keys(EVERY_DEVICE_FIELD), declared('DeviceKeyInfo'));
    assert.deepEqual(Object.keys(EVERY_UPLOAD_FIELD), declared('UploadOneTimeKeysRequest'));
    assert.deepEqual(Object.keys(EVERY_REMAINING_FIELD), declared('RemainingKeysRequest'));
    assert.deepEqual(Object.keys(EVERY_CLAIM_FIELD), declared('ClaimBundleRequest'));
    assert.deepEqual(Object.keys(EVERY_DEVICES_FIELD), declared('DeviceKeysRequest'));
    assert.deepEqual(Object.keys(EVERY_REVOKE_FIELD), declared('RevokeDeviceRequest'));
    assert.deepEqual(Object.keys(EVERY_SAFETY_FIELD), declared('SafetyNumberRequest'));

    // PublishKeysRequest is the server's type less exactly two members, both overwritten from the
    // connection (KeysController.Publish) — a field the server never reads from the body is not one to offer.
    // 少的恰好是服务端用连接覆盖的那两个：服务端从不从请求体读的字段，不该出现在类型上。
    const publish = declared('PublishKeysRequest');
    assert.deepEqual(
      publish.filter((name) => !(name in EVERY_PUBLISH_FIELD)),
      ['deviceId', 'platform'],
    );
    assert.deepEqual(Object.keys(EVERY_PUBLISH_FIELD), publish.filter((name) => name !== 'deviceId' && name !== 'platform'));

    const targets = [
      'keys.publish',
      'keys.upload',
      'keys.remaining',
      'keys.claim',
      'keys.devices',
      'keys.revoke',
      'keys.safetyNumber',
    ];
    const endpoints = loadInventory().endpoints.filter((endpoint) => targets.includes(endpoint.target));
    const shapes = Object.fromEntries(
      endpoints.map((endpoint) => [
        endpoint.target,
        [endpoint.requestType ?? null, (endpoint as { responseType?: string | null }).responseType ?? null],
      ]),
    );
    assert.deepEqual(shapes, {
      'keys.publish': ['PublishKeysRequest', null],
      'keys.upload': ['UploadOneTimeKeysRequest', null],
      'keys.remaining': ['RemainingKeysRequest', 'int'],
      'keys.claim': ['ClaimBundleRequest', 'PreKeyBundle'],
      'keys.devices': ['DeviceKeysRequest', 'List<DeviceKeyInfo>'],
      'keys.revoke': ['RevokeDeviceRequest', null],
      'keys.safetyNumber': ['SafetyNumberRequest', 'string'],
    });
  });

  it('keys.claim returns the bundle with every field, key material exactly as sent, createdAt repaired', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.keys.claim(EVERY_CLAIM_FIELD);
    await until(() => socket.requestsTo('keys.claim').length > 0);
    socket.replyLatest('keys.claim', {
      ...EVERY_BUNDLE_FIELD,
      signedPreKey: { ...EVERY_SIGNED_FIELD, createdAt: '1761100000000' },
    });

    const bundle = await pending;
    assert.deepEqual(bundle, EVERY_BUNDLE_FIELD);
    assert.equal(bundle.identityKey, IDENTITY);
    assert.equal(bundle.signedPreKey.signature, SPK_SIGNATURE);
  });

  it('a claim from an empty pool succeeds with no oneTimePreKey — absent, and a null made absent too', async () => {
    // The server omits the key when the pool is empty; the session is opened with the signed prekey
    // alone. Throwing here would turn "weaker first message" into "cannot message this person".
    // 池空时服务端省略这个字段，会话只用签名预密钥建立。在这里抛异常，等于把「第一条消息弱一点」变成「发不了消息」。
    const { client } = await openClient();
    const socket = FakeSocket.latest;
    const { oneTimePreKey: _consumed, ...drained } = EVERY_BUNDLE_FIELD;

    const absent = client.keys.claim(EVERY_CLAIM_FIELD);
    await until(() => socket.requestsTo('keys.claim').length > 0);
    socket.replyLatest('keys.claim', drained);
    const first = await absent;
    assert.deepEqual(first, drained);
    assert.equal('oneTimePreKey' in first, false);

    const nulled = client.keys.claim(EVERY_CLAIM_FIELD);
    await until(() => socket.requestsTo('keys.claim').length > 1);
    socket.replyLatest('keys.claim', { ...drained, oneTimePreKey: null });
    const second = await nulled;
    assert.deepEqual(second, drained);
    assert.equal('oneTimePreKey' in second, false);
  });

  it('keys.remaining answers a bare number — quoted repaired, zero is zero', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const answers = [
      [37, 37],
      ['99', 99],
      [0, 0],
    ] as const;
    for (const [index, [reply, expected]] of answers.entries()) {
      const pending = client.keys.remaining();
      await until(() => socket.requestsTo('keys.remaining').length > index);
      socket.replyLatest('keys.remaining', reply);
      assert.equal(await pending, expected);
    }
  });

  it('keys.devices answers a bare array in no order; every field decodes; none is []', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const listing = client.keys.devices(EVERY_DEVICES_FIELD);
    await until(() => socket.requestsTo('keys.devices').length > 0);
    const laptop = {
      deviceId: 'bob-laptop',
      platform: Platform.Windows,
      identityKey: OTK_2,
      publishedAt: '1761000000000',
      remainingOneTimeKeys: '0',
    };
    socket.replyLatest('keys.devices', [EVERY_DEVICE_FIELD, laptop]);

    // The server lists devices in no particular order, so compare sorted.
    const devices = (await listing).sort((a, b) => a.deviceId.localeCompare(b.deviceId));
    assert.deepEqual(devices, [
      { ...laptop, publishedAt: 1761000000000, remainingOneTimeKeys: 0 },
      EVERY_DEVICE_FIELD,
    ]);
    assert.equal(devices[1]!.platform, 2, 'platform is the integer the server sent');

    const none = client.keys.devices({ userId: 'nobody' });
    await until(() => socket.requestsTo('keys.devices').length > 1);
    socket.replyLatest('keys.devices', []);
    assert.deepEqual(await none, []);

    const omitted = client.keys.devices();
    await until(() => socket.requestsTo('keys.devices').length > 2);
    socket.replyLatest('keys.devices', undefined);
    assert.deepEqual(await omitted, [], 'an envelope with no data is an empty list, not a TypeError');
  });

  it('keys.safetyNumber answers a bare string, returned exactly', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.keys.safetyNumber(EVERY_SAFETY_FIELD);
    await until(() => socket.requestsTo('keys.safetyNumber').length > 0);
    socket.replyLatest('keys.safetyNumber', SAFETY_NUMBER);

    const number = await pending;
    assert.equal(number, SAFETY_NUMBER);
    assert.match(number, /^\d{5}( \d{5}){11}$/);
  });

  it('publish, upload and revoke resolve with nothing', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const publish = client.keys.publish(EVERY_PUBLISH_FIELD);
    const upload = client.keys.upload(EVERY_UPLOAD_FIELD);
    const revoke = client.keys.revoke(EVERY_REVOKE_FIELD);
    await until(() => socket.requestsTo('keys.revoke').length > 0);
    socket.replyLatest('keys.publish', undefined);
    socket.replyLatest('keys.upload', undefined);
    socket.replyLatest('keys.revoke', undefined);

    assert.equal(await publish, undefined);
    assert.equal(await upload, undefined);
    assert.equal(await revoke, undefined);
  });
});

describe('the directory\'s refusals, and what the SDK never does on its own', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('surfaces each refusal as an ImError with the server\'s code and message, none retried', async () => {
    const { client, errors } = await openClient();
    const socket = FakeSocket.latest;

    const unsigned = client.keys.publish(EVERY_PUBLISH_FIELD);
    const unpublished = client.keys.upload(EVERY_UPLOAD_FIELD);
    const noUser = client.keys.claim({ userId: '', deviceId: 'bob-phone' });
    const blank = client.keys.revoke({ deviceId: '' });
    const nobody = client.keys.safetyNumber({ peerUserId: 'carol' });
    await until(() => socket.requestsTo('keys.safetyNumber').length > 0);

    const reply = (target: string, code: number, text: string): void => {
      const request = socket.requestsTo(target)[0]!;
      socket.reply(request.id, target, null, code, { message: text, traceId: `trace-${target}` });
    };
    reply('keys.publish', 1001, 'signedPreKey signature does not verify against identityKey');
    reply('keys.upload', 1002, 'device has not published its identity key');
    reply('keys.claim', 1001, 'userId is required');
    reply('keys.revoke', 1001, 'deviceId is required');
    reply('keys.safetyNumber', 1002, 'one of the parties has published no keys');

    for (const [pending, code, target, text] of [
      [unsigned, ImErrorCode.InvalidArgument, 'keys.publish', 'signedPreKey signature does not verify against identityKey'],
      [unpublished, ImErrorCode.NotFound, 'keys.upload', 'device has not published its identity key'],
      [noUser, ImErrorCode.InvalidArgument, 'keys.claim', 'userId is required'],
      [blank, ImErrorCode.InvalidArgument, 'keys.revoke', 'deviceId is required'],
      [nobody, ImErrorCode.NotFound, 'keys.safetyNumber', 'one of the parties has published no keys'],
    ] as const) {
      await assert.rejects(
        () => pending,
        (error: unknown) =>
          error instanceof ImError &&
          error.code === code &&
          error.message === text &&
          error.target === target &&
          error.traceId === `trace-${target}` &&
          error.isRetryable === false,
        `${target} ${code}`,
      );
      assert.equal(socket.requestsTo(target).length, 1, `${target} was retried`);
    }
    assert.equal(client.state, 'open', 'a refusal touched the connection');
    assert.deepEqual(errors, [], 'a refusal of one call was reported as a client error');
  });

  for (const [code, text, why, algorithm] of [
    [ImErrorCode.UnsupportedOperation, "unknown algorithm 'x3dh-rot13-v1'", 'an algorithm the server does not know', 'x3dh-rot13-v1'],
    [ImErrorCode.QuotaExceeded, 'a user may publish at most 10 devices', 'an eleventh device', 'x3dh-ed25519-aes256gcm-v1'],
  ] as const) {
    it(`keys.publish ${code} (${why}) is an ordinary ImError`, async () => {
      const { client } = await openClient();
      const socket = FakeSocket.latest;

      const pending = client.keys.publish({ ...EVERY_PUBLISH_FIELD, algorithm });
      await until(() => socket.requestsTo('keys.publish').length > 0);
      const request = socket.requestsTo('keys.publish')[0]!;
      socket.reply(request.id, 'keys.publish', null, code, { message: text });

      await assert.rejects(
        () => pending,
        (error: unknown) => error instanceof ImError && error.code === code && error.message === text,
      );
    });
  }

  it('a claim of a device with no keys is 1002, and an unavailable directory 1005 — the envelope with no data at all', async () => {
    // The server omits nulls, so a failed ApiResult arrives with no `data` key: still an ImError, not a
    // TypeError from repairing a bundle that is not there.
    // 服务端省略 null，失败的答复没有 data 键：仍然是 ImError，而不是修复一个不存在的密钥包时抛的 TypeError。
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const revoked = client.keys.claim(EVERY_CLAIM_FIELD);
    const unavailable = client.keys.claim({ userId: 'carol', deviceId: 'carol-phone' });
    await until(() => socket.requestsTo('keys.claim').length > 1);
    const [first, second] = socket.requestsTo('keys.claim');
    socket.deliver({
      id: first!.id,
      target: 'keys.claim',
      status: 0,
      body: { code: 1002, message: 'device has published no keys', serverTime: 1 },
    });
    socket.deliver({
      id: second!.id,
      target: 'keys.claim',
      status: 0,
      body: { code: 1005, message: 'key directory is unavailable', serverTime: 1 },
    });

    await assert.rejects(
      () => revoked,
      (error: unknown) => error instanceof ImError && error.code === ImErrorCode.NotFound && error.message === 'device has published no keys',
    );
    // 1005 is marked retryable, and the SDK still does not retry it: a claim is a write.
    // 1005 被标为可重试，SDK 仍不替你重试：领取是一次写。
    await assert.rejects(
      () => unavailable,
      (error: unknown) => error instanceof ImError && error.code === ImErrorCode.ServiceUnavailable && error.isRetryable,
    );
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(socket.requestsTo('keys.claim').length, 2, 'a refused claim was sent again');
  });

  it('never re-sends a claim whose reply was lost: it consumes a one-time key, so a retry is a second claim', async () => {
    const { client } = await openClient({ requestTimeoutMs: 100 });
    const socket = FakeSocket.latest;

    const pending = client.keys.claim(EVERY_CLAIM_FIELD);
    await until(() => socket.requestsTo('keys.claim').length > 0);

    await assert.rejects(() => pending, (error: unknown) => error instanceof ImError);
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(socket.requestsTo('keys.claim').length, 1, 'a timed-out claim was sent again');
  });

  it('writes no key material into the SDK\'s own log', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const publish = client.keys.publish(EVERY_PUBLISH_FIELD);
    const claim = client.keys.claim(EVERY_CLAIM_FIELD);
    const refused = client.keys.upload(EVERY_UPLOAD_FIELD);
    await until(() => socket.requestsTo('keys.upload').length > 0);
    socket.replyLatest('keys.publish', undefined);
    socket.replyLatest('keys.claim', EVERY_BUNDLE_FIELD);
    socket.reply(socket.requestsTo('keys.upload')[0]!.id, 'keys.upload', null, 1001, { message: 'no valid one-time prekeys supplied' });
    await publish;
    await claim;
    await refused.catch(() => {});

    const text = (await client.log.read()).map((line) => JSON.stringify(line)).join('\n');
    for (const secretish of [IDENTITY, SPK_PUBLIC, SPK_SIGNATURE, OTK_1, OTK_2]) {
      assert.equal(text.includes(secretish), false, 'key material reached the SDK log');
    }
  });

  it('decodes no keys.* event — the server sends none', () => {
    // No frame announces a revoked device, a changed identity key or a low pool; the push-target table
    // agrees, and a decoder for an event that does not exist is a handler nobody will ever call.
    // 吊销、身份变更、池见底都没有推送帧；推送目标表也这么说。
    const { pushTargets } = loadInventory() as unknown as { pushTargets: Record<string, string> };
    assert.ok(Object.keys(pushTargets).length > 0, 'endpoint-inventory.json lists no push targets; regenerate it');
    assert.deepEqual(
      Object.entries(pushTargets).filter(([name, target]) => /key|identity|e2ee/i.test(name) || /key|identity|e2ee/i.test(target)),
      [],
    );
  });
});
