# CyaimIM

Swift client for Cyaim IM Cloud. iOS, macOS, tvOS and visionOS.

```swift
// Package.swift
.package(url: "https://github.com/Cyaim/im-swift", from: "0.9.0")
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
> .package(path: "../im-cloud-sdk/swift")
> ```
>
> The `Cyaim/im-swift` URL above is the **planned mirror**; that repository does not exist yet.
> SPM requires `Package.swift` at the root of the repository it resolves, and this one lives at
> `swift/Package.swift`, so `github.com/Cyaim/im-cloud-sdk` cannot be added as an SPM dependency as
> it stands — the mirror is the fix, not an optimisation. Xcode's **Add Local…** does the same
> thing as the snippet above.
>
> The registry prerequisites still outstanding are listed in
> [`CONTRACT.md` §9.4](../CONTRACT.md).

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

The user and device id come from the socket, so there is nothing else to send, and there is no field
in the request in which to say otherwise.

**One more call, in the tap handler.** APNs does not report delivery — not to us, not to anyone — so
a tap is the only evidence a notification ever arrived, and the server credits delivery from it. The
tenant's push screen shows a sent → delivered → clicked funnel that has no other source on iOS:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse) async {
    let payload = response.notification.request.content.userInfo
    try? await im.push.clicked(.init(messageId: payload["msgId"] as? String))
}
```

`try?` is deliberate and is the whole story of that signature: `clicked` swallows server failures
(`2401 PushDeliveryNotFound` means the record aged out after seven days) but *does* throw on
cancellation, because a `Task` cancelled mid-flight must not report success to whoever cancelled it.
Never retry it — a tap counted twice is worse than one counted never.

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

**Notification text is set by your server, not by this SDK.** A message sent from here whose
`options.pushConfig` has a non-empty `title` or `body` is refused with `1103` (`ImErrorCode.forbidden`). That text
would replace the notification template that names the sender, and moderation never reads it.
Leave both empty and the recipient's notification is built from the message itself; `sound`,
`channelId`, `badgeCount` and `payload` stay open to clients. For custom text ("your order has
shipped"), send the message from your backend through `/v1` or the server SDK, which may set them.
The same rule, also `1103`, refuses an image, voice, video or file message with `persistent: false`
or `onlineOnly: true` while the app moderates content. See CONTRACT.md §2.

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
| `im.msg` | `send` `sync` `history` `recall` `delete` `edit` `forward` `react` `receipt` `typing` · `pin` `unpin` `pins` `favourite` `unfavourite` `favourites` `burn` `search` `receiptDetail` · tier 4: `streamBegin` `streamAppend` `streamComplete` `streamAbort` `schedule` `scheduled` `cancelScheduled` `translate` |
| `im.conv` | `list` `get` `read` `unreadTotal` `setting` `delete` `clear` · `markUnread` · tier 4: `folders` `upsertFolder` `deleteFolder` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` · `setStatus` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` `clicked` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `blockList` `block` `unblock` · `setRemark` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` · `transfer` `applicationList` `handleApplication` `setRole` `mute` `muteMember` `setNickname` `announcement` |
| `im.moderation` | `report` |
| `im.diag` | `logRequests` `logUploaded` — driven by `ImClient` itself; apps do not call these |
| `im.desk` | `request` `accept` `transfer` `close` `status` `queue` `rate` `canned` `suggest` — tier 4, the customer-service desk |
| `im.room` | `join` `quit` `send` `onlineCount` `memberList` `mute` `kick` — tier 4, chat rooms |
| `im.keys` | `publish` `upload` `remaining` `claim` `devices` `revoke` `safetyNumber` — tier 4, the end-to-end encryption key directory |

That is tiers 0 to 3 of the client contract typed end to end, plus, of tier 4, the nine `desk.*`,
the seven `room.*`, the four `msg.stream*`, the three schedule calls, the three folder calls,
`msg.translate` and the seven `keys.*` — all 107 endpoints; the names after the first `·` are
tier 3.

The desk has two audiences and the session decides which one you are: `request` and `rate` are the
customer's, the rest an agent's, `close` either side's; the conversation itself is an ordinary chat
with the desk account. `DeskTransferRequest` is built with `.agent(…)`, `.skill(…)` or `.queue(…)`
so exactly one target goes out; a `DeskCloseRequest` with `inviteRating` left `nil` still invites a
rating; `DeskStatusRequest` is also the heartbeat, so send it on a timer; `DeskSession.endReason` is
a string where `state` is an integer. `im.deskEvents()` decodes `evt.desk` into `DeskEvent`.
**The 1801–1807 notices a customer sees arrive as ordinary messages** on `messages()` — which is
what keeps a transcript readable months later — so ask `DeskNotification.read(message)` first and
fall through to your chat rendering when it answers `nil`. It answers a notice only when
`contentType` is `.notification` **and** `content["code"]` is 1801–1807: the same seven numbers are
account error codes elsewhere on this platform, and a bare code check will one day draw "your
account is locked" onto a support transcript. The answer carries `sessionId`, `customerId`, `skill`
(may be `nil` on any of them), `agentId` (`nil` until an agent is involved) and a `kind` — `.queued`,
`.assigned`, `.transferred(fromAgentId:)`, `.closed(resolution:reason:)` (`reason` `"timeout"` when
the inactivity timer closed it), `.requeued(previousAgentId:)`, `.abandoned(waitedSeconds:)` and
`.ratingRequested(windowHours:askResolved:starTags:)` — so a `switch` over it needs no `default`;
`code` is the same thing as one of `ImDeskNotificationCode`. It never throws or traps: a member of
the wrong JSON kind reads as its default (an id `""`, a count 0), and the counts and the code are read
whether the server wrote them as numbers or as quoted ones.

```swift
for await message in im.messages() {
    guard let notice = DeskNotification.read(message) else { showChat(message); continue }
    switch notice.kind {
    case .queued: showLine("You are in the queue")
    case .requeued: showLine("We are finding someone else for you")
    case let .ratingRequested(_, askResolved, starTags): showSurvey(notice.sessionId, starTags, askResolved)
    default: showLine("\(notice.code)")
    }
}
```

`ImDeskContextKeys` names the keys the engine copies out of `DeskRequest.context` — `desk.channel`,
`desk.visitorId`, `desk.deskId`, `desk.groupId`, `origin` (`ImDeskContextKeys.originBot`, `"bot"`, for
a bot handoff), and `desk.page` / `desk.visitorName` / `desk.visitorEmail` for the workbench. Every
other key you put in the context travels to the workbench untouched.

A chat room — the live-stream comment wall, the broadcast lobby — trades every delivery guarantee
for scale, and the client has to know which ones:

- **A room message has `seq` 0 and never enters gap repair.** It arrives on `messages()` as an
  ordinary `ImMessage` with `conversationId` `r_<roomId>` and `conversationType` `.chatRoom`,
  delivered the moment it lands — ahead of the repair lane, so never behind another conversation's
  repair, not deduplicated by seq, and never repaired: it is not stored per user, so a dropped frame
  is simply gone and there is no range to ask `msg.sync` for. The SDK keeps it out of every cursor;
  **do not commit it** (`commit(_:seq:)` ignores seq 0, so a "commit everything you store" loop is
  safe). `im.room.send` answers `seq` 0 too and moves nothing.
- **Rooms are created by the tenant's backend** (`POST /v1/rooms`); there is no socket call for it.
- **Joining belongs to the connection.** After a reconnect, call `im.room.join` again for every room
  still on screen — the SDK does not rejoin for you. `RoomJoinResult.recent` is the room's last few
  messages for a newcomer, returned to the caller only and never replayed on `messages()`.
- **`RoomMuteRequest` has no defaults on purpose**: `userId: nil` mutes the whole room, and
  `untilMs: nil` (or a time already past) *lifts* the mute; neither is sent as `null`. Only the
  owner and `ChatRoom.admins` may mute or kick (`1103`), and nobody can mute or kick the owner
  (`1511`).
- **`room.send` takes a `RoomMessage`**, not a `SendMessageRequest`: a room is addressed by
  `roomId`, and quote, thread and receiver fields would be ignored. Its `clientMsgId` is minted when
  it is built and a blank one is filled in. Refusals: `1602` not joined (or kicked), `1603` the room
  is muted, `1506` you are muted, `1003` the room is over its rate.
- **`room.memberList` is a sample**, never the full list; page on `hasMore`. `room.onlineCount` is a
  bare `Int64`, and an unknown room answers 0 rather than `1600`.
- `im.roomEvents()` is the `room.*` events out of `evt.system` — `room.muted`, `room.kicked`,
  `room.destroyed` — as `RoomEvent`. It reads `evt.system` beside the device-log handler and takes
  only names starting `room.`; one this build does not know still arrives, with its raw `body`. A
  `room.kicked` naming you means stop sending: the server answers `1602` from then on.

A streaming reply — an AI assistant typing it out — is opened, appended to piece by piece, and
completed into one ordinary message. The platform calls no model.

```swift
let reply = try await StreamWriter.begin(im.msg, BeginStreamRequest(receiverId: "u_bob", placeholder: assistantCard))
do {
    for try await token in model.generate(prompt) { try await reply.append(token) }
    try await reply.complete()                       // stored as {"text": every piece, joined}
} catch {
    try? await reply.abort(reason: "the model failed") // a terminal frame for everyone; nothing stored
    throw error
}

for await stream in im.streamEvents().assemble() {
    switch stream.status {
    case .streaming: drawTyping(stream.streamId, stream.placeholder, stream.text)
    case .completed: swapForMessage(stream.streamId, stream.messageId)
    case .aborted: drawStopped(stream.streamId, stream.abortReason)
    }
}
```

- **Anyone signed in may stream, but only as themselves**, in a single chat (a chat with yourself
  included) or a group of at most 200 — a chat room, system or assistant conversation answers
  `1008`. Every permission `msg.send` checks is checked at `streamBegin`. Name the conversation by
  `conversationId`, else `receiverId`, else `groupId`.
- **`clientMsgId` is the finished message's idempotency key** and the server makes none up: it is
  minted when the `BeginStreamRequest` is built and a blank one is filled in. `options` is nested
  and matched case-sensitively; a non-empty `pushConfig.title` / `body` is refused (`1103`).
- **The stream dies of silence, not of age**: append or complete within
  `StreamHandle.idleTimeoutSeconds` (30) of the last call, or the server reaps it — a terminal
  frame, no message. 4096 characters a piece (`1401`, and the stream stays open), 100 pieces a
  second (`1003`). `streamComplete` without `content` stores `{"text": …}` of the pieces; with
  `content` it replaces them. The stream is consumed either way: a second complete or abort answers
  `1002`.
- **The pieces are not messages.** `im.streamEvents()` is `evt.stream` decoded into `StreamEvent`s
  — the opening (index 0, with the producer's `placeholder`), pieces (1, 2, 3…), and one terminal
  frame (one past the last piece), `.completed` with the stored message's `messageId` and `seq` or
  `.aborted` with an `abortReason`. No seq, online devices only, never stored, never resent: the SDK
  keeps them away from every cursor and the gap repair, and there is nothing to commit. `assemble()`
  (or a `StreamAssembler`) joins them by index, ignores a duplicate and stops the text at a missing
  piece; **a hole is not repaired** — the stream is marked not `intact`, as is one joined mid-way.
- **The completed stream is an ordinary message**: a real seq, the `clientMsgId` it was opened
  with, delivered on `messages()` through cursors and gap repair like any other — to the producer
  too, which is why `streamComplete`, unlike `msg.send`, does not move the delivered cursor. That
  message, not the assembled text, is what to keep. The terminal frame and the message can arrive
  in either order; match them by `messageId`. Reset a long-lived `StreamAssembler` with `clear()` on
  reconnect (`assemble()` starts a fresh one per call).

A scheduled message is written now and sent by the server later. `im.msg.schedule` answers a
`ScheduledMessage` with the `scheduleId` to cancel it by; `im.msg.scheduled()` pages the outbox;
`im.msg.cancelScheduled(scheduleId)` takes one back.

```swift
let entry = try await im.msg.schedule(ScheduleRequest(
    sendAt: ImClock.nowMilliseconds() + 60 * 60_000,
    content: ["text": .string("Stand-up in five minutes")],
    groupId: "team"
))
try await im.msg.cancelScheduled(entry.scheduleId)
```

- **`ScheduleRequest` is flat and is not a `SendMessageRequest`.** The server binds the message
  members at the top level beside `sendAt`, and there is no `options` and no `sendTime` on this
  path. Address it by `conversationId`, else `groupId`, else `receiverId` (not the order
  `streamBegin` uses); the sender must be allowed to write there exactly as for `msg.send`, checked
  when scheduling. `clientMsgId` is optional and **not minted for you** — left `nil`, the server
  keys the eventual send `sch-<scheduleId>`. `quoteMessageId` / `threadRootId` leave quoted.
- **Limits** (`IM:Extras`): `sendAt` at least 10 seconds and at most 90 days ahead (`1001`
  otherwise); 120 schedules created per user per hour (`1003`); 100 pending per user (`1006`).
  **`msg.schedule` is not idempotent**, and the SDK never retries it: a retry after a lost reply
  schedules twice — list first.
- **It fires on the server's sweep**, every 15 seconds by default: on the first sweep after
  `sendAt`, never before. The receiver gets an **ordinary `evt.message`** (the sender's devices the
  usual self-sync) with a real seq, through `messages()`, cursors and gap repair like any other
  message. Scheduling itself delivers nothing, moves no cursor, and **pushes no event**: another
  device sees the outbox change only by calling `msg.scheduled` again.
- **`ScheduledMessage` has no state field.** Pending: `messageId` and `error` both `nil`. Sent:
  `messageId` set. Cancelled: `error == "cancelled by sender"`. Failed: `error` is the reason.
  **Cancelled, sent and failed entries stay listed for about 48 hours**, so a cancel is not followed
  by an empty list. `msg.scheduled` runs in `sendAt` order, 20 a page by default (100 at most).
- `msg.cancelScheduled`: `1002` for an unknown schedule or someone else's. `1006` when there is
  nothing left to cancel — it is being sent, it was cancelled already, or it was already sent or
  failed — one code, told apart only by the server's message; a sent one is taken back with
  `msg.recall`.

A conversation folder is a saved filter over the conversation list — tags, optionally conversation
types and "unread only" — that the server stores per user and the client applies.
`im.conv.folders()` returns all of them as a plain array (no paging);
`im.conv.upsertFolder(UpsertFolderRequest(name: …))` creates one (no `folderId`) or replaces one
wholesale, and answers it as stored; `im.conv.deleteFolder(folderId)` removes it and leaves the
conversations alone.

- **Every tag must already be on one of your conversations** (`conv.setting`'s `tags`), or the save
  is `1001`. Other limits: 20 folders per user (`1006`), 16 tags per folder, names and tags up to 64
  characters, a `folderId` of 1–64 letters, digits, `-`, `_` or `.`.
- `types` go out as integers; an empty list is stored as none and comes back absent (all types).
  `order` below 0 is stored as 0. Sort by `order`, then `name`.
- **Creating is not idempotent** — keep the `folderId` from the answer and send it on every later
  save. Deleting one you do not have is `1002`. No event announces a folder change; re-read on
  other devices.

`im.msg.translate(TranslateRequest(conversationId:messageIds:targetLanguage:))` translates up to 50
messages of one conversation and answers a `TranslationResult`: one `TranslatedMessage` per id, with
`text`, `cached`, or an `error` for that message alone — a message that cannot be translated does
not fail the call. The ids leave quoted. `sourceLanguage` is a hint; leave it `nil` to let the
provider detect it.

**The platform calls no model of its own, and most deployments refuse this call.** Both refusals are
ordinary `ImError`s carrying the server's sentence, checked before anything else about the request:
`1204 PlanExpired` when the tenant's plan does not include the translation add-on (Enterprise and
up, or a trial), and `1203 FeatureNotEnabled` when the plan includes it but the deployment has no
provider configured (`IM:Translation:Provider`).

```swift
do {
    show(try await im.msg.translate(TranslateRequest(
        conversationId: conversationId, messageIds: [message.messageId], targetLanguage: "zh-CN"
    )))
} catch let error as ImError where error.code == .featureNotEnabled || error.code == .planExpired {
    hideTranslate(error.message)
}
```

Neither is retryable; do not latch either beyond the session, since both are runtime settings.

The key directory (`im.keys`) is where each device publishes its **public** keys and a sender
fetches a peer's to open a session (X3DH-style: identity key, signed prekey, one-time prekeys).
**The SDK types the seven calls and moves the key material unchanged; it performs no
cryptography.** Generating key pairs, signing the signed prekey, running the key agreement and
encrypting messages are your crypto library's. Every key and signature is an opaque
**standard-base64** string (not base64url); pass it exactly as your library produced it — the server
compares identity keys by exact string and hashes the strings into the safety number, so a
re-encoded key is a different key. No private key ever crosses this surface, and the SDK never logs
key material.

```swift
// Once per device, and again whenever you rotate the signed prekey:
try await im.keys.publish(PublishKeysRequest(
    identityKey: identity.publicBase64,
    signedPreKey: SignedPreKey(keyId: "spk-7", publicKey: spk.publicBase64, signature: spkSignatureBase64),
    oneTimePreKeys: batch.map { OneTimePreKey(keyId: $0.id, publicKey: $0.publicBase64) },
    algorithm: "x3dh-ed25519-aes256gcm-v1"   // nil keeps the server default, x3dh-curve25519-aes256gcm-v1
))
if try await im.keys.remaining() < 20 { try await im.keys.upload(nextBatch()) }

// Sending to bob: one ciphertext per device.
for device in try await im.keys.devices("bob") {
    let bundle = try await im.keys.claim(userId: "bob", deviceId: device.deviceId) // consumes a one-time prekey
    openSession(bundle)                                                             // bundle.oneTimePreKey may be nil
}
let fingerprint = try await im.keys.safetyNumber("bob") // "12345 67890 …" — 12 groups of 5 digits
```

- **`keys.claim` consumes.** Each claim hands out one one-time prekey and deletes it (first in,
  first out), so `remaining` drops by one. It is **not idempotent: never retry it after a lost
  reply as if it were, and never prefetch** — the SDK never reissues it, beyond the one renewal on
  `1101 TokenExpired` that every call gets (a call refused for its token did not run). When the pool is empty the claim still succeeds, with `oneTimePreKey` `nil`. Claiming your
  own device is allowed and drains your own pool.
- **`keys.publish` replaces and keeps the pool.** Identity key, signed prekey and algorithm are
  replaced; the one-time pool is kept and the new keys appended — unless the identity key changed,
  which deletes the old pool first. **The device and platform are the connection's; they are not on
  the request.** The signed prekey's signature is the identity key's over the decoded bytes of its
  `publicKey` only; the server verifies it (`1001` when it does not) and picks the scheme from
  `algorithm` (`curve25519`/`x25519`/`xed25519`, `ed25519`, `p256`; anything else `1008`). All four
  `SignedPreKey` members always go out; a `createdAt` of 0 is stamped by the server.
- **`keys.upload` appends** to the connected device's pool; `1002` before that device has
  published. One-time prekeys with a blank or repeated `keyId` or a `publicKey` that is not base64
  are dropped without an error.
- **`keys.revoke(deviceId)`** forgets one of your own devices: after it, a claim is `1002`, the
  device is gone from `devices`, and both sides' safety numbers change. The id is required (`1001`
  when blank, never defaulted to this device); **revoking an unknown device succeeds**.
- **The safety number** is the same from either side, 12 groups of 5 digits. It changes when a
  device is added or revoked or an identity key changes, not on signed-prekey rotation or
  one-time-key use. `1002` when either side has nothing published.
- **Limits:** 100 one-time prekeys per call and 100 held per device (the oldest kept); 10 devices
  per user (an eleventh is `1202 QuotaExceeded`); identity keys up to 256 characters; a device's
  keys expire 180 days after its last publish or upload.
- **Callable whether or not the app's `e2ee.enabled` is set.** That switch constrains settings
  writes and translation, not the directory; there is no `1203` / `1204` here.
- **No events.** Nothing is pushed for a revoked device, a changed identity key or a pool running
  low — read `devices` and `remaining` again (on launch, before sending).
- `remaining` and `devices` without an argument send an empty body: the connected device, the
  caller's own. `remaining` is a bare `Int`, `devices` a plain array in no particular order (an
  unknown user is empty), `safetyNumber` a bare `String`; an unknown device's `remaining` is 0.
  None of these is an error.

Three tier-3 behaviours are worth knowing before the first call. `im.msg.search` is **off by
default** (the tenant's `EnableSearch`, `1203`) and rate limited per user *before* that check
(`1003`), so debounce search-as-you-type. `im.group.setRole` sends only `.member` or `.admin` and
throws before writing a frame for anything else, because the server stores any other number it is
given. And every request that names a message — `ConversationMessageRequest`,
`ReceiptDetailRequest`, recall, edit, delete, forward, react, receipt, and a send's
`quoteMessageId` / `threadRootId` — takes the `Int64` from `ImMessage.messageId` but puts it on the
wire as a quoted string: the server's field is a `string`, and a JSON number there is refused.

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
| `roomEvents()` | `room.muted` / `room.kicked` / `room.destroyed`, out of `evt.system` |
| `streamEvents()` | `evt.stream`: a reply arriving piece by piece; `.assemble()` for the text |
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

A newer server can add endpoints faster than SDK releases type them, so this is a supported route
rather than a workaround. It shares one code path with every typed method, so timeouts,
cancellation and error mapping behave identically — and it never touches a cursor.

```swift
// An endpoint a newer server ships before this SDK types it (the name is illustrative):
try await im.invoke("feature.newCall", body: [
    "id": .string(id),
] as [String: JSONValue], as: EmptyBody.self)
```

`EmptyBody` is the answer type for an endpoint that acknowledges without a payload. In a hand-built
body, give each field the JSON type the server's request DTO declares: the gateway binds field by
field without converting, so a mismatch is refused with `1000`. The `msg.*` endpoints declare their
message ids as `string` — put one in as `.string(String(messageId))` — while times and counts are
numbers.

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

### 没有 Mac 的时候（2026-08-30 起可以了）

这个包声明的平台只有 Apple 的四个，但**源码在 Linux 上也编得过、117 条测试也全过**——
唯一的条件是那四处 `#if canImport(FoundationNetworking)`（`URLSession` 一族在 swift-corelibs 上
属于另一个模块）。CI 仍然跑 macOS，因为那才是客户运行它的地方；下面这条只是让**任何一台有 Docker
的机器**都能在提交之前验一遍，而不是把每一行都盲写出去等 CI 告诉你：

```bash
docker run --rm -v "$PWD/../..:/repo" -w /repo/SDK/swift swift:6.1-noble \
  swift test --scratch-path /tmp/sb
```

**在 Windows 的工作副本上跑，会有两条断言红，而它们红得对。**
`NamespacedSurfaceTests` 里那条「扫描确实找到了它要检查的命名空间」是一条 vacuity 断言：
它读 `Namespaces.swift` 并按 `
` 切行，而 **Swift 里 `
` 是一个 Character**——
CRLF 检出的文件因此整个是一行，扫描一个方法都找不到，于是它拒绝给绿灯。
**那正是它存在的理由**（本仓 2026-08-29 被 CRLF 咬过一次，就是它先叫的）。
要在 Windows 上跑完整套，先把 `SDK/swift` 复制一份并转成 LF——
git 里存的就是 LF，macOS 与 CI 上不会遇到这件事。

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
