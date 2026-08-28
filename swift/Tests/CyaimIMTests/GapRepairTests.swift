import Foundation
import Testing

@testable import CyaimIM

/// WebSocket delivery is at-most-once and unordered across a reconnect. Contiguous `seq` plus the
/// repair loop is what turns that into a correct, ordered conversation, so these tests assert both
/// halves: that the missing range is requested *exactly*, and that nothing reaches the application
/// out of order while it is being fetched.
@Suite("Sequence tracking and gap repair")
struct GapRepairTests {

    private static let conversationId = "s_alice_bob"

    /// Answers `msg.sync` with precisely the range it was asked for, so the assertions below are
    /// about what the client requested rather than about what a lenient server volunteered.
    private static func syncingGateway(
        conversationId: String = GapRepairTests.conversationId
    ) -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            guard request.target == "msg.sync",
                  let from = request["fromSeq"]?.intValue,
                  let to = request["toSeq"]?.intValue,
                  from <= to
            else { return }

            channel.reply(to: request, data: syncPayload(conversationId: conversationId, range: from ... to))
        })
    }

    @Test("a skipped seq is repaired with exactly the missing range")
    func repairsExactlyTheMissingRange() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 5))
        _ = await waitUntil("the first message") { messages.count == 1 }

        // seq 9 with 5 known: 6, 7 and 8 are missing.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 9))
        _ = await waitUntil("the gap to be filled") { messages.count == 5 }

        let syncs = channel.requests(for: "msg.sync")
        #expect(syncs.count == 1)

        let sync = try #require(syncs.first)
        #expect(sync["conversationId"]?.stringValue == Self.conversationId)
        #expect(sync["fromSeq"]?.intValue == 6)
        #expect(sync["toSeq"]?.intValue == 8)
        #expect(sync["limit"]?.intValue == 3)
        #expect(sync["ascending"]?.boolValue == true)

        // And the application never saw 9 before 6, 7 and 8.
        #expect(messages.items.map(\.seq) == [5, 6, 7, 8, 9])

        await client.disconnect()
    }

    @Test("a contiguous stream is never repaired")
    func contiguousMessagesNeedNoSync() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        for seq in Int64(1) ... 5 {
            channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: seq))
        }

        _ = await waitUntil("five messages") { messages.count == 5 }
        await settle()

        #expect(channel.requests(for: "msg.sync").isEmpty)
        #expect(messages.items.map(\.seq) == [1, 2, 3, 4, 5])

        await client.disconnect()
    }

    @Test("the first message in an unseen conversation is not a gap")
    func firstSightOfAConversationIsNotAGap() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // Nothing is known about this conversation, so seq 4_200 is where it starts for us — not a
        // 4_199-message hole to backfill.
        channel.event(.message, data: messagePayload(conversationId: "s_new", seq: 4_200))

        _ = await waitUntil("the message") { messages.count == 1 }
        await settle()

        #expect(channel.requests(for: "msg.sync").isEmpty)
        #expect(messages.items.first?.seq == 4_200)

        await client.disconnect()
    }

    @Test("a duplicate is dropped silently")
    func duplicatesAreDropped() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 7))
        _ = await waitUntil("the message") { messages.count == 1 }

        // Redelivery after a reconnect is normal, not an error, and must not reach the app twice.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 7))
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 3))
        await settle()

        #expect(messages.count == 1)
        #expect(channel.requests(for: "msg.sync").isEmpty)

        await client.disconnect()
    }

    @Test("seq 0 is delivered straight through and never moves the cursor")
    func unpersistedMessagesBypassTheCursor() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "room_1", seq: 0))
        channel.event(.message, data: messagePayload(conversationId: "room_1", seq: 0))

        _ = await waitUntil("both online-only messages") { messages.count == 2 }
        await settle()

        #expect(await client.highestSeq(in: "room_1") == 0)
        #expect(channel.requests(for: "msg.sync").isEmpty)

        await client.disconnect()
    }

    @Test("a gap too large to backfill is not backfilled")
    func oversizedGapsAreNotReplayed() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway, maxAutoRepairSeq: 10))
        let messages = Collector(client.messages())
        let events = Collector(client.sessionEvents())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 1))
        _ = await waitUntil("the first message") { messages.count == 1 }

        // 998 missing messages. Replaying those into a UI helps nobody; the app reloads the
        // conversation from history instead.
        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 1_000))
        _ = await waitUntil("the newest message") { messages.count == 2 }
        await settle()

        #expect(channel.requests(for: "msg.sync").isEmpty)
        #expect(messages.items.map(\.seq) == [1, 1_000])
        #expect(await client.highestSeq(in: Self.conversationId) == 1_000)

        // Advancing the cursor is only half the job: the application has to be told that a stretch
        // of this conversation was skipped, or the hole is one nobody will ever fill.
        #expect(events.items.contains(.conversationNeedsReload(
            conversationId: Self.conversationId,
            fromSeq: 2,
            toSeq: 999
        )))

        await client.disconnect()
    }

    @Test("a failed repair still delivers the message that exposed the gap")
    func aFailedRepairDoesNotStallTheConversation() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "msg.sync" {
                channel.reply(to: request, code: .internalError, message: "storage unavailable", traceId: "t-1")
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 2))
        _ = await waitUntil("the first message") { messages.count == 1 }

        channel.event(.message, data: messagePayload(conversationId: Self.conversationId, seq: 6))
        _ = await waitUntil("the newest message anyway") { messages.count == 2 }

        #expect(messages.items.map(\.seq) == [2, 6])
        #expect(channel.requests(for: "msg.sync").count == 1)

        await client.disconnect()
    }

    /// The whole reconnect story end to end: the client is at seq 5, the socket dies, and on the
    /// new socket the server reports where the gap starts. The client fetches exactly that range.
    @Test("a reconnect resumes and repairs what conn.sync reports")
    func resumeRepairsReportedGaps() async throws {
        let conversationId = Self.conversationId

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.heartbeat":
                _ = MockGateway.answerHousekeeping(request, channel)

            case "conn.sync":
                // Answer honestly, from what the client says it holds: a client at seq 5 in a
                // conversation whose newest seq is 8 is missing 6 through 8.
                let known = request["convSeqs"]?[conversationId]?.intValue ?? 0

                if known > 0, known < 8 {
                    channel.reply(to: request, data: .object([
                        "conversations": .array([conversationPayload(conversationId, maxSeq: 8)]),
                        "gapsFrom": .object([conversationId: .int(known + 1)]),
                        "hasMore": .bool(false),
                        "serverTime": .int(ImClock.nowMilliseconds()),
                    ]))
                } else {
                    _ = MockGateway.answerHousekeeping(request, channel)
                }

            case "msg.sync":
                guard let from = request["fromSeq"]?.intValue,
                      let to = request["toSeq"]?.intValue,
                      from <= to
                else { return }
                channel.reply(to: request, data: syncPayload(conversationId: conversationId, range: from ... to))

            default:
                break
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let messages = Collector(client.messages())

        try await client.connect()
        let first = try #require(gateway.lastChannel)

        first.event(.message, data: messagePayload(conversationId: conversationId, seq: 5))
        _ = await waitUntil("the message before the drop") { messages.count == 1 }

        // The application stored it, so it commits. Without this the reconnect would legitimately
        // redeliver seq 5 as well — see `deliveredResetsToCommittedOnReconnect` in ColdStartTests,
        // which is the same machinery seen from the other side.
        await client.commit(conversationId, seq: 5)

        // The socket dies the way a gateway rolling update kills it.
        first.serverClose(code: 1006, reason: nil)

        _ = await waitUntil("a second socket") { gateway.attempts >= 2 }
        _ = await waitUntil("the missed messages") { messages.count == 4 }

        let second = try #require(gateway.lastChannel)
        let sync = try #require(second.requests(for: "msg.sync").first)

        #expect(sync["fromSeq"]?.intValue == 6)
        #expect(sync["toSeq"]?.intValue == 8)
        #expect(messages.items.map(\.seq) == [5, 6, 7, 8])
        #expect(await client.highestSeq(in: conversationId) == 8)

        await client.disconnect()
    }

    @Test("seeded cursors survive a relaunch, so the first resume reports the real gap")
    func seededCursorsAreSentToTheServer() async throws {
        let gateway = Self.syncingGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        // What a previous launch persisted.
        await client.seed([Self.conversationId: 12], conversationCursor: 1_700_000_000_000)

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = await waitUntil("the resume request") { !channel.requests(for: "conn.sync").isEmpty }

        let resume = try #require(channel.requests(for: "conn.sync").first)
        #expect(resume["convSeqs"]?[Self.conversationId]?.intValue == 12)
        #expect(resume["conversationCursor"]?.intValue == 1_700_000_000_000)

        await client.disconnect()
    }
}
