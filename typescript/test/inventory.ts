import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * `sdk/endpoint-inventory.json` — the generated half of `CONTRACT.md`, and the only thing in this
 * repository that has actually read the server.
 *
 * Two suites read it, so it is loaded in one place: a second copy of the walk-up below would be a
 * second thing to fix the next time the compiled tests move.
 *
 * 清单是这个仓库里唯一真正读过服务端的东西。两个套件都要读它，所以只写一处。
 */
export interface Inventory {
  contractVersion: string;
  tiers: Record<string, { targets: string[] }>;
  /** `requestType` names an entry of `payloadTypes`; null for an endpoint that takes no body. */
  endpoints: Array<{ target: string; requestType?: string | null; tier?: string }>;

  /**
   * The server's request and payload types as **C# declares them** — `string`, `long?`,
   * `List<string>`, an enum's name, another payload type's name. For a request that is exactly what
   * the socket binder holds the body to: it does not go through the platform's JSON options, so a
   * value of the wrong JSON kind is refused rather than coerced (`wire-kinds.test.ts`).
   */
  payloadTypes: Record<string, { properties: Array<{ name: string; type: string; nullable: boolean }> }>;

  /** Bare C# enums, name → integer. On a request each one binds from a JSON integer and nothing else. */
  payloadEnums: Record<string, Record<string, number>>;

  /**
   * The `change` values an `evt.desk` frame can carry, keyed by the server constant's name and in
   * the order `DeskSessionChange.All` declares them.
   *
   * **Present because the generator was taught to emit it, precisely so this list stops being
   * hand-written on both sides.** It is not an `enum` on the server — it is a string-constants
   * class — so it never appeared under `payloadEnums`, and the TypeScript union that mirrors it had
   * nothing to be compared against: the server could grow a fourteenth value, turn the two SPEC
   * documents red in the platform repository, and leave this SDK silently one short. A value the
   * union does not know is a frame `knownDeskChange` returns null for and a workbench drops.
   * 服务端那边是字符串常量类而不是 enum，所以从来不在 payloadEnums 里，而这边镜像它的联合没有比对对象：
   * 服务端加第十四个值会让平台仓的两份 SPEC 变红，却让这个 SDK 悄悄少一个——联合不认识的值就是被丢掉的帧。
   */
  deskChanges: Record<string, string>;
}

export function loadInventory(): Inventory {
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
