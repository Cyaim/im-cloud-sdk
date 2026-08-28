# com.cyaim.im

Unity client for Cyaim IM Cloud. Unity 2022 LTS and newer, every build target including WebGL.

Install through the Package Manager: **Add package from git URL** with
`https://github.com/Cyaim/IM.git?path=/sdk/unity#v0.9.0`, **Add package from disk** pointing at this
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
> Use **Add package from disk**, pointing at `sdk/unity/package.json` in a clone of this
> repository, or copy the folder into your project's `Packages/com.cyaim.im`.
>
> The git-URL form is the one that does not work yet, and it fails for a reason worth knowing:
> UPM resolves the `#v0.9.0` fragment as a **git ref**, and there are no tags. Drop the fragment
> and UPM takes the default branch, which is a moving target and not something to ship against.
>
> The registry prerequisites still outstanding are listed in
> [`sdk/CONTRACT.md` §9.4](../CONTRACT.md).

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

## The typed surface

107 flat methods on one object is not an API, it is a scroll bar. The surface is grouped into
namespaces named exactly for the endpoint prefix, and every method is named for the method half of
its target — so if you know the endpoint you know the call, in this SDK and in the other four.

| | endpoints |
|---|---|
| `im.Conn` | `HeartbeatAsync` `ReauthAsync` `SyncAsync` |
| `im.Msg` | `SendAsync` `SyncAsync` `HistoryAsync` `RecallAsync` `DeleteAsync` `TypingAsync` `EditAsync` `ForwardAsync` `ReactAsync` `ReceiptAsync` |
| `im.Conv` | `ListAsync` `GetAsync` `ReadAsync` `UnreadTotalAsync` `SettingAsync` `DeleteAsync` `ClearAsync` |
| `im.User` | `MeAsync` `ProfileAsync` `BatchProfileAsync` `UpdateProfileAsync` `PresenceAsync` `SubscribePresenceAsync` `UnsubscribePresenceAsync` |
| `im.Friend` | `ListAsync` `AddAsync` `HandleRequestAsync` `RequestListAsync` `DeleteAsync` `BlockListAsync` `BlockAsync` `UnblockAsync` |
| `im.Group` | `CreateAsync` `InfoAsync` `UpdateAsync` `DismissAsync` `MemberListAsync` `JoinedAsync` `InviteAsync` `KickAsync` `QuitAsync` `JoinAsync` |
| `im.Media` | `UploadTicketAsync` `DownloadUrlAsync` |
| `im.Push` | `SetToken` `RegisterAsync` `UnregisterAsync` |

That is tiers **T0**, **T1** and **T2** of `sdk/CONTRACT.md` — 49 of the server's 107 endpoints: the
session floor, everything a two-person chat app needs to launch, and the contacts, blocking, groups
and presence that turn it into a messenger.

Every method takes exactly one request object, because with positional parameters the server adding
one optional field is a source-breaking change in five languages at once. Convenience overloads
exist where a request has at most two required scalars — `im.Conv.ReadAsync(id, seq)` is fine.

Everything else — group administration, pins, favourites, search, calls, E2EE, live rooms, the
service desk, AI streaming, scheduling, conversation folders — is reachable today through the escape
hatch, which shares one code path with the typed surface and is not going away:

```csharp
// group.transfer is tier 3 and not typed yet
var group = await im.InvokeAsync<ImGroup>("group.transfer", JsonValue.NewObject()
    .Set("groupId", groupId)
    .Set("newOwnerId", userId));
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
including a test that fails if a restored cursor is not reported.

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
