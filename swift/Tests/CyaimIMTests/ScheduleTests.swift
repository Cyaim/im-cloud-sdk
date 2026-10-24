import Foundation
import Testing

@testable import CyaimIM

/// `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled`, `conv.folders` / `conv.upsertFolder` /
/// `conv.deleteFolder`, and `msg.translate` — the seven T4 calls typed together. Mirrors the Kotlin
/// `ScheduleTest`.
///
/// Every call is asserted on the whole frame it puts on the wire — target and body, compared as a
/// ``JSONValue`` so `.string("7")`, `.int(7)` and an absent key are told apart — and on what it makes
/// of a reply with every field set; the fixtures and requests are held to `endpoint-inventory.json`'s
/// `payloadTypes`. Three rules get tests of their own: a schedule moves no cursor and the message it
/// fires is an ordinary `evt.message`; a refused schedule is not retried, because the call is not
/// idempotent; and a deployment without translation (`1203` / `1204`) reaches the caller as an
/// ordinary, readable ``ImError`` — code, the server's message, the target — and leaves the connection
/// usable.
///
/// 每个调用断言发出的整帧与对满字段答复的解码，夹具与请求对着清单的 payloadTypes 钉住。另有三条规则单独测：
/// 定时不动游标、到点发出的是普通 evt.message；被拒的定时不重试（它不幂等）；没有翻译能力的部署（1203 / 1204）
/// 以普通、可读的 ImError 交给调用方，连接照常可用。
@Suite("Schedule, folders, translation")
struct ScheduleTests {

    /// Past 2^53 and odd, so a trip through a Double would change its last digit.
    private static let bigId: Int64 = 360_381_357_961_969_667

    // MARK: - Fixtures

    /// Every member of the server's ScheduledMessage when both optionals are given, each with a value
    /// no default reads as. `fixturesCarryEveryServerMember` holds the list to the inventory.
    private static func scheduled(
        _ scheduleId: String = "sch_7f3a",
        messageId: JSONValue? = nil,
        error: String? = nil
    ) -> JSONValue {
        var members: [String: JSONValue] = [
            "scheduleId": .string(scheduleId),
            "appId": .string("demo"),
            "senderId": .string("alice"),
            "conversationId": .string("s_alice_bob"),
            "sendAt": .int(1_755_000_060_000),
            "createdAt": .int(1_755_000_000_000),
        ]
        if let messageId { members["messageId"] = messageId }
        if let error { members["error"] = .string(error) }
        return .object(members)
    }

    /// Every member of the server's ConversationFolder.
    private static func folder(_ folderId: String = "f_work", withTypes: Bool = true) -> JSONValue {
        var members: [String: JSONValue] = [
            "folderId": .string(folderId),
            "name": .string("Work"),
            "order": .int(3),
            "tags": .array([.string("work"), .string("clients")]),
            "unreadOnly": .bool(true),
        ]
        if withTypes { members["types"] = .array([.int(1), .int(2)]) }
        return .object(members)
    }

    private static func translated(_ messageId: JSONValue, text: String?, cached: Bool, error: String?) -> JSONValue {
        var members: [String: JSONValue] = [
            "messageId": messageId,
            "cached": .bool(cached),
        ]
        if let text { members["text"] = .string(text) }
        if let error { members["error"] = .string(error) }
        return .object(members)
    }

    /// Every member of TranslationResult; between them the items carry every member of
    /// TranslatedMessage.
    private static func translation() -> JSONValue {
        .object([
            "targetLanguage": .string("zh-CN"),
            "items": .array([
                Self.translated(.string(String(Self.bigId)), text: "你好", cached: true, error: nil),
                Self.translated(.string("7"), text: nil, cached: false, error: "message has no text"),
            ]),
        ])
    }

    private static func outbox() -> JSONValue {
        .object([
            "items": .array([
                Self.scheduled("sch_pending"),
                Self.scheduled("sch_sent", messageId: .string(String(Self.bigId))),
                Self.scheduled("sch_cancelled", error: "cancelled by sender"),
                Self.scheduled("sch_failed", error: "send failed"),
            ]),
            "nextCursor": .string("c2"),
            "hasMore": .bool(true),
        ])
    }

    private static let noProvider = "no translation provider is configured (IM:Translation:Provider)"
    private static let notInPlan =
        "message translation is not included in this plan; start its trial or enable the add-on in the console"

    /// The server's three `1006` sentences for a schedule past cancelling, keyed by the id that gets
    /// each one here.
    private static let pastCancelling: [String: String] = [
        "sch_sending": "this message is already being sent and can no longer be cancelled",
        "sch_twice": "this scheduled message has already been cancelled",
        "sch_settled": "this scheduled message has already been sent or has failed, and can no longer be cancelled",
    ]

    private static func gateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            switch request.target {
            case "msg.schedule":
                if request["receiverId"]?.stringValue == "busy" {
                    channel.reply(to: request, code: .rateLimited, message: "too many schedules", traceId: "trace-refused")
                } else {
                    channel.reply(to: request, data: Self.scheduled())
                }
            case "msg.scheduled":
                channel.reply(to: request, data: Self.outbox())
            case "msg.cancelScheduled":
                let scheduleId = request["scheduleId"]?.stringValue ?? ""
                if scheduleId == "sch_nope" {
                    channel.reply(to: request, code: .notFound, message: "no such scheduled message", traceId: "trace-refused")
                } else if let sentence = Self.pastCancelling[scheduleId] {
                    channel.reply(to: request, code: .conflict, message: sentence, traceId: "trace-refused")
                } else {
                    channel.reply(to: request, data: .null)
                }
            case "conv.folders":
                channel.reply(to: request, data: .array([Self.folder(), Self.folder("f_all", withTypes: false)]))
            case "conv.upsertFolder":
                channel.reply(to: request, data: Self.folder())
            case "conv.deleteFolder":
                if request["folderId"]?.stringValue == "f_gone" {
                    channel.reply(to: request, code: .notFound, message: "no such folder", traceId: "trace-refused")
                } else {
                    channel.reply(to: request, data: .null)
                }
            case "msg.translate":
                switch request["conversationId"]?.stringValue ?? "" {
                case "s_no_provider":
                    channel.reply(to: request, code: .featureNotEnabled, message: Self.noProvider, traceId: "trace-refused")
                case "s_not_in_plan":
                    channel.reply(to: request, code: .planExpired, message: Self.notInPlan, traceId: "trace-refused")
                default:
                    channel.reply(to: request, data: Self.translation())
                }
            default:
                // Nothing else is scripted here. cancelScheduled and deleteFolder above acknowledge the
                // way the server does, with no payload; so does this.
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

    /// The ``ImError`` a call fails with, or `nil` when it succeeded (or failed some other way).
    private static func failure(_ call: () async throws -> Void) async -> ImError? {
        do {
            try await call()
            return nil
        } catch let error as ImError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - msg.schedule

    @Test("msg.schedule sends the flat request with no options, no sendTime and no invented key, and decodes a pending entry")
    func scheduleSendsTheFlatRequest() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let entry = try await client.msg.schedule(ScheduleRequest(
            sendAt: 1_755_000_060_000,
            content: ["text": .string("later")],
            receiverId: "bob"
        ))

        let expected: JSONValue = .object([
            "sendAt": .int(1_755_000_060_000),
            "content": .object(["text": .string("later")]),
            "contentType": .int(1),
            "receiverId": .string("bob"),
            "mentionAll": .bool(false),
            "mentionedUserIds": .array([]),
        ])
        let sent = channel.requests(for: "msg.schedule")
        #expect(sent.map(\.target) == ["msg.schedule"])
        #expect(sent.map(\.body) == [expected])

        // The server derives sch-<scheduleId> for a missing key; the SDK must not make one up, and
        // there is no options or sendTime on this wire at all.
        let body = try #require(sent.first?.body)
        #expect(body["clientMsgId"] == nil, "an absent key is left to the server: \(body)")
        #expect(body["options"] == nil)
        #expect(body["sendTime"] == nil)

        #expect(entry.scheduleId == "sch_7f3a")
        #expect(entry.id == "sch_7f3a")
        #expect(entry.appId == "demo")
        #expect(entry.senderId == "alice")
        #expect(entry.conversationId == "s_alice_bob")
        #expect(entry.sendAt == 1_755_000_060_000)
        #expect(entry.createdAt == 1_755_000_000_000)
        #expect(entry.messageId == nil, "pending: not sent yet")
        #expect(entry.error == nil, "pending: neither cancelled nor failed")

        await client.disconnect()
    }

    @Test("msg.schedule writes every member in the kind the server binds, the quote and thread ids quoted")
    func scheduleWritesEveryMember() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let content: [String: JSONValue] = ["url": .string("media/a.png")]
        let extensions: [String: JSONValue] = ["k": .string("v")]
        try await client.msg.schedule(ScheduleRequest(
            sendAt: 1_755_000_060_000,
            content: content,
            contentType: .image,
            conversationId: "g_team",
            receiverId: "bob",
            groupId: "team",
            conversationType: .group,
            clientMsgId: "cid-later",
            mentionAll: true,
            mentionedUserIds: ["bob", "carol"],
            quoteMessageId: Self.bigId,
            threadRootId: Self.bigId - 2,
            extensions: extensions
        ))

        let expected: [String: JSONValue] = [
            "sendAt": .int(1_755_000_060_000),
            "content": .object(content),
            "contentType": .int(2),
            "conversationId": .string("g_team"),
            "receiverId": .string("bob"),
            "groupId": .string("team"),
            "conversationType": .int(2),
            "clientMsgId": .string("cid-later"),
            "mentionAll": .bool(true),
            "mentionedUserIds": .array([.string("bob"), .string("carol")]),
            "quoteMessageId": .string("360381357961969667"),
            "threadRootId": .string("360381357961969665"),
            "extensions": .object(extensions),
        ]
        #expect(channel.requests(for: "msg.schedule").map(\.body) == [.object(expected)])
        let server = try Self.members("ScheduleRequest")
        #expect(Set(expected.keys) == server, "every member of the server's ScheduleRequest")

        await client.disconnect()
    }

    @Test("a refused msg.schedule reaches the caller once and is never retried, retryable code or not")
    func refusedScheduleIsNotRetried() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let refused = await Self.failure {
            _ = try await client.msg.schedule(ScheduleRequest(
                sendAt: 1_755_000_060_000,
                content: ["text": .string("later")],
                receiverId: "busy"
            ))
        }
        let error = try #require(refused)
        #expect(error.code == .rateLimited)
        #expect(error.message == "too many schedules")
        #expect(error.target == "msg.schedule")
        #expect(error.isRetryable, "the application may retry it; the SDK does not")

        // Not idempotent: a retry the SDK made on its own could schedule twice.
        await settle()
        #expect(channel.requests(for: "msg.schedule").count == 1)

        await client.disconnect()
    }

    // MARK: - msg.scheduled

    @Test("msg.scheduled sends the page and tells pending, sent, cancelled and failed apart")
    func scheduledTellsTheStatesApart() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let page = try await client.msg.scheduled()
        _ = try await client.msg.scheduled(PageRequest(cursor: page.nextCursor, limit: 100))

        let sent = channel.requests(for: "msg.scheduled").map(\.body)
        #expect(sent == [
            .object(["limit": .int(20)]),
            .object(["cursor": .string("c2"), "limit": .int(100)]),
        ], "no cursor on the first page")

        #expect(page.nextCursor == "c2")
        #expect(page.hasMore)
        #expect(page.total == nil)
        #expect(page.items.map(\.scheduleId) == ["sch_pending", "sch_sent", "sch_cancelled", "sch_failed"])
        try #require(page.items.count == 4)

        let pending = page.items[0]
        #expect(pending.messageId == nil)
        #expect(pending.error == nil)

        let sentEntry = page.items[1]
        #expect(sentEntry.messageId == Self.bigId, "a string id decodes with every digit")
        #expect(sentEntry.error == nil)

        let cancelled = page.items[2]
        #expect(cancelled.error == "cancelled by sender", "a cancelled entry stays listed, marked")
        #expect(cancelled.messageId == nil)

        let failed = page.items[3]
        #expect(failed.error == "send failed")
        #expect(failed.messageId == nil)
        #expect(failed.sendAt == 1_755_000_060_000)

        await client.disconnect()
    }

    @Test("a scheduled message id written as a bare number decodes too")
    func scheduledMessageIdAsANumber() throws {
        let data = try JSONEncoder().encode(Self.scheduled(messageId: .int(42)))
        let entry = try JSONDecoder().decode(ScheduledMessage.self, from: data)
        #expect(entry.messageId == 42)

        let quoted = try JSONDecoder().decode(
            ScheduledMessage.self,
            from: JSONEncoder().encode(Self.scheduled(messageId: .string(String(Self.bigId))))
        )
        #expect(quoted.messageId == Self.bigId)
    }

    // MARK: - msg.cancelScheduled

    @Test("msg.cancelScheduled sends only the id on both overloads, and a refusal carries the server's words")
    func cancelScheduledSendsOnlyTheId() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.msg.cancelScheduled(ScheduleIdRequest("sch_7f3a"))
        try await client.msg.cancelScheduled("sch_8b1c")

        let bodies = channel.requests(for: "msg.cancelScheduled").map(\.body)
        #expect(bodies == [
            .object(["scheduleId": .string("sch_7f3a")]),
            .object(["scheduleId": .string("sch_8b1c")]),
        ])

        let unknownError = await Self.failure { try await client.msg.cancelScheduled("sch_nope") }
        let unknown = try #require(unknownError)
        #expect(unknown.code == .notFound)
        #expect(unknown.message == "no such scheduled message")
        #expect(unknown.target == "msg.cancelScheduled")
        #expect(unknown.traceId == "trace-refused")

        // 1006 has three meanings with one code; only the sentence tells them apart, so it must
        // arrive intact.
        for (scheduleId, sentence) in Self.pastCancelling.sorted(by: { $0.key < $1.key }) {
            let lateError = await Self.failure { try await client.msg.cancelScheduled(ScheduleIdRequest(scheduleId)) }
            let late = try #require(lateError, "\(scheduleId) should have been refused")
            #expect(late.code == .conflict, "\(scheduleId)")
            #expect(late.message == sentence)
            #expect(late.target == "msg.cancelScheduled")
            #expect(!late.isRetryable, "nothing is left to cancel")
        }

        await client.disconnect()
    }

    // MARK: - A fired schedule is an ordinary message

    @Test("scheduling moves no cursor, and the message it fires is an ordinary evt.message")
    func schedulingMovesNoCursor() async throws {
        let store = RecordingCursorStore()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.msg.schedule(ScheduleRequest(
            sendAt: 1_755_000_060_000,
            content: ["text": .string("later")],
            receiverId: "bob"
        ))
        await client.enterBackground()
        await settle()

        #expect(messages.count == 0, "a schedule delivers nothing")
        #expect(await client.committedSeq(in: "s_alice_bob") == 0)
        #expect(await client.highestSeq(in: "s_alice_bob") == 0)
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["s_alice_bob"] == nil })
        #expect(channel.requests(for: "msg.sync").isEmpty)

        // When it fires, the server sends it through the normal path: a plain evt.message with a real
        // seq and the derived key. No decoding of its own, no special case.
        channel.event(.message, data: .object([
            "appId": .string("demo"),
            "conversationId": .string("s_alice_bob"),
            "conversationType": .int(1),
            "seq": .int(1),
            "messageId": .string(String(Self.bigId)),
            "clientMsgId": .string("sch-sch_7f3a"),
            "senderId": .string("alice"),
            "senderPlatform": .int(1),
            "contentType": .int(1),
            "content": .object(["text": .string("later")]),
            "sendTime": .int(1_755_000_061_000),
            "createTime": .int(1_755_000_061_000),
        ]))
        _ = await waitUntil("the fired message") { messages.count == 1 }
        await settle()

        let fired = try #require(messages.items.first)
        #expect(messages.count == 1)
        #expect(fired.conversationId == "s_alice_bob")
        #expect(fired.seq == 1)
        #expect(fired.text == "later")
        #expect(fired.messageId == Self.bigId)
        #expect(fired.clientMsgId == "sch-sch_7f3a")
        #expect(await client.highestSeq(in: "s_alice_bob") == 1)
        #expect(channel.requests(for: "msg.sync").isEmpty, "seq 1 is contiguous; nothing to repair")

        await client.disconnect()
    }

    // MARK: - Folders

    @Test("conv.folders sends an empty body and decodes the bare array")
    func foldersDecodesTheBareArray() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let folders = try await client.conv.folders()

        let sent = channel.requests(for: "conv.folders")
        #expect(sent.map(\.target) == ["conv.folders"])
        #expect(sent.map(\.body) == [.object([:])])

        #expect(folders.map(\.folderId) == ["f_work", "f_all"])
        let work = try #require(folders.first)
        #expect(work.id == "f_work")
        #expect(work.name == "Work")
        #expect(work.order == 3)
        #expect(work.tags == ["work", "clients"])
        #expect(work.unreadOnly)
        #expect(work.types == [ConversationType.single, ConversationType.group], "integers on the wire")
        #expect(folders.last?.types == nil, "absent types means every type")

        await client.disconnect()
    }

    @Test("conv.upsertFolder creates without an id and replaces with one, every member in its kind")
    func upsertFolderCreatesAndReplaces() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let saved = try await client.conv.upsertFolder(UpsertFolderRequest(name: "Work"))
        try await client.conv.upsertFolder(UpsertFolderRequest(
            name: "Work",
            folderId: "f_work",
            order: 3,
            tags: ["work", "clients"],
            unreadOnly: true,
            types: [.single, .group]
        ))

        let create: JSONValue = .object([
            "name": .string("Work"),
            "order": .int(0),
            "tags": .array([]),
            "unreadOnly": .bool(false),
        ])
        let replace: [String: JSONValue] = [
            "name": .string("Work"),
            "folderId": .string("f_work"),
            "order": .int(3),
            "tags": .array([.string("work"), .string("clients")]),
            "unreadOnly": .bool(true),
            "types": .array([.int(1), .int(2)]),
        ]
        let sent = channel.requests(for: "conv.upsertFolder").map(\.body)
        #expect(sent == [create, .object(replace)], "no folderId creates; no types is all")
        let server = try Self.members("UpsertFolderRequest")
        #expect(Set(replace.keys) == server, "every member of the server's UpsertFolderRequest")

        #expect(saved.folderId == "f_work", "the saved folder, id included")
        #expect(saved.name == "Work")
        #expect(saved.order == 3)
        #expect(saved.tags == ["work", "clients"])
        #expect(saved.unreadOnly)
        #expect(saved.types == [ConversationType.single, ConversationType.group])

        await client.disconnect()
    }

    @Test("conv.deleteFolder sends only the id on both overloads, and an unknown one is 1002")
    func deleteFolderSendsOnlyTheId() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.conv.deleteFolder(FolderIdRequest("f_work"))
        try await client.conv.deleteFolder("f_home")

        let bodies = channel.requests(for: "conv.deleteFolder").map(\.body)
        #expect(bodies == [
            .object(["folderId": .string("f_work")]),
            .object(["folderId": .string("f_home")]),
        ])

        let goneError = await Self.failure { try await client.conv.deleteFolder("f_gone") }
        let gone = try #require(goneError)
        #expect(gone.code == .notFound)
        #expect(gone.message == "no such folder")
        #expect(gone.target == "conv.deleteFolder")

        await client.disconnect()
    }

    // MARK: - msg.translate

    @Test("msg.translate quotes every id and decodes each item, a per-message failure included")
    func translateQuotesEveryId() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let result = try await client.msg.translate(TranslateRequest(
            conversationId: "s_alice_bob",
            messageIds: [Self.bigId, 7],
            targetLanguage: "zh-CN"
        ))
        _ = try await client.msg.translate(TranslateRequest(
            conversationId: "s_alice_bob",
            messageIds: [Self.bigId],
            targetLanguage: "zh-CN",
            sourceLanguage: "en"
        ))

        let plain: JSONValue = .object([
            "conversationId": .string("s_alice_bob"),
            "messageIds": .array([.string("360381357961969667"), .string("7")]),
            "targetLanguage": .string("zh-CN"),
        ])
        let hinted: [String: JSONValue] = [
            "conversationId": .string("s_alice_bob"),
            "messageIds": .array([.string("360381357961969667")]),
            "targetLanguage": .string("zh-CN"),
            "sourceLanguage": .string("en"),
        ]
        let sent = channel.requests(for: "msg.translate")
        #expect(sent.map(\.target) == ["msg.translate", "msg.translate"])
        #expect(sent.map(\.body) == [plain, .object(hinted)], "strings on the server, every digit kept; no hint is left off")
        let server = try Self.members("TranslateRequest")
        #expect(Set(hinted.keys) == server, "every member of the server's TranslateRequest")

        #expect(result.targetLanguage == "zh-CN")
        #expect(result.items.count == 2)
        let done = try #require(result.items.first)
        #expect(done.messageId == Self.bigId)
        #expect(done.id == Self.bigId)
        #expect(done.text == "你好")
        #expect(done.cached)
        #expect(done.error == nil)

        let refused = try #require(result.items.last)
        #expect(refused.messageId == 7)
        #expect(refused.text == nil)
        #expect(!refused.cached)
        #expect(refused.error == "message has no text", "one item failing does not fail the call")

        await client.disconnect()
    }

    /// The point of typing this call at all on most deployments: no provider, or a plan without the
    /// add-on. Both must arrive as the SDK's ordinary error — code, the server's sentence, the target —
    /// and leave the connection usable, not as a crash or an undecodable reply.
    @Test("a deployment without translation answers 1203 or 1204 as an ordinary readable ImError")
    func translateRefusalsAreOrdinaryErrors() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let noProviderError = await Self.failure {
            _ = try await client.msg.translate(TranslateRequest(
                conversationId: "s_no_provider",
                messageIds: [Self.bigId],
                targetLanguage: "zh-CN"
            ))
        }
        let noProvider = try #require(noProviderError)
        #expect(noProvider.code == .featureNotEnabled)
        #expect(noProvider.code.rawValue == 1203)
        #expect(noProvider.message == Self.noProvider)
        #expect(noProvider.target == "msg.translate")
        #expect(noProvider.traceId == "trace-refused")
        #expect(!noProvider.isRetryable, "retrying cannot conjure a provider")
        #expect(!noProvider.requiresReauth)

        let notInPlanError = await Self.failure {
            _ = try await client.msg.translate(TranslateRequest(
                conversationId: "s_not_in_plan",
                messageIds: [Self.bigId],
                targetLanguage: "zh-CN"
            ))
        }
        let notInPlan = try #require(notInPlanError)
        #expect(notInPlan.code == .planExpired)
        #expect(notInPlan.code.rawValue == 1204)
        #expect(notInPlan.message == Self.notInPlan)
        #expect(notInPlan.target == "msg.translate")
        #expect(!notInPlan.isRetryable)
        #expect(!notInPlan.requiresReauth)

        // Each refusal was asked once, and it is the call's, not the connection's.
        #expect(channel.requests(for: "msg.translate").count == 2)
        #expect(try await client.conv.folders().count == 2)
        #expect(gateway.openedChannels.count == 1, "no reconnect")

        await client.disconnect()
    }

    // MARK: - Lenient decoding

    @Test("replies with numbers written as strings, and a conversation type this build does not name, still decode")
    func repliesDecodeLeniently() throws {
        let entry = try JSONDecoder().decode(ScheduledMessage.self, from: JSONEncoder().encode(JSONValue.object([
            "scheduleId": .string("sch_q"),
            "sendAt": .string("1755000060000"),
            "createdAt": .string("1755000000000"),
            "messageId": .string("7"),
        ])))
        #expect(entry.scheduleId == "sch_q")
        #expect(entry.sendAt == 1_755_000_060_000)
        #expect(entry.createdAt == 1_755_000_000_000)
        #expect(entry.messageId == 7)
        #expect(entry.appId == "")
        #expect(entry.senderId == "")
        #expect(entry.conversationId == "")
        #expect(entry.error == nil)

        let folder = try JSONDecoder().decode(ConversationFolder.self, from: JSONEncoder().encode(JSONValue.object([
            "folderId": .string("f_q"),
            "order": .string("3"),
            "types": .array([.string("1"), .int(2), .int(9)]),
        ])))
        #expect(folder.folderId == "f_q")
        #expect(folder.name == "")
        #expect(folder.order == 3)
        #expect(folder.tags == [])
        #expect(!folder.unreadOnly)
        #expect(folder.types == [ConversationType.single, ConversationType.group, ConversationType(9)], "an unknown type decodes as itself")

        let result = try JSONDecoder().decode(TranslationResult.self, from: JSONEncoder().encode(JSONValue.object([:])))
        #expect(result.targetLanguage == "")
        #expect(result.items.isEmpty)

        let item = try JSONDecoder().decode(TranslatedMessage.self, from: JSONEncoder().encode(JSONValue.object([
            "messageId": .int(42),
        ])))
        #expect(item.messageId == 42)
        #expect(item.text == nil)
        #expect(!item.cached)
        #expect(item.error == nil)
    }

    // MARK: - Held to the inventory

    /// The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
    /// decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
    /// member the server's type declares, and the requests send every member, held here to
    /// `endpoint-inventory.json`'s `payloadTypes`.
    @Test("the full fixtures and requests carry every member the server declares")
    func fixturesCarryEveryServerMember() throws {
        let scheduledMembers = try Self.members("ScheduledMessage")
        let folderMembers = try Self.members("ConversationFolder")
        let resultMembers = try Self.members("TranslationResult")
        let itemMembers = try Self.members("TranslatedMessage")

        #expect(!scheduledMembers.isEmpty, "the inventory lists no members for ScheduledMessage")
        #expect(Self.keys(Self.scheduled(messageId: .string("1"), error: "e")) == scheduledMembers)
        #expect(Self.keys(Self.folder()) == folderMembers)
        #expect(Self.keys(Self.translation()) == resultMembers)

        let items = Self.translation()["items"]?.arrayValue ?? []
        let itemKeys = items.reduce(into: Set<String>()) { union, item in union.formUnion(Self.keys(item)) }
        #expect(itemKeys == itemMembers, "between them the items carry every member")

        let schedule = try Self.keys(Self.wire(ScheduleRequest(
            sendAt: 1,
            content: ["text": .string("t")],
            conversationId: "c",
            receiverId: "r",
            groupId: "g",
            conversationType: .single,
            clientMsgId: "k",
            mentionedUserIds: ["u"],
            quoteMessageId: 1,
            threadRootId: 2,
            extensions: ["k": .string("v")]
        )))
        let scheduleId = try Self.keys(Self.wire(ScheduleIdRequest("s")))
        let page = try Self.keys(Self.wire(PageRequest(cursor: "c")))
        let upsert = try Self.keys(Self.wire(UpsertFolderRequest(name: "n", folderId: "f", types: [.single])))
        let folderId = try Self.keys(Self.wire(FolderIdRequest("f")))
        let translate = try Self.keys(Self.wire(TranslateRequest(
            conversationId: "c",
            messageIds: [1],
            targetLanguage: "en",
            sourceLanguage: "zh"
        )))

        let scheduleMembers = try Self.members("ScheduleRequest")
        let scheduleIdMembers = try Self.members("ScheduleIdRequest")
        let pageMembers = try Self.members("PageRequest")
        let upsertMembers = try Self.members("UpsertFolderRequest")
        let folderIdMembers = try Self.members("FolderIdRequest")
        let translateMembers = try Self.members("TranslateRequest")

        #expect(schedule == scheduleMembers)
        #expect(scheduleId == scheduleIdMembers)
        #expect(page == pageMembers)
        #expect(upsert == upsertMembers)
        #expect(folderId == folderIdMembers)
        #expect(translate == translateMembers)
    }

    /// `ScheduleRequest` is the members of the server's `SendMessageRequest` the scheduler reads, plus
    /// `sendAt`. This pins both halves: what it adds is exactly `sendAt`, and what it leaves out is
    /// exactly `options` and `sendTime`, which the server deliberately does not bind on this path — a
    /// member either type gains shows up here instead of going unexamined.
    @Test("a schedule request is the send request minus options and sendTime, plus sendAt")
    func scheduleRequestIsTheSendRequestNarrowed() throws {
        let schedule = try Self.members("ScheduleRequest")
        let send = try Self.members("SendMessageRequest")

        #expect(!send.isEmpty, "the inventory lists no members for SendMessageRequest")
        #expect(schedule.subtracting(send) == ["sendAt"])
        #expect(send.subtracting(schedule) == ["options", "sendTime"])
    }

    private static func members(_ type: String) throws -> Set<String> {
        let types = try Self.payloadTypes()
        let properties = (types[type] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
        return Set(properties.compactMap { $0["name"] as? String })
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
