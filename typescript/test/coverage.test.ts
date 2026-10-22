import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  ConnApi,
  ConvApi,
  DeskApi,
  DiagApi,
  FriendApi,
  GroupApi,
  KeysApi,
  MediaApi,
  ModerationApi,
  MsgApi,
  PushApi,
  RoomApi,
  UserApi,
  type ImInvoker,
} from '../src/api.js';
import { ImClient } from '../src/client.js';
import { CONTRACT_VERSION } from '../src/version.js';
import { loadInventory } from './inventory.js';

/**
 * Tier coverage, measured rather than claimed.
 *
 * `sdk/endpoint-inventory.json` is generated from the server, and its `tiers` block is the
 * authority on what each tier contains. This test drives every typed method with a recording
 * invoker and compares the targets that come out against that list, so "T1 is done" is a fact the
 * suite can fail on rather than a line in a README.
 *
 * It also catches the failure mode CONTRACT §4.2 exists to prevent: a method that quietly calls a
 * different endpoint than its name says. A synonym or a typo shows up here as a missing target and
 * an unexpected one, in the same run.
 *
 * 覆盖率是测出来的，不是声称的：用记录型 invoker 调一遍所有类型化方法，
 * 把落到线上的 target 与 inventory 里该层级的清单对齐。
 */

/** Calls every method on every namespace and collects the targets they put on the wire. */
function typedTargets(): Set<string> {
  const targets = new Set<string>();

  const io: ImInvoker = {
    request<T>(target: string): Promise<T> {
      targets.add(target);
      // Never settles. These calls are here to be observed, not awaited.
      return new Promise<T>(() => {});
    },
  };

  const namespaces = [
    new ConnApi(io),
    new MsgApi(io),
    new ConvApi(io),
    new UserApi(io),
    new FriendApi(io),
    new GroupApi(io),
    new MediaApi(io),
    new PushApi(io, () => true),
    new ModerationApi(io),
    new DeskApi(io),
    new RoomApi(io),
    new KeysApi(io),
    new DiagApi(io),
  ];

  for (const namespace of namespaces) {
    const prototype = Object.getPrototypeOf(namespace) as object;
    for (const name of Object.getOwnPropertyNames(prototype)) {
      if (name === 'constructor') continue;

      const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
      if (typeof descriptor?.value !== 'function') continue;

      try {
        void (descriptor.value as (...args: unknown[]) => unknown).call(namespace, {});
      } catch {
        // A method that validates its argument is still a method; the target is what matters.
      }
    }
  }

  return targets;
}

describe('tier coverage', () => {
  const inventory = loadInventory();
  const covered = typedTargets();

  it('implements the contract version the inventory declares', () => {
    assert.equal(CONTRACT_VERSION, inventory.contractVersion);
  });

  for (const tier of ['T0', 'T1', 'T2', 'T3'] as const) {
    it(`types every endpoint in ${tier}`, () => {
      const missing = inventory.tiers[tier]!.targets.filter((target) => !covered.has(target));
      assert.deepEqual(missing, [], `${tier} is not complete: ${missing.join(', ')}`);
    });
  }

  /**
   * The first deliberate exception to "T0–T3 and nothing else", and the reason it is an exception
   * rather than a hole: T4's rule is "correctly typed when a customer asks", and the customer
   * asked. `desk.*` is typed **whole** — all nine — which is what keeps the rule below meaningful.
   * `room.*`, `msg.stream*`, the seven chat-app calls and `keys.*`, below, are the second to fifth —
   * and with `keys.*` every endpoint of T4 is typed.
   * T4 的规则原话就是「有客户要的时候把它类型化」，而客户来了。desk.* 是整族做完的九条，
   * 这才让下面那条「不许做一半」的规矩仍然有意义。
   */
  const deskTargets = inventory.tiers['T4']!.targets.filter((target) => target.startsWith('desk.'));

  it('types every endpoint in T4 desk.*', () => {
    assert.equal(deskTargets.length, 9, 'the server grew or lost a desk endpoint');

    const missing = deskTargets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `desk is not complete: ${missing.join(', ')}`);
  });

  /**
   * The second family of T4 typed whole, for the same reason and on the same terms: `room.*` carries
   * a rule an integrator cannot guess — a room message has `seq: 0` and must stay out of gap repair —
   * and a family whose rule matters is not one to leave behind `invoke()`. All seven, or none.
   * T4 里第二个整族类型化的：聊天室消息 seq 为 0、必须绕开补洞，这条规矩集成方猜不出来。七条全做，或者一条不做。
   */
  const roomTargets = inventory.tiers['T4']!.targets.filter((target) => target.startsWith('room.'));

  it('types every endpoint in T4 room.*', () => {
    assert.equal(roomTargets.length, 7, 'the server grew or lost a room endpoint');

    const missing = roomTargets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `room is not complete: ${missing.join(', ')}`);
  });

  /**
   * The third: the four streaming calls. Not a namespace of their own — they are `msg.*` endpoints,
   * so they live on `im.msg` — but a family all the same, with a rule a signature cannot carry: the
   * fragments on `evt.stream` are not messages and never touch a cursor, while the message the stream
   * completes into is an ordinary one. All four, or none: half a stream is a placeholder that never
   * clears.
   * 第三族：四条流式调用。它们是 msg.* 端点，所以挂在 im.msg 上；分片不是消息、不碰游标，收尾得到的是普通消息。
   * 四条全做，或者一条不做——只做一半的流，就是一个永远收不掉的占位符。
   */
  const streamTargets = inventory.tiers['T4']!.targets.filter((target) => target.startsWith('msg.stream'));

  it('types every streaming endpoint in T4 msg.stream*', () => {
    assert.deepEqual(
      [...streamTargets].sort(),
      ['msg.streamAbort', 'msg.streamAppend', 'msg.streamBegin', 'msg.streamComplete'],
      'the server grew or lost a streaming endpoint',
    );

    const missing = streamTargets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `streaming is not complete: ${missing.join(', ')}`);
  });

  /**
   * The fourth: the seven calls a chat app reaches for after the basics — scheduled messages (three),
   * conversation folders (three) and translation. Not one namespace, so they are named here one by
   * one, and the list is held to the tier list both ways: a server that grows or loses one of them
   * fails the first assertion, an SDK that types six of them the second.
   * 第四组：聊天应用在基础功能之后最常用的七条——定时消息三条、会话文件夹三条、翻译一条。
   * 它们不属于同一个命名空间，所以逐条点名，并与层级表双向核对。
   */
  const chatAppTargets = [
    'msg.schedule',
    'msg.scheduled',
    'msg.cancelScheduled',
    'conv.folders',
    'conv.upsertFolder',
    'conv.deleteFolder',
    'msg.translate',
  ];

  it('types every scheduled-message, folder and translation endpoint in T4', () => {
    const t4 = inventory.tiers['T4']!.targets;
    assert.deepEqual(
      chatAppTargets.filter((target) => !t4.includes(target)),
      [],
      'the server lost or renamed one of these endpoints',
    );
    assert.deepEqual(
      t4.filter((target) => /^msg\.(?:schedule|scheduled|cancelScheduled|translate)$|^conv\./.test(target)).sort(),
      [...chatAppTargets].sort(),
      'the server grew a conv.* or scheduling endpoint in T4',
    );

    const missing = chatAppTargets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `the seven are not complete: ${missing.join(', ')}`);
  });

  /**
   * The fifth: `keys.*`, the end-to-end encryption key directory, all seven. A family with rules a
   * signature cannot carry — `claim` consumes a one-time key and must never be retried, an empty pool
   * still answers, the nested key members bind case-sensitively — and half a key directory is a
   * session that cannot be opened. All seven, or none.
   * 第五族：端到端加密的密钥目录七条。claim 会消耗一次性密钥、绝不能重试，池空照样答复，嵌套成员按大小写绑定——
   * 只做一半的密钥目录就是建不起来的会话。七条全做，或者一条不做。
   */
  const keysTargets = inventory.tiers['T4']!.targets.filter((target) => target.startsWith('keys.'));

  it('types every endpoint in T4 keys.*', () => {
    assert.deepEqual(
      [...keysTargets].sort(),
      ['keys.claim', 'keys.devices', 'keys.publish', 'keys.remaining', 'keys.revoke', 'keys.safetyNumber', 'keys.upload'],
      'the server grew or lost a key-directory endpoint',
    );

    const missing = keysTargets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `keys is not complete: ${missing.join(', ')}`);
  });

  it('with the five families, types every endpoint in T4', () => {
    // Nothing of T4 is left behind invoke(); an endpoint the server adds to T4 fails here until it is
    // typed or deliberately named as left out.
    // T4 再没有只能靠 invoke() 够到的端点；服务端往 T4 加一条，这里就红，直到它被类型化或被明确列为不做。
    const missing = inventory.tiers['T4']!.targets.filter((target) => !covered.has(target));
    assert.deepEqual(missing, [], `T4 is not complete: ${missing.join(', ')}`);
  });

  it('does not half-type a tier it has not committed to', () => {
    // A partially typed tier is worse than an untyped one: a developer cannot tell which half is
    // there, and finds out one endpoint at a time. Everything beyond T3 goes through `invoke()`,
    // which is documented and obviously an escape hatch — except `desk.*`, `room.*`, `msg.stream*`,
    // the seven chat-app calls and `keys.*`, which are committed to whole, above. T3 joined the committed set whole, all twenty at once, for the same reason.
    // T3 是整层二十条一起加进来的，理由同上：不许做一半。
    const shipped = new Set([
      ...inventory.tiers['T0']!.targets,
      ...inventory.tiers['T1']!.targets,
      ...inventory.tiers['T2']!.targets,
      ...inventory.tiers['T3']!.targets,
      ...deskTargets,
      ...roomTargets,
      ...streamTargets,
      ...chatAppTargets,
      ...keysTargets,
    ]);

    const strays = [...covered].filter((target) => !shipped.has(target));
    assert.deepEqual(strays, [], `typed but not in T0–T3, desk.*, room.*, msg.stream*, the seven or keys.*: ${strays.join(', ')}`);
    assert.equal(covered.size, shipped.size);
  });
});

/**
 * Every method on a namespace is an endpoint. Nothing else may live there.
 *
 * CONTRACT §4.1–4.2: the typed surface is the endpoint list transliterated, so that a reader who
 * knows an endpoint name knows the call, in every language, without a lookup table — and so that a
 * support engineer can grep a bug report for the target that failed. A convenience method with no
 * endpoint behind it breaks both halves of that.
 *
 * This is here because it happened: `sdk/unity` grew an `ImMsgApi.SendTextAsync` for which
 * `msg.sendText` is not and never was an endpoint, and its own deprecation messages pointed at the
 * invented method. The tier-coverage test above could not see it — a phantom that delegates to a
 * real endpoint puts a legitimate target on the wire — so the check has to be on the *name*.
 *
 * 命名空间层只能有端点。上面那条按 target 统计的覆盖率测试看不见这种"转发到真端点的幽灵方法"，
 * 所以这里查的是方法名。
 */
describe('the namespaced surface is endpoints only', () => {
  const inventory = loadInventory();
  const endpoints = new Set(inventory.endpoints.map((endpoint) => endpoint.target));

  /**
   * The push token cache is the only non-endpoint the contract puts on a namespace: §6.2 requires
   * re-registering on every connect, which needs somewhere to keep the token. `setToken` /
   * `clearToken` is the pair, spelled that way in all five SDKs.
   */
  const allowed = new Set([
    'setToken',
    'clearToken',
    'forgetToken', // deprecated alias for clearToken, removed in 2.0
    'registerOnConnect', // the connect-time hook; internal everywhere the language allows one
    'isRegistered',
    'currentToken',
  ]);

  const io: ImInvoker = { request: <T,>(): Promise<T> => new Promise<T>(() => {}) };

  const namespaces: Array<[string, object]> = [
    ['conn', new ConnApi(io)],
    ['msg', new MsgApi(io, () => {}, () => 'id')],
    ['conv', new ConvApi(io)],
    ['user', new UserApi(io)],
    ['friend', new FriendApi(io)],
    ['group', new GroupApi(io)],
    ['media', new MediaApi(io)],
    ['push', new PushApi(io, () => true)],
    ['moderation', new ModerationApi(io)],
    ['desk', new DeskApi(io)],
    ['room', new RoomApi(io)],
    ['keys', new KeysApi(io)],
  ];

  it('names no endpoint the server does not have', () => {
    const strays: string[] = [];

    for (const [prefix, namespace] of namespaces) {
      const prototype = Object.getPrototypeOf(namespace) as object;

      for (const name of Object.getOwnPropertyNames(prototype)) {
        if (name === 'constructor' || allowed.has(name)) continue;

        const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
        if (typeof descriptor?.value !== 'function') continue;

        if (!endpoints.has(`${prefix}.${name}`)) {
          strays.push(`${prefix}Api.${name} implies ${prefix}.${name}`);
        }
      }
    }

    assert.deepEqual(
      strays,
      [],
      'these namespaced methods name endpoints the server does not have. Either the endpoint ' +
        'exists and endpoint-inventory.json needs regenerating, or the method is an invention and ' +
        `belongs on ImClient as a flat alias (CONTRACT §4.2): ${strays.join('; ')}`,
    );
  });

  it('keeps sendText off the namespaced surface', () => {
    // The specific regression, named, so the failure says what went wrong rather than making a
    // reader re-derive it from a list of strays.
    assert.equal(
      (MsgApi.prototype as unknown as Record<string, unknown>)['sendText'],
      undefined,
      'msg.sendText is not an endpoint; the flat im.sendText alias is where it belongs',
    );
  });
});

describe('frozen legacy aliases', () => {
  it('keeps all nine flat convenience methods', () => {
    // They are in every README and sample. They stay, they delegate, and they are the only
    // permitted deviation from "the method name is the endpoint's method part" (CONTRACT §4.2).
    for (const name of [
      'send',
      'sendText',
      'history',
      'recall',
      'react',
      'setTyping',
      'conversations',
      'markRead',
      'totalUnread',
    ]) {
      assert.equal(
        typeof (ImClient.prototype as unknown as Record<string, unknown>)[name],
        'function',
        `${name} was removed; it is frozen surface until 2.0`,
      );
    }
  });

  it('keeps invoke as a permanent escape hatch', () => {
    assert.equal(typeof ImClient.prototype.invoke, 'function');
  });
});
