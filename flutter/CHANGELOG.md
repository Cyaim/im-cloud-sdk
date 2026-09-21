# Changelog

Versions are in lockstep across all five Cyaim IM client SDKs (`sdk/CONTRACT.md` §9.1): one number
identifies a *contract*, not one platform's release train.

## 0.9.0

First published release. It is deliberately **not** `1.0.0` — `1.0.0` is reserved for contract
tiers T0 and T1 complete on all five platforms with §5 and §6 implemented everywhere. The previous
`1.0.0` in this manifest had never been published and was a promise the SDK did not keep.

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

### Fixed — silent data loss on cold start

**This SDK lost every message that arrived while the app was closed.** `_maxSeq` lived in a private
`Map` with no accessor and nothing that outlived the process, so each launch reported an empty
`convSeqs` to `conn.sync`, got no `gapsFrom` back — the server can only diff against what it is
told — and then adopted the server's newest `maxSeq` in the first-sight branch. Everything in
between fell behind the cursor: never requested, never delivered, no error and no log line.

The fix is the two-cursor model in `sdk/CONTRACT.md` §5, implemented literally:

- **`ImCursorStore` is now a required argument** on `ImOptions`. `ImCursorStore.file(path)` for a
  JSON file the host app chooses the directory for, or an explicit `ImCursorStore.inMemory()`,
  which logs one warning saying what it costs. There is no implicit default, because defaulting to
  no persistence is what produced the bug.
- Two cursors per conversation: `deliveredSeq` in memory, `committedSeq` written through to the
  store. `convSeqs` reports `committedSeq`, never `deliveredSeq`, and `deliveredSeq` is pulled back
  to `committedSeq` before every `conn.sync` so redelivery actually reaches the application.
- `ImClient.commit(conversationId, seq)` — the application calls it once the message is durably in
  its own store. The SDK never infers durability from a listener returning.
- Adoption of an unseen conversation flushes to the store **synchronously**, before the next
  `conn.sync` page. Ordinary commits may be debounced (`ImOptions.cursorSaveDebounce`); a lost
  debounced commit costs one duplicate delivery, a lost adoption costs permanent silent loss.
- `conn.sync` now **pages until `hasMore` is false**, and `conversationCursor` advances only after
  a run completes. The list is sorted newest-first, so the old behaviour — take the maximum from
  page one and stop — pushed the cursor past every conversation on pages 2…N, which the server
  then never returns again.
- `msg.sync` repair pages too, looping on `hasMore` rather than on `messages.length` (the server
  computes `hasMore` on the raw window before per-user hidden messages are filtered out).
- An over-`maxAutoRepairSeq` gap now raises `conversationNeedsReload` on the **live** path as well
  as the resume path. It used to accept the jump silently: the cursor stayed honest and the
  application was never told a stretch of conversation had been skipped.
- A cursor store that fails to `load()` freezes every cursor for the session and surfaces on
  `ImClient.errors` instead of looking like a fresh install. Adopting on a failed load destroys
  history that is sitting intact in the application's own database.

Delivery is therefore **at-least-once**. Deduplicate on `ImMessage.messageId`.

### Added — the device log

- **`logStore` and `im.diag` (ADR-003).** The console can ask a running device for the SDK's runtime
  log; the client answers once per connect and on an `evt.system` frame. `ImLogStore.inMemory()` is
  the default, `im.log` takes the application's own lines, and `deviceLogUploader` is the seam for
  the web, where `dart:io` does not exist. **Not supplying a store is a complete choice** — the
  in-memory ring covers this run only, and every answer carries `coveredFromMs` and `volatile` so a
  support engineer knows whether they are reading three minutes or three weeks.

### Added — offline push registration

`push.register` / `push.unregister` shipped on the server and no SDK called them, so offline push
was unreachable from any official client.

- `im.push.setToken(provider, token, language:)` caches the vendor token and registers it on every
  successful connect — not once at install, because the vendor may replace a token while the
  process is frozen.
- `im.logout()` sends `push.unregister` **before** closing the socket. `disconnect()` never
  unregisters: a dead socket is precisely the state offline push exists to serve.
- `ImPushProvider` names every channel the server routes (`apns` `fcm` `huawei` `xiaomi` `oppo`
  `vivo` `honor`). Android must always send one explicitly.

### Added — typed endpoint coverage, tiers T0 / T1 / T2

Namespaced to match the endpoint prefix, so `im.group.memberList(…)` is `group.memberList`:
`im.conn` `im.msg` `im.conv` `im.user` `im.friend` `im.group` `im.media` `im.push`
`im.moderation`. 51 endpoints typed, up from 11 referenced.

- **T0 (3/3)** — `conn.heartbeat`, `conn.reauth`, `conn.sync`. `conn.reauth` is new: an expired
  token now costs one frame on the socket that is already open rather than a full reconnect.
- **T1 (18/18)** — the 1:1 chat MVP, including `msg.delete`, `conv.get`, all four `user.*` profile
  calls, both `media.*` and both `push.*`.
- **T2 (30/30)** — all ten core `group.*`, eight `friend.*` including `friend.block`, the three
  presence calls, `conv.setting` / `delete` / `clear`, and `msg.edit` / `forward` / `react` /
  `receipt`. Plus the two the tier gained after it was first written: `moderation.report`, which
  is the other half of `friend.block` — app-store review wants a way to report content as well as
  a way to block a user, and an app shipping only one still fails the submission — and
  `push.clicked`, the tap that closes the tenant's sent → delivered → clicked funnel. It is the
  only call in the package that logs its own failure instead of throwing: best-effort statistics
  that nothing waits on, fired from a tap handler without `await`.

Every typed method takes one request object named for the server DTO, and every one is a thin
wrapper over the same internal request path `invoke()` uses.

### Added — typed endpoint coverage, tier T3 (20/20)

Competitive parity, typed whole — all twenty at once, because a half-typed tier is worse than an
untyped one. 73 of the server's 107 endpoints are now typed; the 34 of T4 stay behind `invoke()`.

- **`im.msg`** — `pin`, `unpin`, `pins`, `favourite`, `unfavourite`, `favourites`, `burn`,
  `search`, `receiptDetail`. The five single-message calls share `ImConversationMessageRequest`;
  `favourites` takes an optional `ImPageRequest`; `pins` returns a plain list of
  `ImPinnedMessage` (the board is capped, there is nothing to page); `receiptDetail` returns
  `ImMessageReceipt`, whose `totalCount` includes the sender.
- **`im.conv.markUnread`**, **`im.user.setStatus`**, **`im.friend.setRemark`**.
- **`im.group`** — `transfer`, `applicationList`, `handleApplication`, `setRole`, `mute`,
  `muteMember`, `setNickname`, `announcement`. `applicationList` takes an optional
  `ImGroupCursorRequest` (an empty `groupId` lists every group the caller manages) and returns
  `ImGroupApplication` rows of every status, not only pending.

What the wire requires and the signatures cannot show:

- **Message ids leave as quoted strings**, and on these endpoints that is the server's rule, not
  only this package's: the request DTOs declare `messageId` as a C# `string`, and the socket binder
  refuses a JSON number for one with `1000 InternalError` rather than a `1001` naming the field.
- **Flags whose server default is `true` are always sent**: `conv.markUnread`'s `unread` and
  `group.mute`'s `mute`. `group.handleApplication`'s `accept` is required, because the server
  reads an absent one as *reject*.
- **`group.setRole` asserts `member` or `admin`.** The server refuses `owner` but stores any other
  integer, and `0` (escapes a group-wide mute) or `4` (outranks every admin) are privilege bugs.
  An `assert`, so it trips in development and compiles away in release.
- Every T3 method documents its refusals, including the ones that read backwards: a past
  `untilMs` mutes a *group* indefinitely but unmutes a *member*; `msg.search` is rate limited
  (`1003`) *before* it checks whether search is on (`1203`), so debounce search-as-you-type.

`test/t3_test.dart` pins each request body — key set, values, JSON kind — and each decoded
payload, and checks the twenty targets that reach the wire against the inventory's T3 list.

### Added — cancellation

`ImCancelToken`, passed as the trailing argument to any typed call. Cancelling abandons the reply,
removes the pending entry, and does **not** cancel the server-side effect — reissue with the same
`clientMsgId`. It raises `ImCancelledException`, not an `ImException` with an invented code.

### Changed

- Errors now carry `traceId` and `target`, and expose `isRetryable` / `requiresReauth` computed
  from the code alone, identically in all five SDKs.
- `status: 2` (no such target) maps to `1008 UnsupportedOperation`, not `1002 NotFound` — the
  signal an SDK newer than a private-deployment server produces.
- A socket that drops with requests in flight fails them `1004 Timeout`, not `1005`: the request
  may well have executed, and 1005 would be claiming otherwise.
- Enums are open (`extension type` over the wire value), so an unknown content type keeps its own
  number instead of being coerced to a default member.
- The nine flat convenience methods (`send`, `sendText`, `history`, `recall`, `react`, `setTyping`,
  `conversations`, `markRead`, `totalUnread`) are deprecated for 2.0 and delegate to the namespaced
  surface.
- `ImSdk.contractVersion` (`"1.0"`) and `ImSdk.packageVersion` are exposed; the package version
  goes on the wire as the handshake's `cv`.
- Apache-2.0 `LICENSE` added, and a runnable `example/main.dart`.

## 1.0.0 — withdrawn

Never published. Superseded by 0.9.0; see §9.1 of the contract for why the number moved down.
