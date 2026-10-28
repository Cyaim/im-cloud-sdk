import Foundation
import Testing

@testable import CyaimIM

/// `msg.streamBegin` / `streamAppend` / `streamComplete` / `streamAbort`, the `evt.stream` push, and
/// the rule streaming imposes on the rest of the client: **the pieces are not messages** — no seq, no
/// cursor, no repair — **and the finished stream is one**, delivered and repaired like any other.
///
/// Every call is asserted on the frame it puts on the wire — target and the whole body, compared as a
/// ``JSONValue`` so `.string("7")`, `.int(7)` and an absent key are told apart — and on what it makes
/// of a reply with every field set. Each `evt.stream` phase is decoded as the server writes it, and
/// the assembly is driven through every order the server can produce: in order, shed pieces, a
/// duplicate, a mid-stream join, a straggler after the end, and the terminal frame before and after
/// the stored message. Mirrors the Kotlin `StreamTest`.
///
/// 每个调用断言发出的整帧与对满字段答复的解码；evt.stream 的每一相按服务端的写法解码；拼装覆盖服务端能产生的
/// 每一种顺序：按序、丢片、重复、中途加入、收尾后迟到的帧，以及终止帧在存储消息之前与之后。
@Suite("Stream")
struct StreamTests {

    /// Past 2^53 and odd, so a trip through a Double would change its last digit.
    private static let bigId: Int64 = 360_381_357_961_969_667

    /// Every member of the server's StreamHandle, each with a value no default reads as.
    /// `fixturesCarryEveryServerMember` holds the list to the inventory.
    private static func handle() -> JSONValue {
        .object([
            "streamId": .string("st_9f2c"),
            "conversationId": .string("s_alice_bob"),
            "startedAt": .int(1_755_000_000_000),
            "idleTimeoutSeconds": .int(30),
        ])
    }

    /// Every member of the server's SendMessageResult; the id is a string, as the server writes it.
    private static func sendResult(seq: Int64 = 5) -> JSONValue {
        .object([
            "messageId": .string(String(Self.bigId)),
            "seq": .int(seq),
            "conversationId": .string("s_alice_bob"),
            "clientMsgId": .string("cid-stream"),
            "createTime": .int(1_755_000_009_000),
            "deduplicated": .bool(true),
            "contentModified": .bool(true),
        ])
    }

    private static func gateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "msg.streamBegin":
                channel.reply(to: request, data: Self.handle())
            case "msg.streamComplete":
                channel.reply(to: request, data: Self.sendResult())
            case "msg.sync":
                // Left unanswered on purpose: the repair test needs one in flight, and no other test
                // here may ask for one at all.
                break
            default:
                // streamAppend and streamAbort acknowledge the way the server does: no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    // MARK: evt.stream frames, exactly as the server writes them (camelCase, nulls left out)

    private static func beginFrame(_ streamId: String = "st_9f2c", placeholder: [String: JSONValue]? = nil) -> JSONValue {
        var frame: [String: JSONValue] = [
            "streamId": .string(streamId),
            "conversationId": .string("s_alice_bob"),
            "senderId": .string("alice"),
            "index": .int(0),
            "done": .bool(false),
        ]
        if let placeholder {
            frame["placeholder"] = .object(placeholder)
        }
        return .object(frame)
    }

    private static func deltaFrame(_ index: Int64, _ delta: String, streamId: String = "st_9f2c") -> JSONValue {
        .object([
            "streamId": .string(streamId),
            "conversationId": .string("s_alice_bob"),
            "senderId": .string("alice"),
            "index": .int(index),
            "delta": .string(delta),
            "done": .bool(false),
        ])
    }

    private static func completedFrame(_ index: Int64, seq: Int64 = 5, streamId: String = "st_9f2c") -> JSONValue {
        .object([
            "streamId": .string(streamId),
            "conversationId": .string("s_alice_bob"),
            "senderId": .string("alice"),
            "index": .int(index),
            "done": .bool(true),
            "messageId": .string(String(Self.bigId)),
            "seq": .int(seq),
        ])
    }

    private static func abortedFrame(_ index: Int64, _ reason: String, streamId: String = "st_9f2c") -> JSONValue {
        .object([
            "streamId": .string(streamId),
            "conversationId": .string("s_alice_bob"),
            "senderId": .string("alice"),
            "index": .int(index),
            "done": .bool(true),
            "abortReason": .string(reason),
        ])
    }

    /// The stored message a completed stream becomes: an ordinary evt.message with a real seq.
    private static func storedMessage(seq: Int64, text: String) -> JSONValue {
        .object([
            "appId": .string("app-test"),
            "conversationId": .string("s_alice_bob"),
            "conversationType": .int(1),
            "seq": .int(seq),
            "messageId": .string(String(Self.bigId)),
            "clientMsgId": .string("cid-stream"),
            "senderId": .string("alice"),
            "senderPlatform": .int(2),
            "contentType": .int(1),
            "content": .object(["text": .string(text)]),
            "sendTime": .int(1_755_000_000_000),
            "createTime": .int(1_755_000_009_000),
        ])
    }

    private static func event(_ frame: JSONValue) throws -> StreamEvent {
        try #require(StreamEvent.fromData(frame), "undecodable: \(frame)")
    }

    /// Feeds frames to an assembler in order and returns what the last one made of its stream.
    @discardableResult
    private static func feed(_ assembler: inout StreamAssembler, _ frames: JSONValue...) throws -> AssembledStream? {
        var last: AssembledStream?
        for frame in frames {
            let decoded = try Self.event(frame)
            last = assembler.accept(decoded)
        }
        return last
    }

    /// A request encoded exactly as ``ImConnection`` encodes a frame's body, read back as JSON.
    private static func wire(_ request: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    }

    private static func keys(_ value: JSONValue?) -> Set<String> {
        guard case let .object(members)? = value else { return [] }
        return Set(members.keys)
    }

    // MARK: - The calls

    @Test("msg.streamBegin sends the minted key and the content type as an integer, fills a blank key, and decodes the handle")
    func streamBeginKeysAndDecodesTheHandle() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let built = BeginStreamRequest(receiverId: "bob")
        let opened = try await client.msg.streamBegin(built)
        _ = try await client.msg.streamBegin(BeginStreamRequest(receiverId: "bob", clientMsgId: " "))

        let sent = channel.requests(for: "msg.streamBegin").map(\.body)
        #expect(sent.count == 2)
        guard sent.count == 2 else {
            await client.disconnect()
            return
        }

        // Nils stay off the frame. The key was minted when the request was built, so a retry of the
        // same request reuses it; the content type is an integer.
        #expect(!built.clientMsgId.isEmpty)
        #expect(sent[0] == .object([
            "receiverId": .string("bob"),
            "clientMsgId": .string(built.clientMsgId),
            "contentType": .int(1),
        ]))

        // A blank key is filled in: the server makes none up and answers 1001 without one.
        #expect(Self.keys(sent[1]) == ["receiverId", "clientMsgId", "contentType"])
        let filled = try #require(sent[1]["clientMsgId"]?.stringValue)
        #expect(!filled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "a blank key is filled in")

        #expect(opened.streamId == "st_9f2c")
        #expect(opened.conversationId == "s_alice_bob")
        #expect(opened.startedAt == 1_755_000_000_000)
        #expect(opened.idleTimeoutSeconds == 30)

        await client.disconnect()
    }

    @Test("msg.streamBegin writes every member it is given, options nested in exact camelCase")
    func streamBeginWritesEveryMember() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.msg.streamBegin(BeginStreamRequest(
            conversationId: "g_team",
            receiverId: "bob",
            groupId: "team",
            clientMsgId: "cid-stream",
            contentType: .custom,
            placeholder: ["name": .string("Assistant"), "avatar": .string("bots/a.png")],
            options: MessageOptions(
                persistent: false,
                updateConversation: false,
                countUnread: false,
                offlinePush: false,
                pushConfig: PushConfig(sound: "ding", payload: ["k": "v"], badgeCount: false, channelId: "ai"),
                needReceipt: true,
                priority: .high,
                onlineOnly: true,
                noSelfSync: true,
                expireIn: 60_000,
                moderationBypass: true
            ),
            extensions: ["model": .string("m-1")]
        ))

        // Built in typed steps rather than one literal, so the type checker is not asked to solve a
        // three-level implicit-member expression inside a macro.
        // title and body are absent because a client may not send them (1103), not because they
        // cannot be.
        let pushConfig: [String: JSONValue] = [
            "sound": .string("ding"),
            "payload": .object(["k": .string("v")]),
            "badgeCount": .bool(false),
            "channelId": .string("ai"),
        ]
        // Nested and matched case-sensitively by the socket: a miscased key would be dropped without
        // a word.
        let options: [String: JSONValue] = [
            "persistent": .bool(false),
            "updateConversation": .bool(false),
            "countUnread": .bool(false),
            "offlinePush": .bool(false),
            "pushConfig": .object(pushConfig),
            "needReceipt": .bool(true),
            "priority": .int(2),
            "onlineOnly": .bool(true),
            "noSelfSync": .bool(true),
            "expireIn": .int(60_000),
            "moderationBypass": .bool(true),
        ]
        let expected: JSONValue = .object([
            "conversationId": .string("g_team"),
            "receiverId": .string("bob"),
            "groupId": .string("team"),
            // A given key is kept.
            "clientMsgId": .string("cid-stream"),
            "contentType": .int(100),
            "placeholder": .object(["name": .string("Assistant"), "avatar": .string("bots/a.png")]),
            "options": .object(options),
            "extensions": .object(["model": .string("m-1")]),
        ])

        let sent = channel.requests(for: "msg.streamBegin").map(\.body)
        #expect(sent == [expected])
        #expect(Self.keys(sent.first?["options"]?["pushConfig"]) == ["sound", "payload", "badgeCount", "channelId"])

        await client.disconnect()
    }

    @Test("msg.streamAppend and msg.streamAbort send the stream id and their one field, as strings")
    func appendAndAbortSendTheirField() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.msg.streamAppend(StreamAppendRequest(streamId: "st_9f2c", delta: "Hel"))
        try await client.msg.streamAppend(StreamAppendRequest(streamId: "st_9f2c", delta: ""))
        try await client.msg.streamAbort(StreamAbortRequest(streamId: "st_9f2c", reason: "the model failed"))
        try await client.msg.streamAbort(StreamAbortRequest(streamId: "st_9f2d"))

        #expect(channel.requests(for: "msg.streamAppend").map(\.body) == [
            .object(["streamId": .string("st_9f2c"), "delta": .string("Hel")]),
            // An empty piece still leaves as a string; the server accepts it and does nothing.
            .object(["streamId": .string("st_9f2c"), "delta": .string("")]),
        ])
        #expect(channel.requests(for: "msg.streamAbort").map(\.body) == [
            .object(["streamId": .string("st_9f2c"), "reason": .string("the model failed")]),
            // No reason is left off, never written as null.
            .object(["streamId": .string("st_9f2d")]),
        ])

        await client.disconnect()
    }

    @Test("msg.streamComplete sends only what it is given and decodes the stored message's identity")
    func completeSendsWhatIsGivenAndDecodesTheResult() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let result = try await client.msg.streamComplete(CompleteStreamRequest(streamId: "st_9f2c"))
        try await client.msg.streamComplete(CompleteStreamRequest(
            streamId: "st_9f2c",
            content: ["text": .string("Hello, cleaned up.")],
            extensions: ["tokens": .int(42)]
        ))

        #expect(channel.requests(for: "msg.streamComplete").map(\.body) == [
            // No content: the server joins the pieces itself.
            .object(["streamId": .string("st_9f2c")]),
            .object([
                "streamId": .string("st_9f2c"),
                "content": .object(["text": .string("Hello, cleaned up.")]),
                "extensions": .object(["tokens": .int(42)]),
            ]),
        ])

        #expect(result.messageId == Self.bigId, "a string id, every digit kept")
        #expect(result.seq == 5)
        #expect(result.conversationId == "s_alice_bob")
        #expect(result.clientMsgId == "cid-stream")
        #expect(result.createTime == 1_755_000_009_000)
        #expect(result.deduplicated)
        #expect(result.contentModified)

        await client.disconnect()
    }

    @Test("a refused stream call throws with the server's code and the target")
    func refusedStreamCallsThrow() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "msg.streamBegin":
                channel.reply(to: request, code: .unsupportedOperation, message: "a chat room takes no stream")
            case "msg.streamAppend":
                channel.reply(to: request, code: .notFound, message: "the stream has finished or expired")
            case "msg.streamComplete":
                channel.reply(to: request, code: .moderationRejected, message: "rejected by moderation")
            case "msg.streamAbort":
                channel.reply(to: request, code: .forbidden, message: "the stream is someone else's")
            default:
                channel.reply(to: request, data: .null)
            }
        })
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        func failure(_ call: () async throws -> Void) async -> String {
            do {
                try await call()
                return "succeeded"
            } catch let error as ImError {
                return "\(error.code.rawValue) \(error.target ?? "-")"
            } catch {
                return "\(error)"
            }
        }

        var failures: [String] = []
        failures.append(await failure { _ = try await client.msg.streamBegin(BeginStreamRequest(conversationId: "r_lobby")) })
        failures.append(await failure { try await client.msg.streamAppend(StreamAppendRequest(streamId: "st_gone", delta: "x")) })
        failures.append(await failure { _ = try await client.msg.streamComplete(CompleteStreamRequest(streamId: "st_9f2c")) })
        failures.append(await failure { try await client.msg.streamAbort(StreamAbortRequest(streamId: "st_theirs")) })

        #expect(failures == [
            "1008 msg.streamBegin",
            "1002 msg.streamAppend",
            "1402 msg.streamComplete",
            "1103 msg.streamAbort",
        ])

        await client.disconnect()
    }

    @Test("a StreamWriter opens with a key it keeps and sends every later call for its own stream")
    func streamWriterHoldsTheStream() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let writer = try await StreamWriter.begin(client.msg, BeginStreamRequest(receiverId: "bob", clientMsgId: ""))
        try await writer.append("Hel")
        try await writer.append("lo")
        let result = try await writer.complete()
        try await writer.abort(reason: "too late")

        let key = try #require(channel.requests(for: "msg.streamBegin").first?["clientMsgId"]?.stringValue)
        #expect(!key.isEmpty, "a blank key is filled before the opening goes out")
        #expect(writer.clientMsgId == key, "the writer knows the key the message will be stored under")
        #expect(writer.streamId == "st_9f2c")
        #expect(writer.handle.idleTimeoutSeconds == 30)
        #expect(channel.requests(for: "msg.streamAppend").map(\.body) == [
            .object(["streamId": .string("st_9f2c"), "delta": .string("Hel")]),
            .object(["streamId": .string("st_9f2c"), "delta": .string("lo")]),
        ])
        #expect(channel.requests(for: "msg.streamComplete").map(\.body) == [.object(["streamId": .string("st_9f2c")])])
        #expect(channel.requests(for: "msg.streamAbort").map(\.body) == [
            .object(["streamId": .string("st_9f2c"), "reason": .string("too late")]),
        ])
        #expect(result.messageId == Self.bigId)

        let given = try await StreamWriter.begin(client.msg, BeginStreamRequest(groupId: "team", clientMsgId: "mine"))
        #expect(given.clientMsgId == "mine")
        #expect(channel.requests(for: "msg.streamBegin").last?["clientMsgId"] == .string("mine"))

        await client.disconnect()
    }

    // MARK: - evt.stream

    @Test("each evt.stream phase decodes as the server writes it, the message id as a string or a number")
    func eachPhaseDecodes() throws {
        let begin = try Self.event(Self.beginFrame(placeholder: ["name": .string("Assistant")]))
        #expect(begin.phase == .begin)
        #expect(begin.streamId == "st_9f2c")
        #expect(begin.conversationId == "s_alice_bob")
        #expect(begin.senderId == "alice")
        #expect(begin.index == 0)
        #expect(begin.delta == nil, "the opening carries no delta")
        #expect(!begin.done)
        #expect(begin.placeholder?["name"] == .string("Assistant"))
        let bare = try Self.event(Self.beginFrame())
        #expect(bare.placeholder == nil, "a stream opened without one")

        let delta = try Self.event(Self.deltaFrame(3, "lo, "))
        #expect(delta.phase == .delta)
        #expect(delta.index == 3)
        #expect(delta.delta == "lo, ")
        #expect(delta.messageId == nil)
        #expect(delta.placeholder == nil)

        let completed = try Self.event(Self.completedFrame(4, seq: 5_000_000_000))
        #expect(completed.phase == .completed)
        #expect(completed.done)
        #expect(completed.index == 4)
        #expect(completed.messageId == Self.bigId, "written as a string: every digit kept")
        #expect(completed.seq == 5_000_000_000)
        #expect(completed.abortReason == nil)

        // The same frame with the id as a bare number, as an older server wrote it.
        let numeric = try Self.event(.object([
            "streamId": .string("st_9f2c"),
            "conversationId": .string("s_alice_bob"),
            "senderId": .string("alice"),
            "index": .int(2),
            "done": .bool(true),
            "messageId": .int(77),
            "seq": .int(6),
        ]))
        #expect(numeric.phase == .completed)
        #expect(numeric.messageId == 77)
        #expect(numeric.seq == 6)

        // Numbers may arrive quoted (CONTRACT.md §2).
        let quoted = try Self.event(.object([
            "streamId": .string("st_9f2c"),
            "index": .string("2"),
            "done": .bool(true),
            "messageId": .string("78"),
            "seq": .string("7"),
        ]))
        #expect(quoted.index == 2)
        #expect(quoted.messageId == 78)
        #expect(quoted.seq == 7)
        #expect(quoted.conversationId == "", "an absent member reads as empty rather than failing the frame")

        let aborted = try Self.event(Self.abortedFrame(4, "the producer stopped sending for 30s"))
        #expect(aborted.phase == .aborted)
        #expect(aborted.done)
        #expect(aborted.messageId == nil, "no message id is what makes it an abort")
        #expect(aborted.seq == nil)
        #expect(aborted.abortReason == "the producer stopped sending for 30s")

        // An explicit null reads as absent: done without a message id is still an abort.
        let nulls = try Self.event(.object([
            "streamId": .string("st_9f2c"),
            "index": .int(3),
            "delta": .null,
            "done": .bool(true),
            "messageId": .null,
            "placeholder": .null,
        ]))
        #expect(nulls.phase == .aborted)
        #expect(nulls.delta == nil)
        #expect(nulls.placeholder == nil)

        #expect(StreamEvent.fromData(.string("not an object")) == nil)
        #expect(StreamEvent.fromData(.object(["index": .int(1), "delta": .string("x")])) == nil, "no stream id")
        #expect(StreamEvent.fromData(.object(["streamId": .string(""), "index": .int(1)])) == nil, "an empty stream id")
        #expect(StreamEvent.fromData(.object(["streamId": .int(7), "index": .int(1)])) == nil, "a stream id that is not a string")
        #expect(StreamEvent.fromData(nil) == nil)
    }

    @Test("an index outside the server's 32-bit range reads as 0, as an absent one does, and cannot trap the assembler")
    func outOfRangeIndexReadsAsAbsent() throws {
        // Int64.min is the frame that trapped: as a terminal index it made the assembler compute
        // Int.min - 1 and took the host app down. Kotlin's toInt() reads it as 0 and Int64.max as -1,
        // both of which assemble as an index of 0 does: an opening, or a terminal frame that says
        // nothing about lost pieces; a non-integer reads as 0 there too. Just past the 32-bit edges
        // Kotlin's truncation lands on Int.MIN_VALUE / Int.MAX_VALUE instead — no server writes
        // either, and Swift reads them as 0 like every other index the server could not have written.
        func frame(index: JSONValue, done: Bool) -> JSONValue {
            var members: [String: JSONValue] = [
                "streamId": .string("st_9f2c"),
                "conversationId": .string("s_alice_bob"),
                "senderId": .string("alice"),
                "index": index,
                "done": .bool(done),
            ]
            if done {
                members["messageId"] = .string(String(Self.bigId))
                members["seq"] = .int(5)
            } else {
                members["delta"] = .string("x")
            }
            return .object(members)
        }

        let outOfRange: [JSONValue] = [
            .int(Int64.min),
            .int(Int64.max),
            .int(Int64(Int32.max) + 1),
            .int(Int64(Int32.min) - 1),
            .string(String(Int64.min)),
            .string("99999999999999999999"),
            .double(Double(Int64.min)),
        ]
        for raw in outOfRange {
            let piece = try Self.event(frame(index: raw, done: false))
            #expect(piece.index == 0, "\(raw)")
            #expect(piece.phase == .begin, "a piece with no readable index is an opening, as on Kotlin: \(raw)")

            let end = try Self.event(frame(index: raw, done: true))
            #expect(end.index == 0, "\(raw)")
            #expect(end.phase == .completed, "\(raw)")

            var assembler = StreamAssembler()
            try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"))
            let doneResult = assembler.accept(end)
            let done = try #require(doneResult, "\(raw)")
            #expect(done.status == .completed, "\(raw)")
            #expect(done.text == "a", "\(raw)")
            #expect(done.intact, "the terminal index says nothing was lost: \(raw)")
            #expect(done.messageId == Self.bigId, "\(raw)")
        }

        // The edges of the range are still indices.
        let highest = try Self.event(frame(index: .int(Int64(Int32.max)), done: false))
        #expect(highest.index == Int(Int32.max))
        #expect(highest.phase == .delta)
        let lowest = try Self.event(frame(index: .string(String(Int32.min)), done: false))
        #expect(lowest.index == Int(Int32.min))
        #expect(lowest.phase == .begin)
    }

    @Test("evt.stream frames come out of streamEvents() and never reach messages() or a cursor")
    func streamFramesStayOutOfMessagesAndCursors() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        let events = Collector(client.streamEvents())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 1))
        _ = await waitUntil("seq 1") { messages.count == 1 }

        channel.event(.stream, data: Self.beginFrame())
        channel.event(.stream, data: Self.deltaFrame(1, "Hel"))
        channel.event(.stream, data: Self.deltaFrame(3, "lo"))
        channel.event(.stream, data: .string("not an object"))
        channel.event(.stream, data: Self.abortedFrame(4, "aborted by the producer"))
        _ = await waitUntil("four stream frames") { events.count == 4 }
        await settle()

        #expect(events.items.map(\.index) == [0, 1, 3, 4], "the unreadable frame is dropped, the rest delivered")
        #expect(events.items.map(\.phase) == [.begin, .delta, .delta, .aborted])
        #expect(messages.items.map(\.seq) == [1], "a piece is not a message")
        #expect(channel.requests(for: "msg.sync").isEmpty, "a hole between pieces is not a range to repair")
        #expect(await client.highestSeq(in: "s_alice_bob") == 1)

        // The conversation's cursor did not move for the stream: its next message is contiguous.
        channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 2))
        _ = await waitUntil("seq 2") { messages.count == 2 }
        await settle()

        #expect(messages.items.map(\.seq) == [1, 2])
        #expect(channel.requests(for: "msg.sync").isEmpty)
        await client.enterBackground()
        let streamKeys = store.savedSnapshots.flatMap { $0.convSeqs.keys }.filter { $0.hasPrefix("st_") }
        #expect(streamKeys.isEmpty, "a stream never reaches the cursor store")

        events.stop()
        await client.disconnect()
    }

    // MARK: - Assembling

    @Test("pieces in order assemble into the text, and the completed stream names its message")
    func piecesInOrderAssemble() throws {
        var assembler = StreamAssembler()

        let openedResult = try Self.feed(&assembler, Self.beginFrame(placeholder: ["name": .string("Assistant")]))
        let opened = try #require(openedResult)
        #expect(opened.status == .streaming)
        #expect(opened.text.isEmpty)
        #expect(opened.intact)
        #expect(opened.placeholder?["name"] == .string("Assistant"))

        let thirdResult = try Self.feed(&assembler, Self.deltaFrame(1, "Hel"), Self.deltaFrame(2, "lo, "), Self.deltaFrame(3, "world"))
        let third = try #require(thirdResult)
        #expect(third.text == "Hello, world")
        #expect(third.intact)
        #expect(assembler["st_9f2c"]?.text == "Hello, world")
        #expect(assembler.active.map(\.streamId) == ["st_9f2c"])

        let doneResult = try Self.feed(&assembler, Self.completedFrame(4))
        let done = try #require(doneResult)
        #expect(done.status == .completed)
        #expect(done.text == "Hello, world")
        #expect(done.intact)
        #expect(done.messageId == Self.bigId)
        #expect(done.seq == 5)
        #expect(done.abortReason == nil)
        #expect(done.senderId == "alice")
        #expect(done.conversationId == "s_alice_bob")
        #expect(done.id == "st_9f2c")
        #expect(done.placeholder?["name"] == .string("Assistant"), "the placeholder outlives the opening frame")
        #expect(assembler.active.isEmpty, "a finished stream is no longer running")
        #expect(assembler["st_9f2c"] == nil)
    }

    @Test("an aborted stream ends with its reason and no message")
    func abortedStreamEndsWithItsReason() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "Hel"))

        let abortedResult = try Self.feed(&assembler, Self.abortedFrame(2, "the producer stopped sending for 30s"))
        let aborted = try #require(abortedResult)

        #expect(aborted.status == .aborted)
        #expect(aborted.abortReason == "the producer stopped sending for 30s")
        #expect(aborted.messageId == nil, "nothing was stored and nothing will arrive")
        #expect(aborted.seq == nil)
        #expect(aborted.text == "Hel")
        #expect(aborted.intact)
        #expect(assembler.active.isEmpty)
    }

    @Test("a stream completed with no pieces is intact")
    func completedWithNoPiecesIsIntact() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame())

        let doneResult = try Self.feed(&assembler, Self.completedFrame(1))
        let done = try #require(doneResult)

        #expect(done.status == .completed)
        #expect(done.text.isEmpty)
        #expect(done.intact)
    }

    @Test("a duplicate piece and a duplicate opening change nothing")
    func duplicatesChangeNothing() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "Hel"))

        // Joined by index, not by content: the same index with other text is still the same piece.
        let duplicatePiece = try Self.feed(&assembler, Self.deltaFrame(1, "XXX"))
        let duplicateOpening = try Self.feed(&assembler, Self.beginFrame(placeholder: ["name": .string("late")]))
        #expect(duplicatePiece == nil)
        #expect(duplicateOpening == nil)
        #expect(assembler["st_9f2c"]?.text == "Hel")
        #expect(assembler["st_9f2c"]?.placeholder == nil, "a second opening changes nothing")

        try Self.feed(&assembler, Self.deltaFrame(2, "lo"))
        let joinedAlready = try Self.feed(&assembler, Self.deltaFrame(1, "Hel"))
        #expect(joinedAlready == nil, "already joined into the text")
        #expect(assembler["st_9f2c"]?.text == "Hello")
    }

    @Test("a piece ahead of a missing one waits, and joins when the missing one arrives")
    func pieceAheadOfAHoleWaits() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"))

        let aheadResult = try Self.feed(&assembler, Self.deltaFrame(3, "c"))
        let ahead = try #require(aheadResult)
        #expect(ahead.text == "a", "the text stops at the hole rather than running past it")
        #expect(!ahead.intact)
        let heldTwice = try Self.feed(&assembler, Self.deltaFrame(3, "c"))
        #expect(heldTwice == nil, "a held piece is not taken twice")

        let filledResult = try Self.feed(&assembler, Self.deltaFrame(2, "b"))
        let filled = try #require(filledResult)
        #expect(filled.text == "abc")
        #expect(filled.intact)
    }

    @Test("a shed piece leaves the stream not intact through to its end, and nothing is repaired")
    func shedPieceIsNeverRepaired() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"), Self.deltaFrame(3, "c"))

        let doneResult = try Self.feed(&assembler, Self.completedFrame(4))
        let done = try #require(doneResult)

        #expect(done.status == .completed)
        #expect(done.text == "a")
        #expect(!done.intact, "the stored message, not this text, is the reply")
        #expect(done.messageId == Self.bigId)
    }

    @Test("a terminal frame past the last piece seen says pieces were lost")
    func terminalIndexRevealsLostPieces() throws {
        // Piece 2 was shed and nothing after it was ever sent: only the terminal index shows the loss.
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"))

        let doneResult = try Self.feed(&assembler, Self.abortedFrame(3, "aborted by the producer"))
        let done = try #require(doneResult)

        #expect(done.status == .aborted)
        #expect(!done.intact)
    }

    @Test("no index a StreamEvent can carry traps the assembler, Int.min and Int.max included")
    func extremeIndicesNeverTrap() throws {
        // StreamEvent's initialiser is public, so an app can hand the assembler any Int. A trap here
        // ends the test process, which is how this test fails.
        func extreme(_ index: Int, done: Bool = false, messageId: Int64? = nil, streamId: String = "st_9f2c") -> StreamEvent {
            StreamEvent(
                streamId: streamId,
                conversationId: "s_alice_bob",
                senderId: "alice",
                index: index,
                delta: done ? nil : "x",
                done: done,
                messageId: messageId
            )
        }

        // The terminal frame that trapped: at Int.min it says no pieces, and Int.min - 1 is never computed.
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"))
        let openingAgain = assembler.accept(extreme(Int.min))
        #expect(openingAgain == nil, "at or below 0 it is an opening, and this stream is already open")
        let endResult = assembler.accept(extreme(Int.min, done: true, messageId: Self.bigId))
        let end = try #require(endResult)
        #expect(end.status == .completed)
        #expect(end.text == "a")
        #expect(end.intact, "a terminal index at or below 0 says nothing was lost")
        #expect(end.messageId == Self.bigId)

        // At the other end: a piece at Int.max waits past the hole like any piece ahead of a missing
        // one, and a terminal frame at Int.max says pieces were lost.
        var far = StreamAssembler()
        try Self.feed(&far, Self.beginFrame("st_far"), Self.deltaFrame(1, "a", streamId: "st_far"))
        let heldResult = far.accept(extreme(Int.max, streamId: "st_far"))
        let held = try #require(heldResult)
        #expect(held.text == "a", "the text stops at the hole")
        #expect(!held.intact)
        let stoppedResult = far.accept(extreme(Int.max, done: true, streamId: "st_far"))
        let stopped = try #require(stoppedResult)
        #expect(stopped.status == .aborted, "done without a message id")
        #expect(stopped.text == "a")
        #expect(!stopped.intact)
        #expect(far.active.isEmpty)
    }

    @Test("a mid-stream join is accepted and marked not intact")
    func midStreamJoinIsAccepted() throws {
        var assembler = StreamAssembler()

        let joinedResult = try Self.feed(&assembler, Self.deltaFrame(4, "late"))
        let joined = try #require(joinedResult)

        #expect(joined.status == .streaming)
        #expect(joined.text.isEmpty, "pieces 1 to 3 never reached this device")
        #expect(!joined.intact)
        #expect(joined.placeholder == nil)
        #expect(joined.senderId == "alice")
        #expect(joined.conversationId == "s_alice_bob")
        #expect(assembler.active.map(\.streamId) == ["st_9f2c"])

        let doneResult = try Self.feed(&assembler, Self.completedFrame(5))
        let done = try #require(doneResult)
        #expect(!done.intact)
        #expect(done.messageId == Self.bigId, "the message id is still there to swap in the stored message")
    }

    @Test("nothing reopens a finished stream")
    func nothingReopensAFinishedStream() throws {
        var assembler = StreamAssembler()
        try Self.feed(&assembler, Self.beginFrame(), Self.deltaFrame(1, "a"), Self.completedFrame(3))

        let straggler = try Self.feed(&assembler, Self.deltaFrame(2, "b"))
        let secondTerminal = try Self.feed(&assembler, Self.completedFrame(3))
        let abortAfter = try Self.feed(&assembler, Self.abortedFrame(3, "x"))
        let reopening = try Self.feed(&assembler, Self.beginFrame())

        #expect(straggler == nil, "a straggler after the end")
        #expect(secondTerminal == nil, "a second terminal frame")
        #expect(abortAfter == nil)
        #expect(reopening == nil)
        #expect(assembler.active.isEmpty)
    }

    @Test("the assembler remembers the last 256 finished streams")
    func finishedStreamsAreRememberedUpToALimit() throws {
        var assembler = StreamAssembler()
        for n in 0 ... StreamAssembler.finishedMemory {
            try Self.feed(&assembler, Self.beginFrame("st_\(n)"), Self.completedFrame(1, streamId: "st_\(n)"))
        }

        // 257 finished: the oldest is forgotten, the next one still is not.
        let remembered = try Self.feed(&assembler, Self.deltaFrame(1, "late", streamId: "st_1"))
        let forgotten = try Self.feed(&assembler, Self.deltaFrame(1, "late", streamId: "st_0"))

        #expect(remembered == nil)
        #expect(forgotten?.status == .streaming, "past the memory, a straggler opens a stream again")
        #expect(forgotten?.intact == false, "as a mid-stream join")
    }

    @Test("streams are kept apart, remove forgets one, and clear drops the running ones")
    func streamsAreKeptApart() throws {
        var assembler = StreamAssembler()
        try Self.feed(
            &assembler,
            Self.beginFrame("st_a"),
            Self.beginFrame("st_b"),
            Self.deltaFrame(1, "A", streamId: "st_a"),
            Self.deltaFrame(1, "B", streamId: "st_b")
        )

        #expect(assembler["st_a"]?.text == "A")
        #expect(assembler["st_b"]?.text == "B")
        #expect(assembler.active.map(\.streamId) == ["st_a", "st_b"], "oldest first")

        assembler.remove("st_a")
        #expect(assembler.active.map(\.streamId) == ["st_b"])

        // A later frame for a removed stream opens it again, as a mid-stream join.
        let rejoinedResult = try Self.feed(&assembler, Self.deltaFrame(2, "A2", streamId: "st_a"))
        let rejoined = try #require(rejoinedResult)
        #expect(!rejoined.intact)
        #expect(rejoined.text.isEmpty)
        #expect(assembler.active.map(\.streamId) == ["st_b", "st_a"])

        assembler.clear()
        #expect(assembler.active.isEmpty)
    }

    // MARK: - The finished stream is a message

    @Test("the stored message arrives through the ordinary path whether it lands before or after the terminal frame")
    func storedMessageArrivesEitherSideOfTheTerminalFrame() async throws {
        for messageFirst in [false, true] {
            let gateway = Self.gateway()
            let client = ImClient(options: makeOptions(connector: gateway))
            let messages = Collector(client.messages())
            let streams = Collector(client.streamEvents().assemble())
            try await client.connect()
            let channel = try #require(gateway.lastChannel)

            channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 4))
            _ = await waitUntil("seq 4") { messages.count == 1 }
            channel.event(.stream, data: Self.beginFrame())
            channel.event(.stream, data: Self.deltaFrame(1, "Hel"))
            channel.event(.stream, data: Self.deltaFrame(2, "lo"))
            _ = await waitUntil("three stream frames") { streams.count == 3 }

            if messageFirst {
                channel.event(.message, data: Self.storedMessage(seq: 5, text: "Hello"))
            }
            channel.event(.stream, data: Self.completedFrame(3, seq: 5))
            if !messageFirst {
                channel.event(.message, data: Self.storedMessage(seq: 5, text: "Hello"))
            }
            _ = await waitUntil("the stored message and the terminal frame") { messages.count == 2 && streams.count == 4 }
            await settle()

            let last = try #require(streams.items.last)
            #expect(last.status == .completed, "messageFirst=\(messageFirst)")
            #expect(last.text == "Hello")
            #expect(last.intact)
            let storedCopy = messages.items.first(where: { $0.seq == 5 })
            let stored = try #require(storedCopy)
            #expect(stored.messageId == last.messageId, "matched by message id (messageFirst=\(messageFirst))")
            #expect(stored.text == "Hello")
            #expect(stored.clientMsgId == "cid-stream")
            #expect(messages.items.map(\.seq) == [4, 5], "contiguous, so nothing to repair")
            #expect(channel.requests(for: "msg.sync").isEmpty)

            streams.stop()
            await client.disconnect()
        }
    }

    @Test("msg.streamComplete moves no cursor, so the producer's own copy is still delivered")
    func completeMovesNoCursor() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 4))
        _ = await waitUntil("seq 4") { messages.count == 1 }

        let result = try await client.msg.streamComplete(CompleteStreamRequest(streamId: "st_9f2c"))
        #expect(result.seq == 5)
        await settle()
        #expect(await client.highestSeq(in: "s_alice_bob") == 4, "the answer moved no cursor")

        channel.event(.message, data: Self.storedMessage(seq: 5, text: "Hello"))
        _ = await waitUntil("the producer's own copy of the stored message") { messages.count == 2 }
        await settle()

        #expect(messages.items.map(\.seq) == [4, 5], "msg.send's cursor hook would have dropped seq 5 as a duplicate")
        #expect(channel.requests(for: "msg.sync").isEmpty)
        #expect(await client.highestSeq(in: "s_alice_bob") == 5)

        await client.disconnect()
    }

    @Test("a stored message that skips a seq is still repaired like any other")
    func storedMessageIsRepairedLikeAnyOther() async throws {
        // The completed stream is an ordinary message: if the one before it was lost, the hole is
        // repaired before it is delivered. msg.sync is left unanswered, so the repair stays in flight.
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .seconds(10)))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 3))
        _ = await waitUntil("seq 3") { messages.count == 1 }
        channel.event(.message, data: Self.storedMessage(seq: 5, text: "Hello"))
        _ = await waitUntil("the repair of seq 4") { channel.requests(for: "msg.sync").count == 1 }
        await settle()

        let sync = try #require(channel.requests(for: "msg.sync").first)
        #expect(sync["conversationId"] == .string("s_alice_bob"))
        #expect(sync["fromSeq"]?.intValue == 4)
        #expect(sync["toSeq"]?.intValue == 4)
        #expect(messages.items.map(\.seq) == [3], "held behind the repair")

        await client.disconnect()
    }

    // MARK: - Held to the inventory

    /// The decoding tests above are only as wide as their fixtures, and a request test only as wide as
    /// the instance it builds. So the full fixtures carry every member the server declares, and the
    /// requests send every member, held here to `endpoint-inventory.json`'s `payloadTypes`.
    @Test("the full fixtures and requests carry every member the server declares")
    func fixturesCarryEveryServerMember() throws {
        let types = try Self.payloadTypes()

        func members(_ type: String) -> Set<String> {
            let properties = (types[type] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
            return Set(properties.compactMap { $0["name"] as? String })
        }

        #expect(!members("StreamHandle").isEmpty, "the inventory lists no members for StreamHandle")
        #expect(Self.keys(Self.handle()) == members("StreamHandle"))
        #expect(Self.keys(Self.sendResult()) == members("SendMessageResult"))

        let begin = try Self.wire(BeginStreamRequest(
            conversationId: "c",
            receiverId: "r",
            groupId: "g",
            clientMsgId: "k",
            placeholder: ["name": .string("n")],
            options: MessageOptions(
                pushConfig: PushConfig(title: "t", body: "b", sound: "s", payload: ["k": "v"], channelId: "c"),
                expireIn: 1
            ),
            extensions: ["k": .string("v")]
        ))
        let append = try Self.wire(StreamAppendRequest(streamId: "st_1", delta: "d"))
        let complete = try Self.wire(CompleteStreamRequest(
            streamId: "st_1",
            content: ["text": .string("t")],
            extensions: ["k": .string("v")]
        ))
        let abortBody = try Self.wire(StreamAbortRequest(streamId: "st_1", reason: "r"))

        #expect(Self.keys(begin) == members("BeginStreamRequest"))
        #expect(Self.keys(begin["options"]) == members("MessageOptions"))
        #expect(Self.keys(begin["options"]?["pushConfig"]) == members("PushConfig"))
        #expect(Self.keys(append) == members("StreamAppendRequest"))
        #expect(Self.keys(complete) == members("CompleteStreamRequest"))
        #expect(Self.keys(abortBody) == members("StreamAbortRequest"))
    }

    /// `evt.stream`'s data is the server's `StreamDelta` (and, for the opening, `StreamBeginFrame`:
    /// the same shape plus `placeholder`). Neither is a request or a reply, so neither is in the
    /// inventory's `payloadTypes`; the members are pinned here from `IStreamingMessageService.cs` and
    /// `StreamingMessageService.cs`, and every one of them is read by `StreamEvent.fromData` — a
    /// fixture key this SDK did not read would decode to `nil` and an expectation above would fail.
    ///
    /// evt.stream 的 data 是服务端的 StreamDelta（开流帧是 StreamBeginFrame，多一个 placeholder）。两者都不在清单的
    /// payloadTypes 里，所以成员在这里照 C# 钉住。
    @Test("the evt.stream fixtures carry every member of StreamDelta and StreamBeginFrame")
    func streamFixturesCarryEveryFrameMember() {
        let streamDelta: Set<String> = [
            "streamId", "conversationId", "senderId", "index", "delta", "done", "messageId", "seq", "abortReason",
        ]
        let streamBeginFrame: Set<String> = ["streamId", "conversationId", "senderId", "index", "done", "placeholder"]

        #expect(Self.keys(Self.beginFrame(placeholder: ["name": .string("n")])) == streamBeginFrame)

        let later = Self.keys(Self.deltaFrame(1, "d"))
            .union(Self.keys(Self.completedFrame(2)))
            .union(Self.keys(Self.abortedFrame(2, "r")))
        #expect(later == streamDelta, "between them the three later phases carry every member")

        // The server leaves nulls out, so each phase carries only its own optional members.
        #expect(Self.keys(Self.deltaFrame(1, "d")) == ["streamId", "conversationId", "senderId", "index", "delta", "done"])
        #expect(Self.keys(Self.completedFrame(2)) == ["streamId", "conversationId", "senderId", "index", "done", "messageId", "seq"])
        #expect(Self.keys(Self.abortedFrame(2, "r")) == ["streamId", "conversationId", "senderId", "index", "done", "abortReason"])
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
