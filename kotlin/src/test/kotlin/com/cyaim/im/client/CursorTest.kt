@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/**
 * CONTRACT.md §5, the cold-start cursor rule.
 *
 * These are not tests of a feature. They are tests of a **silent data-loss bug**: a client that
 * starts with no cursors reports nothing in `convSeqs`, the server therefore reports no gaps —
 * `ConnController.Sync` only produces a gap for a conversation the client reported a non-zero seq
 * for — and the client then adopts the server's current `maxSeq`. Everything that arrived while
 * the app was closed is behind the cursor, will never be requested and will never arrive. No
 * error, no log line, nothing later that corrects it.
 *
 * The first test in this file is the one that fails against the SDK as it shipped.
 *
 * 这些不是功能测试，而是针对一个静默丢数据缺陷的测试：冷启动没有游标 → 不上报 convSeqs →
 * 服务端不报缺口 → 客户端采纳服务端的 maxSeq → 关机期间到达的消息全部永久丢失，且无任何报错。
 */
class CursorTest {

    // ------------------------------------------------------------------- 1. cold start

    /**
     * `coldStartRestoresCursors`.
     *
     * The defect, in one assertion. Before the cursor store existed, `cursors` was a private
     * `ConcurrentHashMap` with no accessor of any kind: nothing could put a seq into it before the
     * first `conn.sync`, so `convSeqs` on a fresh process was always `{}`.
     */
    @Test
    fun `a cold start reports the cursors it persisted, not an empty map`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 100L, "c2" to 7L)))
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        val sync = gateway.latest.requestsTo("conn.sync").single()
        assertEquals(mapOf("c1" to 100L, "c2" to 7L), sync.bodySeqMap("convSeqs"))
    }

    /**
     * The bug itself, end to end, against a `conn.sync` that computes its gaps exactly the way
     * `ConnController.Sync` does:
     *
     * ```csharp
     * var known = request.ConvSeqs?.GetValueOrDefault(view.ConversationId) ?? 0;
     * if (known > 0 && view.MaxSeq > known) gaps[view.ConversationId] = known + 1;
     * ```
     *
     * Report the cursor and you are told about the five messages that arrived while the app was
     * closed. Report nothing — which is what a client with no cursor store does, and what four of
     * the five SDKs did — and the server reports **no gap at all**, the client adopts `maxSeq`, and
     * those five messages are behind the cursor forever. No error, no log line, no later event.
     *
     * Break `CursorBook.restore` and this test fails with `expected 5 messages, got 0`, which is
     * the failure a customer experiences as "messages sent overnight never arrived".
     */
    @Test
    fun `a cold start asks for the gap instead of re-baselining onto the server maxSeq`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> {
                    // The server's own gap arithmetic, transcribed.
                    val known = request.bodySeqMap("convSeqs")["c1"] ?: 0L
                    val gaps = if (known > 0 && SERVER_MAX_SEQ > known) mapOf("c1" to known + 1) else emptyMap()
                    resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = SERVER_MAX_SEQ)),
                        gaps = gaps,
                    )
                }
                "msg.sync" -> syncPage(
                    request,
                    "c1",
                    (request.bodyLong("fromSeq")..request.bodyLong("toSeq")).toList(),
                )
                else -> null
            }
        }

        // Last night the app was closed at seq 100. Five messages arrived since.
        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 100L)))
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        assertEquals(
            listOf(101L, 102L, 103L, 104L, 105L),
            received.map { it.seq },
            "expected the 5 messages that arrived while the app was closed",
        )

        val repair = gateway.latest.requestsTo("msg.sync").single()
        assertEquals(101L, repair.bodyLong("fromSeq"))
        assertEquals(105L, repair.bodyLong("toSeq"))
    }

    /**
     * `coldStartWithoutStoreDoesNotSilentlyAdopt`.
     *
     * Passing `inMemory()` is legitimate. Passing it without knowing what it costs is not, so it
     * says so once, and the state is observable rather than only logged.
     */
    @Test
    fun `the in-memory store warns once and says it restored nothing`() = runTest {
        val gateway = syncingGateway()
        val logger = RecordingLogger()
        val client = newClient(
            gateway,
            store = ImCursorStore.inMemory(),
            options = testOptions(logger = logger),
        )
        openClient(client, gateway)

        val state = assertIs<ImCursorStoreState.Loaded>(client.cursorStoreState.value)
        assertEquals(0, state.conversations)
        assertTrue(!state.persistent, "an in-memory store must not claim to be persistent")

        val warnings = logger.atLeast(ImLogLevel.Warn)
        assertEquals(1, warnings.count { it.contains("inMemory") }, "exactly one warning: $warnings")
        assertTrue(warnings.any { it.contains("§5.3") })
    }

    /**
     * `firstSightAdoptsAndPersistsSynchronously`.
     *
     * The adoption write is the one that may never be debounced. If it is lost, the next cold
     * start sees no entry, adopts a *newer* `maxSeq`, and silently drops everything in between —
     * the original bug, re-created by the optimisation.
     */
    @Test
    fun `an adoption is on disk before the next conn dot sync page is asked for`() = runTest {
        val events = mutableListOf<String>()
        val store = object : ImCursorStore {
            override fun load(): ImCursorSnapshot = ImCursorSnapshot()
            override fun save(snapshot: ImCursorSnapshot) {
                events += "save(${snapshot.convSeqs.toSortedMap()})"
            }
        }

        val gateway = FakeGateway()
        var page = 0
        gateway.onRequest = { request ->
            if (request.target != "conn.sync") {
                null
            } else {
                events += "conn.sync#${++page}"
                when (page) {
                    1 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 40, updatedAt = 100)),
                        hasMore = true,
                        nextCursor = "p2",
                    )
                    else -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c2", maxSeq = 9, updatedAt = 90)),
                    )
                }
            }
        }

        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        val firstSave = events.indexOfFirst { it.startsWith("save(") && it.contains("c1=40") }
        val secondPage = events.indexOf("conn.sync#2")
        assertTrue(firstSave >= 0, "the adoption was never written: $events")
        assertTrue(secondPage >= 0, "the run never paged: $events")
        assertTrue(firstSave < secondPage, "adoption must be durable before the next page: $events")
    }

    // ---------------------------------------------------------------------- 4-6. paging

    /**
     * `resumePagesUntilHasMoreFalse`.
     *
     * `conn.sync` returns at most 200 conversations. A client that reads page one and stops
     * repairs the first 200 conversations and abandons the rest — for a heavy user, permanently.
     */
    @Test
    fun `a three-page resume repairs gaps reported on all three pages`() = runTest {
        val gateway = FakeGateway()
        var page = 0
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> when (++page) {
                    1 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 6, updatedAt = 300)),
                        gaps = mapOf("c1" to 6L),
                        hasMore = true,
                        nextCursor = "p2",
                    )
                    2 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c2", maxSeq = 6, updatedAt = 200)),
                        gaps = mapOf("c2" to 6L),
                        hasMore = true,
                        nextCursor = "p3",
                    )
                    else -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c3", maxSeq = 6, updatedAt = 100)),
                        gaps = mapOf("c3" to 6L),
                    )
                }
                "msg.sync" -> {
                    val conversationId = request.bodyString("conversationId")
                    syncPage(request, conversationId, listOf(6L))
                }
                else -> null
            }
        }

        val store = RecordingCursorStore(
            ImCursorSnapshot(convSeqs = mapOf("c1" to 5L, "c2" to 5L, "c3" to 5L)),
        )
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        assertEquals(3, gateway.latest.requestsTo("conn.sync").size, "it must page")
        assertEquals(
            listOf("c1", "c2", "c3"),
            gateway.latest.requestsTo("msg.sync").map { it.bodyString("conversationId") }.sorted(),
        )
        assertEquals(setOf("c1", "c2", "c3"), received.map { it.conversationId }.toSet())

        // Page two and three carry the cursor page one handed back.
        assertEquals(null, gateway.latest.requestsTo("conn.sync")[0].bodyStringOrNull("cursor"))
        assertEquals("p2", gateway.latest.requestsTo("conn.sync")[1].bodyStringOrNull("cursor"))
        assertEquals("p3", gateway.latest.requestsTo("conn.sync")[2].bodyStringOrNull("cursor"))
    }

    /**
     * `conversationCursorAdvancesOnlyAfterFullRun`.
     *
     * The list is sorted by `updatedAt` **descending**, so page one holds the newest timestamp. A
     * client that takes the maximum from page one and stops has pushed `conversationCursor` past
     * every conversation on pages 2…N, and `ListUserConversationsAsync` filters on
     * `UpdatedAt > updatedAfter` — the server will never mention them again.
     */
    @Test
    fun `an interrupted resume leaves conversationCursor exactly where it was`() = runTest {
        val gateway = FakeGateway()
        var page = 0
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> when (++page) {
                    1 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 3, updatedAt = 9_000)),
                        hasMore = true,
                        nextCursor = "p2",
                    )
                    // Page two dies. The run never completed, so nothing about it may be believed.
                    2 -> replyTo(request, JsonObject(emptyMap()), code = ImErrorCode.InternalError)
                    else -> resumePage(request)
                }
                else -> null
            }
        }

        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        assertEquals(2, gateway.latest.requestsTo("conn.sync").size)
        assertEquals(
            0L,
            store.held.conversationCursor,
            "9000 came off a page-one that was never followed by a completed run",
        )

        // Reconnect: the third page-one request must still ask from the beginning of time.
        gateway.latest.networkFailure()
        runCurrent()
        advanceTimeBy(2.seconds)
        runCurrent()
        gateway.latest.opened()
        runCurrent()

        assertEquals(0L, gateway.latest.requestsTo("conn.sync").first().bodyLong("conversationCursor"))
    }

    @Test
    fun `a completed run does advance conversationCursor, to the maximum across every page`() = runTest {
        val gateway = FakeGateway()
        var page = 0
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> when (++page) {
                    1 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 3, updatedAt = 9_000)),
                        hasMore = true,
                        nextCursor = "p2",
                    )
                    else -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c2", maxSeq = 3, updatedAt = 8_000)),
                    )
                }
                else -> null
            }
        }

        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        assertEquals(9_000L, store.held.conversationCursor)
    }

    /**
     * `pageWithFewerItemsThanLimitStillPages`.
     *
     * `ConversationService.ListAsync` computes its cursor on the raw page, *before* deleted
     * conversations are filtered out, so a page can hold fewer items than the limit while
     * `hasMore` is true. Stopping on a short page is the intuitive bug.
     */
    @Test
    fun `a page shorter than the limit does not end the run`() = runTest {
        val gateway = FakeGateway()
        var page = 0
        gateway.onRequest = { request ->
            if (request.target != "conn.sync") {
                null
            } else {
                when (++page) {
                    // One item against a limit of 200, and still more to come.
                    1 -> resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 1)),
                        hasMore = true,
                        nextCursor = "p2",
                    )
                    else -> resumePage(request)
                }
            }
        }

        val client = newClient(gateway)
        openClient(client, gateway)

        assertEquals(200, gateway.latest.requestsTo("conn.sync").first().bodyLong("limit").toInt())
        assertEquals(2, gateway.latest.requestsTo("conn.sync").size, "1 < 200 is not a reason to stop")
    }

    // ---------------------------------------------------------- 7. delivered vs committed

    /**
     * `deliveredResetsToCommittedOnReconnect`.
     *
     * Without the reset the repaired messages are dropped as duplicates by the very cursor that
     * was too far ahead: the repair runs, the server sends the messages, and the application sees
     * nothing at all — the worst possible shape for a bug, because every log says it worked.
     */
    @Test
    fun `a message delivered but never committed is delivered again after a reconnect`() = runTest {
        val gateway = FakeGateway()
        var syncs = 0
        gateway.onRequest = { request ->
            when (request.target) {
                // The first connect knows of no gap; the reconnect does, because the message the
                // application never committed is still missing as far as the server can tell.
                "conn.sync" -> if (++syncs == 1) {
                    resumePage(request)
                } else {
                    resumePage(
                        request,
                        conversations = listOf(conversationJson("c1", maxSeq = 6)),
                        gaps = mapOf("c1" to 6L),
                    )
                }
                "msg.sync" -> syncPage(request, "c1", listOf(6L))
                else -> null
            }
        }

        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 5L)))
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        // Arrives live, reaches the application, and is never committed — the app crashed, or was
        // killed, or simply had not finished its own write.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 6))
        runCurrent()
        assertEquals(listOf(6L), received.map { it.seq })
        assertEquals(5L, store.held.convSeqs["c1"], "delivery is not durability")

        gateway.latest.networkFailure()
        runCurrent()
        advanceTimeBy(2.seconds)
        runCurrent()
        gateway.latest.opened()
        runCurrent()

        assertEquals(listOf(6L, 6L), received.map { it.seq }, "seq 6 was never durable, so it comes back")

        // And once the application does commit, it stops coming back.
        client.commit("c1", 6)
        runCurrent()
        assertEquals(6L, store.held.convSeqs["c1"])
    }

    @Test
    fun `commit is monotonic and a lower seq is ignored rather than an error`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        client.commit("c1", 10)
        client.commit("c1", 4)
        client.commit("c1", 12)
        runCurrent()

        assertEquals(12L, store.held.convSeqs["c1"])
        assertEquals(12L, client.committedSeq("c1"))
    }

    // ------------------------------------------------------------- 8, 13. oversized gaps

    /**
     * `oversizedGapAdvancesCursorAndRaisesReload`, on the resume path.
     *
     * Both halves are mandatory. Skipping the cursor advance makes every later message look like a
     * gap and re-request a range we have already declined; skipping the event leaves a hole in the
     * UI that nothing will ever mention.
     */
    @Test
    fun `a resume gap over maxAutoRepairSeq moves the cursor and asks for a reload`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(
                    request,
                    conversations = listOf(conversationJson("c1", maxSeq = 5_000)),
                    gaps = mapOf("c1" to 2L),
                )
                else -> null
            }
        }

        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 1L)))
        val client = newClient(gateway, maxAutoRepairSeq = 3, store = store)
        val reloads = collectReloads(client)
        openClient(client, gateway)

        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty(), "4999 messages is not a backfill")
        assertEquals(listOf("c1"), reloads)
        assertEquals(5_000L, store.held.convSeqs["c1"], "the cursor must not be left behind the hole")
    }

    /**
     * `oversizedLiveGapRaisesReload`: the live path takes the identical treatment, because a hole
     * nobody is told about is the same defect as a hole nobody repairs.
     */
    @Test
    fun `a live gap over maxAutoRepairSeq also asks for a reload`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 1L)))
        val client = newClient(gateway, maxAutoRepairSeq = 3, store = store)
        val reloads = collectReloads(client)
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 900))
        runCurrent()

        assertEquals(listOf("c1"), reloads)
        assertEquals(listOf(900L), received.map { it.seq })
        assertEquals(899L, store.held.convSeqs["c1"], "the declined range is behind the committed cursor")
    }

    // ----------------------------------------------------------------------- 9. seq zero

    @Test
    fun `a chat-room message leaves both cursors alone`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("room-1" to 0L)))
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        val before = store.saves.size
        repeat(3) { gateway.latest.push(PushTarget.Message, messageJson("room-1", 0)) }
        runCurrent()

        assertEquals(3, received.size, "seq 0 traffic is delivered, every time, never deduplicated")
        assertEquals(before, store.saves.size, "and it never touches the store")
        assertEquals(0L, client.committedSeq("room-1"))
    }

    // ------------------------------------------------------------- 10. store load failure

    /**
     * `storeLoadFailureDoesNotAdopt`.
     *
     * A failed load and a fresh install are indistinguishable to the adoption branch. Adopting on
     * a failed load destroys history that is sitting intact in the application's own database, so
     * the SDK refuses to adopt or advance anything and says so.
     */
    @Test
    fun `a throwing load surfaces an error and adopts nothing`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            if (request.target == "conn.sync") {
                resumePage(request, conversations = listOf(conversationJson("c1", maxSeq = 900, updatedAt = 55)))
            } else {
                null
            }
        }

        val store = RecordingCursorStore(loadFailure = IOException("disk is on fire"))
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        val state = assertIs<ImCursorStoreState.Failed>(client.cursorStoreState.value)
        assertEquals("disk is on fire", state.cause.message)
        assertTrue(store.saves.isEmpty(), "nothing may be written on top of a store we could not read")

        // The session still works — it is the cursors that are frozen, not the socket.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 901))
        runCurrent()
        assertEquals(listOf(901L), received.map { it.seq })

        // And the application's own recovery path is open: commit() is monotonic, so re-deriving
        // cursors from its own database is the correct fix. It is refused only while frozen.
        client.commit("c1", 901)
        runCurrent()
        assertTrue(store.saves.isEmpty())
    }

    // -------------------------------------------------------------- 11-12. msg.sync pages

    /**
     * `repairPagesUntilSyncHasMoreFalse`.
     *
     * `MessageService.SyncAsync` clamps the limit to 500 and reports `hasMore`. A 1200-seq range
     * asked for in one call silently returns 500, and an SDK that ignores `hasMore` leaves the
     * other 700 as a permanent hole — the exact failure the repair was for.
     */
    @Test
    fun `a repair spanning three msg dot sync pages delivers all three`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.sync" -> {
                    val from = request.bodyLong("fromSeq")
                    val count = minOf(request.bodyLong("limit"), 500L)
                    val seqs = (from until from + count).toList()
                    syncPage(request, "c1", seqs, hasMore = seqs.last() < 1_200L, maxSeq = 1_200)
                }
                else -> null
            }
        }

        val store = RecordingCursorStore(ImCursorSnapshot(convSeqs = mapOf("c1" to 0L)))
        val client = newClient(gateway, maxAutoRepairSeq = 2_000, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        // A live seq 1201 with a local cursor of 0 would not gap-detect (delivered == 0), so drive
        // it the way a resume does: seq 1 first, then the jump.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 1_201))
        runCurrent()

        val calls = gateway.latest.requestsTo("msg.sync")
        assertEquals(3, calls.size, "500 + 500 + 200")
        assertContentEquals(listOf(2L, 502L, 1_002L), calls.map { it.bodyLong("fromSeq") })
        assertContentEquals(listOf(500L, 500L, 199L), calls.map { it.bodyLong("limit") })
        assertEquals(1_201, received.size)
        assertEquals((1L..1_201L).toList(), received.map { it.seq })
    }

    /**
     * `repairPagesWhenPageIsShorterThanLimit`.
     *
     * `hasMore` is computed on the raw window before per-user hidden messages are filtered out, so
     * a page can be short — even empty — while more of the range remains. Looping on
     * `messages.size` ends the repair early and leaves the hole.
     */
    @Test
    fun `a short msg dot sync page does not end the repair`() = runTest {
        val gateway = FakeGateway()
        var call = 0
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.sync" -> when (++call) {
                    // Two of ten, because eight were deleted for this reader. Still hasMore.
                    1 -> syncPage(request, "c1", listOf(2L, 3L), hasMore = true, maxSeq = 11)
                    else -> syncPage(request, "c1", listOf(9L, 10L), hasMore = false, maxSeq = 11)
                }
                else -> null
            }
        }

        val client = newClient(gateway, store = RecordingCursorStore(ImCursorSnapshot(mapOf("c1" to 1L))))
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 11))
        runCurrent()

        assertEquals(2, gateway.latest.requestsTo("msg.sync").size)
        assertEquals(listOf(2L, 4L), gateway.latest.requestsTo("msg.sync").map { it.bodyLong("fromSeq") })
        assertEquals(listOf(2L, 3L, 9L, 10L, 11L), received.map { it.seq })
    }

    // ------------------------------------------------------------------------- scoping

    /**
     * The scope key is `(endpoint host, appId, userId)`. Two accounts sharing one file is a
     * mistake, but it must not be a silent one that hands one user another's cursors.
     */
    @Test
    fun `a snapshot belonging to another account is not adopted`() = runTest {
        val gateway = syncingGateway()
        val logger = RecordingLogger()
        val store = RecordingCursorStore(
            ImCursorSnapshot(convSeqs = mapOf("c1" to 100L), scope = "im.example.com|app-1|bob"),
        )
        val client = newClient(gateway, store = store, options = testOptions(logger = logger))
        openClient(client, gateway)

        assertEquals(
            emptyMap(),
            gateway.latest.requestsTo("conn.sync").single().bodySeqMap("convSeqs"),
            "alice must not inherit bob's cursors",
        )
        assertTrue(logger.atLeast(ImLogLevel.Warn).any { it.contains("bob") })
    }

    @Test
    fun `what is written carries this session's scope`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        client.commit("c1", 3)
        runCurrent()

        assertEquals("im.example.com|app-1|alice", store.held.scope)
    }

    // ------------------------------------------------------------------------- debounce

    @Test
    fun `ordinary commits are coalesced but an adoption is not`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            if (request.target == "conn.sync") {
                resumePage(request, conversations = listOf(conversationJson("c1", maxSeq = 12)))
            } else {
                null
            }
        }

        val store = RecordingCursorStore()
        val client = newClient(
            gateway,
            store = store,
            options = testOptions().copy(cursorFlushInterval = 1.seconds),
        )
        openClient(client, gateway)

        // The adoption ignored the debounce window entirely.
        assertEquals(1, store.saves.size)
        assertEquals(12L, store.held.convSeqs["c1"])

        client.commit("c1", 13)
        client.commit("c1", 14)
        runCurrent()
        assertEquals(1, store.saves.size, "ordinary commits wait for the window")

        advanceTimeBy(1.seconds + 1.seconds)
        runCurrent()
        assertEquals(2, store.saves.size, "and then coalesce into one write")
        assertEquals(14L, store.held.convSeqs["c1"])
    }

    @Test
    fun `close flushes whatever the debounce window still held`() = runTest {
        val gateway = syncingGateway()
        val store = RecordingCursorStore()
        val client = newClient(
            gateway,
            store = store,
            options = testOptions().copy(cursorFlushInterval = 60.seconds),
        )
        openClient(client, gateway)

        client.commit("c1", 21)
        runCurrent()
        assertTrue(store.saves.isEmpty())

        client.close()

        assertEquals(21L, store.held.convSeqs["c1"], "logout is the one path whose next act is a cold start")
    }

    // -------------------------------------------------------------------------- helpers

    private companion object {
        /** Where the conversation stands on the server: five messages past the client's cursor. */
        const val SERVER_MAX_SEQ = 105L
    }

    /** A gateway that answers `conn.sync` with an empty completed run and nothing else. */
    private fun syncingGateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request -> if (request.target == "conn.sync") resumePage(request) else null }
    }
}
