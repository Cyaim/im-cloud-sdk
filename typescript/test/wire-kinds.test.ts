import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import type { ImClient } from '../src/client.js';
import {
  ConversationType,
  GroupInviteMode,
  GroupJoinMode,
  GroupRole,
  GroupType,
  MessageContentType,
  MessagePriority,
  MuteMode,
} from '../src/protocol.js';
import { closeAll, openClient } from './doubles.js';
import { FakeSocket, until } from './fake-socket.js';
import { type Inventory, loadInventory } from './inventory.js';

/**
 * Every request field of every T0–T3 endpoint, in the JSON kind the server's C# type binds from.
 *
 * **Why the kind, and why the server's type rather than this SDK's.** The socket binder does not go
 * through the platform's JSON options: it reads each request property with the C# type the DTO
 * declares, and a value of the wrong JSON kind is refused, not coerced. A message id sent as a
 * number to a C# `string`, a size sent as `"1024"` to a `long`, a role sent as `"Admin"` to an enum
 * — each is `status 1 / code 1000` before the endpoint runs, with nothing to say which field. Kotlin
 * and Swift shipped exactly that on eight `msg.*` fields for a month (DECISION-B9 §8). A test that
 * asserts what this SDK *meant* to send cannot see it; one that holds the frame against the server's
 * declared type can. `endpoint-inventory.json` is that type, generated from the server.
 *
 * **What it does not see.** Nested request objects (`conv.setting`'s `setting`, `group.update`'s
 * `update`, `msg.send`'s `options`) are bound by an options-less `Deserialize`, which matches member
 * names case-sensitively; whether the server accepts the camelCase names published here is the
 * server's side of the contract, and the platform repository's binder test judges it. This file
 * checks that the names are the published ones, exactly, and that every value has the right kind.
 *
 * 逐字段断言线上 JSON 类型与服务端 C# 声明一致：套接字绑定器不走平台的 JSON 选项，类型不对不是被转换，
 * 而是在端点运行之前就回 1000，且说不出是哪个字段。Kotlin 与 Swift 就这样在八个 msg.* 字段上错了一个月。
 * 嵌套对象的成员名大小写由服务端那一侧的绑定测试判定，这里只保证名字与清单一字不差、类型正确。
 */

/**
 * Above 2^53 and odd, so a value that went through a double on its way out is visibly a different
 * id — `String(Number(BIG))` is not `BIG`.
 */
const BIG = '360381357961969667';
const C = 'c_wire';
const ID_KEYS = new Set(['messageId', 'messageIds', 'quoteMessageId', 'threadRootId']);

type Keep = <T>(request: T) => T;

interface Row {
  /** What was called. Unique; a typed method's row is named for its target. */
  via: string;
  target: string;
  /**
   * Makes the call. A row that hands its argument through `keep` is also asserted to be a pure
   * pass-through: the body on the wire is the argument, nothing added, dropped or converted.
   */
  send: (client: ImClient, keep: Keep) => Promise<unknown>;
}

const row = (target: string, send: Row['send'], via = target): Row => ({ via, target, send });

/**
 * One row per typed method, every field populated with a non-default value of the SDK's own declared
 * type — no casts, so what is sampled is what the types let a caller write — plus one row per public
 * method that builds its own body (`msg.send`'s defaults, the frozen flat aliases, `setToken`).
 */
const rows: Row[] = [
  // ---- T0
  row('conn.heartbeat', (c) => c.conn.heartbeat()),
  row('conn.reauth', (c, k) => c.conn.reauth(k({ token: 'token-2' }))),
  row('conn.sync', (c, k) =>
    c.conn.sync(k({ convSeqs: { [C]: 42 }, conversationCursor: 1758412790000, cursor: 'sync:2', limit: 100 })),
  ),

  // ---- T1
  row(
    'msg.send',
    (c, k) =>
      c.msg.send(
        k({
          conversationId: C,
          conversationType: ConversationType.Group,
          clientMsgId: 'cm-1',
          contentType: MessageContentType.Image,
          content: { objectKey: 'demo/alice/a.png', width: 640 },
          mentionAll: true,
          mentionedUserIds: ['bob', 'carol'],
          quoteMessageId: BIG,
          threadRootId: BIG,
          options: {
            persistent: false,
            updateConversation: false,
            countUnread: false,
            offlinePush: false,
            pushConfig: {
              title: 'Alice',
              body: 'sent a photo',
              sound: 'ding.caf',
              payload: { deepLink: 'app://c_wire' },
              badgeCount: false,
              channelId: 'im_messages',
            },
            needReceipt: true,
            priority: MessagePriority.High,
            onlineOnly: true,
            noSelfSync: true,
            expireIn: 5000,
            moderationBypass: true,
          },
          sendTime: 1758412790000,
          extensions: { source: 'wire' },
        }),
      ),
    'msg.send by conversationId, every field',
  ),
  row('msg.send', (c) => c.msg.send({ receiverId: 'bob', content: { text: 'hi' } }), 'msg.send by receiverId, defaults filled in'),
  row(
    'msg.send',
    (c, k) =>
      c.msg.send(
        k({
          groupId: 'team',
          contentType: MessageContentType.Text,
          clientMsgId: 'cm-3',
          content: { text: 'hi all' },
          sendTime: 1758412790001,
        }),
      ),
    'msg.send by groupId',
  ),
  row('msg.sync', (c, k) => c.msg.sync(k({ conversationId: C, fromSeq: 5, toSeq: 9, limit: 5, ascending: false }))),
  row('msg.history', (c, k) => c.msg.history(k({ conversationId: C, beforeSeq: 40, limit: 20 }))),
  row('msg.recall', (c, k) => c.msg.recall(k({ conversationId: C, messageId: BIG, reason: 'wrong chat' }))),
  row('msg.delete', (c, k) => c.msg.delete(k({ conversationId: C, messageIds: [BIG, '7'], forEveryone: true }))),
  row('msg.typing', (c, k) => c.msg.typing(k({ conversationId: C, typing: false }))),
  row('conv.list', (c, k) => c.conv.list(k({ updatedAfter: 1758412790000, cursor: 'conv:2', limit: 50 }))),
  row('conv.get', (c, k) => c.conv.get(k({ conversationId: C }))),
  row('conv.read', (c, k) => c.conv.read(k({ conversationId: C, readSeq: 42 }))),
  row('conv.unreadTotal', (c) => c.conv.unreadTotal()),
  row('user.me', (c) => c.user.me()),
  row('user.profile', (c, k) => c.user.profile(k({ userId: 'bob' }))),
  row('user.batchProfile', (c, k) => c.user.batchProfile(k({ userIds: ['bob', 'carol'] }))),
  row('user.updateProfile', (c, k) => c.user.updateProfile(k({ patch: { nickname: 'Al', gender: 1 } }))),
  row('media.uploadTicket', (c, k) => c.media.uploadTicket(k({ fileName: 'a.png', contentType: 'image/png', size: 1024 }))),
  row('media.downloadUrl', (c, k) => c.media.downloadUrl(k({ objectKey: 'demo/alice/a.png', lifetimeSeconds: 600 }))),
  row('push.register', (c, k) => c.push.register(k({ provider: 'fcm', token: 'fcm-token', language: 'zh-CN' }))),
  row('push.unregister', (c) => c.push.unregister()),

  // ---- T2
  row('msg.edit', (c, k) => c.msg.edit(k({ conversationId: C, messageId: BIG, content: { text: 'edited' } }))),
  row('msg.forward', (c, k) =>
    c.msg.forward(
      k({
        sourceConversationId: C,
        messageIds: [BIG, '7'],
        targetConversationIds: ['g_a', 's_b'],
        merge: true,
        mergeTitle: 'Chat history',
        clientMsgId: 'fw-1',
      }),
    ),
  ),
  row('msg.react', (c, k) => c.msg.react(k({ conversationId: C, messageId: BIG, emoji: '👍', add: false }))),
  row('msg.receipt', (c, k) => c.msg.receipt(k({ conversationId: C, messageIds: [BIG, '7'] }))),
  row('conv.setting', (c, k) =>
    c.conv.setting(
      k({
        conversationId: C,
        setting: { pinned: true, muted: MuteMode.Silent, draft: 'half a thought', tags: ['work'], extensions: { color: 'red' } },
      }),
    ),
  ),
  row('conv.delete', (c, k) => c.conv.delete(k({ conversationId: C }))),
  row('conv.clear', (c, k) => c.conv.clear(k({ conversationId: C }))),
  row('user.presence', (c, k) => c.user.presence(k({ userIds: ['bob'] }))),
  row('user.subscribePresence', (c, k) => c.user.subscribePresence(k({ userIds: ['bob'], ttlSeconds: 300 }))),
  row('user.unsubscribePresence', (c, k) => c.user.unsubscribePresence(k({ userIds: ['bob'] }))),
  row('friend.list', (c, k) => c.friend.list(k({ cursor: 'f:2', limit: 100 }))),
  row('friend.add', (c, k) => c.friend.add(k({ userId: 'bob', greeting: 'hi', source: 'search' }))),
  row('friend.handleRequest', (c, k) => c.friend.handleRequest(k({ fromUserId: 'bob', accept: true, reason: 'welcome' }))),
  row('friend.requestList', (c, k) => c.friend.requestList(k({ incoming: false, cursor: 'fr:2', limit: 100 }))),
  row('friend.delete', (c, k) => c.friend.delete(k({ userId: 'bob' }))),
  row('friend.blockList', (c, k) => c.friend.blockList(k({ cursor: 'b:2', limit: 100 }))),
  row('friend.block', (c, k) => c.friend.block(k({ userId: 'mallory', reason: 'spam' }))),
  row('friend.unblock', (c, k) => c.friend.unblock(k({ userId: 'mallory' }))),
  row('group.create', (c, k) =>
    c.group.create(
      k({
        groupId: 'team',
        name: 'Team',
        avatar: 'https://cdn.test/a.png',
        introduction: 'where the team talks',
        type: GroupType.Super,
        memberIds: ['bob', 'carol'],
        joinMode: GroupJoinMode.NeedApproval,
        inviteMode: GroupInviteMode.AdminsOnly,
        maxMemberCount: 500,
        extensions: { dept: 'ops' },
      }),
    ),
  ),
  row('group.info', (c, k) => c.group.info(k({ groupId: 'team' }))),
  row('group.update', (c, k) =>
    c.group.update(
      k({
        groupId: 'team',
        update: {
          name: 'Team 2',
          avatar: 'https://cdn.test/b.png',
          introduction: 'renamed',
          joinMode: GroupJoinMode.Forbidden,
          inviteMode: GroupInviteMode.Forbidden,
          maxMemberCount: 200,
          extensions: { dept: 'eng' },
        },
      }),
    ),
  ),
  row('group.dismiss', (c, k) => c.group.dismiss(k({ groupId: 'team' }))),
  row('group.memberList', (c, k) => c.group.memberList(k({ groupId: 'team', cursor: 'm:2', limit: 100 }))),
  row('group.joined', (c, k) => c.group.joined(k({ cursor: 'j:2', limit: 100 }))),
  row('group.invite', (c, k) => c.group.invite(k({ groupId: 'team', userIds: ['dave'], reason: 'new hire' }))),
  row('group.kick', (c, k) => c.group.kick(k({ groupId: 'team', userIds: ['eve'], reason: 'left the company' }))),
  row('group.quit', (c, k) => c.group.quit(k({ groupId: 'team' }))),
  row('group.join', (c, k) => c.group.join(k({ groupId: 'team', reason: 'colleague' }))),
  row('push.clicked', (c, k) => c.push.clicked(k({ pushId: 'pu_1', messageId: BIG }))),
  row('diag.logRequests', (c) => c.diag.logRequests()),
  row('diag.logUploaded', (c, k) =>
    c.diag.logUploaded(
      k({
        requestId: 'dl_1',
        uploaded: true,
        sizeBytes: 2048,
        coveredFromMs: 1758412700000,
        volatile: true,
        detail: 'trimmed to the newest 2 KiB',
      }),
    ),
  ),
  row('moderation.report', (c, k) =>
    c.moderation.report(k({ targetUserId: 'mallory', conversationId: C, messageId: BIG, category: 'spam', note: 'n' })),
  ),

  // ---- T3
  row('msg.pin', (c, k) => c.msg.pin(k({ conversationId: C, messageId: BIG }))),
  row('msg.unpin', (c, k) => c.msg.unpin(k({ conversationId: C, messageId: BIG }))),
  row('msg.pins', (c, k) => c.msg.pins(k({ conversationId: C }))),
  row('msg.favourite', (c, k) => c.msg.favourite(k({ conversationId: C, messageId: BIG }))),
  row('msg.unfavourite', (c, k) => c.msg.unfavourite(k({ conversationId: C, messageId: BIG }))),
  row('msg.favourites', (c, k) => c.msg.favourites(k({ cursor: 'fav:2', limit: 50 }))),
  row('msg.burn', (c, k) => c.msg.burn(k({ conversationId: C, messageId: BIG }))),
  row('msg.search', (c, k) =>
    c.msg.search(
      k({
        keyword: 'invoice',
        conversationId: C,
        contentTypes: [MessageContentType.Text, MessageContentType.File],
        senderId: 'bob',
        startTime: 1756684800000,
        endTime: 1759276800000,
        cursor: 'search:2',
        limit: 20,
      }),
    ),
  ),
  row('msg.receiptDetail', (c, k) => c.msg.receiptDetail(k({ conversationId: C, messageId: BIG }))),
  row('conv.markUnread', (c, k) => c.conv.markUnread(k({ conversationId: C, unread: false }))),
  row('user.setStatus', (c, k) => c.user.setStatus(k({ status: 'in a meeting' }))),
  row('friend.setRemark', (c, k) => c.friend.setRemark(k({ userId: 'bob', remark: 'Bob (finance)', tags: ['work'] }))),
  row('group.transfer', (c, k) => c.group.transfer(k({ groupId: 'team', newOwnerId: 'bob' }))),
  row('group.applicationList', (c, k) =>
    c.group.applicationList(k({ groupId: 'team', cursor: 'app:2', limit: 100 })),
  ),
  row('group.handleApplication', (c, k) =>
    c.group.handleApplication(k({ groupId: 'team', applicantId: 'u9', accept: true, reason: 'welcome' })),
  ),
  row('group.setRole', (c, k) => c.group.setRole(k({ groupId: 'team', userId: 'bob', role: GroupRole.Admin }))),
  row('group.mute', (c, k) => c.group.mute(k({ groupId: 'team', mute: false, untilMs: 1758499200000 }))),
  row('group.muteMember', (c, k) => c.group.muteMember(k({ groupId: 'team', userId: 'bob', untilMs: 1758499200000 }))),
  row('group.setNickname', (c, k) => c.group.setNickname(k({ groupId: 'team', userId: 'bob', nickname: 'Bobby' }))),
  row('group.announcement', (c, k) => c.group.announcement(k({ groupId: 'team', announcement: 'Standup at 10:00' }))),

  // ---- public methods that build their own body
  row('msg.send', (c) => c.sendText({ receiverId: 'bob' }, 'hi'), 'im.sendText'),
  row('msg.history', (c) => c.history(C, 40, 20), 'im.history'),
  row('msg.recall', (c) => c.recall(C, BIG, 'wrong chat'), 'im.recall'),
  row('msg.react', (c) => c.react(C, BIG, '👍', false), 'im.react'),
  row('msg.typing', (c) => c.setTyping(C, false), 'im.setTyping'),
  row('conv.list', (c) => c.conversations(1758412790000, 'conv:2', 50), 'im.conversations'),
  row('conv.read', (c) => c.markRead(C, 42), 'im.markRead'),
  row('push.register', (c) => c.push.setToken('apns', 'apns-token'), 'push.setToken'),
];

/**
 * Server fields this SDK never sends, each with the reason. Keyed by the server's type name. An
 * entry must name a real field and must never appear in a body; the list may only shrink.
 */
const OMITTED: Record<string, Record<string, string>> = {
  RecallMessageRequest: {
    asAdmin:
      'MsgController.Recall sets it false for every socket call; recalling as an admin is a server-API ' +
      'capability, so no client type carries it',
  },
};

// ------------------------------------------------------------------------------------ the recording

/**
 * The judge in this file reads `endpoint-inventory.json`, which records the server's C# type
 * names but not its binder's rules — it could not see, for instance, that a nested object is
 * matched case-sensitively. So the bodies sampled here are also written to
 * `SDK/wire-samples/typescript.json`, and the platform repository binds every one of them with the
 * server's real socket binder (`SdkWireSampleBindingTests`). This file keeps that recording honest:
 * it fails when what the SDK sends drifts from what is committed.
 *
 * 这里判定用的清单只记 C# 类型名、不记绑定器的规则（例如嵌套对象按大小写精确匹配）。所以采到的
 * 请求体同时落盘到 SDK/wire-samples/typescript.json，由平台仓用服务端真实的绑定器逐个绑定；
 * 本文件负责让那份录制保持真实——SDK 实际发送的东西一漂移就失败。
 */
const RECORD_COMMAND = 'IM_RECORD_WIRE_SAMPLES=1 npm test (in SDK/typescript)';

const RECORDING_COMMENT =
  'RECORDED by SDK/typescript/test/wire-kinds.test.ts from the frames this SDK\'s typed methods put on a fake ' +
  `socket. Do not edit by hand; re-record with ${RECORD_COMMAND}. Judged against the server's real socket ` +
  'binder by IM.Server/tests/IM.Tests.Unit/SdkWireSampleBindingTests.cs in the platform repository.';

/**
 * Fields the SDK fills in from the clock or a random source, per row. Their values change every
 * run, so the recording keeps their JSON kind — which is all the binder decides on — and pins the
 * value: an integer stays an integer, a fraction stays a fraction, a string stays a string.
 */
const GENERATED: Record<string, readonly string[]> = {
  'msg.send by receiverId, defaults filled in': ['clientMsgId', 'sendTime'],
  'im.sendText': ['clientMsgId', 'sendTime'],
};

function pinned(value: unknown): unknown {
  if (typeof value === 'number') return Number.isInteger(value) ? 1758412790000 : 0.5;
  if (typeof value === 'string') return 'generated';
  return value;
}

function wireSampleFile(): string {
  let directory = dirname(fileURLToPath(import.meta.url));
  for (let depth = 0; depth < 6; depth++) {
    if (existsSync(join(directory, 'endpoint-inventory.json'))) return join(directory, 'wire-samples', 'typescript.json');
    directory = resolve(directory, '..');
  }
  throw new Error('sdk/endpoint-inventory.json not found above the test directory');
}

/** One sample per line, in row order, so a re-recording diffs line by line. */
function recordingText(
  recorded: ReadonlyArray<{ target: string; via: string; body: unknown }>,
  requestTypes: ReadonlyMap<string, string | null>,
): string {
  const omitted = Object.entries(OMITTED).flatMap(([type, fields]) =>
    Object.entries(fields).map(([field, reason]) => `    ${JSON.stringify(`${type}.${field}`)}: ${JSON.stringify(reason)}`),
  );
  const samples = recorded.map((sample) => {
    let body = sample.body ?? null;
    const generated = GENERATED[sample.via];
    if (generated && body !== null && typeof body === 'object' && !Array.isArray(body)) {
      body = Object.fromEntries(
        Object.entries(body).map(([key, value]) => [key, generated.includes(key) ? pinned(value) : value]),
      );
    }
    return (
      `    {"target":${JSON.stringify(sample.target)},"type":${JSON.stringify(requestTypes.get(sample.target) ?? null)},` +
      `"via":${JSON.stringify(sample.via)},"body":${JSON.stringify(body)}}`
    );
  });
  return [
    '{',
    `  "$comment": ${JSON.stringify(RECORDING_COMMENT)},`,
    '  "sdk": "typescript",',
    '  "omitted": {',
    omitted.join(',\n'),
    '  },',
    '  "samples": [',
    samples.join(',\n'),
    '  ]',
    '}',
    '',
  ].join('\n');
}

// ---------------------------------------------------------------------------------------- the judge

type Json = Record<string, unknown>;

function isRecord(value: unknown): value is Json {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** The JSON kind a value has on the wire — the thing the binder decides on. */
function jsonKind(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number';
  if (typeof value === 'object') return 'object';
  return typeof value;
}

const INTEGER_TYPES = new Set(['long', 'int', 'short', 'byte', 'sbyte', 'uint', 'ulong', 'ushort']);
const FRACTIONAL_TYPES = new Set(['double', 'float', 'decimal']);

/**
 * Holds a body against the server's declared C# types. Keeps what it has seen across calls, so the
 * completeness check can ask which declared fields were never sampled.
 */
class Judge {
  /** Declared type → the field names some call sent with a non-null value. */
  readonly seen = new Map<string, Set<string>>();
  /** Every payload type a sampled body reached, nested ones included. */
  readonly reached = new Set<string>();

  private problems: string[] = [];

  constructor(
    private readonly inventory: Inventory,
    /** Sampled calls must prove each element type; frames the client builds itself may be empty. */
    private readonly emptyCollectionsProveNothing = true,
  ) {}

  check(typeName: string, body: unknown, path: string): string[] {
    this.problems = [];
    this.object(typeName, body, path);
    return this.problems;
  }

  private object(typeName: string, value: unknown, path: string): void {
    const type = this.inventory.payloadTypes[typeName];
    if (!type) {
      this.problems.push(`${path}: endpoint-inventory.json has no payload type ${typeName}; regenerate it`);
      return;
    }
    if (!isRecord(value)) {
      this.problems.push(`${path}: sent JSON ${jsonKind(value)}; ${typeName} binds from a JSON object`);
      return;
    }

    this.reached.add(typeName);
    let seen = this.seen.get(typeName);
    if (!seen) this.seen.set(typeName, (seen = new Set()));

    for (const [key, field] of Object.entries(value)) {
      const property = type.properties.find((p) => p.name === key);
      if (!property) {
        this.problems.push(
          `${path}.${key}: ${typeName} declares no "${key}" — the server never reads it, and the call succeeds without it`,
        );
        continue;
      }
      if (field === null) {
        if (!property.nullable) this.problems.push(`${path}.${key}: sent null; ${typeName}.${key} is ${property.type}`);
        continue;
      }
      seen.add(key);
      this.value(property.type, field, `${path}.${key}`);
    }
  }

  private value(declared: string, value: unknown, path: string): void {
    const type = declared.trim().replace(/\?$/, '');
    const kind = jsonKind(value);
    const expect = (wanted: string, ok: boolean): void => {
      if (!ok) {
        this.problems.push(
          `${path}: sent JSON ${kind} ${JSON.stringify(value)?.slice(0, 40)}; the server declares ${declared}, ` +
            `which binds from a JSON ${wanted} only — anything else is status 1 / code 1000 before the endpoint runs`,
        );
      }
    };

    if (type === 'string') return expect('string', kind === 'string');
    if (INTEGER_TYPES.has(type)) return expect('integer', kind === 'integer');
    if (FRACTIONAL_TYPES.has(type)) return expect('number', kind === 'integer' || kind === 'number');
    if (type === 'bool') return expect('true/false', kind === 'boolean');
    if (type in this.inventory.payloadEnums) return expect(`integer (${type} is a bare C# enum)`, kind === 'integer');

    const list = /^(?:List|IList|IReadOnlyList|ICollection|IEnumerable)<(.+)>$/.exec(type) ?? /^(.+)\[\]$/.exec(type);
    if (list) {
      expect('array', Array.isArray(value));
      if (!Array.isArray(value)) return;
      if (value.length === 0 && this.emptyCollectionsProveNothing) {
        this.problems.push(`${path}: sampled as [] — an empty array proves nothing about ${list[1]}`);
      }
      value.forEach((element, index) => this.value(list[1]!, element, `${path}[${index}]`));
      return;
    }

    const dictionary = /^(?:Dictionary|IDictionary|IReadOnlyDictionary)<string,\s*(.+)>$/.exec(type);
    if (dictionary) {
      expect('object', isRecord(value));
      if (!isRecord(value)) return;
      const valueType = dictionary[1]!.trim();
      if (/^(?:object|JsonElement|JsonNode)\??$/.test(valueType)) return;
      if (Object.keys(value).length === 0 && this.emptyCollectionsProveNothing) {
        this.problems.push(`${path}: sampled as {} — an empty map proves nothing about ${valueType}`);
      }
      for (const [key, element] of Object.entries(value)) this.value(valueType, element, `${path}.${key}`);
      return;
    }

    if (type in this.inventory.payloadTypes) return this.object(type, value, path);

    this.problems.push(`${path}: this test does not know the C# type ${declared}; teach Judge.value() before trusting a pass`);
  }
}

// ---------------------------------------------------------------------------------------- the run

interface Sample {
  row: Row;
  body: unknown;
  raw: string;
  /** The argument handed through `keep`, or undefined for a row that builds its own body. */
  kept: unknown;
}

interface WireFrame {
  id: string;
  target: string;
  body?: unknown;
}

describe('request wire kinds: every field, as the server declares it', () => {
  const inventory = loadInventory();
  const shipped = ['T0', 'T1', 'T2', 'T3'].flatMap((tier) => inventory.tiers[tier]?.targets ?? []);
  const requestTypes = new Map(inventory.endpoints.map((e) => [e.target, e.requestType ?? null]));

  const samples: Sample[] = [];
  const internal: WireFrame[] = [];
  const judge = new Judge(inventory);
  const problems = new Map<string, string[]>();

  before(async () => {
    FakeSocket.reset();
    const { client } = await openClient();
    const socket = FakeSocket.latest;
    const ours = new Set<string>();

    for (const r of rows) {
      const from = socket.sent.length;
      let kept: unknown;
      const keep: Keep = (request) => {
        kept = request;
        return request;
      };

      const pending = r.send(client, keep);
      pending.catch(() => {});

      const find = (): string | undefined => {
        const frames: string[] = socket.sent.slice(from);
        return frames.find((raw) => {
          const frame: WireFrame = JSON.parse(raw);
          return frame.target === r.target;
        });
      };
      await until(() => find() !== undefined);

      const raw = find()!;
      const frame: WireFrame = JSON.parse(raw);
      ours.add(frame.id);
      samples.push({ row: r, body: frame.body, raw, kept });

      // A bare acknowledgement settles every call — some then fail decoding an absent payload,
      // which is not what this file is about.
      socket.reply(frame.id, frame.target, undefined);
      await pending.then(
        () => {},
        () => {},
      );
    }

    for (const raw of socket.sent) {
      const frame: WireFrame = JSON.parse(raw);
      if (!ours.has(frame.id)) internal.push(frame);
    }

    for (const sample of samples) {
      const requestType = requestTypes.get(sample.row.target);
      problems.set(sample.row.via, requestType ? judge.check(requestType, sample.body, sample.row.via) : []);
    }
  });

  after(closeAll);

  it('has a row for every T0–T3 endpoint, and names each row once', () => {
    const targets = new Set(rows.map((r) => r.target));
    assert.deepEqual(
      shipped.filter((target) => !targets.has(target)),
      [],
      'a typed endpoint with no row here is one whose body nobody checks',
    );
    assert.deepEqual(
      [...targets].filter((target) => !shipped.includes(target)),
      [],
      'a row for an endpoint outside T0–T3',
    );
    assert.equal(new Set(rows.map((r) => r.via)).size, rows.length, 'two rows share a name');
  });

  for (const r of rows) {
    it(`${r.via} sends every field in the JSON kind its server type binds from`, () => {
      const sample = samples.find((s) => s.row === r);
      assert.ok(sample, `${r.via} never reached the socket`);

      const requestType = requestTypes.get(r.target);
      if (!requestType) {
        assert.deepEqual(sample.body, {}, `${r.target} takes no body; the server binds nothing from one`);
        return;
      }

      const found = problems.get(r.via) ?? [];
      assert.deepEqual(
        found,
        [],
        `${r.via} sends ${found.length} field(s) the socket binder refuses or never reads:\n  ${found.join('\n  ')}\n` +
          'Send the server\'s type — a JSON string for a C# string, a bare integer for long/int/enum, true/false for ' +
          'bool. If the server\'s type is what is wrong, change the DTO and regenerate endpoint-inventory.json.',
      );

      if (sample.kept !== undefined) {
        // The interface is the wire type: the typed method must not add, drop or convert anything.
        assert.deepEqual(sample.body, JSON.parse(JSON.stringify(sample.kept)), `${r.via} is not a pass-through`);
      }
    });
  }

  it('samples every field the server declares, or says why this SDK never sends it', () => {
    const unsampled: string[] = [];
    for (const typeName of judge.reached) {
      for (const property of inventory.payloadTypes[typeName]!.properties) {
        if (judge.seen.get(typeName)?.has(property.name)) continue;
        if (OMITTED[typeName]?.[property.name]) continue;
        unsampled.push(`${typeName}.${property.name} (${property.type})`);
      }
    }
    assert.deepEqual(
      unsampled,
      [],
      'these server fields are in no sampled body and not declared omitted, so their kind is unchecked',
    );

    for (const [typeName, fields] of Object.entries(OMITTED)) {
      for (const field of Object.keys(fields)) {
        const declared = inventory.payloadTypes[typeName]?.properties.some((p) => p.name === field);
        assert.ok(declared, `OMITTED names ${typeName}.${field}, which the server does not declare`);
        assert.ok(!judge.seen.get(typeName)?.has(field), `OMITTED says ${typeName}.${field} is never sent, and it was`);
      }
    }
  });

  it('sends every message id as a quoted string with every digit intact', () => {
    // A kind check alone would pass `String(Number(id))`: a string, and a different message.
    const carried = new Set<string>();

    for (const { row: r, body, raw } of samples) {
      if (!isRecord(body)) continue;
      for (const [key, value] of Object.entries(body)) {
        if (!ID_KEYS.has(key)) continue;
        carried.add(r.target);

        if (Array.isArray(value)) {
          assert.deepEqual(value, [BIG, '7'], `${r.via} ${key}`);
          assert.ok(raw.includes(`"${key}":["${BIG}","7"]`), `${r.via} must quote every id in ${key}`);
        } else {
          assert.equal(value, BIG, `${r.via} ${key}`);
          assert.ok(raw.includes(`"${key}":"${BIG}"`), `${r.via} must quote ${key}`);
        }
      }
    }

    // The eight fields Kotlin and Swift sent as numbers are all among these.
    const expected = [
      'msg.send',
      'msg.recall',
      'msg.delete',
      'msg.edit',
      'msg.forward',
      'msg.react',
      'msg.receipt',
      'msg.pin',
      'msg.unpin',
      'msg.favourite',
      'msg.unfavourite',
      'msg.burn',
      'msg.receiptDetail',
      'push.clicked',
      'moderation.report',
    ];
    assert.deepEqual(expected.filter((target) => !carried.has(target)), [], 'a message-id endpoint went unsampled');
  });

  it('sends the three fields msg.send fills in as a string, an enum integer and a unix-ms integer', () => {
    const sample = samples.find((s) => s.row.via === 'msg.send by receiverId, defaults filled in')!;
    assert.ok(isRecord(sample.body));
    assert.equal(jsonKind(sample.body['clientMsgId']), 'string');
    assert.equal(sample.body['contentType'], MessageContentType.Text);
    assert.equal(jsonKind(sample.body['sendTime']), 'integer');
  });

  it('binds the frames the client sends by itself too', () => {
    // conn.sync and diag.logRequests on connect, and any heartbeat that fell inside the run.
    const lenient = new Judge(inventory, false);
    const found: string[] = [];
    for (const frame of internal) {
      const requestType = requestTypes.get(frame.target);
      if (requestType) found.push(...lenient.check(requestType, frame.body, `${frame.target} (sent by the client)`));
    }
    assert.ok(internal.some((frame) => frame.target === 'conn.sync'), 'the connect-time conn.sync was not seen');
    assert.deepEqual(found, []);
  });

  it('has recorded exactly what it sent, for the server\'s binder to judge', () => {
    const file = wireSampleFile();
    const text = recordingText(
      samples.map((sample) => ({ target: sample.row.target, via: sample.row.via, body: sample.body })),
      requestTypes,
    );

    if (process.env['IM_RECORD_WIRE_SAMPLES'] === '1') {
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, text, 'utf8');
      return;
    }

    assert.ok(existsSync(file), `${file} is missing; record it with ${RECORD_COMMAND} and commit it`);
    const committed = readFileSync(file, 'utf8').replace(/\r\n/g, '\n').split('\n');
    const live = text.split('\n');
    const changed: string[] = [];
    for (let i = 0; i < Math.max(committed.length, live.length) && changed.length < 12; i++) {
      if (committed[i] !== live[i]) changed.push(`  line ${i + 1}\n    committed: ${committed[i] ?? '(none)'}\n    sent now:  ${live[i] ?? '(none)'}`);
    }
    assert.deepEqual(
      changed,
      [],
      `what this SDK sends no longer matches SDK/wire-samples/typescript.json:\n${changed.join('\n')}\n` +
        `If the change is intended, re-record with ${RECORD_COMMAND} and commit the file; the platform ` +
        'repository\'s SdkWireSampleBindingTests will judge it against the server\'s real binder.',
    );
  });

  it('can see the defect it exists for', () => {
    // Controls, independent of any row: each body is one the binder refuses or silently ignores, and
    // the judge must say so. A judge that passes these has stopped looking.
    const control = new Judge(inventory);
    const cases: Array<[string, string, unknown]> = [
      ['a message id sent as a number', 'RecallMessageRequest', { conversationId: C, messageId: 7 }],
      ['message ids sent as numbers', 'ReceiptRequest', { conversationId: C, messageIds: [7] }],
      ['a long sent quoted', 'UploadTicketRequest', { fileName: 'a', contentType: 'image/png', size: '1024' }],
      ['an enum sent by name', 'SetRoleRequest', { groupId: 'team', userId: 'bob', role: 'Admin' }],
      ['a bool sent as a number', 'MuteGroupRequest', { groupId: 'team', mute: 1 }],
      ['a nested bool sent quoted', 'UpdateConversationSettingRequest', { conversationId: C, setting: { pinned: 'true' } }],
      ['a misspelled key', 'RecallMessageRequest', { conversationId: C, mesageId: BIG }],
      ['an int sent fractional', 'CursorRequest', { limit: 1.5 }],
    ];
    for (const [shape, typeName, body] of cases) {
      assert.notDeepEqual(control.check(typeName, body, 'control'), [], `the judge accepted ${shape}`);
    }
  });
});
