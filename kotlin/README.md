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
> cd sdk/kotlin && ./gradlew publishToMavenLocal
> ```
> ```kotlin
> repositories { mavenLocal() }
> dependencies { implementation("com.cyaim.im:im-client:0.9.0") }
> ```
>
> Maven Central is the one with real lead time (namespace verification, GPG key, POM fields,
> a javadoc jar) — none of it is done. Start it before you need it.
>
> The registry prerequisites still outstanding are listed in
> [`sdk/CONTRACT.md` §9.4](../CONTRACT.md).

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

49 endpoints — contract tiers T0, T1 and T2 — grouped into namespaces named for the target prefix,
so a reader who knows the endpoint name knows the call without a lookup table. `msg.recall` is
`im.msg.recall`; there are no synonyms.

| Namespace | Endpoints |
|---|---|
| `im.conn` | `heartbeat` `reauth` `sync` |
| `im.msg` | `send` `sync` `history` `recall` `edit` `delete` `forward` `react` `receipt` `typing` |
| `im.conv` | `list` `get` `read` `setting` `delete` `clear` `unreadTotal` |
| `im.user` | `me` `profile` `batchProfile` `updateProfile` `presence` `subscribePresence` `unsubscribePresence` |
| `im.friend` | `list` `add` `handleRequest` `requestList` `delete` `block` `unblock` `blockList` |
| `im.group` | `create` `info` `update` `dismiss` `memberList` `joined` `invite` `kick` `quit` `join` |
| `im.media` | `uploadTicket` `downloadUrl` |
| `im.push` | `register` `unregister` |

Every method takes exactly one request object, named for the server DTO. That is not a style
preference: with positional parameters, the server adding one optional field is a source-breaking
change in five languages at once. Kotlin's default arguments give the ergonomics back, and a few
one- and two-field calls have positional overloads (`im.conv.read(id, seq)`).

Returns are the `data` payload, unwrapped — never an envelope. A non-zero code throws. List
endpoints return `Page<T>`, which keeps `nextCursor`/`hasMore`/`total`: **page on `hasMore`, never
on `items.size`**, because the server computes its cursor before filtering rows you cannot see.

### Anything not yet typed

Tiers T3 and T4 — group administration, pins, favourites, search, calls, E2EE, chat rooms, service
desk, streaming — go through the escape hatch, which shares one code path with the typed methods:

```kotlin
im.invoke<Unit>("group.setRole", buildJsonObject {
    put("groupId", groupId)
    put("userId", userId)
    put("role", GroupRole.Admin.code)
})
```

`invoke` never touches a cursor: `invoke("msg.sync", …)` returns messages and moves nothing.

## Coroutines and Flow

Events are flows, calls are `suspend` functions, and everything is structured.

| | |
|---|---|
| `messages: SharedFlow<ImMessage>` | Every message, in `seq` order per conversation, gaps repaired |
| `state: StateFlow<ConnectionState>` | `Idle` \| `Connecting` \| `Open` \| `Reconnecting` \| `Closed` |
| `kicks: Flow<KickEvent>` | Why the session ended, from the push or the close reason |
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
They are reachable now, and the wiring is four lines in *your* app.

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

If a client dies without unregistering — force quit, crash, uninstall — only your backend can clean
up: `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Ship that call, or ship the bug.

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
> **本机跑通的 88 条就是用上面这条命令跑出来的。** 不带那两个参数，`./gradlew test` 会执行
> **零个测试**并打印 `BUILD SUCCESSFUL`；连"数 XML 报告里的用例数"这个断言也拦不住它，
> 因为构建缓存会把 `test-results/` 一起恢复——那份报告证明的是"某一次成功过"，不是"这一次"。

The tests never open a socket. `ImSocketFactory` is the seam, `ImCursorStore` is the other one, and
every timing rule in here — the backoff window, the thirty-second heartbeat, the fifteen-second
request timeout, the cursor debounce — is asserted on `kotlinx-coroutines-test`'s virtual clock, so
the whole suite runs in under a second and none of it is flaky.
