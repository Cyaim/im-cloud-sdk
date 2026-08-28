import Foundation
import Testing

@testable import CyaimIM

/// The typed surface for tiers 0, 1 and 2, from `sdk/CONTRACT.md` §3 and §4.
///
/// The point of these is coverage rather than behaviour: a customer choosing a platform reads a
/// feature matrix, and "typed on Swift, `invoke()` on Swift" is the row that loses the deal. So the
/// central test walks every endpoint in the three tiers and asserts that a typed method exists, is
/// named for the endpoint, and puts the endpoint's own name on the wire.
///
/// 这一组测的是覆盖面而不是行为：客户按功能矩阵选平台，"这个端点在 Swift 上只能 invoke"就是丢单的那一行。
@Suite("Typed surface (T0, T1, T2)")
struct TypedSurfaceTests {

    // MARK: - Canned payloads

    private static func userProfile(_ userId: String = "bob") -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "userId": .string(userId),
            "nickname": .string("Bob"),
            "avatar": .string("app-test/u/bob.png"),
            "gender": .int(1),
            "banned": .bool(false),
            "createdAt": .int(1_700_000_000_000),
            "updatedAt": .int(1_700_000_000_001),
            "extensions": .object(["team": .string("ops")]),
        ])
    }

    private static func group(_ groupId: String = "g-1") -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "groupId": .string(groupId),
            "type": .int(1),
            "name": .string("Ops"),
            "ownerId": .string("alice"),
            "memberCount": .int(4),
            "maxMemberCount": .int(500),
            "joinMode": .int(1),
            "inviteMode": .int(0),
            "muteAll": .bool(false),
            "dismissed": .bool(false),
            "createdAt": .int(1_700_000_000_000),
            "updatedAt": .int(1_700_000_000_001),
        ])
    }

    private static func groupMember() -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "groupId": .string("g-1"),
            "userId": .string("bob"),
            "role": .int(2),
            "nickname": .string("Bobby"),
            "joinTime": .int(1_700_000_000_000),
        ])
    }

    private static func friend() -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "userId": .string("alice"),
            "friendUserId": .string("bob"),
            "remark": .string("Bob from ops"),
            "tags": .array([.string("work")]),
            "addTime": .int(1_700_000_000_000),
        ])
    }

    private static func friendRequest() -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "fromUserId": .string("carol"),
            "toUserId": .string("alice"),
            "greeting": .string("hi"),
            "status": .int(0),
            "createdAt": .int(1_700_000_000_000),
        ])
    }

    private static func blockEntry() -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "userId": .string("alice"),
            "blockedUserId": .string("mallory"),
            "createdAt": .int(1_700_000_000_000),
            "reason": .string("spam"),
        ])
    }

    private static func presence() -> JSONValue {
        .object([
            "userId": .string("bob"),
            "online": .bool(true),
            "platforms": .array([.int(1), .int(5)]),
            "lastSeen": .int(1_700_000_000_000),
            "customStatus": .string("in a meeting"),
        ])
    }

    private static func uploadTicket() -> JSONValue {
        .object([
            "objectKey": .string("app-test/alice/2026/photo.jpg"),
            "uploadUrl": .string("https://storage.example.com/put?sig=abc"),
            "downloadUrl": .string("https://storage.example.com/get?sig=abc"),
            "formFields": .object(["x-amz-acl": .string("private")]),
            "expiresAt": .int(1_700_000_003_600),
        ])
    }

    private static func sendResult(seq: Int64 = 1) -> JSONValue {
        .object([
            "messageId": .int(5_000 + seq),
            "seq": .int(seq),
            "conversationId": .string("s_alice_bob"),
            "clientMsgId": .string("cm-\(seq)"),
            "createTime": .int(1_700_000_000_000),
            "deduplicated": .bool(false),
            "contentModified": .bool(false),
        ])
    }

    private static func page(_ items: [JSONValue], hasMore: Bool = false, nextCursor: String? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["items": .array(items), "hasMore": .bool(hasMore)]
        if let nextCursor { body["nextCursor"] = .string(nextCursor) }
        return .object(body)
    }

    /// Replies to every T0–T2 endpoint with a payload of the right shape.
    private static func fullGateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.heartbeat", "conn.sync":
                _ = MockGateway.answerHousekeeping(request, channel)

            case "msg.send":
                channel.reply(to: request, data: sendResult(seq: 1))
            case "msg.forward":
                channel.reply(to: request, data: .array([sendResult(seq: 2)]))
            case "msg.sync":
                channel.reply(to: request, data: syncPayload(conversationId: "s_alice_bob", range: 1 ... 2))
            case "msg.history":
                channel.reply(to: request, data: page([messagePayload(conversationId: "s_alice_bob", seq: 1)]))

            case "conv.list":
                channel.reply(to: request, data: page([conversationPayload("s_alice_bob", maxSeq: 9)]))
            case "conv.get":
                channel.reply(to: request, data: conversationPayload("s_alice_bob", maxSeq: 9))
            case "conv.unreadTotal":
                channel.reply(to: request, data: .int(12))

            case "user.me", "user.profile":
                channel.reply(to: request, data: userProfile())
            case "user.batchProfile":
                channel.reply(to: request, data: .array([userProfile("bob"), userProfile("carol")]))
            case "user.presence":
                channel.reply(to: request, data: .array([presence()]))

            case "media.uploadTicket":
                channel.reply(to: request, data: uploadTicket())
            case "media.downloadUrl":
                channel.reply(to: request, data: .string("https://storage.example.com/get?sig=xyz"))

            case "friend.list":
                channel.reply(to: request, data: page([friend()]))
            case "friend.requestList":
                channel.reply(to: request, data: page([friendRequest()]))
            case "friend.blockList":
                channel.reply(to: request, data: page([blockEntry()]))

            case "group.create", "group.info":
                channel.reply(to: request, data: group())
            case "group.memberList":
                channel.reply(to: request, data: page([groupMember()]))
            case "group.joined":
                channel.reply(to: request, data: page([group()]))

            default:
                // Every remaining endpoint in these tiers returns ApiResult with no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    // MARK: - Coverage

    @Test("every endpoint in T0, T1 and T2 has a typed method that names it")
    func tieredEndpointsAreAllTyped() async throws {
        let gateway = Self.fullGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // T0 — session floor.
        _ = try await client.conn.heartbeat()
        try await client.conn.reauth(token: "token-2")
        _ = try await client.conn.sync(ResumeRequest())

        // T1 — 1:1 chat MVP.
        _ = try await client.msg.send(.text("hello", to: .user("bob")))
        _ = try await client.msg.sync(SyncMessagesRequest(conversationId: "s_alice_bob", fromSeq: 1, toSeq: 2))
        _ = try await client.msg.history(HistoryRequest(conversationId: "s_alice_bob"))
        try await client.msg.recall(RecallMessageRequest(conversationId: "s_alice_bob", messageId: 1))
        try await client.msg.delete(DeleteMessagesRequest(conversationId: "s_alice_bob", messageIds: [1]))
        try await client.msg.typing(TypingRequest(conversationId: "s_alice_bob"))
        _ = try await client.conv.list()
        _ = try await client.conv.get("s_alice_bob")
        try await client.conv.read("s_alice_bob", readSeq: 9)
        _ = try await client.conv.unreadTotal()
        _ = try await client.user.me()
        _ = try await client.user.profile("bob")
        _ = try await client.user.batchProfile(UserIdsRequest(["bob", "carol"]))
        try await client.user.updateProfile(UpdateProfileRequest(patch: ["nickname": .string("Alice")]))
        _ = try await client.media.uploadTicket(UploadTicketRequest(
            fileName: "photo.jpg",
            contentType: "image/jpeg",
            size: 120_000
        ))
        _ = try await client.media.downloadUrl(objectKey: "app-test/alice/photo.jpg")
        try await client.push.register(RegisterPushTokenRequest(token: "apns-token"))
        try await client.push.unregister()

        // T2 — social graph and groups.
        try await client.msg.edit(EditMessageRequest(
            conversationId: "s_alice_bob",
            messageId: 1,
            content: ["text": .string("fixed")]
        ))
        _ = try await client.msg.forward(ForwardMessagesRequest(
            sourceConversationId: "s_alice_bob",
            messageIds: [1],
            targetConversationIds: ["g_ops"]
        ))
        try await client.msg.react(ReactRequest(conversationId: "s_alice_bob", messageId: 1, emoji: "👍"))
        try await client.msg.receipt(ReceiptRequest(conversationId: "s_alice_bob", messageIds: [1]))
        try await client.conv.setting(UpdateConversationSettingRequest(
            conversationId: "s_alice_bob",
            setting: ConversationSetting(pinned: true, muted: .noPush)
        ))
        try await client.conv.delete(ConversationIdRequest("s_alice_bob"))
        try await client.conv.clear(ConversationIdRequest("s_alice_bob"))
        _ = try await client.user.presence(UserIdsRequest(["bob"]))
        try await client.user.subscribePresence(SubscribePresenceRequest(userIds: ["bob"]))
        try await client.user.unsubscribePresence(UserIdsRequest(["bob"]))
        _ = try await client.friend.list()
        try await client.friend.add(AddFriendRequest(userId: "carol", greeting: "hi"))
        try await client.friend.handleRequest(HandleFriendRequest(fromUserId: "carol", accept: true))
        _ = try await client.friend.requestList()
        try await client.friend.delete(UserIdRequest("carol"))
        _ = try await client.friend.blockList()
        try await client.friend.block(BlockRequest(userId: "mallory"))
        try await client.friend.unblock(UserIdRequest("mallory"))
        _ = try await client.group.create(CreateGroupRequest(name: "Ops", memberIds: ["bob"]))
        _ = try await client.group.info("g-1")
        try await client.group.update(UpdateGroupCommand(groupId: "g-1", update: UpdateGroupRequest(name: "Ops 2")))
        try await client.group.dismiss(GroupIdRequest("g-1"))
        _ = try await client.group.memberList(GroupCursorRequest(groupId: "g-1"))
        _ = try await client.group.joined()
        try await client.group.invite(GroupMembersRequest(groupId: "g-1", userIds: ["dave"]))
        try await client.group.kick(GroupMembersRequest(groupId: "g-1", userIds: ["dave"]))
        try await client.group.quit(GroupIdRequest("g-1"))
        try await client.group.join(JoinGroupRequest(groupId: "g-2"))

        let expected: Set<String> = [
            // T0
            "conn.heartbeat", "conn.reauth", "conn.sync",
            // T1
            "msg.send", "msg.sync", "msg.history", "msg.recall", "msg.delete", "msg.typing",
            "conv.list", "conv.get", "conv.read", "conv.unreadTotal",
            "user.me", "user.profile", "user.batchProfile", "user.updateProfile",
            "media.uploadTicket", "media.downloadUrl",
            "push.register", "push.unregister",
            // T2
            "msg.edit", "msg.forward", "msg.react", "msg.receipt",
            "conv.setting", "conv.delete", "conv.clear",
            "user.presence", "user.subscribePresence", "user.unsubscribePresence",
            "friend.list", "friend.add", "friend.handleRequest", "friend.requestList",
            "friend.delete", "friend.blockList", "friend.block", "friend.unblock",
            "group.create", "group.info", "group.update", "group.dismiss", "group.memberList",
            "group.joined", "group.invite", "group.kick", "group.quit", "group.join",
        ]

        #expect(expected.count == 49, "T0 (3) + T1 (18) + T2 (28)")

        let seen = Set(channel.requests.map(\.target))
        #expect(expected.subtracting(seen).isEmpty, "untyped: \(expected.subtracting(seen).sorted())")

        await client.disconnect()
    }

    // MARK: - Payloads

    @Test("payload types decode the fields an app actually renders")
    func payloadsDecode() async throws {
        let gateway = Self.fullGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let profile = try await client.user.me()
        #expect(profile.userId == "bob")
        #expect(profile.nickname == "Bob")
        #expect(profile.extensions["team"]?.stringValue == "ops")
        #expect(profile.silencedUntil == nil)

        let group = try await client.group.info("g-1")
        #expect(group.name == "Ops")
        #expect(group.joinMode == .needApproval)
        #expect(group.inviteMode == .allMembers)
        #expect(group.memberCount == 4)

        let members = try await client.group.memberList(GroupCursorRequest(groupId: "g-1"))
        #expect(members.items.first?.role == .admin)
        #expect(members.items.first?.nickname == "Bobby")
        #expect(members.hasMore == false)

        let presence = try await client.user.presence(UserIdsRequest(["bob"]))
        #expect(presence.first?.online == true)
        #expect(presence.first?.platforms == [.iOS, .web])
        #expect(presence.first?.customStatus == "in a meeting")

        let ticket = try await client.media.uploadTicket(UploadTicketRequest(
            fileName: "photo.jpg",
            contentType: "image/jpeg",
            size: 1
        ))
        #expect(ticket.objectKey == "app-test/alice/2026/photo.jpg")
        #expect(ticket.formFields["x-amz-acl"] == "private")

        // A bare string and a bare number both come back unwrapped, not as an envelope.
        let url = try await client.media.downloadUrl(objectKey: "k")
        #expect(url == "https://storage.example.com/get?sig=xyz")
        #expect(try await client.conv.unreadTotal() == 12)

        let friends = try await client.friend.list()
        #expect(friends.items.first?.friendUserId == "bob")
        #expect(friends.items.first?.remark == "Bob from ops")

        let requests = try await client.friend.requestList()
        #expect(requests.items.first?.status == .pending)

        let blocked = try await client.friend.blockList()
        #expect(blocked.items.first?.blockedUserId == "mallory")

        await client.disconnect()
    }

    @Test("a 64-bit value written as a string still decodes")
    func numbersMayArriveAsStrings() async throws {
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // `AllowReadingFromString` is set on the gateway's serialiser, so this is legal wire — and
        // a decoder that throws on it drops the whole message, not one field of it.
        channel.event(.message, data: .object([
            "conversationId": .string("s_alice_bob"),
            "seq": .string("42"),
            "messageId": .string("9007199254740993"),
            "contentType": .string("1"),
            "senderId": .string("bob"),
            "content": .object(["text": .string("hi")]),
            "createTime": .string("1700000000000"),
        ]))

        _ = await waitUntil("the message") { messages.count == 1 }
        let message = try #require(messages.items.first)

        #expect(message.seq == 42)
        #expect(message.messageId == 9_007_199_254_740_993, "a value past 2^53 must survive intact")
        #expect(message.contentType == .text)
        #expect(message.createTime == 1_700_000_000_000)

        await client.disconnect()
    }

    @Test("an enum value this build has never heard of keeps its raw value")
    func unknownEnumValuesArePreserved() async throws {
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // The server ships new content types without waiting for the app. Coercing this to `.text`
        // would render a payment request as an empty bubble; throwing would lose the message.
        channel.event(.message, data: .object([
            "conversationId": .string("s_alice_bob"),
            "seq": .int(1),
            "contentType": .int(7_777),
            "content": .object(["kind": .string("payment")]),
        ]))

        _ = await waitUntil("the message") { messages.count == 1 }
        let message = try #require(messages.items.first)

        #expect(message.contentType.rawValue == 7_777)
        #expect(message.contentType != .text)
        #expect(message.content["kind"]?.stringValue == "payment")

        await client.disconnect()
    }

    @Test("nil fields are omitted from a request rather than sent as null")
    func nullsAreOmittedWhenWriting() async throws {
        let gateway = Self.fullGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.msg.history(HistoryRequest(conversationId: "s_alice_bob"))

        let history = try #require(channel.requests(for: "msg.history").first)
        #expect(history["conversationId"]?.stringValue == "s_alice_bob")
        #expect(history["beforeSeq"] == nil, "an unset optional is absent, not null")
        #expect(history["limit"]?.intValue == 20)

        await client.disconnect()
    }

    @Test("invoke shares the typed code path and never moves a cursor")
    func invokeIsAPeerOfTheTypedSurface() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "msg.sync" {
                channel.reply(to: request, data: syncPayload(conversationId: "s_alice_bob", range: 1 ... 5))
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())
        try await client.connect()

        // The escape hatch is a supported route for an endpoint the typed surface has not reached
        // yet, so it has to behave like one: same errors, same timeouts — and no side effects.
        let result: SyncMessagesResult = try await client.invoke("msg.sync", body: SyncMessagesRequest(
            conversationId: "s_alice_bob",
            fromSeq: 1,
            toSeq: 5
        ))

        #expect(result.messages.count == 5)
        await settle()

        // Nothing was delivered and nothing was recorded: an escape hatch that quietly mutated
        // sequence state would be unpredictable in exactly the situations it gets used in.
        #expect(messages.count == 0)
        #expect(await client.highestSeq(in: "s_alice_bob") == 0)
        #expect(await client.committedSeq(in: "s_alice_bob") == 0)

        await client.disconnect()
    }

    @Test("the legacy flat methods still work and still hit the same endpoints")
    func frozenLegacyAliasesDelegate() async throws {
        let gateway = Self.fullGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.sendText("hello", to: .user("bob"))
        _ = try await client.history(of: "s_alice_bob")
        _ = try await client.sync("s_alice_bob", from: 1, to: 2)
        try await client.recall(1, in: "s_alice_bob")
        try await client.react("👍", to: 1, in: "s_alice_bob")
        try await client.setTyping(true, in: "s_alice_bob")
        _ = try await client.conversations()
        try await client.markRead("s_alice_bob", upTo: 9)
        _ = try await client.totalUnread()

        // They appear in every README and sample that has ever shipped, so they stay — as thin
        // delegates to the namespaced surface, not as a second implementation of it.
        let seen = Set(channel.requests.map(\.target))
        for target in ["msg.send", "msg.history", "msg.sync", "msg.recall", "msg.react",
                       "msg.typing", "conv.list", "conv.read", "conv.unreadTotal"] {
            #expect(seen.contains(target), "\(target) is missing")
        }

        await client.disconnect()
    }

    @Test("the SDK reports which contract it implements")
    func versionConstants() {
        #expect(ImSdk.contractVersion == "1.0")
        #expect(ImSdk.packageVersion == "0.9.0")
        #expect(ImSdk.userAgent == "cyaim-swift/0.9.0")
    }
}
