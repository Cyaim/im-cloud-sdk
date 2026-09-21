# Changelog

All notable changes to `com.cyaim.im` are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): the wire protocol version is separate
and is negotiated with `v=1` in the handshake. The version number is in lockstep across all five
Cyaim client SDKs, so "we're on 0.9.0" answers "which endpoints do you have" without anyone having
to ask which platform.

## [Unreleased]

### Changed on the server (2026-09-21)

- `moderation.report` `messageId` and `msg.translate` `messageIds` are strings on the server now
  (they were `long` / `List<long>`, which refused the quoted ids SDKs send). The typed calls send
  strings; a raw `invoke` that sends either as a JSON number is now refused with `status 1` /
  `code 1000`. On `moderation.report`, absent, blank or `"0"` reports the account and any other
  unreadable id is refused with 1001.
- Nested request objects (`options`, `pushConfig`, `setting`, group updates) bind as the SDKs send
  them since the same day; until then every nested option was dropped. Two of them are authority,
  decided by the credential: from a client, a `msg.send` whose `options.pushConfig` has a non-empty
  `title` or `body` is refused with 1103, and so is an image, voice, video or file message with
  `persistent: false` or `onlineOnly: true` while the app moderates content. See CONTRACT.md §2.

### Fixed

- **This assembly did not compile.** Two deprecated overloads on `ImClient` — `RecallAsync` and
  `ReactAsync` — assigned a `long` to `MessageId`, which is a `string` on both request types. A
  plain type error on a published API surface, unnoticed because Unity is the one client SDK with no
  build in CI: there is no Unity licence on the runners and no headless compiler in the box, so a
  whole assembly sat broken for as long as nobody opened it in an editor. Fixed, and
  `IM.Tests.UnitySdkCompile` now compiles `Runtime/` against a hand-written UnityEngine shim as part
  of the server solution, so it cannot happen again.
- **Every send that quoted a message failed.** `ImSendRequest.QuoteMessageId` went on the wire as
  a JSON number, while the server declares `quoteMessageId` a `string?` and the gateway's socket
  binder refuses a number for a string member: the call answered `1000 InternalError` before the
  endpoint ran. It is now written as the decimal string of the id; the property stays a `long?`,
  so an `ImMessage.MessageId` still goes in unconverted. The suite's request assertions now read
  through kind-strict helpers (`WireString` / `WireLong` / `WireInt` / `WireBool` /
  `WireStrings`), because `JsonValue.AsString()` returns the same digits for `7` and `"7"` — which
  is how the existing tests could not have seen this. All 73 typed endpoints' request members were
  audited against the server's C# types; this was the only one of the wrong kind.

### Added

- **Tier T3 typed — all twenty endpoints.** `im.Msg.PinAsync` / `UnpinAsync` / `PinsAsync` /
  `FavouriteAsync` / `UnfavouriteAsync` / `FavouritesAsync` / `BurnAsync` / `SearchAsync` /
  `ReceiptDetailAsync`, `im.Conv.MarkUnreadAsync`, `im.User.SetStatusAsync`,
  `im.Friend.SetRemarkAsync`, and `im.Group.TransferAsync` / `ApplicationListAsync` /
  `HandleApplicationAsync` / `SetRoleAsync` / `MuteAsync` / `MuteMemberAsync` /
  `SetNicknameAsync` / `AnnouncementAsync`. With T0–T2 that is 73 of the server's 107 endpoints;
  the 34 of T4 stay on `InvokeAsync`. New request types carry the server DTO names
  (`ImConversationMessageRequest`, `ImPageRequest`, `ImSearchMessagesRequest`,
  `ImReceiptDetailRequest`, `ImMarkUnreadRequest`, `ImSetStatusRequest`, `ImSetRemarkRequest`,
  `ImTransferOwnerRequest`, `ImHandleApplicationRequest`, `ImSetRoleRequest`,
  `ImMuteGroupRequest`, `ImMuteMemberRequest`, `ImSetGroupNicknameRequest`,
  `ImAnnouncementRequest`), and three new payloads decode the answers (`ImPinnedMessage`,
  `ImMessageReceipt`, `ImGroupApplication`). Three places refuse input before it is sent, because
  the server would accept it and do the wrong thing: a message id that is not the digits of a
  positive integer (`msg.unpin` and `msg.unfavourite` answer success for one), a
  `HandleApplicationAsync` with `Accept` left null (the server reads that as a rejection, and it
  cannot be undone), and a `SetRoleAsync` with any role but `Member` or `Admin` (the server stores
  any other integer, and `0` or `4` are privilege bugs). A `SearchAsync` with a blank keyword
  throws too: the server refuses it, but only after its rate limiter has charged the call to the
  user's per-minute search budget. Message ids leave as strings, which the
  server's socket binder requires for these endpoints; the ids in the answers are read back into
  `long` without passing through a double, like every other message id in this SDK.
- **`LogStore` and the device log (ADR-003).** `im.Diag`, an `IImLogStore` option with
  `ImLogStore.InMemory()` as its default and `ImLogStore.File(path)` for when the studio has decided
  where its players' runtime detail may be written. `im.Log` takes the game's own lines. Every
  answer carries `CoveredFromMs` and `Volatile` so a support engineer knows whether they are reading
  three minutes or three weeks.
- **`im.Moderation.ReportAsync`** — `moderation.report`, the half of app-store review that
  `im.Friend.BlockAsync` does not cover. Reviewers treat blocking an abusive user and reporting
  objectionable content as two separate mandatory items, so a game that shipped only the first
  failed the same submission twice. There is no member for the reporter and there must not be: the
  reporter is the socket, which is what makes a report unforgeable. The answer is a receipt rather
  than the stored row — who handled it and what they decided belong to the tenant's console.
- **`im.Push.ClickedAsync`** — `push.clicked`, the tap that closes the delivery funnel. APNs and
  FCM report no delivery at all, so on most deployments the tap is the only evidence a notification
  ever arrived. It is best-effort statistics: a failure is logged rather than raised and is never
  retried, because the call site is a tap handler where nothing awaits the returned task, and
  throwing there would turn a missing metric into an unobserved exception in a player build.
- **`ImErrorCode.PushDeliveryNotFound`** (`2401`) — the delivery row aged out after seven days, or
  the notification did not come from this platform. Named so it can be recognised in a log rather
  than looked up.

## [0.9.0] — 2026-08-22

The first release intended for publication. It is `0.9.0` and not `1.0.0` on purpose: `1.0.0` is
reserved for tiers T0 and T1 complete on **all five** SDKs, and the number a customer reads has to
be a promise the whole product keeps rather than one this platform keeps alone. The `1.0.0` in
earlier manifests was never published.

### Fixed

- **Cold start no longer loses every message that arrived while the app was closed.** This is the
  headline of the release and it was a silent, unlogged, unrecoverable data loss. The client kept
  its per-conversation position in memory only; on the next launch it reported nothing in
  `conn.sync`'s `convSeqs`, the server can only compute a gap for a conversation the client told it
  about, so it reported none — and the client then took the server's `maxSeq` as its own position.
  Everything in between was behind the cursor, never requested, and never delivered. See
  `sdk/CONTRACT.md` §5 and the `CursorStoreTests` suite.
- **`conn.sync` now pages.** It returns at most 200 conversations at a time; a user with more than
  that previously had gaps repaired only for the first page.
- **`conversationCursor` now advances only when a resume run completes.** The list is sorted by
  `updatedAt` descending, so taking page one's maximum and stopping pushed the cursor past every
  conversation on the pages that were never read — and the server filters on `updatedAt > cursor`,
  so it would never offer them again.
- **`msg.sync` repair now pages.** The server clamps a sync to 500 messages and reports `hasMore`;
  a 900-seq range asked for in one call silently returned 500 and left the rest as a permanent hole.
  The loop ends on `hasMore` and never on the message count, because `hasMore` is computed on the
  raw window before rows hidden from this user are filtered out.
- **An oversized *live* gap now raises `ConversationNeedsReload`.** It used to be accepted silently:
  the cursor stayed honest, but nothing ever told the application that a stretch of the conversation
  had been skipped, so nothing ever reloaded it.
- **A socket that drops with requests in flight now fails them `1004 Timeout`, not `1005
  ServiceUnavailable`.** 1005 claims the call was never delivered and the SDK does not know that —
  the request may well have executed. 1004 is the honest answer and the one that points a caller at
  `ClientMsgId` idempotency instead of a blind resend.
- **A reply with transport `status: 2` now maps to `1008 UnsupportedOperation`, not
  `1000 InternalError`.** "This deployment does not have this endpoint" is the exact signal an SDK
  newer than a private-deployment server produces, and it is not an internal error.

### Added

- **`ImClientOptions.CursorStore`, and it is required.** `ImCursorStore.PersistentDataPath()` for a
  game, `ImCursorStore.File(path)` for a headless build, `ImCursorStore.PlayerPrefs()` where file IO
  is not dependable, and `ImCursorStore.InMemory()` as an explicit opt-out that logs one line saying
  what it costs. There is no default: defaulting to no persistence is what produced the bug above,
  and defaulting to *some* persistence would mean guessing where a game may write.
- **`ImClient.Commit(conversationId, seq)`** — the application tells the SDK when a message is
  durably stored, and that is the number reported to the server. Delivery is therefore at-least-once;
  be idempotent on `ImMessage.MessageId`. `DeliveredSeqOf` and `CommittedSeqOf` expose both cursors.
- **`ImClient.CursorStoreFailed`** — an unreadable cursor store surfaces instead of being mistaken
  for a fresh install. The SDK then adopts nothing and writes nothing for the session; the recovery
  path is to re-derive cursors from your own store with `Commit`, which is monotonic for exactly
  this reason.
- **Push registration: `im.Push`.** `SetToken(provider, token)` caches the vendor token and
  registers it on every connect — not once at install, because the vendor may replace it while the
  process is frozen. `ImClient.LogoutAsync()` unregisters **before** closing the socket, which is the
  only order that works: afterwards there is no authenticated channel and only the tenant backend
  can remove the token, with `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
- **A typed surface for tiers T0, T1 and T2 — 49 endpoints** — grouped into namespaces named for the
  target prefix: `im.Conn`, `im.Msg`, `im.Conv`, `im.User`, `im.Friend`, `im.Group`, `im.Media`,
  `im.Push`. Each method is named for the method half of its target, so a reader who knows
  `group.memberList` knows to write `im.Group.MemberListAsync` without a lookup table.
- **`conn.reauth`, and the SDK uses it.** A request that comes back `1101 TokenExpired` now renews
  the token on the socket that is already open and retries the call once, instead of costing a full
  reconnect on the flaky network where tokens tend to expire.
- **`InvokeAsync<T>`**, plus `InvokeListAsync<T>` and `InvokePageAsync<T>`, so the escape hatch is as
  typed as the rest of the surface. No reflection: every payload maps itself, which is what keeps
  managed stripping safe in an IL2CPP build.
- **`ImException.IsRetryable` and `ImException.RequiresReauth`**, computed from the code alone and
  identical across all five SDKs.
- **`ImConnection.ReauthAsync(token)`** and **`ImConnection.PendingRequests`**.
- **`ImClient.FlushCursors()`**, and an automatic flush on Unity's suspend callbacks
  (`ImMainThreadDispatcher.ApplicationSuspending`), so a game killed in the background does not lose
  what the commit debounce was still holding.
- **`ImConnectionOptions.UserId`** — not sent in the handshake, but the SDK keys its cursor store on
  `(host, appId, userId)`, which is what stops two accounts on a shared handset reading each other's
  positions.
- New payload types: `ImUserProfile`, `ImPresenceState`, `ImMediaUploadTicket`, `ImGroup`,
  `ImGroupMember`, `ImFriend`, `ImFriendRequest`, `ImBlockEntry`, `ImHeartbeatResult`,
  `ImSyncResult`, `ImResumeResult`; and the enums `ImGroupType`, `ImGroupRole`, `ImGroupJoinMode`,
  `ImGroupInviteMode`, `ImMuteMode`, `ImApplicationStatus`, `ImMessageStatus`, `ImMessagePriority`.
- `LICENSE.md` (Apache-2.0) and the `documentationUrl` / `changelogUrl` / `licensesUrl` entries UPM
  shows in the Package Manager window.

### Changed

- **`convSeqs` now reports the committed cursor, not the delivered one.** `docs/SPEC-02-protocol.md`
  §3.3 always said so. An application that never calls `Commit` will have messages redelivered after
  every reconnect — which is loud, correct, and much better than the alternative.
- On every connect, `deliveredSeq` is reset to `committedSeq` before `conn.sync` goes out. Without
  that reset the repaired messages are dropped as duplicates by the very cursor that was too far
  ahead, and the repair achieves nothing.
- `ImConversationView.UnreadCount` is `long` (the server's type), `Muted` is `ImMuteMode` rather than
  `int`, and the view gained `ManuallyUnread`, `Peer`, `Group` and `Extensions`.
- `ImPage<T>` gained `Total`, which is `null` — not `0` — when the store cannot count cheaply.
- `ImMessage` gained `Status`, `ThreadRootId` and `ExpireAt`.
- License changed from MIT to **Apache-2.0**, for its express patent grant and to match the
  Apache-2.0 transport library the server already depends on.

### Deprecated

The nine flat convenience methods stay, delegate to the namespaced surface, and are marked for
removal in 2.0: `SendAsync`, `SendTextAsync`, `HistoryAsync`, `RecallAsync`, `ReactAsync`,
`SetTypingAsync`, `ConversationsAsync`, `MarkReadAsync`, `TotalUnreadAsync`. Four of them had already
drifted from their endpoint names, which is the drift the naming rule stops.
`ImClient.CursorOf` is now `DeliveredSeqOf`; `ImClient.ConversationStale` is now
`ConversationNeedsReload`. Both old names still work and still fire.

### Known limitations

- Tiers T3 and T4 — group administration, pins, favourites, search, calls, E2EE keys, live rooms,
  the service desk, AI streaming, scheduling and conversation folders — are not typed. Reach them
  with `InvokeAsync`; the README carries a worked example.
- The test suite runs under the Unity Test Framework and needs a Unity licence to execute. It was
  developed and run against a compile-equivalent .NET host, which the repository does not carry.

## [1.0.0] — 2026-08-20 (never published)

First working client. `ImClient`, `ImConnection`, full-jitter reconnect, kick handling, main-thread
marshalling, the WebGL transport, the dependency-free JSON layer, and per-conversation gap repair
on a live socket. Superseded by 0.9.0, which renumbers honestly and fixes the cold-start hole in the
gap repair.
