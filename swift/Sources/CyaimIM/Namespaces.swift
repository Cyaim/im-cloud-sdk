import Foundation

// The typed surface, grouped into namespaces named exactly for the target prefix. See
// sdk/CONTRACT.md §4.
//
// 107 flat methods on one object is not an API, it is a scroll bar. Grouping them by prefix means
// a reader who knows the endpoint name knows the call — `msg.cancelScheduled` is
// `im.msg.cancelScheduled(_:)` and nothing else, in every language, without a lookup table. The
// method name is the endpoint's method part with no synonyms, however much better a synonym might
// read: a synonym costs every future reader a lookup and costs the support engineer the ability to
// grep a bug report.
//
// Every method here is a thin wrapper over `ImConnection.request` / `.execute` — the same code path
// `invoke(_:body:as:)` uses. If a typed method were not a wrapper, the two paths would drift on
// timeouts, cancellation, error mapping and metrics, and the drift would be found by a customer.
//
// 命名空间按 target 前缀分组，方法名就是端点的方法名，不用同义词：同义词让每个读者多查一次，
// 也让支持工程师没法直接 grep 一份 bug 报告。

// MARK: - conn

/// `conn.*` — transport lifecycle. Tier 0: an SDK missing one of these is broken, not incomplete.
public struct ImConnNamespace: Sendable {
    let connection: ImConnection

    /// Keeps the session alive, and heals a cluster routing entry that has gone missing.
    ///
    /// You do not normally call this: ``ImConnection`` beats on the cadence the server reports and
    /// forces the socket down when a beat fails. It is here because a diagnostic screen wants
    /// ``HeartbeatResult/connectionId`` and ``HeartbeatResult/nodeId``, which turn a support ticket
    /// into one query against one node.
    @discardableResult
    public func heartbeat() async throws -> HeartbeatResult {
        try await connection.request("conn.heartbeat")
    }

    /// Swaps in a fresh token on the socket that is already open.
    ///
    /// Rarely called directly: when a request comes back `1101`, the SDK already asks
    /// ``ImClientOptions/tokenProvider`` for a replacement, calls this, and retries once. Call it
    /// yourself when your backend hands you a new token before the old one expires — a proactive
    /// renewal costs one round trip, whereas letting it expire costs a full reconnect, and on a
    /// flaky network a reconnect is exactly what a long-lived socket was avoiding.
    ///
    /// The renewed token must belong to the identity already on the socket; the server refuses a
    /// token for a different user with `1103` rather than letting a client change who it is.
    public func reauth(_ request: ReauthRequest) async throws {
        try await connection.execute("conn.reauth", body: request)
    }

    /// ``reauth(_:)`` for a bare token string.
    public func reauth(token: String) async throws {
        try await reauth(ReauthRequest(token: token))
    }

    /// What changed while we were away.
    ///
    /// ``ImClient`` runs this itself on every connect and reconnect, pages it to the end, and
    /// repairs what it reports — which is the only correct way to use it, and is why this method
    /// exists mainly for a tenant driving its own sync. Read §5 before calling it by hand: the
    /// paging and the `conversationCursor` advance both have failure modes that are silent.
    public func sync(_ request: ResumeRequest) async throws -> ResumeResult {
        try await connection.request("conn.sync", body: request)
    }
}

// MARK: - msg

/// `msg.*` — the message path.
public struct ImMsgNamespace: Sendable {
    let connection: ImConnection
    let client: ImClient?

    /// Sends a message. Idempotent on `clientMsgId`: retrying after a timeout returns the original
    /// result with ``SendMessageResult/deduplicated`` set rather than sending twice.
    @discardableResult
    public func send(_ request: SendMessageRequest) async throws -> SendMessageResult {
        let result: SendMessageResult = try await connection.request("msg.send", body: request)

        // Our own message occupies a seq like any other; recording it keeps the echo the server
        // pushes back from looking like a gap.
        client?.noteSent(result)
        return result
    }

    /// A contiguous seq window.
    ///
    /// The server clamps `limit` to 500 and reports ``SyncMessagesResult/hasMore`` — computed on the
    /// raw window, before per-user hidden messages are filtered out, so `messages` can be shorter
    /// than `limit` while `hasMore` is true. Page on `hasMore`, never on `messages.count`.
    ///
    /// Moves no cursor. The gap-repair loop has its own path through the same endpoint.
    public func sync(_ request: SyncMessagesRequest) async throws -> SyncMessagesResult {
        try await connection.request("msg.sync", body: request)
    }

    /// Pages backwards from a seq cursor.
    public func history(_ request: HistoryRequest) async throws -> Page<ImMessage> {
        try await connection.request("msg.history", body: request)
    }

    /// Withdraws a message for everyone. Peers get `evt.messageUpdate`, not a deletion, so a UI can
    /// replace the bubble in place instead of leaving a hole. Outside the tenant's
    /// `RecallWindowMinutes` this is `1403`.
    public func recall(_ request: RecallMessageRequest) async throws {
        try await connection.execute("msg.recall", body: request)
    }

    /// Hides messages for the caller — or, with `forEveryone`, removes them. Distinct from
    /// ``recall(_:)``, which withdraws and leaves a tombstone.
    public func delete(_ request: DeleteMessagesRequest) async throws {
        try await connection.execute("msg.delete", body: request)
    }

    /// Rewrites a message's content. Outside `EditWindowMinutes` this is `1405`.
    public func edit(_ request: EditMessageRequest) async throws {
        try await connection.execute("msg.edit", body: request)
    }

    /// Forwards messages to other conversations, one by one or bundled into a single `Merged`
    /// message. One result per target conversation.
    @discardableResult
    public func forward(_ request: ForwardMessagesRequest) async throws -> [SendMessageResult] {
        try await connection.request("msg.forward", body: request)
    }

    /// Adds or removes the caller's emoji reaction.
    public func react(_ request: ReactRequest) async throws {
        try await connection.execute("msg.react", body: request)
    }

    /// Per-message read marks. Distinct from the conversation-level pointer in
    /// ``ImConvNamespace/read(_:)`` — that one drives unread counts, this one drives "seen by".
    public func receipt(_ request: ReceiptRequest) async throws {
        try await connection.execute("msg.receipt", body: request)
    }

    /// Typing indicator. Never stored, never counted, dropped first when a connection is behind,
    /// and single chats only — broadcasting a keystroke to a large group is a fan-out that turns a
    /// chat product into a load generator.
    ///
    /// Gated by the tenant's `EnableTypingIndicator`; expect `1203` when it is off, and **keep
    /// calling** — the flag is runtime-settable and a client that latches it stays broken until the
    /// app restarts.
    public func typing(_ request: TypingRequest) async throws {
        try await connection.execute("msg.typing", body: request)
    }

    /// Pins a message to the conversation's shared board.
    ///
    /// A pin is an announcement, not a bookmark — one shared set per conversation — which is why it is
    /// permission-gated and ``favourite(_:)`` is not. In a single chat either participant may pin; in
    /// a group only the owner or an admin, while the deployment's `IM:Extras:GroupPinRequiresAdmin`
    /// is on (the default), otherwise `1504`. Chat rooms are `1008`; a system or assistant
    /// conversation is `1103` unless the caller has received something there.
    ///
    /// Refused with `1400` for a message that is not there (a missing or unparseable id included) or
    /// has been recalled, `1008` for an ephemeral one (sent with ``MessageOptions/expireIn``), and
    /// `1006` once the board holds `IM:Extras:MaxPinsPerConversation` pins (20 by default) — unpin one
    /// first. Pinning something already pinned succeeds and announces nothing.
    ///
    /// Success posts a notification message into the conversation (`contentType` 9, `content.code`
    /// 1514, `pinned: true`), sent as the operator, uncounted and unpushed. Its `content.messageId` is
    /// a **bare JSON number**, unlike every other message id on this wire — re-read ``pins(_:)``
    /// rather than trusting it across platforms.
    ///
    /// 置顶是全员共享的公告，群里受权限约束；成功后会在会话里发一条 1514 通知消息，
    /// 其中 content.messageId 是裸数字而非字符串，以 msg.pins 为准。
    public func pin(_ request: ConversationMessageRequest) async throws {
        try await connection.execute("msg.pin", body: request)
    }

    /// Takes a message off the board. The same permission rules as ``pin(_:)``.
    ///
    /// **A message that is not pinned succeeds silently** — a missing or unparseable id included — so
    /// a success here does not prove anything was removed. Notification 1514 with `pinned: false`
    /// goes out only when a pin really was removed and the message still exists.
    public func unpin(_ request: ConversationMessageRequest) async throws {
        try await connection.execute("msg.unpin", body: request)
    }

    /// The conversation's pinned board, newest pin first.
    ///
    /// **Not paged**: a plain array of at most `MaxPinsPerConversation` entries (20 by default), and
    /// `[]` when there are none. Any participant may read it — a group non-member is `1503`. Each
    /// ``PinnedMessage/brief`` is built at read time, so a message recalled after it was pinned shows
    /// as `"[Recalled]"`; pins whose message has since vanished are dropped and cleaned up.
    public func pins(_ request: ConversationIdRequest) async throws -> [PinnedMessage] {
        try await connection.request("msg.pins", body: request)
    }

    /// Bookmarks a message for the caller alone. Private and silent: nobody else can tell.
    ///
    /// Any participant may. `1400` for a message that is not there (a bad id included), `1008` for an
    /// ephemeral one, and `1006` once the caller holds `IM:Extras:MaxFavouritesPerUser` (5000 by
    /// default) — counted before the write, so re-favouriting at the cap fails too. A recalled message
    /// is **not** refused. Repeating it is safe, but it resets the timestamp and moves the favourite
    /// to the top.
    public func favourite(_ request: ConversationMessageRequest) async throws {
        try await connection.execute("msg.favourite", body: request)
    }

    /// Removes a bookmark. Always succeeds and is safe to repeat, and has no conversation access
    /// check — so it still works after the caller has left the group.
    public func unfavourite(_ request: ConversationMessageRequest) async throws {
        try await connection.execute("msg.unfavourite", body: request)
    }

    /// The caller's bookmarks across every conversation, as whole messages, newest favourite first.
    ///
    /// **Page until ``Page/nextCursor`` is `nil`**: a page can be short — even empty — while a cursor
    /// is still set, because favourites in conversations the caller can no longer read are hidden
    /// (and kept), and favourites whose message is gone or was deleted for the caller are removed
    /// as the page is read. Recalled messages **are** listed, with ``ImMessage/recalled`` set. The
    /// payload carries no favourite timestamp, and ``Page/total`` is never present.
    public func favourites(_ request: PageRequest = .init()) async throws -> Page<ImMessage> {
        try await connection.request("msg.favourites", body: request)
    }

    /// Starts the burn-after-reading countdown on a message the caller has just displayed.
    ///
    /// Only for messages sent with ``MessageOptions/expireIn`` > 0; anything else is `1008`. A missing
    /// or unparseable id is `1001` — the one call in this group that validates it — and a message
    /// that is not there is `1400`.
    ///
    /// **Safe to call for every rendered message.** The sender calling it on their own message
    /// succeeds and starts nothing. The first read by anyone else moves `expireAt` from
    /// `createTime + expireIn` to `now + expireIn`, and that is conversation-wide: in a group the
    /// first reader starts everyone's clock. Later calls succeed silently. Participants then get
    /// `evt.messageUpdate` (low priority) with `kind: "burn"` and the absolute `expireAt`; a message
    /// nobody reads still expires at `createTime + expireIn`.
    ///
    /// A courtesy between cooperating clients, not a defence: a recipient who already has the bytes
    /// can keep them.
    ///
    /// 阅后即焚是协作客户端之间的约定：已经拿到字节的接收方仍可留存。
    public func burn(_ request: ConversationMessageRequest) async throws {
        try await connection.execute("msg.burn", body: request)
    }

    /// Full-text search over the conversations the caller can see, newest first.
    ///
    /// **Off by default.** It needs the tenant's `EnableSearch` (default off, and forced off on an
    /// end-to-end-encrypted app) — `1203` otherwise — and the search add-on in the plan — `1204`
    /// otherwise. Do not latch either: both can change at runtime.
    ///
    /// **Rate limited per user, before either gate:** `1003` past `MaxSearchPerMinutePerUser` (30 by
    /// default) in a sliding minute, with no retry hint. Because the limiter runs first, calls against
    /// disabled search still spend the budget — debounce search-as-you-type.
    ///
    /// Recalled messages and messages the caller deleted for themselves are left out. Filters are
    /// applied after the index page (see ``SearchMessagesRequest``), so short or empty pages with
    /// `hasMore` true are normal: page on ``Page/nextCursor``. An index that takes longer than five
    /// seconds comes back as `1000`, not `1004` — retryable either way. ``Page/total`` may be absent.
    ///
    /// 默认关闭（EnableSearch、增值项两道闸），且限流在闸之前：关着也会消耗额度，输入即搜要防抖。
    public func search(_ request: SearchMessagesRequest) async throws -> Page<ImMessage> {
        try await connection.request("msg.search", body: request)
    }

    /// Who has read one message — the "seen by" list behind ``receipt(_:)``.
    ///
    /// Returns the stored receipt when there is one. Otherwise `1400` for a message that is not there
    /// (a bad id included), `1410` for one not sent with ``MessageOptions/needReceipt``, and else an
    /// empty receipt: no readers, `readCount` 0, the current `totalCount`. Access errors are `1001`,
    /// `1103` and `1503`.
    ///
    /// **Nothing caps or truncates this read.** The group-size limit applies to the *write*: in a
    /// group larger than the tenant's `ReceiptGroupMemberLimit` (100 by default) ``receipt(_:)``
    /// is refused with `1410`, so no reads are recorded and this returns an empty — or frozen —
    /// receipt. Read ``MessageReceipt/totalCount`` before comparing: it includes the sender.
    ///
    /// 这次读取本身没有上限；群人数上限卡的是 msg.receipt 的写入，超限群里这里只会是空的或停住的回执。
    public func receiptDetail(_ request: ReceiptDetailRequest) async throws -> MessageReceipt {
        try await connection.request("msg.receiptDetail", body: request)
    }

    // MARK: streaming (T4)

    /// Opens a stream — a reply that arrives a piece at a time — and pushes its opening `evt.stream`
    /// frame to every online member of the conversation, the producer's own connection included.
    ///
    /// A blank ``BeginStreamRequest/clientMsgId`` is filled in: the server makes none up, and it is
    /// the key the finished message is stored under. Every permission `msg.send` checks is checked
    /// here, at the opening (see ``BeginStreamRequest`` for the codes); `1003` is more than 60
    /// openings a minute. Then ``streamAppend(_:)`` the pieces and ``streamComplete(_:)`` or
    /// ``streamAbort(_:)`` within ``StreamHandle/idleTimeoutSeconds`` of the last call, or the server
    /// reaps the stream. ``StreamWriter`` holds the handle and the key for a producer. The types are
    /// in Stream.swift.
    ///
    /// 开流。clientMsgId 留空由这里补上（服务端不生成，最终消息以它为幂等键）。msg.send 的全部权限检查都在开流时做。
    public func streamBegin(_ request: BeginStreamRequest) async throws -> StreamHandle {
        try await connection.request("msg.streamBegin", body: request.keyed())
    }

    /// Sends the next piece; the server numbers it and pushes it as an `evt.stream` frame. See
    /// ``StreamAppendRequest`` for the refusals — `1401` leaves the stream open.
    public func streamAppend(_ request: StreamAppendRequest) async throws {
        try await connection.execute("msg.streamAppend", body: request)
    }

    /// Finishes the stream: the server stores it as one ordinary message, delivers that on
    /// `evt.message`, pushes the terminal `evt.stream` frame, and answers the message's identity.
    ///
    /// **Unlike ``send(_:)``, this does not move the delivered cursor.** The stored message is pushed
    /// to the producer's own connection too, and arrives on ``ImClient/messages()`` through the
    /// ordinary path — cursors, ordering and gap repair included. Moving the cursor here would make
    /// that delivery look like a duplicate and drop it.
    ///
    /// Can be refused as `msg.send` can (moderation, a webhook, the store), and the stream is consumed
    /// either way; a second complete answers `1002`.
    ///
    /// 与 send 不同，这里不推进 delivered 游标：存下来的消息也会推给生产者自己的连接，经普通路径进 messages()；
    /// 在这里推进游标会让那次投递被当成重复而丢掉。
    @discardableResult
    public func streamComplete(_ request: CompleteStreamRequest) async throws -> SendMessageResult {
        try await connection.request("msg.streamComplete", body: request)
    }

    /// Ends the stream without a message. Receivers get a terminal frame carrying the reason;
    /// nothing is stored. A second abort, or one after ``streamComplete(_:)``, answers `1002`.
    public func streamAbort(_ request: StreamAbortRequest) async throws {
        try await connection.execute("msg.streamAbort", body: request)
    }

    // MARK: scheduling (T4)

    /// Schedules a message for ``ScheduleRequest/sendAt`` and answers the outbox entry —
    /// ``ScheduledMessage/scheduleId`` to cancel it by, no ``ScheduledMessage/messageId`` yet.
    ///
    /// **Moves no cursor and delivers nothing.** When it fires, the message reaches the receiver as an
    /// ordinary `evt.message` with a real seq (and the sender's devices through the usual self-sync),
    /// on the first server sweep after `sendAt` (every 15 seconds by default). No event announces the
    /// schedule itself. **Not idempotent**: a retry after a lost reply schedules twice, so the SDK never
    /// retries it and leaves ``ScheduleRequest/clientMsgId`` alone. See ``ScheduleRequest`` for the
    /// refusals and limits; the types are in Schedule.swift.
    ///
    /// 不动游标、不投递任何东西：到点发出时，接收方经普通 evt.message 收到它（发送者的设备经通常的自同步），粒度是服务端扫描周期（默认 15 秒）。
    /// 不幂等：丢了答复就重试会建两条。
    @discardableResult
    public func schedule(_ request: ScheduleRequest) async throws -> ScheduledMessage {
        try await connection.request("msg.schedule", body: request)
    }

    /// The caller's outbox in `sendAt` order, earliest first: pending schedules **and** the ones
    /// settled in about the last 48 hours — sent, cancelled (``ScheduledMessage/error``
    /// "cancelled by sender") or failed. See ``ScheduledMessage`` for telling them apart. 20 a page by
    /// default, 100 at most. Page on ``Page/nextCursor``; ``Page/total`` is never present.
    ///
    /// 按 sendAt 从早到晚列出待发的，以及约 48 小时内已了结的（已发、已取消、失败）。
    public func scheduled(_ request: PageRequest = .init()) async throws -> Page<ScheduledMessage> {
        try await connection.request("msg.scheduled", body: request)
    }

    /// Cancels one of the caller's pending schedules. `1002` for an unknown id or someone else's;
    /// `1006` when there is nothing left to cancel — being sent, already cancelled, or already sent or
    /// failed, told apart only by the server's message. The entry stays listed, marked cancelled, for
    /// about 48 hours.
    public func cancelScheduled(_ request: ScheduleIdRequest) async throws {
        try await connection.execute("msg.cancelScheduled", body: request)
    }

    /// ``cancelScheduled(_:)`` for a bare schedule id.
    public func cancelScheduled(_ scheduleId: String) async throws {
        try await cancelScheduled(ScheduleIdRequest(scheduleId))
    }

    // MARK: translation (T4)

    /// Translates up to 50 messages of one conversation. Per-message failures come back inside the
    /// result (``TranslatedMessage/error``); the call itself fails only as a whole.
    ///
    /// **A deployment without translation refuses it as an ordinary ``ImError``**: `1204 PlanExpired`
    /// when the plan lacks the translation add-on, `1203 FeatureNotEnabled` when the plan has it but no
    /// provider is configured — both checked before the request itself, both carrying the server's
    /// message. Neither is retryable; do not latch either for longer than a session. The types are in
    /// Translation.swift.
    ///
    /// 没有翻译能力的部署以普通 ImError 拒绝：套餐不含翻译回 1204，含翻译但没配服务商回 1203，都带服务端的原话，都不可重试。
    public func translate(_ request: TranslateRequest) async throws -> TranslationResult {
        try await connection.request("msg.translate", body: request)
    }
}

// MARK: - conv

/// `conv.*` — the conversation list and the per-user state hanging off it.
public struct ImConvNamespace: Sendable {
    let connection: ImConnection

    /// The conversation list, incrementally.
    ///
    /// Pass the largest `updatedAt` you already hold as ``ListConversationsRequest/updatedAfter``.
    /// Getting that wrong is the difference between a one-second cold start and a thirty-second one
    /// for a heavy user.
    public func list(_ request: ListConversationsRequest = .init()) async throws -> Page<ConversationView> {
        try await connection.request("conv.list", body: request)
    }

    public func get(_ request: ConversationIdRequest) async throws -> ConversationView {
        try await connection.request("conv.get", body: request)
    }

    /// ``get(_:)`` for a bare conversation id.
    public func get(_ conversationId: String) async throws -> ConversationView {
        try await get(ConversationIdRequest(conversationId))
    }

    /// Moves the read cursor. Unread is derived server-side from `maxSeq - readSeq`, so this single
    /// write clears the badge on every other device of the same user.
    ///
    /// Unrelated to ``ImClient/commit(_:seq:)``: that one is about what your app has stored, this
    /// one is about what the user has read.
    public func read(_ request: ReadRequest) async throws {
        try await connection.execute("conv.read", body: request)
    }

    /// ``read(_:)`` for the two values it actually takes.
    public func read(_ conversationId: String, readSeq: Int64) async throws {
        try await read(ReadRequest(conversationId: conversationId, readSeq: readSeq))
    }

    /// The badge number.
    public func unreadTotal() async throws -> Int64 {
        try await connection.request("conv.unreadTotal")
    }

    /// Pin, mute, draft and tags in one call. Every field of ``ConversationSetting`` is optional:
    /// `nil` leaves it alone.
    public func setting(_ request: UpdateConversationSettingRequest) async throws {
        try await connection.execute("conv.setting", body: request)
    }

    /// Removes the conversation from the caller's list. Other participants are untouched.
    public func delete(_ request: ConversationIdRequest) async throws {
        try await connection.execute("conv.delete", body: request)
    }

    /// Clears the caller's own view of the history. Clearing for everyone destroys other people's
    /// data and is therefore a server-API operation, not a client one.
    public func clear(_ request: ConversationIdRequest) async throws {
        try await connection.execute("conv.clear", body: request)
    }

    /// Marks a conversation unread — or, with `unread: false`, clears the mark.
    ///
    /// It does not move `readSeq`, so the other side's receipts are unaffected. The mark shows up as
    /// ``ConversationView/manuallyUnread``, and ``ConversationView/unreadCount`` reads 1 where it would
    /// otherwise be 0. ``read(_:)``, ``delete(_:)`` and ``clear(_:)`` all clear it. Setting the value
    /// it already has succeeds and sends nothing; otherwise the caller's own devices get
    /// `evt.conversationUpdate` with kind `"unread"`. Access errors are `1001`, `1103` and `1503`.
    public func markUnread(_ request: MarkUnreadRequest) async throws {
        try await connection.execute("conv.markUnread", body: request)
    }

    // MARK: folders (T4)

    /// The caller's folders, all of them: **a plain array, not a ``Page``** (at most 20). Sort by
    /// ``ConversationFolder/order``, then name. Nothing is pushed when a folder changes on another
    /// device; call this again to pick it up. The types are in Folders.swift.
    ///
    /// 直接是数组而不是分页（至多 20 个）。别的设备改了文件夹不会推送，要重新调用。
    public func folders() async throws -> [ConversationFolder] {
        try await connection.request("conv.folders")
    }

    /// Creates a folder (no `folderId`) or replaces one, and answers it as stored — take the id from
    /// here. Every tag must already be on one of the caller's conversations (`1001` otherwise); see
    /// ``UpsertFolderRequest`` for the limits. A retried create makes a second folder.
    @discardableResult
    public func upsertFolder(_ request: UpsertFolderRequest) async throws -> ConversationFolder {
        try await connection.request("conv.upsertFolder", body: request)
    }

    /// Deletes a folder; the conversations and their tags stay. `1002` for one the caller does not
    /// have.
    public func deleteFolder(_ request: FolderIdRequest) async throws {
        try await connection.execute("conv.deleteFolder", body: request)
    }

    /// ``deleteFolder(_:)`` for a bare folder id.
    public func deleteFolder(_ folderId: String) async throws {
        try await deleteFolder(FolderIdRequest(folderId))
    }
}

// MARK: - user

/// `user.*` — profiles and presence.
public struct ImUserNamespace: Sendable {
    let connection: ImConnection

    /// The caller's own profile.
    public func me() async throws -> UserProfile {
        try await connection.request("user.me")
    }

    public func profile(_ request: UserIdRequest) async throws -> UserProfile {
        try await connection.request("user.profile", body: request)
    }

    /// ``profile(_:)`` for a bare user id.
    public func profile(_ userId: String) async throws -> UserProfile {
        try await profile(UserIdRequest(userId))
    }

    /// Resolves many peers at once — the call that stops a fifty-row conversation list from issuing
    /// fifty profile requests and taking two seconds to paint. At most 200 ids per call.
    public func batchProfile(_ request: UserIdsRequest) async throws -> [UserProfile] {
        try await connection.request("user.batchProfile", body: request)
    }

    /// Patches the caller's own profile. A client may only edit itself, and `banned`,
    /// `silencedUntil` and friends are stripped server-side whatever the body says.
    public func updateProfile(_ request: UpdateProfileRequest) async throws {
        try await connection.execute("user.updateProfile", body: request)
    }

    /// Online state for a set of users. Gated by the tenant's `EnablePresence`: expect `1203` when
    /// it is off, and do not latch it.
    public func presence(_ request: UserIdsRequest) async throws -> [PresenceState] {
        try await connection.request("user.presence", body: request)
    }

    /// Watches users for online/offline transitions, for `ttlSeconds`.
    ///
    /// Note the asymmetry: this call is **not** gated by `EnablePresence`, unlike ``presence(_:)``.
    /// A subscribe against a presence-disabled app succeeds and then never fires, so do not infer
    /// the tenant's flag from a successful subscribe.
    public func subscribePresence(_ request: SubscribePresenceRequest) async throws {
        try await connection.execute("user.subscribePresence", body: request)
    }

    public func unsubscribePresence(_ request: UserIdsRequest) async throws {
        try await connection.execute("user.unsubscribePresence", body: request)
    }

    /// Sets the caller's custom status — `"in a meeting"`, `"on call"` — or clears it with `nil`.
    ///
    /// **It lapses after seven days** and disappears silently; set it again on login if it should
    /// persist. Longer than 64 characters (after trimming) is `1001`, and `1005` means the presence
    /// store is down. Subscribers get `evt.presence` carrying ``PresenceState/customStatus``.
    ///
    /// Like ``subscribePresence(_:)`` this is **not** gated by `EnablePresence` — but reading it back
    /// through ``presence(_:)`` is, so a status set on a presence-disabled app is stored and unseen.
    public func setStatus(_ request: SetStatusRequest) async throws {
        try await connection.execute("user.setStatus", body: request)
    }
}

// MARK: - media

/// `media.*` — uploads go straight to object storage, never through the gateway.
public struct ImMediaNamespace: Sendable {
    let connection: ImConnection

    /// Issues a short-lived presigned PUT plus the object key to put in the message.
    ///
    /// The server chooses the key, so a client cannot write outside its own tenant and user prefix.
    /// A disallowed MIME type is `1701`; too large is `1702`.
    public func uploadTicket(_ request: UploadTicketRequest) async throws -> MediaUploadTicket {
        try await connection.request("media.uploadTicket", body: request)
    }

    /// Exchanges a stored object key for a short-lived download URL.
    ///
    /// Every reader signs their own link, which is what makes expiry and revocation possible at
    /// all — a URL baked into a message is public forever the moment it leaks.
    public func downloadUrl(_ request: DownloadUrlRequest) async throws -> String {
        try await connection.request("media.downloadUrl", body: request)
    }

    /// ``downloadUrl(_:)`` for a bare object key.
    public func downloadUrl(objectKey: String, lifetimeSeconds: Int = 3600) async throws -> String {
        try await downloadUrl(DownloadUrlRequest(objectKey: objectKey, lifetimeSeconds: lifetimeSeconds))
    }
}

// MARK: - push

/// `push.*` — offline push registration.
///
/// Most apps should call ``setToken(provider:token:language:)`` rather than ``register(_:)``: it
/// caches the token and re-registers on every connect, which is the behaviour the contract actually
/// requires. ``register(_:)`` and ``unregister()`` are the raw endpoints, for an app that wants to
/// drive the timing itself.
public struct ImPushNamespace: Sendable {
    let connection: ImConnection
    let client: ImClient?

    /// Hands the SDK a vendor token, and registers it now if the socket is open.
    ///
    /// `setToken` / `clearToken`, on `im.push`, is the pair — spelled the same way in all five SDKs
    /// (Unity: `SetToken` / `ClearToken`). It used to live on ``ImClient`` here and be called
    /// `setPushToken`, which meant a customer following another platform's README found nothing
    /// where they looked.
    ///
    /// **The host app owns token acquisition; the SDK owns token delivery.** APNs, Firebase and the
    /// OEM channels all hand the token to the application rather than to a library, so this is the
    /// seam: call it from `didRegisterForRemoteNotificationsWithDeviceToken` and once at startup,
    /// and the SDK registers on the next connect and on every connect after that.
    public func setToken(provider: String = ImPushProvider.apns, token: String, language: String? = nil) async {
        await client?.setPushTokenInternal(provider: provider, token: token, language: language)
    }

    /// ``setToken(provider:token:language:)`` for the `Data` APNs hands you.
    public func setToken(deviceToken: Data, provider: String = ImPushProvider.apns, language: String? = nil) async {
        await setToken(
            provider: provider,
            token: deviceToken.map { String(format: "%02x", $0) }.joined(),
            language: language
        )
    }

    /// Forgets the cached token without telling the server. A logout wants ``unregister()`` — or
    /// better ``ImClient/logout()``, which gets the order right — instead.
    public func clearToken() async {
        await client?.clearPushTokenInternal()
    }

    /// Records or refreshes this device's vendor token.
    ///
    /// Identity comes from the socket — this connection is the one place where app id, user id and
    /// device id are all already authenticated together, which is why "register a token against
    /// someone else's device" is not merely forbidden but unsayable.
    ///
    /// Idempotent, and cheap to repeat: the server debounces an unchanged token
    /// (`IM:Push:TokenRefreshDebounceMinutes`).
    public func register(_ request: RegisterPushTokenRequest) async throws {
        try await connection.execute("push.register", body: request)
        await client?.notePushRegistered(request)
    }

    /// Drops this device's registration. Other devices of the same user are untouched.
    ///
    /// **Call this before ``ImClient/disconnect()``, never after** — once the socket is gone there
    /// is no authenticated channel left to remove the token with, and only the tenant backend can
    /// then clean up via `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
    /// ``ImClient/logout()`` does both in the right order.
    public func unregister() async throws {
        try await connection.execute("push.unregister")
        await client?.notePushUnregistered()
    }

    /// Reports that this device's user tapped a notification.
    ///
    /// Call it from the tap handler — `userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// — and not from wherever the message gets rendered. What it feeds is the delivery funnel on
    /// the tenant's push screen: sent → delivered → clicked. APNs and the OEM channels do not
    /// report delivery at all, so on most deployments a tap is the only evidence a notification
    /// ever arrived, and the server credits delivery from it.
    ///
    /// Pass whatever the payload gave you; `messageId` from its `msgId` is the usual one. With
    /// neither field the server attributes this device's newest delivery, which is the right answer
    /// for a tap that opened the app without naming a message.
    ///
    /// **It swallows server failures and is never retried.** A miss is `2401 PushDeliveryNotFound`
    /// — the row expired after seven days, or the notification did not come from this platform —
    /// and neither is the app's fault nor anything a user could act on. This is the one call in the
    /// typed surface that swallows its failure, because it is a statistic: making a notification
    /// tap fail to collect one would cost more than the statistic is worth.
    ///
    /// **Cancellation is the one thing it does throw**, which is why the signature is `throws` at
    /// all. `CONTRACT.md` §7.5 rule 3 puts it plainly — cancellation is not a server outcome — and
    /// a `Task` that was cancelled mid-flight must not finish as though it succeeded, or the group
    /// that cancelled it never learns the child stopped. Written `async` without `throws`, as it
    /// first was, the rule is not merely unimplemented but unsatisfiable: there is no channel left
    /// to raise it on. Callers who genuinely want fire-and-forget write `try? await`, which is the
    /// ordinary Swift spelling of that intent and stays honest about what is being discarded.
    ///
    /// 尽力而为的统计：APNs 与厂商通道根本不回报送达，多数部署上「点击」是这条通知到过的唯一证据。
    /// 服务端失败不抛出；**唯一会抛出的是取消**——取消不是服务端结果（§7.5 规则 3），
    /// 一个中途被取消的 Task 不能装作成功完成，否则取消它的那一方永远不知道子任务停了。
    /// 写成不带 throws 的 async 时，这条规则不是「没实现」而是「无法实现」：没有任何通道能抛出它。
    /// 真心要 fire-and-forget 的调用方写 `try? await`——那是这个意图在 Swift 里的标准写法，
    /// 并且对「丢掉了什么」保持诚实。
    public func clicked(_ request: PushClickedRequest = .init()) async throws {
        do {
            try await connection.execute("push.clicked", body: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ImLog.warn(
                "push.clicked was not recorded: \(error). The delivery funnel is one tap short.",
                using: client?.warningSink
            )
        }
    }
}

// MARK: - friend

/// `friend.*` — contacts, requests and the blocklist.
public struct ImFriendNamespace: Sendable {
    let connection: ImConnection

    public func list(_ request: CursorRequest = .init()) async throws -> Page<Friend> {
        try await connection.request("friend.list", body: request)
    }

    /// Sends a friend request. Whether it lands as a request or an immediate friendship is the
    /// tenant's policy, not the client's.
    public func add(_ request: AddFriendRequest) async throws {
        try await connection.execute("friend.add", body: request)
    }

    /// Accepts or rejects a request that was sent to the caller.
    public func handleRequest(_ request: HandleFriendRequest) async throws {
        try await connection.execute("friend.handleRequest", body: request)
    }

    public func requestList(_ request: FriendRequestListRequest = .init()) async throws -> Page<FriendRequest> {
        try await connection.request("friend.requestList", body: request)
    }

    /// Removes a friend. Symmetric — the other side loses the entry too.
    public func delete(_ request: UserIdRequest) async throws {
        try await connection.execute("friend.delete", body: request)
    }

    public func blockList(_ request: CursorRequest = .init()) async throws -> Page<BlockEntry> {
        try await connection.request("friend.blockList", body: request)
    }

    /// Blocks a user.
    ///
    /// Not an optional feature: App Store review treats user blocking as mandatory for any app
    /// carrying user-generated content, so an app that ships without a path to this call ships
    /// without a path to approval.
    public func block(_ request: BlockRequest) async throws {
        try await connection.execute("friend.block", body: request)
    }

    public func unblock(_ request: UserIdRequest) async throws {
        try await connection.execute("friend.unblock", body: request)
    }

    /// Sets the caller's private remark and tags for a contact.
    ///
    /// **Read ``SetRemarkRequest`` first:** a `nil` remark *clears* it, while `nil` tags leave them
    /// alone. Somebody who is not a contact is `1302`. Only the caller's own devices hear about it,
    /// through `evt.friend` with action `"updated"`.
    public func setRemark(_ request: SetRemarkRequest) async throws {
        try await connection.execute("friend.setRemark", body: request)
    }
}

// MARK: - group

/// `group.*` — group lifecycle and membership, and the calls that administer a group: transfer,
/// roles, mutes, nicknames, the announcement and join applications.
///
/// Most administrative calls announce themselves in the group as a notification message
/// (`contentType` 9), so the other members' clients learn of them through the ordinary message
/// stream rather than a separate event. Where a method below says "notification N", N is that
/// message's `content.code`. **Those codes share their numbers with unrelated error codes** — 1511
/// is an ownership transfer in a notification and ``ImErrorCode/cannotOperateOwner`` in an error,
/// 1512 an announcement change and ``ImErrorCode/applicationNotFound`` — so never read one where you
/// expect the other.
///
/// 通知消息的 content.code 与错误码数值重叠（1511、1512 在两边含义不同），不要混读。
public struct ImGroupNamespace: Sendable {
    let connection: ImConnection

    /// Creates a group. Supply ``CreateGroupRequest/groupId`` yourself to make it idempotent.
    public func create(_ request: CreateGroupRequest) async throws -> Group {
        try await connection.request("group.create", body: request)
    }

    /// A group's metadata. A dismissed group still resolves, with
    /// ``Group/dismissed`` set, so an app can say so rather than showing a 404 where a conversation
    /// used to be.
    public func info(_ request: GroupIdRequest) async throws -> Group {
        try await connection.request("group.info", body: request)
    }

    /// ``info(_:)`` for a bare group id.
    public func info(_ groupId: String) async throws -> Group {
        try await info(GroupIdRequest(groupId))
    }

    /// Patches a group. Every field of ``UpdateGroupRequest`` is optional.
    public func update(_ request: UpdateGroupCommand) async throws {
        try await connection.execute("group.update", body: request)
    }

    /// Dismisses a group. Owner only.
    public func dismiss(_ request: GroupIdRequest) async throws {
        try await connection.execute("group.dismiss", body: request)
    }

    public func memberList(_ request: GroupCursorRequest) async throws -> Page<GroupMember> {
        try await connection.request("group.memberList", body: request)
    }

    /// The groups the caller belongs to.
    public func joined(_ request: CursorRequest = .init()) async throws -> Page<Group> {
        try await connection.request("group.joined", body: request)
    }

    /// Adds members. Subject to the group's `inviteMode`; `1510` when the caller may not.
    public func invite(_ request: GroupMembersRequest) async throws {
        try await connection.execute("group.invite", body: request)
    }

    /// Removes members. Admins and above; the owner cannot be removed (`1511`).
    public func kick(_ request: GroupMembersRequest) async throws {
        try await connection.execute("group.kick", body: request)
    }

    /// Leaves a group. The owner must transfer ownership first.
    public func quit(_ request: GroupIdRequest) async throws {
        try await connection.execute("group.quit", body: request)
    }

    /// Joins a group.
    ///
    /// With `joinMode == .needApproval` this lodges an application and comes back `1508`, which is
    /// a state to render, not a failure to report.
    public func join(_ request: JoinGroupRequest) async throws {
        try await connection.execute("group.join", body: request)
    }

    /// Hands the group to another member. **Owner only** (`1504`).
    ///
    /// Not repeatable: a retry after it succeeded is `1504`, because the caller is no longer the
    /// owner. The outgoing owner becomes a plain member, **not** an admin — have the new owner call
    /// ``setRole(_:)`` if that is what you want. Transferring to yourself is `1001`; to a non-member,
    /// `1503`. Announced with notification 1511.
    public func transfer(_ request: TransferOwnerRequest) async throws {
        try await connection.execute("group.transfer", body: request)
    }

    /// Join applications, newest first.
    ///
    /// With no group — the default, an empty ``GroupCursorRequest/groupId`` — it lists across every
    /// group the caller manages, looking only at the first 200 groups they have joined. With a group,
    /// the caller must be its owner or an admin (`1504`).
    ///
    /// **It returns every status, not only pending**: filter on ``GroupApplication/status`` for a
    /// "waiting for you" list. ``GroupCursorRequest/limit`` 1…200 is kept; anything else becomes 50.
    ///
    /// 返回所有状态而不只是待处理的；「等你处理」要自己筛 pending。
    public func applicationList(
        _ request: GroupCursorRequest = GroupCursorRequest(groupId: "")
    ) async throws -> Page<GroupApplication> {
        try await connection.request("group.applicationList", body: request)
    }

    /// Accepts or rejects one join application. Owner or admin (`1504`).
    ///
    /// `1512` when there is no such application, `1006` when it was already handled. A rejection is
    /// stored with its reason and **tells nobody**. An acceptance adds the member and announces
    /// notification 1513 — unless the group is full (`1502`), in which case the application stays
    /// pending.
    public func handleApplication(_ request: HandleApplicationRequest) async throws {
        try await connection.execute("group.handleApplication", body: request)
    }

    /// Promotes a member to admin, or demotes an admin to member. **Owner only** (`1504`).
    ///
    /// Only ``GroupRole/member`` and ``GroupRole/admin`` are sent. ``GroupRole/owner`` throws `1008`
    /// here — the code the server gives it, with the same advice: ownership moves with
    /// ``transfer(_:)``. Any other value throws `1001`. Both are thrown before a frame is written,
    /// because the server stores any other integer it is given; see ``SetRoleRequest`` for why that
    /// matters.
    ///
    /// A non-member target is `1503`; the owner as target — the owner calling on themselves included
    /// — is `1511`. Setting the role a member already has succeeds and announces nothing; otherwise
    /// notification 1507 (made admin) or 1508 (anything else) goes out.
    public func setRole(_ request: SetRoleRequest) async throws {
        guard request.role == .member || request.role == .admin else {
            if request.role == .owner {
                throw ImError(
                    code: .unsupportedOperation,
                    message: "group.setRole cannot make an owner; ownership moves with group.transfer",
                    target: "group.setRole"
                )
            }

            throw ImError(
                code: .invalidArgument,
                message: "group.setRole takes GroupRole.member or GroupRole.admin, not \(request.role.rawValue)",
                target: "group.setRole"
            )
        }

        try await connection.execute("group.setRole", body: request)
    }

    /// Mutes or unmutes the whole group. Owner or admin (`1504`); the owner and admins can still send
    /// while it is on, and everyone else gets `1505`.
    ///
    /// **Read ``MuteGroupRequest`` first:** `mute` defaults to true, and **a past `untilMs` mutes
    /// indefinitely**, not "until a moment already gone" — unmuting is `mute: false`. Every call
    /// writes and announces notification 1509, even when nothing changed.
    ///
    /// 过去的 untilMs 是「无限期」而不是「解除」；每次调用都会写入并发 1509 通知，哪怕没有变化。
    public func mute(_ request: MuteGroupRequest) async throws {
        try await connection.execute("group.mute", body: request)
    }

    /// Mutes one member until a time, or unmutes them. Owner or admin (`1504`).
    ///
    /// **A `nil` or past `untilMs` unmutes** — the opposite reading from ``mute(_:)`` — and there is
    /// no indefinite member mute. A non-member target is `1503`, the owner `1511`, yourself `1008`,
    /// and an admin muting another admin `1504`. The muted member's sends then fail with `1506`.
    /// Announced with notification 1510.
    public func muteMember(_ request: MuteMemberRequest) async throws {
        try await connection.execute("group.muteMember", body: request)
    }

    /// Sets a member's in-group nickname — the caller's own with no `userId`, which any member may
    /// do. Someone else's needs owner or admin **and** outranking them (`1504` / `1511`); a
    /// non-member target is `1503`. Past 64 characters it is silently truncated. Announced with
    /// notification 1506, whose `fields` spells the field `"Nickname"`, capitalised.
    public func setNickname(_ request: SetGroupNicknameRequest) async throws {
        try await connection.execute("group.setNickname", body: request)
    }

    /// Replaces the group announcement; `nil` or blank clears it. Owner or admin (`1504`).
    ///
    /// Past 4096 characters it is silently truncated. Sets ``Group/announcementUpdatedAt``, and every
    /// call announces notification 1512 — even when the text did not change.
    public func announcement(_ request: AnnouncementRequest) async throws {
        try await connection.execute("group.announcement", body: request)
    }
}

// MARK: - moderation

/// `moderation.*` — what an end user can do about content.
public struct ImModerationNamespace: Sendable {
    let connection: ImConnection

    /// Reports a user, optionally naming a message.
    ///
    /// The other half of ``ImFriendNamespace/block(_:)``. App Store review asks for both a way to
    /// block an abusive user and a way to report objectionable content, so an app that ships one
    /// without the other still has nowhere to point the reviewer.
    ///
    /// **The reporter is the connection.** ``SubmitReportRequest`` has no field for it and must not
    /// grow one: a report filed in somebody else's name is both a way to get them banned and a way
    /// to poison the count a moderator decides on.
    ///
    /// The target and the category are validated — reporting yourself is `1001`, and so is a
    /// category the server does not know. A report naming a message that has already been deleted
    /// is accepted on purpose: it is the report a moderator most wants, and refusing it would turn
    /// the platform's own retention into a way to escape moderation.
    ///
    /// What comes back is a receipt, not the row. There is no state to poll and no way for the
    /// reporter to read what a moderator decided, which is deliberate.
    public func report(_ request: SubmitReportRequest) async throws -> ReportReceipt {
        try await connection.request("moderation.report", body: request)
    }
}

// MARK: - diag

/// `diag.*` — this device's half of troubleshooting.
///
/// **Ordinary applications never call these.** ``ImClient`` drives both: it asks once after every
/// connect and answers whatever is waiting. They are typed because this SDK's rule is that every
/// endpoint has a typed method — a capability reachable only through a raw invoke is one a support
/// engineer cannot find.
///
/// See `ADR-003` for why the log store belongs to the integrating application, and
/// ``ImLogStore`` for what an integrator who supplies none still gets.
public struct ImDiagNamespace: Sendable {
    let connection: ImConnection

    /// Open log requests for this device, each with a freshly signed upload target.
    ///
    /// **Once per connect, never on a timer.** Requests are raised by a person looking at a support
    /// ticket, so the rate is at most one every few days; polling would turn a human-paced feature
    /// into background traffic on every handset a tenant has.
    /// 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
    public func logRequests() async throws -> [PendingDeviceLog] {
        try await connection.request("diag.logRequests", as: [PendingDeviceLog].self)
    }

    /// Reports what happened to one request — a bundle, or why there is none.
    ///
    /// **A refusal is an answer and must be sent.** Silence is indistinguishable from a device that
    /// never received the request, and the two send a support engineer in opposite directions: wait
    /// for the customer to open the app, or look at why this build cannot comply.
    /// 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别，而两者要查的方向相反。
    public func logUploaded(_ answer: DeviceLogAnswer) async throws {
        try await connection.execute("diag.logUploaded", body: answer)
    }
}

// MARK: - desk (T4)

/// `desk.*` — the customer-service desk, from both sides of it (T4).
///
/// **Two audiences, one namespace, and which one you are is decided by the session rather than by
/// the method you call.** ``request(_:)`` and ``rate(_:)`` are the customer's; ``accept(_:)``,
/// ``transfer(_:)``, ``status(_:)``, ``queue()``, ``canned(_:)`` and ``suggest(_:)`` are an
/// agent's; ``close(_:)`` is either side's. The server checks the caller against the session's
/// holder on every one of them, so an agent-shaped call from a customer is `1103`.
///
/// **The conversation is not here.** Everything a customer and an agent say to each other is an
/// ordinary single chat between the customer and the desk account, sent with `msg.send` and read
/// with `msg.history`. These nine verbs only move the *assignment* around it — which is why an
/// in-app support screen is a chat screen plus ``request(_:)`` and ``rate(_:)``.
///
/// **A deployment older than this build answers `1008 UnsupportedOperation`**; neither retrying nor
/// re-authenticating changes it. The types are in Desk.swift.
///
/// 两种角色共用一个命名空间，「你是谁」由会话判定。聊天不在这里：这九个动词只负责「谁来接」。
public struct ImDeskNamespace: Sendable {
    let connection: ImConnection

    /// Asks for a person, and returns the session — a new one, or the caller's own open one.
    ///
    /// Idempotent server-side, so the button needs no guard. ``DeskSession/state`` says what
    /// happened: `.queued` means waiting, `.assigned` means an idle agent took it in the same call.
    public func request(_ request: DeskRequest = DeskRequest()) async throws -> DeskSession {
        try await connection.request("desk.request", body: request)
    }

    /// Takes a session: the named one, or the next one waiting when no id is given.
    ///
    /// An empty queue is `1002`, which a workbench polling for work should read as "nothing
    /// waiting"; being at capacity is `1205`, which is **not** retryable — finish a session first.
    /// 队列为空答 1002；已满答 1205，解法是先结掉一个，不是重试。
    public func accept(_ request: DeskAcceptRequest = DeskAcceptRequest()) async throws -> DeskSession {
        try await connection.request("desk.accept", body: request)
    }

    /// Hands a session on — to a named agent, a skill queue, or back to its own queue. Build the
    /// request with ``DeskTransferRequest/agent(sessionId:agentId:note:)``,
    /// ``DeskTransferRequest/skill(sessionId:skill:note:)`` or
    /// ``DeskTransferRequest/queue(sessionId:note:)``. Only an assigned session can be transferred
    /// (`1006` otherwise), and only by its holder or a supervisor (`1103`).
    public func transfer(_ request: DeskTransferRequest) async throws {
        try await connection.execute("desk.transfer", body: request)
    }

    /// Ends a session; either side may. **Closing an already-closed session succeeds**, which is what
    /// makes a retry after a timeout safe. Leaving ``DeskCloseRequest/inviteRating`` `nil` still
    /// invites.
    public func close(_ request: DeskCloseRequest) async throws {
        try await connection.execute("desk.close", body: request)
    }

    /// Sets this agent's availability and renews their heartbeat. **Call it on a timer**, not only
    /// when the agent changes status: the roster drops an agent whose console stopped talking.
    /// 要按心跳周期调用：名册会把不再说话的坐席回收并重排它的会话。
    public func status(_ request: DeskStatusRequest) async throws {
        try await connection.execute("desk.status", body: request)
    }

    /// The queue as a supervisor watches it. Takes no arguments — it is the whole desk.
    /// ``DeskQueueView/avgFirstResponseSeconds`` is `nil` when nothing in the window is measurable.
    public func queue() async throws -> DeskQueueView {
        try await connection.request("desk.queue", as: DeskQueueView.self)
    }

    /// The customer rates a finished session, 1–5, in reply to the 1807 notice. Accepted once, only
    /// inside the rating window (`1006` otherwise); `1203` when ratings are switched off.
    public func rate(_ request: DeskRateRequest) async throws {
        try await connection.execute("desk.rate", body: request)
    }

    /// The canned replies in this centre's phrasebook. Read-only here.
    ///
    /// **Pass your own member id as ``DeskCannedRequest/ownerMemberId``** for "shared, plus mine":
    /// leaving it `nil` lists every member's personal entries, because the server does not narrow
    /// by caller on this route.
    public func canned(_ request: DeskCannedRequest = DeskCannedRequest()) async throws -> [DeskCannedReply] {
        try await connection.request("desk.canned", body: request, as: [DeskCannedReply].self)
    }

    /// Up to three model-written drafts for the session this agent holds. Nothing here reaches the
    /// customer. `1203` when the tenant has configured no LLM; `1005` when the model did not answer.
    public func suggest(_ request: DeskSuggestRequest) async throws -> [String] {
        try await connection.request("desk.suggest", body: request, as: [String].self)
    }
}

// MARK: - room (T4)

/// `room.*` — chat rooms: the live-stream comment wall, the broadcast lobby (T4).
///
/// **A room trades every delivery guarantee for scale, and the client has to know it.** Its messages
/// are not stored per user, not pushed offline and carry `seq` **0**: they arrive on
/// ``ImClient/messages()`` as ordinary ``ImMessage``s with `conversationId` `r_<roomId>`, and
/// ``ImClient`` keeps them out of cursors and gap repair entirely — a dropped frame is gone, and there
/// is no range to ask for. Do not commit them; ``ImClient/commit(_:seq:)`` ignores a seq of 0.
///
/// **Rooms are created by the tenant's backend** (`POST /v1/rooms`), never from a device. **Joining
/// belongs to the connection**: after a reconnect, send ``join(_:)`` again for every room still on
/// screen — the SDK does not do it for you. Mutes, kicks and the room's destruction arrive on
/// ``ImClient/roomEvents()``.
///
/// **A deployment older than this build answers `1008 UnsupportedOperation`**; neither retrying nor
/// re-authenticating changes it. The types are in Room.swift.
///
/// 聊天室用全部投递保证换规模：消息不按人存储、不发离线推送、seq 为 0，ImClient 让它们完全绕开游标与补洞。
/// 聊天室由租户后端创建；入房属于连接，重连后要重新 join，SDK 不代劳。
public struct ImRoomNamespace: Sendable {
    let connection: ImConnection

    /// Enters a room on this connection and returns it, the head count, and its last few messages.
    ///
    /// `1600 RoomNotFound` for a room that does not exist or was destroyed; `1601 RoomFull` when
    /// ``ChatRoom/maxOnline`` connections are already in.
    public func join(_ request: RoomIdRequest) async throws -> RoomJoinResult {
        try await connection.request("room.join", body: request)
    }

    /// Leaves a room on this connection. Leaving one you are not in succeeds.
    public func quit(_ request: RoomIdRequest) async throws {
        try await connection.execute("room.quit", body: request)
    }

    /// Says something to the room. The result's `seq` is **always 0** and its `conversationId` is
    /// `r_<roomId>`; it moves no cursor, which is why this does not go through `msg.send`.
    ///
    /// A blank ``RoomMessage/clientMsgId`` is filled in and a ``RoomMessage/sendTime`` of 0 or below
    /// stamped. Refusals: `1602 NotInRoom` (not joined, or kicked), `1603 RoomMuted` (the whole room
    /// is muted and you are neither owner nor admin), `1506 MemberMuted`, `1401 MessageTooLong`,
    /// `1402 ModerationRejected`, `1003 RateLimited` (the room is over its rate).
    ///
    /// 结果的 seq 恒为 0，不动游标，所以不走 msg.send。
    @discardableResult
    public func send(_ request: RoomSendRequest) async throws -> SendMessageResult {
        var outgoing = request
        if outgoing.message.clientMsgId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outgoing.message.clientMsgId = ClientMessageId.generate()
        }
        if outgoing.message.sendTime <= 0 {
            outgoing.message.sendTime = ImClock.nowMilliseconds()
        }
        return try await connection.request("room.send", body: outgoing)
    }

    /// Connections in the room right now, cluster-wide. A bare number. **An unknown room answers 0**,
    /// not `1600`: this is polled for a viewer counter and the server skips the existence check.
    public func onlineCount(_ request: RoomIdRequest) async throws -> Int64 {
        try await connection.request("room.onlineCount", body: request)
    }

    /// **A sample** of the user ids present, not the full list: the server never enumerates a large
    /// room exactly. Page on ``Page/hasMore`` / ``Page/nextCursor``; a page can be short, or empty,
    /// with more to come. An unknown room is an empty sample, not `1600`.
    public func memberList(_ request: RoomCursorRequest) async throws -> Page<String> {
        try await connection.request("room.memberList", body: request)
    }

    /// Mutes the room or one member until a time — or, with ``RoomMuteRequest/untilMs`` `nil` or
    /// past, lifts the mute. Owner or admins only (`1103`); never the owner (`1511`).
    public func mute(_ request: RoomMuteRequest) async throws {
        try await connection.execute("room.mute", body: request)
    }

    /// Removes a member from the room. Owner or admins only (`1103`); never the owner (`1511`).
    public func kick(_ request: RoomKickRequest) async throws {
        try await connection.execute("room.kick", body: request)
    }
}

// MARK: - keys (T4)

/// `keys.*` — the end-to-end encryption key directory (T4): publishing this device's public keys,
/// and fetching a peer's so a session can be opened.
///
/// **The SDK performs no cryptography.** It moves opaque, standard-base64 strings the application's
/// own crypto library produced, unchanged, and never logs them; generating keys, signing the signed
/// prekey, running X3DH and encrypting messages are the application's. The types are in Keys.swift.
///
/// **Writes speak only for the connected device** (publish, upload); reads name their target.
/// **Callable whether or not the app's `e2ee.enabled` is set** — that switch does not gate the
/// directory. **No event is pushed** for a revoked device, an identity change or a low pool.
///
/// SDK 不做任何加密运算，只原样搬运应用自己算出的字符串，也不记录它们。写操作只能替当前连接的设备说话，读操作在请求体里点名目标。
/// 不论 e2ee.enabled 开没开都能调用；吊销、身份变更、池子见底都不推送事件。
public struct ImKeysNamespace: Sendable {
    let connection: ImConnection

    /// Publishes this device's identity key and signed prekey, with an optional first batch of
    /// one-time prekeys. **Replaces** identity, signed prekey and algorithm; **keeps** the one-time
    /// pool and appends to it (a changed identity key deletes the old pool first). The device and
    /// platform are the connection's. See ``PublishKeysRequest`` for every refusal.
    ///
    /// 替换身份公钥、签名预密钥与算法，保留一次性池并追加；设备与平台取自连接。
    public func publish(_ request: PublishKeysRequest) async throws {
        try await connection.execute("keys.publish", body: request)
    }

    /// Appends one-time prekeys to the connected device's pool (at most 100 per call, 100 held).
    /// `1002` before this device has published. Call it when ``remaining(_:)`` runs low.
    public func upload(_ request: UploadOneTimeKeysRequest) async throws {
        try await connection.execute("keys.upload", body: request)
    }

    /// ``upload(_:)`` for the one-field case.
    public func upload(_ keys: [OneTimePreKey]) async throws {
        try await upload(UploadOneTimeKeysRequest(keys: keys))
    }

    /// One-time prekeys left on one of the caller's own devices — the connected one by default (an
    /// empty body). An unknown device is 0, not an error. Nothing is pushed when the pool runs low;
    /// ask on launch. A bare number on the wire.
    public func remaining(_ request: RemainingKeysRequest = RemainingKeysRequest()) async throws -> Int {
        try await connection.request("keys.remaining", body: request)
    }

    /// ``remaining(_:)`` for one named device of the caller's own.
    public func remaining(_ deviceId: String) async throws -> Int {
        try await remaining(RemainingKeysRequest(deviceId: deviceId))
    }

    /// Fetches a bundle to open a session with one device of ``ClaimBundleRequest/userId``.
    ///
    /// **A write dressed as a read: it consumes one one-time prekey**, atomically and first-in
    /// first-out, so the device's ``remaining(_:)`` drops by one. **Never retry it as if it were
    /// idempotent, and never prefetch**: a call whose reply was lost (a `1004` timeout, which
    /// ``ImError/isRetryable`` calls retryable in general) may already have spent a key, and a retry
    /// spends the next; a prefetched bundle spends one a real first contact needed. Use a bundle for
    /// one session only — two sessions opened from the same one-time prekey get no forward secrecy
    /// from it. The SDK never reissues it, beyond the one renewal on `1101 TokenExpired` that every
    /// call gets (a call refused for its token did not run). When the pool is empty the claim **still
    /// succeeds**, with ``PreKeyBundle/oneTimePreKey`` `nil`. Claiming one's own device is allowed and
    /// drains one's own pool.
    ///
    /// `1001` for a blank user or device id; `1002` "device has published no keys" (also for an
    /// unknown user, and after a revoke); `1005` when the directory is unavailable.
    ///
    /// 看起来是读，实质是写：每次领取原子地消耗一个一次性预密钥（先进先出），余量减一。不能当幂等请求重试，也不能预取。
    /// 池子空了照样成功，只是 oneTimePreKey 为 nil。
    public func claim(_ request: ClaimBundleRequest) async throws -> PreKeyBundle {
        try await connection.request("keys.claim", body: request)
    }

    /// ``claim(_:)`` for the two-field case. Consumes a one-time prekey like the other overload.
    public func claim(userId: String, deviceId: String) async throws -> PreKeyBundle {
        try await claim(ClaimBundleRequest(userId: userId, deviceId: deviceId))
    }

    /// Every device of a user that has keys published — the caller's own by default (an empty body) —
    /// in no particular order: one ciphertext per device in this list. A bare array on the wire; an
    /// unknown user is an empty list. No signed prekey here; ``claim(_:)`` has it.
    public func devices(_ request: DeviceKeysRequest = DeviceKeysRequest()) async throws -> [DeviceKeyInfo] {
        try await connection.request("keys.devices", body: request, as: [DeviceKeyInfo].self)
    }

    /// ``devices(_:)`` for one named user.
    public func devices(_ userId: String) async throws -> [DeviceKeyInfo] {
        try await devices(DeviceKeysRequest(userId: userId))
    }

    /// Forgets one of the caller's own devices: its record, its pool, its place in ``devices(_:)``.
    /// After it, ``claim(_:)`` for that device is `1002` and both sides' safety numbers change;
    /// existing sessions are the clients' business, and **no event** tells peers. The id is required
    /// (`1001` when blank, never defaulted); an id the caller does not have **succeeds**. Revoking the
    /// connected device is allowed.
    ///
    /// 吊销调用者自己的一台设备。设备 id 必填、不会默认成当前设备；吊销不存在的设备照样成功。不推送任何事件。
    public func revoke(_ request: RevokeDeviceRequest) async throws {
        try await connection.execute("keys.revoke", body: request)
    }

    /// ``revoke(_:)`` for the one-field case.
    public func revoke(_ deviceId: String) async throws {
        try await revoke(RevokeDeviceRequest(deviceId: deviceId))
    }

    /// The fingerprint two users read to each other to confirm nobody is in the middle: 12 groups of
    /// 5 digits separated by single spaces, **the same from either side**. It is built from both user
    /// ids and every identity key of each, so it changes when a device is added or revoked or an
    /// identity key changes — not on signed-prekey rotation or one-time-key use. `1001` for a blank
    /// peer; `1002` when either side has no devices published. A bare string on the wire.
    ///
    /// 两端互读核对的指纹：12 组 5 位数字、单个空格分隔，两边算出来一样。增删设备或身份公钥变更时改变，轮换签名预密钥或消耗一次性预密钥不变。
    public func safetyNumber(_ request: SafetyNumberRequest) async throws -> String {
        try await connection.request("keys.safetyNumber", body: request)
    }

    /// ``safetyNumber(_:)`` for the one-field case.
    public func safetyNumber(_ peerUserId: String) async throws -> String {
        try await safetyNumber(SafetyNumberRequest(peerUserId: peerUserId))
    }
}
