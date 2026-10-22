package com.cyaim.im.client

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull

/*
 * `msg.streamBegin` / `msg.streamAppend` / `msg.streamComplete` / `msg.streamAbort` — a reply produced
 * a piece at a time, an AI assistant typing it out (T4) — and the `evt.stream` push that carries the
 * pieces to everyone in the conversation. The four calls live on [MsgApi], because their prefix is
 * `msg` (CONTRACT.md §4.1); everything else about streaming is here, so a reader looking for "what
 * does a stream send, get back and push" finds one place.
 *
 * **The pieces are not messages.** An `evt.stream` frame has no seq, is pushed to online devices only
 * and is never stored: nothing about it is ever repaired, synced or committed, and [ImClient] never
 * lets it near a cursor. What survives is the **completed** stream, which the server stores as one
 * ordinary message — a real seq, `clientMsgId` the one the stream was opened with — and delivers on
 * `evt.message` like any other, to the producer too. That message goes through [ImClient.messages],
 * cursors and gap repair exactly as every other message does, so a device that was offline for the
 * whole generation receives one finished message and not five hundred fragments.
 *
 * 分片不是消息：evt.stream 没有 seq，只投在线设备、从不落库，不补、不同步、不 commit，ImClient 不让它碰游标。
 * 留下来的是收尾后的那条普通消息——真 seq、clientMsgId 是开流时那个——经 evt.message 投递（生产者自己也收到），
 * 走 messages、游标与补洞，与任何消息一样。整段生成期间离线的设备收到的是一条完成的消息，而不是几百个碎片。
 */

// ---------------------------------------------------------------------------------- requests

/**
 * `msg.streamBegin`: opens a stream in a single chat or a group and tells every online member that a
 * reply is coming, so they can draw a placeholder before the first piece.
 *
 * **Name the conversation one of three ways** — [conversationId], else [receiverId], else [groupId],
 * in that order of precedence; none of them is `1001`. Only single chats (a chat with yourself
 * included) and groups take a stream: a chat room, a system or an assistant conversation answers
 * `1008`, as does a group of more than 200 members.
 *
 * Anyone signed in may stream — an ordinary user, a bot, a desk agent — but **only as themselves**,
 * under the same rules as `msg.send`: `1104` banned, `1408` muted, `1303` blocked, `1302` not a friend
 * where the app requires one, `1500` / `1501` / `1503` / `1506` / `1505` for the group. All of it is
 * checked here, at the opening, not at the end. No app setting or add-on gates streaming.
 *
 * 会话三选一：conversationId 优先，其次 receiverId，再次 groupId，都没有是 1001。只有单聊（含自己和自己）与群可以开流；
 * 任何登录用户都能开，但只能以自己的身份、按 msg.send 的同一套规则，全在开流时检查。
 */
@Serializable
public data class BeginStreamRequest(
    public val conversationId: String? = null,
    public val receiverId: String? = null,
    public val groupId: String? = null,
    /**
     * The idempotency key of the message this stream becomes — the server does **not** make one up.
     * Blank is filled in by [MsgApi.streamBegin]; the [SendMessageResult] of `msg.streamComplete`
     * carries it back, and so does the stored message.
     */
    public val clientMsgId: String = "",
    /**
     * The content type of the finished message, an integer on the wire. Whatever you open with is
     * what the stored message carries; [MessageContentType.Stream] is not something to open with.
     */
    public val contentType: MessageContentType = MessageContentType.Text,
    /**
     * Whatever receivers should draw while the stream runs — an assistant's name, an avatar. Echoed
     * only in the opening `evt.stream` frame ([StreamEvent.placeholder]); never stored.
     */
    public val placeholder: JsonObject? = null,
    /**
     * The finished message's options, matched **case-sensitively** like every nested object the socket
     * binds. Two are refused at the opening with `1103`: a non-empty `pushConfig.title` / `body`, and
     * unstored media (`persistent = false` or `onlineOnly`) while the app moderates.
     */
    public val options: MessageOptions? = null,
    /** Merged into the finished message; the keys given to `msg.streamComplete` win. */
    public val extensions: JsonObject? = null,
)

/**
 * `msg.streamAppend`: the next piece. The server numbers the pieces 1, 2, 3… in the order it accepts
 * them and pushes each one as an `evt.stream` frame.
 *
 * An empty [delta] is accepted and does nothing (no frame, no rate token). Refusals: `1002` the stream
 * has finished or expired, `1103` the stream is someone else's, `1401` a piece longer than 4096
 * characters or a stream whose text would pass the server's cap (the stream **stays open**: send a
 * shorter piece, or complete it), `1003` more than 100 pieces a second.
 *
 * 空 delta 被接受且什么都不做。1401 之后流仍然开着。
 */
@Serializable
public data class StreamAppendRequest(
    /** [StreamHandle.streamId]. */
    public val streamId: String,
    public val delta: String,
)

/**
 * `msg.streamComplete`: finishes the stream, stores it as one ordinary message and delivers that
 * message on `evt.message` — to the producer's own connection too.
 *
 * With [content] null (or empty) the message is `{"text": <every piece, joined in order>}`. A
 * [content] **replaces** the pieces rather than being added to them: a producer can store a
 * cleaned-up version of what it streamed. The answer is the stored message's [SendMessageResult].
 *
 * The send runs through the same pipeline as `msg.send`, so it can be refused the same ways
 * (moderation, a webhook, the store). **The stream is consumed either way**: a refused completion
 * pushes a terminal frame with an `abortReason`, and a second complete or abort answers `1002`.
 *
 * content 为空时消息是 {"text": 全部分片按序拼接}；给了 content 就整个替换分片。收尾可以像 msg.send 一样被拒，
 * 但无论成败流都被消费掉了：被拒时推一帧带 abortReason 的终止帧，第二次 complete / abort 回 1002。
 */
@Serializable
public data class CompleteStreamRequest(
    public val streamId: String,
    /** Null keeps the pieces as `{"text": …}`; anything else replaces them. */
    public val content: JsonObject? = null,
    /** Merged over [BeginStreamRequest.extensions]; these keys win. */
    public val extensions: JsonObject? = null,
)

/**
 * `msg.streamAbort`: ends the stream **without a message** — the model failed, the user pressed stop.
 * Everyone watching receives a terminal frame carrying [reason], so no placeholder hangs.
 *
 * Nothing is stored and nothing is delivered on `evt.message`. A second abort, or an abort after
 * complete, answers `1002`.
 */
@Serializable
public data class StreamAbortRequest(
    public val streamId: String,
    /** Shown to receivers as [StreamEvent.abortReason]. Blank becomes "aborted by the producer"; cut to 256 characters. */
    public val reason: String? = null,
)

// --------------------------------------------------------------------------------- responses

/** What `msg.streamBegin` answers: the stream to append to. */
@Serializable
public data class StreamHandle(
    /** `st_…`. Every other call about this stream names it. */
    public val streamId: String = "",
    /** The conversation the stream — and the message it becomes — belongs to. */
    public val conversationId: String = "",
    /** Unix ms. Also the finished message's `sendTime`. */
    public val startedAt: Long = 0,
    /**
     * Seconds of silence after which the server gives up on the stream (30). There is no limit on
     * how long a stream may run, only on how long it may go quiet: append or complete within it, or
     * the stream is reaped — a terminal frame with an `abortReason`, and no message.
     *
     * 只限沉默、不限总时长：在这个秒数内追加或收尾，否则流被回收——推一帧带 abortReason 的终止帧，不产生消息。
     */
    public val idleTimeoutSeconds: Int = 0,
)

// ------------------------------------------------------------------------------- evt.stream

/** Which of the four kinds of `evt.stream` frame a [StreamEvent] is. */
public enum class StreamPhase {
    /** Index 0: a stream opened. No delta; maybe a [StreamEvent.placeholder]. */
    Begin,

    /** Index 1 and up: one piece. */
    Delta,

    /** Terminal: the stream became the stored message [StreamEvent.messageId] at [StreamEvent.seq]. */
    Completed,

    /**
     * Terminal, no message: the producer aborted, went quiet past the idle timeout, or its completion
     * was refused by the send pipeline. [StreamEvent.abortReason] says which.
     */
    Aborted,
}

/**
 * One `evt.stream` frame, as [ImClient.streamEvents] delivers it.
 *
 * The four kinds share one shape, and [phase] tells them apart:
 *
 * | | index | done | carries |
 * |---|---|---|---|
 * | [StreamPhase.Begin] | 0 | false | [placeholder], when the producer gave one |
 * | [StreamPhase.Delta] | 1, 2, 3… | false | [delta] |
 * | [StreamPhase.Completed] | last + 1 | true | [messageId], [seq] |
 * | [StreamPhase.Aborted] | last + 1 | true | [abortReason] |
 *
 * **A missing index is a missing piece, and nothing will resend it.** Pieces are pushed at low
 * priority and may be shed under load; there is no offset, no resend and no catch-up call. A device
 * that notices a hole, joins mid-stream (its first frame has an index above 0) or was offline does
 * not repair anything: it waits for the stored message, which arrives on [ImClient.messages] with the
 * whole text. [StreamAssembler] does that bookkeeping.
 *
 * 缺一个 index 就是丢了一片，而且没有任何东西会重发：没有偏移、没有重发、没有追补。发现缺口、中途加入
 * 或离线过的设备什么都不补，等那条存下来的消息——它带着全文从 messages 到来。
 */
public data class StreamEvent(
    public val streamId: String,
    public val conversationId: String,
    /** The producer. The opening frame and every piece reach the producer's own connection too. */
    public val senderId: String,
    /** 0 for the opening frame, 1… for pieces, one past the last piece for the terminal frame. */
    public val index: Int,
    /** [StreamPhase.Delta] only. */
    public val delta: String?,
    /** True on the terminal frame, whichever way the stream ended. */
    public val done: Boolean,
    /** [StreamPhase.Completed] only: the stored message. A string on the wire, read either way. */
    public val messageId: Long?,
    /** [StreamPhase.Completed] only: the stored message's real seq in [conversationId]. */
    public val seq: Long?,
    /** [StreamPhase.Aborted] only. */
    public val abortReason: String?,
    /** [StreamPhase.Begin] only, when the producer gave one. */
    public val placeholder: JsonObject?,
) {
    /** Done with a message id is [StreamPhase.Completed], done without one [StreamPhase.Aborted]. */
    public val phase: StreamPhase
        get() = when {
            done && messageId != null -> StreamPhase.Completed
            done -> StreamPhase.Aborted
            index <= 0 -> StreamPhase.Begin
            else -> StreamPhase.Delta
        }

    public companion object {
        /**
         * The `data` of an `evt.stream` frame — or null when it is not one this build can read (not
         * an object, or no stream id). Never throws: a frame of an unexpected shape must not stop the
         * flow every later frame arrives on.
         */
        internal fun fromData(data: JsonElement?): StreamEvent? {
            val frame = data as? JsonObject ?: return null
            val streamId = frame.string("streamId")?.takeIf { it.isNotEmpty() } ?: return null
            return StreamEvent(
                streamId = streamId,
                conversationId = frame.string("conversationId").orEmpty(),
                senderId = frame.string("senderId").orEmpty(),
                index = frame.long("index")?.toInt() ?: 0,
                delta = frame.string("delta"),
                done = (frame["done"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: false,
                // The server writes the id as a string (it passes 2^53); an older one wrote a number.
                // 服务端把 id 写成字符串（它超过 2^53）；更早的版本写数字。两种都读。
                messageId = frame.long("messageId"),
                seq = frame.long("seq"),
                abortReason = frame.string("abortReason"),
                placeholder = frame["placeholder"] as? JsonObject,
            )
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

        /** A JSON integer, or a string holding one. */
        private fun JsonObject.long(key: String): Long? {
            val value = this[key] as? JsonPrimitive ?: return null
            return if (value.isString) value.content.toLongOrNull() else value.longOrNull
        }
    }
}

// ------------------------------------------------------------------------------ assembling

/** Where an [AssembledStream] stands. */
public enum class StreamStatus {
    /** Opened, not finished. */
    Streaming,

    /** Became the stored message [AssembledStream.messageId]; swap the placeholder for it. */
    Completed,

    /** Ended without a message; [AssembledStream.abortReason] says why. Nothing will arrive. */
    Aborted,
}

/**
 * One stream as a receiver should draw it, built by [StreamAssembler] from its `evt.stream` frames.
 *
 * [text] is **for display while the stream runs**. The stored message is the truth: when it arrives on
 * [ImClient.messages] — matched by [messageId] once the terminal frame has named it — draw that
 * instead. It can differ from [text]: the producer may complete with content that replaces the
 * pieces, and a piece that never reached this device is in the stored message and not in [text].
 *
 * text 只用于流进行时的显示；存下来的那条消息才是准的——按 messageId 匹配到之后换成它。两者可能不同：
 * 生产者收尾时可以给出替换分片的 content，没到这台设备的分片在消息里而不在 text 里。
 */
public data class AssembledStream(
    public val streamId: String,
    public val conversationId: String,
    public val senderId: String,
    /** From the opening frame; null if the producer gave none or this device missed the opening. */
    public val placeholder: JsonObject?,
    /**
     * The pieces joined in index order, **up to the first missing one**. A later piece is held back
     * rather than appended past a hole, and joins the text if the missing piece turns up.
     */
    public val text: String,
    public val status: StreamStatus,
    /**
     * Every frame up to the newest one this device has seen arrived — the opening included. False
     * after a shed piece or a mid-stream join: [text] is incomplete and nothing will complete it but
     * the stored message.
     */
    public val intact: Boolean,
    /** [StreamStatus.Completed] only. */
    public val messageId: Long?,
    /** [StreamStatus.Completed] only. */
    public val seq: Long?,
    /** [StreamStatus.Aborted] only. */
    public val abortReason: String?,
)

/**
 * Turns `evt.stream` frames into the streams a receiver draws — the pieces joined by index, the
 * terminal frame read as completed or aborted — and holds to the server's rules while doing it:
 *
 * - **Pieces are joined by [StreamEvent.index], not by arrival.** A duplicate is ignored; a piece that
 *   arrives ahead of a missing one waits, and [AssembledStream.text] stops at the hole.
 * - **A hole is never repaired.** Nothing can resend a piece. The stream is marked not
 *   [AssembledStream.intact] and keeps going; the stored message is what fixes it.
 * - **A mid-stream join is accepted**, not dropped: the first frame seen opens the stream, marked
 *   not intact.
 * - **A terminal frame finishes the stream for good.** A piece or a second terminal frame arriving
 *   after it is ignored, and so is a frame for a stream finished recently.
 *
 * Not thread-safe: feed it from one coroutine, as [assemble] does. Streams whose terminal frame this
 * device never sees — it was offline when the producer stopped — stay [StreamStatus.Streaming]; call
 * [clear] when the connection comes back, since every stream in flight across a disconnect will be
 * settled by the stored message or not at all.
 *
 * 按 index 拼，不按到达顺序：重复的丢掉，越过缺口到来的先等着，text 停在缺口处。缺口不补，只标记 intact = false；
 * 中途加入照样接收；终止帧之后到来的任何帧都忽略。非线程安全。断线重连后调 clear()。
 */
public class StreamAssembler {

    private class Live(
        val streamId: String,
        var conversationId: String,
        var senderId: String,
        var placeholder: JsonObject?,
        var opened: Boolean,
    ) {
        val pieces = HashMap<Int, String>()
        val text = StringBuilder()

        /** The highest index joined into [text]: every index from 1 to here is present. */
        var joined = 0
        var newest = 0
    }

    private val live = LinkedHashMap<String, Live>()
    private val finished = object : LinkedHashMap<String, Unit>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?): Boolean = size > FinishedMemory
    }

    /** The streams still running, oldest first. */
    public val active: List<AssembledStream>
        get() = live.values.map { snapshot(it, StreamStatus.Streaming, null) }

    /** The running stream [streamId], or null. */
    public operator fun get(streamId: String): AssembledStream? =
        live[streamId]?.let { snapshot(it, StreamStatus.Streaming, null) }

    /**
     * Applies one frame and returns the stream as it now stands, or null when the frame changed
     * nothing (a duplicate, or a frame for a stream already finished).
     */
    public fun accept(event: StreamEvent): AssembledStream? {
        if (event.streamId in finished) return null
        val stream = live.getOrPut(event.streamId) {
            Live(event.streamId, event.conversationId, event.senderId, placeholder = null, opened = false)
        }
        if (stream.conversationId.isEmpty()) stream.conversationId = event.conversationId
        if (stream.senderId.isEmpty()) stream.senderId = event.senderId

        when (event.phase) {
            StreamPhase.Begin -> {
                if (stream.opened) return null
                stream.opened = true
                stream.placeholder = event.placeholder
            }

            StreamPhase.Delta -> {
                if (event.index <= stream.joined || event.index in stream.pieces) return null
                stream.pieces[event.index] = event.delta.orEmpty()
                stream.newest = maxOf(stream.newest, event.index)
                while (true) {
                    val next = stream.pieces.remove(stream.joined + 1) ?: break
                    stream.text.append(next)
                    stream.joined += 1
                }
            }

            StreamPhase.Completed, StreamPhase.Aborted -> {
                live.remove(event.streamId)
                finished[event.streamId] = Unit
                // The terminal index is one past the last piece, so it says how many there were.
                stream.newest = maxOf(stream.newest, event.index - 1)
                val status = if (event.phase == StreamPhase.Completed) StreamStatus.Completed else StreamStatus.Aborted
                return snapshot(stream, status, event)
            }
        }
        return snapshot(stream, StreamStatus.Streaming, null)
    }

    /** Stops tracking [streamId]. A later frame for it opens it again, as a mid-stream join. */
    public fun remove(streamId: String) {
        live.remove(streamId)
    }

    /** Drops every running stream. Call it when the connection comes back. */
    public fun clear() {
        live.clear()
    }

    private fun snapshot(stream: Live, status: StreamStatus, terminal: StreamEvent?): AssembledStream =
        AssembledStream(
            streamId = stream.streamId,
            conversationId = stream.conversationId,
            senderId = stream.senderId,
            placeholder = stream.placeholder,
            text = stream.text.toString(),
            status = status,
            intact = stream.opened && stream.joined >= stream.newest,
            messageId = terminal?.messageId,
            seq = terminal?.seq,
            abortReason = terminal?.abortReason,
        )

    private companion object {
        /** Finished stream ids remembered so a straggling frame cannot reopen one. */
        const val FinishedMemory = 256
    }
}

/**
 * Assembles a flow of `evt.stream` frames — [ImClient.streamEvents] — with a [StreamAssembler] of its
 * own per collection, emitting each stream every time it changes.
 *
 * ```kotlin
 * im.streamEvents.assemble().collect { stream -> render(stream) }
 * ```
 */
public fun Flow<StreamEvent>.assemble(): Flow<AssembledStream> = flow {
    val assembler = StreamAssembler()
    collect { event -> assembler.accept(event)?.let { emit(it) } }
}

// ---------------------------------------------------------------------------------- producing

/**
 * One stream from the producer's side: [begin] it, [append] pieces, then [complete] or [abort].
 *
 * A convenience over the four [MsgApi] calls, which remain the surface — it holds the [handle] and the
 * [clientMsgId] the stream was opened with so the caller does not have to.
 *
 * ```kotlin
 * val reply = StreamWriter.begin(im.msg, BeginStreamRequest(receiverId = "u_bob"))
 * try {
 *     model.generate(prompt).collect { token -> reply.append(token) }
 *     reply.complete()
 * } catch (e: Exception) {
 *     reply.abort("the model failed")
 *     throw e
 * }
 * ```
 *
 * 生产者一侧的便利封装：begin → append* → complete | abort。四个 MsgApi 调用才是正式的表面。
 */
public class StreamWriter private constructor(
    private val msg: MsgApi,
    /** What `msg.streamBegin` answered. */
    public val handle: StreamHandle,
    /** The idempotency key of the message this stream becomes. */
    public val clientMsgId: String,
) {
    public val streamId: String get() = handle.streamId

    /** `msg.streamAppend` for this stream. */
    public suspend fun append(delta: String) {
        msg.streamAppend(StreamAppendRequest(streamId, delta))
    }

    /** `msg.streamComplete` for this stream. Null [content] stores the pieces as `{"text": …}`. */
    public suspend fun complete(content: JsonObject? = null, extensions: JsonObject? = null): SendMessageResult =
        msg.streamComplete(CompleteStreamRequest(streamId, content, extensions))

    /** `msg.streamAbort` for this stream. */
    public suspend fun abort(reason: String? = null) {
        msg.streamAbort(StreamAbortRequest(streamId, reason))
    }

    public companion object {
        /** Sends `msg.streamBegin`, filling a blank [BeginStreamRequest.clientMsgId] first. */
        public suspend fun begin(msg: MsgApi, request: BeginStreamRequest): StreamWriter {
            val keyed = msg.keyed(request)
            return StreamWriter(msg, msg.streamBegin(keyed), keyed.clientMsgId)
        }
    }
}
