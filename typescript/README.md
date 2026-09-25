# @cyaim/im-client

TypeScript/JavaScript client for Cyaim IM Cloud. Browser, Node and React Native. No runtime
dependencies.

```bash
npm install @cyaim/im-client
```

> ### ⚠️ Not published yet — the line above is the *future* install command
>
> As of **2026-08-23** this package has **never been published to any registry**, and the
> repository has **no git tags** (`git tag` returns nothing; the tag-triggered release workflow
> has therefore never run). Running the command above today gets you a **404**, not the SDK.
> Version `0.9.0` is what the manifest declares, not what a registry serves.
>
> **尚未发布**：上面那行是发布之后的安装方式。截至 2026-08-23，本包从未发布到任何仓库，
> 仓库也还没有任何 git tag，现在跑那行命令只会得到 404。
>
> **What works today / 今天真正能用的方式：**
>
> ```bash
> # From a clone of this repository (submodules not needed for the SDK):
> cd typescript && npm install && npm run build && npm pack
> # then, in your app:
> npm install /path/to/cyaim-im-client-0.9.0.tgz
> ```
>
> A `file:` dependency on `typescript` works too, but `npm pack` is what you want for a
> smoke test: it exercises the same `files` allow-list the real publish will use, so a file
> that is missing from the tarball fails here rather than at a customer.
>
> The registry prerequisites still outstanding are listed in
> [`CONTRACT.md` §9.4](../CONTRACT.md).

```ts
import { ImClient, ImCursorScope, ImCursorStore, MessageContentType } from '@cyaim/im-client';

const im = new ImClient({
  endpoint: 'wss://im.example.com',
  appId: 'your-app-id',
  userId: 'alice',                       // who this token is for; scopes the cursor store
  token: await fetchTokenFromYourBackend(),
  deviceId: stableDeviceUuid,            // stable per installation — see Notes
  platform: 5,                           // Web
  cursorStore: ImCursorStore.localStorage(
    ImCursorScope.of('wss://im.example.com', 'your-app', 'alice')),
  onTokenExpired: () => fetchTokenFromYourBackend(),
});

im.onMessage(async (m) => {
  await saveToYourStore(m);              // durable write first…
  im.commit(m.conversationId, m.seq);    // …then tell the SDK, so a cold start resumes here
});

im.onConversationNeedsReload((id) => reloadFromHistory(id));
im.onState((s) => console.log('connection', s));

await im.connect();
await im.msg.send({ receiverId: 'bob', content: { text: 'hello' } });
```

## The two lines that are easy to skip

**`cursorStore` is required, and `commit()` is not optional.** Together they are what makes the
messages that arrived while your app was closed actually show up.

The SDK keeps two positions per conversation. `deliveredSeq` is the highest seq it has handed to
you in this process — in memory, used for ordering and de-duplication. `committedSeq` is the
highest seq *you* have said you durably stored; it is written to the cursor store and it is the
number reported to the server on reconnect. On every connect the SDK resets `deliveredSeq` to
`committedSeq`, asks `conn.sync` for everything past it, and repairs the gap.

If you never call `commit()`, `committedSeq` stays at zero, the server is told you hold nothing, and
nothing is ever backfilled. The SDK cannot infer durability for you: a listener returning means the
message reached memory, which is exactly the state a crash loses.

Delivery is therefore **at-least-once**. Reconnects, gap repairs and an uncommitted crash all
redeliver. **Be idempotent on `messageId`.**

**The cursor store and your message store have one lifetime.** Whatever destroys one destroys the
other, cursors first. Clearing messages while keeping cursors shows an empty conversation that will
never refill; keeping messages while clearing cursors costs a full re-download and a wave of
duplicates.

| Store | Use |
|---|---|
| `ImCursorStore.localStorage(scope, keyPrefix?)` | Browsers. Throws at construction where there is no `localStorage`, rather than silently forgetting. |
| `ImCursorStore.file(path)` | Node and Electron. Write-then-rename, so a kill mid-write leaves the previous cursors intact. |
| `ImCursorStore.inMemory()` | Explicit opt-out. Warns once, because a client that re-baselines on every launch looks perfectly healthy until someone asks why a day is missing. |
| your own | Implement `load()` / `save(snapshot)`; both may be async. Optional `scope(key)` receives `"{host}\|{appId}\|{userId}"`. |

The store is keyed by `(endpoint host, appId, userId)` — not the device id, since the store is
already local to the device. `userId` is the part that stops account switching on a shared handset
from handing one user the other's cursors.

## Offline push

The token comes from your push provider to *your app*; the SDK cannot ask for it. Hand it over and
the SDK does the rest, including re-registering on every reconnect — a vendor may replace a token
while the process is frozen, and the server has no other way to learn it.

```ts
im.push.setToken('fcm', tokenFromYourProvider);   // cached if offline, sent on the next connect
await im.logout();                                 // push.unregister, THEN close the socket
```

`provider` is one of `apns` `fcm` `huawei` `xiaomi` `oppo` `vivo` `honor`. On Android always send it
explicitly: the platform default is only reliable on iOS, and the server cannot guess which of five
OEM channels a token came from.

Two rules with sharp edges:

- **`logout()`, not `disconnect()`, when the user signs out.** Once the socket closes there is no
  authenticated channel and the token cannot be removed at all. `disconnect()` deliberately never
  unregisters — a dead socket is precisely the state offline push exists to serve.
- **If a client dies without unregistering** — force-quit, crash, uninstall — only your backend can
  clean it up, with `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Without that, the user keeps
  getting notifications on a handset that is gone.

**Notification text is set by your server, not by this SDK.** A message sent from here whose
`options.pushConfig` has a non-empty `title` or `body` is refused with `1103` (`ImErrorCode.Forbidden`). That text
would replace the notification template that names the sender, and moderation never reads it.
Leave both empty and the recipient's notification is built from the message itself; `sound`,
`channelId`, `badgeCount` and `payload` stay open to clients. For custom text ("your order has
shipped"), send the message from your backend through `/v1` or the server SDK, which may set them.
The same rule, also `1103`, refuses an image, voice, video or file message with `persistent: false`
or `onlineOnly: true` while the app moderates content. See CONTRACT.md §2.

## What this SDK does that a hand-rolled client usually does not

**Survives a cold start without losing messages.** See above. This is the one that is invisible when
it is wrong: no error, no log line, just a conversation missing a stretch nobody can explain.

**Reconnects without stampeding.** A gateway is stateful, so a rolling update drops every socket on
the node being replaced — and every one of those clients reconnects at the same instant. Delays here
use full jitter (a uniform random draw from `0..ceiling`, ceiling doubling to 30s) rather than a
fixed backoff, because that is what actually de-synchronises a fleet. A fixed or lightly-jittered
backoff reconnects the whole node's worth of clients in the same second, at the service that has
just come back up.

**Tells "you were kicked" apart from "the network died".** They look identical at the socket level
and need opposite responses. The server closes with a reason of `im-kick:{Reason}`; the SDK stops
reconnecting for terminal reasons (another device took over, banned, revoked) and asks
`onTokenExpired` for a fresh token when the reason is expiry.

**Repairs gaps, and pages while it does.** Every message carries a gap-free per-conversation `seq`.
When an arriving message skips a number the SDK pulls the missing range with `msg.sync` before
delivering, so the application never sees a conversation jump forward and then fill in behind it.
The server clamps `msg.sync` to 500 rows and reports `hasMore` on the *raw* window — a short page is
normal — so the repair loops on `hasMore`, never on how many messages came back. `conn.sync` pages
the same way, and `conversationCursor` only advances once a run has read every page.

**Swaps an expired token without reconnecting.** A request answered `1101` triggers `conn.reauth` on
the socket that is already open, then the request is reissued once. On the flaky network where
tokens tend to expire unnoticed, a reconnect is exactly what you were trying to avoid.

**Deduplicates sends.** `clientMsgId` is generated automatically if you do not supply one, so a
retry after a timeout returns the original result instead of sending twice.

## API

Methods are grouped into namespaces named exactly for the endpoint prefix, and each method is named
for the endpoint's method part with no synonyms — `im.msg.recall(…)` is `msg.recall`, so a bug
report can be grepped rather than translated.

| Namespace | Methods |
|---|---|
| `im.conn` | `heartbeat` `reauth` `sync` — the SDK drives all three; public for the odd case |
| `im.msg` | `send` `sync` `history` `recall` `delete` `edit` `forward` `react` `receipt` `typing` · `pin` `unpin` `pins` `favourite` `unfavourite` `favourites` `burn` `search` `receiptDetail` |
| `im.conv` | `list` `get` `read` `setting` `delete` `clear` `unreadTotal` · `markUnread` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` · `setStatus` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `blockList` `block` `unblock` · `setRemark` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` · `transfer` `applicationList` `handleApplication` `setRole` `mute` `muteMember` `setNickname` `announcement` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` `clicked` `setToken` |
| `im.moderation` | `report` |
| `im.diag` | `logRequests` `logUploaded` — the client drives both; ordinary applications never call them |
| `im.desk` | `request` `accept` `transfer` `close` `status` `queue` `rate` `canned` `suggest` |

That is tiers **T0, T1, T2 and T3 in full, plus the whole of `desk.*` from T4** — 82 of the
server's 107 endpoints, verified against `sdk/endpoint-inventory.json` by the test suite rather than
counted by hand. The names after the `·` are T3. The other 25 endpoints of T4 go through `invoke()`
until they are typed.

### Tier T3 — what the signatures do not say

Every T3 method carries its full list of refusals in its doc comment. These are the ones that bite:

- **Message ids leave as strings, and the server insists.** The T3 request bodies declare
  `messageId` as a string server-side, and the socket refuses a JSON number for one with an opaque
  `1000` rather than a `1001` naming the field. The id types here are `string` for that reason and
  for the older one — a snowflake does not survive a JavaScript number.
- **`msg.search` is off unless the tenant turned it on** (`1203`), needs the search add-on (`1204`),
  and is rate limited per user (`1003`, 30 a minute by default) **before** either check — so calls
  against a tenant with search off still spend the budget. Debounce search-as-you-type.
- **`msg.receiptDetail`'s `totalCount` includes the sender**; `readUserIds` never does. Fully read is
  `readCount === totalCount - 1`. The read itself has no size cap: in groups above the tenant's
  receipt limit it is `msg.receipt` that refuses, so nothing is recorded to read.
- **`group.mute` with an `untilMs` in the past mutes indefinitely**, while `group.muteMember` with one
  in the past unmutes. `mute` and `conv.markUnread`'s `unread` both default to `true` when omitted.
- **`group.setRole` is typed to `Member` or `Admin` only.** The server refuses `Owner` but stores
  any other integer, and `0` or `4` are privilege bugs rather than roles.
- **`group.applicationList` returns every status**, not only pending — filter on `status` yourself.
  Called with no argument it lists across every group you manage.
- **`friend.setRemark` without `remark` clears the remark**, while leaving out `tags` keeps them.

Client-level:

| Member | Purpose |
|---|---|
| `connect()` / `disconnect()` / `logout()` | Open, close, and sign out (unregisters push first) |
| `onMessage(fn)` | Every message, in seq order per conversation, gaps repaired |
| `commit(conversationId, seq)` | You have durably stored up to `seq`. Monotonic |
| `onConversationNeedsReload(fn)` | A conversation the SDK declined to backfill; reload it from history |
| `onEvent(target, fn)` | Any other server event (`evt.typing`, `evt.read`, `evt.group`, …) |
| `onState(fn)` | `idle` \| `connecting` \| `open` \| `reconnecting` \| `closed` |
| `onError(fn)` | SDK-level failures with no caller to reject — cursor store, interrupted resume |
| `deliveredSeq` / `committedSeq` / `cursorSnapshot()` | What the SDK believes, so you can check it |
| `restoredConversations` / `cursorStoreFailed` | Fresh install, or a store that would not load? |
| `invoke<T>(target, body, options?)` | Any endpoint not yet in the typed surface |

Every typed call takes one request object plus an optional trailing options bag:

```ts
const controller = new AbortController();
await im.msg.send({ receiverId: 'bob', content: { text: 'hi' } }, { signal: controller.signal });
```

Cancelling abandons the reply. It does **not** cancel the server-side effect — a cancelled
`msg.send` may well have sent the message. Reissue with the same `clientMsgId` and the server
returns the original result rather than a second message.

### `invoke()` — the escape hatch

With 107 endpoints and five release trains, the typed surface will always trail the server. `invoke`
is permanent, shares the typed methods' code path exactly (same timeouts, cancellation and error
mapping), and never touches a cursor.

```ts
// msg.cancelScheduled is tier T4 and not typed yet:
await im.invoke<void>('msg.cancelScheduled', { scheduleId });
```

## Customer-service desk

`desk.*` is the one tier-4 namespace that is typed, because a customer asked for it. Nine verbs move
the *assignment* around a session; **everything either side actually says is an ordinary chat** in
the single conversation between the customer and the desk account, sent with `msg.send` and read
with `msg.history` like any other message.

The customer's half is three calls and one thing to read:

```ts
const session = await im.desk.request({ skill: 'billing', context: { orderId } });
// session.state is Queued, Assigned, or Bot — Bot counts as open. Calling twice returns this
// same session rather than occupying a second agent.

im.onMessage((message) => {
  const notice = readDeskNotification(message);      // null for ordinary chat
  if (!notice) return renderChat(message);

  switch (notice.code) {
    case DeskNotificationCode.Queued:          return say('Finding someone for you…');
    case DeskNotificationCode.Assigned:        return say(`${notice.agentId} is with you now`);
    case DeskNotificationCode.RatingRequested: return showSurvey(notice.starTags, notice.askResolved);
    default:                                   return renderNotice(notice);
  }
});

await im.desk.rate({ sessionId: session.sessionId, score: 5 });   // answers the 1807 above
```

`readDeskNotification` exists because desk events **are messages** — which is what makes a
transcript explain itself six months later, and what puts frames in your `onMessage` handler that
must not be drawn as chat. It checks the content type *and* the 1801–1807 band together, because the
same seven numbers are account error codes elsewhere on this platform.

An agent's half subscribes instead:

```ts
setInterval(() => im.desk.status({ status: AgentStatus.Available }), 30_000);   // also the heartbeat

im.onDeskEvent((event) => {
  if (event.event === 'desk.agent') return standDown(event.connectionId);  // another tab took over
  // event.session is null only on a forced release.
  const change = knownDeskChange(event.change);
  if (change) apply(change, event.session);
});
```

Four things worth knowing before you build on it:

- **`desk.status` is the heartbeat.** Availability and liveness are one call on purpose, so send it
  on a timer and not only when the agent flips a switch — an agent whose console went quiet is
  reclaimed and their sessions requeued.
- **`transfer` names exactly one of `toAgentId`, `toSkill`, `toQueue`,** and the type enforces it, so
  a workbench that names two does not compile rather than failing 1001 mid-handover.
- **Omitted is not null on `desk.close` and `desk.rate`.** The server reads an absent field as "the
  agent did not fill this in", and `inviteRating` omitted means **true** — the only way to close
  without asking for a rating is to send `inviteRating: false`.
- **`desk.canned` does not narrow `personal` replies to you — pass your own member id.**
  `ownerMemberId` is a filter, not a guard: absent means "do not filter by owner", which returns
  every member's private phrasebook, and naming someone else's id returns theirs. A workbench that
  calls `im.desk.canned()` with no argument puts colleagues' private drafts on the agent's screen.
  The caller-narrowing behaviour lives only on the console route.

  ```ts
  const mine = await im.desk.canned({ ownerMemberId: me.memberId });   // shared + mine
  const everyones = await im.desk.canned();                            // shared + everybody's personal
  ```

`1205 ConcurrencyLimitExceeded` on `desk.accept` means this agent is at the capacity they declared;
the fix is to finish a session, not to retry, which is why it is not in the retryable set. An empty
queue is `1002`, not an empty success.

## Errors

Every failure is an `ImError` with `code`, `message`, `traceId`, `target`, `isRetryable` and
`requiresReauth`. Branch on `code`, never on the message text.

```ts
try {
  await im.msg.send({ receiverId: 'bob', content: { text: 'hi' } });
} catch (e) {
  if (e instanceof ImError && e.code === ImErrorCode.RateLimited) showBackoffToast();
  else if (e instanceof ImError) report(e.code, e.traceId);   // traceId makes it one query, not a guess
}
```

- `isRetryable` is exactly `1000` `1003` `1004` `1005`. `requiresReauth` is `1100` `1101` `1102`.
  Everything else is terminal: retrying produces the same answer.
- **The SDK never auto-retries a business call.** It retries the connection and its own gap repair.
  A silent re-send on `1003 RateLimited` hides rate limiting from the UI that has to explain it.
- `1203 FeatureNotEnabled` is never cached locally — a tenant can flip a feature flag at runtime, and
  a client that remembers "typing is off" stays broken until the app restarts.
- Requests issued while offline reject immediately with `1005`; they are not queued. A `msg.send`
  buffered across a five-minute outage arrives in a conversation that has moved on, and only your
  app knows whether it is still worth sending.
- A socket that drops with requests in flight fails them `1004 Timeout`, not `1005` — 1005 would
  claim the call was never delivered, and the SDK does not know that.
- **`im.push.clicked` is the one exception to all of the above, and the only one.** It resolves
  whatever the server says: a `2401 PushDeliveryNotFound` (the record aged out after seven days, or
  the notification did not come from this platform) is logged through `console.debug` and swallowed.
  It is a statistic, nobody in the app is waiting on it, and the natural call site is a notification
  tap — where an unhandled rejection is a red screen for a tap that worked. The cost is real and
  worth naming: a deployment whose click funnel reads zero forever leaves no evidence above verbose
  logging, so check the funnel on the tenant push screen rather than waiting for an error. An
  `AbortError` still propagates — cancellation is not a server outcome (`CONTRACT.md` §7.5).
- `status: 2` (no such endpoint on this deployment) surfaces as `1008 UnsupportedOperation`, which is
  the signal that the SDK is newer than the server it is talking to.

## Notes

- **Never put an AppSecret in client code.** The client only ever holds a short-lived user token
  minted by your backend, and never calls the `/v1` REST API — that is your backend's surface.
- `deviceId` must be stable for a given installation. The multi-device policy uses it to tell a
  reconnect apart from a second device, and a random value per launch will make users kick
  themselves offline.
- Order messages by `seq`, never by timestamp. Client clocks are wrong and arrival order is not
  send order.
- Put `objectKey` from `media.uploadTicket` in the message, never `downloadUrl`. Every reader signs
  their own short-lived link, which is what makes expiry and revocation possible at all.
- Enums are open: an unknown `contentType` from a newer server keeps its raw number rather than
  being coerced to a default you would then render wrongly.
- `im.push` on the web is only useful where the deployment supports Web Push. A tab that stays open
  gets its messages over the live socket.

## Versioning

`ImSdk.version` is this package; `ImSdk.contractVersion` is the client contract all five SDKs
implement, and the SDK sends its own version as the `cv` handshake parameter. A support ticket then
carries both without anyone having to ask.

The five SDKs move in lockstep: one version number across TypeScript, Kotlin, Swift, Dart and Unity,
bumped together even when only one platform changed. See [`CHANGELOG.md`](CHANGELOG.md).

## Testing

```bash
npm install
npm test
```

The suite drives a fake WebSocket through `webSocketImpl`, because every behaviour worth testing
here — reconnect policy, kick classification, gap repair, cold-start cursors — is defined by what
happens when a socket dies, and a real one cannot be made to die on cue. It runs on Node's built-in
test runner, so the package keeps its zero-runtime-dependency footprint.

Tests compile to ESM alongside the sources, exactly as the shipped build does. That is deliberate:
transpiling them to CommonJS instead would hide whether the published package is importable by Node
at all.

Three things are checked in ways worth knowing about:

- **The backoff is checked statistically** — 5000 draws must populate every decile of `0..ceiling`
  with none dominant, which a fixed backoff or a ±10% jitter would fail — and `BASE_DELAY_MS` /
  `MAX_DELAY_MS` are asserted against the values the other SDKs use, since a fleet of mixed clients
  only de-synchronises evenly if every SDK draws from the same interval.
- **Tier coverage is measured, not claimed.** `coverage.test.ts` drives every typed method with a
  recording invoker and compares the targets against `sdk/endpoint-inventory.json`, so "T3 is
  complete" is something the suite can fail on. `t3.test.ts` then pins every T3 request body on
  the wire — key set, values and JSON kind — because a field of the wrong kind is what the server's
  socket binder turns into an unexplained `1000`.
- **Adoption ordering is tested with a store that blocks inside `save`**, so "the next `conn.sync`
  page had not gone out yet" is observed rather than inferred — the ordering it asserts is one no
  amount of polling could see.
