import Foundation
import Testing

@testable import CyaimIM

/// Delivery ordering and reentrancy, from `sdk/CONTRACT.md` §7.6.
///
/// One rule above all: for a given conversation, messages reach the application in `seq` order and
/// never concurrently with each other. Everything here serves that, and the hardest case is the one
/// that looks least likely — a live message arriving while a repair for the same conversation is
/// still in flight.
@Suite("Delivery ordering")
struct OrderingTests {

    private static let conversationId = "s_alice_bob"

    @Test("messages arriving during a repair are held and delivered after it, in seq order")
    func messagesArriveInSeqOrder() async throws {
        let held = Holder<SentRequest>()

        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            // The repair is parked, so the test controls exactly when it completes.
            if request.target == "msg.sync" { held.set(request) }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 5))
        _ = await waitUntil("the first message") { messages.count == 1 }

        // seq 9 exposes a gap; the repair for 6…8 is now parked.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 9))
        _ = await waitUntil("the repair to go out") { !channel.requests(for: "msg.sync").isEmpty }

        // Two more live messages land while it is parked. They must wait, not overtake.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 10))
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 11))
        await settle()

        #expect(messages.items.map(\.seq) == [5], "nothing may be delivered while a repair is open")

        let repair = try #require(held.take())
        channel.reply(to: repair, data: syncPayload(conversationId: Self.conversationId, range: 6 ... 8))

        _ = await waitUntil("everything, in order") { messages.count == 7 }
        await settle()

        #expect(messages.items.map(\.seq) == [5, 6, 7, 8, 9, 10, 11])

        await client.disconnect()
    }

    @Test("only one repair runs for a conversation at a time")
    func repairsDoNotRunConcurrently() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            guard request.target == "msg.sync",
                  let from = request["fromSeq"]?.intValue,
                  let to = request["toSeq"]?.intValue,
                  from <= to
            else { return }

            channel.reply(to: request, data: syncPayload(conversationId: Self.conversationId, range: from ... to))
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 1))
        _ = await waitUntil("the first message") { messages.count == 1 }

        // Two gaps queued back to back. Serialised through one lane, the second repair sees the
        // first one's cursor and asks only for what is still missing.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 5))
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 9))

        _ = await waitUntil("everything") { messages.count == 9 }
        await settle()

        #expect(messages.items.map(\.seq) == Array(Int64(1) ... 9))

        let ranges = channel.requests(for: "msg.sync").map {
            [$0["fromSeq"]?.intValue ?? -1, $0["toSeq"]?.intValue ?? -1]
        }
        #expect(ranges == [[2, 4], [6, 8]], "no range may be requested twice or overlap another")

        await client.disconnect()
    }

    @Test("a listener that gives up does not stop delivery for the others")
    func throwingListenerDoesNotStopDelivery() async throws {
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        let survivor = Collector(client.messages())

        // A consumer that tears its own stream down on the second message — the shape an
        // application bug takes here, since a stream consumer cannot throw back into the SDK.
        let brittle = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 1))
        _ = await waitUntil("the first message everywhere") { brittle.count == 1 && survivor.count == 1 }

        brittle.stop()

        for seq in Int64(2) ... 5 {
            channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: seq))
        }

        _ = await waitUntil("the rest") { survivor.count == 5 }
        await settle()

        // One application bug in one handler must not stop delivery for every conversation, and
        // must never lose a cursor.
        #expect(survivor.items.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(await client.highestSeq(in: Self.conversationId) == 5)

        await client.disconnect()
    }

    @Test("calling back into the client from a listener does not deadlock")
    func reentrantCallFromListenerDoesNotDeadlock() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "conv.unreadTotal" {
                channel.reply(to: request, data: .int(3))
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let stream = client.messages()

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let done = Holder<Int>()

        // The natural shape of an application's delivery loop: store the message, commit its seq,
        // and ask the client something while you are there.
        let consumer = Task {
            var seen = 0
            for await message in stream {
                await client.commit(message.conversationId, seq: message.seq)
                _ = try? await client.conv.unreadTotal()
                seen += 1
                if seen == 3 { break }
            }
            done.set(seen)
        }

        for seq in Int64(1) ... 3 {
            channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: seq))
        }

        _ = await waitUntil("the consumer to finish") { done.take() != nil || consumer.isCancelled }
        consumer.cancel()

        #expect(await client.committedSeq(in: Self.conversationId) == 3)

        await client.disconnect()
    }
}
