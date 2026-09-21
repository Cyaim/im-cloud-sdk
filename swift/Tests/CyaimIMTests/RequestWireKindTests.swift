import Foundation
import Testing

@testable import CyaimIM

/// Every request field in the JSON kind its server DTO declares.
///
/// The gateway binds a request body field by field, by the C# type of each property, and without the
/// serialiser's number handling: a C# `string` accepts only a JSON string, a `long` or `int` only a
/// bare JSON integer, a `bool` only `true`/`false`, an enum only its integer, and a `List<string>`
/// only an array of strings. A field of the wrong kind is not coerced — the whole call comes back
/// status `1`, `1000 InternalError`, before the endpoint runs. Message ids are where this SDK had it
/// wrong: the property is an `Int64` and the server's field is a `string`.
///
/// So every assertion here compares a whole ``JSONValue`` with `==`, which tells `.string("7")` from
/// `.int(7)` from `.bool(true)`, and never goes through ``JSONValue/intValue`` (which also answers for
/// a `.double`) or `asInt64` (which also answers for a `.string`). A bare-number id in a string
/// field has to be able to turn these red.
///
/// 网关按 C# 类型逐字段绑定请求体，不做数字/字符串互转：类型不对整个调用回 1000。
/// 这里一律整值比较 JSONValue，看得见 JSON 的种类，不经过会把 "7" 与 7 当成一回事的访问器。
@Suite("Request fields in the server's JSON kinds")
struct RequestWireKindTests {

    /// Past 2^53 and odd: a Double round trip changes its last digit.
    private static let big: Int64 = 360_381_357_961_969_667
    private static let bigText = "360381357961969667"

    private static func sendResult() -> JSONValue {
        .object([
            "messageId": .string("360381357961969999"),
            "seq": .int(1),
            "conversationId": .string("g_ops"),
            "clientMsgId": .string("cm-wire"),
            "createTime": .int(1_700_000_000_000),
            "deduplicated": .bool(false),
            "contentModified": .bool(false),
        ])
    }

    private static func gateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "msg.send":
                channel.reply(to: request, data: Self.sendResult())
            case "msg.forward":
                channel.reply(to: request, data: .array([Self.sendResult()]))
            default:
                // Every other write here acknowledges the way the server does: no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    /// A request encoded exactly as ``ImConnection`` encodes a frame's body, read back as JSON.
    private static func wire(_ request: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    }

    private static func expectWire(_ target: String, _ request: some Encodable, _ expected: JSONValue) throws {
        let actual = try wire(request)
        #expect(actual == expected, "\(target): sent \(actual)")
    }

    // MARK: - Message ids leave quoted

    @Test("recall, edit, react, delete, forward and receipt send every message id as a quoted string")
    func messageIdsLeaveQuoted() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.msg.recall(RecallMessageRequest(conversationId: "c_wire", messageId: Self.big, reason: "wire"))
        try await client.msg.edit(EditMessageRequest(
            conversationId: "c_wire",
            messageId: Self.big,
            content: ["text": .string("fixed")]
        ))
        try await client.msg.react(ReactRequest(conversationId: "c_wire", messageId: Self.big, emoji: "+1", add: false))
        try await client.msg.delete(DeleteMessagesRequest(conversationId: "c_wire", messageIds: [Self.big, 7], forEveryone: true))
        _ = try await client.msg.forward(ForwardMessagesRequest(
            sourceConversationId: "c_wire",
            messageIds: [Self.big, 7],
            targetConversationIds: ["g_ops"],
            merge: true,
            mergeTitle: "wire",
            clientMsgId: "cm-forward"
        ))
        try await client.msg.receipt(ReceiptRequest(conversationId: "c_wire", messageIds: [Self.big, 7]))

        let ids: JSONValue = .array([.string(Self.bigText), .string("7")])

        let expected: [String: JSONValue] = [
            "msg.recall": .object([
                "conversationId": .string("c_wire"),
                "messageId": .string(Self.bigText),
                "reason": .string("wire"),
            ]),
            "msg.edit": .object([
                "conversationId": .string("c_wire"),
                "messageId": .string(Self.bigText),
                "content": .object(["text": .string("fixed")]),
            ]),
            "msg.react": .object([
                "conversationId": .string("c_wire"),
                "messageId": .string(Self.bigText),
                "emoji": .string("+1"),
                "add": .bool(false),
            ]),
            "msg.delete": .object([
                "conversationId": .string("c_wire"),
                "messageIds": ids,
                "forEveryone": .bool(true),
            ]),
            "msg.forward": .object([
                "sourceConversationId": .string("c_wire"),
                "messageIds": ids,
                "targetConversationIds": .array([.string("g_ops")]),
                "merge": .bool(true),
                "mergeTitle": .string("wire"),
                "clientMsgId": .string("cm-forward"),
            ]),
            "msg.receipt": .object([
                "conversationId": .string("c_wire"),
                "messageIds": ids,
            ]),
        ]

        for (target, body) in expected {
            let sent = try #require(channel.requests(for: target).first, "\(target) was never sent")
            #expect(sent.body == body, "\(target): sent \(sent.body)")
        }

        await client.disconnect()
    }

    @Test("an unset optional id is absent, and the legacy recall and react quote theirs too")
    func optionalIdsAndLegacyAliases() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.msg.recall(RecallMessageRequest(conversationId: "c_wire", messageId: 7))
        try await client.recall(Self.big, in: "c_wire")
        try await client.react("+1", to: Self.big, in: "c_wire")

        let recalls = channel.requests(for: "msg.recall")
        try #require(recalls.count == 2)

        let noReason: JSONValue = .object(["conversationId": .string("c_wire"), "messageId": .string("7")])
        #expect(recalls[0].body == noReason, "a nil reason is absent, and a small id is quoted as well")

        let legacyRecall: JSONValue = .object(["conversationId": .string("c_wire"), "messageId": .string(Self.bigText)])
        #expect(recalls[1].body == legacyRecall)

        let react = try #require(channel.requests(for: "msg.react").first)
        let legacyReact: JSONValue = .object([
            "conversationId": .string("c_wire"),
            "messageId": .string(Self.bigText),
            "emoji": .string("+1"),
            "add": .bool(true),
        ])
        #expect(react.body == legacyReact)

        await client.disconnect()
    }

    // MARK: - msg.send

    @Test("msg.send quotes quoteMessageId and threadRootId and keeps every other field's kind")
    func sendKinds() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.msg.send(SendMessageRequest(
            conversationId: "g_ops",
            conversationType: .group,
            clientMsgId: "cm-wire",
            contentType: .image,
            content: ["objectKey": .string("k"), "width": .int(1080)],
            mentionAll: true,
            mentionedUserIds: ["bob"],
            quoteMessageId: Self.big,
            threadRootId: 7,
            options: MessageOptions(
                persistent: false,
                updateConversation: false,
                countUnread: false,
                offlinePush: false,
                pushConfig: PushConfig(
                    title: "t",
                    body: "b",
                    sound: "s",
                    payload: ["k": "v"],
                    badgeCount: false,
                    channelId: "ch"
                ),
                needReceipt: true,
                priority: .high,
                onlineOnly: true,
                noSelfSync: true,
                expireIn: 5_000,
                moderationBypass: true
            ),
            sendTime: 1_700_000_000_000,
            extensions: ["trace": .string("x")]
        ))

        _ = try await client.msg.send(.text("hi", to: .user("bob")))

        let sends = channel.requests(for: "msg.send")
        try #require(sends.count == 2)

        let pushConfig: JSONValue = .object([
            "title": .string("t"),
            "body": .string("b"),
            "sound": .string("s"),
            "payload": .object(["k": .string("v")]),
            "badgeCount": .bool(false),
            "channelId": .string("ch"),
        ])

        let options: JSONValue = .object([
            "persistent": .bool(false),
            "updateConversation": .bool(false),
            "countUnread": .bool(false),
            "offlinePush": .bool(false),
            "pushConfig": pushConfig,
            "needReceipt": .bool(true),
            "priority": .int(2),
            "onlineOnly": .bool(true),
            "noSelfSync": .bool(true),
            "expireIn": .int(5_000),
            "moderationBypass": .bool(true),
        ])

        let expected: JSONValue = .object([
            "conversationId": .string("g_ops"),
            "conversationType": .int(2),
            "clientMsgId": .string("cm-wire"),
            "contentType": .int(2),
            "content": .object(["objectKey": .string("k"), "width": .int(1080)]),
            "mentionAll": .bool(true),
            "mentionedUserIds": .array([.string("bob")]),
            "quoteMessageId": .string(Self.bigText),
            "threadRootId": .string("7"),
            "options": options,
            "sendTime": .int(1_700_000_000_000),
            "extensions": .object(["trace": .string("x")]),
        ])

        #expect(sends[0].body == expected, "sent \(sends[0].body)")

        // Unset, the two ids are absent rather than null or zero.
        #expect(sends[1]["quoteMessageId"] == nil)
        #expect(sends[1]["threadRootId"] == nil)
        #expect(sends[1]["receiverId"] == .string("bob"))
        #expect(sends[1]["contentType"] == .int(1))
        #expect(sends[1]["mentionAll"] == .bool(false))

        await client.disconnect()
    }

    @Test("a draft quotes its quoteMessageId, and send(_:) carries its options instead of dropping them")
    func draftKinds() async throws {
        let draft = MessageDraft(
            to: .user("bob"),
            content: ["text": .string("hi")],
            clientMsgId: "cm-draft",
            quoteMessageId: Self.big,
            options: ["offlinePush": .bool(false), "priority": .int(2)],
            sendTime: 1_700_000_000_000
        )

        // The draft is `Encodable` in its own right and `invoke` accepts it, so its own encoder
        // has to be right too.
        let encoded = try Self.wire(draft)
        #expect(encoded["quoteMessageId"] == .string(Self.bigText))
        #expect(encoded["options"] == .object(["offlinePush": .bool(false), "priority": .int(2)]))

        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.send(draft)

        let sent = try #require(channel.requests(for: "msg.send").first)
        #expect(sent["quoteMessageId"] == .string(Self.bigText))
        #expect(sent["options"]?["offlinePush"] == .bool(false), "the draft's switch reached the frame")
        #expect(sent["options"]?["priority"] == .int(2))

        // What the draft left out is the server's own default, not something invented.
        #expect(sent["options"]?["persistent"] == .bool(true))
        #expect(sent["options"]?["needReceipt"] == .bool(false))
        #expect(sent["options"]?["expireIn"] == nil)

        await client.disconnect()
    }

    // MARK: - Everything else

    /// The T0–T2 requests not covered above, each with every field set to a non-default value, compared
    /// whole. Tier 3 is `CompetitiveParityTests`' business. The typed methods pass these objects to the
    /// socket unchanged, so encoding them is what the frame carries.
    @Test("every other T0–T2 request sends each field in the kind its server DTO declares")
    func everyOtherRequestKeepsItsKinds() throws {
        try Self.expectWire("conn.reauth", ReauthRequest(token: "t"), .object(["token": .string("t")]))

        try Self.expectWire(
            "conn.sync",
            ResumeRequest(convSeqs: ["c1": 41], conversationCursor: 1_700_000_000_000, cursor: "p2", limit: 100),
            .object([
                "convSeqs": .object(["c1": .int(41)]),
                "conversationCursor": .int(1_700_000_000_000),
                "cursor": .string("p2"),
                "limit": .int(100),
            ])
        )

        try Self.expectWire(
            "msg.sync",
            SyncMessagesRequest(conversationId: "c1", fromSeq: 6, toSeq: 8, limit: 3, ascending: false),
            .object([
                "conversationId": .string("c1"),
                "fromSeq": .int(6),
                "toSeq": .int(8),
                "limit": .int(3),
                "ascending": .bool(false),
            ])
        )

        try Self.expectWire(
            "msg.history",
            HistoryRequest(conversationId: "c1", beforeSeq: 40, limit: 30),
            .object(["conversationId": .string("c1"), "beforeSeq": .int(40), "limit": .int(30)])
        )

        try Self.expectWire(
            "msg.typing",
            TypingRequest(conversationId: "c1", typing: false),
            .object(["conversationId": .string("c1"), "typing": .bool(false)])
        )

        try Self.expectWire(
            "conv.list",
            ListConversationsRequest(updatedAfter: 1_700_000_000_000, cursor: "p2", limit: 10),
            .object(["updatedAfter": .int(1_700_000_000_000), "cursor": .string("p2"), "limit": .int(10)])
        )

        try Self.expectWire("conv.get", ConversationIdRequest("c1"), .object(["conversationId": .string("c1")]))

        try Self.expectWire(
            "conv.read",
            ReadRequest(conversationId: "c1", readSeq: 9),
            .object(["conversationId": .string("c1"), "readSeq": .int(9)])
        )

        try Self.expectWire(
            "conv.setting",
            UpdateConversationSettingRequest(
                conversationId: "c1",
                setting: ConversationSetting(
                    pinned: true,
                    muted: .noPush,
                    draft: "d",
                    tags: ["work"],
                    extensions: ["k": .string("v")]
                )
            ),
            .object([
                "conversationId": .string("c1"),
                "setting": .object([
                    "pinned": .bool(true),
                    "muted": .int(1),
                    "draft": .string("d"),
                    "tags": .array([.string("work")]),
                    "extensions": .object(["k": .string("v")]),
                ]),
            ])
        )

        try Self.expectWire("user.profile", UserIdRequest("bob"), .object(["userId": .string("bob")]))

        try Self.expectWire(
            "user.batchProfile",
            UserIdsRequest(["bob", "carol"]),
            .object(["userIds": .array([.string("bob"), .string("carol")])])
        )

        try Self.expectWire(
            "user.updateProfile",
            UpdateProfileRequest(patch: ["nickname": .string("Al"), "gender": .int(1)]),
            .object(["patch": .object(["nickname": .string("Al"), "gender": .int(1)])])
        )

        try Self.expectWire(
            "user.subscribePresence",
            SubscribePresenceRequest(userIds: ["bob"], ttlSeconds: 900),
            .object(["userIds": .array([.string("bob")]), "ttlSeconds": .int(900)])
        )

        try Self.expectWire(
            "media.uploadTicket",
            UploadTicketRequest(fileName: "a.jpg", contentType: "image/jpeg", size: 120_000),
            .object([
                "fileName": .string("a.jpg"),
                "contentType": .string("image/jpeg"),
                "size": .int(120_000),
            ])
        )

        try Self.expectWire(
            "media.downloadUrl",
            DownloadUrlRequest(objectKey: "k", lifetimeSeconds: 60),
            .object(["objectKey": .string("k"), "lifetimeSeconds": .int(60)])
        )

        try Self.expectWire(
            "push.register",
            RegisterPushTokenRequest(provider: ImPushProvider.fcm, token: "tok", language: "en-US"),
            .object(["provider": .string("fcm"), "token": .string("tok"), "language": .string("en-US")])
        )

        try Self.expectWire(
            "push.clicked",
            PushClickedRequest(pushId: "pu_1", messageId: Self.bigText),
            .object(["pushId": .string("pu_1"), "messageId": .string(Self.bigText)])
        )

        try Self.expectWire(
            "friend.list",
            CursorRequest(cursor: "p2", limit: 10),
            .object(["cursor": .string("p2"), "limit": .int(10)])
        )

        try Self.expectWire(
            "friend.add",
            AddFriendRequest(userId: "carol", greeting: "hi", source: "qr"),
            .object(["userId": .string("carol"), "greeting": .string("hi"), "source": .string("qr")])
        )

        try Self.expectWire(
            "friend.handleRequest",
            HandleFriendRequest(fromUserId: "carol", accept: false, reason: "no"),
            .object(["fromUserId": .string("carol"), "accept": .bool(false), "reason": .string("no")])
        )

        try Self.expectWire(
            "friend.requestList",
            FriendRequestListRequest(incoming: false, cursor: "p2", limit: 10),
            .object(["incoming": .bool(false), "cursor": .string("p2"), "limit": .int(10)])
        )

        try Self.expectWire(
            "friend.block",
            BlockRequest(userId: "mallory", reason: "spam"),
            .object(["userId": .string("mallory"), "reason": .string("spam")])
        )

        try Self.expectWire(
            "group.create",
            CreateGroupRequest(
                name: "Ops",
                memberIds: ["bob"],
                groupId: "g-1",
                avatar: "a",
                introduction: "i",
                type: .superGroup,
                joinMode: .needApproval,
                inviteMode: .adminsOnly,
                maxMemberCount: 500,
                extensions: ["k": .string("v")]
            ),
            .object([
                "groupId": .string("g-1"),
                "name": .string("Ops"),
                "avatar": .string("a"),
                "introduction": .string("i"),
                "type": .int(2),
                "memberIds": .array([.string("bob")]),
                "joinMode": .int(1),
                "inviteMode": .int(1),
                "maxMemberCount": .int(500),
                "extensions": .object(["k": .string("v")]),
            ])
        )

        try Self.expectWire(
            "group.update",
            UpdateGroupCommand(
                groupId: "g-1",
                update: UpdateGroupRequest(
                    name: "n",
                    avatar: "a",
                    introduction: "i",
                    joinMode: .forbidden,
                    inviteMode: .forbidden,
                    maxMemberCount: 200,
                    extensions: ["k": .string("v")]
                )
            ),
            .object([
                "groupId": .string("g-1"),
                "update": .object([
                    "name": .string("n"),
                    "avatar": .string("a"),
                    "introduction": .string("i"),
                    "joinMode": .int(2),
                    "inviteMode": .int(2),
                    "maxMemberCount": .int(200),
                    "extensions": .object(["k": .string("v")]),
                ]),
            ])
        )

        try Self.expectWire("group.info", GroupIdRequest("g-1"), .object(["groupId": .string("g-1")]))

        try Self.expectWire(
            "group.memberList",
            GroupCursorRequest(groupId: "g-1", cursor: "p2", limit: 10),
            .object(["groupId": .string("g-1"), "cursor": .string("p2"), "limit": .int(10)])
        )

        try Self.expectWire(
            "group.invite",
            GroupMembersRequest(groupId: "g-1", userIds: ["dave"], reason: "r"),
            .object(["groupId": .string("g-1"), "userIds": .array([.string("dave")]), "reason": .string("r")])
        )

        try Self.expectWire(
            "group.join",
            JoinGroupRequest(groupId: "g-2", reason: "r"),
            .object(["groupId": .string("g-2"), "reason": .string("r")])
        )

        try Self.expectWire(
            "moderation.report",
            SubmitReportRequest(
                targetUserId: "mallory",
                conversationId: "c1",
                messageId: Self.big,
                category: ImReportCategory.spam,
                note: "n"
            ),
            .object([
                "targetUserId": .string("mallory"),
                "conversationId": .string("c1"),
                "messageId": .string(Self.bigText),
                "category": .string("spam"),
                "note": .string("n"),
            ])
        )

        try Self.expectWire(
            "diag.logUploaded",
            DeviceLogAnswer(
                requestId: "lr_1",
                uploaded: true,
                sizeBytes: 2_048,
                coveredFromMs: 1_700_000_000_000,
                isVolatile: true,
                detail: "d"
            ),
            .object([
                "requestId": .string("lr_1"),
                "uploaded": .bool(true),
                "sizeBytes": .int(2_048),
                "coveredFromMs": .int(1_700_000_000_000),
                "volatile": .bool(true),
                "detail": .string("d"),
            ])
        )
    }
}
