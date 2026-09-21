# Changelog

All notable changes to `@cyaim/im-client`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version number
is [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) **in lockstep with the other
four client SDKs** — one number across TypeScript, Kotlin, Swift, Dart and Unity, bumped together
even when only one platform changed. A version number therefore identifies a *contract*, so "we're
on 0.9.0" answers "which endpoints do you have" without anyone having to ask which platform.

## [0.9.0] — unreleased

First published release. The version is deliberately **below 1.0**: the previous `1.0.0` in the
manifest was never published and was a promise the SDK did not keep, with tier T1 at 8 of 18
endpoints. `1.0.0` is reserved for T0 + T1 complete on all five SDKs.

Implements [`sdk/CONTRACT.md`](../CONTRACT.md) contract version `1.0`.

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

- **Cold-start data loss (CONTRACT §5.1).** Every message that arrived while the application was
  not running was silently discarded. The client kept one private map of "highest seq seen", with
  no accessor and no persistence; on a cold start that map was empty, so `conn.sync` was told
  nothing, so the server reported no gap — it only reports one for a conversation the client claims
  a position in — and the client then adopted the server's `maxSeq` on its own first-sight branch.
  No error, no log line, no later event that corrected it.
- **`conn.sync` stopped after one page (§5.6).** A user with more than 200 conversations got gaps
  reported only for the first page; the rest were never repaired.
- **`conversationCursor` advanced from page 1 (§5.6).** The list is sorted by `updatedAt`
  descending, so page 1 holds the newest timestamp. Advancing from it pushed the cursor past every
  conversation on later pages, which the server then filtered out permanently.
- **`msg.sync` repair ignored `hasMore` (§5.9).** The server clamps `limit` to 500, so a repair
  wider than that silently returned 500 messages and left the remainder as a permanent hole.
- **An oversized live gap was accepted in silence (§5.10).** The cursor stayed honest, but nothing
  ever told the application that a stretch of conversation had been skipped, so nothing reloaded it.
- **A dropped socket failed in-flight requests `1005 ServiceUnavailable` (§7.2).** 1005 claims the
  call was never delivered, which the SDK cannot know. Both close paths now fail `1004 Timeout`.
- **`status: 2` mapped to the caller's `body.code`.** It now maps to `1008 UnsupportedOperation`,
  which says "this deployment does not have this endpoint" rather than "your object does not exist".
- **64-bit values sent as JSON strings.** `NumberHandling.AllowReadingFromString` is set
  server-side, so `seq` can legitimately arrive as `"1234"`. Comparisons coerced and hid it;
  `seq + 1` did not, and produced a repair request for a range that does not exist.
- **`GroupCursorRequest.limit` was documented as "1…100".** The server keeps 1–200 and turns
  anything else — absent, 0, or over 200 — into 50, for `group.memberList` and
  `group.applicationList` alike.

### Added

- **Tier T3 typed whole — all twenty endpoints.** `im.msg.pin` `unpin` `pins` `favourite`
  `unfavourite` `favourites` `burn` `search` `receiptDetail`, `im.conv.markUnread`,
  `im.user.setStatus`, `im.friend.setRemark`, and `im.group.transfer` `applicationList`
  `handleApplication` `setRole` `mute` `muteMember` `setNickname` `announcement`, with their request
  and payload types (`ConversationMessageRequest`, `PageRequest`, `SearchMessagesRequest`,
  `ReceiptDetailRequest`, `MessageReceipt`, `PinnedMessage`, `GroupApplication`, and one request type
  per group verb). The typed surface is now 82 of 107 endpoints; the rest of T4 stays behind
  `invoke()`.
  - **Message ids are strings on both sides, and on these endpoints the server requires it:** the
    request DTOs declare `messageId` as a C# `string`, and the socket binder answers a JSON number
    with `1000`. The responses (`MessageReceipt`, `PinnedMessage`, `MessageBrief`, `ImMessage`) write
    theirs with `WriteAsString`, whatever the inventory's `payloadTypes` says.
  - **`SetRoleRequest.role` is `Member | Admin` by type.** The server refuses `Owner` (`1008`) but
    stores any other integer, and `0` escapes a group-wide mute while `4` outranks every admin.
  - `HandleApplicationRequest.accept` is required although the server defaults it: absent means
    *reject*, which should never be what leaving a field out does.
  - Doc comments carry what the signatures cannot: `msg.search` off by default (`1203`), gated by the
    plan (`1204`) and rate limited (`1003`) **before** either gate; `msg.receiptDetail`'s
    `totalCount` including the sender and the read having no size cap (the limit is on
    `msg.receipt`); `group.mute` reading a past `untilMs` as *indefinite* while `group.muteMember`
    reads it as *unmute*; `group.applicationList` returning every status, not only pending;
    `friend.setRemark` clearing an omitted remark but keeping omitted tags.
  - `test/t3.test.ts` pins every T3 request body on the wire — keys, values and JSON kind — and
    every payload decode; `coverage.test.ts` now commits to T3 whole.
- **The customer-service desk, typed (`im.desk`, tier T4).** All nine verbs — `request` `accept`
  `transfer` `close` `status` `queue` `rate` `canned` `suggest` — with `DeskSession` carrying every
  field the server returns today, `DeskSessionState` including `Bot`, the string-valued
  `DeskEndReason`, and the payload types for the end-of-session drawer, the rating survey, canned
  replies and knowledge-base articles. T4's rule is "correctly typed when a customer asks"; the
  customer asked, and it is typed whole rather than in halves.
  - `transfer` takes a **union**: exactly one of `toAgentId`, `toSkill` or `toQueue`, so naming two
    is a compile error rather than a `1001` in front of a customer halfway through a handover.
  - `readDeskNotification(message)` reads the 1801–1807 notices, which arrive as ordinary messages
    on the customer's transcript and therefore land in `onMessage` alongside chat. It checks the
    content type and the band together — the same seven numbers are account error codes elsewhere
    on this platform, and a reader keyed on the number alone eventually draws "your account is
    locked" onto a support transcript.
  - `im.onDeskEvent(fn)` decodes `evt.desk` into a union split on `event`: `session` is null on a
    forced release and absent altogether on the agent-level `takeover` frame. The thirteen `change`
    values are a **closed** union — the one closed union in the package — so a workbench can write a
    switch the compiler proves it has finished; `knownDeskChange()` is the narrowing seam, and the
    frame's own field stays open so a value a newer server adds still arrives. The closed list is
    held to `endpoint-inventory.json`'s new `deskChanges` block, which the generator fills from the
    server, so a fourteenth value cannot leave the union silently one short.
  - **`desk.canned`'s `ownerMemberId` is a filter, not a guard.** The server does not narrow it to
    the caller on this surface: absent returns every member's `personal` replies and another
    member's id returns theirs. Pass your own member id for the usual "shared, plus mine". Documented
    rather than worked around, because the SDK inventing a default here would hide a server-side
    question that is still open.
  - Desk error codes `2500`–`2511` are named on `ImErrorCode`. None of them can come back from a
    `desk.*` socket call — they belong to the console, widget and admin surfaces around it — but a
    number with no name is a number nobody can grep.
- **`logStore` and the device log (ADR-003).** `im.diag`, an `ImLogStore` option with
  `inMemoryLogStore()` as its default, and `im.log` for an application's own lines. The console can
  ask a running device for the SDK's runtime log; the client answers once per connect and on an
  `evt.system` frame. **The store belongs to you, and not supplying one is a complete choice** — the
  in-memory ring covers this process only, and every answer carries `coveredFromMs` and `volatile`
  so a support engineer knows whether they are reading three minutes or three weeks.
- `ImCursorStore` and the two-cursor model — `deliveredSeq` in memory, `committedSeq` durable —
  with `ImCursorStore.inMemory()`, `.localStorage(keyPrefix)` and `.file(path)`, plus
  `im.commit(conversationId, seq)`, `im.deliveredSeq()`, `im.committedSeq()`, `im.cursorSnapshot()`
  and `im.flushCursors()`.
- `im.onConversationNeedsReload(fn)` — a conversation the SDK declined to backfill because the span
  exceeded `maxAutoRepairSeq`.
- `im.onError(fn)` — SDK-level failures with no caller to reject: cursor store read/write failures,
  an interrupted resume run.
- **Push registration**, which no client SDK had reached at all: `im.push.register`,
  `im.push.unregister`, `im.push.setToken(provider, token)` with automatic re-registration on every
  connect, and `im.logout()`, which unregisters *before* closing the socket.
- **`conn.reauth`** — a token expiring mid-session is now one round trip on the open socket rather
  than a full reconnect. Driven automatically when a request answers `1101`.
- **Namespaced typed surface** for tiers T0, T1 and T2: `im.conn`, `im.msg`, `im.conv`, `im.user`,
  `im.friend`, `im.group`, `im.media`, `im.push`, `im.moderation` — 51 endpoints, up from 11.
- **`im.moderation.report`** — the other half of `im.friend.block`. App-store review requires both a
  way to block an abusive user and a way to report objectionable content, so an app shipping one
  without the other fails the same submission. The reporter is the socket and never an argument.
- **`im.push.clicked`** — a notification tap, reported back for the delivery funnel. APNs and FCM do
  not report delivery at all, so on most deployments a click is the only evidence a notification
  arrived. It is best-effort: the promise never rejects and nothing is retried, because an
  unhandled rejection escaping a tap handler is a worse bug than a missing funnel row.
- `AbortSignal` cancellation on every typed call: `im.msg.send(req, { signal })`.
- `ImError.isRetryable` and `ImError.requiresReauth`, computed from the code alone.
- `ImSdk.contractVersion` / `ImSdk.version`, and `cv` on the handshake now defaults to this SDK's
  own version.
- Payload types for every model tiers T0–T2 reach, and `PagedResult<T>` returned whole so
  `nextCursor` is reachable.

### Changed

- **`cursorStore` and `userId` are now required constructor options.** There is no implicit
  default: defaulting to no persistence is what produced the cold-start bug, and the store is scoped
  `(endpoint host, appId, userId)` so that account switching on a shared device cannot hand one user
  another's cursors. `ImCursorStore.inMemory()` is the explicit opt-out and warns once.
- Delivery is **at-least-once** and messages are delivered on a microtask, never synchronously
  inside the frame that carried them. Be idempotent on `messageId`.
- Enums (`ConversationType`, `MessageContentType`, `Platform`, …) are now **open**: an unknown value
  from a newer server keeps its raw number instead of being coerced. They are const objects with a
  companion type rather than TypeScript `enum`s, so reverse lookup (`Platform[5]`) no longer works.
- The nine flat convenience methods (`send`, `sendText`, `history`, `recall`, `react`, `setTyping`,
  `conversations`, `markRead`, `totalUnread`) are deprecated in favour of the namespaced surface and
  now delegate to it. They are removed in 2.0.
- `license` is `Apache-2.0`, not `MIT` — for the express patent grant, which is a recurring redline
  in enterprise legal review that MIT's silence cannot answer.
- `disconnect()` no longer implies logout, and never unregisters the push token: a dead socket is
  precisely the state offline push exists to serve.
