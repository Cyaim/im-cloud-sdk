package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration

/**
 * The two cursors, per conversation, and the invariants between them (CONTRACT.md §5.2).
 *
 * - **`delivered`** — the highest seq handed to the application *in this process*. Memory only.
 *   Gap detection and duplicate suppression both read it.
 * - **`committed`** — the highest seq the application has told us it has **durably stored**.
 *   Written through to the [ImCursorStore]. This is the value reported in `convSeqs`.
 *
 * Three rules hold at all times:
 *
 * 1. `committed <= delivered`.
 * 2. On every connect and reconnect, before `conn.sync`, `delivered := committed`
 *    ([resetDeliveredToCommitted]). Without that reset the redelivered messages are dropped as
 *    duplicates by the very cursor that was too far ahead — the repair runs and delivers nothing.
 * 3. `convSeqs` is built from `committed`, never from `delivered`.
 *
 * Delivery is therefore at-least-once and the application must be idempotent on `messageId`.
 *
 * 两个游标：delivered 是本进程投递到应用的最高 seq（仅内存），committed 是应用声明"已落库"的
 * 最高 seq（持久化，且是上报给 conn.sync 的那个）。每次连接前必须把 delivered 复位到 committed，
 * 否则补拉回来的消息会被那个跑得太前的游标当成重复丢掉。
 *
 * Every method is safe from any thread: the maps are concurrent and each conversation is only ever
 * mutated from its own inbox coroutine, so the only cross-thread reads are the snapshot ones.
 */
internal class CursorBook {

    private val committed = ConcurrentHashMap<String, Long>()
    private val delivered = ConcurrentHashMap<String, Long>()

    @Volatile
    var conversationCursor: Long = 0
        private set

    /**
     * Set when [ImCursorStore.load] failed. While it is set nothing is adopted and no cursor
     * advances, because a failed load is indistinguishable from a fresh install to the adoption
     * branch — and adopting on a failed load destroys history sitting intact in the app's own
     * database. See CONTRACT.md §5.8.
     */
    @Volatile
    var frozen: Boolean = false
        private set

    fun freeze() {
        frozen = true
    }

    fun restore(snapshot: ImCursorSnapshot) {
        committed.clear()
        delivered.clear()
        for ((conversationId, seq) in snapshot.convSeqs) {
            if (seq >= 0) {
                committed[conversationId] = seq
                delivered[conversationId] = seq
            }
        }
        conversationCursor = snapshot.conversationCursor
    }

    fun committedOf(conversationId: String): Long = committed[conversationId] ?: 0L

    fun deliveredOf(conversationId: String): Long = delivered[conversationId] ?: 0L

    /**
     * Whether this conversation has ever had a cursor. False is what triggers adoption, so it has
     * to answer "was it in the snapshot, or has it been adopted since" — not "is its seq above
     * zero". An empty conversation legitimately sits at 0 and must not be adopted twice.
     */
    fun isKnown(conversationId: String): Boolean = committed.containsKey(conversationId)

    /** §5.2 rule 2. Runs before every `conn.sync`, including the first. */
    fun resetDeliveredToCommitted() {
        delivered.clear()
        delivered.putAll(committed)
    }

    /** Monotonic. Returns true when the cursor actually moved. */
    fun markDelivered(conversationId: String, seq: Long): Boolean {
        if (seq <= 0) return false
        val known = delivered[conversationId] ?: 0L
        if (seq <= known) return false
        delivered[conversationId] = seq
        return true
    }

    /**
     * Monotonic; a lower seq is ignored rather than an error, which is what lets an application
     * re-derive cursors from its own store by replaying them in any order.
     *
     * Returns true when something changed and the store therefore needs writing.
     */
    fun commit(conversationId: String, seq: Long): Boolean {
        if (frozen) return false
        if (seq < 0) return false
        val known = committed[conversationId]
        if (known != null && seq <= known) return false
        committed[conversationId] = seq
        markDelivered(conversationId, seq)
        return true
    }

    /** Monotonic. Only a completed `conn.sync` run may call this; see CONTRACT.md §5.6 step 8. */
    fun advanceConversationCursor(updatedAt: Long): Boolean {
        if (frozen) return false
        if (updatedAt <= conversationCursor) return false
        conversationCursor = updatedAt
        return true
    }

    fun snapshot(scope: String?): ImCursorSnapshot =
        ImCursorSnapshot(
            convSeqs = HashMap(committed),
            conversationCursor = conversationCursor,
            scope = scope,
        )

    /** What goes in `ResumeRequest.convSeqs`: committed, never delivered. */
    fun committedSeqs(): Map<String, Long> = HashMap(committed)
}

/**
 * Writes the snapshot out, coalescing ordinary commits and never coalescing an adoption.
 *
 * The asymmetry is the whole design and is worth stating where someone might "simplify" it away:
 * **a lost debounced commit costs one duplicate delivery; a lost cursor entry costs silent,
 * permanent data loss.** An adoption is the only write of the second kind — if it is lost, the
 * next cold start sees no entry for that conversation, adopts a *newer* `maxSeq`, and drops
 * everything in between. So [flushNow] is called before every `conn.sync` page and directly after
 * every adoption, while [schedule] is allowed to be lazy.
 *
 * 普通提交可以合并，采纳（adoption）不可以：丢一次合并写只会多投一条重复消息，
 * 丢一条采纳记录会让下次冷启动采纳一个更新的 maxSeq，中间的消息永久静默丢失。
 */
internal class CursorWriter(
    private val store: ImCursorStore,
    private val scope: CoroutineScope,
    private val storeContext: CoroutineContext,
    private val flushInterval: Duration,
    private val logger: ImLogger,
    private val snapshot: () -> ImCursorSnapshot,
) {
    private val dirty = AtomicBoolean(false)
    private val writing = Mutex()

    @Volatile
    private var timer: Job? = null

    /** Marks the snapshot dirty without arming a timer. For a write that flushes immediately. */
    fun markDirty() {
        dirty.set(true)
    }

    /** Marks the snapshot dirty and arms the debounce timer if one is not already running. */
    fun schedule() {
        dirty.set(true)
        if (flushInterval <= Duration.ZERO) {
            scope.launch { flushNow() }
            return
        }
        if (timer?.isActive == true) return
        timer = scope.launch {
            delay(flushInterval)
            flushNow()
        }
    }

    /** Writes now, if anything changed since the last write. Suspends until the store returns. */
    suspend fun flushNow() {
        if (!dirty.getAndSet(false)) return
        val pending = snapshot()
        writing.withLock {
            try {
                withContext(storeContext) { store.save(pending) }
            } catch (cancellation: CancellationException) {
                dirty.set(true)
                throw cancellation
            } catch (failure: Throwable) {
                // Leave it dirty so the next flush retries. Losing this write costs duplicate
                // delivery, not data — but a store that keeps failing is worth saying out loud,
                // because the *next* cold start behaves as if the app had never run.
                dirty.set(true)
                logger.warn("cursor store write failed; cold start may re-deliver messages", failure)
            }
        }
    }

    /**
     * The last-gasp write on [ImClient.close].
     *
     * Blocking, on the caller's thread, and deliberately so: `close()` is not a suspending function
     * and the coroutine scope is about to be cancelled, so there is nowhere to put an asynchronous
     * write. The alternative is losing every commit made since the last debounce window, on the
     * one code path — logout, process teardown — where the next thing that happens is a cold start.
     */
    fun flushBlocking() {
        if (!dirty.getAndSet(false)) return
        try {
            store.save(snapshot())
        } catch (failure: Throwable) {
            dirty.set(true)
            logger.warn("cursor store write failed during close", failure)
        }
    }
}
