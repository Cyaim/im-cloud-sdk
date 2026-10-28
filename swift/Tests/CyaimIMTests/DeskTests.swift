import Foundation
import Testing

@testable import CyaimIM

/// `desk.*` — the nine customer-service verbs, and the `evt.desk` frame.
///
/// Every verb is asserted on the frame it puts on the wire — target and the whole body, compared as
/// a ``JSONValue`` so `.string("7")`, `.int(7)` and `.bool(true)` are told apart — and on what it
/// makes of a representative reply. Three properties carry the weight and none is visible from a
/// signature: a transfer names exactly one target, an absent optional member is not the same as one
/// set to a value (`inviteRating` omitted *invites*), and `endReason` is a string where its
/// neighbour `state` is an integer.
///
/// 每个动词都断言它发出的整帧（整值比较 JSONValue），以及它对一个代表性答复的解码。
@Suite("Desk")
struct DeskTests {

    private static func session(full: Bool) -> JSONValue {
        var members: [String: JSONValue] = [
            "sessionId": .string("ds_1"),
            "appId": .string("demo"),
            "customerId": .string("v_01hh"),
            "conversationId": .string("s_desk_v_01hh"),
            "state": .int(full ? 1 : 0),
            "priority": .int(full ? 3 : 0),
            "queuedAt": .int(1_755_000_000_000),
        ]

        if full {
            // Every member of the server's DeskSession, each with a value no default reads as — so a
            // CodingKey spelled wrong decodes to nil or a default and an expectation below fails.
            // `fixturesCarryEveryServerMember` holds the list to the inventory.
            members["agentId"] = .string("a_7")
            members["skill"] = .string("billing")
            members["assignedAt"] = .int(1_755_000_060_000)
            members["closedAt"] = .int(1_755_000_900_000)
            members["resolution"] = .string("refunded")
            members["context"] = .object(["desk.channel": .string("app")])
            members["history"] = .array([.string("a_3")])
            members["firstAgentMessageAt"] = .int(1_755_000_070_000)
            members["rating"] = .int(4)
            members["ratingInvitedAt"] = .int(1_755_000_910_000)
            members["ratingComment"] = .string("quick")
            members["ratedAt"] = .int(1_755_000_920_000)
            members["channel"] = .string("app")
            members["visitorId"] = .string("v_01hh")
            members["deskId"] = .string("dk_1")
            members["groupId"] = .string("g_billing")
            members["disposition"] = .string("resolved")
            members["ratingReason"] = .string("slow at first")
            members["ratingTags"] = .array([.string("polite")])
            members["snoozedUntil"] = .int(1_755_001_000_000)
            members["summary"] = .object([
                "issue": .string("refund"),
                "state": .string("waiting on finance"),
                "nextStep": .string("check the order"),
                "generatedAt": .int(1_755_000_050_000),
                "model": .string("demo/model"),
            ])
            members["tags"] = .array([.string("billing/refund")])
            members["endReason"] = .string("bot-handoff")
            members["ratingResolved"] = .bool(false)
            members["star"] = .bool(true)
            members["responseSamples"] = .array([
                .object(["customerAt": .int(1), "agentAt": .int(2), "agentId": .string("a_7")]),
            ])
        }

        return .object(members)
    }

    private static func queueView(measured: Bool) -> JSONValue {
        var members: [String: JSONValue] = [
            "waiting": .int(3),
            "assigned": .int(2),
            "availableAgents": .int(1),
            "headWaitSeconds": .int(95),
            "waitingBySkill": .object(["billing": .int(3)]),
        ]
        if measured {
            members["avgFirstResponseSeconds"] = .double(12.5)
        }
        return .object(members)
    }

    private static let cannedRow: JSONValue = .object([
        "id": .string("cr_1"),
        "title": .string("Refunds"),
        "content": .string("Refunds take 3-5 days."),
        "skill": .string("billing"),
        "scope": .string("personal"),
        "folder": .string("refunds"),
        "ownerMemberId": .string("m_1"),
        "updatedAt": .int(1_755_000_000_000),
    ])

    private static func gateway(measuredQueue: Bool = false) -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "desk.request":
                channel.reply(to: request, data: Self.session(full: false))
            case "desk.accept":
                channel.reply(to: request, data: Self.session(full: true))
            case "desk.queue":
                channel.reply(to: request, data: Self.queueView(measured: measuredQueue))
            case "desk.canned":
                channel.reply(to: request, data: .array([
                    Self.cannedRow,
                    .object([
                        "id": .string("cr_2"),
                        "title": .string("Hello"),
                        "content": .string("Hi!"),
                        "scope": .string("all"),
                        "updatedAt": .int(1),
                    ]),
                ]))
            case "desk.suggest":
                channel.reply(to: request, data: .array([.string("Sure, one moment.")]))
            default:
                // transfer, close, status and rate acknowledge the way the server does: no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    @Test("desk.request sends an empty body by default and decodes a queued session with its absences")
    func requestDefaultsAndAbsences() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let queued = try await client.desk.request()
        #expect(channel.requests(for: "desk.request").first?.body == .object([:]))

        #expect(queued.sessionId == "ds_1")
        #expect(queued.state == .queued)
        #expect(queued.agentId == nil, "absent while queued")
        #expect(queued.endReason == nil)
        #expect(queued.summary == nil)
        #expect(queued.context == nil)
        #expect(queued.tags.isEmpty)
        #expect(queued.star == false)
        #expect(queued.ratingResolved == nil)

        _ = try await client.desk.request(DeskRequest(
            skill: "billing",
            priority: 2,
            context: ["desk.page": .string("/orders/9")]
        ))
        #expect(channel.requests(for: "desk.request").last?.body == .object([
            "skill": .string("billing"),
            "priority": .int(2),
            "context": .object(["desk.page": .string("/orders/9")]),
        ]))

        await client.disconnect()
    }

    @Test("desk.accept names the session or nothing, and decodes every product field")
    func acceptDecodesTheProductFields() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.desk.accept()
        let taken = try await client.desk.accept(DeskAcceptRequest(sessionId: "ds_1"))

        let sent = channel.requests(for: "desk.accept").map(\.body)
        #expect(sent == [.object([:]), .object(["sessionId": .string("ds_1")])])

        #expect(taken.sessionId == "ds_1")
        #expect(taken.appId == "demo")
        #expect(taken.customerId == "v_01hh")
        #expect(taken.agentId == "a_7")
        #expect(taken.conversationId == "s_desk_v_01hh")
        #expect(taken.state == .assigned)
        #expect(taken.skill == "billing")
        #expect(taken.priority == 3)
        #expect(taken.queuedAt == 1_755_000_000_000)
        #expect(taken.assignedAt == 1_755_000_060_000)
        #expect(taken.closedAt == 1_755_000_900_000)
        #expect(taken.resolution == "refunded")
        #expect(taken.context?["desk.channel"] == .string("app"))
        #expect(taken.history == ["a_3"])
        #expect(taken.firstAgentMessageAt == 1_755_000_070_000)
        #expect(taken.rating == 4)
        #expect(taken.ratingInvitedAt == 1_755_000_910_000)
        #expect(taken.ratingComment == "quick")
        #expect(taken.ratedAt == 1_755_000_920_000)
        #expect(taken.summary?.issue == "refund")
        #expect(taken.summary?.state == "waiting on finance")
        #expect(taken.summary?.nextStep == "check the order")
        #expect(taken.summary?.generatedAt == 1_755_000_050_000)
        #expect(taken.summary?.model == "demo/model")
        #expect(taken.tags == ["billing/refund"])
        #expect(taken.channel == "app")
        #expect(taken.visitorId == "v_01hh")
        #expect(taken.deskId == "dk_1")
        #expect(taken.groupId == "g_billing")
        #expect(taken.disposition == ImDeskDisposition.resolved)
        // A string on the wire, unlike `state` beside it.
        #expect(taken.endReason == ImDeskEndReason.botHandoff)
        #expect(taken.ratingReason == "slow at first")
        #expect(taken.ratingResolved == false)
        #expect(taken.ratingTags == ["polite"])
        #expect(taken.star)
        #expect(taken.snoozedUntil == 1_755_001_000_000)
        #expect(taken.responseSamples.first?.customerAt == 1)
        #expect(taken.responseSamples.first?.agentAt == 2)
        #expect(taken.responseSamples.first?.agentId == "a_7")

        await client.disconnect()
    }

    @Test("desk.transfer sends exactly the one target its factory names")
    func transferNamesOneTarget() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.desk.transfer(.agent(sessionId: "ds_1", agentId: "a_9", note: "VIP, be gentle"))
        try await client.desk.transfer(.skill(sessionId: "ds_1", skill: "billing"))
        try await client.desk.transfer(.queue(sessionId: "ds_1"))

        let sent = channel.requests(for: "desk.transfer").map(\.body)
        #expect(sent == [
            .object(["sessionId": .string("ds_1"), "toAgentId": .string("a_9"), "note": .string("VIP, be gentle")]),
            .object(["sessionId": .string("ds_1"), "toSkill": .string("billing")]),
            // `toQueue` is a C# bool: true/false, never "true" or 1, and only when it is the target.
            .object(["sessionId": .string("ds_1"), "toQueue": .bool(true)]),
        ])

        await client.disconnect()
    }

    @Test("a refused transfer reaches the caller with its code")
    func refusedTransferThrows() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            if request.target == "desk.transfer" {
                channel.reply(
                    to: request,
                    code: .invalidArgument,
                    message: "exactly one of toAgentId, toSkill or toQueue is required",
                    traceId: "trace-desk-1"
                )
            }
        })
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            try await client.desk.transfer(.queue(sessionId: "ds_1"))
            Issue.record("a refused transfer should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .invalidArgument)
            #expect(error.target == "desk.transfer")
            #expect(error.traceId == "trace-desk-1")
            #expect(!error.isRetryable)
        }

        await client.disconnect()
    }

    @Test("desk.close sends only what the agent filled in, and inviteRating only when said out loud")
    func closeOmitsWhatWasNotFilledIn() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.desk.close(DeskCloseRequest(sessionId: "ds_1"))
        try await client.desk.close(DeskCloseRequest(
            sessionId: "ds_1",
            resolution: "refunded",
            tags: ["billing/refund"],
            disposition: ImDeskDisposition.toLead,
            summary: "wants a refund, passed to sales",
            inviteRating: false
        ))

        let sent = channel.requests(for: "desk.close").map(\.body)
        // Omitting inviteRating invites; sending false would be a different request.
        #expect(sent == [
            .object(["sessionId": .string("ds_1")]),
            .object([
                "sessionId": .string("ds_1"),
                "resolution": .string("refunded"),
                "tags": .array([.string("billing/refund")]),
                "disposition": .string("to-lead"),
                "summary": .string("wants a refund, passed to sales"),
                "inviteRating": .bool(false),
            ]),
        ])

        await client.disconnect()
    }

    @Test("desk.status sends the agent status as its integer")
    func statusIsAnInteger() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.desk.status(DeskStatusRequest(status: .available))
        try await client.desk.status(DeskStatusRequest(status: .busy, maxConcurrent: 4))

        // An enum by name is refused with 1000 before the endpoint runs.
        let sent = channel.requests(for: "desk.status").map(\.body)
        #expect(sent == [
            .object(["status": .int(1)]),
            .object(["status": .int(2), "maxConcurrent": .int(4)]),
        ])

        await client.disconnect()
    }

    @Test("desk.queue sends no body and keeps an unmeasured average nil")
    func queueKeepsTheUnmeasuredAverageNil() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let view = try await client.desk.queue()

        #expect(channel.requests(for: "desk.queue").first?.body == .object([:]))
        #expect(view.waiting == 3)
        #expect(view.assigned == 2)
        #expect(view.availableAgents == 1)
        #expect(view.headWaitSeconds == 95)
        #expect(view.avgFirstResponseSeconds == nil, "absent is \"not measured\", and must not read as 0")
        #expect(view.waitingBySkill == ["billing": 3])

        await client.disconnect()
    }

    @Test("desk.queue decodes a measured average")
    func queueDecodesAMeasuredAverage() async throws {
        let gateway = Self.gateway(measuredQueue: true)
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let view = try await client.desk.queue()

        #expect(view.avgFirstResponseSeconds == 12.5)

        await client.disconnect()
    }

    @Test("desk.rate omits what the survey did not ask")
    func rateOmitsWhatWasNotAsked() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.desk.rate(DeskRateRequest(sessionId: "ds_1", score: 5))
        try await client.desk.rate(DeskRateRequest(
            sessionId: "ds_1",
            score: 2,
            resolved: false,
            starTags: ["slow"],
            comment: "twenty minutes"
        ))

        // resolved absent = the survey never asked; resolved false = "no".
        let sent = channel.requests(for: "desk.rate").map(\.body)
        #expect(sent == [
            .object(["sessionId": .string("ds_1"), "score": .int(5)]),
            .object([
                "sessionId": .string("ds_1"),
                "score": .int(2),
                "resolved": .bool(false),
                "starTags": .array([.string("slow")]),
                "comment": .string("twenty minutes"),
            ]),
        ])

        await client.disconnect()
    }

    @Test("desk.canned filters by what it is given and decodes each tier")
    func cannedFiltersAndDecodes() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        _ = try await client.desk.canned()
        let replies = try await client.desk.canned(DeskCannedRequest(
            skill: "billing",
            scope: ImDeskCannedReplyScope.personal,
            ownerMemberId: "m_1"
        ))

        let sent = channel.requests(for: "desk.canned").map(\.body)
        #expect(sent == [
            .object([:]),
            .object(["skill": .string("billing"), "scope": .string("personal"), "ownerMemberId": .string("m_1")]),
        ])

        #expect(replies.map(\.id) == ["cr_1", "cr_2"])
        #expect(replies.first?.title == "Refunds")
        #expect(replies.first?.content == "Refunds take 3-5 days.")
        #expect(replies.first?.skill == "billing")
        #expect(replies.first?.scope == ImDeskCannedReplyScope.personal)
        #expect(replies.first?.folder == "refunds")
        #expect(replies.first?.ownerMemberId == "m_1")
        #expect(replies.first?.updatedAt == 1_755_000_000_000)
        #expect(replies.last?.scope == ImDeskCannedReplyScope.all)
        #expect(replies.last?.ownerMemberId == nil)
        #expect(replies.last?.skill == nil)
        #expect(replies.last?.folder == nil)

        await client.disconnect()
    }

    @Test("desk.suggest names the session and returns the drafts")
    func suggestReturnsDrafts() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let drafts = try await client.desk.suggest(DeskSuggestRequest(sessionId: "ds_1"))

        #expect(channel.requests(for: "desk.suggest").first?.body == .object(["sessionId": .string("ds_1")]))
        #expect(drafts == ["Sure, one moment."])

        await client.disconnect()
    }

    @Test("evt.desk frames decode, a forced release carries no session, and an unknown event is skipped")
    func deskEventsDecode() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        let events = Collector(client.deskEvents())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.desk, data: .object([
            "event": .string("desk.session"),
            "change": .string("message"),
            "session": Self.session(full: true),
            "message": .object(["messageId": .string("360381357961969667")]),
        ]))
        channel.event(.desk, data: .object(["event": .string("desk.somethingNew")]))
        channel.event(.desk, data: .object([
            "event": .string("desk.session"),
            "change": .string("released"),
            "reason": .string("supervisor"),
            "forced": .bool(true),
        ]))
        channel.event(.desk, data: .object([
            "event": .string("desk.agent"),
            "change": .string("takeover"),
            "connectionId": .string("conn-2"),
            "memberId": .string("m_1"),
        ]))
        channel.event(.desk, data: .object([
            "event": .string("desk.session"),
            "change": .string("overdue"),
            "session": Self.session(full: true),
            "kind": .string("first-response"),
            "assignedAt": .int(1_755_000_060_000),
            "minutes": .int(5),
        ]))
        channel.event(.desk, data: .object([
            "event": .string("desk.session"),
            "change": .string("inactive"),
            "session": Self.session(full: true),
            "minutes": .int(10),
            "silentSince": .int(1_755_000_500_000),
            "star": .bool(true),
        ]))
        channel.event(.desk, data: .object([
            "event": .string("desk.session"),
            "change": .string("note"),
            "session": Self.session(full: true),
            "note": .object(["text": .string("called back")]),
            "author": .object(["memberId": .string("m_2")]),
        ]))

        _ = await waitUntil("six desk frames") { events.count >= 6 }
        await settle()
        let received = events.items
        events.stop()

        #expect(received.count == 6, "the unknown event is skipped, not delivered half-built")
        guard received.count == 6 else {
            await client.disconnect()
            return
        }

        #expect(received[0].change == ImDeskSessionChange.message)
        #expect(received[0].session?.sessionId == "ds_1")
        #expect(received[0].message?["messageId"] == .string("360381357961969667"))

        #expect(received[1].change == ImDeskSessionChange.released)
        #expect(received[1].session == nil, "a forced release carries no session")
        #expect(received[1].forced == true)
        #expect(received[1].reason == "supervisor")

        #expect(received[2].event == DeskEvent.agentEvent)
        #expect(received[2].change == ImDeskSessionChange.takeover)
        #expect(received[2].connectionId == "conn-2")
        #expect(received[2].memberId == "m_1")
        #expect(received[2].session == nil)

        #expect(received[3].change == ImDeskSessionChange.overdue)
        #expect(received[3].kind == "first-response")
        #expect(received[3].assignedAt == 1_755_000_060_000)
        #expect(received[3].minutes == 5)

        #expect(received[4].change == ImDeskSessionChange.inactive)
        #expect(received[4].minutes == 10)
        #expect(received[4].silentSince == 1_755_000_500_000)
        #expect(received[4].star == true)

        #expect(received[5].change == ImDeskSessionChange.note)
        #expect(received[5].note?["text"] == .string("called back"))
        #expect(received[5].author?["memberId"] == .string("m_2"))

        await client.disconnect()
    }

    /// The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
    /// decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
    /// member the server's type declares, held here to `endpoint-inventory.json`'s `payloadTypes`.
    @Test("the full fixtures carry every member the server declares")
    func fixturesCarryEveryServerMember() throws {
        let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.inventoryURL())) as? [String: Any]
        let types = inventory?["payloadTypes"] as? [String: Any] ?? [:]

        func members(_ type: String) -> Set<String> {
            let properties = (types[type] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
            return Set(properties.compactMap { $0["name"] as? String })
        }

        func keys(_ value: JSONValue) -> Set<String> {
            if case let .object(members) = value { return Set(members.keys) }
            return []
        }

        #expect(!members("DeskSession").isEmpty, "the inventory lists no members for DeskSession")
        #expect(keys(Self.session(full: true)) == members("DeskSession"))
        #expect(keys(Self.queueView(measured: true)) == members("DeskQueueView"))
        #expect(keys(Self.cannedRow) == members("DeskCannedReply"))
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

    /// CONTRACT.md §4.5: the change values are held to the server's list, order included.
    @Test("the change values are the server's thirteen, in its order")
    func changeValuesMatchTheInventory() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var inventory: URL?
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("endpoint-inventory.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                inventory = candidate
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let url = try #require(inventory, "could not locate sdk/endpoint-inventory.json")

        // The block is an object whose member order is the server's declaration order; a Swift
        // dictionary would lose it, so the values are read in textual order instead.
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "\"deskChanges\""))
        let open = try #require(text.range(of: "{", range: start.upperBound ..< text.endIndex))
        let close = try #require(text.range(of: "}", range: open.upperBound ..< text.endIndex))
        let block = String(text[open.upperBound ..< close.lowerBound])

        let expression = try NSRegularExpression(pattern: "\"[A-Za-z]+\"\\s*:\\s*\"([^\"]+)\"")
        let range = NSRange(block.startIndex ..< block.endIndex, in: block)
        let server: [String] = expression.matches(in: block, range: range).compactMap { match in
            Range(match.range(at: 1), in: block).map { String(block[$0]) }
        }

        #expect(server.count == 13, "the inventory's deskChanges parsed to \(server.count) values")
        #expect(ImDeskSessionChange.all == server)
    }

    // MARK: - The 1801-1807 notices

    /// A desk notice, as it arrives inside an ordinary message on the customer's transcript —
    /// decoded through `ImMessage`'s own decoder, the way `messages()` would hand it over.
    private static func notice(
        _ content: [String: JSONValue],
        contentType: MessageContentType = .notification
    ) throws -> ImMessage {
        try JSONValue.object([
            "appId": "demo",
            "conversationId": "c1",
            "conversationType": 1,
            "seq": 4,
            "messageId": "350598345233801216",
            "clientMsgId": "desk-1801-x",
            "senderId": "desk",
            "senderPlatform": 100,
            "contentType": .int(Int64(contentType.rawValue)),
            "content": .object(content),
            "sendTime": 1_755_000_000_000,
            "createTime": 1_755_000_000_000,
        ]).decoded(as: ImMessage.self)
    }

    @Test("DeskNotification.read reads all seven codes with the extras each one carries")
    func noticeReadsAllSevenCodes() throws {
        let queued = try DeskNotification.read(
            Self.notice(["code": 1801, "sessionId": "ds_1", "customerId": "v_1", "skill": "billing"])
        )
        // The whole value: no agentId, because none was written.
        #expect(queued == DeskNotification(sessionId: "ds_1", customerId: "v_1", skill: "billing", kind: .queued))
        #expect(queued?.code == ImDeskNotificationCode.queued)

        let assigned = try DeskNotification.read(
            Self.notice(["code": 1802, "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "agentId": "a_7"])
        )
        #expect(assigned?.code == ImDeskNotificationCode.assigned)
        #expect(assigned?.agentId == "a_7")
        // `skill` is written into a dictionary, where "omit nulls" does not reach, so the key is there
        // and the value is null. `agentId` is only written when there is one. Two different absences.
        // skill 是写进字典的，「省略 null」管不到它：键在、值是 null。agentId 则是有才写。两种不同的「没有」。
        #expect(assigned == DeskNotification(sessionId: "ds_1", customerId: "v_1", skill: nil, agentId: "a_7", kind: .assigned))

        let transferred = try DeskNotification.read(
            Self.notice([
                "code": 1803, "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "agentId": "a_8",
                "fromAgentId": "a_7",
            ])
        )
        #expect(transferred?.code == ImDeskNotificationCode.transferred)
        #expect(transferred == DeskNotification(
            sessionId: "ds_1", customerId: "v_1", agentId: "a_8", kind: .transferred(fromAgentId: "a_7")
        ))

        let closed = try DeskNotification.read(
            Self.notice(["code": 1804, "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "reason": "timeout"])
        )
        #expect(closed?.code == ImDeskNotificationCode.closed)
        #expect(closed?.kind == .closed(resolution: nil, reason: ImDeskEndReason.timeout))

        let requeued = try DeskNotification.read(
            Self.notice(["code": 1805, "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "previousAgentId": "a_7"])
        )
        #expect(requeued?.code == ImDeskNotificationCode.requeued)
        #expect(requeued?.kind == .requeued(previousAgentId: "a_7"))

        let abandoned = try DeskNotification.read(
            Self.notice(["code": 1806, "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "waitedSeconds": 903])
        )
        #expect(abandoned?.code == ImDeskNotificationCode.abandoned)
        #expect(abandoned?.kind == .abandoned(waitedSeconds: 903))

        let rating = try DeskNotification.read(
            Self.notice([
                "code": 1807, "sessionId": "ds_1", "customerId": "v_1", "skill": .null,
                "windowHours": 24, "askResolved": true, "starTags": ["slow", "wrong answer"],
            ])
        )
        #expect(rating?.code == ImDeskNotificationCode.ratingRequested)
        #expect(rating?.kind == .ratingRequested(windowHours: 24, askResolved: true, starTags: ["slow", "wrong answer"]))
    }

    @Test("a 1804 keeps a typed resolution, and leaves both absent when nothing was filled in")
    func noticeClosedResolution() throws {
        let typed = try DeskNotification.read(
            Self.notice([
                "code": 1804, "sessionId": "ds_1", "customerId": "v_1", "skill": "billing", "agentId": "a_7",
                "resolution": "refunded",
            ])
        )
        #expect(typed == DeskNotification(
            sessionId: "ds_1", customerId: "v_1", skill: "billing", agentId: "a_7",
            kind: .closed(resolution: "refunded", reason: nil)
        ))

        let bare = try DeskNotification.read(
            Self.notice(["code": 1804, "sessionId": "ds_1", "customerId": "v_1", "skill": .null])
        )
        #expect(bare == DeskNotification(sessionId: "ds_1", customerId: "v_1", kind: .closed(resolution: nil, reason: nil)))
    }

    @Test("DeskNotification.read coerces the counts the server may have written as strings")
    func noticeCoercesQuotedNumbers() throws {
        // `NumberHandling.AllowReadingFromString` runs in both directions in practice: a 64-bit value
        // can arrive quoted. The code itself is read the same way.
        // 服务端可以把 64 位数字写成字符串；码值与计数都按同一条规则读。
        let abandoned = try DeskNotification.read(
            Self.notice(["code": "1806", "sessionId": "ds_1", "customerId": "v_1", "skill": .null, "waitedSeconds": "903"])
        )
        #expect(abandoned?.kind == .abandoned(waitedSeconds: 903))

        let rating = try DeskNotification.read(
            Self.notice(["code": 1807, "sessionId": "ds_1", "customerId": "v_1", "windowHours": "48"])
        )
        #expect(rating?.kind == .ratingRequested(windowHours: 48, askResolved: false, starTags: []))

        // A whole number written with a fraction part is still that number, as `Number("1806.0")` is
        // in TypeScript; a fractional count is truncated rather than lost.
        let wholeDouble = try DeskNotification.read(Self.notice(["code": 1806.0, "waitedSeconds": 903.7]))
        #expect(wholeDouble?.kind == .abandoned(waitedSeconds: 903))
        let quotedFraction = try DeskNotification.read(Self.notice(["code": "1806.0", "waitedSeconds": "903.7"]))
        #expect(quotedFraction?.kind == .abandoned(waitedSeconds: 903))
    }

    @Test("DeskNotification.read reads a member of the wrong kind as its default and never traps")
    func noticeWrongKindsReadAsDefaults() throws {
        // A notice is half of a customer's transcript: one odd member must not make the whole line
        // vanish, and it must not trap inside the message handler either.
        // 一个字段类型不对，不能让整条通知消失，更不能在消息回调里崩掉。
        let odd = try DeskNotification.read(
            Self.notice([
                "code": 1803,
                "sessionId": .int(360_381_357_961_969_667), // an older server's numeric id: kept as its literal
                // customerId absent
                "skill": 7,
                "agentId": "",
                "fromAgentId": ["id": "a_7"],
            ])
        )
        #expect(
            odd == DeskNotification(sessionId: "360381357961969667", kind: .transferred(fromAgentId: "")),
            "an empty agentId is no agent, a number is no skill, an object where an id belongs is no id"
        )

        let closed = try DeskNotification.read(
            Self.notice(["code": 1804, "sessionId": "ds_1", "resolution": 3, "reason": true, "agentId": 9])
        )
        #expect(closed == DeskNotification(sessionId: "ds_1", kind: .closed(resolution: nil, reason: nil)))

        let requeued = try DeskNotification.read(Self.notice(["code": 1805, "previousAgentId": .null, "customerId": true]))
        #expect(requeued == DeskNotification(customerId: "true", kind: .requeued(previousAgentId: "")))

        let soon = try DeskNotification.read(Self.notice(["code": 1806, "waitedSeconds": "soon"]))
        #expect(soon == DeskNotification(kind: .abandoned(waitedSeconds: 0)), "a count that is not a number reads as 0")
        let object = try DeskNotification.read(Self.notice(["code": 1806, "waitedSeconds": [:]]))
        #expect(object == DeskNotification(kind: .abandoned(waitedSeconds: 0)))
        // Far past Int64: `Int64(_:)` would trap here, and a trap in a message handler is a crash.
        let huge = try DeskNotification.read(Self.notice(["code": 1806, "waitedSeconds": 1e30]))
        #expect(huge == DeskNotification(kind: .abandoned(waitedSeconds: 0)))
        let hugeQuoted = try DeskNotification.read(Self.notice(["code": 1806, "waitedSeconds": "1e30"]))
        #expect(hugeQuoted == DeskNotification(kind: .abandoned(waitedSeconds: 0)))

        let rating = try DeskNotification.read(
            Self.notice([
                "code": 1807,
                "windowHours": "a day",
                "askResolved": "true", // a string is not the JSON true
                "starTags": ["slow", 5, .null, ["tag": "x"], "rude"],
            ])
        )
        #expect(rating == DeskNotification(kind: .ratingRequested(windowHours: 0, askResolved: false, starTags: ["slow", "rude"])))

        let tagsNotAnArray = try DeskNotification.read(Self.notice(["code": 1807, "starTags": "slow", "askResolved": 1]))
        #expect(tagsNotAnArray?.kind == .ratingRequested(windowHours: 0, askResolved: false, starTags: []))
    }

    @Test("DeskNotification.read leaves an ordinary chat message alone")
    func noticeLeavesChatAlone() throws {
        // The reason this matters: desk notices travel down the same `messages()` stream as chat, so
        // the handler asks this first and falls through. A reader keyed on `code` alone would
        // eventually hit a tenant's own notification and draw a support line into the wrong
        // conversation.
        let chat = try Self.notice(["code": 1801, "text": "hello"], contentType: .text)
        #expect(DeskNotification.read(chat) == nil, "the code is right but the content type is not a notification")
        let noCode = try Self.notice(["text": "hello"])
        #expect(DeskNotification.read(noCode) == nil, "a notification with no code is not a desk notice")
        #expect(DeskNotification.read(nil) == nil)
    }

    @Test("DeskNotification.read refuses the account error codes that share these seven numbers")
    func noticeRefusesCodesOutsideTheBand() throws {
        // 1801 is `AccountLocked` on the server's own error table and 1804 is `PasswordTooWeak`. They
        // never appear in `message.content`, and this is the assertion that keeps the two tables apart:
        // a code outside the band is not a desk notice however plausible it looks.
        // 1801 在服务端错误码表里是「账号已锁定」。这条断言守住的就是「两张表不能合并」。
        for code: JSONValue in [1800, 1808, 1500] {
            let message = try Self.notice(["code": code, "sessionId": "ds_1", "customerId": "v_1"])
            #expect(DeskNotification.read(message) == nil, "\(code)")
        }
        // And a code that is not a whole number is no code.
        for code: JSONValue in [1801.5, "1801.5", "18o1", "", true, .null, ["value": 1801], [1801]] {
            let message = try Self.notice(["code": code])
            #expect(DeskNotification.read(message) == nil, "\(code)")
        }
    }

    @Test("a notice decoded off the wire reads, and a switch over its kind needs no default")
    func noticeDecodedOffTheWire() throws {
        let json = #"{"conversationId":"c1","seq":"4","messageId":"350598345233801216","contentType":9,"senderId":"desk","content":{"code":1802,"sessionId":"ds_1","customerId":"v_1","skill":null,"agentId":"a_7"}}"#
        let message = try JSONDecoder().decode(ImMessage.self, from: Data(json.utf8))
        let read = try #require(DeskNotification.read(message))

        // Exhaustive without a `default`: a new case is a compile error here, not a silent miss.
        let sentence: String
        switch read.kind {
        case .queued: sentence = "queued"
        case .assigned: sentence = "with \(read.agentId ?? "?")"
        case .transferred: sentence = "transferred"
        case .closed: sentence = "closed"
        case .requeued: sentence = "requeued"
        case .abandoned: sentence = "abandoned"
        case .ratingRequested: sentence = "rate"
        }
        #expect(sentence == "with a_7")
        #expect(read.skill == nil)
    }

    /// The constants are held to TypeScript's, where they were first written down: a key spelled
    /// differently here is a context value the engine silently fails to copy out. Read line by line
    /// from source with regexes, as `changeValuesMatchTheInventory` reads the inventory.
    @Test("ImDeskContextKeys and ImDeskNotificationCode are TypeScript's, name for name")
    func deskConstantsMatchTypeScript() throws {
        let root = try Self.inventoryURL().deletingLastPathComponent()

        func block(_ file: String, _ start: String, _ pattern: String) throws -> [String: String] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let from = try #require(text.range(of: start), "\(start) is not in \(file)")
            let expression = try NSRegularExpression(pattern: pattern)
            var found: [String: String] = [:]
            // `.newlines` rather than splitting on "\n": a CRLF file's "\r\n" is one Character.
            for line in text[from.upperBound...].components(separatedBy: .newlines).dropFirst() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("}") { break }
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard let match = expression.firstMatch(in: line, range: range),
                      let name = Range(match.range(at: 1), in: line),
                      let value = Range(match.range(at: 2), in: line)
                else { continue }
                found[String(line[name])] = String(line[value])
            }
            return found
        }

        let typeScriptKeys = try block(
            "typescript/src/desk.ts", "export const DeskContextKeys = {", #"^\s*(\w+): '([^']*)',\s*$"#
        )
        let typeScriptCodes = try block(
            "typescript/src/protocol.ts", "export const DeskNotificationCode = {", #"^\s*(\w+): (\d+),\s*$"#
        )

        let keys: [String: String] = [
            "Channel": ImDeskContextKeys.channel,
            "VisitorId": ImDeskContextKeys.visitorId,
            "DeskId": ImDeskContextKeys.deskId,
            "GroupId": ImDeskContextKeys.groupId,
            "Origin": ImDeskContextKeys.origin,
            "OriginBot": ImDeskContextKeys.originBot,
            "Page": ImDeskContextKeys.page,
            "VisitorName": ImDeskContextKeys.visitorName,
            "VisitorEmail": ImDeskContextKeys.visitorEmail,
        ]
        let codes: [String: String] = [
            "Queued": String(ImDeskNotificationCode.queued),
            "Assigned": String(ImDeskNotificationCode.assigned),
            "Transferred": String(ImDeskNotificationCode.transferred),
            "Closed": String(ImDeskNotificationCode.closed),
            "Requeued": String(ImDeskNotificationCode.requeued),
            "Abandoned": String(ImDeskNotificationCode.abandoned),
            "RatingRequested": String(ImDeskNotificationCode.ratingRequested),
        ]

        #expect(typeScriptKeys.count == 9, "parsed TypeScript's DeskContextKeys: \(typeScriptKeys)")
        #expect(keys == typeScriptKeys)
        #expect(typeScriptCodes.count == 7, "parsed TypeScript's DeskNotificationCode: \(typeScriptCodes)")
        #expect(codes == typeScriptCodes)
        #expect(typeScriptCodes.values.compactMap { Int($0) }.sorted() == Array(1801 ... 1807))
    }
}
