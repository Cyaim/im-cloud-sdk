import Foundation
import Testing

@testable import CyaimIM

/// The cold-start cursor model, from `sdk/CONTRACT.md` §5.
///
/// This is the suite with a silent data-loss bug behind it. A client that restarts, fails to report
/// what it already holds, and adopts the server's newest `seq` loses every message that arrived
/// while the app was closed — with no error, no log line, and no later event that corrects it. Four
/// of the five SDKs shipped exactly that; this one avoided it only if the integrator noticed
/// `seed(_:)` and wired it up, which nothing forced them to do.
///
/// Every test here is about a failure that is otherwise **invisible**, which is why they assert on
/// what went out on the wire and what reached the store rather than on a return value.
///
/// 本组测试对应的是一个静默丢消息的缺陷：冷启动不上报已持有的 seq，就会采纳服务端最新 seq，
/// 关闭期间的消息永远不会被请求，也不会有任何报错。
@Suite("Cold start and cursors")
struct ColdStartTests {

    private static let conversationId = "s_alice_bob"

    // MARK: - Restoring

    @Test("a cold start reports the cursors the store held, rather than starting from nothing")
    func coldStartRestoresCursors() async throws {
        let store = RecordingCursorStore(convSeqs: ["c1": 100], conversationCursor: 1_700_000_000_000)
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the resume request") { !channel.requests(for: "conn.sync").isEmpty }

        let resume = try #require(channel.requests(for: "conn.sync").first)
        #expect(resume["convSeqs"]?["c1"]?.intValue == 100)
        #expect(resume["conversationCursor"]?.intValue == 1_700_000_000_000)
        #expect(store.loads == 1)

        await client.disconnect()
    }

    @Test("every snapshot the SDK writes carries (host, appId, userId)")
    func writesAreStampedWithTheScope() async throws {
        let store = RecordingCursorStore()
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(
            connector: gateway,
            userId: "bob",
            cursorStore: store.store
        ))

        try await client.connect()
        _ = await waitUntil("the resume request") { gateway.lastChannel != nil }

        await client.commit("c1", seq: 5)
        await client.enterBackground()
        _ = await waitUntil("the write") { !store.savedSnapshots.isEmpty }

        #expect(store.current.scope == "im.test|app-test|bob")

        await client.disconnect()
    }

    @Test("cursors belonging to another account are refused, not replayed")
    func foreignScopeIsRefused() async throws {
        // CONTRACT §5.3, the account-switch guarantee. Alice signed out, Bob signed in, and the app
        // pointed both at one store. Handing Bob Alice's position marks messages Bob has never seen
        // as already consumed — one person's cursors replaying into another person's client,
        // silently and permanently.
        //
        // The guarantee is structural: it comes from the identity the SDK stamped into the
        // snapshot, so a store that does nothing to keep two accounts apart cannot defeat it.
        let warnings = WarningLog()
        let store = RecordingCursorStore(
            convSeqs: ["c1": 100],
            conversationCursor: 1_700_000_000_000,
            scope: "im.test|app-test|alice"
        )

        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(
            connector: gateway,
            userId: "bob",
            cursorStore: store.store,
            warningHandler: warnings.handler
        ))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the resume request") { !channel.requests(for: "conn.sync").isEmpty }

        let resume = try #require(channel.requests(for: "conn.sync").first)
        #expect(resume["convSeqs"]?["c1"]?.intValue == nil, "Bob must not report Alice's position")
        #expect(resume["conversationCursor"]?.intValue ?? 0 == 0)
        #expect(await client.committedSeq(in: "c1") == 0)
        #expect(await client.didRejectForeignCursors)
        #expect(await client.isCursorStoreUsable, "another account's cursors are not a broken store")
        #expect(warnings.contains("im.test|app-test|alice"))

        await client.disconnect()
    }

    @Test("cursors stamped with this account are used as they always were")
    func matchingScopeIsRestored() async throws {
        let store = RecordingCursorStore(
            convSeqs: ["c1": 100],
            scope: "im.test|app-test|bob"
        )

        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(
            connector: gateway,
            userId: "bob",
            cursorStore: store.store
        ))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the resume request") { !channel.requests(for: "conn.sync").isEmpty }

        let resume = try #require(channel.requests(for: "conn.sync").first)
        #expect(resume["convSeqs"]?["c1"]?.intValue == 100)
        #expect(await client.didRejectForeignCursors == false)

        await client.disconnect()
    }

    @Test("an in-memory store says so, out loud, once")
    func coldStartWithoutStoreDoesNotSilentlyAdopt() async throws {
        let warnings = WarningLog()
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(
            connector: gateway,
            cursorStore: .inMemory(),
            warningHandler: warnings.handler
        ))

        let events = Collector(client.sessionEvents())
        try await client.connect()
        _ = await waitUntil("the warning") { events.items.contains(.cursorsNotPersisted) }

        #expect(warnings.contains("§5.3"))
        #expect(warnings.contains("not being persisted"))

        // And the application can see for itself that nothing was restored.
        #expect(await client.committedSeq(in: Self.conversationId) == 0)

        await client.disconnect()
    }

    @Test("a load failure is not a fresh install: nothing is adopted and nothing is written")
    func storeLoadFailureDoesNotAdopt() async throws {
        let warnings = WarningLog()
        let store = RecordingCursorStore(.empty, loadFailure: CursorStoreFailure(reason: "disk is on fire"))

        let gateway = MockGateway(responder: { request, channel in
            guard request.target == "conn.sync" else {
                _ = MockGateway.answerHousekeeping(request, channel)
                return
            }

            channel.reply(to: request, data: MockGateway.resumePage(
                conversations: [conversationPayload("c1", maxSeq: 500, updatedAt: 9_000)]
            ))
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            cursorStore: store.store,
            warningHandler: warnings.handler
        ))

        let events = Collector(client.sessionEvents())
        try await client.connect()
        await settle()

        // Adopting here would destroy history sitting intact in the application's own database:
        // a failed load and a fresh install are indistinguishable to the adoption branch, so the
        // only safe answer is to do nothing at all.
        #expect(await client.committedSeq(in: "c1") == 0)
        #expect(await client.highestSeq(in: "c1") == 0)
        #expect(store.savedSnapshots.isEmpty, "a store that could not be read must not be overwritten")
        #expect(await client.isCursorStoreUsable == false)

        let surfaced = events.items.contains {
            if case .cursorStoreUnavailable = $0 { return true }
            return false
        }
        #expect(surfaced, "the failure must reach the application, not just a log")
        #expect(warnings.contains("§5.8"))

        await client.disconnect()
    }

    // MARK: - Committing

    @Test("committed seq is what conn.sync reports, and it only ever moves forward")
    func commitDrivesConvSeqsAndIsMonotonic() async throws {
        let store = RecordingCursorStore()
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))

        await client.commit("c1", seq: 40)
        await client.commit("c1", seq: 12) // lower: ignored, not an error
        await client.commit("c1", seq: 41)

        #expect(await client.committedSeq(in: "c1") == 41)

        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the resume request") { !channel.requests(for: "conn.sync").isEmpty }

        let resume = try #require(channel.requests(for: "conn.sync").first)
        #expect(resume["convSeqs"]?["c1"]?.intValue == 41)

        await client.disconnect()
        #expect(store.current.convSeqs["c1"] == 41)
    }

    @Test("a message delivered but never committed is delivered again after a reconnect")
    func deliveredResetsToCommittedOnReconnect() async throws {
        let store = RecordingCursorStore(convSeqs: [Self.conversationId: 5])

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                let known = request["convSeqs"]?[Self.conversationId]?.intValue ?? 0
                channel.reply(to: request, data: MockGateway.resumePage(
                    conversations: [conversationPayload(Self.conversationId, maxSeq: 7, updatedAt: 100)],
                    gapsFrom: known > 0 ? [Self.conversationId: known + 1] : [:]
                ))

            case "msg.sync":
                guard let from = request["fromSeq"]?.intValue,
                      let to = request["toSeq"]?.intValue,
                      from <= to
                else { return }
                channel.reply(to: request, data: syncPayload(conversationId: Self.conversationId, range: from ... to))

            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()
        _ = await waitUntil("the first repair") { messages.count == 2 }

        // The application never committed 6 or 7 — it was handed them and then the process would
        // have crashed. Delivery is at-least-once precisely so that this is recoverable.
        let first = try #require(gateway.lastChannel)
        first.serverClose(code: 1006, reason: nil)

        _ = await waitUntil("a second socket") { gateway.attempts >= 2 }
        _ = await waitUntil("the redelivery") { messages.count == 4 }
        await settle()

        #expect(messages.items.map(\.seq) == [6, 7, 6, 7])
        #expect(await client.committedSeq(in: Self.conversationId) == 5)

        await client.disconnect()
    }

    // MARK: - Adoption

    @Test("an unknown conversation is adopted, and the write lands before the next page is asked for")
    func firstSightAdoptsAndPersistsSynchronously() async throws {
        let store = RecordingCursorStore()
        let observed = Holder<[String: Int64]>()

        let pager = ScriptedResponder(
            [
                .data(MockGateway.resumePage(
                    conversations: [conversationPayload("c1", maxSeq: 10, updatedAt: 100)],
                    nextCursor: "page-2",
                    hasMore: true
                )),
                .data(MockGateway.resumePage(
                    conversations: [conversationPayload("c2", maxSeq: 20, updatedAt: 90)]
                )),
            ],
            beforeReply: { index, _ in
                // The world as it is at the exact moment the SDK asks for page 2.
                if index == 1 { observed.set(store.current.convSeqs) }
            }
        )

        let gateway = MockGateway(responder: { request, channel in
            if request.target == "conn.sync" {
                pager.answer(request, channel)
                return
            }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        try await client.connect()
        _ = await waitUntil("both pages") { pager.served == 2 }
        await settle()

        // An adoption write that is merely queued is an adoption write that a crash loses — and the
        // next cold start then sees no entry, adopts a *newer* maxSeq, and silently drops
        // everything in between. That is the original bug, re-created by the optimisation.
        let atPageTwo = try #require(observed.take())
        #expect(atPageTwo["c1"] == 10, "c1's adoption must be in the store before page 2 goes out")

        #expect(await client.committedSeq(in: "c1") == 10)
        #expect(await client.committedSeq(in: "c2") == 20)

        await client.disconnect()
    }

    // MARK: - Paging the resume

    @Test("a three-page conn.sync repairs gaps from all three pages")
    func resumePagesUntilHasMoreFalse() async throws {
        let store = RecordingCursorStore(convSeqs: ["c1": 1, "c2": 1, "c3": 1])

        let pager = ScriptedResponder([
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c1", maxSeq: 3, updatedAt: 300)],
                gapsFrom: ["c1": 2],
                nextCursor: "page-2",
                hasMore: true
            )),
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c2", maxSeq: 3, updatedAt: 200)],
                gapsFrom: ["c2": 2],
                nextCursor: "page-3",
                hasMore: true
            )),
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c3", maxSeq: 3, updatedAt: 100)],
                gapsFrom: ["c3": 2]
            )),
        ])

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                pager.answer(request, channel)
            case "msg.sync":
                guard let conversationId = request["conversationId"]?.stringValue,
                      let from = request["fromSeq"]?.intValue,
                      let to = request["toSeq"]?.intValue,
                      from <= to
                else { return }
                channel.reply(to: request, data: syncPayload(conversationId: conversationId, range: from ... to))
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // `conn.sync` returns at most 200 conversations per page. A client that reads page 1 and
        // stops repairs the first page's gaps and leaves every later one open forever.
        _ = await waitUntil("all three pages") { pager.served == 3 }
        _ = await waitUntil("all three repairs") { channel.requests(for: "msg.sync").count == 3 }
        await settle()

        let repaired = Set(channel.requests(for: "msg.sync").compactMap { $0["conversationId"]?.stringValue })
        #expect(repaired == ["c1", "c2", "c3"])
        #expect(Set(messages.items.map(\.conversationId)) == ["c1", "c2", "c3"])

        await client.disconnect()
    }

    @Test("a page shorter than the limit does not end the run")
    func pageWithFewerItemsThanLimitStillPages() async throws {
        let store = RecordingCursorStore()

        // `ConversationService.ListAsync` computes the paging cursor from the raw page *before*
        // deleted conversations are filtered out, so a page can legitimately return one row while
        // `hasMore` is true. Stopping on a short page is how the rest is skipped permanently.
        let pager = ScriptedResponder([
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c1", maxSeq: 5, updatedAt: 500)],
                nextCursor: "page-2",
                hasMore: true
            )),
            .data(MockGateway.resumePage(conversations: [])),
        ])

        let gateway = MockGateway(responder: { request, channel in
            if request.target == "conn.sync" {
                pager.answer(request, channel)
                return
            }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        try await client.connect()

        _ = await waitUntil("the second page") { pager.served == 2 }
        await settle()

        #expect(pager.served == 2)

        await client.disconnect()
    }

    @Test("an interrupted run leaves conversationCursor exactly where it was")
    func conversationCursorAdvancesOnlyAfterFullRun() async throws {
        let store = RecordingCursorStore()

        let pager = ScriptedResponder([
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c1", maxSeq: 5, updatedAt: 9_999)],
                nextCursor: "page-2",
                hasMore: true
            )),
            .failure(.internalError, "the node went away mid-run"),
        ])

        let gateway = MockGateway(responder: { request, channel in
            if request.target == "conn.sync" {
                pager.answer(request, channel)
                return
            }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        try await client.connect()

        _ = await waitUntil("both attempts") { pager.served == 2 }
        await settle()

        // The list is sorted by `updatedAt` descending, so page 1 holds the newest timestamp.
        // Taking it and stopping would push the cursor past every conversation on pages 2…N, and
        // `ListUserConversationsAsync` filters on `UpdatedAt > updatedAfter` — the server would
        // never return them again. Re-reading a page is free; skipping one is permanent.
        #expect(await client.cursorSnapshot().conversationCursor == 0)
        #expect(store.savedSnapshots.allSatisfy { $0.conversationCursor == 0 })

        // The adoption from page 1 still stands: that one is a commit, not a run outcome.
        #expect(await client.committedSeq(in: "c1") == 5)

        await client.disconnect()
    }

    @Test("a completed run advances conversationCursor to the newest updatedAt across all pages")
    func conversationCursorTakesTheMaximumOfTheWholeRun() async throws {
        let store = RecordingCursorStore()

        let pager = ScriptedResponder([
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c1", maxSeq: 5, updatedAt: 9_999)],
                nextCursor: "page-2",
                hasMore: true
            )),
            .data(MockGateway.resumePage(
                conversations: [conversationPayload("c2", maxSeq: 5, updatedAt: 4_000)]
            )),
        ])

        let gateway = MockGateway(responder: { request, channel in
            if request.target == "conn.sync" {
                pager.answer(request, channel)
                return
            }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        try await client.connect()

        _ = await waitUntil("both pages") { pager.served == 2 }
        _ = await waitUntil("the cursor to settle") { await client.cursorSnapshot().conversationCursor == 9_999 }

        #expect(await client.cursorSnapshot().conversationCursor == 9_999)
        #expect(store.current.conversationCursor == 9_999)

        await client.disconnect()
    }

    // MARK: - Paging the repair

    @Test("a repair spanning three msg.sync pages delivers all three")
    func repairPagesUntilSyncHasMoreFalse() async throws {
        // No gap entry from the server on purpose: `ConnController.Sync` only emits one when the
        // client reported a non-zero seq, so a conversation held at 0 produces none at all. The
        // client has to work the range out from its own committed cursor.
        let store = RecordingCursorStore(convSeqs: ["c1": 0])

        let syncPages = ScriptedResponder([
            .data(pagedSyncPayload(conversationId: "c1", range: 1 ... 10, maxSeq: 30, hasMore: true)),
            .data(pagedSyncPayload(conversationId: "c1", range: 11 ... 20, maxSeq: 30, hasMore: true)),
            .data(pagedSyncPayload(conversationId: "c1", range: 21 ... 30, maxSeq: 30, hasMore: false)),
        ])

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                channel.reply(to: request, data: MockGateway.resumePage(
                    conversations: [conversationPayload("c1", maxSeq: 30, updatedAt: 10)]
                ))
            case "msg.sync":
                syncPages.answer(request, channel)
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()

        // `MessageService.SyncAsync` clamps `limit` to 500 and reports `hasMore`. An SDK that
        // ignores `hasMore` leaves the rest of the range as a permanent hole — the exact failure the
        // repair existed to prevent.
        _ = await waitUntil("all thirty messages") { messages.count == 30 }
        await settle()

        #expect(syncPages.served == 3)
        #expect(messages.items.map(\.seq) == Array(Int64(1) ... 30))
        #expect(await client.highestSeq(in: "c1") == 30)

        await client.disconnect()
    }

    @Test("a msg.sync page shorter than its limit does not end the repair")
    func repairPagesWhenPageIsShorterThanLimit() async throws {
        let store = RecordingCursorStore(convSeqs: ["c1": 0])

        // `hasMore` is computed on the raw window, before per-user hidden messages are filtered
        // out, so an empty page with `hasMore: true` is a legal answer and must not end the loop.
        let syncPages = ScriptedResponder([
            .data(pagedSyncPayload(conversationId: "c1", range: nil, maxSeq: 5, hasMore: true)),
            .data(pagedSyncPayload(conversationId: "c1", range: 6 ... 10, maxSeq: 10, hasMore: false)),
        ])

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                channel.reply(to: request, data: MockGateway.resumePage(
                    conversations: [conversationPayload("c1", maxSeq: 10, updatedAt: 10)]
                ))
            case "msg.sync":
                syncPages.answer(request, channel)
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()
        _ = await waitUntil("the second page's messages") { messages.count == 5 }
        await settle()

        #expect(syncPages.served == 2)
        #expect(messages.items.map(\.seq) == [6, 7, 8, 9, 10])

        await client.disconnect()
    }

    // MARK: - Oversized spans

    @Test("an oversized gap found on resume moves the cursor and raises a reload")
    func oversizedGapAdvancesCursorAndRaisesReload() async throws {
        let store = RecordingCursorStore(convSeqs: ["c1": 1])

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                channel.reply(to: request, data: MockGateway.resumePage(
                    conversations: [conversationPayload("c1", maxSeq: 500, updatedAt: 10)],
                    gapsFrom: ["c1": 2]
                ))
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            maxAutoRepairSeq: 10,
            cursorStore: store.store
        ))

        let events = Collector(client.sessionEvents())
        try await client.connect()

        _ = await waitUntil("the reload event") {
            events.items.contains(.conversationNeedsReload(conversationId: "c1", fromSeq: 2, toSeq: 500))
        }
        await settle()

        let channel = try #require(gateway.lastChannel)
        #expect(channel.requests(for: "msg.sync").isEmpty)

        // Both halves are mandatory: without the cursor advance every later message looks like a
        // gap and re-requests a range already declined; without the event the UI has a hole nobody
        // will ever mention.
        #expect(await client.committedSeq(in: "c1") == 500)
        #expect(await client.highestSeq(in: "c1") == 500)
        #expect(store.current.convSeqs["c1"] == 500)

        await client.disconnect()
    }

    @Test("an oversized gap found on the live path raises a reload too")
    func oversizedLiveGapRaisesReload() async throws {
        let store = RecordingCursorStore()
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(
            connector: gateway,
            maxAutoRepairSeq: 10,
            cursorStore: store.store
        ))

        let messages = Collector(client.messages())
        let events = Collector(client.sessionEvents())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 1))
        _ = await waitUntil("the first message") { messages.count == 1 }

        channel.event(.message, data: messagePayload(conversationId: "c1", seq: 1_000))
        _ = await waitUntil("the newest message") { messages.count == 2 }

        // The cursor stayed honest on this path before, but the application was never told a
        // stretch had been skipped — and a hole nobody is told about is the same defect as a hole
        // nobody repairs.
        _ = await waitUntil("the reload event") {
            events.items.contains(.conversationNeedsReload(conversationId: "c1", fromSeq: 2, toSeq: 999))
        }

        #expect(channel.requests(for: "msg.sync").isEmpty)
        #expect(await client.committedSeq(in: "c1") == 999)
        #expect(await client.highestSeq(in: "c1") == 1_000)

        await client.disconnect()
    }

    // MARK: - seq 0

    @Test("a chat-room message leaves both cursors alone")
    func seqZeroNeverMovesCursor() async throws {
        let store = RecordingCursorStore()
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        channel.event(.message, data: messagePayload(conversationId: "room_1", seq: 0))
        channel.event(.message, data: messagePayload(conversationId: "room_1", seq: 0))
        _ = await waitUntil("both online-only messages") { messages.count == 2 }
        await settle()

        #expect(await client.highestSeq(in: "room_1") == 0)
        #expect(await client.committedSeq(in: "room_1") == 0)
        #expect(store.savedSnapshots.allSatisfy { $0.convSeqs["room_1"] == nil })

        await client.disconnect()
    }

    // MARK: - Recovery

    @Test("re-derived cursors plus resync repair what a failed load could not")
    func resyncAfterStoreFailureRepairsTheGap() async throws {
        let store = RecordingCursorStore(.empty, loadFailure: CursorStoreFailure(reason: "unreadable"))

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.sync":
                let known = request["convSeqs"]?["c1"]?.intValue ?? 0
                channel.reply(to: request, data: MockGateway.resumePage(
                    conversations: [conversationPayload("c1", maxSeq: 8, updatedAt: 10)],
                    gapsFrom: known > 0 ? ["c1": known + 1] : [:]
                ))
            case "msg.sync":
                guard let from = request["fromSeq"]?.intValue,
                      let to = request["toSeq"]?.intValue,
                      from <= to
                else { return }
                channel.reply(to: request, data: syncPayload(conversationId: "c1", range: from ... to))
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: store.store))
        let messages = Collector(client.messages())

        try await client.connect()
        await settle()
        #expect(messages.count == 0, "nothing may be adopted or repaired while the store is unreadable")

        // This is the documented recovery: the application knows what it holds, says so, and asks
        // for the pass that the failed load made impossible. `commit` is monotonic exactly so that
        // re-deriving in any order is safe.
        await client.commit("c1", seq: 5)
        await client.resync()

        _ = await waitUntil("the repaired range") { messages.count == 3 }
        #expect(messages.items.map(\.seq) == [6, 7, 8])

        await client.disconnect()
    }
}

/// A `msg.sync` reply that can be short, empty, or claim there is more.
///
/// `syncPayload` in the shared helpers always answers exactly what was asked for; this one exists to
/// reproduce the server's real behaviour, where `hasMore` is computed on the raw window before
/// per-user hidden messages are filtered out.
func pagedSyncPayload(
    conversationId: String,
    range: ClosedRange<Int64>?,
    maxSeq: Int64,
    hasMore: Bool
) -> JSONValue {
    .object([
        "conversationId": .string(conversationId),
        "messages": .array((range.map(Array.init) ?? []).map {
            messagePayload(conversationId: conversationId, seq: $0)
        }),
        "maxSeq": .int(maxSeq),
        "minSeq": .int(1),
        "hasMore": .bool(hasMore),
    ])
}
