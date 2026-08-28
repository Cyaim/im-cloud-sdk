# CyaimIM

Swift client for Cyaim IM Cloud. iOS, macOS, tvOS and visionOS.

```swift
// Package.swift
.package(url: "https://github.com/cyaim/im-swift", from: "0.9.0")
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
> ```swift
> // Package.swift — a local path dependency on a clone of this repository
> .package(path: "../IM/sdk/swift")
> ```
>
> The `cyaim/im-swift` URL above is the **planned mirror**; that repository does not exist yet.
> SPM requires `Package.swift` at the root of the repository it resolves, and this one lives at
> `sdk/swift/Package.swift`, so `github.com/Cyaim/IM` cannot be added as an SPM dependency as
> it stands — the mirror is the fix, not an optimisation. Xcode's **Add Local…** does the same
> thing as the snippet above.
>
> The registry prerequisites still outstanding are listed in
> [`sdk/CONTRACT.md` §9.4](../CONTRACT.md).

```swift
import CyaimIM

let endpoint = URL(string: "wss://im.example.com")!

let im = ImClient(options: ImClientOptions(
    endpoint: endpoint,
    appId: "your-app-id",
    token: try await backend.imToken(),
    deviceId: KeychainDeviceId.current,          // stable per installation
    cursorStore: try .applicationSupport(scope: .init(
        endpoint: endpoint, appId: "your-app-id", userId: me.id
    )),
    tokenProvider: { try? await backend.imToken() }
))

Task {
    for await message in im.messages() {
        try await store.append(message)                              // durable
        await im.commit(message.conversationId, seq: message.seq)    // …then commit
    }
}
Task { for await state in im.states() { banner.show(state) } }
Task { for await kick in im.kicks() { await session.signOut(because: kick.reason) } }
Task { for await event in im.sessionEvents() { await handle(event) } }

try await im.connect()
try await im.msg.send(.text("hello", to: .user("bob")))
```

Swift 6, strict concurrency, no dependencies. The client is an `actor`, every call is
`async`/`await`, and everything you observe is an `AsyncStream`. There is no delegate to retain, no
completion handler, no "which queue does this come back on" — a callback-based SDK in 2026 is a
tell, and so is one that hands you a `[String: Any]`.

This build implements client contract **1.0** (`ImSdk.contractVersion`) and ships as **0.9.0**
(`ImSdk.version`). Both go out in the `cv` handshake parameter, so a support ticket carries them
without anyone having to ask.

## What this SDK does that a hand-rolled client usually does not

**Survives a cold start without losing messages.** The hard part of an IM client is not the socket,
it is the cursor. A client that restarts, fails to tell the server what it already holds, and adopts
the server's newest `seq` loses every message that arrived while the app was closed — silently, with
no error and no later event that corrects it. This SDK keeps two cursors and makes the durable one a
constructor argument you cannot forget. See [Cursors](#cursors-the-part-that-loses-messages-if-you-get-it-wrong).

**Reconnects without stampeding.** A gateway is stateful, so a rolling update drops every socket on
the node being replaced — and every one of those clients reconnects at the same instant. Delays here
use full jitter (a uniform random draw from `0..ceiling`, ceiling doubling to 30s) rather than a
fixed backoff, because that is what actually de-synchronises a fleet. A fixed or lightly-jittered
backoff reconnects the whole node's worth of clients in the same second, at the service that has
just come back up.

**Tells "you were kicked" apart from "the network died".** They look identical at the socket level
and need opposite responses. The server closes with a reason of `im-kick:{Reason}`; the SDK stops
reconnecting for terminal reasons (another device took over, banned, revoked) and asks
`tokenProvider` for a fresh token when the reason is expiry. `ServerShutdown` is deliberately *not*
terminal — that one is a deploy, and the node is coming back.

**Renews a token without dropping the socket.** A call that comes back `1101 TokenExpired` triggers
`conn.reauth` with a token from `tokenProvider` and is then retried once, on the same connection.
Letting the token expire used to cost a full reconnect, and on a flaky network a reconnect is
exactly what a long-lived socket was avoiding.

**Repairs gaps in the message stream, and pages while it does.** Every message carries a gap-free
per-conversation `seq`. When an arriving message skips a number the client pulls the missing range
with `msg.sync` before delivering — and keeps pulling until the server says `hasMore: false`, because
the server clamps a sync to 500 messages and an SDK that ignores that leaves the rest as a permanent
hole.

**Resumes on reconnect, to the end of the list.** It asks the server what changed while it was away,
and the server replies with which conversations moved and where each gap starts. `conn.sync` returns
at most 200 conversations per page, so the client pages to the end before it moves the conversation
cursor — the list is sorted newest-first, and a client that takes page 1's timestamp and stops has
told the server it has already seen pages 2…N.

**Deduplicates sends.** `clientMsgId` is minted with the request, not with the send, so retrying
after a timeout returns the original result instead of sending twice.

**Notices a socket that is dead but still open.** The heartbeat runs on the cadence the server
reports, and a beat that goes unanswered forces the socket closed so the reconnect logic takes over.
Half-open connections are the normal case on a phone, not an edge case.

## Cursors: the part that loses messages if you get it wrong

Two cursors per conversation, and the difference between them is the whole of it:

| | what it means | lives |
|---|---|---|
| **delivered** | the highest `seq` this SDK has handed *you* in this process | memory |
| **committed** | the highest `seq` *you* have told the SDK you have durably stored | the `ImCursorStore` |

Only **committed** is reported to the server. A callback returning means the message reached your
app's memory, which is exactly the state a crash loses, so the SDK never infers durability from it:

```swift
for await message in im.messages() {
    try await database.insert(message)                            // durable
    await im.commit(message.conversationId, seq: message.seq)     // now it counts
}
```

`commit` is monotonic — a lower `seq` is ignored rather than an error — which is what lets you
re-derive cursors from your own database in any order after a failure.

Delivery is therefore **at-least-once**. A message you were handed but never committed is delivered
again after a reconnect. **Be idempotent on `messageId`.**

### The store is a required argument

```swift
cursorStore: try .applicationSupport(scope: .init(endpoint: endpoint, appId: appId, userId: me.id))
cursorStore: .file(at: containerURL.appendingPathComponent("im-cursors.json"))
cursorStore: .inMemory()   // explicit opt-out; logs one warning and loses messages across launches
```

There is no default. Defaulting to no persistence is what produced the bug this section exists for;
defaulting to *some* persistence would mean the SDK guessing where your app is allowed to write, and
a wrong guess about that is worse than a compile error.

The scope key is `(endpoint host, appId, userId)` — not the device id, since the store is already
local to the device. The user id is in there because without it, two accounts on one handset share
one file and the second one to sign in inherits the first one's cursors.

**The cursor store and your message store have exactly one lifetime.** Whatever destroys one destroys
the other, and in that order — cursors first. Clearing messages while keeping cursors shows an empty
conversation that will never refill; keeping messages while clearing cursors costs a full re-download.

### Things the SDK has to tell you

```swift
for await event in im.sessionEvents() {
    switch event {
    case .conversationNeedsReload(let conversationId, _, _):
        // A span longer than `maxAutoRepairSeq` was skipped rather than backfilled. Both cursors
        // have moved past it, so nothing will ever request it: reload from history.
        await store.reloadFromHistory(conversationId)

    case .cursorStoreUnavailable(let error):
        // load() failed. The SDK will not adopt and will not advance a cursor this session,
        // because a failed load and a fresh install are indistinguishable — and adopting on a
        // failed load destroys history sitting intact in your own database.
        await im.commit(database.highestStoredSeqPerConversation())
        await im.resync()

    case .cursorsNotPersisted:
        assertionFailure("shipping with ImCursorStore.inMemory()")

    case .pushTokenNotRegistered(let provider, let error):
        log.error("no offline push on this device: \(provider) \(String(describing: error))")
    }
}
```

Call `im.enterBackground()` on suspend to flush a pending commit, and `im.enterForeground()` on
resume (below).

## Offline push

Registration is a client responsibility on **every connect**, not a one-time setup step: a vendor can
replace the token while your process is frozen, and the server has no other way to learn it.
Re-registering an unchanged token costs no write server-side, so the SDK does it for you once you
hand it a token.

```swift
func application(_ app: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Task { await im.setPushToken(deviceToken: token) }   // apns, hex-encoded for you
}
```

That is the whole integration. The user and device id come from the socket, so there is nothing else
to send, and there is no field in the request in which to say otherwise.

**On logout, call `im.logout()` rather than `im.disconnect()`.** It sends `push.unregister` and
*then* closes; after the socket is gone there is no authenticated channel left to remove the token
with, and the user keeps getting notifications for an account they signed out of.

```swift
await im.logout()      // push.unregister, then disconnect
```

`disconnect()` deliberately never unregisters: a dead socket is precisely the state offline push
exists to serve.

If a client dies without unregistering — force-quit, crash, uninstall — only your backend can clean
up, with `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Wire that into your own account-deletion
and device-management paths; nothing else will.

The raw endpoints are on `im.push` if you want to drive the timing yourself.

## iOS backgrounding, which is most of the difficulty on this platform

When your app is suspended, its socket dies. Not "may die" — iOS stops your process, the connection
goes away within seconds or minutes, and the gateway notices when your heartbeat stops. Messages that
arrive meanwhile are delivered as pushes by APNs, provided this device's token is registered (above).

When the app comes back, make **one call**:

```swift
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .active: Task { await im.enterForeground() }
    case .background: Task { await im.enterBackground() }
    default: break
    }
}
```

`enterForeground()` does the two different things the situation actually needs. If the client is
waiting out a reconnect backoff it skips the rest of the wait — after a suspension that timer may
still have twenty seconds to run, and those are exactly the seconds the user spends looking at a chat
that has not loaded. If the socket instead looks open, it probes it with an immediate heartbeat rather
than trusting it, because a connection frozen for half an hour is frequently dead with nothing having
said so. Either way the reconnect that follows runs `conn.sync`, and everything the app missed arrives
through `messages()` in `seq` order.

`enterBackground()` only flushes pending cursor commits. There is nothing to close: closing the socket
yourself only makes the next foreground slower. `disconnect()` is for logging out, not for backgrounding.

`ImClient` deliberately does **not** start a background task or use a VoIP socket to stay alive.
Neither survives review for a chat app, and neither is a substitute for push.

## API

Endpoints are grouped into namespaces named exactly for the target prefix, and each method is named
for the endpoint's method part with no synonyms — so if you know the endpoint name you know the call,
and a bug report mentioning `msg.forward` can be grepped for.

| Namespace | Endpoints |
|---|---|
| `im.conn` | `heartbeat` `reauth` `sync` |
| `im.msg` | `send` `sync` `history` `recall` `delete` `edit` `forward` `react` `receipt` `typing` |
| `im.conv` | `list` `get` `read` `unreadTotal` `setting` `delete` `clear` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `blockList` `block` `unblock` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` |

That is tiers 0, 1 and 2 of the client contract — 49 endpoints — typed end to end. Tier 3
(group administration, pins, favourites, search) and tier 4 (calls, E2EE, live rooms, service desk,
AI streaming) go through `invoke` until they are typed.

Every method takes exactly one request object, named for the server DTO, because a server that adds
one optional field should be an additive change rather than a source break. Convenience overloads
exist only where a request has at most two required scalars: `im.conv.read("c1", readSeq: 40)` is
fine, a nine-argument `send` is not.

| Client | Purpose |
|---|---|
| `connect()` / `disconnect()` / `logout()` | Open, close, and sign out (unregisters push first) |
| `enterForeground()` / `enterBackground()` | Resume: skip the backoff and probe. Suspend: flush cursors |
| `messages()` | Every message, in seq order, gaps repaired |
| `commit(_:seq:)` | Tell the SDK a message is durably stored |
| `sessionEvents()` | Reloads needed, cursor-store trouble, push not registered |
| `events(_:as:)` / `frames(for:)` | Any server event (`evt.typing`, `evt.read`, `evt.group`, …) |
| `states()` | `idle` \| `connecting` \| `open` \| `reconnecting` \| `closed` |
| `kicks()` | Why the server ended the session |
| `setPushToken(deviceToken:)` | Hand over the APNs token; re-registered on every connect |
| `highestSeq(in:)` / `committedSeq(in:)` / `cursorSnapshot()` | Read the cursors |
| `resync()` | Run `conn.sync` again after re-deriving cursors |
| `invoke(_:body:as:)` | Any endpoint not yet in the typed surface |

The nine flat methods that appear in older samples — `send` `sendText` `history` `sync` `recall`
`react` `setTyping` `conversations` `markRead` `totalUnread` — still work and delegate to the
namespaced surface. They are deprecated for 2.0.

Message content is open — `["text": "hi"]`, `["objectKey": …, "width": …]`, or whatever your tenant
invents for `contentType: 100` — so it is modelled as `JSONValue` rather than as `[String: Any]`,
which is neither `Sendable` nor decodable into anything useful:

```swift
let ticket = try await im.media.uploadTicket(UploadTicketRequest(
    fileName: "photo.jpg", contentType: "image/jpeg", size: Int64(data.count)
))
try await upload(data, to: ticket.uploadUrl)

try await im.msg.send(SendMessageRequest(
    groupId: "g-123",
    contentType: .image,
    content: ["objectKey": .string(ticket.objectKey), "width": .int(1080), "height": .int(1920)]
))
```

Messages carry the object key, never a URL: every reader signs their own link with
`im.media.downloadUrl(objectKey:)`, which is what makes expiry and revocation possible at all.

### `invoke` — the escape hatch

The catalogue is larger than the typed surface and grows faster than SDK releases do, so this is a
supported route rather than a workaround. It shares one code path with every typed method, so
timeouts, cancellation and error mapping behave identically — and it never touches a cursor.

```swift
// msg.pin is tier 3 and not yet typed here.
try await im.invoke("msg.pin", body: [
    "conversationId": .string(conversationId),
    "messageId": .int(messageId),
] as [String: JSONValue], as: EmptyBody.self)
```

## Errors

Every failure is an `ImError` carrying `code`, `message`, `traceId`, `target`, `isRetryable` and
`requiresReauth`. Branch on `code`, never on message text.

- `traceId` and `target` are not decoration: a bug report carrying both is a one-query investigation.
- `isRetryable` is exactly `1000` InternalError, `1003` RateLimited, `1004` Timeout and `1005`
  ServiceUnavailable. Everything else is terminal.
- **The SDK never auto-retries a business call.** It retries the connection and its own gap repair;
  everything else surfaces so the UI that has to explain it can.
- `1203 FeatureNotEnabled` means the tenant has the feature off. Do not remember it — a tenant can
  turn it back on at runtime, and a client that latched it stays broken until the app restarts.
- `1202 QuotaExceeded` and `1204 PlanExpired` are billing. Never retry, and never bury them.
- A request made while the socket is down fails immediately with `1005`. Nothing is queued: a client
  that buffers a send across a five-minute outage delivers it into a conversation that has moved on,
  and only your app knows whether it is still worth sending.
- A socket that drops with requests in flight fails them `1004 Timeout`, not `1005` — the SDK does
  not know whether they executed, and `1004` is the honest answer.

Cancelling the calling `Task` throws `CancellationError` and forgets the request. It does **not**
cancel the server-side effect: a cancelled `msg.send` may well have sent the message, which is what
`clientMsgId` idempotency is for.

## Notes

- **Never put an AppSecret in client code.** The client only ever holds a short-lived user token
  minted by your backend, and `tokenProvider` is how you hand it a fresh one. A client SDK must never
  call the server's `/v1` REST API; that is your backend's, and it authenticates with app credentials.
- `deviceId` must be stable for a given installation. The multi-device policy uses it to tell a
  reconnect apart from a second device, and a random value per launch will make users kick themselves
  offline. Keep it in the keychain, not `UserDefaults` — a reinstall wipes one and not the other.
- Order messages by `seq`, never by timestamp. Client clocks are wrong and arrival order is not send
  order.
- `disconnect()` (or `logout()`) is not optional. A live client's tasks hold it, exactly like a strong
  delegate cycle, so a client that is simply dropped keeps reconnecting for the life of the process.
- `connect()` returns when the socket is *usable*, and keeps waiting while the network is down. Wrap
  it in a timeout if your UI needs to give up and show something.
- Unknown enum values keep their raw value rather than collapsing to a default member. The server
  ships new content types without waiting for your next release.

## Tests

```bash
swift test
```

The suite covers the parts that are hard to get right and impossible to verify against a live
gateway on CI: that a cold start reports what this device actually holds rather than re-baselining,
that a multi-page `conn.sync` and a multi-page `msg.sync` both run to the end, that an interrupted
resume leaves the conversation cursor untouched, that a skipped `seq` produces a `msg.sync` for
exactly the missing range before the message that exposed it is delivered, that a span too large to
backfill still tells the application, that push is registered on every connect and unregistered
before the socket closes, that reconnect delays are drawn from the whole jitter window rather than
clustered, and that each terminal kick reason stops the client dead while a network failure and a
`ServerShutdown` do not. The transport is a protocol (`ImWebSocketConnector`) precisely so those
tests need no network.
