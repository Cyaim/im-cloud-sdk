package com.cyaim.im.client

import kotlinx.serialization.Serializable
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * Who a set of cursors belongs to: `(endpoint host, appId, userId)`.
 *
 * Not the device id — the store is already local to the device. [userId] is the part that matters:
 * without it, two accounts on one handset share one set of cursors, and the second one to sign in
 * silently inherits the first one's position and skips whatever the first had already consumed.
 * That is one person's cursors replaying into another person's client. CONTRACT.md §5.3.
 *
 * 作用域键必须含 userId：同一台设备换账号时，否则第二个账号会继承第一个账号的游标。
 */
public data class ImCursorScope(
    public val host: String,
    public val appId: String,
    public val userId: String,
) {
    /**
     * The identity stamped into [ImCursorSnapshot.scope] and compared on load. Spelled the same way
     * in all five SDKs, so a snapshot written by one is legible to the others.
     */
    public val key: String get() = "$host|$appId|${userId.ifBlank { "*" }}"

    /** The same identity, safe as a file name on every platform. */
    public val storageKey: String get() = key.replace(Regex("[^A-Za-z0-9._-]"), "_")

    override fun toString(): String = key

    public companion object {
        /**
         * The usual construction: the endpoint the client connects to, reduced to its host.
         *
         * The host and not the whole URL, because a deployment that moves between `wss://h/im` and
         * `wss://h/gateway` is the same server holding the same seqs; re-downloading everything
         * because a path changed is a cost with nothing behind it.
         */
        public fun of(endpoint: String, appId: String, userId: String): ImCursorScope =
            ImCursorScope(
                host = endpoint.substringAfter("://").substringBefore('/').substringBefore('?'),
                appId = appId,
                userId = userId,
            )
    }
}

/**
 * What survives a process restart.
 *
 * @property convSeqs per conversation, the highest seq the **application has durably stored**.
 *   This is what `conn.sync` is told, and it is deliberately not "the highest seq we received":
 *   a message that reached a callback and not a database is exactly what a crash loses.
 * @property conversationCursor the highest `ConversationView.updatedAt` a **completed**
 *   `conn.sync` run consumed. Advancing it after a partial run permanently hides every
 *   conversation on the pages that were never read.
 * @property scope which [ImCursorScope] these belong to, as [ImCursorScope.key]. The SDK stamps it
 *   on every write and refuses a snapshot belonging to a different account, which is what stops
 *   account switching on a shared handset from handing one user another's cursors.
 *
 *   **The identity lives in the payload rather than in the store's signature on purpose.** A store
 *   is a few lines an integrator writes; a store that keys itself per account is a few lines an
 *   integrator *remembers* to write. Carrying the identity here means the SDK can refuse cursors
 *   belonging to somebody else even when the store did nothing to keep two accounts apart — an app
 *   that does nothing special cannot get it wrong. Null on a snapshot the SDK has never written.
 */
@Serializable
public data class ImCursorSnapshot(
    public val convSeqs: Map<String, Long> = emptyMap(),
    public val conversationCursor: Long = 0,
    public val scope: String? = null,
)

/**
 * Where the cold-start cursors live.
 *
 * **This is a required constructor argument of [ImClient], and there is no default.** That is a
 * deliberate compile error rather than a convenience.
 *
 * The bug it exists to prevent: a client that starts with no cursors reports nothing in
 * `convSeqs`, the server therefore reports no gaps (`ConnController.Sync` only produces a gap for
 * a conversation the client reported a non-zero seq for), and the client then adopts the server's
 * current `maxSeq`. Every message that arrived while the app was closed is now behind the cursor,
 * will never be requested and will never arrive — with no error, no log line and no later event
 * that corrects it. Four of the five SDKs shipped that behaviour.
 *
 * Defaulting to no persistence is what produced it. Defaulting to *some* persistence would mean
 * the SDK guessing where a JVM application may write, and a wrong guess about that is worse than
 * a compile error. So the choice is yours and it is explicit: [file] for a real one, [inMemory]
 * for none.
 *
 * **Lifetime: this store and your own message store have exactly one lifetime.** Whatever destroys
 * one destroys the other, cursors first. Clearing messages while keeping cursors shows an empty
 * conversation that will never refill; clearing cursors while keeping messages costs a full
 * re-download and duplicate delivery. A logout that keeps messages for a fast re-login keeps the
 * cursors too.
 *
 * 本存储与你自己的消息库共用同一个生命周期，销毁时先游标后消息。只清消息会留下一个
 * 永远填不回来的空会话；只清游标会导致全量重下与重复投递。
 *
 * Implementations may be called from any thread but never concurrently with themselves; the SDK
 * serialises its own writes. [save] runs on the dispatcher passed to [ImClient] as
 * `cursorStoreContext`, which defaults to `Dispatchers.IO`, so blocking here is expected.
 */
public interface ImCursorStore {

    /** Called once, before the first connect. Throwing is handled — see [ImClient.cursorStoreState]. */
    public fun load(): ImCursorSnapshot

    /** Called by the SDK. May be coalesced; see [ImOptions.cursorFlushInterval]. */
    public fun save(snapshot: ImCursorSnapshot)

    public companion object {
        /**
         * No persistence at all. Every cold start adopts the server's position and silently drops
         * whatever arrived while the process was down.
         *
         * Legitimate for a bot, a test, or a client whose message store is itself in memory.
         * Not legitimate for a chat app — pass [file] and give it a directory.
         */
        public fun inMemory(): ImCursorStore = InMemoryCursorStore()

        /**
         * One JSON file, written through a temp file and renamed.
         *
         * The host app supplies the path because this artifact has no Android dependency and
         * therefore no `Context`: on Android pass `File(context.filesDir, "im-cursors.json")`, on
         * a desktop or service host whatever directory you already own.
         *
         * `java.io.File` rather than `java.nio.file.Path`, deliberately. `Path` and `Files` are
         * API 26 on Android and this SDK supports API 21; a `Path` in this signature would compile
         * everywhere and then throw `NoClassDefFoundError` on a five-year-old handset unless the
         * app happened to have core library desugaring switched on.
         *
         * The file is per account. If you point two accounts at the same path the SDK notices —
         * the snapshot carries its scope key — and starts clean rather than adopting the other
         * user's cursors, but you lose the first account's cursors when the second one writes.
         * Put the user id in the filename.
         */
        public fun file(path: File): ImCursorStore = FileCursorStore(path)

        /** [file] for callers holding a string path. */
        public fun file(path: String): ImCursorStore = FileCursorStore(File(path))
    }
}

/** What happened when [ImCursorStore.load] was called. Observable so an app can assert on it. */
public sealed interface ImCursorStoreState {

    /** Before the first connect. */
    public data object NotLoaded : ImCursorStoreState

    /**
     * The snapshot was read. [conversations] is how many cursors came back — **zero on a genuine
     * fresh install, and also zero when a store silently loses its data**, which is why
     * [persistent] is here too.
     */
    public data class Loaded(
        public val conversations: Int,
        public val conversationCursor: Long,
        public val persistent: Boolean,
    ) : ImCursorStoreState

    /**
     * [ImCursorStore.load] threw, or returned something the SDK could not use.
     *
     * The SDK does **not** treat this as a fresh install: it refuses to adopt any conversation and
     * refuses to advance any cursor for the rest of the session. A failed load and a fresh install
     * are indistinguishable to the adoption branch, and adopting on a failed load destroys history
     * that is sitting intact in your own database.
     *
     * You decide what to do: re-derive the cursors from your own message store and replay them
     * through [ImClient.commit] (the correct fix, and the reason `commit` is monotonic), or accept
     * a re-download by constructing a new client with a working store.
     */
    public data class Failed(public val cause: Throwable) : ImCursorStoreState
}

/**
 * [ImCursorStore.inMemory].
 *
 * Recognised by [ImClient] by type, and that is the whole mechanism: "is this store persistent" is
 * answered by the SDK from the store's identity, never declared by the store. The interface used to
 * carry an `isPersistent` flag, which let *any* store — including one an integrator wrote over
 * SQLite — announce itself volatile; and the only thing that answer drives is the warning about
 * losing messages. A store that can lie about that is a store that can silence the one line
 * standing between a misconfigured client and a support ticket about missing history.
 *
 * 「是否持久化」由 SDK 按存储的身份判断，不由存储自己声明。
 */
internal class InMemoryCursorStore : ImCursorStore {
    private val held = AtomicReference(ImCursorSnapshot())

    override fun load(): ImCursorSnapshot = held.get()

    override fun save(snapshot: ImCursorSnapshot) {
        held.set(snapshot)
    }
}

/**
 * [ImCursorStore.file].
 *
 * Written through a sibling temp file and then moved, because the failure this whole mechanism
 * guards against is a *partial* cursor file: a half-written JSON document fails to parse, which
 * the SDK correctly refuses to treat as a fresh install, which strands the session with no cursor
 * advancement until the app is restarted. A rename is the cheapest way to make the file either the
 * old one or the new one and never something in between.
 */
internal class FileCursorStore(private val file: File) : ImCursorStore {

    override fun load(): ImCursorSnapshot {
        if (!file.exists()) return ImCursorSnapshot()
        val text = file.readText(Charsets.UTF_8)
        if (text.isBlank()) return ImCursorSnapshot()
        return ImJson.decodeFromString(ImCursorSnapshot.serializer(), text)
    }

    override fun save(snapshot: ImCursorSnapshot) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(ImJson.encodeToString(ImCursorSnapshot.serializer(), snapshot), Charsets.UTF_8)

        // On every filesystem Android uses, renaming over an existing file is atomic and is what
        // makes the file either the old snapshot or the new one. The fallbacks are for Windows and
        // the odd FUSE volume, which refuse a rename onto an existing name.
        if (temp.renameTo(file)) return
        if (file.delete() && temp.renameTo(file)) return

        try {
            temp.copyTo(file, overwrite = true)
        } finally {
            temp.delete()
        }
    }
}
