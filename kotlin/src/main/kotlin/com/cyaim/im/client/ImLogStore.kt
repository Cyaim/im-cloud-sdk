package com.cyaim.im.client

import java.io.File
import java.util.ArrayDeque

/**
 * One line of the SDK's own runtime log. [t] is Unix ms.
 *
 * Spelled the same way in all five SDKs so a bundle written by one is legible to whoever opens it,
 * whatever produced it.
 * 五端拼写一致：谁打开这份日志，都读得懂它是哪一端写的。
 */
public data class ImLogLine(
    public val t: Long,
    public val level: String,
    public val msg: String,
)

/**
 * Where the SDK's runtime log lives between runs.
 *
 * The decision behind this interface is `ADR-003`: **the store belongs to the integrating
 * application**, exactly as [ImCursorStore] does. The SDK does not pick a write location, because
 * on Android that is app-private storage whose backup behaviour you configure, and "do chat logs
 * end up in Google's backup" is a question you answer to a regulator rather than one an SDK author
 * should answer for you.
 * 依据 ADR-003：存储属于接入方，与游标存储同理。SDK 不替你选写入位置——
 * 「聊天日志会不会进入云备份」是你要向监管解释的问题。
 *
 * **Every method may throw**, and every throw is handled. A broken store must never take down a
 * client that is otherwise chatting happily: logging is a diagnostic feature, so its failure has to
 * cost less than the thing it serves.
 * 每个方法都可以抛，而每一次抛出都被处理：坏掉的存储绝不能让一个本来聊得好好的客户端断线。
 */
public interface ImLogStore {
    /** Appends lines. May coalesce, and may drop the oldest to stay within its own bound. */
    public fun append(lines: List<ImLogLine>)

    /** Everything currently held, oldest first. */
    public fun read(): List<ImLogLine>

    /** Called after a successful upload. A store that ignores this is allowed but will grow. */
    public fun clear()

    public companion object {
        /**
         * Loses everything on restart. The default, and an honest one.
         *
         * What it costs is stated rather than hidden: the log then covers this process only, so it
         * answers "what is happening now" completely and "what happened when it crashed" not at
         * all. The console shows which of the two a support engineer is looking at, because a
         * three-minute log and a seven-day log are otherwise identical.
         * 代价说在明处：只覆盖本次进程——完整地回答「现在正在发生什么」，
         * 而对「崩的时候发生了什么」一个字也答不出。
         *
         * @param capacity lines kept before the oldest are dropped. Bounded on lines rather than
         * bytes because a line is what a reader counts, and a byte cap truncates the middle of the
         * sentence somebody is trying to read.
         */
        public fun inMemory(capacity: Int = 2000): ImLogStore = InMemoryLogStore(capacity)

        /**
         * A single append-only file, rotated once at [maxBytes].
         *
         * **Provided but not the default**, and the difference matters: choosing this is you saying
         * where your users' runtime detail may be written. On Android pass a file under
         * `context.filesDir` and decide separately whether that directory is backed up.
         * 提供但不是默认：选它，是你在说「我的用户的运行细节可以写在这里」。
         *
         * Two files rather than one, because a single file truncated at the limit loses the tail —
         * and the tail is the failure. The older half is kept as `.1` and read back first.
         * 两个文件而不是一个：单文件到限就截断会丢掉尾巴，而尾巴正是故障本身。
         */
        public fun file(path: File, maxBytes: Long = 2L * 1024 * 1024): ImLogStore =
            FileLogStore(path, maxBytes)
    }
}

/**
 * True only for the store [ImLogStore.inMemory] builds.
 *
 * "Is this store persistent" is answered by the SDK from the store's identity, never by the store
 * itself — the same rule [isVolatileCursorStore] follows. A declared flag would let any store
 * announce itself persistent, and the only thing that answer drives is whether a support engineer
 * is told the log they are reading covers three minutes or three weeks. A store that can lie about
 * that is a store that can make somebody conclude nothing went wrong.
 * 由 SDK 按身份判断而不是由存储自称：能自称持久的存储，也能让人得出「什么都没发生」的结论。
 */
public fun isVolatileLogStore(store: ImLogStore): Boolean = store is InMemoryLogStore

internal class InMemoryLogStore(private val capacity: Int) : ImLogStore {
    private val lines = ArrayDeque<ImLogLine>()

    @Synchronized
    override fun append(lines: List<ImLogLine>) {
        this.lines.addAll(lines)
        // The newest are what a support engineer needs: the failure is at the end of the log.
        // 保留最新的：故障在日志末尾。
        while (this.lines.size > capacity) {
            this.lines.pollFirst()
        }
    }

    @Synchronized
    override fun read(): List<ImLogLine> = lines.toList()

    @Synchronized
    override fun clear() {
        lines.clear()
    }
}

internal class FileLogStore(private val path: File, private val maxBytes: Long) : ImLogStore {
    private val previous = File(path.parentFile, path.name + ".1")

    @Synchronized
    override fun append(lines: List<ImLogLine>) {
        path.parentFile?.mkdirs()

        if (path.exists() && path.length() >= maxBytes) {
            previous.delete()
            path.renameTo(previous)
        }

        path.appendText(lines.joinToString(separator = "") { "${it.t}\t${it.level}\t${escape(it.msg)}\n" })
    }

    @Synchronized
    override fun read(): List<ImLogLine> =
        (readOne(previous) + readOne(path))

    @Synchronized
    override fun clear() {
        path.delete()
        previous.delete()
    }

    private fun readOne(file: File): List<ImLogLine> {
        if (!file.exists()) return emptyList()

        return file.readLines().mapNotNull { line ->
            val parts = line.split('\t', limit = 3)
            if (parts.size < 3) return@mapNotNull null
            val at = parts[0].toLongOrNull() ?: return@mapNotNull null
            ImLogLine(at, parts[1], unescape(parts[2]))
        }
    }

    // Newlines and tabs are escaped rather than forbidden: a log line very often carries a stack
    // trace, and a format that silently split one across records would make the traces unreadable
    // exactly when they matter.
    // 转义而不是禁止换行与制表符：日志行里常常是一段堆栈，
    // 而一个会静默把它拆成几条记录的格式，恰好在最要紧的时候让堆栈变得读不懂。
    private fun escape(text: String): String = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")

    private fun unescape(text: String): String {
        val out = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '\\' && i + 1 < text.length) {
                when (text[i + 1]) {
                    'n' -> { out.append('\n'); i += 2; continue }
                    't' -> { out.append('\t'); i += 2; continue }
                    '\\' -> { out.append('\\'); i += 2; continue }
                }
            }
            out.append(c)
            i++
        }
        return out.toString()
    }
}

/**
 * Tees the SDK's own diagnostics into both the integrator's [ImLogger] sink and the [ImLogStore].
 *
 * Both, because they answer different questions. The sink is for the developer watching Logcat
 * right now; the store is for the support engineer reading a bundle from a customer's handset a
 * week later. Wiring only the sink would mean nothing to upload; wiring only the store would take
 * away the line a developer is staring at.
 * 两边都写，因为它们回答不同的问题：sink 给此刻盯着 Logcat 的开发者，
 * store 给一周后读客户手机上那份包的支持工程师。
 */
internal class ImLog(
    private val store: ImLogStore,
    private val sink: ImLogger,
    private val now: () -> Long = System::currentTimeMillis,
) {
    @Volatile
    private var failedToWrite = false

    val isVolatile: Boolean get() = isVolatileLogStore(store)

    /** True once an append or a read has thrown. Surfaced so a misconfigured store is findable. */
    val storeFailed: Boolean get() = failedToWrite

    fun write(level: ImLogLevel, message: String, cause: Throwable? = null) {
        sink.log(level, message, cause)

        val text = if (cause == null) message else "$message: ${cause.stackTraceToString()}"

        try {
            store.append(listOf(ImLogLine(now(), level.name.lowercase(), text)))
        } catch (failure: Throwable) {
            // Deliberately swallowed. A store that cannot be written to is a diagnostic problem,
            // and raising it here would put a logging failure in the path of whatever was being
            // logged — very often an error the application actually needs to see.
            // 刻意吞掉：在这里抛出，会把一次日志失败插进正在被记录的那件事的路径上。
            failedToWrite = true
        }
    }

    fun read(): List<ImLogLine> =
        try {
            store.read()
        } catch (failure: Throwable) {
            failedToWrite = true
            emptyList()
        }

    fun clear() {
        try {
            store.clear()
        } catch (failure: Throwable) {
            failedToWrite = true
        }
    }
}

/**
 * Renders lines as the text file a support engineer opens.
 *
 * Plain text, one line each, ISO timestamps — not JSON. Whoever reads this is reading it in a
 * viewer, often on a phone, and the first thing they do is search it for a word.
 * 纯文本而不是 JSON：读它的人在查看器里读、常常在手机上，而他做的第一件事是搜一个词。
 */
internal fun renderLogBundle(lines: List<ImLogLine>): String =
    lines.joinToString(separator = "\n") {
        "${java.time.Instant.ofEpochMilli(it.t)} ${it.level.uppercase().padEnd(5)} ${it.msg}"
    }
