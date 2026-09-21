import Foundation
import Testing

@testable import CyaimIM

/// Tier 3 on the wire: what each typed call puts in the frame, and what it makes of the reply.
///
/// `TypedSurfaceTests` proves every tier-3 endpoint has a method that names it. That is not the same
/// as the call working. The gateway binds a request body field by field, without the serialiser's
/// number handling, so a field sent in the wrong JSON *type* is not coerced — it fails the whole call
/// with `1000`. A message id is the sharpest case: the server declares it `string`, this SDK holds it
/// as `Int64`, and a JSON number in that position is refused outright. So these tests read the frame
/// the SDK actually wrote and assert each field's JSON type, not just its value.
///
/// 网关逐字段绑定请求体，不做数字/字符串互转：类型写错不会被纠正，而是整个调用回 1000。
/// 所以这里断言的是每个字段在 JSON 里的类型，而不只是值。
@Suite("Tier 3 on the wire")
struct CompetitiveParityTests {

    /// Past 2^53 by a factor of 40: a Double round trip changes its last digits.
    private static let snowflake: Int64 = 360_306_324_097_966_080
    private static let snowflakeText = "360306324097966080"

    // MARK: - Canned payloads

    /// A message as the server writes it: the id quoted.
    private static func quotedMessage(seq: Int64, recalled: Bool = false) -> JSONValue {
        var message: [String: JSONValue] = [
            "appId": .string("app-test"),
            "conversationId": .string("g_ops"),
            "conversationType": .int(2),
            "seq": .int(seq),
            "messageId": .string(snowflakeText),
            "clientMsgId": .string("cm-\(seq)"),
            "senderId": .string("bob"),
            "senderPlatform": .int(1),
            "contentType": .int(1),
            "content": .object(["text": .string("invoice #\(seq)")]),
            "sendTime": .int(1_700_000_000_000),
            "createTime": .int(1_700_000_000_000),
        ]

        if recalled {
            message["recalled"] = .object([
                "operatorId": .string("bob"),
                "recallTime": .int(1_700_000_001_000),
                "byAdmin": .bool(false),
            ])
        }

        return .object(message)
    }

    private static func gateway(
        _ answer: @escaping @Sendable (SentRequest, MockChannel) -> Bool = { _, _ in false }
    ) -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            if answer(request, channel) { return }

            // Everything not scripted acknowledges the way the server does for a write: no payload.
            channel.reply(to: request, data: .null)
        })
    }

    /// The top-level keys of a request body, for "nothing else was sent" assertions.
    private static func keys(of request: SentRequest) throws -> Set<String> {
        let object = try #require(request.body.objectValue, "the body is not an object")
        return Set(object.keys)
    }

    // MARK: - Message ids leave quoted

    @Test("the five message-addressing calls send the id as a quoted string, digits intact")
    func conversationMessageIdsAreQuoted() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let request = ConversationMessageRequest(conversationId: "g_ops", messageId: Self.snowflake)
        try await client.msg.pin(request)
        try await client.msg.unpin(request)
        try await client.msg.favourite(request)
        try await client.msg.unfavourite(request)
        try await client.msg.burn(request)

        for target in ["msg.pin", "msg.unpin", "msg.favourite", "msg.unfavourite", "msg.burn"] {
            let sent = try #require(channel.requests(for: target).first, "\(target) was never sent")

            #expect(sent["conversationId"]?.stringValue == "g_ops", "\(target)")
            #expect(sent["messageId"]?.stringValue == Self.snowflakeText, "\(target)")
            #expect(sent["messageId"]?.intValue == nil, "\(target): a JSON number here is refused with 1000")
            #expect(try Self.keys(of: sent) == ["conversationId", "messageId"], "\(target)")
        }

        await client.disconnect()
    }

    @Test("receiptDetail sends the id quoted and decodes the receipt, id exact")
    func receiptDetailRoundTrip() async throws {
        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.receiptDetail" else { return false }

            channel.reply(to: request, data: .object([
                "appId": .string("app-test"),
                "conversationId": .string("g_ops"),
                "messageId": .string(Self.snowflakeText),
                "readUserIds": .array([.string("bob"), .string("carol")]),
                "readCount": .int(2),
                "totalCount": .int(8),
                "updatedAt": .int(1_700_000_000_500),
            ]))
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let receipt = try await client.msg.receiptDetail(ReceiptDetailRequest(
            conversationId: "g_ops",
            messageId: Self.snowflake
        ))

        let sent = try #require(channel.requests(for: "msg.receiptDetail").first)
        #expect(sent["conversationId"]?.stringValue == "g_ops")
        #expect(sent["messageId"]?.stringValue == Self.snowflakeText)
        #expect(sent["messageId"]?.intValue == nil)

        #expect(receipt.messageId == Self.snowflake, "an id past 2^53 must survive intact")
        #expect(receipt.id == Self.snowflake)
        #expect(receipt.conversationId == "g_ops")
        #expect(receipt.readUserIds == ["bob", "carol"])
        #expect(receipt.readCount == 2)

        // `totalCount` includes the sender and `readUserIds` never does: 2 of a possible 7 readers.
        #expect(receipt.totalCount == 8)
        #expect(receipt.readCount < receipt.totalCount - 1)
        #expect(receipt.updatedAt == 1_700_000_000_500)

        await client.disconnect()
    }

    // MARK: - Numbers stay numbers

    @Test("search sends numbers as numbers, enums as integers, and omits what was not set")
    func searchBodyTypes() async throws {
        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.search" else { return false }
            channel.reply(to: request, data: .object([
                "items": .array([Self.quotedMessage(seq: 9)]),
                "hasMore": .bool(true),
                "nextCursor": .string("c2"),
            ]))
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let page = try await client.msg.search(SearchMessagesRequest(
            keyword: "invoice",
            contentTypes: [.text, .file],
            startTime: 1_756_684_800_000,
            endTime: 1_758_412_800_000
        ))

        let sent = try #require(channel.requests(for: "msg.search").first)
        #expect(sent["keyword"]?.stringValue == "invoice")

        // Each of these is a `long?`, an enum list and an `int` on the server: a quoted value throws
        // there, exactly as a bare number does in a `string` field.
        #expect(sent["startTime"] == .int(1_756_684_800_000))
        #expect(sent["endTime"] == .int(1_758_412_800_000))
        #expect(sent["contentTypes"] == .array([.int(1), .int(5)]))
        #expect(sent["limit"] == .int(20))

        // Unset optionals are absent rather than null.
        #expect(try Self.keys(of: sent) == ["keyword", "contentTypes", "startTime", "endTime", "limit"])

        #expect(page.items.first?.messageId == Self.snowflake)
        #expect(page.items.first?.seq == 9)
        #expect(page.hasMore)
        #expect(page.nextCursor == "c2")
        #expect(page.total == nil)

        await client.disconnect()
    }

    @Test("favourites pages on the cursor, and a short page with a cursor is not the end")
    func favouritesPaging() async throws {
        let pages = ScriptedResponder([
            // A page can come back empty while a cursor is still set: favourites the caller can no
            // longer read are hidden, and ones whose message is gone are removed as the page is read.
            .data(.object([
                "items": .array([]),
                "hasMore": .bool(true),
                "nextCursor": .string("c2"),
            ])),
            .data(.object([
                "items": .array([Self.quotedMessage(seq: 3, recalled: true)]),
                "hasMore": .bool(false),
            ])),
        ])

        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.favourites" else { return false }
            pages.answer(request, channel)
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let first = try await client.msg.favourites()
        #expect(first.items.isEmpty)
        #expect(first.nextCursor == "c2", "an empty page with a cursor is not the last page")

        let second = try await client.msg.favourites(PageRequest(cursor: first.nextCursor))
        #expect(second.nextCursor == nil)

        // Recalled messages are listed, with the recall set, and the id survives its quoting.
        let message = try #require(second.items.first)
        #expect(message.isRecalled)
        #expect(message.messageId == Self.snowflake)

        let sent = channel.requests(for: "msg.favourites")
        try #require(sent.count == 2)
        #expect(try Self.keys(of: sent[0]) == ["limit"], "the default page asks for no cursor")
        #expect(sent[0]["limit"] == .int(20))
        #expect(sent[1]["cursor"]?.stringValue == "c2")

        await client.disconnect()
    }

    // MARK: - Pins

    @Test("pins is a plain array whose ids and briefs decode exactly")
    func pinsDecode() async throws {
        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.pins" else { return false }

            channel.reply(to: request, data: .array([
                .object([
                    "messageId": .string(Self.snowflakeText),
                    "seq": .int(42),
                    "pinnedBy": .string("alice"),
                    "pinnedAt": .int(1_700_000_000_000),
                    "brief": .object([
                        "messageId": .string(Self.snowflakeText),
                        "seq": .int(42),
                        "senderId": .string("bob"),
                        "contentType": .int(2),
                        "digest": .string("[Image]"),
                        "createTime": .int(1_699_999_999_000),
                        "recalled": .bool(false),
                    ]),
                ]),
                .object([
                    "messageId": .string("360306324097966081"),
                    "seq": .int(40),
                    "pinnedBy": .string("bob"),
                    "pinnedAt": .int(1_699_000_000_000),
                    "brief": .object([
                        "messageId": .string("360306324097966081"),
                        "seq": .int(40),
                        "senderId": .string("carol"),
                        "contentType": .int(1),
                        "digest": .string("[Recalled]"),
                        "createTime": .int(1_698_999_999_000),
                        "recalled": .bool(true),
                    ]),
                ]),
            ]))
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let pins = try await client.msg.pins(ConversationIdRequest("g_ops"))

        let sent = try #require(channel.requests(for: "msg.pins").first)
        #expect(try Self.keys(of: sent) == ["conversationId"])
        #expect(sent["conversationId"]?.stringValue == "g_ops")

        try #require(pins.count == 2)
        let newest = try #require(pins.first)
        #expect(newest.messageId == Self.snowflake)
        #expect(newest.id == Self.snowflake)
        #expect(newest.seq == 42)
        #expect(newest.pinnedBy == "alice")
        #expect(newest.pinnedAt == 1_700_000_000_000)
        #expect(newest.brief?.messageId == Self.snowflake)
        #expect(newest.brief?.contentType == .image)
        #expect(newest.brief?.digest == "[Image]")

        // Two ids one apart: a Double round trip would make them equal.
        #expect(pins[1].messageId == Self.snowflake + 1)
        #expect(pins[1].brief?.recalled == true)
        #expect(pins[1].brief?.digest == "[Recalled]")

        await client.disconnect()
    }

    @Test("an empty board is an empty array, not a failure")
    func noPinsIsEmpty() async throws {
        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.pins" else { return false }
            channel.reply(to: request, data: .array([]))
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        #expect(try await client.msg.pins(ConversationIdRequest("g_ops")).isEmpty)

        await client.disconnect()
    }

    // MARK: - conv, user, friend

    @Test("markUnread sends unread explicitly, true by default and false to clear")
    func markUnreadBody() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.conv.markUnread(MarkUnreadRequest(conversationId: "s_alice_bob"))
        try await client.conv.markUnread(MarkUnreadRequest(conversationId: "s_alice_bob", unread: false))

        let sent = channel.requests(for: "conv.markUnread")
        try #require(sent.count == 2)
        #expect(sent[0]["conversationId"]?.stringValue == "s_alice_bob")
        #expect(sent[0]["unread"] == .bool(true))

        // `false` must be on the wire: an absent `unread` means *true* to the server.
        #expect(sent[1]["unread"] == .bool(false))

        await client.disconnect()
    }

    @Test("setStatus sends the status, and a nil status sends an empty body that clears it")
    func setStatusBody() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.user.setStatus(SetStatusRequest("in a meeting"))
        try await client.user.setStatus(SetStatusRequest(status: nil))

        let sent = channel.requests(for: "user.setStatus")
        try #require(sent.count == 2)
        #expect(sent[0]["status"]?.stringValue == "in a meeting")
        #expect(try Self.keys(of: sent[1]).isEmpty, "nil is omitted, and the server reads that as clear")

        await client.disconnect()
    }

    @Test("setRemark tells an absent remark from an empty tag list")
    func setRemarkBody() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.friend.setRemark(SetRemarkRequest(userId: "bob", remark: "Bob from ops", tags: ["work"]))
        try await client.friend.setRemark(SetRemarkRequest(userId: "bob", remark: nil, tags: []))

        let sent = channel.requests(for: "friend.setRemark")
        try #require(sent.count == 2)
        #expect(sent[0]["userId"]?.stringValue == "bob")
        #expect(sent[0]["remark"]?.stringValue == "Bob from ops")
        #expect(sent[0]["tags"] == .array([.string("work")]))

        // The server reads these two absences differently: a missing remark clears it, an empty tag
        // list clears the tags, and a missing tag list would have left them alone.
        #expect(try Self.keys(of: sent[1]) == ["userId", "tags"])
        #expect(sent[1]["tags"] == .array([]))

        await client.disconnect()
    }

    // MARK: - group

    @Test("the group administration calls send each field in the JSON type the server binds")
    func groupAdministrationBodies() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.group.transfer(TransferOwnerRequest(groupId: "g-1", newOwnerId: "bob"))
        try await client.group.handleApplication(HandleApplicationRequest(groupId: "g-1", applicantId: "dave", accept: false, reason: "full"))
        try await client.group.setRole(SetRoleRequest(groupId: "g-1", userId: "bob", role: .admin))
        try await client.group.mute(MuteGroupRequest(groupId: "g-1", untilMs: 1_758_499_200_000))
        try await client.group.mute(MuteGroupRequest(groupId: "g-1", mute: false))
        try await client.group.muteMember(MuteMemberRequest(groupId: "g-1", userId: "bob", untilMs: 1_758_499_200_000))
        try await client.group.muteMember(MuteMemberRequest(groupId: "g-1", userId: "bob", untilMs: nil))
        try await client.group.setNickname(SetGroupNicknameRequest(groupId: "g-1", nickname: "Al"))
        try await client.group.setNickname(SetGroupNicknameRequest(groupId: "g-1", userId: "bob", nickname: "Bobby"))
        try await client.group.announcement(AnnouncementRequest(groupId: "g-1", announcement: "Standup at ten"))
        try await client.group.announcement(AnnouncementRequest(groupId: "g-1", announcement: nil))

        let transfer = try #require(channel.requests(for: "group.transfer").first)
        #expect(try Self.keys(of: transfer) == ["groupId", "newOwnerId"])
        #expect(transfer["newOwnerId"]?.stringValue == "bob")

        // `false` is on the wire: an absent `accept` would also reject, but by accident.
        let handled = try #require(channel.requests(for: "group.handleApplication").first)
        #expect(handled["applicantId"]?.stringValue == "dave")
        #expect(handled["accept"] == .bool(false))
        #expect(handled["reason"]?.stringValue == "full")

        // The role is the integer the server's enum binds from; its name would be refused.
        let role = try #require(channel.requests(for: "group.setRole").first)
        #expect(role["userId"]?.stringValue == "bob")
        #expect(role["role"] == .int(2))

        let mutes = channel.requests(for: "group.mute")
        try #require(mutes.count == 2)
        #expect(mutes[0]["mute"] == .bool(true), "the default is sent, not left to the server")
        #expect(mutes[0]["untilMs"] == .int(1_758_499_200_000))
        #expect(mutes[1]["mute"] == .bool(false))
        #expect(mutes[1]["untilMs"] == nil)

        let memberMutes = channel.requests(for: "group.muteMember")
        try #require(memberMutes.count == 2)
        #expect(memberMutes[0]["untilMs"] == .int(1_758_499_200_000))
        #expect(try Self.keys(of: memberMutes[1]) == ["groupId", "userId"], "nil unmutes by being absent")

        let nicknames = channel.requests(for: "group.setNickname")
        try #require(nicknames.count == 2)
        #expect(try Self.keys(of: nicknames[0]) == ["groupId", "nickname"], "no userId means the caller")
        #expect(nicknames[1]["userId"]?.stringValue == "bob")
        #expect(nicknames[1]["nickname"]?.stringValue == "Bobby")

        let announcements = channel.requests(for: "group.announcement")
        try #require(announcements.count == 2)
        #expect(announcements[0]["announcement"]?.stringValue == "Standup at ten")
        #expect(try Self.keys(of: announcements[1]) == ["groupId"], "nil clears by being absent")

        await client.disconnect()
    }

    @Test("setRole refuses the owner and unknown roles before a frame is written")
    func setRoleRefusesWhatTheServerWouldStore() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // The owner is refused with the server's own code and advice.
        do {
            try await client.group.setRole(SetRoleRequest(groupId: "g-1", userId: "bob", role: .owner))
            Issue.record("making an owner through setRole should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .unsupportedOperation)
            #expect(error.target == "group.setRole")
            #expect(error.message.contains("group.transfer"))
        }

        // `0` would escape a group-wide mute and `4` would outrank the admins — and the server stores
        // either without complaint, which is why the SDK does not send them.
        for raw in [0, 4] {
            do {
                try await client.group.setRole(SetRoleRequest(groupId: "g-1", userId: "bob", role: GroupRole(raw)))
                Issue.record("role \(raw) should not have been sent")
            } catch let error as ImError {
                #expect(error.code == .invalidArgument)
                #expect(error.target == "group.setRole")
            }
        }

        #expect(channel.requests(for: "group.setRole").isEmpty, "nothing reached the wire")

        await client.disconnect()
    }

    @Test("applicationList defaults to every managed group and keeps every status")
    func applicationListDecodes() async throws {
        let gateway = Self.gateway { request, channel in
            guard request.target == "group.applicationList" else { return false }

            channel.reply(to: request, data: .object([
                "items": .array([
                    .object([
                        "appId": .string("app-test"),
                        "groupId": .string("g-1"),
                        "applicantId": .string("dave"),
                        "inviterId": .string("bob"),
                        "reason": .string("on-call rotation"),
                        "status": .int(0),
                        "createdAt": .int(1_700_000_000_000),
                    ]),
                    .object([
                        "appId": .string("app-test"),
                        "groupId": .string("g-2"),
                        "applicantId": .string("erin"),
                        "status": .int(1),
                        "handlerId": .string("alice"),
                        "handleReason": .string("welcome"),
                        "createdAt": .int(1_699_000_000_000),
                        "handledAt": .int(1_699_000_500_000),
                    ]),
                    .object([
                        "appId": .string("app-test"),
                        "groupId": .string("g-2"),
                        "applicantId": .string("frank"),
                        "status": .int(9),
                        "createdAt": .int(1_698_000_000_000),
                    ]),
                ]),
                "hasMore": .bool(false),
            ]))
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let page = try await client.group.applicationList()

        // An empty group id is the server's "every group I manage", and 50 is its own default.
        let sent = try #require(channel.requests(for: "group.applicationList").first)
        #expect(sent["groupId"]?.stringValue == "")
        #expect(sent["limit"] == .int(50))
        #expect(sent["cursor"] == nil)

        try #require(page.items.count == 3)

        let pending = page.items[0]
        #expect(pending.applicantId == "dave")
        #expect(pending.inviterId == "bob")
        #expect(pending.reason == "on-call rotation")
        #expect(pending.status == .pending)
        #expect(pending.handledAt == nil)
        #expect(pending.id == "g-1/dave")

        // The server does not filter by status, so a handled row is part of the answer.
        let accepted = page.items[1]
        #expect(accepted.status == .accepted)
        #expect(accepted.handlerId == "alice")
        #expect(accepted.handleReason == "welcome")
        #expect(accepted.handledAt == 1_699_000_500_000)

        // A status this build has never heard of keeps its raw value rather than costing the page.
        #expect(page.items[2].status.rawValue == 9)

        await client.disconnect()
    }

    // MARK: - Refusals

    @Test("search's two refusals reach the caller with their codes and their retry advice")
    func searchRefusals() async throws {
        let replies = ScriptedResponder([
            .failure(.featureNotEnabled, "search is not enabled for this app"),
            .failure(.rateLimited, "search rate limit exceeded"),
        ])

        let gateway = Self.gateway { request, channel in
            guard request.target == "msg.search" else { return false }
            replies.answer(request, channel)
            return true
        }

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        // Off by default: 1203, terminal, and not something to remember — the tenant can turn it on.
        do {
            _ = try await client.msg.search(SearchMessagesRequest(keyword: "invoice"))
            Issue.record("a disabled search should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .featureNotEnabled)
            #expect(error.target == "msg.search")
            #expect(!error.isRetryable)
        }

        // The per-user limiter runs first, so this can come back even while search is off.
        do {
            _ = try await client.msg.search(SearchMessagesRequest(keyword: "invoice"))
            Issue.record("a rate-limited search should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .rateLimited)
            #expect(error.isRetryable)
        }

        await client.disconnect()
    }

    // MARK: - The escape hatch

    @Test("invoke with EmptyBody succeeds on an acknowledgement that carries no data")
    func invokeAcceptsAnAcknowledgement() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            // The gateway omits `data` altogether on a reply that has none.
            channel.push(ImFrame(
                id: request.id,
                target: request.target,
                status: 0,
                body: ImBody(code: .ok, serverTime: ImClock.nowMilliseconds(), data: nil)
            ))
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // The worked example in the README, which used to report failure after it had succeeded.
        let _: EmptyBody = try await client.invoke("msg.cancelScheduled", body: [
            "scheduleId": .string("sc_1"),
        ] as [String: JSONValue])

        let sent = try #require(channel.requests(for: "msg.cancelScheduled").first)
        #expect(sent["scheduleId"]?.stringValue == "sc_1")

        // A payload type that is not EmptyBody still needs a payload.
        do {
            let _: MessageReceipt = try await client.invoke("msg.receiptDetail", body: EmptyBody())
            Issue.record("a missing payload should not decode as a receipt")
        } catch let error as ImError {
            #expect(error.code == .internalError)
        }

        await client.disconnect()
    }
}
