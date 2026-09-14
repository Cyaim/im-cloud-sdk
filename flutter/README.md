# cyaim_im

Dart/Flutter client for Cyaim IM Cloud. iOS, Android, Windows, macOS, Linux and web from one
codebase, with no Flutter dependency — the package is plain Dart, so a CLI tool or a server-side
bot uses the same build.

```bash
dart pub add cyaim_im
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
> ```yaml
> # pubspec.yaml — a path dependency on a clone of this repository
> dependencies:
>   cyaim_im:
>     path: ../im-cloud-sdk/flutter
> ```
>
> A `git:` dependency with `path: flutter` also resolves, but needs a ref that exists —
> and there are no tags, so it would have to be a branch or a commit sha.
>
> The registry prerequisites still outstanding are listed in
> [`CONTRACT.md` §9.4](../CONTRACT.md).

## Quick start

```dart
import 'package:cyaim_im/cyaim_im.dart';
import 'package:path_provider/path_provider.dart';

// Where cursors survive a process restart. Required, with no default — see "Cursors" below;
// this one argument is the difference between resuming and silently losing offline messages.
final Directory dir = await getApplicationSupportDirectory();
final ImClient im = ImClient(ImOptions(
  endpoint: 'wss://im.example.com',
  appId: 'your-app-id',
  token: await fetchTokenFromYourBackend(),
  deviceId: stableDeviceUuid,
  platform: ImPlatform.android,
  cursorStore: ImCursorStore.file(
    '${dir.path}/cyaim-${ImCursorStore.scopeKey(
      endpoint: 'wss://im.example.com',
      appId: 'your-app-id',
      userId: currentUserId,
    )}.json',
  ),
  onTokenExpired: fetchTokenFromYourBackend,
));

im.messages.listen((ImMessage message) async {
  render(message);                                  // delivery is at-least-once:
  await yourDatabase.upsert(message);               // deduplicate on messageId,
  await im.commit(message.conversationId, message.seq); // then say it is durable
});

im.states.listen((ImConnectionState s) => debugPrint('connection $s'));
im.kicks.listen((ImKickEvent k) { if (k.isTerminal) navigateToLogin(); });
im.errors.listen(reportToCrashlytics);
im.conversationNeedsReload.listen(reloadConversationFromHistory);

await im.connect();
await im.msg.send(ImSendMessageRequest.text('hello', receiverId: 'bob'));
```

`example/main.dart` is the same thing you can actually run:

```bash
dart run example/main.dart --endpoint wss://im.example.com --app-id demo --user alice \
  --token "$IM_TOKEN"
```

## Cursors, and the bug this replaces

**Versions before 0.9.0 lost every message that arrived while the app was closed.** The seq cursor
lived in a private map that died with the process, so each launch reported an empty `convSeqs` to
`conn.sync`, got no gaps back — the server can only diff against what you tell it — and then
adopted the server's newest `maxSeq`. Everything in between fell behind the cursor: never
requested, never delivered, no error, no log line, nothing later that corrected it.

The SDK now keeps **two** cursors per conversation:

| | lives | means | reported to the server |
|---|---|---|---|
| `deliveredSeq` | memory only | highest seq handed to your app in this process | no |
| `committedSeq` | the `ImCursorStore` | highest seq you said you had **durably stored** | yes, as `convSeqs` |

Three rules follow, and they are why the API looks the way it does:

- **You call `commit`, the SDK does not.** A listener returning means the message reached your
  process's memory, which is exactly the state a crash loses. Call `im.commit(conversationId, seq)`
  after your own write completes. It is monotonic, so a lower seq is ignored rather than an error —
  which is also how you re-derive cursors from your own database if you ever need to.
- **Delivery is at-least-once.** On every reconnect `deliveredSeq` is pulled back to
  `committedSeq`, so anything delivered but never committed is delivered again. Be idempotent on
  `ImMessage.messageId`.
- **The cursor store and your message store have one lifetime.** Whatever destroys one destroys the
  other, cursors first. Clearing messages but keeping cursors leaves an empty conversation that
  will never refill; clearing cursors but keeping messages costs a full re-download. `im.logout()`
  takes `clearCursors:` for exactly this decision, and defaults to `false` — an app that keeps
  messages for a fast re-login keeps the cursors too.

Scope the store by **(endpoint host, appId, userId)** with `ImCursorStore.scopeKey`. Not the device
id: the file is already local to the device, and it is account switching on a shared handset that
hands one user another user's cursors.

Two more things worth wiring up:

```dart
// A mobile OS can stop the process without warning. A debounced commit that never reached disk
// is a duplicate delivery on the next launch — cheap, but free to avoid.
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused) im.flushCursors();
}
```

If `load()` throws, the SDK does **not** treat it as a fresh install: it raises on `im.errors`,
refuses to adopt, and freezes every cursor for the session (`im.cursorsFrozen`). A failed load and
a fresh install are indistinguishable to the adoption branch, and adopting on a failed load
destroys history that is sitting intact in your own database.

On the **web** there is no filesystem, so `ImCursorStore.file` throws. Implement `ImCursorStore`
over `localStorage` or IndexedDB — it is two methods — or pass `ImCursorStore.inMemory()` and
accept a re-download per tab. `inMemory()` logs one warning saying so, because a silently
non-persisting client is indistinguishable from a working one until a customer reports missing
messages.

## Offline push

The server side of `push.*` has shipped for a while and no client SDK called it, so offline push
was unreachable from any official client. It is wired up now.

**The host app owns token acquisition; the SDK owns token delivery.** Firebase, APNs and every OEM
channel hand the token to the application, not to a library, so this package takes no push plugin
dependency — use whichever one you already have:

```dart
// once at startup, and again whenever the vendor rotates it
await im.push.setToken(ImPushProvider.fcm, await FirebaseMessaging.instance.getToken() ?? '');
FirebaseMessaging.instance.onTokenRefresh.listen(
  (String t) => im.push.setToken(ImPushProvider.fcm, t),
);
```

- `setToken` registers immediately when connected, and again **on every successful connect** — not
  once at install. The vendor may replace a token while the process is frozen and the server has no
  other way to learn it. Re-registering an unchanged token costs no write; the server debounces it.
- **`im.logout()` sends `push.unregister` before closing the socket.** `im.disconnect()` never
  unregisters, and that is the entire point of a push token: a dead socket is precisely the state
  offline push exists to serve. Order matters — after the socket closes there is no authenticated
  channel and the token cannot be removed at all.
- **Android must always send `provider` explicitly.** It fragments across five OEM channels
  (`ImPushProvider.huawei` `xiaomi` `oppo` `vivo` `honor`) and the server cannot guess which one a
  token came from. Empty falls back to the platform default, which is only reliable on iOS.
- If a client dies without unregistering — force-quit, crash, uninstall — its token stays
  registered and the user gets notifications on a device that is gone. Only your backend can clean
  that up: `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Ship that call, or ship the bug.
- **Call `im.push.clicked()` from the tap handler.** APNs and FCM do not report delivery at all, so
  on most deployments the click is the only evidence a notification ever arrived, and the tenant's
  sent → delivered → clicked funnel is blank without it. Pass the payload's `msgId` when the tap
  gave you one; with nothing at all the server attributes this device's newest delivery. It is the
  one call in the package that swallows its own failure — best-effort statistics that nothing in
  your app waits on, and firing it without `await` must not become an unhandled asynchronous error.

## What this SDK does that a hand-rolled client usually does not

**Reconnects without stampeding.** A gateway is stateful, so a rolling update drops every socket on
the node being replaced — and every one of those clients reconnects at the same instant. Delays here
use full jitter (a uniform random draw from `0..ceiling`, ceiling doubling to 30s) rather than a
fixed backoff, because that is what actually de-synchronises a fleet. A fixed or lightly-jittered
backoff reconnects the whole node's worth of clients in the same second, at the service that has
just come back up.

**Tells "you were kicked" apart from "the network died".** They look identical at the socket level
and need opposite responses. The server closes with a reason of `im-kick:{Reason}`; the SDK stops
reconnecting for terminal reasons (another device took over, banned, revoked) and asks
`onTokenExpired` for a fresh token when the reason is expiry. A refused handshake — a 401, a captive
portal — never produces a close frame at all, so it is caught separately and retried.

**Repairs gaps in the message stream, and pages while it does.** When an arriving message skips a
number the client pulls the missing range with `msg.sync` before delivering it, so a conversation
never jumps forward and then fills in behind. Both loops page properly: `conn.sync` until `hasMore`
is false (a user with more than 200 conversations otherwise gets gaps reported for the first page
only), and `msg.sync` until *it* says it is done (the server clamps a range to 500 messages and
computes `hasMore` on the raw window, so a page can be short — even empty — with more behind it).

**Knows when it gave up.** Past `maxAutoRepairSeq` (default 500) the SDK does not backfill: it
advances the cursor past the hole, commits, and raises `conversationNeedsReload`. Both halves
matter. Without the cursor advance every later message looks like a gap over a range you already
declined; without the event the UI keeps a hole nothing will ever mention. Listen to it.

**Renews a token without dropping the socket.** `conn.reauth` costs one frame; a reconnect costs a
handshake and a resume, on the flaky network where tokens tend to expire in the first place.

**Deduplicates sends.** `clientMsgId` is generated automatically if you do not supply one, so a
retry after a timeout returns the original result instead of sending twice. Check
`ImSendResult.deduplicated` if you want to know it happened; getting `true` back is idempotency
working, not a failure.

**Fails fast when offline.** A request issued on a closed socket throws
`ImException(ImErrorCode.connectionLost)` immediately instead of queueing. A chat client that
silently buffers sends produces messages that arrive minutes later with no explanation, by which
time the user has retyped them. You know whether a message is still worth sending; the SDK does not.

## The typed surface

Namespaces are named exactly for the endpoint prefix, and each method is the endpoint's method part
with no synonyms — so `im.group.memberList(…)` is `group.memberList` and a bug report naming an
endpoint greps straight to the call.

| Namespace | Methods |
|---|---|
| `im.conn` | `heartbeat` `reauth` `sync` |
| `im.msg` | `send` `sync` `history` `recall` `delete` `typing` `edit` `forward` `react` `receipt` |
| `im.conv` | `list` `get` `read` `unreadTotal` `setting` `delete` `clear` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `blockList` `block` `unblock` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` `clicked` · plus `setToken` / `clearToken` for the lifecycle above |
| `im.moderation` | `report` |

That is contract tiers **T0, T1 and T2 complete** — session floor, 1:1 chat MVP, social graph and
groups. Every method takes exactly one request object named for the server DTO, so the server
adding an optional field stays additive instead of breaking your call sites.

Client-side members:

| Member | Purpose |
|---|---|
| `connect()` / `disconnect()` / `logout()` / `dispose()` | Lifecycle. `logout` unregisters push first |
| `messages` | `Stream<ImMessage>` — in seq order per conversation, gaps repaired |
| `commit(conversationId, seq)` | You stored it durably; advance the persisted cursor |
| `conversationNeedsReload` | `Stream<String>` — a gap the SDK deliberately did not backfill |
| `errors` | `Stream<ImException>` — session failures nothing else is awaiting |
| `states` / `kicks` | Connection state; server-ended sessions (`isTerminal`) |
| `events(target)` | `Stream<Map<String, dynamic>>` for any other server event (`evt.typing`, `evt.read`, `evt.group`, …) |
| `deliveredSeq` / `committedSeq` / `cursors` / `flushCursors()` | Cursor inspection and flushing |
| `invoke<T>(target, body, [cancel])` | Any endpoint not yet in the typed surface |

`events(target)` subscribes lazily and tears the subscription down when the last listener leaves, so
a screen that stops listening stops costing anything.

### `invoke` — the escape hatch

112 endpoints and five release trains mean the typed surface will always trail the server. `invoke`
is the difference between "wait for the next SDK release" and "ship on Friday". It shares one code
path with every typed method — same timeouts, same cancellation, same error mapping — and it never
touches a cursor.

```dart
// group.transfer is tier T3 and not typed yet:
await im.invoke<void>('group.transfer', <String, Object?>{
  'groupId': groupId,
  'newOwnerId': userId,
});
```

### Cancelling

Dart futures are not cancellable and this package takes no `package:async` dependency, so
cancellation is an explicit token — the trailing argument on every typed call.

```dart
final ImCancelToken token = ImCancelToken();
final Future<ImPage<ImMessage>> page = im.msg.history(request, token);
// …the user leaves the screen
token.cancel();
```

Cancelling abandons the reply and removes the pending entry. **It does not cancel the server-side
effect** — a cancelled `msg.send` may well have sent the message, which is what `clientMsgId`
idempotency is for. It raises `ImCancelledException`, never an `ImException` with an invented code,
so it does not land in the same `catch` as a rate limit.

## Errors

Every failure is an `ImException` carrying `code`, `message`, `traceId`, `target`, `isRetryable`
and `requiresReauth`. **Branch on `code`, never on message text.** Quote `traceId` and `target` in a
support ticket and the server-side log line can be found in one query.

```dart
try {
  await im.msg.send(request);
} on ImException catch (e) {
  switch (e.code) {
    case ImErrorCode.rateLimited:       // 1003 — back off and say so in the UI
    case ImErrorCode.quotaExceeded:     // 1202 — tenant billing; never retry
    case ImErrorCode.featureNotEnabled: // 1203 — switched off *right now*, may come back
    case ImErrorCode.moderationRejected:
  }
}
```

- `isRetryable` is exactly `1000` `1003` `1004` `1005`, and the same four in all five SDKs.
  Everything else is terminal. **The SDK never auto-retries a business call** — it retries the
  connection and its own gap repair, and lets you decide the rest.
- Never latch `1203 FeatureNotEnabled` locally. A tenant can flip the flag at runtime, and a client
  that remembers "typing is off" stays broken until the app restarts.
- `status: 2` — the deployment has no such endpoint — is `1008 UnsupportedOperation`, not
  `1002 NotFound`. That is the signal you get from an SDK newer than a private-deployment server.

## Notes

- **Never put an AppSecret in client code.** The client only ever holds a short-lived user token
  minted by your backend. This SDK never calls the `/v1` REST API; that is your backend's surface.
- `deviceId` must be stable for a given installation. The multi-device policy uses it to tell a
  reconnect apart from a second device, and a random value per launch will make users kick
  themselves offline.
- Order messages by `seq`, never by timestamp. Client clocks are wrong and arrival order is not
  send order. A `seq` of `0` means the message was never persisted (typing, presence, chat-room
  traffic) — deliver it, but never let it move a cursor.
- **On web, `messageId` is a JS double.** Ids beyond 2^53 lose precision there. Compare messages by
  `(conversationId, seq)` or by `clientMsgId` in code that must run in a browser.
- Unknown enum values keep their raw number rather than collapsing to a default member, so the
  server can ship a new content type without waiting for your app to update.
- Supply your own transport with `socketFactory` if the host app already multiplexes a socket, sits
  behind a proxy, or needs the WebSocket created on a particular isolate. It is also how the tests
  make a socket die on command.
- `ImSdk.contractVersion` is the client contract this build implements — the same number in all five
  SDKs — and `ImSdk.packageVersion` is this pub.dev release, which also goes on the wire as the
  handshake's `cv`. A support ticket carries both without anyone having to ask.

## Testing

```bash
dart pub get
dart test
```

59 cases, no Flutter toolchain required — the suite runs under the plain Dart SDK, which is worth
preserving. It drives a fake socket, because every behaviour worth testing here is defined by what
happens when a socket dies and a real one cannot be made to die on cue. The 26 conformance cases
from `sdk/CONTRACT.md` §10 are named and numbered in `test/cursor_test.dart`, `test/push_test.dart`,
`test/error_test.dart` and `test/ordering_test.dart`; the backoff is checked statistically, because
5000 draws is the only honest way to tell full jitter from a fixed delay.
