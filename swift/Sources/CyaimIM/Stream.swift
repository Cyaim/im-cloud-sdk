import Foundation

// `msg.streamBegin` / `msg.streamAppend` / `msg.streamComplete` / `msg.streamAbort` — a reply produced
// a piece at a time, an AI assistant typing it out (T4) — and the `evt.stream` push that carries the
// pieces to everyone in the conversation. The four calls live on ``ImMsgNamespace``, because their
// prefix is `msg` (CONTRACT.md §4.1); everything else about streaming is here, so a reader looking for
// "what does a stream send, get back and push" finds one place.
//
// **The pieces are not messages.** An `evt.stream` frame has no seq, is pushed to online devices only
// and is never stored: nothing about it is ever repaired, synced or committed, and ``ImClient`` never
// lets it near a cursor — it reads `evt.stream` only in ``ImClient/streamEvents()``. What survives is
// the **completed** stream, which the server stores as one ordinary message — a real seq, the
// `clientMsgId` the stream was opened with — and delivers on `evt.message` like any other, to the
// producer too. That message goes through ``ImClient/messages()``, cursors and gap repair exactly as
// every other message does, so a device that was offline for the whole generation receives one
// finished message and not five hundred fragments.
//
// 分片不是消息：evt.stream 没有 seq，只投在线设备、从不落库，不补、不同步、不 commit，ImClient 不让它碰游标。
// 留下来的是收尾后的那条普通消息——真 seq、clientMsgId 是开流时那个——经 evt.message 投递（生产者自己也收到），
// 走 messages()、游标与补洞，与任何消息一样。整段生成期间离线的设备收到的是一条完成的消息，而不是几百个碎片。

// MARK: - Requests

/// `msg.streamBegin`: opens a stream in a single chat or a group and tells every online member that a
/// reply is coming, so they can draw a placeholder before the first piece.
///
/// **Name the conversation one of three ways** — ``conversationId``, else ``receiverId``, else
/// ``groupId``, in that order of precedence; none of them is `1001`. Only single chats (a chat with
/// yourself included) and groups take a stream: a chat room, a system or an assistant conversation
/// answers `1008`, as does a group of more than 200 members.
///
/// Anyone signed in may stream — an ordinary user, a bot, a desk agent — but **only as themselves**,
/// under the same rules as `msg.send`: `1104` banned, `1408` muted, `1303` blocked, `1302` not a friend
/// where the app requires one, `1500` / `1501` / `1503` / `1506` / `1505` for the group. All of it is
/// checked here, at the opening, not at the end. No app setting or add-on gates streaming.
///
/// ``clientMsgId`` is minted when the request is built, as ``SendMessageRequest`` mints its own, so
/// retrying the same request reuses it; a blank one is filled in by ``ImMsgNamespace/streamBegin(_:)``.
///
/// 会话三选一：conversationId 优先，其次 receiverId，再次 groupId，都没有是 1001。只有单聊（含自己和自己）与群可以开流；
/// 任何登录用户都能开，但只能以自己的身份、按 msg.send 的同一套规则，全在开流时检查。
public struct BeginStreamRequest: Encodable, Sendable, Hashable {
    public var conversationId: String?
    public var receiverId: String?
    public var groupId: String?

    /// The idempotency key of the message this stream becomes — the server does **not** make one up
    /// (`1001` without it). Minted when the request is built; a blank one is filled in by
    /// ``ImMsgNamespace/streamBegin(_:)``. The ``SendMessageResult`` of `msg.streamComplete` carries it
    /// back, and so does the stored message.
    public var clientMsgId: String

    /// The content type of the finished message, an integer on the wire. Whatever you open with is
    /// what the stored message carries; ``MessageContentType/stream`` is not something to open with.
    public var contentType: MessageContentType

    /// Whatever receivers should draw while the stream runs — an assistant's name, an avatar. Echoed
    /// only in the opening `evt.stream` frame (``StreamEvent/placeholder``); never stored.
    public var placeholder: [String: JSONValue]?

    /// The finished message's options, matched **case-sensitively** like every nested object the
    /// socket binds. Two are refused at the opening with `1103`: a non-empty `pushConfig.title` /
    /// `body`, and unstored media (`persistent == false` or `onlineOnly`) while the app moderates.
    public var options: MessageOptions?

    /// Merged into the finished message; the keys given to `msg.streamComplete` win.
    public var extensions: [String: JSONValue]?

    public init(
        conversationId: String? = nil,
        receiverId: String? = nil,
        groupId: String? = nil,
        clientMsgId: String = ClientMessageId.generate(),
        contentType: MessageContentType = .text,
        placeholder: [String: JSONValue]? = nil,
        options: MessageOptions? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.conversationId = conversationId
        self.receiverId = receiverId
        self.groupId = groupId
        self.clientMsgId = clientMsgId
        self.contentType = contentType
        self.placeholder = placeholder
        self.options = options
        self.extensions = extensions
    }

    /// This request with a client message id, filled in when blank. Shared by
    /// ``ImMsgNamespace/streamBegin(_:)`` and ``StreamWriter/begin(_:_:)``.
    func keyed() -> BeginStreamRequest {
        guard clientMsgId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }

        var filled = self
        filled.clientMsgId = ClientMessageId.generate()
        return filled
    }
}

/// `msg.streamAppend`: the next piece. The server numbers the pieces 1, 2, 3… in the order it accepts
/// them and pushes each one as an `evt.stream` frame.
///
/// An empty ``delta`` is accepted and does nothing (no frame, no rate token). Refusals: `1002` the
/// stream has finished or expired, `1103` the stream is someone else's, `1401` a piece longer than
/// 4096 characters or a stream whose text would pass the server's cap (the stream **stays open**: send
/// a shorter piece, or complete it), `1003` more than 100 pieces a second.
///
/// 空 delta 被接受且什么都不做。1401 之后流仍然开着。
public struct StreamAppendRequest: Encodable, Sendable, Hashable {
    /// ``StreamHandle/streamId``.
    public var streamId: String
    public var delta: String

    public init(streamId: String, delta: String) {
        self.streamId = streamId
        self.delta = delta
    }
}

/// `msg.streamComplete`: finishes the stream, stores it as one ordinary message and delivers that
/// message on `evt.message` — to the producer's own connection too.
///
/// With ``content`` `nil` (or empty) the message is `{"text": <every piece, joined in order>}`. A
/// ``content`` **replaces** the pieces rather than being added to them: a producer can store a
/// cleaned-up version of what it streamed. The answer is the stored message's ``SendMessageResult``.
///
/// The send runs through the same pipeline as `msg.send`, so it can be refused the same ways
/// (moderation, a webhook, the store). **The stream is consumed either way**: a refused completion
/// pushes a terminal frame with an `abortReason`, and a second complete or abort answers `1002`.
///
/// content 为空时消息是 {"text": 全部分片按序拼接}；给了 content 就整个替换分片。收尾可以像 msg.send 一样被拒，
/// 但无论成败流都被消费掉了：被拒时推一帧带 abortReason 的终止帧，第二次 complete / abort 回 1002。
public struct CompleteStreamRequest: Encodable, Sendable, Hashable {
    public var streamId: String

    /// `nil` keeps the pieces as `{"text": …}`; anything else replaces them.
    public var content: [String: JSONValue]?

    /// Merged over ``BeginStreamRequest/extensions``; these keys win.
    public var extensions: [String: JSONValue]?

    public init(streamId: String, content: [String: JSONValue]? = nil, extensions: [String: JSONValue]? = nil) {
        self.streamId = streamId
        self.content = content
        self.extensions = extensions
    }
}

/// `msg.streamAbort`: ends the stream **without a message** — the model failed, the user pressed
/// stop. Everyone watching receives a terminal frame carrying ``reason``, so no placeholder hangs.
///
/// Nothing is stored and nothing is delivered on `evt.message`. A second abort, or an abort after
/// complete, answers `1002`.
public struct StreamAbortRequest: Encodable, Sendable, Hashable {
    public var streamId: String

    /// Shown to receivers as ``StreamEvent/abortReason``. Blank becomes "aborted by the producer";
    /// cut to 256 characters. `nil` leaves the key out of the body.
    public var reason: String?

    public init(streamId: String, reason: String? = nil) {
        self.streamId = streamId
        self.reason = reason
    }
}

// MARK: - Payloads

/// What `msg.streamBegin` answers: the stream to append to.
public struct StreamHandle: Decodable, Sendable, Hashable {
    /// `st_…`. Every other call about this stream names it.
    public let streamId: String

    /// The conversation the stream — and the message it becomes — belongs to.
    public let conversationId: String

    /// Unix ms. Also the finished message's `sendTime`.
    public let startedAt: Int64

    /// Seconds of silence after which the server gives up on the stream (30). There is no limit on
    /// how long a stream may run, only on how long it may go quiet: append or complete within it, or
    /// the stream is reaped — a terminal frame with an `abortReason`, and no message.
    ///
    /// 只限沉默、不限总时长：在这个秒数内追加或收尾，否则流被回收——推一帧带 abortReason 的终止帧，不产生消息。
    public let idleTimeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case streamId, conversationId, startedAt, idleTimeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamId = c.imString(.streamId) ?? ""
        conversationId = c.imString(.conversationId) ?? ""
        startedAt = c.imInt64(.startedAt) ?? 0
        idleTimeoutSeconds = c.imInt(.idleTimeoutSeconds) ?? 0
    }
}

// MARK: - evt.stream

/// Which of the four kinds of `evt.stream` frame a ``StreamEvent`` is.
public enum StreamPhase: Sendable, Hashable {
    /// Index 0: a stream opened. No delta; maybe a ``StreamEvent/placeholder``.
    case begin

    /// Index 1 and up: one piece.
    case delta

    /// Terminal: the stream became the stored message ``StreamEvent/messageId`` at
    /// ``StreamEvent/seq``.
    case completed

    /// Terminal, no message: the producer aborted, went quiet past the idle timeout, or its
    /// completion was refused by the send pipeline. ``StreamEvent/abortReason`` says which.
    case aborted
}

/// One `evt.stream` frame, as ``ImClient/streamEvents()`` delivers it.
///
/// The four kinds share one shape, and ``phase`` tells them apart:
///
/// | | index | done | carries |
/// |---|---|---|---|
/// | ``StreamPhase/begin`` | 0 | false | ``placeholder``, when the producer gave one |
/// | ``StreamPhase/delta`` | 1, 2, 3… | false | ``delta`` |
/// | ``StreamPhase/completed`` | last + 1 | true | ``messageId``, ``seq`` |
/// | ``StreamPhase/aborted`` | last + 1 | true | ``abortReason`` |
///
/// **A missing index is a missing piece, and nothing will resend it.** Pieces are pushed at low
/// priority and may be shed under load; there is no offset, no resend and no catch-up call. A device
/// that notices a hole, joins mid-stream (its first frame has an index above 0) or was offline does
/// not repair anything: it waits for the stored message, which arrives on ``ImClient/messages()`` with
/// the whole text. ``StreamAssembler`` does that bookkeeping.
///
/// 缺一个 index 就是丢了一片，而且没有任何东西会重发：没有偏移、没有重发、没有追补。发现缺口、中途加入
/// 或离线过的设备什么都不补，等那条存下来的消息——它带着全文从 messages() 到来。
public struct StreamEvent: Sendable, Hashable {
    public let streamId: String
    public let conversationId: String

    /// The producer. The opening frame and every piece reach the producer's own connection too.
    public let senderId: String

    /// 0 for the opening frame, 1… for pieces, one past the last piece for the terminal frame.
    public let index: Int

    /// ``StreamPhase/delta`` only.
    public let delta: String?

    /// True on the terminal frame, whichever way the stream ended.
    public let done: Bool

    /// ``StreamPhase/completed`` only: the stored message. A string on the wire, read either way.
    public let messageId: Int64?

    /// ``StreamPhase/completed`` only: the stored message's real seq in ``conversationId``.
    public let seq: Int64?

    /// ``StreamPhase/aborted`` only.
    public let abortReason: String?

    /// ``StreamPhase/begin`` only, when the producer gave one.
    public let placeholder: [String: JSONValue]?

    public init(
        streamId: String,
        conversationId: String,
        senderId: String,
        index: Int,
        delta: String? = nil,
        done: Bool = false,
        messageId: Int64? = nil,
        seq: Int64? = nil,
        abortReason: String? = nil,
        placeholder: [String: JSONValue]? = nil
    ) {
        self.streamId = streamId
        self.conversationId = conversationId
        self.senderId = senderId
        self.index = index
        self.delta = delta
        self.done = done
        self.messageId = messageId
        self.seq = seq
        self.abortReason = abortReason
        self.placeholder = placeholder
    }

    /// Done with a message id is ``StreamPhase/completed``, done without one ``StreamPhase/aborted``.
    public var phase: StreamPhase {
        if done, messageId != nil { return .completed }
        if done { return .aborted }
        if index <= 0 { return .begin }
        return .delta
    }

    /// The `data` of an `evt.stream` frame — or `nil` when it is not one this build can read (not an
    /// object, or no stream id). Read by hand and never throws: a frame of an unexpected shape must
    /// not stop the stream every later frame arrives on.
    static func fromData(_ data: JSONValue?) -> StreamEvent? {
        guard case let .object(frame)? = data,
              case let .string(streamId)? = frame["streamId"],
              !streamId.isEmpty
        else {
            return nil
        }

        return StreamEvent(
            streamId: streamId,
            conversationId: frame["conversationId"]?.stringValue ?? "",
            senderId: frame["senderId"]?.stringValue ?? "",
            index: StreamEvent.integer(frame["index"]).flatMap { Int(exactly: $0) } ?? 0,
            delta: frame["delta"]?.stringValue,
            done: frame["done"]?.boolValue ?? false,
            // The server writes the id as a string (it passes 2^53); an older one wrote a number.
            // 服务端把 id 写成字符串（它超过 2^53）；更早的版本写数字。两种都读。
            messageId: StreamEvent.integer(frame["messageId"]),
            seq: StreamEvent.integer(frame["seq"]),
            abortReason: frame["abortReason"]?.stringValue,
            placeholder: frame["placeholder"]?.objectValue
        )
    }

    /// A JSON integer, or a string holding one — never through a `Double` that could round it, and
    /// never a trap on a value out of range.
    private static func integer(_ value: JSONValue?) -> Int64? {
        switch value {
        case let .int(number)?:
            return number
        case let .string(text)?:
            return Int64(text)
        case let .double(number)?:
            return Int64(exactly: number)
        default:
            return nil
        }
    }
}

// MARK: - Assembling

/// Where an ``AssembledStream`` stands.
public enum StreamStatus: Sendable, Hashable {
    /// Opened, not finished.
    case streaming

    /// Became the stored message ``AssembledStream/messageId``; swap the placeholder for it.
    case completed

    /// Ended without a message; ``AssembledStream/abortReason`` says why. Nothing will arrive.
    case aborted
}

/// One stream as a receiver should draw it, built by ``StreamAssembler`` from its `evt.stream`
/// frames.
///
/// ``text`` is **for display while the stream runs**. The stored message is the truth: when it
/// arrives on ``ImClient/messages()`` — matched by ``messageId`` once the terminal frame has named it
/// — draw that instead. It can differ from ``text``: the producer may complete with content that
/// replaces the pieces, and a piece that never reached this device is in the stored message and not
/// in ``text``.
///
/// text 只用于流进行时的显示；存下来的那条消息才是准的——按 messageId 匹配到之后换成它。两者可能不同：
/// 生产者收尾时可以给出替换分片的 content，没到这台设备的分片在消息里而不在 text 里。
public struct AssembledStream: Sendable, Hashable, Identifiable {
    public let streamId: String
    public let conversationId: String
    public let senderId: String

    /// From the opening frame; `nil` if the producer gave none or this device missed the opening.
    public let placeholder: [String: JSONValue]?

    /// The pieces joined in index order, **up to the first missing one**. A later piece is held back
    /// rather than appended past a hole, and joins the text if the missing piece turns up.
    public let text: String

    public let status: StreamStatus

    /// Every frame up to the newest one this device has seen arrived — the opening included. False
    /// after a shed piece or a mid-stream join: ``text`` is incomplete and nothing will complete it
    /// but the stored message.
    public let intact: Bool

    /// ``StreamStatus/completed`` only.
    public let messageId: Int64?

    /// ``StreamStatus/completed`` only.
    public let seq: Int64?

    /// ``StreamStatus/aborted`` only.
    public let abortReason: String?

    public var id: String { streamId }
}

/// Turns `evt.stream` frames into the streams a receiver draws — the pieces joined by index, the
/// terminal frame read as completed or aborted — and holds to the server's rules while doing it:
///
/// - **Pieces are joined by ``StreamEvent/index``, not by arrival.** A duplicate is ignored; a piece
///   that arrives ahead of a missing one waits, and ``AssembledStream/text`` stops at the hole.
/// - **A hole is never repaired.** Nothing can resend a piece. The stream is marked not
///   ``AssembledStream/intact`` and keeps going; the stored message is what fixes it.
/// - **A mid-stream join is accepted**, not dropped: the first frame seen opens the stream, marked
///   not intact.
/// - **A terminal frame finishes the stream for good.** A piece or a second terminal frame arriving
///   after it is ignored, and so is a frame for a stream finished recently (the last 256).
///
/// A value type: feed it from one task, as `AsyncStream.assemble()` does. Streams whose
/// terminal frame this device never sees — it was offline when the producer stopped — stay
/// ``StreamStatus/streaming``; call ``clear()`` when the connection comes back, since every stream in
/// flight across a disconnect will be settled by the stored message or not at all.
///
/// 按 index 拼，不按到达顺序：重复的丢掉，越过缺口到来的先等着，text 停在缺口处。缺口不补，只标记 intact = false；
/// 中途加入照样接收；终止帧之后到来的任何帧都忽略。值类型，在一个任务里喂它。断线重连后调 clear()。
public struct StreamAssembler: Sendable {
    private struct Live: Sendable {
        let streamId: String
        var conversationId: String
        var senderId: String
        var placeholder: [String: JSONValue]? = nil
        var opened = false

        /// Pieces received ahead of a missing one, by index.
        var pieces: [Int: String] = [:]
        var text = ""

        /// The highest index joined into ``text``: every index from 1 to here is present.
        var joined = 0
        var newest = 0
    }

    /// Finished stream ids remembered so a straggling frame cannot reopen one.
    static let finishedMemory = 256

    private var live: [String: Live] = [:]

    /// ``live``'s keys, oldest first.
    private var order: [String] = []

    private var finished: Set<String> = []

    /// ``finished``'s members, oldest first, so the oldest is the one forgotten.
    private var finishedOrder: [String] = []

    public init() {}

    /// The streams still running, oldest first.
    public var active: [AssembledStream] {
        order.compactMap { streamId in
            live[streamId].map { StreamAssembler.snapshot($0, .streaming, nil) }
        }
    }

    /// The running stream `streamId`, or `nil`.
    public subscript(streamId: String) -> AssembledStream? {
        live[streamId].map { StreamAssembler.snapshot($0, .streaming, nil) }
    }

    /// Applies one frame and returns the stream as it now stands, or `nil` when the frame changed
    /// nothing (a duplicate, or a frame for a stream already finished).
    @discardableResult
    public mutating func accept(_ event: StreamEvent) -> AssembledStream? {
        if finished.contains(event.streamId) { return nil }

        if live[event.streamId] == nil {
            order.append(event.streamId)
        }
        var stream = live[event.streamId]
            ?? Live(streamId: event.streamId, conversationId: event.conversationId, senderId: event.senderId)
        if stream.conversationId.isEmpty { stream.conversationId = event.conversationId }
        if stream.senderId.isEmpty { stream.senderId = event.senderId }

        switch event.phase {
        case .begin:
            guard !stream.opened else {
                live[event.streamId] = stream
                return nil
            }
            stream.opened = true
            stream.placeholder = event.placeholder

        case .delta:
            guard event.index > stream.joined, stream.pieces[event.index] == nil else {
                live[event.streamId] = stream
                return nil
            }
            stream.pieces[event.index] = event.delta ?? ""
            stream.newest = max(stream.newest, event.index)
            while true {
                let nextIndex = stream.joined + 1
                guard let next = stream.pieces.removeValue(forKey: nextIndex) else { break }
                stream.text += next
                stream.joined = nextIndex
            }

        case .completed, .aborted:
            live.removeValue(forKey: event.streamId)
            order.removeAll { $0 == event.streamId }
            remember(event.streamId)
            // The terminal index is one past the last piece, so it says how many there were.
            stream.newest = max(stream.newest, event.index - 1)
            let status: StreamStatus = event.phase == .completed ? .completed : .aborted
            return StreamAssembler.snapshot(stream, status, event)
        }

        live[event.streamId] = stream
        return StreamAssembler.snapshot(stream, .streaming, nil)
    }

    /// Stops tracking `streamId`. A later frame for it opens it again, as a mid-stream join.
    public mutating func remove(_ streamId: String) {
        live.removeValue(forKey: streamId)
        order.removeAll { $0 == streamId }
    }

    /// Drops every running stream. Call it when the connection comes back.
    public mutating func clear() {
        live.removeAll()
        order.removeAll()
    }

    private mutating func remember(_ streamId: String) {
        guard finished.insert(streamId).inserted else { return }

        finishedOrder.append(streamId)
        if finishedOrder.count > StreamAssembler.finishedMemory {
            let forgotten = finishedOrder.removeFirst()
            finished.remove(forgotten)
        }
    }

    private static func snapshot(_ stream: Live, _ status: StreamStatus, _ terminal: StreamEvent?) -> AssembledStream {
        AssembledStream(
            streamId: stream.streamId,
            conversationId: stream.conversationId,
            senderId: stream.senderId,
            placeholder: stream.placeholder,
            text: stream.text,
            status: status,
            intact: stream.opened && stream.joined >= stream.newest,
            messageId: terminal?.messageId,
            seq: terminal?.seq,
            abortReason: terminal?.abortReason
        )
    }
}

extension AsyncStream where Element == StreamEvent {
    /// Assembles a stream of `evt.stream` frames — ``ImClient/streamEvents()`` — with a
    /// ``StreamAssembler`` of its own per call, yielding each stream every time it changes.
    ///
    /// ```swift
    /// for await stream in im.streamEvents().assemble() { render(stream) }
    /// ```
    public func assemble() -> AsyncStream<AssembledStream> {
        let events = self

        return AsyncStream<AssembledStream>(bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                var assembler = StreamAssembler()
                for await event in events {
                    if let stream = assembler.accept(event) {
                        continuation.yield(stream)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

// MARK: - Producing

/// One stream from the producer's side: ``begin(_:_:)`` it, ``append(_:)`` pieces, then
/// ``complete(content:extensions:)`` or ``abort(reason:)``.
///
/// A convenience over the four ``ImMsgNamespace`` calls, which remain the surface — it holds the
/// ``handle`` and the ``clientMsgId`` the stream was opened with so the caller does not have to.
///
/// ```swift
/// let reply = try await StreamWriter.begin(im.msg, BeginStreamRequest(receiverId: "u_bob"))
/// do {
///     for try await token in model.generate(prompt) { try await reply.append(token) }
///     try await reply.complete()
/// } catch {
///     try? await reply.abort(reason: "the model failed")
///     throw error
/// }
/// ```
///
/// 生产者一侧的便利封装：begin → append* → complete | abort。四个 ImMsgNamespace 调用才是正式的表面。
public struct StreamWriter: Sendable {
    private let msg: ImMsgNamespace

    /// What `msg.streamBegin` answered.
    public let handle: StreamHandle

    /// The idempotency key of the message this stream becomes.
    public let clientMsgId: String

    public var streamId: String { handle.streamId }

    private init(msg: ImMsgNamespace, handle: StreamHandle, clientMsgId: String) {
        self.msg = msg
        self.handle = handle
        self.clientMsgId = clientMsgId
    }

    /// Sends `msg.streamBegin`, filling a blank ``BeginStreamRequest/clientMsgId`` first.
    public static func begin(_ msg: ImMsgNamespace, _ request: BeginStreamRequest) async throws -> StreamWriter {
        let keyed = request.keyed()
        let handle = try await msg.streamBegin(keyed)
        return StreamWriter(msg: msg, handle: handle, clientMsgId: keyed.clientMsgId)
    }

    /// `msg.streamAppend` for this stream.
    public func append(_ delta: String) async throws {
        try await msg.streamAppend(StreamAppendRequest(streamId: streamId, delta: delta))
    }

    /// `msg.streamComplete` for this stream. `nil` content stores the pieces as `{"text": …}`.
    @discardableResult
    public func complete(
        content: [String: JSONValue]? = nil,
        extensions: [String: JSONValue]? = nil
    ) async throws -> SendMessageResult {
        try await msg.streamComplete(CompleteStreamRequest(streamId: streamId, content: content, extensions: extensions))
    }

    /// `msg.streamAbort` for this stream.
    public func abort(reason: String? = nil) async throws {
        try await msg.streamAbort(StreamAbortRequest(streamId: streamId, reason: reason))
    }
}
