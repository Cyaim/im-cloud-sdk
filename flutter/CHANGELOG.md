# Changelog

Versions are in lockstep across all five Cyaim IM client SDKs (`sdk/CONTRACT.md` §9.1): one number
identifies a *contract*, not one platform's release train.

## 0.9.0

First published release. It is deliberately **not** `1.0.0` — `1.0.0` is reserved for contract
tiers T0 and T1 complete on all five platforms with §5 and §6 implemented everywhere. The previous
`1.0.0` in this manifest had never been published and was a promise the SDK did not keep.

### Added (2026-10-28, desk notices)

- **`readDeskNotification(message)`** reads the 1801–1807 desk notices out of an ordinary
  `ImMessage`, as TypeScript's `readDeskNotification` does, into the sealed `ImDeskNotification`
  (`ImDeskQueuedNotification`, `…Assigned…`, `…Transferred…` with `fromAgentId`, `…Closed…` with
  `resolution` / `reason`, `…Requeued…` with `previousAgentId`, `…Abandoned…` with `waitedSeconds`,
  `…RatingRequested…` with `windowHours` / `askResolved` / `starTags`; each with its `code`). Null
  unless `contentType` is `ImMessageContentType.notification` **and** `content['code']` is 1801–1807
  — the same seven numbers are account error codes elsewhere. Never throws: an id of the wrong kind
  reads as `''` (a number or bool as its literal), a string member as null (stricter than the
  package's `imString`, which would turn a number into text — TypeScript does not), a count as 0,
  `askResolved` is true only for the JSON `true`, a `starTags` entry that is not a string is skipped,
  and an empty `agentId` is none. `code`, `waitedSeconds` and `windowHours` are read from a JSON
  number or a string holding one (`num.tryParse`, so `'903'` and `'1.805e3'` both read). Where
  TypeScript keeps a fraction, this does not: a code that is not a whole number is no notice (in
  TypeScript `1801.5` falls through to the 1807 branch), and a fractional count is truncated, since
  the fields are `int`.
- **`ImDeskNotificationCode`** (1801–1807) and **`ImDeskContextKeys`** (the nine context keys of
  `ImDeskRequest.context`), with TypeScript's values under lowerCamel names.
- `test/desk_test.dart`, 8 more cases (22 in the file): every code with the extras it carries; a typed
  resolution and a bare close; quoted counts, a quoted code and whole numbers in other spellings;
  members of the wrong kind read as defaults; a chat message, a notification with no code and null
  all answer null; 1800 / 1808 / 1500 and non-whole codes refused; a notice decoded off the wire with
  an exhaustive `switch`; and the constants held to `typescript/src/desk.ts` / `protocol.ts` name for
  name.
- README: a "Desk notices (1801–1807) and the context keys" section replaces "this SDK has no reader
  yet", with the README's two snippets checked by `dart analyze`; the Testing count is now 212.
- Run locally (Dart 3.10.2, Windows): `dart test` 212 passed, `dart analyze` no issues. Not run on the
  web compiler.

### Added (2026-10-22)

- **Key directory (T4)**: `im.keys.publish` / `upload` / `remaining` / `claim` / `devices` / `revoke` /
  `safetyNumber`, named for their endpoints (CONTRACT §4.2). The SDK carries keys and performs no
  cryptography: key material is an opaque standard-base64 string, sent and returned unchanged.
  `ImPublishKeysRequest` (identity key, `ImSignedPreKey`, optional `ImOneTimePreKey` list left out when
  empty, optional algorithm; no device or platform, which the server takes from the connection),
  `ImUploadOneTimeKeysRequest`, `ImRemainingKeysRequest` / `ImDeviceKeysRequest` (optional: the
  connected device / the caller's own), `ImClaimBundleRequest` → `ImPreKeyBundle` (`oneTimePreKey`
  null when the pool was empty), `ImDeviceKeyInfo` (platform as `ImPlatform`), `ImRevokeDeviceRequest`,
  `ImSafetyNumberRequest`; `remaining`, `devices` and `safetyNumber` read the server's bare number,
  array and string. Doc comments say claim consumes a one-time key (never prefetch or retry), publish
  replaces and keeps the pool, upload appends, revoking an unknown device succeeds, and no setting
  (`e2ee.enabled` included) gates the directory.
- `test/keys_test.dart`: every call's whole frame, full and minimal (nested members under exact
  camelCase, key material unchanged, no device or platform); replies with every member decoded; a
  drained bundle; refusals by code and message; no key material in the log; fixtures and bodies held
  to `payloadTypes`. The request bodies are in `wire-samples/flutter.json`, with
  `PublishKeysRequest.deviceId` / `platform` declared omitted; the README has a "Key directory
  (end-to-end encryption)" section and now counts all 107 endpoints typed. The `invoke()` examples say
  they are for any target. `msg.cancelScheduled`'s `1006` is documented in full (already being sent,
  already cancelled, or already sent or failed; `msg.recall` for a sent one).
- **Scheduled messages, folders and translation (T4)**: `im.msg.schedule` / `scheduled` /
  `cancelScheduled`, `im.conv.folders` / `upsertFolder` / `deleteFolder` and `im.msg.translate`, named
  for their endpoints (CONTRACT §4.2). `ImScheduleRequest` is the server's flat `ScheduleRequest`
  (no `options`, no `sendTime`; `clientMsgId` optional and not generated, as the server derives one),
  with a `.text` factory; `msg.scheduled` takes the existing `ImPageRequest` and returns
  `ImPage<ImScheduledMessage>`, whose `state` (pending / sent / cancelled / failed) is read off
  `messageId` and `error` since the server has no state field. `ImUpsertFolderRequest` (types as
  integers; an empty tag list left out, which the server reads as empty) with `.edit` for the
  replace-not-patch save, `ImFolderIdRequest`, `ImConversationFolder`; `ImTranslateRequest`,
  `ImTranslationResult` and `ImTranslatedMessage` (message ids as strings both ways). `msg.translate`
  on a deployment without translation surfaces `1203` / `1204` as an ordinary `ImException` with the
  server's message.
- `test/extras_test.dart`: every call's whole frame, full and minimal; replies with every member
  decoded; refusals by code and message, translate's `1203` / `1204` included; fixtures and bodies held
  to `payloadTypes`. The seven request bodies are in `wire-samples/flutter.json`; the README has a
  "Scheduled messages, folders and translation" section. The `invoke()` examples now use
  `keys.remaining`, which is still untyped.

- **The four streaming calls of T4 on `im.msg`**: `streamBegin`, `streamAppend`, `streamComplete`,
  `streamAbort` — named for their endpoints (CONTRACT §4.2), with `ImBeginStreamRequest` (address
  as for `msg.send`, `clientMsgId` generated when omitted, `contentType`, `placeholder`, nested
  `ImMessageOptions`, `extensions`), `ImStreamAppendRequest`, `ImCompleteStreamRequest`,
  `ImStreamAbortRequest` and `ImStreamHandle`; `streamComplete` returns `ImSendResult` and writes no
  cursor. `ImStreamWriter` is an optional handle over the same four calls.
- `im.streamEvents` decodes `evt.stream` into `ImStreamEvent` (`phase`: begin / delta / completed /
  aborted; a `messageId` read as a string whether it arrives quoted or bare), and
  `ImStreamAssembler` puts the frames back together by the server's rules: ordered by index,
  duplicates ignored, a fragment that lands after the terminal frame filling in the finished stream
  rather than opening a new one, holes counted (`hasGap`, `missingFragments`) and never repaired.
- Tests prove the frames stay out of the message path (no `msg.sync`, no cursor, even when the
  terminal frame names a seq past the cursor) while the finished message goes through it, gap repair
  included, before or after its terminal frame. The four request bodies are in
  `wire-samples/flutter.json`, one with every member (nested `options` and `options.pushConfig`
  included) and one minimal; the README has a "Streaming replies" section.

- **`im.room` — the seven `room.*` endpoints of T4**: `join`, `quit`, `send`, `onlineCount`,
  `memberList`, `mute`, `kick`, with `ImRoomIdRequest`, `ImRoomCursorRequest`, `ImRoomSendRequest`
  (an `ImRoomMessage` nested under `message` — the members of `SendMessageRequest` a room reads,
  as in TypeScript and Kotlin — plus `.text` factories that take a priority),
  `ImRoomMuteRequest` (`untilMs` required-but-nullable, and `.unmute`), `ImRoomKickRequest`,
  `ImChatRoom` and `ImRoomJoinResult`. `room.onlineCount` reads the bare number the server answers;
  `room.memberList` returns an `ImPage<String>` sample.
- `im.roomEvents` decodes the `room.muted` / `room.kicked` / `room.destroyed` events out of
  `evt.system` into `ImRoomEvent`, keeping an unknown `room.*` event with its body and leaving every
  other `evt.system` event (the device-log request) to its own handler. `ImRoom` maps a room id to
  its `r_<roomId>` conversation id and back.
- Tests prove the rule the inventory notes on `room.join`: a room message (`seq` 0) is delivered
  without a `msg.sync`, without touching any cursor, without making the next conversation message
  look like a gap, without waiting behind a repair in flight, and even past a stale cursor under the
  room's id; `room.send` writes no cursor from its `seq` 0 result.
- The room bodies are in `wire-samples/flutter.json`; the recorder now pins the generated
  `clientMsgId` / `sendTime` inside `room.send`'s nested `message` as it does at the top level, and
  the kind test accepts a nested member left out only through `nestedOmitted`, which names the
  path and the reason and is checked against the inventory (not recorded into the sample file).

### Added (2026-10-09)

- **`im.desk` — the nine `desk.*` endpoints of T4**, typed as TypeScript has typed them since
  2026-09-07: `request`, `accept`, `transfer`, `close`, `status`, `queue`, `rate`, `canned`,
  `suggest`, with their request and payload types (`ImDeskSession`, `ImDeskQueueView`,
  `ImDeskCannedReply`, …), `ImAgentStatus` / `ImDeskSessionState` as open integer enums and
  `ImDeskEndReason` / `ImDeskDisposition` / `ImDeskCannedReplyScope` / `ImDeskSessionChange` as
  string constants. `ImDeskTransferRequest` has one constructor per target, so exactly one goes out.
  `im.deskEvents` decodes `evt.desk`.
- `test/wire_kind_test.dart` now judges and records every target this package types, not only
  T0–T3, so the desk bodies are in `wire-samples/flutter.json` for the platform's binder.

### Fixed (2026-09-28)

- **`connect()` now completes once the connection is open**, waiting out a refused or dropped first
  attempt and its jittered retries, and throws if the connection closes first — `1100` for a terminal
  kick or `close()`, `1101` when the token expired and `onTokenExpired` had no fresh one — as Kotlin,
  Swift and Unity already did (CONTRACT §7). It used to complete after the *first* attempt either way:
  a gateway that refused the first handshake left the caller "connected" to nothing and its next
  request failed with `1005 not connected`, and a socket that died before its handshake settled
  left `connect()` waiting forever.

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
- Since 2026-09-25 both refusals also apply when a client opens a stream (`msg.streamBegin`, through
  `invoke`), with the same 1103 and wording, instead of only when it commits; and the README's
  "Offline push" section now says it where push is wired.

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
