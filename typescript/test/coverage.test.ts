import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';

import {
  ConnApi,
  ConvApi,
  DiagApi,
  FriendApi,
  GroupApi,
  MediaApi,
  ModerationApi,
  MsgApi,
  PushApi,
  UserApi,
  type ImInvoker,
} from '../src/api.js';
import { ImClient } from '../src/client.js';
import { CONTRACT_VERSION } from '../src/version.js';

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

interface Inventory {
  contractVersion: string;
  tiers: Record<string, { targets: string[] }>;
  endpoints: Array<{ target: string }>;
}

function loadInventory(): Inventory {
  // The compiled tests run from `dist-test/test`, the sources from `test`. Walk up until the
  // generated inventory turns up rather than hard-coding a depth that differs between the two.
  let directory = dirname(fileURLToPath(import.meta.url));

  for (let depth = 0; depth < 6; depth++) {
    const candidate = join(directory, 'endpoint-inventory.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Inventory;
    directory = resolve(directory, '..');
  }

  throw new Error('sdk/endpoint-inventory.json not found above the test directory');
}

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

  for (const tier of ['T0', 'T1', 'T2'] as const) {
    it(`types every endpoint in ${tier}`, () => {
      const missing = inventory.tiers[tier]!.targets.filter((target) => !covered.has(target));
      assert.deepEqual(missing, [], `${tier} is not complete: ${missing.join(', ')}`);
    });
  }

  it('does not half-type a tier it has not committed to', () => {
    // A partially typed tier is worse than an untyped one: a developer cannot tell which half is
    // there, and finds out one endpoint at a time. Everything beyond T2 goes through `invoke()`,
    // which is documented and obviously an escape hatch.
    const shipped = new Set([
      ...inventory.tiers['T0']!.targets,
      ...inventory.tiers['T1']!.targets,
      ...inventory.tiers['T2']!.targets,
    ]);

    const strays = [...covered].filter((target) => !shipped.has(target));
    assert.deepEqual(strays, [], `typed but not in T0–T2: ${strays.join(', ')}`);
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
