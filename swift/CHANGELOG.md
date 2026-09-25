# Changelog

All notable changes to `CyaimIM` are recorded here. The version number is shared across all five
Cyaim IM client SDKs — one number identifies a *contract*, not a platform, so "we're on 0.9.0"
answers "which endpoints do you have" without anyone asking which platform the customer is on.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [0.9.0] — unreleased

First published release. The version is deliberately **0.9.0** rather than 1.0.0: `1.0.0` is
reserved for tiers 0 and 1 complete on all five SDKs, and until then the number would be a promise
the family does not keep. Implements client contract **1.0**.

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

- **Recall, edit, delete, forward, react and read receipts work again.** `RecallMessageRequest`,
  `EditMessageRequest`, `ReactRequest`, `DeleteMessagesRequest`, `ForwardMessagesRequest` and
  `ReceiptRequest` wrote their message ids as JSON numbers, and so did `SendMessageRequest`'s
  `quoteMessageId` and `threadRootId` and `MessageDraft`'s `quoteMessageId`. The server declares
  every one of them `string`, and the gateway binds each field by its C# type without converting,
  so each of those calls came back status `1`, `1000 InternalError`, before the endpoint ran — and
  a send that quoted or threaded a message failed outright. They are now written as quoted strings.
  The properties stay `Int64`, so `ImMessage.messageId` still goes straight in; nothing changes at a
  call site. `RequestWireKindTests` compares every T0–T2 request body whole, kind included.
- **`send(_ draft:)` no longer drops the draft's `options`.** `MessageDraft.request` left them
  behind, so every draft went out with the default switches whatever it asked for. They now cross
  through `MessageOptions`' own decoder: a switch the draft leaves out takes the server's default.
- `MessageOptions.expireIn` was documented as seconds. The server adds it to its millisecond clock,
  so it is **milliseconds**, and a value written as seconds expired the message a thousand times too
  soon.
- **Cold start no longer loses messages.** The client now keeps two cursors per conversation — the
  `seq` it has handed the application (`delivered`, in memory) and the `seq` the application has
  told it is durably stored (`committed`, in the cursor store) — and reports the second one in
  `conn.sync`'s `convSeqs`. Previously nothing forced an integrator to restore anything, and a
  relaunch that restored nothing adopted the server's newest `seq`, dropping every message that had
  arrived while the app was closed. Silently: no error, no log line, no later event that corrected
  it. See `sdk/CONTRACT.md` §5.
- **`conn.sync` now pages to the end of the conversation list.** It returns at most 200
  conversations per page; a client that stopped after page 1 repaired only that page's gaps. The
  conversation cursor is now advanced only when a run reaches `hasMore: false`, and to the maximum
  `updatedAt` across the whole run — the list is sorted newest-first, so taking page 1's timestamp
  and stopping told the server it had already seen every later page, which it would then never
  return again.
- **Gap repair now pages `msg.sync`.** The server clamps a sync to 500 messages and reports
  `hasMore`; a single call left anything beyond that as a permanent hole. `hasMore` is computed on
  the raw window before per-user hidden messages are filtered out, so the loop runs on `hasMore` and
  never on `messages.count`.
- **An oversized gap now tells the application.** A span longer than `maxAutoRepairSeq` advances both
  cursors and raises `ImSessionEvent.conversationNeedsReload`, on the live path as well as the resume
  path. Previously the cursor moved in silence and nothing ever mentioned the missing stretch.
- **Numbers written as JSON strings decode.** The gateway serialises with
  `NumberHandling.AllowReadingFromString`, so a 64-bit `seq` may arrive as `"1234"`. Because frames
  are decoded whole, a decoder that threw on that dropped the entire message.
- Transport `status: 2` now maps to `1008 UnsupportedOperation` rather than to whatever the (absent)
  business envelope said, and `status: 1` to `1000 InternalError` with the transport's own message.
- A socket that drops with requests in flight now fails them `1004 Timeout` rather than `1005`:
  `1005` claims the call was never delivered, and the SDK does not know that.
- `JSONValue.decoded(as:)` no longer declares a generic type inside a generic function, which the
  Swift 6 frontend rejects outright on the corelibs platforms.
- `invoke(_:body:as: EmptyBody.self)` now succeeds on an acknowledgement. The gateway omits `data`
  on a reply that has none, and the escape hatch threw `1000 "… returned no payload"` for exactly
  the call its own documentation used as the example — so every write endpoint reached through
  `invoke` reported failure after it had succeeded.

### Added

- **`logStore` and the device log (ADR-003).** `im.diag`, an `ImLogStore` option with
  `.inMemory()` as its default and `.file(at:)` for when you have decided where your users' runtime
  detail may be written — `Documents` and `Library/Caches` differ in backup behaviour, and that is
  your decision rather than the SDK's. `im.log` takes an application's own lines. Every answer
  carries `coveredFromMs` and `volatile` so a support engineer knows what they are reading.
- **`ImCursorStore`, a required constructor argument.** `ImCursorStore.applicationSupport(subdirectory:scope:)`,
  `.file(at:)` and an explicit `.inMemory()` that logs one warning. There is no default: defaulting
  to no persistence is what produced the bug above, and defaulting to *some* persistence would mean
  guessing where an app may write.
- `ImClient.commit(_:seq:)` — monotonic, and the only thing that advances the durable cursor.
  Delivery is at-least-once; applications must be idempotent on `messageId`.
- `ImClient.sessionEvents()` and `ImSessionEvent`: `conversationNeedsReload`,
  `cursorStoreUnavailable`, `cursorsNotPersisted`, `pushTokenNotRegistered`.
- `ImClient.resync()`, for re-running `conn.sync` after re-deriving cursors from the app's own store.
- `ImClient.enterBackground()`, which flushes pending cursor commits on suspend.
- **Push registration.** `ImClient.setPushToken(deviceToken:)` (hex-encodes an APNs token),
  re-registered automatically on every connect, and `ImClient.logout()`, which sends
  `push.unregister` *before* closing the socket. `disconnect()` deliberately never unregisters.
  `im.push.clicked(_:)` closes the delivery funnel from the tap handler; it is the one call in the
  typed surface that swallows a server failure, because APNs reports no delivery and a statistic
  that could fail a notification tap would cost more than the statistic is worth. It still throws on
  cancellation — a `Task` cancelled mid-flight must not report success to whoever cancelled it
  (`CONTRACT.md` §7.5) — so the ordinary call is `try? await`.
- **`conn.reauth`.** A call that comes back `1101 TokenExpired` now renews the token on the open
  socket and retries once, instead of costing a full reconnect.
- **Typed methods for all of tiers 0, 1 and 2 — 51 endpoints**, grouped into namespaces named for
  the target prefix: `im.conn`, `im.msg`, `im.conv`, `im.user`, `im.media`, `im.push`, `im.friend`,
  `im.group`, `im.moderation`. Every method takes one request object named for the server DTO.
- **Tier 3, competitive parity — all 20 endpoints typed**, on the namespaces that already existed:
  `im.msg.pin` `unpin` `pins` `favourite` `unfavourite` `favourites` `burn` `search`
  `receiptDetail`; `im.conv.markUnread`; `im.user.setStatus`; `im.friend.setRemark`;
  `im.group.transfer` `applicationList` `handleApplication` `setRole` `mute` `muteMember`
  `setNickname` `announcement`.
  - Request types `ConversationMessageRequest`, `ReceiptDetailRequest`, `PageRequest`,
    `SearchMessagesRequest`, `MarkUnreadRequest`, `SetStatusRequest`, `SetRemarkRequest`,
    `TransferOwnerRequest`, `HandleApplicationRequest`, `SetRoleRequest`, `MuteGroupRequest`,
    `MuteMemberRequest`, `SetGroupNicknameRequest`, `AnnouncementRequest`; payload types
    `PinnedMessage`, `MessageReceipt`, `GroupApplication`. `msg.pins` reuses
    `ConversationIdRequest` and `group.applicationList` reuses `GroupCursorRequest`, defaulting to an
    empty `groupId` — "every group I manage".
  - **The message id leaves quoted.** `ConversationMessageRequest` and `ReceiptDetailRequest` keep
    an `Int64` property, so `ImMessage.messageId` goes straight in, and write it as a JSON string:
    the server's field is a `string`, and the gateway refuses a JSON number there with `1000`.
    The older `msg.*` requests now do the same; see **Fixed**.
  - **`im.group.setRole` throws before sending** anything but `.member` or `.admin` — `.owner` as
    `1008` (use `group.transfer`, the server's own answer), anything else as `1001` — because the
    server stores any other integer it is given, and `0` escapes a group-wide mute while `4` or more
    outranks the admins.
  - Destructive-when-absent fields carry no default: `SetRemarkRequest.remark`,
    `SetStatusRequest.status`, `SetGroupNicknameRequest.nickname`, `AnnouncementRequest.announcement`
    and `MuteMemberRequest.untilMs` clear or unmute when `nil`, and `HandleApplicationRequest.accept`
    and `SetRoleRequest.role` would reject or demote when absent. Each has to be written at the call
    site.
- Payload types: `UserProfile`, `PresenceState`, `MediaUploadTicket`, `Group`, `GroupMember`,
  `Friend`, `FriendRequest`, `BlockEntry`, `ReportReceipt`, `ConversationSetting`, `MessageOptions`,
  `PushConfig`, and the open enums `MuteMode`, `MessageStatus`, `MessagePriority`,
  `MultiLoginPolicy`, `GroupType`, `GroupRole`, `GroupJoinMode`, `GroupInviteMode`,
  `ApplicationStatus`.
- `ImError.requiresReauth`, the contract's name for the flag previously spelled `isAuthFailure`
  (which stays, deprecated for 2.0).
- The full `ImErrorCode` table, including `1204 PlanExpired`, `1405 EditWindowExpired`,
  `1508 JoinNeedsApproval` and `1701 FileTypeNotAllowed`.
- `ImSdk.version` and `ImSdk.contractVersion`, both surfaced in the `cv` handshake parameter.
- `LICENSE` (Apache-2.0). The express patent grant is what an enterprise buyer's legal review asks
  for and MIT does not answer.

### Changed

- **Source-breaking:** `ImClientOptions.init` now takes `cursorStore` and has no default for it.
- **Source-breaking:** `ImClient.init(connection:maxAutoRepairSeq:)` is now `init(connection:)`; the
  repair limits come from the options the connection was built with.
- **Source-breaking:** `ConversationView.muted` is now `MuteMode` rather than `Int`.
- `ImMessage` gained `threadRootId`, `options`, `status` and `expireAt`; `ConversationView` gained
  `peer`, `group` and `extensions`; `Page` gained `total`.
- The nine flat convenience methods (`send`, `sendText`, `history`, `sync`, `recall`, `react`,
  `setTyping`, `conversations`, `markRead`, `totalUnread`) now delegate to the namespaced surface and
  are deprecated for 2.0. They keep their existing signatures, including `totalUnread() -> Int`;
  `im.conv.unreadTotal()` returns the wire's `Int64`.
- `conv.list` no longer adopts cursors as a side effect. Only the resume path and live delivery touch
  cursor state.
- `cv` now carries this package's version alongside the host app's `clientVersion`.
- The transport compiles on the swift-corelibs platforms (`FoundationNetworking`, `noasync` locks),
  so the suite can run somewhere a Mac is not. No behavioural change on Apple platforms.

### Known gaps

- Tier 4 (34 endpoints: live rooms, service desk, the E2EE key directory, AI streaming and
  translation, scheduling, conversation folders) is reachable through `invoke(_:body:as:)` and is
  not yet typed.
- `evt.messageUpdate` with `kind: "burn"` — what `im.msg.burn` makes the server push — has no typed
  payload yet; read it through `events(_:as:)`.
