using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im;
using Cyaim.Im.Json;
using Cyaim.Im.Threading;
using Cyaim.Im.Transport;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// A socket that never touches the network: the test drives both ends of it.
    /// </summary>
    /// <remarks>
    /// Everything the SDK does about reconnecting, kicks and gap repair is a reaction to what a
    /// socket did, so the only way to test it honestly is to be the socket. Combined with
    /// <see cref="ManualDispatcher"/> — whose clock the test turns by hand — every test below is
    /// deterministic and finishes in microseconds, with no sleeping and no real timing.
    /// </remarks>
    internal sealed class FakeTransport : IImTransport
    {
        private readonly List<Sent> _sent = new List<Sent>();
        private readonly HashSet<string> _answered = new HashSet<string>(StringComparer.Ordinal);
        private TaskCompletionSource<bool> _handshake;
        private bool _closeRaised;

        /// <summary>Set false to leave the handshake hanging until <see cref="CompleteHandshake"/>.</summary>
        internal bool AutoOpen = true;

        /// <summary>The URL the connection asked for, including the query string.</summary>
        internal Uri Url;

        /// <summary>True once <see cref="Abort"/> ran — the forced close a failed heartbeat causes.</summary>
        internal bool Aborted;

        /// <summary>True once <see cref="Close"/> ran — the polite close a client shutdown causes.</summary>
        internal bool PolitelyClosed;

        /// <summary>True once the connection released this socket.</summary>
        internal bool DisposeCalled;

        /// <inheritdoc/>
        public ImTransportState State { get; private set; }

        /// <inheritdoc/>
        public Action<string> TextReceived { get; set; }

        /// <inheritdoc/>
        public Action<ImTransportClose> Closed { get; set; }

        /// <inheritdoc/>
        public Task ConnectAsync(Uri url, CancellationToken cancellationToken)
        {
            Url = url;
            State = ImTransportState.Connecting;
            _handshake = new TaskCompletionSource<bool>();

            if (AutoOpen)
            {
                CompleteHandshake();
            }

            return _handshake.Task;
        }

        /// <inheritdoc/>
        public void Send(string payload)
        {
            var frame = JsonValue.Parse(payload);
            _sent.Add(new Sent(frame["id"].AsString(string.Empty), frame["target"].AsString(string.Empty), frame["body"]));
        }

        /// <inheritdoc/>
        public void Close(int code, string reason)
        {
            PolitelyClosed = true;
            State = ImTransportState.Closed;
            RaiseClosed(new ImTransportClose(code, reason));
        }

        /// <inheritdoc/>
        public void Abort()
        {
            Aborted = true;
            State = ImTransportState.Closed;
            RaiseClosed(new ImTransportClose(1006, string.Empty));
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            DisposeCalled = true;
        }

        /// <summary>Lets a deferred handshake succeed.</summary>
        internal void CompleteHandshake()
        {
            State = ImTransportState.Open;
            _handshake.TrySetResult(true);
        }

        /// <summary>The server (or the network) ends this socket. Empty reason means a network failure.</summary>
        internal void ServerCloses(int code, string reason)
        {
            State = ImTransportState.Closed;
            RaiseClosed(new ImTransportClose(code, reason));
        }

        /// <summary>Delivers a raw frame to the client.</summary>
        internal void Deliver(string json)
        {
            var handler = TextReceived;
            if (handler != null)
            {
                handler(json);
            }
        }

        /// <summary>Requests this socket was asked to send, oldest first.</summary>
        internal IList<Sent> Requests
        {
            get { return _sent; }
        }

        /// <summary>How many requests were sent for an endpoint.</summary>
        internal int CountOf(string target)
        {
            int count = 0;
            for (int i = 0; i < _sent.Count; i++)
            {
                if (string.Equals(_sent[i].Target, target, StringComparison.OrdinalIgnoreCase))
                {
                    count++;
                }
            }

            return count;
        }

        /// <summary>True when a request for this endpoint is on the wire with no reply yet.</summary>
        internal bool HasUnanswered(string target)
        {
            return FindOldestUnanswered(target) != null;
        }

        /// <summary>The newest request body for an endpoint, or null if it was never asked for.</summary>
        internal JsonValue LastBody(string target)
        {
            var request = FindLast(target, false);
            return request == null ? null : request.Body;
        }

        /// <summary>Replies to the oldest unanswered request for an endpoint.</summary>
        internal void Reply(string target, JsonValue data, int code = 0, string traceId = null)
        {
            var request = FindOldestUnanswered(target);
            if (request == null)
            {
                throw new InvalidOperationException("no unanswered " + target + " request to reply to");
            }

            _answered.Add(request.Id);
            Deliver(ImFrames.Reply(request.Id, target, data, code, traceId));
        }

        /// <summary>
        /// Replies to the oldest unanswered request for an endpoint whose body matches — needed
        /// when two conversations have a repair in flight at the same time.
        /// </summary>
        internal void ReplyMatching(string target, Func<JsonValue, bool> predicate, JsonValue data, int code = 0)
        {
            for (int i = 0; i < _sent.Count; i++)
            {
                var request = _sent[i];
                if (!string.Equals(request.Target, target, StringComparison.OrdinalIgnoreCase) ||
                    _answered.Contains(request.Id) ||
                    !predicate(request.Body))
                {
                    continue;
                }

                _answered.Add(request.Id);
                Deliver(ImFrames.Reply(request.Id, target, data, code, null));
                return;
            }

            throw new InvalidOperationException("no matching unanswered " + target + " request to reply to");
        }

        /// <summary>Replies with a transport-level failure: the endpoint threw, or does not exist.</summary>
        internal void ReplyTransportError(string target, int status, string message)
        {
            var request = FindOldestUnanswered(target);
            if (request == null)
            {
                throw new InvalidOperationException("no unanswered " + target + " request to reply to");
            }

            _answered.Add(request.Id);

            var frame = JsonValue.NewObject()
                .Set("id", request.Id)
                .Set("target", target)
                .Set("status", (long)status)
                .Set("msg", message);

            Deliver(frame.ToJson());
        }

        private Sent FindOldestUnanswered(string target)
        {
            for (int i = 0; i < _sent.Count; i++)
            {
                if (string.Equals(_sent[i].Target, target, StringComparison.OrdinalIgnoreCase) &&
                    !_answered.Contains(_sent[i].Id))
                {
                    return _sent[i];
                }
            }

            return null;
        }

        private Sent FindLast(string target, bool unansweredOnly)
        {
            for (int i = _sent.Count - 1; i >= 0; i--)
            {
                if (!string.Equals(_sent[i].Target, target, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (unansweredOnly && _answered.Contains(_sent[i].Id))
                {
                    continue;
                }

                return _sent[i];
            }

            return null;
        }

        private void RaiseClosed(ImTransportClose close)
        {
            if (_closeRaised)
            {
                return;
            }

            _closeRaised = true;

            var handler = Closed;
            if (handler != null)
            {
                handler(close);
            }
        }

        /// <summary>One request the client put on the wire.</summary>
        internal sealed class Sent
        {
            internal readonly string Id;
            internal readonly string Target;
            internal readonly JsonValue Body;

            internal Sent(string id, string target, JsonValue body)
            {
                Id = id;
                Target = target;
                Body = body;
            }
        }
    }

    /// <summary>Frames as the gateway would serialise them.</summary>
    internal static class ImFrames
    {
        internal static string Reply(string id, string target, JsonValue data, int code = 0, string traceId = null)
        {
            var body = JsonValue.NewObject()
                .Set("code", (long)code)
                .Set("serverTime", 1767225600000L)
                .Set("traceId", traceId)
                .Set("data", data != null ? data : JsonValue.Null);

            if (code != 0)
            {
                body.Set("message", "the server said no");
            }

            return JsonValue.NewObject()
                .Set("id", id)
                .Set("target", target)
                .Set("status", 0L)
                .Set("body", body)
                .ToJson();
        }

        internal static string Push(string target, JsonValue data)
        {
            var body = JsonValue.NewObject()
                .Set("code", 0L)
                .Set("serverTime", 1767225600000L)
                .Set("data", data != null ? data : JsonValue.Null);

            return JsonValue.NewObject()
                .Set("id", "srv-" + Guid.NewGuid().ToString("N"))
                .Set("target", target)
                .Set("status", 0L)
                .Set("body", body)
                .ToJson();
        }

        /// <summary>A message push, with only the fields these tests care about filled in.</summary>
        internal static string Message(string conversationId, long seq, string text = null)
        {
            var content = JsonValue.NewObject()
                .Set("text", text != null ? text : "message " + seq.ToString(CultureInfo.InvariantCulture));

            var message = MessageJson(conversationId, seq, content);
            return Push(ImPushTarget.Message, message);
        }

        /// <summary>One row of a <c>conn.sync</c> or <c>conv.list</c> page.</summary>
        internal static JsonValue Conversation(string conversationId, long maxSeq, long updatedAt)
        {
            return JsonValue.NewObject()
                .Set("conversationId", conversationId)
                .Set("type", 1L)
                .Set("maxSeq", maxSeq)
                .Set("readSeq", 0L)
                .Set("unreadCount", 0L)
                .Set("updatedAt", updatedAt);
        }

        /// <summary>A <c>conn.sync</c> reply payload.</summary>
        internal static JsonValue ResumePage(
            JsonValue conversations = null,
            JsonValue gapsFrom = null,
            bool hasMore = false,
            string nextCursor = null)
        {
            return JsonValue.NewObject()
                .Set("conversations", conversations != null ? conversations : JsonValue.NewArray())
                .Set("gapsFrom", gapsFrom != null ? gapsFrom : JsonValue.NewObject())
                .Set("hasMore", hasMore)
                .Set("nextCursor", nextCursor)
                .Set("serverTime", 1767225600000L);
        }

        /// <summary>
        /// A <c>msg.sync</c> reply payload, with <c>hasMore</c> under the test's control.
        /// </summary>
        /// <remarks>
        /// Separating <c>hasMore</c> from the message count is deliberate: the server computes it on
        /// the raw window before per-user hidden rows are filtered out, so a short — even empty —
        /// page with more to come is the ordinary case and the one clients get wrong.
        /// </remarks>
        internal static JsonValue SyncPage(string conversationId, bool hasMore, long maxSeq, params long[] seqs)
        {
            var array = JsonValue.NewArray();
            for (int i = 0; i < seqs.Length; i++)
            {
                array.Add(MessageJson(conversationId, seqs[i]));
            }

            return JsonValue.NewObject()
                .Set("conversationId", conversationId)
                .Set("messages", array)
                .Set("maxSeq", maxSeq)
                .Set("minSeq", 1L)
                .Set("hasMore", hasMore);
        }

        internal static JsonValue MessageJson(string conversationId, long seq, JsonValue content = null)
        {
            return JsonValue.NewObject()
                .Set("appId", "app")
                .Set("conversationId", conversationId)
                .Set("conversationType", 1L)
                .Set("seq", seq)
                .Set("messageId", 9007199254740993L + seq)
                .Set("clientMsgId", "srv-" + seq.ToString(CultureInfo.InvariantCulture))
                .Set("senderId", "bob")
                .Set("contentType", 1L)
                .Set("content", content != null
                    ? content
                    : JsonValue.NewObject().Set("text", "message " + seq.ToString(CultureInfo.InvariantCulture)))
                .Set("sendTime", 1767225600000L)
                .Set("createTime", 1767225600000L);
        }
    }

    /// <summary>
    /// A cursor store the test can seed, break, and count writes on.
    /// </summary>
    /// <remarks>
    /// Counting the writes is the point of the class. Several rules in <c>sdk/CONTRACT.md</c> §5 are
    /// about <i>when</i> a snapshot reaches the store rather than what is in it — adoption must be
    /// flushed before the next <c>conn.sync</c> page goes out, ordinary commits may be coalesced —
    /// and neither is observable from the wire.
    /// </remarks>
    internal sealed class RecordingCursorStore : IImCursorStore
    {
        private ImCursorSnapshot _stored = new ImCursorSnapshot();

        /// <summary>Set to make <see cref="Load"/> throw, standing in for a corrupt file.</summary>
        internal bool FailLoad;

        /// <summary>How many times the SDK has asked to read.</summary>
        internal int Loads;

        /// <summary>How many times the SDK has asked to write.</summary>
        internal int Saves;

        /// <summary>
        /// Stamps the stored snapshot with an account identity, as a previous run of the app would
        /// have left it. The SDK compares it against this session's scope and refuses a mismatch.
        /// </summary>
        internal RecordingCursorStore Stamp(string scopeKey)
        {
            _stored.Scope = scopeKey;
            return this;
        }

        /// <summary>Pre-loads a committed cursor, as a previous run of the app would have left it.</summary>
        internal RecordingCursorStore Seed(string conversationId, long seq)
        {
            _stored.ConvSeqs[conversationId] = seq;
            return this;
        }

        /// <summary>Pre-loads the conversation-list cursor.</summary>
        internal RecordingCursorStore SeedConversationCursor(long updatedAt)
        {
            _stored.ConversationCursor = updatedAt;
            return this;
        }

        /// <summary>What is on "disk" right now.</summary>
        internal ImCursorSnapshot Stored
        {
            get { return _stored.Clone(); }
        }

        /// <summary>Committed seq currently persisted for a conversation, or 0.</summary>
        internal long StoredSeq(string conversationId)
        {
            long seq;
            return _stored.ConvSeqs.TryGetValue(conversationId, out seq) ? seq : 0;
        }

        public ImCursorSnapshot Load()
        {
            Loads++;

            if (FailLoad)
            {
                throw new InvalidOperationException("the cursor file is unreadable");
            }

            return _stored.Clone();
        }

        public void Save(ImCursorSnapshot snapshot)
        {
            Saves++;
            _stored = snapshot.Clone();
        }
    }

    /// <summary>A backoff with no randomness, so a reconnect lands at a time the test chose.</summary>
    /// <remarks>
    /// Never ship this. It exists so a reconnect test can advance a virtual clock by exactly one
    /// delay; the randomness it removes is the entire point of the real policy, which is tested on
    /// its own in <c>FullJitterBackoffTests</c>.
    /// </remarks>
    internal sealed class FixedBackoff : IReconnectBackoff
    {
        private readonly TimeSpan _delay;

        internal FixedBackoff(TimeSpan delay)
        {
            _delay = delay;
        }

        internal int Attempts { get; private set; }

        public TimeSpan NextDelay(int attempt)
        {
            Attempts++;
            return _delay;
        }
    }

    /// <summary>
    /// A client wired to a hand-driven clock and a hand-driven socket, plus the log capture that
    /// keeps SDK diagnostics out of the test runner's console.
    /// </summary>
    internal sealed class ImTestHarness : IDisposable
    {
        internal static readonly TimeSpan ReconnectDelay = TimeSpan.FromMilliseconds(100);

        private readonly ImLogLevel _previousLevel;
        private readonly Action<ImLogLevel, string, Exception> _previousSink;
        private readonly List<FakeTransport> _transports = new List<FakeTransport>();

        internal readonly ManualDispatcher Dispatcher = new ManualDispatcher();
        internal readonly FixedBackoff Backoff = new FixedBackoff(ReconnectDelay);
        internal readonly List<string> Log = new List<string>();
        internal readonly ImClientOptions Options;
        internal readonly ImClient Client;

        /// <summary>The store the client was built with. A <see cref="RecordingCursorStore"/> unless
        /// the test supplied its own.</summary>
        internal readonly IImCursorStore CursorStore;

        /// <summary>Tokens the client asked for, in order. Empty when it never had to.</summary>
        internal readonly List<string> TokenRequests = new List<string>();

        /// <summary>What <see cref="ImConnectionOptions.TokenProvider"/> returns. Null refuses.</summary>
        internal string NextToken = "token-2";

        /// <summary>Set false to make new sockets hang in the handshake instead of opening.</summary>
        internal bool AutoOpenSockets = true;

        internal ImTestHarness(
            Action<ImClientOptions> configure = null,
            IImCursorStore cursorStore = null,
            string userId = "alice")
        {
            _previousLevel = ImLog.Level;
            _previousSink = ImLog.Sink;

            CursorStore = cursorStore != null ? cursorStore : new RecordingCursorStore();

            // Captured rather than printed: the SDK logs a warning on every failed repair and the
            // test runner treats an unexpected console error as a failed test.
            ImLog.Level = ImLogLevel.Verbose;
            ImLog.Sink = delegate(ImLogLevel level, string message, Exception error)
            {
                Log.Add(level + " " + message);
            };

            Options = new ImClientOptions(CursorStore, userId)
            {
                Endpoint = "wss://im.test",
                AppId = "app",
                Token = "token-1",
                DeviceId = "device-1",
                Platform = ImPlatform.Windows,
                Dispatcher = Dispatcher,
                Backoff = Backoff,
                RequestTimeout = TimeSpan.FromSeconds(15),
                ConnectTimeout = TimeSpan.FromSeconds(30),

                // Write through on every commit. The debounce is worth a test of its own, but
                // making every other test advance a clock to see a cursor land would hide what
                // those tests are actually about.
                CursorFlushInterval = TimeSpan.Zero,
            };

            Options.TransportFactory = delegate
            {
                var transport = new FakeTransport();
                transport.AutoOpen = AutoOpenSockets;
                _transports.Add(transport);
                return transport;
            };

            Options.TokenProvider = delegate(CancellationToken token)
            {
                TokenRequests.Add(NextToken);
                return Task.FromResult(NextToken);
            };

            if (configure != null)
            {
                configure(Options);
            }

            Client = new ImClient(Options);
        }

        /// <summary>Every socket the connection has created, oldest first.</summary>
        internal IList<FakeTransport> Transports
        {
            get { return _transports; }
        }

        /// <summary>The socket currently in use.</summary>
        internal FakeTransport Socket
        {
            get { return _transports.Count == 0 ? null : _transports[_transports.Count - 1]; }
        }

        /// <summary>
        /// Marks a task as deliberately unobserved. Tests that start a request and never answer it
        /// leave a faulted task behind when the harness closes the connection, and an unobserved
        /// faulted task can surface later as a console error in an unrelated test.
        /// </summary>
        internal static void Forget(Task task)
        {
            task.ContinueWith(
                delegate(Task completed) { var ignored = completed.Exception; },
                TaskContinuationOptions.OnlyOnFaulted);
        }

        /// <summary>
        /// A plain text <c>msg.send</c> request. There is no <c>Msg.SendTextAsync</c> to call:
        /// <c>msg.sendText</c> is not an endpoint, so the typed surface does not invent one
        /// (<c>sdk/CONTRACT.md</c> §4.2).
        /// </summary>
        internal static ImSendRequest TextMessage(ImRecipient recipient, string text)
        {
            return new ImSendRequest
            {
                Recipient = recipient,
                ContentType = ImMessageContentType.Text,
                Content = JsonValue.NewObject().Set("text", text),
            };
        }

        /// <summary>Runs everything queued, without moving the clock.</summary>
        internal void Pump()
        {
            Dispatcher.PumpUntilIdle();
        }

        /// <summary>Moves the virtual clock forward and runs whatever that made due.</summary>
        internal void Advance(TimeSpan delta)
        {
            Dispatcher.Advance(delta);
        }

        /// <summary>Connects, and by default answers the resume that every open triggers.</summary>
        internal void Connect(bool answerResume = true)
        {
            var connecting = Client.ConnectAsync();
            Pump();

            if (!connecting.IsCompleted)
            {
                throw new InvalidOperationException("the fake socket did not open");
            }

            if (answerResume)
            {
                AnswerResume();
            }

            AnswerHousekeeping();
        }

        /// <summary>
        /// Answers the housekeeping a connect triggers besides the resume — today that is the one
        /// <c>diag.logRequests</c> pull ADR-003 makes after every connect.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Unanswered, that pull sits in the correlation map until it times out, and any test that
        /// counts pending requests is then counting it too. That is exactly how
        /// <c>Cancelling_abandons_the_reply_and_leaves_no_entry_behind</c> read "2" where the
        /// contract (§10.21) says the map holds only the call under test — a wrong reading of a
        /// correct SDK, produced by a harness that answered half of what a connect asks.
        /// 未被答复时，这条拉取会一直待在关联表里直到超时，于是任何数 pending 的用例都把它一起数了。
        /// </para>
        /// <para>
        /// An empty list is the answer in every test here, because a test that wanted a log request
        /// would say so itself. The Swift harness answers the same set for the same reason
        /// (<c>MockGateway.answerHousekeeping</c>); this is that, in Unity's shape.
        /// 空列表是这里每个用例的答案——想要别的答案的用例会自己说。Swift 的 harness 出于同样理由
        /// 答复同一组端点。
        /// </para>
        /// </remarks>
        internal void AnswerHousekeeping()
        {
            if (!Socket.HasUnanswered("diag.logRequests"))
            {
                return;
            }

            Socket.Reply("diag.logRequests", JsonValue.NewArray());
            Pump();
        }

        /// <summary>Answers the <c>conn.sync</c> the client sends on every (re)connect.</summary>
        internal void AnswerResume(JsonValue result = null)
        {
            Socket.Reply("conn.sync", result != null
                ? result
                : JsonValue.NewObject()
                    .Set("conversations", JsonValue.NewArray())
                    .Set("gapsFrom", JsonValue.NewObject()));

            Pump();
        }

        /// <summary>Delivers a message push and runs the delivery it triggers.</summary>
        internal void PushMessage(string conversationId, long seq, string text = null)
        {
            Socket.Deliver(ImFrames.Message(conversationId, seq, text));
            Pump();
        }

        /// <summary>Stands in for the application storing a message and saying so.</summary>
        internal void Commit(string conversationId, long seq)
        {
            Client.Commit(conversationId, seq);
            Pump();
        }

        /// <summary>Drops the socket and lets the reconnect land, without answering the resume.</summary>
        internal void Reconnect()
        {
            Socket.ServerCloses(1006, string.Empty);
            Pump();
            Advance(ReconnectDelay);
        }

        /// <summary>The body of the newest <c>conn.sync</c> the client sent.</summary>
        internal JsonValue LastResume
        {
            get { return Socket.LastBody("conn.sync"); }
        }

        public void Dispose()
        {
            Client.Dispose();
            Pump();

            ImLog.Level = _previousLevel;
            ImLog.Sink = _previousSink;
        }
    }
}
