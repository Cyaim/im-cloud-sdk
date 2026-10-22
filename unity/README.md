# com.cyaim.im

Unity client for Cyaim IM Cloud. Unity 2022 LTS and newer, every build target including WebGL.

Install through the Package Manager: **Add package from git URL** with
`https://github.com/Cyaim/im-cloud-sdk.git?path=/unity#v0.9.0`, **Add package from disk** pointing at this
folder's `package.json`, or by copying the folder into your project's `Packages/com.cyaim.im`.

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
> Use **Add package from disk**, pointing at `unity/package.json` in a clone of this
> repository, or copy the folder into your project's `Packages/com.cyaim.im`.
>
> The git-URL form is the one that does not work yet, and it fails for a reason worth knowing:
> UPM resolves the `#v0.9.0` fragment as a **git ref**, and there are no tags. Drop the fragment
> and UPM takes the default branch, which is a moving target and not something to ship against.
>
> The registry prerequisites still outstanding are listed in
> [`CONTRACT.md` §9.4](../CONTRACT.md).

```csharp
using Cyaim.Im;

var im = new ImClient(new ImClientOptions
{
    Endpoint = "wss://im.example.com",
    AppId    = "your-app-id",
    UserId   = "alice",                              // who the token is for
    Token    = await FetchTokenFromYourBackend(),
    DeviceId = ImDevice.GetOrCreateDeviceId(),
    TokenProvider = ct => FetchTokenFromYourBackend(ct),

    // Required. See "Cursors" below — this is the difference between an app that
    // picks up where it left off and one that silently loses what arrived overnight.
    CursorStore = ImCursorStore.PersistentDataPath(),
});

im.MessageReceived += m =>
{
    ChatDatabase.Insert(m);                          // durable first
    im.Commit(m.ConversationId, m.Seq);              // then, and only then, commit
    chatView.Append(m);                              // main thread, always
};

im.StateChanged += s => banner.SetState(s);
im.Kicked       += k => { if (k.IsTerminal) ReturnToLogin(k); };

await im.ConnectAsync();
await im.Msg.SendTextAsync(ImRecipient.User("bob"), "hello");
```

The **Chat Quickstart** sample (Package Manager → Samples) is the same thing as a `MonoBehaviour`,
including a real token fetch against your own backend, an image send, and push registration.

## Cursors, and the two lines you must not skip

The SDK keeps two numbers per conversation and they are not interchangeable.

| | what it is | where it lives |
|---|---|---|
| `deliveredSeq` | highest seq handed to your code in this process | memory |
| `committedSeq` | highest seq **you** have said is durably stored | `CursorStore`, and reported to the server |

`Commit` is the only thing that moves the second one. The SDK will not infer it from a handler
returning, because a handler returning means the message reached memory — which is exactly the state
a crash loses.

**What goes wrong without it.** A client that keeps its position in memory only reports nothing on
the next launch. The server computes a gap only for conversations the client told it about, so it
reports none; the client then adopts the server's newest seq as its own. Every message that arrived
while the app was closed is now behind the cursor. It is never requested, never arrives, and nothing
— no error, no log line, no later event — ever says so. That was a real bug in four of the five
Cyaim client SDKs, and this design is the fix. The whole model is `sdk/CONTRACT.md` §5.

Consequences worth knowing before you ship:

- **Delivery is at-least-once.** Be idempotent on `ImMessage.MessageId`. A message delivered but not
  committed is delivered again after the next reconnect, which is the mechanism working.
- **A game with no local store can commit straight from the handler.** "Durable" then means "as
  durable as this game gets". That is honest, and it is still better than the SDK assuming it,
  because the choice is visible in your code rather than hidden in ours.
- **Never call `Commit` before your write returns.** Committing optimistically is how a crash turns
  into a permanently skipped message.
- **The cursor store and your message store have one lifetime**, cursors first. Clearing messages
  while keeping cursors leaves a conversation the app will never refill; clearing cursors while
  keeping messages costs a full re-download and duplicate delivery.

Stores:

| | when |
|---|---|
| `ImCursorStore.PersistentDataPath()` | almost every game. One file per account under `Application.persistentDataPath`; `PlayerPrefs` on WebGL, where Unity flushes the filesystem image on its own schedule |
| `ImCursorStore.PlayerPrefs()` | small snapshots, or a build where file IO is not dependable |
| `ImCursorStore.File(path)` | headless builds, dedicated servers, editor tooling |
| `ImCursorStore.InMemory()` | bots, load tests, kiosks. An explicit opt-out that logs one line saying what it costs |

There is no default, deliberately: defaulting to no persistence is what produced the bug, and
defaulting to *some* persistence would mean guessing where a game may write.

If the store cannot be read, `CursorStoreFailed` fires and the SDK adopts nothing and writes nothing
for the rest of the session — a failed load and a fresh install are indistinguishable to the
adoption branch, and guessing wrong destroys history you still have. Recover by re-deriving from
your own database: `im.Commit(conversationId, highestSeqYouHold)` for each one. `Commit` is
monotonic, so order does not matter.

## Offline push

The server side of this exists and the app has to call it. Nothing in `Disconnect` touches a push
token, because a dead socket is precisely the state offline push serves.

```csharp
// iOS, once the OS has answered the permission prompt
im.Push.SetToken(ImPushProvider.Apns, HexOf(NotificationServices.deviceToken));

// Android with the Firebase Unity SDK
FirebaseMessaging.TokenReceived += (_, e) => im.Push.SetToken(ImPushProvider.Fcm, e.Token);
```

Hand the SDK the token once and it re-registers on **every** connect from then on. That is not
wasteful — the vendor may replace a token while the process is frozen and the server has no other
way to learn it, and re-registering an unchanged token costs no write because the server debounces
it. `IsRegistered` is worth surfacing in a settings screen: false while a token is held is otherwise
indistinguishable from a broken push provider, and that misdiagnosis costs a support cycle.

**Always name the provider on Android.** An empty one falls back to the platform default, which is
only reliable on iOS; Android fragments across `fcm`, `huawei`, `xiaomi`, `oppo`, `vivo` and `honor`
and the server cannot guess which channel a token came from.

Sign out with **`await im.LogoutAsync()`**, never with `Disconnect()`. It unregisters and *then*
closes: once the socket is gone there is no authenticated channel and the token cannot be removed at
all, so the handset keeps receiving the next user's notifications.

**Your backend has a job here too.** A client that dies without unregistering — force-quit, crash,
uninstall — leaves its token live. Only the tenant backend can clean that up, with
`DELETE /v1/users/{userId}/push-tokens/{deviceId}`. An integrator who does not know this ships the
bug.

**Report the tap.** APNs and FCM report no delivery at all, so on most deployments the tap is the
only evidence a notification ever arrived, and it is what the tenant's funnel — sent, delivered,
clicked — is built from. Call it from the tap handler with whatever the payload carried:

```csharp
im.Push.ClickedAsync(new ImPushClickedRequest { MessageId = payload["msgId"] });
```

It never throws and is never retried, so there is nothing to await and nothing to handle. With no
arguments at all the server credits this device's newest notification, which is the right answer for
a tap that opened the game without naming a message.

**Notification text is set by your server, not by this SDK.** A message sent from here whose
`Options` carries a `pushConfig` with a non-empty `title` or `body` is refused with `1103`
(`ImErrorCode.Forbidden`). That text would replace the notification template that names the sender,
and moderation never reads it.
Leave both empty and the recipient's notification is built from the message itself; `sound`,
`channelId`, `badgeCount` and `payload` stay open to clients. For custom text ("your order has
shipped"), send the message from your backend through `/v1` or the server SDK, which may set them.
The same rule, also `1103`, refuses an image, voice, video or file message with `persistent: false`
or `onlineOnly: true` while the app moderates content. See CONTRACT.md §2.

## Reporting a player

App-store review treats blocking and reporting as two separate mandatory items for anything carrying
user-generated content, so a game that ships `im.Friend.BlockAsync` alone fails the same submission
twice.

```csharp
var receipt = await im.Moderation.ReportAsync(new ImSubmitReportRequest
{
    TargetUserId   = "bob",
    ConversationId = conversationId,
    MessageId      = message.MessageId.ToString(),
    Category       = ImReportCategory.Harassment,
    Note           = noteField.text,
});
```

There is no field for who is reporting, and there must not be: the reporter is the socket, which is
what makes a report unforgeable. Everything except the target is optional — with no `MessageId` the
report is about the account rather than one message — and the receipt's `ReportId` is what to show in
the confirmation, so a player writing to support has something to quote.

Report the message even when it is gone locally. The target and the category are checked, the message is not: a report
about a message that has already been recalled or deleted is the one a moderator most wants, and
refusing it would turn the platform's own retention into a way to escape moderation.

## The typed surface

107 flat methods on one object is not an API, it is a scroll bar. The surface is grouped into
namespaces named exactly for the endpoint prefix, and every method is named for the method half of
its target — so if you know the endpoint you know the call, in this SDK and in the other four.

| | endpoints |
|---|---|
| `im.Conn` | `HeartbeatAsync` `ReauthAsync` `SyncAsync` |
| `im.Msg` | `SendAsync` `SyncAsync` `HistoryAsync` `RecallAsync` `DeleteAsync` `TypingAsync` `EditAsync` `ForwardAsync` `ReactAsync` `ReceiptAsync` · `PinAsync` `UnpinAsync` `PinsAsync` `FavouriteAsync` `UnfavouriteAsync` `FavouritesAsync` `BurnAsync` `SearchAsync` `ReceiptDetailAsync` · `StreamBeginAsync` `StreamAppendAsync` `StreamCompleteAsync` `StreamAbortAsync` (T4, streaming replies) · `ScheduleAsync` `ScheduledAsync` `CancelScheduledAsync` (T4, scheduled messages) · `TranslateAsync` (T4) |
| `im.Conv` | `ListAsync` `GetAsync` `ReadAsync` `UnreadTotalAsync` `SettingAsync` `DeleteAsync` `ClearAsync` · `MarkUnreadAsync` · `FoldersAsync` `UpsertFolderAsync` `DeleteFolderAsync` (T4, folders) |
| `im.User` | `MeAsync` `ProfileAsync` `BatchProfileAsync` `UpdateProfileAsync` `PresenceAsync` `SubscribePresenceAsync` `UnsubscribePresenceAsync` · `SetStatusAsync` |
| `im.Friend` | `ListAsync` `AddAsync` `HandleRequestAsync` `RequestListAsync` `DeleteAsync` `BlockListAsync` `BlockAsync` `UnblockAsync` · `SetRemarkAsync` |
| `im.Group` | `CreateAsync` `InfoAsync` `UpdateAsync` `DismissAsync` `MemberListAsync` `JoinedAsync` `InviteAsync` `KickAsync` `QuitAsync` `JoinAsync` · `TransferAsync` `ApplicationListAsync` `HandleApplicationAsync` `SetRoleAsync` `MuteAsync` `MuteMemberAsync` `SetNicknameAsync` `AnnouncementAsync` |
| `im.Media` | `UploadTicketAsync` `DownloadUrlAsync` |
| `im.Push` | `SetToken` `RegisterAsync` `UnregisterAsync` `ClickedAsync` |
| `im.Moderation` | `ReportAsync` |
| `im.Diag` | `LogRequestsAsync` `LogUploadedAsync` — the client drives both; ordinary games never call them |
| `im.Desk` | `RequestAsync` `AcceptAsync` `TransferAsync` `CloseAsync` `StatusAsync` `QueueAsync` `RateAsync` `CannedAsync` `SuggestAsync` — T4, the customer-service desk |
| `im.Room` | `JoinAsync` `QuitAsync` `SendAsync` `OnlineCountAsync` `MemberListAsync` `MuteAsync` `KickAsync` — T4, chat rooms |
| `im.Keys` | `PublishAsync` `UploadAsync` `RemainingAsync` `ClaimAsync` `DevicesAsync` `RevokeAsync` `SafetyNumberAsync` — T4, the end-to-end encryption key directory |

That is tiers **T0**, **T1**, **T2** and **T3** of `sdk/CONTRACT.md`, plus the nine `desk.*`, the
seven `room.*`, the four `msg.stream*`, the three scheduled-message calls, the three folder calls,
`msg.translate` and the seven `keys.*` of T4 — all 107 of the server's endpoints: the session floor, everything a two-person chat app needs to launch, the contacts,
blocking, groups, presence and reporting that turn it into a messenger a store will accept, and the
competitive-parity tier on top — pins, favourites, search, read-receipt detail, burn-after-reading
and group administration. The names after the first `·` are T3; the groups marked T4 are T4.

The desk is how an in-game "contact support" screen reaches a person: `RequestAsync` and
`RateAsync` are the player's, the rest an agent's, `CloseAsync` either side's, and the conversation
itself is an ordinary chat with the desk account. `ImDeskTransferRequest` is built with `Agent`,
`Skill` or `Queue`, so exactly one target goes out; an `ImDeskCloseRequest` with `InviteRating` left
null still invites a rating; `ImDeskStatusRequest` is also the heartbeat, and takes its status as a
constructor argument (`new ImDeskStatusRequest(ImAgentStatus.Available)`) because the default, 0, is
`Offline` and the server accepts it; `ImDeskSession.EndReason` is a string where `State` is an integer. `im.OnDeskEvent(handler)` decodes `evt.desk` into
`ImDeskEvent`. The 1801–1807 notices a player sees arrive as ordinary messages. Treat one as a desk
notice only when `ContentType` is `ImMessageContentType.Notification` **and** the content's `code`
is 1801–1807: the same seven numbers are account error codes elsewhere on this platform, so a bare
code check will one day draw "your account is locked" onto a support transcript. The TypeScript
SDK's `readDeskNotification` documents the fields each code carries; this SDK has no reader yet.

### Chat rooms

A room is the live-stream comment wall, the world channel, the lobby everyone is in at once — and it
trades **every delivery guarantee** for that scale. One rule follows, and it is not visible from any
signature:

**A room message has `Seq` 0, and it never enters gap repair.** It arrives on `MessageReceived` as an
ordinary `ImMessage` with `ConversationId` `r_<roomId>` and `ConversationType.ChatRoom`, the moment it
arrives — never held behind a repair in another conversation, never fetched with `msg.sync`, never
replayed after a reconnect, and it moves no cursor. Nothing is stored per player and nothing is pushed
offline: a frame dropped while the socket was down is gone, and there is no range to ask for. Do not
order room messages by `Seq` (it is 0 on all of them — use arrival order or `CreateTime`), and there
is nothing to `Commit`: `Commit` ignores a seq of 0, so a game that commits everything it stores does
not register the room as a conversation to resume. `im.Room.SendAsync` answers `Seq` 0 too, which is
why it does not go through `msg.send` and its cursor bookkeeping.

```csharp
var joined = await im.Room.JoinAsync("lobby");           // the room, its head count, its last few messages
foreach (var m in joined.Recent) ShowComment(m);         // returned here only; not replayed on MessageReceived

await im.Room.SendAsync(new ImRoomSendRequest("lobby", ImRoomMessage.Text("gg")));

using (im.OnRoomEvent(e =>
{
    if (e.Event == ImRoomEvent.Kicked && e.UserId == myUserId) LeaveRoomScreen();
}))
{
    // …
}
```

- **Rooms are created by the tenant's backend** (`POST /v1/rooms`); there is no socket call for it.
- **Joining belongs to the connection.** After a reconnect, call `JoinAsync` again for every room still
  on screen — the SDK does not rejoin for you.
- **`ImRoomMuteRequest` takes all three members in its constructor**, because both optional ones mean
  something when absent: a null `userId` mutes the whole room, and a null or past `untilMs` *lifts*
  the mute. `ImRoomMuteRequest.Unmute(roomId, userId)` says the lifting half out loud. Only the owner
  and the room's admins may mute or kick (`1103`), and never the owner (`1511`).
- **`MemberListAsync` returns a sample**, not the roster; page on `HasMore` / `NextCursor`.
  `OnlineCountAsync` is a bare number. An unknown or destroyed room answers 0 and an empty sample
  there, and `1600` from join, send, mute and kick.
- **`im.OnRoomEvent(handler)`** decodes `room.muted`, `room.kicked` and `room.destroyed` out of
  `evt.system`, beside — not instead of — the device-log request that rides the same target. A
  `room.*` name this build does not know is delivered with its raw `Body`. A `room.muted` without
  `UntilMs` is a lift; `IsMuteInForceAt(nowMs)` reads it for you.

Every method takes exactly one request object, because with positional parameters the server adding
one optional field is a source-breaking change in five languages at once. Convenience overloads
exist where a request has at most two required scalars — `im.Conv.ReadAsync(id, seq)` is fine.

### Streaming replies

An AI assistant typing out its reply — a bot, a desk agent's suggestion, an NPC: the producer opens a
stream, appends pieces as its model produces them, and completes it into one ordinary message. The
platform calls no model; it carries the pieces.

**Sending.** `im.Msg.StreamBeginAsync(new ImBeginStreamRequest(recipient))` answers an
`ImStreamHandle`; then `StreamAppendAsync(streamId, delta)` for each piece, and finally
`StreamCompleteAsync(new ImCompleteStreamRequest(streamId))` (the stored message's `ImSendResult`) or
`StreamAbortAsync(new ImStreamAbortRequest(streamId, reason))`. `ImStreamWriter` holds the stream id and
the `ClientMsgId` for you; the four calls remain the surface.

```csharp
var reply = await ImStreamWriter.BeginAsync(im.Msg, new ImBeginStreamRequest(ImRecipient.User("bob"))
{
    Placeholder = JsonValue.NewObject().Set("name", "Assistant"),
});
try
{
    foreach (var token in tokens) await reply.AppendAsync(token);
    await reply.CompleteAsync();                 // stored as {"text": every piece, joined}
}
catch (Exception)
{
    await reply.AbortAsync("the model failed");  // a terminal frame for everyone; nothing stored
    throw;
}
```

- **Anyone signed in may stream, but only as themselves**, in a single chat (a chat with yourself
  included) or a group of at most 200 — a chat room, system or assistant conversation answers `1008`.
  Every permission `msg.send` checks is checked at `StreamBeginAsync`, not at the end; no app setting
  or add-on gates it. `Recipient` names the conversation, as on `ImSendRequest`.
- **`ClientMsgId` is the finished message's idempotency key** and the server makes none up: a null one
  is generated and written back onto the request. `ContentType` is what the finished message will
  carry (sent as its integer). `Options` is an `ImMessageOptions`, because its keys — and
  `pushConfig`'s, one level further down — are matched case-sensitively and a miscased one is dropped
  without an error; a non-empty `PushConfig.Title` / `Body` is refused (`1103`).
- **A stream dies of silence, not of age**: append or complete within
  `ImStreamHandle.IdleTimeoutSeconds` (30) of the last call, or the server reaps it — a terminal
  frame, no message. Limits: 4096 characters a piece and 16384 in all (`1401`, and the stream stays
  open), 100 pieces a second and 60 openings a minute (`1003`). An empty piece is accepted and ignored.
- **`StreamCompleteAsync` without `Content` stores `{"text": …}` of the pieces; with `Content`, it
  replaces them.** It can be refused as `msg.send` can, and the stream is consumed either way: a
  second complete or abort answers `1002`, as does any call after the stream was reaped. Unlike
  `SendAsync` it moves no cursor — the stored message comes back to the producer on
  `MessageReceived` like everyone else's, and a cursor already at its seq would drop it.

**Receiving.** `im.OnStreamEvent(handler)` decodes `evt.stream` into `ImStreamEvent`s: the opening
(index 0, with the producer's `Placeholder`), pieces (index 1, 2, 3…), and one terminal frame (one past
the last piece) — `Completed` with the stored message's `MessageId` and `Seq`, or `Aborted` with an
`AbortReason` (the producer aborted, went quiet, or its completion was refused). The producer's own
connection receives all of them too. An `ImStreamAssembler` turns them into the `ImStreamState` to draw:

```csharp
var assembler = new ImStreamAssembler();
im.OnStreamEvent(e =>
{
    var s = assembler.Accept(e);
    if (s == null) return;                       // a duplicate, or nothing changed
    switch (s.Status)
    {
        case ImStreamStatus.Streaming: DrawTyping(s.StreamId, s.Placeholder, s.Text); break;
        case ImStreamStatus.Completed: SwapForMessage(s.StreamId, s.MessageId.Value); break;
        case ImStreamStatus.Aborted:   DrawStopped(s.StreamId, s.AbortReason); break;
    }
});
```

- **The pieces are not messages.** No seq, online devices only, never stored, never resent: they never
  reach `MessageReceived`, a cursor or the gap repair, and there is nothing to `Commit`. Pieces are
  joined by index, not arrival; a duplicate is ignored. **A hole is not repaired** — there is no
  offset, resend or catch-up — it is counted (`HasGap`, `MissingFragments`), as is a stream this device
  joined midway (`SawBegin` false). A piece can arrive *after* the terminal frame (pieces are low
  priority, the terminal frame is not, and the server's queue sends normal frames first); the
  assembler remembers finished streams and fills it in rather than reopening one.
- **The completed stream is an ordinary message**: a real seq, the `ClientMsgId` it was opened with,
  delivered on `MessageReceived` through cursors and gap repair like any other — to the producer too.
  That message, not `ImStreamState.Text`, is what to keep: the producer may have replaced the pieces,
  and a piece this device missed is in it. **The terminal frame and the message arrive in either
  order**; match them by `MessageId` (or `ClientMsgId`). A device that was offline simply gets the
  message.
- An aborted stream leaves nothing behind. Streams in flight when the connection drops are settled by
  the stored message or not at all — `assembler.Clear()` on reconnect.

### Scheduled messages

"Send this at 9:00 tomorrow." `im.Msg.ScheduleAsync` queues it and answers an `ImScheduledMessage` — a
schedule id, not a message id; `ScheduledAsync` lists, `CancelScheduledAsync` cancels.

```csharp
var s = await im.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.User("bob"), sendAtUnixMs, "happy birthday"));
// …later, on any device:
var page = await im.Msg.ScheduledAsync();
await im.Msg.CancelScheduledAsync(s.ScheduleId);
```

- **The body is flat and narrower than a send**: the members of `msg.send` beside `SendAt` (unix ms), and
  no `Options` or `SendTime` — the server's `ScheduleRequest` has neither, so `ImScheduleRequest` does
  not offer them. `Recipient` and a non-empty `Content` are required (checked before sending). A null
  `ClientMsgId` is not generated: the server uses `sch-<scheduleId>`.
- **Limits**: `SendAt` at least 10 seconds ahead and at most 90 days (`1001`); 100 pending per user
  (`1006`); 120 created per user per hour (`1003`); the access rules of `msg.send` (not a member,
  blocked…). No app setting or add-on gates it. **`msg.schedule` is not idempotent** — a retry after a
  lost reply makes a second schedule; list before retrying.
- **Firing granularity**: the server's dispatcher runs every 15 seconds (by default), so a schedule goes
  out on the first pass at or after `SendAt` — up to about 15 s late.
- **A schedule is not a message until it fires**: no seq, invisible to the recipient, and nothing is
  pushed when one is created, cancelled or sent — another device sees it only by listing. When it
  fires, every receiver (the sender's other devices too) gets an ordinary `evt.message` with an ordinary
  seq on `MessageReceived`. Scheduling moves no cursor.
- **There is no state field.** `ScheduledAsync` lists pending schedules *and* those settled in about the
  last 48 hours: `MessageId` set means sent (match it against `ImMessage.MessageId`); `Error` equal to
  `ImScheduledMessage.CancelledBySender` ("cancelled by sender") means cancelled — **a cancelled schedule
  stays listed**; any other `Error` means the send failed for good; neither means still waiting.
  `IsPending` / `IsSent` / `IsCancelled` / `IsFailed` spell that out. Cancelling answers `1002` for an
  unknown or someone else's schedule. `1006` means nothing is left to cancel — it is being sent, was
  already cancelled, or was already sent or failed; only the server's message tells which, so branch
  on the code. For one that was sent, the remedy is `msg.recall` on the message it became.

### Conversation folders

A folder holds **tags, not conversations**: filing a conversation is tagging it
(`im.Conv.SettingAsync` with `ImConversationSetting.Tags`), and the client filters `conv.list` with the
folder's `Tags`, `UnreadOnly` and `Types`. So a folder never disagrees with the list, and
`DeleteFolderAsync` removes a name and nothing else — the conversations keep their tags.

```csharp
await im.Conv.SettingAsync(new ImUpdateConversationSettingRequest
{
    ConversationId = convId,
    Setting = new ImConversationSetting { Tags = new List<string> { "work" } },
});
var work = await im.Conv.UpsertFolderAsync(new ImUpsertFolderRequest("Work", "work") { FolderId = "f_work" });
List<ImConversationFolder> folders = await im.Conv.FoldersAsync();   // a plain list, not a page
```

- **`UpsertFolderAsync` replaces the whole folder** (every member is written); no `FolderId` creates one
  with a server-chosen id, which is **not idempotent** — choose the id yourself to make a save safe to
  repeat. `FolderId`: 1–64 letters, digits, `-`, `_`, `.`.
- **Limits** (`1001` unless noted): a non-blank `Name` of at most 64 characters; at most 16 tags of at
  most 64 characters, and **every tag must already be on one of your conversations** — tag first, then
  file; at most 20 folders per user (`1006`). `Types` go out as integers; a folder read back with
  `Types` null shows every kind. Deleting an unknown folder answers `1002`.
- Folder changes are not pushed: other devices call `FoldersAsync` again.

### Translation

`im.Msg.TranslateAsync(new ImTranslateRequest(conversationId, "zh-CN", messageIds))` translates up to
50 messages the caller can already read and answers an `ImTranslationResult`; message ids go out as
strings and come back with every digit.

```csharp
try
{
    var result = await im.Msg.TranslateAsync(new ImTranslateRequest(convId, "zh-CN", "360381357961969667"));
    foreach (var item in result.Items)
        if (item.Error == null) ShowTranslation(item.MessageId, item.Text);
}
catch (ImException e) when (e.Code == ImErrorCode.FeatureNotEnabled || e.Code == ImErrorCode.PlanExpired)
{
    HideTranslateButton(e.Message);             // the ordinary answer on most deployments
}
```

- **Most deployments refuse it, and that is an ordinary answer**: `1204` (`PlanExpired`) when the plan
  lacks the translation add-on (Enterprise and up, or a trial), checked first; `1203`
  (`FeatureNotEnabled`) when the app has translation off or no provider is configured. Both arrive as
  an `ImException` carrying the code and the server's message. Do not cache either — a tenant can turn
  it on at runtime.
- After those: BCP-47 `TargetLanguage` (required) and `SourceLanguage` (optional; null lets the
  provider detect it), 1–50 ids (`1001`), the conversation's access errors, 60 calls a minute per user
  (`1003`). One message that cannot be translated does not fail the call — its `Error` is set and the
  others carry their `Text`; `Cached` says the server answered from its cache.

### Key directory (end-to-end encryption)

The directory where each device publishes its **public** keys and a sender fetches a peer's to open
a session (X3DH-style: identity key, signed prekey, one-time prekeys). `im.Keys` types its seven calls.

**What the SDK does and does not do.** It moves the key material, unchanged. **It performs no
cryptography**: generating key pairs, signing the signed prekey, running the key agreement and
encrypting messages are your crypto library's. Every key and signature is an opaque **standard-base64**
string (not base64url); pass it exactly as your library produced it — the server compares identity
keys by exact string and hashes the strings into the safety number, so a re-encoded key is a different
key. No private key can cross this surface, and the SDK writes no key material to any log (even the
`Verbose` frame trace leaves `keys.*` bodies out).

```csharp
// Once per device, and again whenever you rotate the signed prekey:
await im.Keys.PublishAsync(new ImPublishKeysRequest(
    identity.PublicBase64,
    new ImSignedPreKey("spk-7", spk.PublicBase64, spkSignatureBase64),
    batch.Select(k => new ImOneTimePreKey(k.Id, k.PublicBase64)).ToArray())
{
    Algorithm = "x3dh-ed25519-aes256gcm-v1",   // null keeps the server default, x3dh-curve25519-aes256gcm-v1
});
if (await im.Keys.RemainingAsync() < 20) await im.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(NextBatch()));

// Sending to bob: one ciphertext per device.
foreach (var device in await im.Keys.DevicesAsync(new ImDeviceKeysRequest("bob")))
{
    var bundle = await im.Keys.ClaimAsync("bob", device.DeviceId);   // consumes one of that device's one-time prekeys
    OpenSession(bundle);                                               // bundle.OneTimePreKey may be null
}
var fingerprint = await im.Keys.SafetyNumberAsync("bob");           // 12 groups of 5 digits
```

- **`ClaimAsync` consumes.** Each claim hands out one one-time prekey and deletes it (first in, first
  out), so `RemainingAsync` drops by one. It is **not idempotent: never retry it after a lost reply as
  if it were, and never prefetch.** When the pool is empty the claim still succeeds, with
  `OneTimePreKey` null. Claiming your own device is allowed and drains your own pool.
- **`PublishAsync` replaces and keeps the pool.** Identity key, signed prekey and algorithm are
  replaced; the one-time pool is kept and the new keys appended — unless the identity key changed,
  which deletes the old pool first. The device and platform are the connection's; they are not on the
  request. The signed prekey's `Signature` is the identity key's over the decoded bytes of its
  `PublicKey` only; the server verifies it (`1001` when it does not) and picks the scheme from
  `Algorithm` (`curve25519` / `x25519` / `xed25519`, `ed25519`, `p256`; anything else `1008`). A null
  member of a signed or one-time prekey is refused before sending: inside those nested objects the
  server requires every name, case-sensitively, and a body without one is `1000` for the whole call.
- **`UploadAsync` appends** to the connected device's pool; `1002` before that device has published.
  One-time prekeys with a blank or repeated `KeyId` or a `PublicKey` that is not base64 are dropped
  without an error.
- **`RevokeAsync(deviceId)`** forgets one of your own devices: after it, a claim is `1002`, the device
  is gone from `DevicesAsync`, and both sides' safety numbers change. The id is required (never
  defaulted to this device); **revoking an unknown device succeeds**.
- **The safety number** is the same from either side, 12 groups of 5 digits separated by spaces. It
  changes when a device is added or revoked or an identity key changes, not on signed-prekey rotation
  or one-time-key use. `1002` when either side has nothing published.
- **Limits:** 100 one-time prekeys per call and 100 held per device (the oldest kept); 10 devices per
  user (an eleventh is `1202 QuotaExceeded`); identity keys up to 256 characters; a device's keys
  expire 180 days after its last publish or upload.
- **Callable whether or not the app's `e2ee.enabled` is set.** That switch constrains settings writes
  and translation, not the directory; there is no `1203` / `1204` here.
- **No events.** Nothing is pushed for a revoked device, a changed identity key or a pool running low —
  call `DevicesAsync` and `RemainingAsync` again (on launch, before sending).
- `DevicesAsync` comes back in no particular order; an unknown user is an empty list, and an unknown
  device's `RemainingAsync` is 0. Neither is an error. `RemainingAsync()` and `DevicesAsync()` with no
  request mean this device and yourself.

### Tier T3 — what the signatures do not say

Every T3 method carries its full list of refusals in its doc comment. These are the ones that bite:

- **Message ids leave as strings, and the server insists.** The T3 request bodies declare
  `messageId` as a string server-side, and the socket refuses a JSON number for one with an opaque
  `1000` rather than a `1001` naming the field. Convert an `ImMessage.MessageId` with
  `ToString(CultureInfo.InvariantCulture)`. An id that is not the digits of a positive integer
  throws `ArgumentException` before anything is sent, because `msg.unpin` and `msg.unfavourite`
  answer success for an id the server cannot read.
- **`msg.search` is off unless the tenant turned it on** (`1203`), needs the search add-on (`1204`),
  and is rate limited per user (`1003`, 30 a minute by default) **before** either check — so calls
  against a tenant with search off still spend the budget. Debounce search-as-you-type.
- **`msg.receiptDetail`'s `TotalCount` includes the sender**; `ReadUserIds` never does. Fully read is
  `ReadCount == TotalCount - 1`. The read itself has no size cap: in groups above the tenant's
  receipt limit it is `msg.receipt` that refuses, so nothing is recorded to read.
- **`group.mute` with an `UntilMs` in the past mutes indefinitely**, while `group.muteMember` with one
  in the past unmutes. `Mute` and `conv.markUnread`'s `Unread` both default to `true`, and this
  package always sends them.
- **`group.setRole` accepts `Member` or `Admin` and throws on anything else.** The server refuses
  `Owner` but stores any other integer, and `0` or `4` are privilege bugs rather than roles.
- **`group.handleApplication` throws when `Accept` is left null**: the server reads a missing
  `accept` as a rejection, and a handled application cannot be handled again.
- **`group.applicationList` returns every status**, not only pending — filter on `Status` yourself.
  Called with no request it lists across every group you manage.
- **`friend.setRemark` without `Remark` clears the remark**, while leaving `Tags` null keeps them.

Every endpoint the server publishes today is typed. The escape hatch stays, for an endpoint a newer
server ships before this SDK types it; it shares one code path with the typed surface and is not
going away:

```csharp
// The name is illustrative:
var reply = await im.InvokeAsync("feature.newCall", JsonValue.NewObject()
    .Set("id", id));
```

`InvokeAsync` never touches a cursor: `InvokeAsync("msg.sync", …)` returns messages and moves
nothing. `InvokeListAsync<T>` and `InvokePageAsync<T>` cover the list and page shapes.

## Sending an image

Bytes go straight to object storage and never through the gateway.

```csharp
var ticket = await im.Media.UploadTicketAsync(new ImUploadTicketRequest
{
    FileName = "screenshot.png", ContentType = "image/png", Size = bytes.LongLength,
});

using (var put = UnityWebRequest.Put(ticket.UploadUrl, bytes))
{
    put.SetRequestHeader("Content-Type", "image/png");
    await put.SendWebRequest();
}

await im.Msg.SendAsync(new ImSendRequest
{
    Recipient   = ImRecipient.User("bob"),
    ContentType = ImMessageContentType.Image,
    Content     = JsonValue.NewObject().Set("url", ticket.ObjectKey),
});
```

Note what goes in the message: `ObjectKey`, not a URL. Every reader signs their own short-lived link
with `im.Media.DownloadUrlAsync(objectKey)`, which is the only thing that makes expiry, revocation
and per-reader access control possible at all — a URL baked into a message is public forever the
moment it leaks. Sign it when the image is about to be shown, not when the message arrives; the
default lifetime is an hour.

## Errors

Failures arrive as `ImException` carrying `Code` (see `ImErrorCode`), `Target`, and the `TraceId`
that makes a support ticket answerable in one query instead of a guess.

Branch on `Code`, never on the message text. Two flags are computed from the code alone and are
identical in all five SDKs:

- `IsRetryable` — `1000` InternalError, `1003` RateLimited, `1004` Timeout, `1005`
  ServiceUnavailable. Nothing else. There is no `retryAfter` on the WebSocket path, so apply your own
  full-jitter backoff: base 500 ms, cap 30 s.
- `RequiresReauth` — `1100` Unauthorized, `1101` TokenExpired, `1102` TokenInvalid.

**The SDK never retries a business call for you.** It retries the connection and its own gap repair;
everything else surfaces with these flags and your code decides. An SDK that silently re-sends on
`1003` hides rate limiting from the UI that has to explain it, and one that silently retries a send
turns a visible failure into an invisible delay. The one exception is `1101`: the SDK renews the
token in place with `conn.reauth` on the socket that is already open and retries the failed call
once, which is safe because `ClientMsgId` was generated before the first attempt.

Three codes to handle by name rather than generically: `1202` QuotaExceeded and `1204` PlanExpired
are tenant billing and must never be retried or buried, and `1203` FeatureNotEnabled means the tenant
has a feature switched off — **do not remember it.** A tenant can flip `EnablePresence`,
`EnableTypingIndicator`, `EnableSearch` or `EnableOfflinePush` at runtime, and a client that latches
"typing is off" stays broken until the app restarts.

Requests issued while offline reject immediately with `1005` rather than queueing. A chat client that
queues a send across a five-minute outage delivers it into a conversation that has moved on; your
app knows whether the message is still worth sending and the SDK does not.

## What this SDK does that a hand-rolled client usually does not

**Reconnects without stampeding.** A gateway is stateful, so a rolling update drops every socket on
the node being replaced — and every one of those clients reconnects at the same instant. Delays here
use full jitter (a uniform random draw from `0..ceiling`, ceiling doubling from 500 ms to 30 s)
rather than a fixed backoff, because that is what actually de-synchronises a fleet. A fixed or
lightly-jittered backoff brings the whole node's worth of players back in the same second, at the
service that has just finished starting up. `ImConnection.ReconnectNow()` skips the wait when the
platform tells you something the SDK cannot see — the app returned to the foreground, or
connectivity came back.

**Tells "you were kicked" apart from "the network died".** They look identical at the socket level
and need opposite responses. The server closes with a reason of `im-kick:{Reason}`; the SDK stops
reconnecting for terminal reasons (another device took over, banned, revoked, app disabled, admin
kick) and asks `TokenProvider` for a fresh token when the reason is expiry. Return null from that
provider and it stops — that is how you say "this user is logged out now". A reason this build does
not recognise is reported but *not* treated as terminal, so one new server-side reason cannot strand
every shipped build.

**Repairs gaps in the message stream, on both paths.** Every message carries a gap-free
per-conversation `seq`. When an arriving message skips a number the client pulls the missing range
with `msg.sync` **before** delivering, so the game never sees a conversation jump forward and then
fill in behind it. The same code runs for a gap the server reports on resume. Each conversation has
its own queue, so a slow repair in one chat never holds up another and a message arriving mid-repair
cannot overtake it.

Both loops page, and both had to: `conn.sync` returns at most 200 conversations at a time and
`msg.sync` is clamped to 500 messages, and in both cases `hasMore` is computed before per-user
filtering — so a page can come back short, even empty, with more still to come. Loop on `hasMore`,
never on the item count. Past `MaxAutoRepairSeq` (500 by default) a conversation is skipped forward,
committed, and raised on `ConversationNeedsReload` — reload that one from `im.Msg.HistoryAsync` when
the player opens it.

**Deduplicates sends.** `ClientMsgId` is generated automatically when you do not supply one, so a
retry after a timeout returns the original result with `Deduplicated` set instead of sending twice.

**Notices a half-open socket.** It heartbeats on the interval the *server* reports, and a beat that
does not come back aborts the socket rather than closing it politely. That case — the phone changed
network, a middlebox dropped the flow, and the OS still reports a perfectly healthy connection
because nothing was ever sent to prove otherwise — is invisible to everything else.

## The Unity-specific half

**Every callback lands on the main thread.** `MessageReceived`, `StateChanged`, `Kicked`,
`ConversationNeedsReload`, `CursorStoreFailed`, `On(target, …)` and every `await` of an SDK call
resume on the Unity main thread, so a handler can instantiate a prefab or touch a `Transform`
directly. This is not a convenience: touching a Unity API from a worker thread is undefined
behaviour that usually presents as a hard crash of the player, and the first thing anyone writes in a
message handler is `Instantiate(chatBubble)`. Socket I/O is the only thing that happens off the main
thread. Calling back into the SDK from inside a handler is legal and does not deadlock.

The queue is drained by a hidden `DontDestroyOnLoad` behaviour that creates itself on first use, so
there is nothing to add to a scene. Its clock is a wall clock, not `Time.time` — a pause menu that
sets `timeScale = 0` still has to send heartbeats. A headless build or an edit-mode tool can supply
`ImClientOptions.Dispatcher = new ManualDispatcher()` and pump it itself.

Because completion happens on that loop, **never block on a returned `Task` from the main thread**.
`.Result` or `.Wait()` there deadlocks the pump that would have completed it. `await` is fine; so is
ignoring the task.

Cursor writes are coalesced (`CursorFlushInterval`, 1 s by default) and flushed regardless before
every resume, on `Disconnect`/`Dispose`, and on Unity's own suspend callbacks — a game killed in the
background does not lose what the debounce was holding. Adoption of a conversation seen for the first
time is **never** coalesced, because losing a debounced commit costs one duplicate delivery while
losing an adoption costs silent permanent data loss.

**WebGL is handled explicitly, not silently.** `System.Net.WebSockets.ClientWebSocket` cannot work
in a browser — there is no TCP stack in a tab — and it does not fail loudly either, which is how
WebGL support usually ships broken. This package contains a second transport,
`Runtime/Plugins/WebGL/ImWebSocket.jslib` plus `WebGLWebSocketTransport`, behind the same
`IImTransport` interface; `ImTransports.CreateDefault()` picks it at compile time. Two browser
constraints leak through and cannot be hidden:

- the handshake carries no custom headers, which is why this protocol authenticates with query
  parameters;
- a page served over HTTPS may only open `wss://`, and a `ws://` endpoint is blocked by the browser
  before any of this code runs.

There is also no background execution in a hidden tab: a WebGL client goes away when the page is
hidden and comes back through the normal reconnect-and-resume path.

**No third-party dependencies, and no NuGet.** The wire format needs free-form `content` objects,
maps keyed by conversation id, and members that are absent rather than defaulted — none of which
`JsonUtility` can express, and all of which Newtonsoft would cost a package dependency and a slab of
IL2CPP reflection to buy. So `Runtime/Json` is a hand-written parser and writer: integers stay
`long` (a snowflake `messageId` past 2^53 silently rounds as a `double`, and two different messages
start comparing equal), numbers are read and written with `InvariantCulture` (a device whose locale
uses a decimal comma would otherwise emit `1,5` and have every frame rejected), and member lookup is
case-insensitive so a serialiser policy change on the server cannot break shipped clients. Nothing
in the runtime uses reflection — including `InvokeAsync<T>`, where every payload maps itself — so
managed stripping at any level is safe.

The two entries in `dependencies` are Unity's own built-in modules: `unitywebrequest` for the sample's
token fetch, and `test-framework` for the tests below. The runtime itself needs neither.

## API at a glance

| Member | Purpose |
|---|---|
| `ConnectAsync()` / `Disconnect()` / `LogoutAsync()` | Open, close, sign out (unregisters push first) |
| `Commit(id, seq)` / `FlushCursors()` | Say a message is stored; force the store write |
| `DeliveredSeqOf(id)` / `CommittedSeqOf(id)` | The two cursors |
| `MessageReceived` | Every message, in seq order, gaps repaired |
| `ConversationNeedsReload` | This conversation was skipped forward; reload it from history |
| `CursorStoreFailed` | Cursors unreadable; re-derive them with `Commit` |
| `StateChanged` | `Idle` \| `Connecting` \| `Open` \| `Reconnecting` \| `Closed` |
| `Kicked` | Kicked off, with whether it is terminal |
| `On(target, fn)` | Any other server event (`evt.typing`, `evt.read`, `evt.group`, …) |
| `OnDeskEvent(fn)` / `OnRoomEvent(fn)` | `evt.desk`, and the `room.*` events inside `evt.system`, decoded |
| `OnStreamEvent(fn)` | `evt.stream` — streaming-reply pieces, decoded; feed them to an `ImStreamAssembler` |
| `Conn` `Msg` `Conv` `User` `Friend` `Group` `Media` `Push` | The typed surface |
| `InvokeAsync<T>(target, body)` | Any endpoint not yet typed |
| `Connection` | The socket underneath: `ReconnectNow()`, `SetToken()`, `ReauthAsync()`, raw frames |
| `ImSdk.ContractVersion` | Which contract this build implements. Quote it in a ticket |

## Tests

`Tests/Runtime` runs under the Unity Test Framework in both Edit Mode and Play Mode
(**Window → General → Test Runner**), which means it needs a Unity licence to execute and is
therefore not wired into CI. They use a hand-driven clock and a fake socket, so there is no sleeping
and no real network: the full-jitter distribution is asserted decile by decile (a ±10% jitter fails
it), every terminal and recoverable kick reason is checked against what the connection then does,
every typed method is asserted against the endpoint name it must put on the wire, and the cursor
suite asserts the cold-start, paging and adoption rules that the rest of this README describes —
including a test that fails if a restored cursor is not reported. The T3 tests also pin the JSON
*kind* of every request member, because a member of the wrong kind is what the server's socket
binder turns into an unexplained `1000`, and one of them drives all twenty T3 methods and compares
the targets that reach the wire with the T3 list in `endpoint-inventory.json`, so "T3 is complete"
is something the suite can fail on.

## Notes

- **Never put an AppSecret in a client build.** It signs tokens and belongs on your server; anything
  shipped inside a game is extracted within a day of release. The client only ever holds a
  short-lived user token minted by your backend, and never calls the `/v1` REST API — that is your
  backend's, and it authenticates with server credentials.
- `DeviceId` must be stable for an installation. The multi-device policy uses it to tell a reconnect
  apart from a second device, and a random value per launch makes players kick themselves offline.
  `ImDevice.GetOrCreateDeviceId()` stores one in `PlayerPrefs`.
- Set `UserId`. It is not sent in the handshake — the gateway reads the identity out of the token —
  but the cursor store is keyed on `(host, appId, userId)`, and without it two accounts on a shared
  handset read each other's positions.
- Order messages by `seq`, never by timestamp. Client clocks are wrong and arrival order is not send
  order.
- Call `ImConnection.ReconnectNow()` from `OnApplicationPause(false)`. The socket usually died while
  the app was suspended and the OS will not say so.
- `ImLog.Level` defaults to `Warning`; `ImLog.Sink` routes SDK diagnostics into your own logger.
- This package builds under Unity, not under the .NET SDK, and is deliberately absent from
  `IM.slnx`.

## Licence

Apache-2.0. See [`LICENSE.md`](LICENSE.md).
