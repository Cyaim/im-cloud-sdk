# Changelog

All notable changes to `com.cyaim.im:im-client`.

Versions are [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html) and move **in lockstep with the
other four Cyaim IM SDKs** (TypeScript, Swift, Flutter, Unity). One number identifies a *contract*,
not a platform, so "we're on 0.9.0" answers "which endpoints do you have" without anyone having to
ask which SDK. The contract itself is [`sdk/CONTRACT.md`](../CONTRACT.md) and its version is
published as `ImSdk.contractVersion`.

## [0.9.0] — unreleased

First published release. The version is deliberately below 1.0.0: `1.0.0` is reserved for contract
tiers T0 and T1 complete on **all five** SDKs. Nothing before this was ever published.

### Added (2026-10-28, desk notices)

- **`readDeskNotification(message)`** reads the 1801–1807 desk notices out of an ordinary
  `ImMessage`, as TypeScript's `readDeskNotification` does, into the sealed `DeskNotification`
  (`Queued`, `Assigned`, `Transferred`, `Closed`, `Requeued`, `Abandoned`, `RatingRequested`, each
  with its `code`). Null unless `contentType` is `Notification` **and** `content.code` is 1801–1807
  — the same seven numbers are account error codes elsewhere. Never throws: an id of the wrong kind
  reads as `""` (a numeric one as its literal), a string as null, a count as 0, `askResolved` is
  true only for the JSON `true`, a `starTags` entry that is not a string is skipped, and an empty
  `agentId` is none. `code`, `waitedSeconds` and `windowHours` are read from a JSON integer or a
  string holding one; unlike TypeScript's `Number(…)`, a fraction, an exponent or padded whitespace
  is not an integer here, so such a code is no notice and such a count is 0.
- **`DeskNotificationCode`** (1801–1807) and **`DeskContextKeys`** (the nine context keys of
  `DeskRequest.context`), with TypeScript's names and values.
- Tests (`DeskTest`, 8 more): every code with the extras it carries; a typed resolution and a bare
  close; quoted counts and a quoted code; members of the wrong kind read as defaults; a chat message,
  a notification with no code and null all answer null; 1800 / 1808 / 1500 and non-integer codes
  refused; a notice decoded off the wire with an exhaustive `when`; and the constants held to
  `typescript/src/desk.ts` / `protocol.ts` name for name.
- README: the desk section now describes the reader and the keys instead of saying there is none.
- **Not compiled or run locally**: the machine this was written on has JDK 11 and the build needs
  17. The SDK repository's CI is the first thing to compile and run it.

### Added (2026-10-22, key directory)

- **`im.keys` — the end-to-end encryption key directory** (T4): `publish`, `upload`, `remaining`,
  `claim`, `devices`, `revoke`, `safetyNumber` (one-field overloads, and `claim(userId, deviceId)`),
  with `PublishKeysRequest` / `SignedPreKey` / `OneTimePreKey` / `UploadOneTimeKeysRequest` /
  `RemainingKeysRequest` / `ClaimBundleRequest` / `DeviceKeysRequest` / `RevokeDeviceRequest` /
  `SafetyNumberRequest`, and `PreKeyBundle` / `DeviceKeyInfo`. **The SDK performs no cryptography**:
  keys and signatures are opaque standard-base64 strings passed through unchanged and never logged.
  `PublishKeysRequest` has no device id or platform — the server takes both from the connection.
  `remaining` and `devices` default to the connected device / the caller's own (an empty body).
  `claim` consumes a one-time prekey and is documented as non-idempotent; an empty pool decodes as
  `oneTimePreKey == null`. No `e2ee.enabled` gate and no events, as the server has none.
- Tests (`KeysTest`, 15): every call's whole frame on both overloads, nested `signedPreKey` /
  `oneTimePreKeys[]` / `keys[]` names exact; replies with every field set held to `payloadTypes`;
  the empty-pool claim; a claim sent exactly once whether refused (`1005`) or unanswered (`1004`);
  the 1001 / 1008 / 1202 / 1002 refusals; key material unchanged on the wire and absent from the log.
- `wire-samples/kotlin.json` records the seven request bodies in full, plus a minimal publish and
  the empty `remaining` / `devices` bodies; `PublishKeysRequest.deviceId` / `.platform` are declared
  omitted with the reason.
- README section "Key directory (end-to-end encryption)"; the escape-hatch example now names an
  illustrative future endpoint. The `msg.cancelScheduled` docs say what `1006` means in full: in
  flight, already cancelled, or already sent / failed.

### Added (2026-10-22, scheduling, folders, translation)

- **Scheduled messages on `im.msg`**: `schedule`, `scheduled`, `cancelScheduled` (with a one-field
  overload), with `ScheduleRequest` / `ScheduleIdRequest` and `ScheduledMessage`. `ScheduleRequest`
  is the server's flat shape — the message members beside `sendAt`, no `options`, no `sendTime` —
  and leaves `clientMsgId` to the server when null. `ScheduledMessage` has no state field; its KDoc
  says how `messageId` and `error` tell pending, sent, cancelled ("cancelled by sender") and failed
  apart. A fired schedule is an ordinary `evt.message`; nothing new is decoded.
- **Conversation folders on `im.conv`**: `folders` (a plain list), `upsertFolder`, `deleteFolder`
  (with a one-field overload), with `UpsertFolderRequest` / `FolderIdRequest` and
  `ConversationFolder`; `types` go out as integers.
- **`im.msg.translate`** with `TranslateRequest` (ids quoted), `TranslationResult` and
  `TranslatedMessage`. A deployment without translation answers `1203` / `1204`, which reach the
  caller as an ordinary `ImException` with the server's message.
- Tests (`ScheduleTest`): every call's whole frame, minimal and full; replies with every field set
  held to `payloadTypes`; `ScheduleRequest` pinned as `SendMessageRequest` minus `options` and
  `sendTime` plus `sendAt`; scheduling proven to move no cursor; the 1203 / 1204 / 1002 / 1006 paths.
- `wire-samples/kotlin.json` records the five new request bodies in full, and the three that have
  optional members once more in their shortest form (`via` ending `minimal`).
- README sections for the three families; the escape-hatch example is now `keys.remaining`.

### Added (2026-10-22, streaming)

- **The four `msg.stream*` endpoints of T4** on `im.msg`: `streamBegin`, `streamAppend`,
  `streamComplete`, `streamAbort`, with `BeginStreamRequest` / `StreamAppendRequest` /
  `CompleteStreamRequest` / `StreamAbortRequest` and `StreamHandle`. `streamBegin` fills a blank
  `clientMsgId` (the server makes none up); `streamComplete` answers the stored message's
  `SendMessageResult` and, unlike `msg.send`, moves no cursor — the stored message reaches the
  producer's own connection on `evt.message` and is delivered through the ordinary path.
  `StreamWriter.begin(im.msg, request)` holds the stream id and key for a producer.
- **`im.streamEvents`** decodes `evt.stream` into `StreamEvent` (`Begin` / `Delta` / `Completed` /
  `Aborted`; the message id read as a string or a number). `StreamAssembler` and
  `Flow<StreamEvent>.assemble()` join the pieces by index — duplicates ignored, the text stopping at
  a missing piece, a hole or a mid-stream join marked not `intact` and never repaired, nothing
  reopening a finished stream.
- Tests: every call's frame, replies with every field set held to `payloadTypes`, each phase, the
  assembly in every order the server produces, the terminal frame before and after the stored
  message, and the pieces proven to stay out of `messages`, cursors and `msg.sync`.
- `wire-samples/kotlin.json` records the four stream request bodies.

### Added (2026-10-22)

- **`im.room` — the seven `room.*` endpoints of T4**: `join`, `quit`, `send`, `onlineCount`,
  `memberList`, `mute`, `kick`, with `RoomIdRequest` / `RoomCursorRequest` / `RoomSendRequest` /
  `RoomMuteRequest` / `RoomKickRequest`, `ChatRoom` and `RoomJoinResult`. `room.send` takes a
  `RoomMessage` — the members of `SendMessageRequest` a room reads — and fills a blank `clientMsgId`.
  `RoomMuteRequest` has no defaults: a null `userId` is the whole room and a null `untilMs` lifts the
  mute, and neither should happen by omission. `im.roomEvents` decodes `room.muted` / `room.kicked` /
  `room.destroyed` out of `evt.system`, beside the device-log handler and without touching it.
- Tests prove a chat-room message (`seq` 0, `r_<roomId>`) is delivered at once, asks `msg.sync` for
  nothing, is not held behind another conversation's repair and moves no cursor.
- `wire-samples/kotlin.json` records the five room request bodies.

### Changed (2026-10-22)

- **`commit(conversationId, seq)` ignores a seq of 0 or below**, as the TypeScript SDK always has.
  The quick start commits every message it stores; a room message committed that way registered the
  room as a conversation at 0 and sent it in every `conn.sync`.

### Added (2026-10-09)

- **`im.desk` — the nine `desk.*` endpoints of T4**, typed as TypeScript has typed them since
  2026-09-07: `request`, `accept`, `transfer`, `close`, `status`, `queue`, `rate`, `canned`,
  `suggest`, with their request and payload types (`DeskSession`, `DeskQueueView`,
  `DeskCannedReply`, …), `AgentStatus` / `DeskSessionState` as open integer enums and
  `DeskEndReason` / `DeskDisposition` / `DeskCannedReplyScope` / `DeskSessionChange` as string
  constants. `DeskTransferRequest` is built through `agent` / `skill` / `queue` so exactly one target
  goes out. `im.deskEvents` decodes `evt.desk`.
- `wire-samples/kotlin.json` records the eight desk request bodies, so the platform's binder judges
  them like every other request.

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

### Fixed

- **Cold-start data loss (CONTRACT.md §5).** The client re-baselined onto the server's newest `seq`
  on every process start, so every message that arrived while the app was closed was silently
  dropped — no error, no log line, and no later event that corrected it. `conn.sync` only reports a
  gap for a conversation the client named in `convSeqs`, and the client named none, because
  `cursors` was a private map with no accessor of any kind.

  The fix is the contract's two-cursor model: `deliveredSeq` in memory, `committedSeq` durable and
  written through a required [`ImCursorStore`](src/main/kotlin/com/cyaim/im/client/ImCursorStore.kt).
  The application calls `commit(conversationId, seq)` once a message is in *its* store, and
  `convSeqs` is built from that and nothing else. **Delivery is at-least-once; be idempotent on
  `messageId`.**

- **`conn.sync` did not page.** It returns at most 200 conversations. A user with more than that got
  gaps reported for the first page only; the rest were never repaired.

- **`conversationCursor` advanced after a partial run.** The list is sorted by `updatedAt`
  descending, so page one holds the newest timestamp — taking the maximum from page one and
  stopping pushed the cursor past every conversation on pages 2…N, which the server then never
  returned again. It now moves only when a run reaches `hasMore == false`.

- **`msg.sync` repair did not page.** The server clamps the limit to 500 and reports `hasMore`, so a
  900-seq repair silently fetched 500 and left 400 as a permanent hole. `hasMore` is computed on the
  raw window before per-reader hidden messages are filtered out, so the loop is on `hasMore` and
  never on `messages.size`.

- **An oversized *live* gap was accepted silently.** The cursor stayed honest but the application was
  never told that a stretch of conversation had been skipped, so it never reloaded it. Both paths
  now advance the cursor *and* raise `conversationNeedsReload`.

- **Error mapping (CONTRACT.md §7.2).** `status == 2` now maps to `1008 UnsupportedOperation` (not
  `1002 NotFound`) — "this deployment does not have this endpoint" is a different sentence from
  "your group does not exist". `status == 1` maps to `1000 InternalError` with the transport's own
  message. Requests in flight when a socket drops now fail `1004 Timeout` rather than `1005`,
  because 1005 would claim the call never reached the server and the SDK does not know that.

- **Recall, edit, delete, react, forward and receipts were refused on every call.** Their message
  ids left as JSON numbers, while the server declares those fields strings and the socket binder
  refuses a number there with `1000` before the endpoint runs. `msg.send` had the same fault on
  `quoteMessageId` and `threadRootId`, so a reply or a thread message failed outright. The fields
  stay `Long` (what `ImMessage.messageId` holds) and are now written with `LongAsStringSerializer`,
  list elements included; an absent quote or thread id still stays off the frame. Nothing in the
  suite asserted these bodies, and the shared test accessors read `7` and `"7"` as the same value;
  they now check the JSON kind first. `RequestWireKindTest` checks every field of every typed request
  (51 request types, 187 fields) against the server types in `endpoint-inventory.json`.

### Added

- **`logStore` and the device log (ADR-003).** `im.diag`, an `ImLogStore` option with
  `ImLogStore.inMemory()` as its default and `ImLogStore.file(File)` for when you have decided where
  your users' runtime detail may be written. The console can ask a running device for the SDK's
  runtime log; the client answers once per connect and on an `evt.system` frame. **Not supplying a
  store is a complete choice** — the in-memory ring covers this process only, and every answer
  carries `coveredFromMs` and `volatile` so a support engineer knows what they are reading.
- **Offline push (CONTRACT.md §6).** `im.push.register` / `im.push.unregister`, plus
  `im.push.setToken(provider, token)` for the host app to hand over an FCM or OEM token from its own
  `onNewToken`. The SDK re-registers on every successful connect, caches a token handed over while
  offline, and `im.logout()` unregisters *before* closing the socket — after the socket is gone
  there is no authenticated channel and only the tenant backend can remove the token
  (`DELETE /v1/users/{userId}/push-tokens/{deviceId}`). The server side shipped some time ago and no
  SDK called it, so offline notifications were unreachable from any official client.

- **Typed coverage of contract tiers T0, T1 and T2** — 51 endpoints, grouped into namespaces named
  for the target prefix: `im.conn`, `im.msg`, `im.conv`, `im.user`, `im.friend`, `im.group`,
  `im.media`, `im.push`, `im.moderation`. Previously 11 endpoints were reachable and 9 were typed.

- **Typed coverage of contract tier T3, all twenty endpoints** — `ImSdk.tiers` now reads
  `T0`–`T3`, and the typed surface is 73 of the server's 107 endpoints.
  - `im.msg`: `pin` `unpin` `pins` `favourite` `unfavourite` `favourites` `burn` `search`
    `receiptDetail`; `im.conv.markUnread`; `im.user.setStatus`; `im.friend.setRemark`;
    `im.group`: `transfer` `applicationList` `handleApplication` `setRole` `mute` `muteMember`
    `setNickname` `announcement`.
  - New request types `ConversationMessageRequest`, `ReceiptDetailRequest`, `PageRequest`,
    `SearchMessagesRequest`, `MarkUnreadRequest`, `SetStatusRequest`, `SetRemarkRequest`,
    `TransferOwnerRequest`, `HandleApplicationRequest`, `SetRoleRequest`, `MuteGroupRequest`,
    `MuteMemberRequest`, `SetGroupNicknameRequest`, `AnnouncementRequest`; payloads
    `PinnedMessage`, `MessageReceipt`, `GroupApplication`. `ConversationIdRequest` and
    `GroupCursorRequest` are reused.
  - **Message ids in these requests leave quoted.** The server declares them strings and the socket
    refuses a JSON number with `1000`, so `ConversationMessageRequest.messageId` and
    `ReceiptDetailRequest.messageId` are `Long` fields written as strings, as
    `SubmitReportRequest.messageId` already was.
  - `group.setRole` throws `IllegalArgumentException` for any role but `Member` or `Admin` before
    sending: the server refuses `Owner` but stores any other integer, and `0` escapes a group-wide
    mute while `4` outranks the admins.
  - `group.applicationList()` with no argument sends an empty `groupId`, which the server reads as
    "every group I manage".
  - `CompetitiveParityTest` drives all twenty against the inventory's T3 list and pins every request
    body on the wire — key set and JSON type — and every payload decode.

- **`conn.reauth`.** A token expiring mid-session is now a round trip on the existing socket rather
  than a full reconnect, and the call that hit `1101` is retried once.

- `ImCursorStore.file(path)` and `ImCursorStore.inMemory()`; `ImClient.commit`,
  `ImClient.flushCursors`, `ImClient.committedSeq`, `ImClient.cursorStoreState`, `ImClient.logout`.

- `ImException.isRetryable` / `ImException.requiresReauth`, computed from the code alone and
  identical across all five SDKs.

- `ImLogger`, so the handful of diagnostics that cannot be returned to a caller — a cursor store
  that would not write, a push token held but never registered — are visible rather than silent.

- The whole of the server's `ImErrorCode` as named constants, not just the codes this SDK raises.

- `ImSdk.version`, `ImSdk.contractVersion` and `ImSdk.tiers`. The package version is sent as the
  `cv` handshake parameter when the application has not set one of its own.

### Changed

- **`ImClient` now takes an `ImCursorStore` as its second constructor argument, with no default.**
  This is the breaking change, and it is deliberately a compile error: defaulting to no persistence
  is what produced the data-loss bug, and defaulting to *some* persistence would mean the SDK
  guessing where a JVM application may write.

- **Wire enumerations are open.** `Platform`, `ConversationType`, `MessageContentType` and the nine
  new ones are value classes over the server's integer rather than `enum class`, so an unrecognised
  member keeps its number instead of collapsing into `Unknown` and losing the one thing a support
  ticket needed. `when` over one of them now needs an `else` — that branch is the one that handles a
  server newer than your build.

- The nine flat convenience methods (`send`, `sendText`, `history`, `recall`, `react`, `setTyping`,
  `conversations`, `markRead`, `totalUnread`) are deprecated in favour of the namespaced surface.
  They still work and still delegate; they are scheduled for removal in 2.0.

- `staleConversations` is renamed `conversationNeedsReload` to match the other four SDKs. The old
  name is deprecated and points at the same flow.

- `ConversationDigest` is renamed `MessageBrief`, after the server payload type. Deprecated typealias
  kept.

- `conv.unreadTotal()` returns `Long`; `ConversationView.unreadCount` is `Long`. The server sends a
  64-bit value.

- Licence is Apache-2.0, not MIT — for the express patent grant, which is a recurring redline in
  enterprise legal review, and to match the Apache-2.0 transport submodule.

### Known gaps

- Tier T4 (E2EE keys, chat rooms, service desk, streaming, scheduling, folders, translation) is not
  typed. Reach it through `im.invoke<T>(target, body)`, which shares one code path with every typed
  method.
