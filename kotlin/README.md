# im-client (Kotlin)

Kotlin client for Cyaim IM Cloud. Android and any JVM — one plain `.jar`, no Android dependencies,
no `Context` to hand it.

```kotlin
dependencies {
    implementation("com.cyaim.im:im-client:0.9.0")
}
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
> # From a clone of this repository:
> cd kotlin && ./gradlew publishToMavenLocal
> ```
> ```kotlin
> repositories { mavenLocal() }
> dependencies { implementation("com.cyaim.im:im-client:0.9.0") }
> ```
>
> Maven Central is the one with real lead time. **As of 2026-09-14 the parts that live in this
> repository are done** — the POM carries every field Central requires, `withSourcesJar()` and
> `withJavadocJar()` are configured, `META-INF/LICENSE` is in all three jars, and `publishing{}`
> names a real Central Portal repository. What is left needs an account and a domain, not a commit:
> namespace verification for `com.cyaim` (a DNS TXT record — the long pole) and a published GPG key.
> Start those before you need them.
>
> The registry prerequisites still outstanding are listed in
> [`CONTRACT.md` §9.4](../CONTRACT.md).

```kotlin
val im = ImClient(
    ImOptions(
        endpoint = "wss://im.example.com",
        appId = "your-app-id",
        token = token,                        // minted by YOUR backend, never an AppSecret
        deviceId = stableDeviceUuid,          // persisted, not regenerated per launch
        userId = currentUserId,               // scopes the cursor store; see below
        platform = Platform.Android,
        onTokenExpired = { api.freshImToken() },
    ),
    // Required, and deliberately so. See "Cursors" below for the bug a default would reintroduce.
    cursorStore = ImCursorStore.file(File(context.filesDir, "im-cursors-$currentUserId.json")),
    parentContext = viewModelScope.coroutineContext,
)

viewModelScope.launch {
    im.messages.collect { message ->
        db.insert(message)          // your write
        im.commit(message.conversationId, message.seq)   // …then tell the SDK it is durable
    }
}
viewModelScope.launch { im.state.collect { banner(it) } }

viewModelScope.launch {
    im.connect()
    im.msg.send(SendRequest(SendTarget.User("bob"), textContent("hello")))
}
```

`connect()` suspends until the socket is actually usable, so the next line is not a race. Collect
`messages` *before* `connect()`: the flow is hot and has no replay, exactly like registering a
listener before opening a socket in the other SDKs.

## Cursors, and the bug they exist to prevent

**Read this before you ship.** It is four paragraphs and it is the difference between a chat app
that works and one that loses messages overnight without saying so.

The SDK keeps two cursors per conversation:

- **`deliveredSeq`** — the highest `seq` handed to you in this process. Memory only.
- **`committedSeq`** — the highest `seq` you have told the SDK you have **durably stored**, by
  calling `commit(conversationId, seq)`. Written through to the `ImCursorStore`, and the only value
  ever reported to the server in `conn.sync`'s `convSeqs`.

Why two. `conn.sync` reports a gap only for a conversation the client *named* in `convSeqs`; a
conversation it did not name produces no gap entry at all, and the client then adopts the server's
current `maxSeq`. So a client with no persisted cursors names nothing, is told about nothing, and
skips every message that arrived while it was closed — with no error, no log line and no later
event that corrects it. And a client that persists "the highest seq I received" has the same hole
one crash wide, because a message that reached a callback and not a database is exactly what a
crash loses.

So the store is a **required constructor argument** with no default. That is a compile error on
purpose: defaulting to no persistence is what produced the bug, and defaulting to *some*
persistence would mean this library guessing where your application may write. `ImCursorStore.file(path)`
takes the directory from you — on Android `context.filesDir`, elsewhere whatever you already own.
`ImCursorStore.inMemory()` is the explicit way to say you do not want any; it logs one warning and
`cursorStoreState` reports `persistent = false`, so a test can assert on it.

Three consequences to design around:

- **Delivery is at-least-once. Be idempotent on `messageId`.** Anything you received but never
  committed comes back after a reconnect — that is the mechanism working, not a bug.
- **The cursor store and your message store have exactly one lifetime.** Whatever destroys one
  destroys the other, cursors first. Clearing messages while keeping cursors shows an empty
  conversation that will never refill; clearing cursors while keeping messages costs a full
  re-download. A logout that keeps messages for a fast re-login keeps the cursors too.
- **Scope the file per account.** The scope key is `(endpoint host, appId, userId)`, stamped into
  the snapshot. Point two accounts at one path and the SDK notices and starts clean rather than
  handing one user another's cursors — but the second account's write still costs the first its
  cursors. Put the user id in the filename.

If `load()` throws, the SDK does **not** treat it as a fresh install: it refuses to adopt anything
and refuses to advance any cursor for the session, and says so on `cursorStoreState`. A failed load
and a fresh install look identical to the adoption branch, and adopting on a failed load destroys
history sitting intact in your own database. Your recovery is to re-derive cursors from that
database and replay them through `commit`, which is monotonic and takes them in any order.

## What this SDK does that a hand-rolled client usually does not

**Reconnects without stampeding.** A gateway is stateful, so a rolling update drops every socket on
the node being replaced — and every one of those clients reconnects at the same instant. Delays here
use full jitter (a uniform random draw from `0..ceiling`, ceiling doubling to 30s) rather than a
fixed backoff, because that is what actually de-synchronises a fleet. `BackoffTest` asserts the
distribution, not just the wait, so the policy cannot quietly regress into something cheaper.

**Tells "you were kicked" apart from "the network died".** They look identical at the socket level
and need opposite responses. The server closes with a reason of `im-kick:{Reason}`; the SDK stops
reconnecting for terminal reasons (another device took over, banned, revoked, app disabled, admin
kick) and asks `onTokenExpired` for a fresh token when the reason is expiry. A reason this version
does not recognise is treated as recoverable — a newer server must not be able to strand an older
client offline.

**Repairs gaps, and pages while it does.** `msg.sync` is clamped to 500 messages server-side and
reports `hasMore`, so a 900-message repair asked for in one call silently returns 500. The loop here
is on `hasMore`, never on how many messages came back — the server computes `hasMore` on the raw seq
window *before* removing rows you may not see, so a short page with more to come is normal.

**Resumes across every page.** `conn.sync` returns at most 200 conversations. The list is sorted by
`updatedAt` descending, so page one holds the newest timestamp — the SDK therefore reads every page
and only then advances `conversationCursor`, because a cursor moved after a partial run hides every
conversation on the pages that were never read, permanently.

**Says when it gave up.** A gap wider than `maxAutoRepairSeq` (default 500) is not backfilled
message by message. Both cursors jump the hole *and* the conversation id is raised on
`conversationNeedsReload` — the cursor advance stops every later message looking like a gap, and the
event stops the hole from being one nobody is ever told about. Reload that conversation from
`im.msg.history(...)`.

**Renews a token without reconnecting.** A `1101 TokenExpired` on any call fetches a fresh token
from `onTokenExpired`, exchanges it on the socket you already have with `conn.reauth`, and retries
the failed call once. On the flaky network where tokens expire, a reconnect is the thing you were
trying to avoid.

**Deduplicates sends.** `clientMsgId` is generated automatically if you do not supply one, so a
retry after a timeout returns the original result with `deduplicated = true` instead of sending
twice.

**Notices a half-open socket.** The heartbeat runs on the interval the *server* reports, and a
missed beat abandons the socket outright rather than asking politely for a close frame the dead
peer will never send.

## The typed surface

107 endpoints — contract tiers T0, T1, T2 and T3 in full, plus, of T4, the nine `desk.*`, the seven
`room.*`, the four `msg.stream*`, the three schedule calls, the three folder calls, `msg.translate` and the seven `keys.*` — grouped into namespaces named for the target prefix, so a reader who knows the endpoint name knows the call
without a lookup table. `msg.recall` is `im.msg.recall`; there are no synonyms. The names after the
`·` are T3.

| Namespace | Endpoints |
|---|---|
| `im.conn` | `heartbeat` `reauth` `sync` |
| `im.msg` | `send` `sync` `history` `recall` `edit` `delete` `forward` `react` `receipt` `typing` · `pin` `unpin` `pins` `favourite` `unfavourite` `favourites` `burn` `search` `receiptDetail` · T4: `streamBegin` `streamAppend` `streamComplete` `streamAbort` `schedule` `scheduled` `cancelScheduled` `translate` |
| `im.conv` | `list` `get` `read` `setting` `delete` `clear` `unreadTotal` · `markUnread` · T4: `folders` `upsertFolder` `deleteFolder` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` · `setStatus` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `block` `unblock` `blockList` · `setRemark` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` · `transfer` `applicationList` `handleApplication` `setRole` `mute` `muteMember` `setNickname` `announcement` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` `clicked` |
| `im.moderation` | `report` |
| `im.diag` | `logRequests` `logUploaded` — the client drives both; ordinary applications never call them |
| `im.desk` | `request` `accept` `transfer` `close` `status` `queue` `rate` `canned` `suggest` — T4, the customer-service desk |
| `im.room` | `join` `quit` `send` `onlineCount` `memberList` `mute` `kick` — T4, chat rooms |
| `im.keys` | `publish` `upload` `remaining` `claim` `devices` `revoke` `safetyNumber` — T4, the end-to-end encryption key directory |

Every method takes exactly one request object, named for the server DTO. That is not a style
preference: with positional parameters, the server adding one optional field is a source-breaking
change in five languages at once. Kotlin's default arguments give the ergonomics back, and a few
one- and two-field calls have positional overloads (`im.conv.read(id, seq)`).

Returns are the `data` payload, unwrapped — never an envelope. A non-zero code throws. List
endpoints return `Page<T>`, which keeps `nextCursor`/`hasMore`/`total`: **page on `hasMore`, never
on `items.size`**, because the server computes its cursor before filtering rows you cannot see.

### Tier T3 — what the signatures do not say

Every T3 method carries its full list of refusals in its KDoc. These are the ones that bite:

- **Message ids leave quoted, and the server insists.** Every request DTO that carries a message id
  (T1–T3 alike: recall, edit, delete, react, forward, receipts, a reply's `quoteMessageId`, pins,
  favourites, reports) declares it a string, and the socket refuses a JSON number for one with an
  opaque `1000` rather than a `1001` naming the field. The field is still a `Long` here —
  `ImMessage.messageId` goes straight in — and every request type writes it as a string.
- **`msg.search` is off unless the tenant turned it on** (`1203` — do not latch it), needs the search
  add-on (`1204`), and is rate limited per user (`1003`, 30 a minute by default) **before** either
  check, so calls against a tenant with search off still spend the budget. Debounce
  search-as-you-type.
- **`msg.receiptDetail`'s `totalCount` includes the sender**; `readUserIds` never does. Fully read is
  `readCount == totalCount - 1`. The read itself has no size cap: in groups above the tenant's
  receipt limit it is `msg.receipt` that refuses, so there is nothing recorded to read.
- **`group.mute` with an `untilMs` in the past mutes indefinitely**, while `group.muteMember` with one
  in the past unmutes. `mute` and `conv.markUnread`'s `unread` both default to `true`, and the SDK
  sends that default explicitly.
- **`group.setRole` sends `GroupRole.Member` or `GroupRole.Admin` only**, and throws
  `IllegalArgumentException` for anything else before a frame is written: the server refuses
  `Owner` but stores any other integer, and `0` or `4` are privilege bugs rather than roles.
- **`group.applicationList` returns every status**, not only pending — filter on `status` yourself.
  Called with no argument it lists across every group you manage.
- **`friend.setRemark` without `remark` clears the remark**, while leaving `tags` null keeps them.

### The service desk — `im.desk` (T4)

Two audiences share the namespace and the session decides which one you are: `request` and `rate`
are the customer's (an in-app "contact support" screen), `accept`, `transfer`, `status`, `queue`,
`canned` and `suggest` are an agent's, `close` is either side's. The conversation itself is an
ordinary chat with the desk account — `msg.send` and `msg.history` — and these nine only move the
assignment around it.

- **`DeskTransferRequest` has no public constructor.** Build it with `DeskTransferRequest.agent(…)`,
  `.skill(…)` or `.queue(…)`: the server refuses two targets, or none, with `1001`.
- **Leaving `DeskCloseRequest.inviteRating` null invites a rating** — the server's default is `true`.
  Pass `false` to close quietly.
- **`DeskStatusRequest` is also the heartbeat.** Send it on a timer; the roster reclaims an agent
  whose console stops talking. `AgentStatus` goes out as its integer.
- **`DeskSession.endReason` is a string** (`DeskEndReason`) where `state` beside it is an integer.
- **`DeskCannedRequest.ownerMemberId` is a filter, not a permission**: leave it null and every
  member's personal entries come back.
- `im.deskEvents` is `evt.desk` decoded into `DeskEvent` — a session frame (`change` is one of
  `DeskSessionChange`, and `session` is null on a forced release) or the agent `takeover` frame.
- **The 1801–1807 notices a customer sees arrive as ordinary messages** on `im.messages` — which
  is what keeps a transcript readable months later — so ask `readDeskNotification(message)` first
  and fall through to your chat rendering when it answers null. It answers a notice only when
  `contentType` is `MessageContentType.Notification` **and** `content.code` is 1801–1807: the same
  seven numbers are account error codes elsewhere on this platform, and a bare code check will one
  day draw "your account is locked" onto a support transcript. The answer is the sealed
  `DeskNotification` — `Queued`, `Assigned`, `Transferred` (`fromAgentId`), `Closed` (`resolution`,
  `reason` `"timeout"`), `Requeued` (`previousAgentId`), `Abandoned` (`waitedSeconds`) and
  `RatingRequested` (`windowHours`, `askResolved`, `starTags`) — so a `when` over it needs no
  `else`. `skill` may be null on any of them and `agentId` is null until an agent is involved. It
  never throws: a member of the wrong JSON kind reads as its default (an id `""`, a count 0), and
  the counts and the code are read whether the server wrote them as numbers or as quoted ones.

  ```kotlin
  im.messages.collect { message ->
      when (val notice = readDeskNotification(message)) {
          null -> showChat(message)
          is DeskNotification.Queued -> showLine("You are in the queue")
          is DeskNotification.Requeued -> showLine("We are finding someone else for you")
          is DeskNotification.RatingRequested -> showSurvey(notice.sessionId, notice.starTags, notice.askResolved)
          else -> showLine(notice.toString())
      }
  }
  ```
- **`DeskContextKeys` names the keys the engine copies out of `DeskRequest.context`** —
  `desk.channel`, `desk.visitorId`, `desk.deskId`, `desk.groupId`, `origin` (`"bot"` for a bot
  handoff), and `desk.page` / `desk.visitorName` / `desk.visitorEmail` for the workbench. Every other
  key you put in the context travels to the workbench untouched.

### Chat rooms — `im.room` (T4)

A room is the live-stream comment wall and the broadcast lobby: it trades every delivery guarantee
for scale, and the client has to know which ones.

- **A room message has `seq` 0 and never enters gap repair.** It arrives on `im.messages` as an
  ordinary `ImMessage` with `conversationId` `r_<roomId>` and `conversationType` `ChatRoom`,
  delivered the moment it lands — not ordered, not deduplicated by seq, and never repaired: it is
  not stored per user, so a dropped frame is simply gone and there is no range to ask `msg.sync`
  for. The SDK keeps it out of every cursor; **do not commit it** (`commit` ignores seq 0, so the
  quick start's "commit everything you store" loop is safe). `im.room.send` answers `seq` 0 too and
  moves nothing.
- **Rooms are created by the tenant's backend** (`POST /v1/rooms`); there is no socket call for it.
- **Joining belongs to the connection.** After a reconnect, send `room.join` again for every room
  still on screen — the SDK does not rejoin for you. `RoomJoinResult.recent` is the room's last few
  messages for a newcomer, returned to the caller only and never replayed on `im.messages`.
- **`RoomMuteRequest` has no defaults on purpose**: `userId = null` mutes the whole room, and
  `untilMs = null` (or a time already past) *lifts* the mute. Only the owner and `ChatRoom.admins`
  may mute or kick (`1103`), and nobody can mute or kick the owner (`1511`).
- **`room.send` takes a `RoomMessage`**, not a `SendMessageRequest`: a room is addressed by
  `roomId`, and quote, thread and receiver fields would be ignored. A blank `clientMsgId` is filled
  in. Refusals: `1602` not joined (or kicked), `1603` the room is muted, `1506` you are muted,
  `1003` the room is over its rate.
- **`room.memberList` is a sample**, never the full list; page on `hasMore`. `room.onlineCount` is a
  bare `Long`, and an unknown room answers 0 rather than `1600`.
- `im.roomEvents` is the `room.*` events out of `evt.system` — `room.muted`, `room.kicked`,
  `room.destroyed` — decoded into `RoomEvent`. It reads `evt.system` beside the device-log handler
  and takes only names starting `room.`; one this build does not know still arrives, with its raw
  `body`. A `room.kicked` naming you means stop sending: the server answers `1602` from then on.

### Streaming replies — `im.msg.stream*` (T4)

An AI assistant typing out its reply: the producer opens a stream, appends pieces as its model
produces them, and completes it into one ordinary message. The platform calls no model.

**Sending.** `im.msg.streamBegin(BeginStreamRequest(…))` answers a `StreamHandle`; then
`streamAppend(StreamAppendRequest(streamId, delta))` for each piece, and finally
`streamComplete(CompleteStreamRequest(streamId))` (the stored message's `SendMessageResult`) or
`streamAbort(StreamAbortRequest(streamId, reason))`. `StreamWriter.begin(im.msg, request)` holds the
stream id and the `clientMsgId` for you; the four calls remain the surface.

```kotlin
val reply = StreamWriter.begin(im.msg, BeginStreamRequest(receiverId = "u_bob", placeholder = assistantCard))
try {
    model.generate(prompt).collect { token -> reply.append(token) }
    reply.complete()                  // stored as {"text": every piece, joined}
} catch (e: Exception) {
    reply.abort("the model failed")   // a terminal frame for everyone; nothing stored
    throw e
}
```

- **Anyone signed in may stream, but only as themselves**, in a single chat (a chat with yourself
  included) or a group of at most 200 — a chat room, system or assistant conversation answers
  `1008`. Every permission `msg.send` checks is checked at `streamBegin`; no app setting gates it.
  Name the conversation by `conversationId`, else `receiverId`, else `groupId`.
- **`clientMsgId` is the finished message's idempotency key** and the server makes none up; a blank
  one is filled in. `contentType` is what the finished message will carry. `options` is nested and
  matched case-sensitively; a non-empty `pushConfig.title` / `body` is refused (`1103`).
- **The stream dies of silence, not of age**: append or complete within
  `StreamHandle.idleTimeoutSeconds` (30) of the last call, or the server reaps it — a terminal frame,
  no message. Limits: 4096 characters a piece and 16384 in all (`1401`, and the stream stays open),
  100 pieces a second (`1003`), 60 openings a minute.
- **`streamComplete` without `content` stores `{"text": …}` of the pieces; with `content`, it
  replaces them.** It can be refused like `msg.send`, and the stream is consumed either way: a
  second complete or abort answers `1002`, as does any call after the stream was reaped.

**Receiving.** `im.streamEvents` is `evt.stream`, decoded into `StreamEvent`s: the opening (index 0,
with the producer's `placeholder`), pieces (index 1, 2, 3…), and one terminal frame (one past the
last piece) — `Completed` with the stored message's `messageId` and `seq`, or `Aborted` with an
`abortReason` (the producer aborted, went quiet, or its completion was refused). The producer's own
connection receives all of them too. `assemble()` turns them into the `AssembledStream` to draw:

```kotlin
im.streamEvents.assemble().collect { stream ->
    when (stream.status) {
        StreamStatus.Streaming -> drawTyping(stream.streamId, stream.placeholder, stream.text)
        StreamStatus.Completed -> swapForMessage(stream.streamId, stream.messageId!!)
        StreamStatus.Aborted -> drawStopped(stream.streamId, stream.abortReason)
    }
}
```

- **The pieces are not messages.** No seq, online devices only, never stored, never resent — the
  SDK keeps them away from every cursor and the gap repair, and there is nothing to commit. Pieces
  are joined by index, a duplicate is ignored, and the text stops at a missing piece rather than
  running past it. **A hole is not repaired** (there is no resend or catch-up): the stream is
  marked not `intact`, as is one this device joined mid-way.
- **The completed stream is an ordinary message**: a real seq, the `clientMsgId` it was opened with,
  delivered on `im.messages` through cursors and gap repair like any other — to the producer too,
  which is why `streamComplete`, unlike `msg.send`, does not move the delivered cursor. That message,
  not the assembled text, is what to keep: the producer may have replaced the pieces, and a piece
  this device missed is in it. **The terminal frame and the message can arrive in either order**;
  match them by `messageId`. A device that was offline simply receives the message.
- An aborted stream leaves nothing behind. Streams in flight when the connection drops are settled
  by the stored message or not at all — reset a long-lived `StreamAssembler` with `clear()` on
  reconnect (`assemble()` starts a fresh one per collection).

### Scheduled messages — `im.msg.schedule` (T4)

Write a message now, have the server send it later: `im.msg.schedule(ScheduleRequest(sendAt, content, receiverId = …))`
answers a `ScheduledMessage` with the `scheduleId` to cancel it by; `im.msg.scheduled()` pages the
outbox; `im.msg.cancelScheduled(scheduleId)` takes one back.

```kotlin
val entry = im.msg.schedule(ScheduleRequest(
    sendAt = System.currentTimeMillis() + 60 * 60_000,
    content = textContent("Stand-up in five minutes"),
    groupId = "team",
))
im.msg.cancelScheduled(entry.scheduleId)
```

- **`ScheduleRequest` is flat and is not a `SendMessageRequest`.** The server binds the message
  members at the top level beside `sendAt`, and there is no `options` and no `sendTime` on this
  path. Address it by `conversationId`, else `groupId`, else `receiverId`; the sender must be allowed
  to write there exactly as for `msg.send`, checked when scheduling. `clientMsgId` is optional — left
  null, the server keys the eventual send `sch-<scheduleId>`.
- **Limits** (`IM:Extras`): `sendAt` at least 10 seconds and at most 90 days ahead (`1001`
  otherwise); 120 schedules created per user per hour (`1003`); 100 pending per user (`1006`).
  **`msg.schedule` is not idempotent**: a retry after a lost reply schedules twice — list first.
- **It fires on the server's sweep**, every 15 seconds by default: on the first sweep after `sendAt`,
  never before. The receiver gets an **ordinary `evt.message`** (the sender's devices the usual self-sync) with
  a real seq, through `im.messages`, cursors and gap repair like any other message. Scheduling itself
  delivers nothing, moves no cursor, and **pushes no event**: another device sees the outbox change
  only by calling `msg.scheduled` again.
- **`ScheduledMessage` has no state field.** Pending: `messageId` and `error` both null. Sent:
  `messageId` set. Cancelled: `error == "cancelled by sender"`. Failed: `error` is the reason.
  **Cancelled, sent and failed entries stay listed for about 48 hours**, so a cancel is not followed
  by an empty list. `msg.scheduled` runs in `sendAt` order, 20 a page by default (100 at most).
- `msg.cancelScheduled`: `1002` for an unknown schedule or someone else's. `1006` means nothing is
  left to cancel — it is being sent, was already cancelled, or was already sent or failed; only the
  server's message tells which. For one that was sent, the remedy is `msg.recall`.

### Conversation folders — `im.conv.folders` (T4)

A folder is a saved filter over the conversation list — tags, optionally conversation types and
"unread only" — that the server stores per user and the client applies. `im.conv.folders()` returns
all of them as a plain `List` (no paging); `im.conv.upsertFolder(UpsertFolderRequest(name, …))`
creates one (no `folderId`) or replaces one wholesale, and answers it as stored;
`im.conv.deleteFolder(folderId)` removes it and leaves the conversations alone.

- **Every tag must already be on one of your conversations** (`conv.setting`'s `tags`), or the save
  is `1001`. Other limits: 20 folders per user (`1006`), 16 tags per folder, names and tags up to 64
  characters, a `folderId` of 1–64 letters, digits, `-`, `_` or `.`.
- `types` go out as integers; an empty list is stored as none and comes back absent (all types).
  `order` below 0 is stored as 0. Sort by `order`, then `name`.
- **Creating is not idempotent** — keep the `folderId` from the answer and send it on every later save.
  Deleting one you do not have is `1002`. No event announces a folder change; re-read on other devices.

### Translation — `im.msg.translate` (T4)

`im.msg.translate(TranslateRequest(conversationId, messageIds, "zh-CN"))` translates up to 50
messages of one conversation and answers a `TranslationResult`: one `TranslatedMessage` per id, with
`text`, `cached`, or an `error` for that message alone — a message that cannot be translated does not
fail the call. `sourceLanguage` is a hint; leave it null to let the provider detect it.

**The platform calls no model of its own, and most deployments refuse this call.** Both refusals are
ordinary `ImException`s carrying the server's sentence, checked before anything else about the request:

- `1204 PlanExpired` — the tenant's plan does not include the translation add-on (Enterprise and up,
  or a trial);
- `1203 FeatureNotEnabled` — the plan includes it but the deployment has no provider configured
  (`IM:Translation:Provider`).

```kotlin
try {
    show(im.msg.translate(TranslateRequest(conversationId, listOf(message.messageId), "zh-CN")))
} catch (e: ImException) {
    if (e.code == ImErrorCode.FeatureNotEnabled || e.code == ImErrorCode.PlanExpired) hideTranslate(e.message)
    else throw e
}
```

Neither is retryable; do not latch either beyond the session, since both are runtime settings.

### Key directory (end-to-end encryption) — `im.keys` (T4)

The directory where each device publishes its **public** keys and a sender fetches a peer's to
open a session (X3DH-style: identity key, signed prekey, one-time prekeys).

**What the SDK does and does not do.** It types the seven calls and moves the key material
unchanged. **It performs no cryptography**: generating key pairs, signing the signed prekey,
running the key agreement and encrypting messages are your crypto library's. Every key and
signature is an opaque **standard-base64** string (not base64url); pass it exactly as your library
produced it — the server compares identity keys by exact string and hashes the strings into the
safety number, so a re-encoded key is a different key. No private key ever crosses this surface,
and the SDK never logs key material.

```kotlin
// Once per device, and again whenever you rotate the signed prekey:
im.keys.publish(PublishKeysRequest(
    identityKey = identity.publicBase64,
    signedPreKey = SignedPreKey(keyId = "spk-7", publicKey = spk.publicBase64, signature = spkSignatureBase64),
    oneTimePreKeys = batch.map { OneTimePreKey(it.id, it.publicBase64) },
    algorithm = "x3dh-ed25519-aes256gcm-v1",   // null keeps the server default, x3dh-curve25519-aes256gcm-v1
))
if (im.keys.remaining() < 20) im.keys.upload(nextBatch())

// Sending to bob: one ciphertext per device.
for (device in im.keys.devices("bob")) {
    val bundle = im.keys.claim("bob", device.deviceId)   // consumes one of that device's one-time prekeys
    openSession(bundle)                                   // bundle.oneTimePreKey may be null
}
val fingerprint = im.keys.safetyNumber("bob")             // "12345 67890 … " — 12 groups of 5 digits
```

- **`keys.claim` consumes.** Each claim hands out one one-time prekey and deletes it (first in,
  first out), so `remaining` drops by one. It is **not idempotent: never retry it after a lost
  reply as if it were, and never prefetch.** When the pool is empty the claim still succeeds, with
  `oneTimePreKey` null. Claiming your own device is allowed and drains your own pool.
- **`keys.publish` replaces and keeps the pool.** Identity key, signed prekey and algorithm are
  replaced; the one-time pool is kept and the new keys appended — unless the identity key changed,
  which deletes the old pool first. The device and platform are the connection's; they are not on
  the request. The signed prekey's signature is the identity key's over the decoded bytes of its
  `publicKey` only; the server verifies it (`1001` when it does not) and picks the scheme from
  `algorithm` (`curve25519`/`x25519`/`xed25519`, `ed25519`, `p256`; anything else `1008`).
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
- `devices` comes back in no particular order; an unknown user is an empty list, and an unknown
  device's `remaining` is 0. Neither is an error.

### Anything not yet typed

The escape hatch shares one code path with the typed methods — for an endpoint a newer server
ships before this SDK types it:

```kotlin
// The name is illustrative:
val reply = im.invoke<JsonElement>("feature.newCall", buildJsonObject {
    put("id", id)
})
```

`invoke` never touches a cursor: `invoke("msg.sync", …)` returns messages and moves nothing.

## Single-chat ids

A single chat's id is fixed by its two users, so it can be built from them alone — to open the
chat's history or look it up with `im.conv.get` before you hold a message from it:

```kotlin
import com.cyaim.im.client.singleConversationId

singleConversationId("bob", "alice")      // "s_alice_bob"
singleConversationId("u_alice", "u_bob")  // "s_u~1alice_u~1bob"
```

The rule is `"s_" + enc(A) + "_" + enc(B)`: the two **raw** user ids ordered by UTF-16 code unit
(Kotlin's own `String` comparison), each with `~` written `~0` and `_` written `~1`, so the one `_`
after the prefix is the separator and every id names exactly one pair. Which end you pass first does
not matter. **Do not join the ids yourself**: `"s_${a}_$b"` is right only while neither id contains
`_` or `~`; past that, the id it gives is malformed (the server answers `1001`) or names a different
pair. The rule is shared with the server and the other SDKs through
[`single-chat-id-vectors.json`](../single-chat-id-vectors.json), which `SingleChatIdTest` reads.

## Coroutines and Flow

Events are flows, calls are `suspend` functions, and everything is structured.

| | |
|---|---|
| `messages: SharedFlow<ImMessage>` | Every message, in `seq` order per conversation, gaps repaired |
| `state: StateFlow<ConnectionState>` | `Idle` \| `Connecting` \| `Open` \| `Reconnecting` \| `Closed` |
| `kicks: Flow<KickEvent>` | Why the session ended, from the push or the close reason |
| `deskEvents: Flow<DeskEvent>` | `evt.desk`, for a service-desk agent |
| `roomEvents: Flow<RoomEvent>` | `room.muted` / `room.kicked` / `room.destroyed`, out of `evt.system` |
| `streamEvents: Flow<StreamEvent>` | `evt.stream`: a reply arriving piece by piece; `.assemble()` for the text |
| `conversationNeedsReload: Flow<String>` | Fell too far behind to backfill — reload it |
| `cursorStoreState: StateFlow<…>` | Whether the cursor store loaded, and whether it persists |
| `events<T>(target)` | Any other server event, decoded (`evt.typing`, `evt.read`, `evt.group`, …) |

Pass a `parentContext` and the client is a child of *your* scope: cancel a `viewModelScope` and the
socket, the reconnect loop, the heartbeat and every in-flight request go with it.

Messages for one conversation are delivered in `seq` order and never concurrently — each
conversation has its own inbox coroutine, which is also what holds a live message behind an
in-flight repair. Calling back into the SDK from inside a collector is legal and does not deadlock.
Cancelling a call abandons the reply; it does **not** cancel the server-side effect, which is what
`clientMsgId` idempotency is for.

Failures are exceptions, not result codes. `ImException` carries `code` (see `ImErrorCode`),
`traceId` — quote it in a support ticket and the server logs line up — the `target` that failed, and
`isRetryable` / `requiresReauth`, both computed from the code alone so all five SDKs agree.

```kotlin
try {
    im.msg.send(SendRequest(SendTarget.Group("g-123"), textContent(text)))
} catch (e: ImException) {
    when (e.code) {
        ImErrorCode.MemberMuted -> toast("You are muted in this group")
        ImErrorCode.ModerationRejected -> toast("Message rejected")
        ImErrorCode.RateLimited -> backOffAndTellTheUser()
        ImErrorCode.QuotaExceeded, ImErrorCode.PlanExpired -> alertTheTenant(e)
        else -> log("send failed: ${e.code} trace=${e.traceId}")
    }
}
```

The SDK never auto-retries a business call. It retries the *connection* and its own gap repair;
everything else surfaces with `isRetryable` set and you decide. An SDK that silently re-sends on
`1003` hides rate limiting from the UI that has to explain it.

`1203 FeatureNotEnabled` means the tenant has that feature switched off right now. **Do not cache
it** — the flag is a runtime setting, and a client that remembers "typing is off" stays broken after
the tenant turns it back on.

## Offline push

The server has had `push.register` since before this SDK called it, which meant offline
notifications — the feature every mobile deal turns on — were unreachable from any official client.
They are reachable now, and the wiring is a few lines in *your* app.

**The host app owns token acquisition. The SDK owns token delivery.** Firebase hands the FCM token
to a `FirebaseMessagingService`, not to a library, so this artifact does not pretend it can ask for
one — which is also how it stays free of Android dependencies.

```kotlin
class ImMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Im.client?.push?.setToken(PushProvider.Fcm, token)
    }
}

// …and once at startup, because onNewToken only fires when the token *changes*:
im.push.setToken(PushProvider.Fcm, FirebaseMessaging.getInstance().token.await())
```

On a Chinese OEM handset substitute that vendor's SDK and its provider constant — `PushProvider`
has `Huawei`, `Xiaomi`, `Oppo`, `Vivo`, `Honor` and `Apns` alongside `Fcm`. **Always pass the
provider explicitly on Android:** the server's empty-provider fallback is only reliable on iOS, and
Android fragments across five OEM channels the server cannot guess between.

From there the SDK handles the rules:

- It registers on **every successful connect**, not once at install — the vendor can replace a token
  while your process is frozen and the server has no other way to learn it. Re-registering an
  unchanged token costs no write; the server debounces it.
- A token handed over while the socket is down is cached and sent on the next connect.
- **`im.logout()` unregisters before it closes the socket.** Closing first would leave the token
  registered with no authenticated channel left to remove it, and the user would keep getting
  notifications for an account that has logged out. `close()` on its own never unregisters — a dead
  socket is precisely the state offline push exists to serve.

**Report the tap, from the tap handler.** Neither FCM nor any OEM channel reports delivery back to
us, so on most deployments a tap is the only evidence a notification ever arrived, and the server
credits delivery from it. The tenant's push screen shows a sent → delivered → clicked funnel with no
other source:

```kotlin
override fun onNewIntent(intent: Intent) {
    val messageId = intent.getStringExtra("msgId") ?: return
    lifecycleScope.launch { im.push.clicked(PushClickedRequest(messageId = messageId)) }
}
```

Call it where the tap is handled, not where the message is rendered — the two are different moments
and only the first one is a click. It does not throw and must not be retried: a failure is
`2401 PushDeliveryNotFound` (the record aged out after seven days), which is nobody's fault, and a
tap counted twice is worse than one counted never. Cancellation still propagates, so a cancelled
scope stays cancelled.

If a client dies without unregistering — force quit, crash, uninstall — only your backend can clean
up: `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Ship that call, or ship the bug.

**Notification text is set by your server, not by this SDK.** A message sent from here whose
`options.pushConfig` has a non-empty `title` or `body` is refused with `1103` (`ImErrorCode.Forbidden`). That text
would replace the notification template that names the sender, and moderation never reads it.
Leave both empty and the recipient's notification is built from the message itself; `sound`,
`channelId`, `badgeCount` and `payload` stay open to clients. For custom text ("your order has
shipped"), send the message from your backend through `/v1` or the server SDK, which may set them.
The same rule, also `1103`, refuses an image, voice, video or file message with `persistent: false`
or `onlineOnly: true` while the app moderates content. See CONTRACT.md §2.

## Android

**Doze and App Standby will kill the socket, and that is fine.** Once the screen has been off and
still for a while, Android suspends the process and tears down its network. There is no client-side
trick that prevents it, and the SDK deliberately does not try: no wake lock, no foreground service,
no alarm. Holding a `PARTIAL_WAKE_LOCK` to keep a chat socket alive drains a battery and *still*
loses the connection. The reconnect path is built to survive the interruption instead — the backoff
ceiling never grows past 30s, so a phone that wakes after eight hours is back within half a minute.

**Give the reconnect a nudge when you come back.**

```kotlin
lifecycle.addObserver(LifecycleEventObserver { _, event ->
    when (event) {
        Lifecycle.Event.ON_START -> im.resumeNow()
        Lifecycle.Event.ON_STOP -> lifecycleScope.launch { im.flushCursors() }
        else -> {}
    }
})

connectivityManager.registerDefaultNetworkCallback(object : NetworkCallback() {
    override fun onAvailable(network: Network) = im.resumeNow()
})
```

`resumeNow()` skips whatever remains of the current backoff and resets the attempt counter.
`flushCursors()` writes out any commit still inside the debounce window; the SDK also flushes before
every `conn.sync` and on `close()`, and never debounces an adoption, so this is a safety net rather
than a requirement.

**Scope it to the session, not to a screen.** One `ImClient` per logged-in user, created when the
token is issued and closed on logout. If you tie it to an Activity's `lifecycleScope`, a rotation
closes the socket and opens a new one — which the multi-device policy is entitled to read as a
second device.

**Other details.**

- `minSdk 21`, `jvmTarget 11`. No `android.*` imports, no manifest, no `Context`.
- **`compileSdk` is not a free choice, and it is not ours.** On Android the `okhttp` coordinate
  resolves to `okhttp-android`, whose AAR carries a `minCompileSdk` that every consumer inherits.
  We pin OkHttp **5.3.0** because that is the newest release with no floor at all; 5.4.0 requires
  `compileSdk 36` and 5.5.0 requires `37`. A build that violates it fails at
  `checkDebugAarMetadata` — before any code of ours runs — so it reads as a project misconfiguration
  rather than as a dependency constraint. If you force a newer OkHttp, raise `compileSdk` to match.
  **compileSdk 不是随便选的，而且那个约束不来自我们**：Android 上 `okhttp` 会解析成
  `okhttp-android`，它的 AAR 带着一个所有消费者都会继承的 minCompileSdk。
  我们钉 OkHttp **5.3.0**，因为它是完全没有下限的最新版；5.4.0 要 36，5.5.0 要 37。
  违反时失败在 checkDebugAarMetadata 上——**我们的代码一行都还没跑**——
  于是它读起来像工程配置错了，而不像一条依赖约束。要强行用更新的 OkHttp，就同步抬 compileSdk。
- R8 rules for kotlinx.serialization ship inside the jar (`META-INF/proguard/im-client.pro`), so a
  shrunk release build decodes messages exactly like the debug build.
- `deviceId` must survive reinstall-free restarts: store a UUID in DataStore on first run. A random
  value per launch makes users kick themselves offline under `OnePerPlatform`.
- The SDK adds no permissions of its own. `INTERNET` is the only one it needs.
- Bring your own `OkHttpClient` if you have tuned one:
  `ImClient(options, store, OkHttpSocketFactory(myClient))`.

## Notes

- **Never put an AppSecret in client code.** The client only ever holds a short-lived user token
  minted by your backend, and it never calls the `/v1` REST API — that surface authenticates with
  server credentials and belongs to your backend.
- Order messages by `seq`, never by timestamp. Client clocks are wrong and arrival order is not send
  order.
- Wire enumerations are **open**: `MessageContentType`, `GroupRole` and the rest are value classes
  over the server's integer, so a member this build does not know keeps its number instead of
  collapsing into `Unknown`. `when` over one needs an `else`, and that branch is the one that
  handles a server newer than your app.
- Unread counts come from the server as `maxSeq - readSeq`. They are derived, not a counter that can
  drift, so marking read on one device clears the badge on all of them.
- `ImOptions.toString()` redacts the token. Anything you log yourself should too.
- `ImSdk.version` and `ImSdk.contractVersion` are what a support ticket should quote.

## Building

```bash
./gradlew build                                  # compiles, runs the tests
./gradlew test --rerun-tasks --no-build-cache    # cursors, push, jitter, kicks, gap repair, half-open sockets
```

Java 11 or newer to consume, Java 17 or newer to build.

> ### ⚠️ `--rerun-tasks --no-build-cache` is not belt-and-braces. Without it the suite runs zero tests.
>
> Plain `./gradlew test` prints **`BUILD SUCCESSFUL`** having executed **nothing**: `:test` is
> `UP-TO-DATE`, and after a `cleanTest` it comes back `FROM-CACHE`. This was live in CI for a while
> and it is exactly the kind of green that is worse than red — it converts "we did not test this"
> into "we tested this and it was fine".
>
> **The obvious guard does not work either**, which is the part worth remembering: counting test
> cases in `build/test-results/**/*.xml` is defeated by the same cache, because the build cache
> restores `test-results/` alongside the task outcome. The report proves a test task *once*
> succeeded, not that it succeeded here. Only re-running does.
>
> **本机跑通的 112 条就是用上面这条命令跑出来的。** 不带那两个参数，`./gradlew test` 会执行
> **零个测试**并打印 `BUILD SUCCESSFUL`；连"数 XML 报告里的用例数"这个断言也拦不住它，
> 因为构建缓存会把 `test-results/` 一起恢复——那份报告证明的是"某一次成功过"，不是"这一次"。

The tests never open a socket. `ImSocketFactory` is the seam, `ImCursorStore` is the other one, and
every timing rule in here — the backoff window, the thirty-second heartbeat, the fifteen-second
request timeout, the cursor debounce — is asserted on `kotlinx-coroutines-test`'s virtual clock, so
the whole suite runs in under a second and none of it is flaky.
