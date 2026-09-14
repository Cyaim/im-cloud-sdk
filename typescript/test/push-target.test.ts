import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { PushTarget, type PushTargetName } from '../src/protocol.js';

/**
 * `evt.call` and `evt.desk` shipped in the server and in SPEC-02 §2.7 while no client SDK named
 * them (AUDIT-2026-08-21 §6.1) — the frames arrived, nothing matched them, and applications
 * dropped them in silence.
 *
 * `evt.call` is gone from both sides as of 2026-09-14: the server withdrew calling from every
 * product surface, so `PushTarget` no longer declares it and this list no longer expects it. The
 * audit is still why this file exists — `evt.desk` is the half that survived, and it is pinned
 * below on its own. A reader who finds only one of the two names here should read this paragraph
 * rather than assume the other was dropped by accident.
 *
 * The authoritative guard is `PushTargetParityTests` in `tests/IM.Tests.Unit`, which reads all five
 * SDK tables and compares them against `PushTarget` in `ServerPush.cs`; only that one can see the
 * server. This suite exists so the omission is also visible to someone running `npm test` without a
 * .NET SDK on the machine.
 */
describe('push targets', () => {
  it('lists exactly the targets the server can push', () => {
    assert.deepEqual([...Object.values(PushTarget)].sort(), [
      'conn.kick', 'evt.conversationUpdate', 'evt.desk', 'evt.friend',
      'evt.group', 'evt.message', 'evt.messageUpdate', 'evt.presence', 'evt.read',
      'evt.stream', 'evt.system', 'evt.typing',
    ]);
  });

  it('keeps desk inside the union type', () => {
    const desk: PushTargetName = PushTarget.Desk;
    assert.equal(desk, 'evt.desk');
  });
});
