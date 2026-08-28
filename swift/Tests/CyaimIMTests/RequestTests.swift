import Foundation
import Testing

@testable import CyaimIM

/// One socket carries every request, every reply and every push. These tests cover the part that
/// makes that safe: a reply finds its caller by id no matter when it arrives, an unanswered request
/// fails on its own rather than hanging a screen, and a failure reaches the caller with the code and
/// trace id a support ticket needs.
@Suite("Request multiplexing")
struct RequestTests {

    @Test("replies are matched by id, not by arrival order")
    func repliesAreMatchedById() async throws {
        let held = Holder<SentRequest>()

        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "slow.one":
                held.set(request)

            case "fast.two":
                // The second request is answered first, and only then the first one — which is
                // exactly the ordering a multiplexed socket has to survive.
                channel.reply(to: request, data: .string("two"))
                if let first = held.take() {
                    channel.reply(to: first, data: .string("one"))
                }

            default:
                break
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let slow = Task { try await client.invoke("slow.one", as: String.self) }
        _ = await waitUntil("the first request on the wire") {
            channel.requests(for: "slow.one").count == 1
        }

        let two = try await client.invoke("fast.two", as: String.self)
        let one = try await slow.value

        #expect(one == "one")
        #expect(two == "two")

        await client.disconnect()
    }

    @Test("every request carries a distinct id")
    func requestIdsAreUnique() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            channel.reply(to: request, data: .int(0))
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        for _ in 0 ..< 5 {
            _ = try await client.totalUnread()
        }

        let ids = channel.requests(for: "conv.unreadTotal").map(\.id)
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)

        await client.disconnect()
    }

    @Test("an unanswered request times out instead of hanging")
    func requestsTimeOut() async throws {
        let gateway = MockGateway(responder: { request, channel in
            // Housekeeping still works; everything else falls into a hole.
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .milliseconds(120)))
        try await client.connect()

        do {
            let _: String = try await client.invoke("never.answered")
            Issue.record("the request should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .timeout)
            #expect(error.target == "never.answered")
            #expect(error.isRetryable)
        }

        await client.disconnect()
    }

    @Test("a business failure arrives as a typed error carrying its trace id")
    func businessFailuresCarryCodeAndTrace() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "msg.send" {
                channel.reply(
                    to: request,
                    code: .moderationRejected,
                    message: "content rejected",
                    traceId: "trace-4711"
                )
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            _ = try await client.sendText("something forbidden", to: .user("bob"))
            Issue.record("the send should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .moderationRejected)
            #expect(error.traceId == "trace-4711")
            #expect(error.target == "msg.send")
            #expect(!error.isRetryable)
        }

        await client.disconnect()
    }

    @Test("a request made while the socket is down fails immediately rather than queueing")
    func offlineRequestsFailFast() async throws {
        let client = ImClient(options: makeOptions(connector: MockGateway()))

        do {
            _ = try await client.totalUnread()
            Issue.record("a request without a socket should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .notConnected)
        }
    }

    @Test("clientMsgId is generated for you, and resending the same draft reuses it")
    func clientMessageIdMakesRetriesIdempotent() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            guard request.target == "msg.send" else { return }

            let clientMsgId = request["clientMsgId"]?.stringValue ?? ""
            channel.reply(to: request, data: .object([
                "messageId": .int(1_001),
                "seq": .int(1),
                "conversationId": .string("s_alice_bob"),
                "clientMsgId": .string(clientMsgId),
                "createTime": .int(ImClock.nowMilliseconds()),
                "deduplicated": .bool(false),
            ]))
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // The id is minted with the draft, not with the send, so a retry of the *same* draft is the
        // same message as far as the server is concerned.
        let draft = MessageDraft.text("hello", to: .user("bob"))
        _ = try await client.send(draft)
        _ = try await client.send(draft)

        let sends = channel.requests(for: "msg.send")
        #expect(sends.count == 2)

        let firstId = try #require(sends.first?["clientMsgId"]?.stringValue)
        let secondId = try #require(sends.last?["clientMsgId"]?.stringValue)
        #expect(!firstId.isEmpty)
        #expect(firstId == secondId)

        // A genuinely new message gets a genuinely new id.
        #expect(MessageDraft.text("hello", to: .user("bob")).clientMsgId != draft.clientMsgId)

        // …and the target is resolved server-side from receiverId.
        #expect(sends.first?["receiverId"]?.stringValue == "bob")
        #expect(sends.first?["contentType"]?.intValue == 1)
        #expect(sends.first?["content"]?["text"]?.stringValue == "hello")

        await client.disconnect()
    }

    @Test("a send records its own seq, so the server's echo is not mistaken for a gap")
    func sendingRecordsTheSeq() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            guard request.target == "msg.send" else { return }

            channel.reply(to: request, data: .object([
                "messageId": .int(2_002),
                "seq": .int(41),
                "conversationId": .string("s_alice_bob"),
                "clientMsgId": .string(request["clientMsgId"]?.stringValue ?? ""),
                "createTime": .int(ImClock.nowMilliseconds()),
            ]))
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let result = try await client.sendText("hi", to: .user("bob"))
        #expect(result.seq == 41)

        // Recorded on the delivery lane rather than inline, so it cannot overtake a repair that is
        // mid-flight and make the repaired messages look like duplicates. That makes it observable
        // a moment after the send returns rather than instantly.
        _ = await waitUntil("the sent seq to reach the cursor") {
            await client.highestSeq(in: "s_alice_bob") == 41
        }
        #expect(await client.highestSeq(in: "s_alice_bob") == 41)

        // The gateway echoes the message back on the fan-out path. It is the next seq, not a gap.
        channel.event(.message, data: messagePayload(conversationId: "s_alice_bob", seq: 42))
        _ = await waitUntil("the echoed message") { messages.count == 1 }
        await settle()

        #expect(channel.requests(for: "msg.sync").isEmpty)

        await client.disconnect()
    }

    @Test("the handshake carries everything the gateway needs and nothing it should not have")
    func handshakeQuery() async throws {
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway, token: "token-abc"))
        try await client.connect()

        let url = try #require(gateway.handshakeURLs.first)
        #expect(url.scheme == "wss", "an https endpoint must be rewritten to wss")
        #expect(url.path == "/im")
        #expect(gateway.queryValue("appId", ofAttempt: 1) == "app-test")
        #expect(gateway.queryValue("token", ofAttempt: 1) == "token-abc")
        #expect(gateway.queryValue("deviceId", ofAttempt: 1) == "device-test")
        #expect(gateway.queryValue("platform", ofAttempt: 1) == "1")
        #expect(gateway.queryValue("v", ofAttempt: 1) == "1")
        // Both halves: the host app's version and this package's, because a support ticket that
        // carries only one of them always needs a follow-up question.
        #expect(gateway.queryValue("cv", ofAttempt: 1) == "1.0.0-test cyaim-swift/\(ImSdk.packageVersion)")
        #expect(gateway.queryValue("lang", ofAttempt: 1) == "en-US")

        await client.disconnect()
    }

    @Test("typed events decode; a payload this build cannot read is skipped, not fatal")
    func typedEventStreams() async throws {
        struct TypingEvent: Decodable, Sendable {
            let conversationId: String
            let userId: String
            let typing: Bool
        }

        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let typing = Collector(client.events(.typing, as: TypingEvent.self))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // A payload from a newer server, missing a field this build requires.
        channel.event(.typing, data: .object(["conversationId": .string("s_alice_bob")]))
        channel.event(.typing, data: .object([
            "conversationId": .string("s_alice_bob"),
            "userId": .string("bob"),
            "typing": .bool(true),
        ]))

        _ = await waitUntil("the decodable event") { typing.count == 1 }
        await settle()

        #expect(typing.count == 1)
        #expect(typing.items.first?.userId == "bob")

        await client.disconnect()
    }
}
