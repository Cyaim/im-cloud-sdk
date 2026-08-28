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
}

// MARK: - group

/// `group.*` — group lifecycle and membership.
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
