import Foundation
import Testing

@testable import CyaimIM

/// `room.*` — the seven chat-room calls, the `room.*` events inside `evt.system`, and the one rule a
/// room imposes on the rest of the client: **its messages carry seq 0 and never enter cursors or gap
/// repair**.
///
/// Every call is asserted on the frame it puts on the wire — target and the whole body, compared as a
/// ``JSONValue`` so `.string("7")`, `.int(7)` and an absent key are told apart — and on what it makes
/// of a reply with every field set. The seq-0 tests are the reason this family needed typing at all:
/// a client that fed a room message into the repair path would ask `msg.sync` for a range that does
/// not exist on every message, hold a live room behind another conversation's repair, or move a
/// cursor with a number that means nothing. Mirrors the Kotlin `RoomTest`.
///
/// 每个调用都断言发出的整帧与对满字段答复的解码；seq 0 那几条是这一族非类型化不可的原因：
/// 把聊天室消息喂进补洞的客户端会对每条消息去要一段不存在的区间、让直播间排在别的会话补洞后面，
/// 或者用一个毫无意义的数去动会话游标。
@Suite("Room")
struct RoomTests {

    /// Past 2^53 and odd, so a trip through a Double would change its last digit.
    private static let bigId: Int64 = 360_381_357_961_969_667

    /// Every member of the server's ChatRoom, each with a value no default reads as — so a CodingKey
    /// spelled wrong decodes to a default and an expectation below fails.
    /// `fixturesCarryEveryServerMember` holds the list to the inventory.
    private static func chatRoom() -> JSONValue {
        .object([
            "appId": .string("demo"),
            "roomId": .string("lobby"),
            "name": .string("Launch stream"),
            "avatar": .string("rooms/lobby.png"),
            "ownerId": .string("alice"),
            "admins": .array([.string("carol")]),
            "maxOnline": .int(5_000_000_000),
            "historyBufferSize": .int(20),
            "rateLimitPerSecond": .int(150),
            "muteAll": .bool(true),
            "destroyed": .bool(true),
            "createdAt": .int(1_755_000_000_000),
            "extensions": .object(["topic": .string("launch")]),
        ])
    }

    /// A room message as the server builds one: seq 0, `r_<roomId>`, type ChatRoom, online only.
    private static func roomMessage(_ roomId: String, _ n: Int64, sender: String = "bob") -> JSONValue {
        .object([
            "appId": .string("demo"),
            "conversationId": .string("r_\(roomId)"),
            "conversationType": .int(3),
            "seq": .int(0),
            "messageId": .string(String(Self.bigId + n)),
            "clientMsgId": .string("room-\(n)"),
            "senderId": .string(sender),
            "senderPlatform": .int(2),
            "contentType": .int(1),
            "content": .object(["text": .string("wave \(n)")]),
            "options": .object([
                "persistent": .bool(false),
                "updateConversation": .bool(false),
                "countUnread": .bool(false),
                "offlinePush": .bool(false),
                "onlineOnly": .bool(true),
                "priority": .int(1),
            ]),
            "sendTime": .int(1_755_000_000_000 + n),
            "createTime": .int(1_755_000_000_000 + n),
        ])
    }

    private static func joinResult() -> JSONValue {
        .object([
            "room": Self.chatRoom(),
            "onlineCount": .int(3_000_000_000),
            "recent": .array([Self.roomMessage("lobby", 1), Self.roomMessage("lobby", 2)]),
        ])
    }

    /// The server's SendMessageResult for a room: seq is always 0, the id is a string.
    private static func sendResult(_ request: SentRequest) -> JSONValue {
        let roomId = request["roomId"]?.stringValue ?? ""
        let key = request["message"]?["clientMsgId"]?.stringValue ?? ""

        return .object([
            "messageId": .string(String(Self.bigId + 10)),
            "seq": .int(0),
            "conversationId": .string("r_\(roomId)"),
            "clientMsgId": .string(key),
            "createTime": .int(1_755_000_000_500),
            "deduplicated": .bool(true),
            "contentModified": .bool(true),
        ])
    }

    private static func gateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "room.join":
                channel.reply(to: request, data: Self.joinResult())
            case "room.send":
                channel.reply(to: request, data: Self.sendResult(request))
            case "room.onlineCount":
                channel.reply(to: request, data: .int(3_000_000_000))
            case "room.memberList":
                channel.reply(to: request, data: .object([
                    "items": .array([.string("bob"), .string("carol")]),
                    "nextCursor": .string("1"),
                    "hasMore": .bool(true),
                ]))
            case "msg.sync":
                // Left unanswered on purpose: a repair stays in flight, which is what the "not held
                // behind a repair" test needs, and no other test here may ask for one at all.
                break
            default:
                // quit, mute and kick acknowledge the way the server does: no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    /// A request encoded exactly as ``ImConnection`` encodes a frame's body, read back as JSON.
    private static func wire(_ request: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    }

    private static func keys(_ value: JSONValue?) -> Set<String> {
        guard case let .object(members)? = value else { return [] }
        return Set(members.keys)
    }

    /// `conversationId#seq`, so an ordering claim reads as one comparison.
    private static func positions(_ messages: [ImMessage]) -> [String] {
        messages.map { "\($0.conversationId)#\($0.seq)" }
    }

    // MARK: - The calls

    @Test("room.join sends only the room and decodes the room, the head count and the recent messages")
    func joinDecodesTheRoom() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let joined = try await client.room.join(RoomIdRequest("lobby"))

        let sent = channel.requests(for: "room.join").map(\.body)
        #expect(sent == [.object(["roomId": .string("lobby")])])

        let room = joined.room
        #expect(room.appId == "demo")
        #expect(room.roomId == "lobby")
        #expect(room.id == "lobby")
        #expect(room.name == "Launch stream")
        #expect(room.avatar == "rooms/lobby.png")
        #expect(room.ownerId == "alice")
        #expect(room.admins == ["carol"])
        #expect(room.maxOnline == 5_000_000_000, "maxOnline is 64-bit")
        #expect(room.historyBufferSize == 20)
        #expect(room.rateLimitPerSecond == 150)
        #expect(room.muteAll)
        #expect(room.destroyed)
        #expect(room.createdAt == 1_755_000_000_000)
        #expect(room.extensions?["topic"] == .string("launch"))
        #expect(joined.onlineCount == 3_000_000_000, "onlineCount is 64-bit")

        #expect(joined.recent.map(\.messageId) == [Self.bigId + 1, Self.bigId + 2], "string ids, every digit kept")
        let first = try #require(joined.recent.first)
        #expect(first.seq == 0)
        #expect(first.conversationId == "r_lobby")
        #expect(first.conversationType == .chatRoom)
        #expect(first.text == "wave 1")
        #expect(first.options.persistent == false)
        #expect(first.options.onlineOnly)

        // The buffer is handed to the caller and nowhere else: not replayed as live traffic, and not
        // a reason to touch a cursor.
        await settle()
        #expect(messages.count == 0, "join's recent messages are not replayed on messages()")
        #expect(await client.committedSeq(in: "r_lobby") == 0)
        #expect(await client.highestSeq(in: "r_lobby") == 0)
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["r_lobby"] == nil }, "a room never reaches the cursor store")
        #expect(channel.requests(for: "msg.sync").isEmpty)

        await client.disconnect()
    }

    @Test("room.quit and room.onlineCount send only the room, and onlineCount answers a bare 64-bit number")
    func quitAndOnlineCountSendOnlyTheRoom() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let count = try await client.room.onlineCount(RoomIdRequest("lobby"))
        try await client.room.quit(RoomIdRequest(roomId: "lobby"))

        for target in ["room.onlineCount", "room.quit"] {
            let sent = channel.requests(for: target).map(\.body)
            #expect(sent == [.object(["roomId": .string("lobby")])], "\(target): sent \(sent)")
        }
        #expect(count == 3_000_000_000)

        await client.disconnect()
    }

    @Test("room.memberList sends the default limit, passes the cursor back, and decodes a sample page")
    func memberListPagesASample() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let page = try await client.room.memberList(RoomCursorRequest(roomId: "lobby"))
        _ = try await client.room.memberList(RoomCursorRequest(roomId: "lobby", cursor: page.nextCursor, limit: 100))

        let sent = channel.requests(for: "room.memberList").map(\.body)
        #expect(sent == [
            // No cursor on the first page; the limit is always written.
            .object(["roomId": .string("lobby"), "limit": .int(50)]),
            .object(["roomId": .string("lobby"), "cursor": .string("1"), "limit": .int(100)]),
        ])

        #expect(page.items == ["bob", "carol"])
        #expect(page.nextCursor == "1")
        #expect(page.hasMore)
        #expect(page.total == nil)

        await client.disconnect()
    }

    @Test("room.mute writes each absence only when it is asked for, and never as null")
    func muteWritesEachAbsenceOnPurpose() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.room.mute(RoomMuteRequest(roomId: "lobby", userId: "bob", untilMs: 1_755_000_060_000))
        try await client.room.mute(RoomMuteRequest(roomId: "lobby", userId: nil, untilMs: 1_755_000_060_000))
        try await client.room.mute(RoomMuteRequest(roomId: "lobby", userId: nil, untilMs: nil))

        let sent = channel.requests(for: "room.mute").map(\.body)
        #expect(sent == [
            .object(["roomId": .string("lobby"), "userId": .string("bob"), "untilMs": .int(1_755_000_060_000)]),
            // No userId is the whole room.
            .object(["roomId": .string("lobby"), "untilMs": .int(1_755_000_060_000)]),
            // No untilMs lifts the mute. A JSON null here would be a key with .null and fail this.
            .object(["roomId": .string("lobby")]),
        ])

        await client.disconnect()
    }

    @Test("room.kick names the room and the member")
    func kickNamesTheMember() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.room.kick(RoomKickRequest(roomId: "lobby", userId: "bob"))

        let sent = channel.requests(for: "room.kick").map(\.body)
        #expect(sent == [.object(["roomId": .string("lobby"), "userId": .string("bob")])])

        await client.disconnect()
    }

    @Test("room.send writes the message members a room reads, fills a blank key and a zero clock, and keeps given ones")
    func sendWritesTheRoomMessage() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let built = RoomMessage.text("hi")
        let result = try await client.room.send(RoomSendRequest(roomId: "lobby", message: built))
        try await client.room.send(RoomSendRequest(
            roomId: "lobby",
            message: RoomMessage(content: ["text": .string("again")], clientMsgId: " ", sendTime: 0)
        ))
        try await client.room.send(RoomSendRequest(
            roomId: "lobby",
            message: RoomMessage(
                content: ["url": .string("media/a.png")],
                contentType: .image,
                clientMsgId: "cid-room",
                mentionAll: true,
                mentionedUserIds: ["carol"],
                options: MessageOptions(priority: .low),
                sendTime: 1_755_000_000_100,
                extensions: ["k": .string("v")]
            )
        ))

        let sent = channel.requests(for: "room.send").map(\.body)
        #expect(sent.count == 3)
        guard sent.count == 3 else {
            await client.disconnect()
            return
        }

        // Exact camelCase, because the server matches keys inside `message` case-sensitively and
        // drops a miscased one without a word. No receiver, group, conversation, quote or thread.
        #expect(Self.keys(sent[0]) == ["roomId", "message"])
        #expect(sent[0]["roomId"] == .string("lobby"))
        let plain = sent[0]["message"]
        #expect(Self.keys(plain) == ["content", "contentType", "clientMsgId", "mentionAll", "mentionedUserIds", "sendTime"])
        #expect(plain?["content"] == .object(["text": .string("hi")]))
        #expect(plain?["contentType"] == .int(1), "an integer on the wire")
        #expect(plain?["mentionAll"] == .bool(false))
        #expect(plain?["mentionedUserIds"] == .array([]))
        // Minted when the message was built, so a retry of the same request reuses it.
        #expect(!built.clientMsgId.isEmpty)
        #expect(plain?["clientMsgId"] == .string(built.clientMsgId))
        #expect(plain?["sendTime"] == .int(built.sendTime))
        #expect(built.sendTime > 0)

        // A blank key is filled and a zero clock stamped: the server answers 1001 without a key.
        let blank = sent[1]["message"]
        let filled = try #require(blank?["clientMsgId"]?.stringValue)
        #expect(!filled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "a blank key is filled in")
        if case let .int(clock)? = blank?["sendTime"] {
            #expect(clock > 0, "a zero clock is stamped")
        } else {
            Issue.record("sendTime did not leave as an integer: \(String(describing: blank?["sendTime"]))")
        }

        // Everything given is kept, member for member.
        let options = try Self.wire(MessageOptions(priority: .low))
        #expect(options["priority"] == .int(0), "priority leaves as its integer")
        #expect(sent[2] == .object([
            "roomId": .string("lobby"),
            "message": .object([
                "content": .object(["url": .string("media/a.png")]),
                "contentType": .int(2),
                "clientMsgId": .string("cid-room"),
                "mentionAll": .bool(true),
                "mentionedUserIds": .array([.string("carol")]),
                "options": options,
                "sendTime": .int(1_755_000_000_100),
                "extensions": .object(["k": .string("v")]),
            ]),
        ]))

        #expect(result.messageId == Self.bigId + 10, "a string id, every digit kept")
        #expect(result.seq == 0)
        #expect(result.conversationId == "r_lobby")
        #expect(result.clientMsgId == built.clientMsgId)
        #expect(result.createTime == 1_755_000_000_500)
        #expect(result.deduplicated)
        #expect(result.contentModified)

        #expect(channel.requests(for: "msg.send").isEmpty, "a room send is not a msg.send")

        await client.disconnect()
    }

    @Test("a refused room send reaches the caller with its code")
    func refusedSendThrows() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            if request.target == "room.send" {
                channel.reply(
                    to: request,
                    code: .notInRoom,
                    message: "join the room before sending to it",
                    traceId: "trace-1602"
                )
            }
        })
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            try await client.room.send(RoomSendRequest(roomId: "lobby", message: .text("hi")))
            Issue.record("a refused room send should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .notInRoom)
            #expect(error.target == "room.send")
            #expect(error.traceId == "trace-1602")
            #expect(!error.isRetryable)
        }

        await client.disconnect()
    }

    // MARK: - seq 0 stays out of repair

    @Test("a seq-0 room message is delivered at once and never enters gap repair")
    func seqZeroNeverEntersRepair() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 1))
        _ = await waitUntil("c1 seq 1") { messages.count == 1 }

        // Three room messages, all at seq 0: each is delivered — not taken for a duplicate of the
        // last — and none is taken for a gap in its own "conversation" or in c1's.
        for n in Int64(1) ... 3 {
            channel.event(.message, data: Self.roomMessage("lobby", n))
        }
        _ = await waitUntil("three room messages") { messages.count == 4 }

        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 2))
        _ = await waitUntil("c1 seq 2") { messages.count == 5 }
        await settle()

        #expect(Self.positions(messages.items) == ["c1#1", "r_lobby#0", "r_lobby#0", "r_lobby#0", "c1#2"])
        #expect(messages.items.filter { $0.seq == 0 }.compactMap(\.text) == ["wave 1", "wave 2", "wave 3"])
        #expect(channel.requests(for: "msg.sync").isEmpty, "a room message is never a range to repair")

        // c1's cursor did not move for the room traffic, so the next real message is contiguous.
        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 3))
        _ = await waitUntil("c1 seq 3") { messages.count == 6 }
        await settle()

        #expect(messages.items.filter { $0.conversationId == "c1" }.map(\.seq) == [1, 2, 3])
        #expect(channel.requests(for: "msg.sync").isEmpty)

        #expect(await client.committedSeq(in: "r_lobby") == 0)
        #expect(await client.highestSeq(in: "r_lobby") == 0)
        await client.enterBackground()
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["r_lobby"] == nil }, "a room never reaches the cursor store")

        await client.disconnect()
    }

    @Test("a room message is not held behind another conversation's repair in flight")
    func roomMessageIsNotHeldBehindARepair() async throws {
        // msg.sync is left unanswered (and the timeout is long): c1's repair is still in flight when
        // the room message lands.
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .seconds(10)))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 1))
        _ = await waitUntil("c1 seq 1") { messages.count == 1 }
        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 5))
        _ = await waitUntil("c1 starts repairing 2…4") { channel.requests(for: "msg.sync").count == 1 }

        channel.event(.message, data: Self.roomMessage("lobby", 1))
        _ = await waitUntil("the room message, ahead of the repair") { messages.count == 2 }
        await settle()

        #expect(Self.positions(messages.items) == ["c1#1", "r_lobby#0"], "the room message did not wait for c1's repair")
        #expect(channel.requests(for: "msg.sync").count == 1, "and asked for no repair of its own")

        await client.disconnect()
    }

    @Test("committing a room message changes no cursor, and a real commit still does")
    func committingARoomMessageChangesNoCursor() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        try await client.connect()

        // The application that commits everything it stores, room messages included.
        await client.commit("r_lobby", seq: 0)
        await client.commit("c1", seq: 4)
        await client.enterBackground()
        _ = await waitUntil("the real commit reached the store") { store.current.convSeqs["c1"] == 4 }

        #expect(await client.committedSeq(in: "r_lobby") == 0)
        #expect(await client.committedSeq(in: "c1") == 4)
        #expect(store.current.convSeqs == ["c1": 4], "only the real conversation is stored")
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["r_lobby"] == nil })

        await client.disconnect()
    }

    @Test("a room send result moves no cursor and is not delivered as a message")
    func roomSendResultMovesNoCursor() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.room.send(RoomSendRequest(roomId: "lobby", message: .text("hi")))
        await client.enterBackground()
        await settle()

        #expect(await client.committedSeq(in: "r_lobby") == 0)
        #expect(await client.highestSeq(in: "r_lobby") == 0)
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["r_lobby"] == nil })
        #expect(messages.count == 0, "the echo, if any, is the server's evt.message — not the reply")
        #expect(channel.requests(for: "msg.sync").isEmpty)

        await client.disconnect()
    }

    // MARK: - room.* events

    @Test("room events come out of evt.system — the kicked member's own included — and nothing else on it does")
    func roomEventsComeOutOfEvtSystem() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let events = Collector(client.roomEvents())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        func system(_ event: String, _ body: [String: JSONValue]) {
            channel.event(.system, data: .object(["event": .string(event), "body": .object(body)]))
        }

        system(RoomEvent.muted, ["roomId": .string("lobby"), "operatorId": .string("alice"), "untilMs": .int(1_755_000_060_000)])
        system(RoomEvent.muted, ["roomId": .string("lobby"), "operatorId": .string("carol"), "userId": .string("bob")])
        // A quoted until-time: a 64-bit value may arrive as a string.
        system(RoomEvent.muted, [
            "roomId": .string("lobby"),
            "operatorId": .string("carol"),
            "userId": .string("dave"),
            "untilMs": .string("1755000060000"),
        ])
        // makeOptions signs in as alice: the server writes room.kicked to the kicked member's own
        // connections too, and the client must hand it over rather than read it as someone else's.
        system(RoomEvent.kicked, ["roomId": .string("lobby"), "operatorId": .string("carol"), "userId": .string("alice")])
        system(RoomEvent.destroyed, ["roomId": .string("lobby"), "operatorId": .string("ops")])
        system("room.renamed", ["roomId": .string("lobby"), "operatorId": .string("ops"), "name": .string("After party")])
        // Not a room's: the device-log request shares the target, and so does whatever comes next.
        system("device.logRequest", ["requestId": .string("lr_1"), "deviceId": .string("another-device")])
        system("roomish.event", ["roomId": .string("lobby")])
        channel.event(.system, data: .string("not an object"))
        channel.event(.message, data: Self.roomMessage("lobby", 1))

        _ = await waitUntil("six room events") { events.count >= 6 }
        await settle()
        let received = events.items
        events.stop()

        #expect(
            received.map(\.event) == [
                RoomEvent.muted, RoomEvent.muted, RoomEvent.muted, RoomEvent.kicked, RoomEvent.destroyed, "room.renamed",
            ],
            "only room.* events, the unknown one included: \(received.map(\.event))"
        )
        guard received.count == 6 else {
            await client.disconnect()
            return
        }

        let wholeRoom = received[0]
        #expect(wholeRoom.roomId == "lobby")
        #expect(wholeRoom.operatorId == "alice")
        #expect(wholeRoom.userId == nil, "no userId is the whole room")
        #expect(wholeRoom.untilMs == 1_755_000_060_000)

        let member = received[1]
        #expect(member.userId == "bob")
        #expect(member.operatorId == "carol")
        #expect(member.untilMs == nil, "no untilMs: the mute was lifted")

        #expect(received[2].userId == "dave")
        #expect(received[2].untilMs == 1_755_000_060_000, "a quoted until-time is read")

        let kicked = received[3]
        #expect(kicked.userId == "alice", "the kicked member hears its own room.kicked")
        #expect(kicked.operatorId == "carol")
        #expect(kicked.roomId == "lobby")
        #expect(kicked.untilMs == nil)

        let destroyed = received[4]
        #expect(destroyed.roomId == "lobby")
        #expect(destroyed.operatorId == "ops")
        #expect(destroyed.userId == nil)

        let renamed = received[5]
        #expect(renamed.roomId == "lobby")
        #expect(renamed.operatorId == "ops")
        #expect(renamed.body["name"] == .string("After party"), "an unknown event keeps its whole body")

        await client.disconnect()
    }

    @Test("only a room.* name is a room event, and an explicit null reads as absent")
    func onlyRoomNamesAreRoomEvents() throws {
        #expect(RoomEvent.fromSystemData(nil) == nil)
        #expect(RoomEvent.fromSystemData(.string("room.muted")) == nil, "not an object")
        #expect(RoomEvent.fromSystemData(.object(["body": .object(["roomId": .string("lobby")])])) == nil, "no event name")
        #expect(RoomEvent.fromSystemData(.object(["event": .int(1)])) == nil, "an event name that is not a string")
        #expect(
            RoomEvent.fromSystemData(.object(["event": .string("roomy"), "body": .object(["roomId": .string("lobby")])])) == nil,
            "the prefix is room. with the dot"
        )
        #expect(
            RoomEvent.fromSystemData(.object([
                "event": .string("device.logRequest"),
                "body": .object(["requestId": .string("lr_1"), "roomId": .string("lobby")]),
            ])) == nil
        )

        let nulls = try #require(RoomEvent.fromSystemData(.object([
            "event": .string(RoomEvent.muted),
            "body": .object([
                "roomId": .string("lobby"),
                "operatorId": .string("alice"),
                "userId": .null,
                "untilMs": .null,
            ]),
        ])))
        #expect(nulls.roomId == "lobby")
        #expect(nulls.userId == nil, "an explicit null is the whole room, as an absent key is")
        #expect(nulls.untilMs == nil, "an explicit null lifts, as an absent key does")
    }

    @Test("listening for room events leaves the device-log request to its own handler")
    func deviceLogRequestStillReachesItsHandler() async throws {
        // evt.system is shared. The room stream is an extra subscriber: it must not swallow the device
        // log request the client answers on its own subscription.
        // evt.system 是共享的：房间事件流只是多挂的一个订阅者，不能吞掉设备日志请求。
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let events = Collector(client.roomEvents())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // Expired on arrival, so the device-log handler answers it with a log line and no upload —
        // which is the evidence that it still ran.
        channel.event(.system, data: .object([
            "event": .string("device.logRequest"),
            "body": .object([
                "requestId": .string("lr_mine"),
                "deviceId": .string("device-test"),
                "uploadUrl": .string("https://upload.test"),
                "objectKey": .string("k"),
                "expiresAt": .int(1),
                "maxBytes": .int(1_000),
            ]),
        ]))
        channel.event(.system, data: .object([
            "event": .string(RoomEvent.kicked),
            "body": .object(["roomId": .string("lobby"), "operatorId": .string("carol"), "userId": .string("bob")]),
        ]))

        _ = await waitUntil("the room event") { events.count == 1 }
        let answered = await waitUntil("the device-log handler saw its request") {
            await client.log.read().contains { $0.msg.contains("lr_mine") && $0.msg.contains("window closed") }
        }
        #expect(answered, "the device-log handler never saw its request")
        #expect(events.items.map(\.event) == [RoomEvent.kicked])
        events.stop()

        await client.disconnect()
    }

    // MARK: - Held to the inventory

    /// The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
    /// decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
    /// member the server's type declares, and the requests send every member, held here to
    /// `endpoint-inventory.json`'s `payloadTypes`.
    @Test("the full fixtures and requests carry every member the server declares")
    func fixturesCarryEveryServerMember() throws {
        let types = try Self.payloadTypes()

        func members(_ type: String) -> Set<String> {
            let properties = (types[type] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
            return Set(properties.compactMap { $0["name"] as? String })
        }

        #expect(!members("ChatRoom").isEmpty, "the inventory lists no members for ChatRoom")
        #expect(Self.keys(Self.chatRoom()) == members("ChatRoom"))
        #expect(Self.keys(Self.joinResult()) == members("RoomJoinResult"))

        let idRequest = try Self.keys(Self.wire(RoomIdRequest("lobby")))
        let cursorRequest = try Self.keys(Self.wire(RoomCursorRequest(roomId: "lobby", cursor: "1", limit: 20)))
        let muteRequest = try Self.keys(Self.wire(RoomMuteRequest(roomId: "lobby", userId: "bob", untilMs: 1)))
        let kickRequest = try Self.keys(Self.wire(RoomKickRequest(roomId: "lobby", userId: "bob")))
        let sendRequest = try Self.keys(Self.wire(RoomSendRequest(roomId: "lobby", message: .text("hi"))))

        #expect(idRequest == members("RoomIdRequest"))
        #expect(cursorRequest == members("RoomCursorRequest"))
        #expect(muteRequest == members("RoomMuteRequest"))
        #expect(kickRequest == members("RoomKickRequest"))
        #expect(sendRequest == members("RoomSendRequest"))
    }

    /// `RoomMessage` is the server's `SendMessageRequest` minus what a room never reads. This pins
    /// both halves: every member it sends is a member of the server type (so none is dropped as
    /// unknown), and what it leaves out is exactly the addressing, quoting and threading a room has no
    /// use for — a member the server adds shows up here instead of going unexamined.
    @Test("a room message sends server members only, and leaves out exactly what a room ignores")
    func roomMessageLeavesOutExactlyWhatARoomIgnores() throws {
        let types = try Self.payloadTypes()
        let properties = (types["SendMessageRequest"] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
        let server = Set(properties.compactMap { $0["name"] as? String })

        let full = try Self.keys(Self.wire(RoomMessage(
            content: ["text": .string("hi")],
            contentType: .text,
            clientMsgId: "c",
            mentionAll: true,
            mentionedUserIds: ["bob"],
            options: MessageOptions(),
            sendTime: 1,
            extensions: ["k": .string("v")]
        )))

        #expect(!server.isEmpty, "the inventory lists no members for SendMessageRequest")
        #expect(full.subtracting(server).isEmpty, "sent, but not a member of the server's SendMessageRequest: \(full.subtracting(server).sorted())")
        #expect(
            server.subtracting(full) == [
                "conversationId", "receiverId", "groupId", "conversationType", "quoteMessageId", "threadRootId",
            ]
        )
    }

    private static func payloadTypes() throws -> [String: Any] {
        let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.inventoryURL())) as? [String: Any]
        return inventory?["payloadTypes"] as? [String: Any] ?? [:]
    }

    private static func inventoryURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("endpoint-inventory.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
