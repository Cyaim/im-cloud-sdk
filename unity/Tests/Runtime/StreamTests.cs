using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// <c>msg.streamBegin</c> / <c>streamAppend</c> / <c>streamComplete</c> / <c>streamAbort</c>, the
    /// <c>evt.stream</c> push, the assembly of its pieces, and the rule an integrator cannot guess: the
    /// pieces are not messages, and the completed stream is.
    /// </summary>
    /// <remarks>
    /// Every call is asserted on the frame it puts on the wire — target and the whole body, by JSON kind,
    /// nested <c>options</c> and <c>options.pushConfig</c> included, because the binder matches those keys
    /// case-sensitively and drops a miscased one without a word. The assembly is driven through every
    /// order the server can produce: its per-connection queue sends normal frames (the opening, the
    /// terminal frame, the stored message) ahead of queued low ones (the pieces).
    /// 每个调用都断言整帧（含嵌套 options / pushConfig）；拼装按服务端可能产生的每种顺序驱动——
    /// 每连接队列先发普通帧（开流帧、终帧、最终消息），再发排队的低优先级分片。
    /// </remarks>
    public sealed class StreamTests
    {
        private const string Conversation = "s_alice_bob";

        private const string StreamId = "st_360381357961969700";

        private ImTestHarness _harness;
        private List<ImMessage> _delivered;
        private List<ImStreamEvent> _events;

        [SetUp]
        public void SetUp()
        {
            _harness = new ImTestHarness();
            _delivered = new List<ImMessage>();
            _events = new List<ImStreamEvent>();
            _harness.Client.MessageReceived += _delivered.Add;
            _harness.Client.OnStreamEvent(_events.Add);
            _harness.Connect();
        }

        [TearDown]
        public void TearDown()
        {
            _harness.Dispose();
        }

        // ------------------------------------------------------------------ fixtures

        private static ImMessageOptions FullOptions()
        {
            return new ImMessageOptions
            {
                Persistent = false,
                UpdateConversation = false,
                CountUnread = false,
                OfflinePush = false,
                PushConfig = new ImPushConfig
                {
                    Title = "Assistant",
                    Body = "is replying",
                    Sound = "ding.caf",
                    Payload = new Dictionary<string, string> { { "deepLink", "app://s_alice_bob" } },
                    BadgeCount = false,
                    ChannelId = "im_messages",
                },
                NeedReceipt = true,
                Priority = ImMessagePriority.High,
                OnlineOnly = true,
                NoSelfSync = true,
                ExpireIn = 5000L,
                ModerationBypass = true,
            };
        }

        private static ImBeginStreamRequest FullBegin(ImRecipient recipient)
        {
            return new ImBeginStreamRequest(recipient)
            {
                ClientMsgId = "cm-stream",
                ContentType = ImMessageContentType.Custom,
                Placeholder = JsonValue.NewObject().Set("name", "Assistant").Set("avatar", "bots/a.png"),
                Options = FullOptions(),
                Extensions = JsonValue.NewObject().Set("model", "m-1"),
            };
        }

        private static JsonValue Handle()
        {
            return JsonValue.NewObject()
                .Set("streamId", StreamId)
                .Set("conversationId", Conversation)
                .Set("startedAt", 1767225600123L)
                .Set("idleTimeoutSeconds", 30L);
        }

        private static JsonValue SendResult(long seq)
        {
            return JsonValue.NewObject()
                .Set("messageId", "360381357961969667")
                .Set("seq", seq)
                .Set("conversationId", Conversation)
                .Set("clientMsgId", "cm-stream")
                .Set("createTime", 1767225601000L)
                .Set("deduplicated", true)
                .Set("contentModified", true);
        }

        private static JsonValue Frame(string streamId, int index)
        {
            return JsonValue.NewObject()
                .Set("streamId", streamId)
                .Set("conversationId", Conversation)
                .Set("senderId", "u_alice")
                .Set("index", (long)index);
        }

        private static JsonValue BeginFrame(string streamId = StreamId, bool placeholder = true)
        {
            var frame = Frame(streamId, 0).Set("done", false);
            if (placeholder)
            {
                frame.Set("placeholder", JsonValue.NewObject().Set("name", "Assistant"));
            }

            return frame;
        }

        private static JsonValue DeltaFrame(int index, string delta, string streamId = StreamId)
        {
            return Frame(streamId, index).Set("delta", delta).Set("done", false);
        }

        /// <summary>The server writes the id with <c>WriteAsString</c>: a quoted snowflake past 2^53.</summary>
        private static JsonValue CompletedFrame(int index, long seq, string streamId = StreamId)
        {
            return Frame(streamId, index).Set("done", true).Set("messageId", "360381357961969667").Set("seq", seq);
        }

        private static JsonValue AbortedFrame(int index, string reason, string streamId = StreamId)
        {
            return Frame(streamId, index).Set("done", true).Set("abortReason", reason);
        }

        /// <summary>The stored message, as <c>evt.message</c> carries it to everyone — the producer too.</summary>
        private static JsonValue StoredMessage(long seq, string text)
        {
            return ImFrames.MessageJson(Conversation, seq, JsonValue.NewObject().Set("text", text))
                .Set("messageId", "360381357961969667")
                .Set("clientMsgId", "cm-stream")
                .Set("senderId", "u_alice");
        }

        private void Push(JsonValue data)
        {
            _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Stream, data));
            _harness.Pump();
        }

        private void PushStored(long seq, string text)
        {
            _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Message, StoredMessage(seq, text)));
            _harness.Pump();
        }

        private static ImStreamEvent Event(JsonValue data)
        {
            var decoded = ImPayload.Read<ImStreamEvent>(data);
            Assert.That(decoded.StreamId, Is.Not.Empty);
            return decoded;
        }

        // ------------------------------------------------------------------ helpers

        private T Answered<T>(Task<T> pending, string target, JsonValue data)
        {
            _harness.Pump();
            _harness.Socket.Reply(target, data);
            _harness.Pump();

            Assert.That(pending.IsCompleted, Is.True, target + " did not complete");
            return pending.Result;
        }

        private JsonValue Acknowledged(Task pending, string target)
        {
            _harness.Pump();
            var body = _harness.Socket.LastBody(target);
            Assert.That(body, Is.Not.Null, target + " never reached the socket");

            _harness.Socket.Reply(target, JsonValue.Null);
            _harness.Pump();
            Assert.That(pending.IsCompleted && !pending.IsFaulted, Is.True, target + " did not succeed");
            return body;
        }

        private ImException Refused(Task pending, string target, int code)
        {
            _harness.Pump();
            _harness.Socket.Reply(target, JsonValue.Null, code);
            _harness.Pump();

            Assert.That(pending.IsFaulted, Is.True, target + " should have failed with " + code);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null);
            return error;
        }

        private static List<string> Keys(JsonValue body)
        {
            var keys = new List<string>();
            foreach (var member in body.Members)
            {
                keys.Add(member.Key);
            }

            keys.Sort(StringComparer.Ordinal);
            return keys;
        }

        private long[] Seqs()
        {
            var seqs = new long[_delivered.Count];
            for (var i = 0; i < _delivered.Count; i++)
            {
                seqs[i] = _delivered[i].Seq;
            }

            return seqs;
        }

        // ------------------------------------------------------------------ msg.streamBegin

        [Test]
        public void Begin_with_every_member_sends_each_in_the_servers_kind_nested_keys_included()
        {
            var handle = Answered(
                _harness.Client.Msg.StreamBeginAsync(FullBegin(ImRecipient.User("u_bob"))),
                "msg.streamBegin",
                Handle());

            var body = _harness.Socket.LastBody("msg.streamBegin");
            Assert.That(Keys(body), Is.EqualTo(new[]
            {
                "clientMsgId", "contentType", "extensions", "options", "placeholder", "receiverId",
            }));
            Assert.That(body["receiverId"].WireString(), Is.EqualTo("u_bob"));
            Assert.That(body["clientMsgId"].WireString(), Is.EqualTo("cm-stream"));
            Assert.That(body["contentType"].WireInt(), Is.EqualTo(100), "an enum member takes its integer");
            Assert.That(body["placeholder"]["name"].WireString(), Is.EqualTo("Assistant"));
            Assert.That(body["extensions"]["model"].WireString(), Is.EqualTo("m-1"));

            // Exact camelCase, both levels: the binder drops a nested key in any other case, silently.
            var options = body["options"];
            Assert.That(Keys(options), Is.EqualTo(new[]
            {
                "countUnread", "expireIn", "moderationBypass", "needReceipt", "noSelfSync", "offlinePush",
                "onlineOnly", "persistent", "priority", "pushConfig", "updateConversation",
            }));
            Assert.That(options["persistent"].WireBool(), Is.False);
            Assert.That(options["updateConversation"].WireBool(), Is.False);
            Assert.That(options["countUnread"].WireBool(), Is.False);
            Assert.That(options["offlinePush"].WireBool(), Is.False);
            Assert.That(options["needReceipt"].WireBool(), Is.True);
            Assert.That(options["priority"].WireInt(), Is.EqualTo(2));
            Assert.That(options["onlineOnly"].WireBool(), Is.True);
            Assert.That(options["noSelfSync"].WireBool(), Is.True);
            Assert.That(options["expireIn"].WireLong(), Is.EqualTo(5000L));
            Assert.That(options["moderationBypass"].WireBool(), Is.True);

            var push = options["pushConfig"];
            Assert.That(Keys(push), Is.EqualTo(new[] { "badgeCount", "body", "channelId", "payload", "sound", "title" }));
            Assert.That(push["title"].WireString(), Is.EqualTo("Assistant"));
            Assert.That(push["body"].WireString(), Is.EqualTo("is replying"));
            Assert.That(push["sound"].WireString(), Is.EqualTo("ding.caf"));
            Assert.That(push["payload"]["deepLink"].WireString(), Is.EqualTo("app://s_alice_bob"), "a map of strings");
            Assert.That(push["badgeCount"].WireBool(), Is.False);
            Assert.That(push["channelId"].WireString(), Is.EqualTo("im_messages"));

            Assert.That(handle.StreamId, Is.EqualTo(StreamId));
            Assert.That(handle.ConversationId, Is.EqualTo(Conversation));
            Assert.That(handle.StartedAt, Is.EqualTo(1767225600123L));
            Assert.That(handle.IdleTimeoutSeconds, Is.EqualTo(30));
        }

        [Test]
        public void Begin_fills_in_the_idempotency_key_on_the_request_and_sends_nothing_unset()
        {
            var request = new ImBeginStreamRequest(ImRecipient.Group("g_team"));
            ImTestHarness.Forget(_harness.Client.Msg.StreamBeginAsync(request));
            _harness.Pump();

            var body = _harness.Socket.LastBody("msg.streamBegin");
            Assert.That(Keys(body), Is.EqualTo(new[] { "clientMsgId", "contentType", "groupId" }));
            Assert.That(body["groupId"].WireString(), Is.EqualTo("g_team"));
            Assert.That(body["contentType"].WireInt(), Is.EqualTo(1), "Text, the server's default, said out loud");
            Assert.That(body["clientMsgId"].WireString(), Is.Not.Empty, "the server answers 1001 without one and makes none up");
            Assert.That(request.ClientMsgId, Is.EqualTo(body["clientMsgId"].AsString()),
                "written back onto the request, so the caller knows the key of the message this stream becomes");

            ImTestHarness.Forget(_harness.Client.Msg.StreamBeginAsync(new ImBeginStreamRequest(ImRecipient.Conversation(Conversation))
            {
                Options = new ImMessageOptions(),
            }));
            _harness.Pump();

            var addressed = _harness.Socket.LastBody("msg.streamBegin");
            Assert.That(Keys(addressed), Is.EqualTo(new[] { "clientMsgId", "contentType", "conversationId", "options" }));
            Assert.That(addressed["conversationId"].WireString(), Is.EqualTo(Conversation));
            Assert.That(Keys(addressed["options"]), Is.Empty, "options left unset leave every server default standing");
        }

        [Test]
        public void Begin_without_an_address_is_refused_before_anything_is_sent()
        {
            var before = _harness.Socket.Requests.Count;

            Assert.Throws<ArgumentNullException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.StreamBeginAsync(null)); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.StreamBeginAsync(new ImBeginStreamRequest())); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.StreamAppendAsync(new ImStreamAppendRequest(null, "x"))); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest())); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.StreamAbortAsync(new ImStreamAbortRequest(string.Empty))); });

            _harness.Pump();
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before));
        }

        [Test]
        public void A_refused_begin_fails_with_the_server_code()
        {
            var room = Refused(
                _harness.Client.Msg.StreamBeginAsync(new ImBeginStreamRequest(ImRecipient.Conversation("r_lobby"))),
                "msg.streamBegin",
                ImErrorCode.UnsupportedOperation);
            Assert.That(room.Code, Is.EqualTo(ImErrorCode.UnsupportedOperation), "a chat room takes no stream");

            var forbidden = Refused(
                _harness.Client.Msg.StreamBeginAsync(FullBegin(ImRecipient.User("u_bob"))),
                "msg.streamBegin",
                ImErrorCode.Forbidden);
            Assert.That(forbidden.Code, Is.EqualTo(ImErrorCode.Forbidden), "a client's pushConfig.title is refused at the opening");
        }

        // ------------------------------------------------------------------ msg.streamAppend

        [Test]
        public void Append_sends_the_stream_and_the_piece_and_nothing_else()
        {
            var body = Acknowledged(_harness.Client.Msg.StreamAppendAsync(new ImStreamAppendRequest(StreamId, "Hel")), "msg.streamAppend");
            Assert.That(Keys(body), Is.EqualTo(new[] { "delta", "streamId" }));
            Assert.That(body["streamId"].WireString(), Is.EqualTo(StreamId));
            Assert.That(body["delta"].WireString(), Is.EqualTo("Hel"));

            var shorthand = Acknowledged(_harness.Client.Msg.StreamAppendAsync(StreamId, "lo"), "msg.streamAppend");
            Assert.That(shorthand["delta"].WireString(), Is.EqualTo("lo"));

            var empty = Acknowledged(_harness.Client.Msg.StreamAppendAsync(StreamId, null), "msg.streamAppend");
            Assert.That(empty["delta"].WireString(), Is.Empty, "a string member: null goes out as \"\", which the server accepts and ignores");
        }

        [Test]
        public void Append_refusals_carry_the_server_code()
        {
            Assert.That(Refused(_harness.Client.Msg.StreamAppendAsync(StreamId, "x"), "msg.streamAppend", ImErrorCode.NotFound).Code,
                Is.EqualTo(ImErrorCode.NotFound), "finished, aborted or reaped");
            Assert.That(Refused(_harness.Client.Msg.StreamAppendAsync(StreamId, "x"), "msg.streamAppend", ImErrorCode.Forbidden).Code,
                Is.EqualTo(ImErrorCode.Forbidden), "someone else's stream");
            Assert.That(Refused(_harness.Client.Msg.StreamAppendAsync(StreamId, new string('x', 4097)), "msg.streamAppend", ImErrorCode.MessageTooLong).Code,
                Is.EqualTo(ImErrorCode.MessageTooLong), "over 4096 characters; the stream stays open");
            Assert.That(Refused(_harness.Client.Msg.StreamAppendAsync(StreamId, "x"), "msg.streamAppend", ImErrorCode.RateLimited).Code,
                Is.EqualTo(ImErrorCode.RateLimited));
        }

        // ------------------------------------------------------------------ msg.streamComplete

        [Test]
        public void Complete_sends_what_is_set_and_decodes_the_stored_message_with_every_field()
        {
            var result = Answered(
                _harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)
                {
                    Content = JsonValue.NewObject().Set("text", "Hello, cleaned up"),
                    Extensions = JsonValue.NewObject().Set("model", "m-2"),
                }),
                "msg.streamComplete",
                SendResult(6));

            var body = _harness.Socket.LastBody("msg.streamComplete");
            Assert.That(Keys(body), Is.EqualTo(new[] { "content", "extensions", "streamId" }));
            Assert.That(body["streamId"].WireString(), Is.EqualTo(StreamId));
            Assert.That(body["content"]["text"].WireString(), Is.EqualTo("Hello, cleaned up"));
            Assert.That(body["extensions"]["model"].WireString(), Is.EqualTo("m-2"));

            Assert.That(result.MessageId, Is.EqualTo(360381357961969667L), "a quoted snowflake past 2^53 keeps every digit");
            Assert.That(result.Seq, Is.EqualTo(6L));
            Assert.That(result.ConversationId, Is.EqualTo(Conversation));
            Assert.That(result.ClientMsgId, Is.EqualTo("cm-stream"));
            Assert.That(result.CreateTime, Is.EqualTo(1767225601000L));
            Assert.That(result.Deduplicated, Is.True);
            Assert.That(result.ContentModified, Is.True);

            ImTestHarness.Forget(_harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)));
            _harness.Pump();
            Assert.That(Keys(_harness.Socket.LastBody("msg.streamComplete")), Is.EqualTo(new[] { "streamId" }),
                "no content: the server stores the pieces as {\"text\": …}");
        }

        /// <summary>
        /// <c>msg.send</c> moves the delivered cursor to its own seq, because the server does not echo the
        /// message to the connection that sent it. A completed stream is echoed — to the producer too — so
        /// the same move would drop the producer's own copy as a duplicate.
        /// </summary>
        [Test]
        public void Complete_moves_no_cursor_so_the_producers_own_copy_still_arrives()
        {
            _harness.PushMessage(Conversation, 5);

            var result = Answered(_harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)), "msg.streamComplete", SendResult(6));
            Assert.That(result.Seq, Is.EqualTo(6L));
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(5), "the result reconciles no cursor");

            PushStored(6, "Hello");

            Assert.That(Seqs(), Is.EqualTo(new long[] { 5, 6 }), "the stored message reaches MessageReceived on the producer too");
            Assert.That(_delivered[1].ClientMsgId, Is.EqualTo("cm-stream"));
            Assert.That(_delivered[1].MessageId, Is.EqualTo(360381357961969667L));
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(6));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
        }

        [Test]
        public void A_second_complete_or_abort_fails_with_not_found()
        {
            Answered(_harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)), "msg.streamComplete", SendResult(6));

            Assert.That(Refused(_harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)), "msg.streamComplete", ImErrorCode.NotFound).Code,
                Is.EqualTo(ImErrorCode.NotFound));
            Assert.That(Refused(_harness.Client.Msg.StreamAbortAsync(new ImStreamAbortRequest(StreamId)), "msg.streamAbort", ImErrorCode.NotFound).Code,
                Is.EqualTo(ImErrorCode.NotFound));
        }

        // ------------------------------------------------------------------ msg.streamAbort

        [Test]
        public void Abort_sends_the_reason_only_when_it_is_given()
        {
            var body = Acknowledged(_harness.Client.Msg.StreamAbortAsync(new ImStreamAbortRequest(StreamId, "the model failed")), "msg.streamAbort");
            Assert.That(Keys(body), Is.EqualTo(new[] { "reason", "streamId" }));
            Assert.That(body["streamId"].WireString(), Is.EqualTo(StreamId));
            Assert.That(body["reason"].WireString(), Is.EqualTo("the model failed"));

            var bare = Acknowledged(_harness.Client.Msg.StreamAbortAsync(new ImStreamAbortRequest(StreamId)), "msg.streamAbort");
            Assert.That(Keys(bare), Is.EqualTo(new[] { "streamId" }), "the server words a missing reason itself");
        }

        // ------------------------------------------------------------------ the writer

        [Test]
        public void The_writer_holds_the_stream_and_its_key_across_the_four_calls()
        {
            var writing = ImStreamWriter.BeginAsync(_harness.Client.Msg, new ImBeginStreamRequest(ImRecipient.User("u_bob")));
            var writer = Answered(writing, "msg.streamBegin", Handle());

            Assert.That(writer.StreamId, Is.EqualTo(StreamId));
            Assert.That(writer.Handle.IdleTimeoutSeconds, Is.EqualTo(30));
            Assert.That(writer.ClientMsgId, Is.EqualTo(_harness.Socket.LastBody("msg.streamBegin")["clientMsgId"].AsString()));
            Assert.That(writer.ClientMsgId, Is.Not.Empty);

            var piece = Acknowledged(writer.AppendAsync("Hel"), "msg.streamAppend");
            Assert.That(piece["streamId"].WireString(), Is.EqualTo(StreamId));
            Assert.That(piece["delta"].WireString(), Is.EqualTo("Hel"));

            var done = Answered(writer.CompleteAsync(), "msg.streamComplete", SendResult(6));
            Assert.That(Keys(_harness.Socket.LastBody("msg.streamComplete")), Is.EqualTo(new[] { "streamId" }));
            Assert.That(done.Seq, Is.EqualTo(6L));

            var stop = Acknowledged(writer.AbortAsync("stopped"), "msg.streamAbort");
            Assert.That(stop["streamId"].WireString(), Is.EqualTo(StreamId));
            Assert.That(stop["reason"].WireString(), Is.EqualTo("stopped"));

            Assert.Throws<ArgumentNullException>(delegate { ImTestHarness.Forget(ImStreamWriter.BeginAsync(null, new ImBeginStreamRequest())); });
        }

        // ------------------------------------------------------------------ evt.stream

        [Test]
        public void Each_phase_of_evt_stream_is_decoded_with_every_field()
        {
            Push(BeginFrame());
            Push(DeltaFrame(1, "Hel"));
            Push(CompletedFrame(2, 6));
            Push(AbortedFrame(3, "the producer stopped sending for 30s", "st_other"));

            Assert.That(_events, Has.Count.EqualTo(4));

            var begin = _events[0];
            Assert.That(begin.Phase, Is.EqualTo(ImStreamPhase.Begin));
            Assert.That(begin.StreamId, Is.EqualTo(StreamId));
            Assert.That(begin.ConversationId, Is.EqualTo(Conversation));
            Assert.That(begin.SenderId, Is.EqualTo("u_alice"));
            Assert.That(begin.Index, Is.Zero);
            Assert.That(begin.Done, Is.False);
            Assert.That(begin.Delta, Is.Null, "the opening carries no delta key");
            Assert.That(begin.Placeholder["name"].AsString(), Is.EqualTo("Assistant"));
            Assert.That(begin.MessageId, Is.Null);
            Assert.That(begin.Seq, Is.Null);
            Assert.That(begin.AbortReason, Is.Null);

            var delta = _events[1];
            Assert.That(delta.Phase, Is.EqualTo(ImStreamPhase.Delta));
            Assert.That(delta.Index, Is.EqualTo(1));
            Assert.That(delta.Delta, Is.EqualTo("Hel"));
            Assert.That(delta.Placeholder, Is.Null);

            var completed = _events[2];
            Assert.That(completed.Phase, Is.EqualTo(ImStreamPhase.Completed));
            Assert.That(completed.Done, Is.True);
            Assert.That(completed.Index, Is.EqualTo(2), "one past the last piece");
            Assert.That(completed.MessageId, Is.EqualTo(360381357961969667L), "quoted on the wire, every digit kept");
            Assert.That(completed.Seq, Is.EqualTo(6L));
            Assert.That(completed.AbortReason, Is.Null);

            var aborted = _events[3];
            Assert.That(aborted.Phase, Is.EqualTo(ImStreamPhase.Aborted));
            Assert.That(aborted.StreamId, Is.EqualTo("st_other"));
            Assert.That(aborted.AbortReason, Is.EqualTo("the producer stopped sending for 30s"));
            Assert.That(aborted.MessageId, Is.Null, "done without a message id is an abort, whatever its cause");
            Assert.That(aborted.Seq, Is.Null);
            Assert.That(aborted.Data["abortReason"].AsString(), Is.EqualTo("the producer stopped sending for 30s"), "the raw payload rides along");
        }

        [Test]
        public void A_bare_numeric_message_id_is_read_as_well()
        {
            var completed = Event(Frame(StreamId, 3).Set("done", true).Set("messageId", 360381357961969667L).Set("seq", 9L));
            Assert.That(completed.Phase, Is.EqualTo(ImStreamPhase.Completed));
            Assert.That(completed.MessageId, Is.EqualTo(360381357961969667L));
        }

        [Test]
        public void A_frame_this_build_cannot_read_is_dropped_and_the_next_one_still_arrives()
        {
            Push(JsonValue.NewArray());
            Push(JsonValue.NewObject().Set("index", 1L).Set("delta", "orphan").Set("done", false));
            Push(JsonValue.Of("evt"));
            Push(DeltaFrame(1, "Hel"));

            Assert.That(_events, Has.Count.EqualTo(1));
            Assert.That(_events[0].Delta, Is.EqualTo("Hel"));
        }

        [Test]
        public void A_disposed_stream_reader_receives_nothing()
        {
            var received = new List<ImStreamEvent>();
            _harness.Client.OnStreamEvent(received.Add).Dispose();

            Push(DeltaFrame(1, "Hel"));

            Assert.That(received, Is.Empty);
            Assert.That(_events, Has.Count.EqualTo(1), "another subscription is untouched");
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.OnStreamEvent(null); });
        }

        // ------------------------------------------------------------------ the pieces are not messages

        /// <summary>
        /// The frames have no seq and are never stored, so nothing about them may reach a cursor, the
        /// gap repair or <see cref="ImClient.MessageReceived"/> — not even a terminal frame that names a
        /// seq past the cursor. The stored message that arrives afterwards does all of that, as any
        /// message does.
        /// </summary>
        [Test]
        public void Stream_frames_move_no_cursor_ask_for_no_repair_and_are_not_messages()
        {
            var savesBefore = ((RecordingCursorStore)_harness.CursorStore).Saves;
            _harness.PushMessage(Conversation, 5);

            Push(BeginFrame());
            Push(DeltaFrame(1, "Hel"));
            Push(DeltaFrame(3, "!"));
            Push(CompletedFrame(4, 9));

            Assert.That(_events, Has.Count.EqualTo(4));
            Assert.That(Seqs(), Is.EqualTo(new long[] { 5 }), "no frame is delivered as a message");
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "neither the missing piece 2 nor seq 9 asks for a repair");
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(5));
            Assert.That(_harness.Client.CommittedSeqOf(Conversation), Is.Zero);
            Assert.That(((RecordingCursorStore)_harness.CursorStore).Saves, Is.EqualTo(savesBefore));
        }

        [Test]
        public void The_stored_message_goes_through_gap_repair_when_it_skips_a_seq()
        {
            _harness.PushMessage(Conversation, 5);

            Push(BeginFrame());
            Push(DeltaFrame(1, "Hello"));
            Push(CompletedFrame(2, 7));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);

            PushStored(7, "Hello");

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.EqualTo(1), "seq 6 is missing; the stored message waits for it like any other");
            var sync = _harness.Socket.LastBody("msg.sync");
            Assert.That(sync["conversationId"].WireString(), Is.EqualTo(Conversation));
            Assert.That(sync["fromSeq"].WireLong(), Is.EqualTo(6L));
            Assert.That(Seqs(), Is.EqualTo(new long[] { 5 }), "held behind the repair");

            _harness.Socket.Reply("msg.sync", JsonValue.NewObject().Set("messages", JsonValue.NewArray()
                .Add(ImFrames.MessageJson(Conversation, 6))));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 5, 6, 7 }));
            Assert.That(_delivered[2].Text, Is.EqualTo("Hello"));
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(7));
        }

        [Test]
        public void The_stored_message_may_arrive_before_its_terminal_frame_and_still_matches_by_id()
        {
            var assembler = new ImStreamAssembler();
            _harness.Client.OnStreamEvent(e => assembler.Accept(e));

            Push(BeginFrame());
            Push(DeltaFrame(1, "Hel"));
            PushStored(1, "Hello");

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1 }), "the message is delivered without waiting for any frame");
            Assert.That(assembler.StateOf(StreamId).Status, Is.EqualTo(ImStreamStatus.Streaming));

            Push(CompletedFrame(3, 1));
            Push(DeltaFrame(2, "lo"));

            var state = assembler.StateOf(StreamId);
            Assert.That(state.Status, Is.EqualTo(ImStreamStatus.Completed));
            Assert.That(state.MessageId, Is.EqualTo(_delivered[0].MessageId), "terminal frame and message meet on the id");
            Assert.That(state.Text, Is.EqualTo("Hello"));
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1 }), "and the frames after it delivered nothing more");
        }

        // ------------------------------------------------------------------ assembly

        [Test]
        public void Pieces_in_order_assemble_into_the_completed_text()
        {
            var assembler = new ImStreamAssembler();

            var opened = assembler.Accept(Event(BeginFrame()));
            Assert.That(opened.Status, Is.EqualTo(ImStreamStatus.Streaming));
            Assert.That(opened.SawBegin, Is.True);
            Assert.That(opened.Placeholder["name"].AsString(), Is.EqualTo("Assistant"));
            Assert.That(opened.Text, Is.Empty);

            assembler.Accept(Event(DeltaFrame(1, "Hel")));
            var running = assembler.Accept(Event(DeltaFrame(2, "lo, ")));
            Assert.That(running.Text, Is.EqualTo("Hello, "));
            Assert.That(assembler.Active, Has.Count.EqualTo(1));

            assembler.Accept(Event(DeltaFrame(3, "world")));
            var done = assembler.Accept(Event(CompletedFrame(4, 6)));

            Assert.That(done.Status, Is.EqualTo(ImStreamStatus.Completed));
            Assert.That(done.IsFinished, Is.True);
            Assert.That(done.Text, Is.EqualTo("Hello, world"));
            Assert.That(done.Fragments, Is.EqualTo(3));
            Assert.That(done.MissingFragments, Is.Zero);
            Assert.That(done.HasGap, Is.False);
            Assert.That(done.MessageId, Is.EqualTo(360381357961969667L));
            Assert.That(done.Seq, Is.EqualTo(6L));
            Assert.That(done.AbortReason, Is.Null);
            Assert.That(done.StreamId, Is.EqualTo(StreamId));
            Assert.That(done.ConversationId, Is.EqualTo(Conversation));
            Assert.That(done.SenderId, Is.EqualTo("u_alice"));
            Assert.That(assembler.Active, Is.Empty);
            Assert.That(assembler.StateOf(StreamId).Status, Is.EqualTo(ImStreamStatus.Completed), "remembered after it finished");
        }

        [Test]
        public void An_aborted_stream_keeps_its_text_and_says_why_and_has_no_message()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame()));
            assembler.Accept(Event(DeltaFrame(1, "Hel")));
            var aborted = assembler.Accept(Event(AbortedFrame(2, "the model failed")));

            Assert.That(aborted.Status, Is.EqualTo(ImStreamStatus.Aborted));
            Assert.That(aborted.AbortReason, Is.EqualTo("the model failed"));
            Assert.That(aborted.MessageId, Is.Null);
            Assert.That(aborted.Seq, Is.Null);
            Assert.That(aborted.Text, Is.EqualTo("Hel"));
            Assert.That(aborted.HasGap, Is.False);
        }

        [Test]
        public void An_empty_stream_completes_with_no_text_and_nothing_missing()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame(placeholder: false)));
            var done = assembler.Accept(Event(CompletedFrame(1, 6)));

            Assert.That(done.Status, Is.EqualTo(ImStreamStatus.Completed));
            Assert.That(done.Text, Is.Empty);
            Assert.That(done.Fragments, Is.Zero);
            Assert.That(done.MissingFragments, Is.Zero);
            Assert.That(done.Placeholder, Is.Null);
        }

        [Test]
        public void Pieces_are_joined_by_index_not_by_arrival()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame()));

            var ahead = assembler.Accept(Event(DeltaFrame(2, "lo")));
            Assert.That(ahead.Text, Is.EqualTo("lo"), "a hole is skipped for display, not waited on");
            Assert.That(ahead.MissingFragments, Is.EqualTo(1));

            var filled = assembler.Accept(Event(DeltaFrame(1, "Hel")));
            Assert.That(filled.Text, Is.EqualTo("Hello"));
            Assert.That(filled.MissingFragments, Is.Zero);
            Assert.That(filled.Fragments, Is.EqualTo(2));
        }

        [Test]
        public void Duplicates_a_second_opening_and_a_second_terminal_frame_change_nothing()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame()));
            assembler.Accept(Event(DeltaFrame(1, "Hel")));
            assembler.Accept(Event(DeltaFrame(3, "!")));

            Assert.That(assembler.Accept(Event(DeltaFrame(1, "Hel"))), Is.Null, "a joined piece again");
            Assert.That(assembler.Accept(Event(DeltaFrame(3, "!"))), Is.Null, "a waiting piece again");
            Assert.That(assembler.Accept(Event(BeginFrame())), Is.Null);

            assembler.Accept(Event(CompletedFrame(4, 6)));
            Assert.That(assembler.Accept(Event(CompletedFrame(4, 6))), Is.Null);
            Assert.That(assembler.Accept(Event(AbortedFrame(4, "late"))), Is.Null, "a finished stream cannot change its ending");
            Assert.That(assembler.Accept(Event(BeginFrame())), Is.Null, "nor reopen");
            Assert.That(assembler.Active, Is.Empty);

            var state = assembler.StateOf(StreamId);
            Assert.That(state.Status, Is.EqualTo(ImStreamStatus.Completed));
            Assert.That(state.Text, Is.EqualTo("Hel!"));
            Assert.That(state.MissingFragments, Is.EqualTo(1));
        }

        /// <summary>
        /// The terminal frame is pushed at normal priority and the pieces at low, and the server's queue
        /// sends normal first: a piece still queued when the producer completed arrives after the end.
        /// </summary>
        [Test]
        public void A_piece_overtaken_by_the_terminal_frame_fills_in_the_finished_stream()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame()));
            assembler.Accept(Event(DeltaFrame(1, "Hel")));

            var early = assembler.Accept(Event(CompletedFrame(3, 6)));
            Assert.That(early.Status, Is.EqualTo(ImStreamStatus.Completed));
            Assert.That(early.MissingFragments, Is.EqualTo(1), "the terminal index says there were two pieces");
            Assert.That(early.HasGap, Is.True);

            var late = assembler.Accept(Event(DeltaFrame(2, "lo")));
            Assert.That(late, Is.Not.Null);
            Assert.That(late.Status, Is.EqualTo(ImStreamStatus.Completed), "still finished — not reopened as a stream that never ends");
            Assert.That(late.Text, Is.EqualTo("Hello"));
            Assert.That(late.MissingFragments, Is.Zero);
            Assert.That(assembler.Active, Is.Empty);
        }

        [Test]
        public void A_shed_piece_is_counted_and_never_repaired()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame()));
            assembler.Accept(Event(DeltaFrame(1, "Hel")));
            assembler.Accept(Event(DeltaFrame(3, "!")));
            var done = assembler.Accept(Event(CompletedFrame(4, 6)));

            Assert.That(done.HasGap, Is.True);
            Assert.That(done.MissingFragments, Is.EqualTo(1));
            Assert.That(done.Text, Is.EqualTo("Hel!"), "what arrived, in order; the stored message has the rest");
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
        }

        [Test]
        public void A_mid_stream_join_is_accepted_without_an_opening()
        {
            var assembler = new ImStreamAssembler();
            var joined = assembler.Accept(Event(DeltaFrame(3, "world")));

            Assert.That(joined.Status, Is.EqualTo(ImStreamStatus.Streaming));
            Assert.That(joined.SawBegin, Is.False);
            Assert.That(joined.Placeholder, Is.Null);
            Assert.That(joined.MissingFragments, Is.EqualTo(2));
            Assert.That(joined.Text, Is.EqualTo("world"));

            var aborted = assembler.Accept(Event(AbortedFrame(4, "aborted by the producer")));
            Assert.That(aborted.Status, Is.EqualTo(ImStreamStatus.Aborted));
            Assert.That(aborted.HasGap, Is.True);
        }

        [Test]
        public void Interleaved_streams_are_assembled_apart()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame("st_a")));
            assembler.Accept(Event(BeginFrame("st_b")));
            assembler.Accept(Event(DeltaFrame(1, "one", "st_a")));
            assembler.Accept(Event(DeltaFrame(1, "uno", "st_b")));
            assembler.Accept(Event(DeltaFrame(2, " two", "st_a")));
            assembler.Accept(Event(AbortedFrame(2, "stopped", "st_b")));

            Assert.That(assembler.StateOf("st_a").Text, Is.EqualTo("one two"));
            Assert.That(assembler.StateOf("st_a").Status, Is.EqualTo(ImStreamStatus.Streaming));
            Assert.That(assembler.StateOf("st_b").Text, Is.EqualTo("uno"));
            Assert.That(assembler.StateOf("st_b").Status, Is.EqualTo(ImStreamStatus.Aborted));
            Assert.That(assembler.Active, Has.Count.EqualTo(1));
            Assert.That(assembler.StateOf("st_unknown"), Is.Null);
        }

        [Test]
        public void A_forgotten_stream_ignores_its_frames_and_clear_forgets_every_running_one()
        {
            var assembler = new ImStreamAssembler();
            assembler.Accept(Event(BeginFrame("st_a")));
            assembler.Accept(Event(DeltaFrame(1, "one", "st_a")));
            assembler.Accept(Event(BeginFrame("st_b")));
            assembler.Accept(Event(BeginFrame("st_c")));
            assembler.Accept(Event(CompletedFrame(1, 6, "st_c")));

            var last = assembler.Forget("st_a");
            Assert.That(last.Text, Is.EqualTo("one"));
            Assert.That(assembler.Accept(Event(DeltaFrame(2, " two", "st_a"))), Is.Null, "a frame for a forgotten stream");
            Assert.That(assembler.Accept(Event(CompletedFrame(3, 7, "st_a"))), Is.Null);
            Assert.That(assembler.Forget("st_unknown"), Is.Null);

            var cleared = assembler.Clear();
            Assert.That(cleared, Has.Count.EqualTo(1), "only st_b was still running");
            Assert.That(cleared[0].StreamId, Is.EqualTo("st_b"));
            Assert.That(assembler.Active, Is.Empty);
            Assert.That(assembler.Accept(Event(DeltaFrame(1, "late", "st_b"))), Is.Null);
            Assert.That(assembler.StateOf("st_c").Status, Is.EqualTo(ImStreamStatus.Completed), "a finished stream is not touched by Clear");
        }

        [Test]
        public void Only_the_last_finished_streams_are_remembered()
        {
            var assembler = new ImStreamAssembler(1);
            assembler.Accept(Event(BeginFrame("st_a")));
            assembler.Accept(Event(CompletedFrame(2, 6, "st_a")));
            assembler.Accept(Event(BeginFrame("st_b")));
            assembler.Accept(Event(CompletedFrame(1, 7, "st_b")));

            Assert.That(assembler.StateOf("st_a"), Is.Null, "evicted, oldest first");
            Assert.That(assembler.StateOf("st_b"), Is.Not.Null);

            var stray = assembler.Accept(Event(DeltaFrame(1, "very late", "st_a")));
            Assert.That(stray.Status, Is.EqualTo(ImStreamStatus.Streaming), "past the memory a straggler reads as a mid-stream join");
            Assert.That(stray.SawBegin, Is.False);

            Assert.Throws<ArgumentOutOfRangeException>(delegate { new ImStreamAssembler(-1); });
            Assert.Throws<ArgumentNullException>(delegate { assembler.Accept(null); });
        }

        // ------------------------------------------------------------------ inventory

        /// <summary>
        /// "msg.stream* is typed" is something this suite can fail on: every method is driven, and the
        /// targets that reach the wire are compared with the inventory's own list.
        /// </summary>
        [Test]
        public void Every_stream_endpoint_in_the_inventory_is_typed_here()
        {
            var calls = new List<Task>
            {
                _harness.Client.Msg.StreamBeginAsync(new ImBeginStreamRequest(ImRecipient.User("u_bob"))),
                _harness.Client.Msg.StreamAppendAsync(StreamId, "x"),
                _harness.Client.Msg.StreamCompleteAsync(new ImCompleteStreamRequest(StreamId)),
                _harness.Client.Msg.StreamAbortAsync(new ImStreamAbortRequest(StreamId)),
            };

            foreach (var call in calls)
            {
                ImTestHarness.Forget(call);
            }

            _harness.Pump();

            var sent = new HashSet<string>(StringComparer.Ordinal);
            foreach (var request in _harness.Socket.Requests)
            {
                sent.Add(request.Target);
            }

            var streams = new List<string>();
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                var target = endpoint["target"].AsString();
                if (target.StartsWith("msg.stream", StringComparison.Ordinal))
                {
                    streams.Add(target);
                }
            }

            Assert.That(streams, Has.Count.EqualTo(4), "the inventory's stream list parsed to the wrong size");

            var missing = streams.FindAll(target => !sent.Contains(target));
            Assert.That(missing, Is.Empty, "stream endpoints no typed method sends: " + string.Join(", ", missing.ToArray()));
        }

        /// <summary>
        /// The frame tests are only as wide as the bodies they build and the decoding tests only as wide as
        /// their fixtures, so both are held to the inventory's <c>payloadTypes</c>. A begin body names one
        /// address, so the three addressing modes together must cover the type.
        /// </summary>
        [Test]
        public void The_full_fixtures_and_bodies_carry_every_member_the_server_declares()
        {
            var begin = new SortedSet<string>(StringComparer.Ordinal);
            begin.UnionWith(Keys(FullBegin(ImRecipient.User("u_bob")).ToJson()));
            begin.UnionWith(Keys(FullBegin(ImRecipient.Group("g_team")).ToJson()));
            begin.UnionWith(Keys(FullBegin(ImRecipient.Conversation(Conversation)).ToJson()));
            Assert.That(begin, Is.EqualTo(Members("BeginStreamRequest")));

            Assert.That(Keys(FullOptions().ToJson()), Is.EqualTo(Members("MessageOptions")));
            Assert.That(Keys(FullOptions().PushConfig.ToJson()), Is.EqualTo(Members("PushConfig")));
            Assert.That(Keys(new ImStreamAppendRequest(StreamId, "x").ToJson()), Is.EqualTo(Members("StreamAppendRequest")));
            Assert.That(Keys(new ImCompleteStreamRequest(StreamId)
            {
                Content = JsonValue.NewObject(),
                Extensions = JsonValue.NewObject(),
            }.ToJson()), Is.EqualTo(Members("CompleteStreamRequest")));
            Assert.That(Keys(new ImStreamAbortRequest(StreamId, "r").ToJson()), Is.EqualTo(Members("StreamAbortRequest")));

            Assert.That(Keys(Handle()), Is.EqualTo(Members("StreamHandle")));
            Assert.That(Keys(SendResult(6)), Is.EqualTo(Members("SendMessageResult")));
        }

        /// <summary>
        /// <c>evt.stream</c>'s payload is not in the inventory's <c>payloadTypes</c> — the generator walks
        /// request and response types, not pushes — so its members are pinned here from the server's C#:
        /// <c>StreamDelta</c> (IStreamingMessageService.cs) and the opening frame's <c>StreamBeginFrame</c>,
        /// which adds <c>placeholder</c>. The day the inventory declares <c>StreamDelta</c>, it is the judge.
        /// </summary>
        [Test]
        public void The_frame_fixtures_carry_every_member_of_the_servers_push()
        {
            var pinned = new List<string>
            {
                "abortReason", "conversationId", "delta", "done", "index", "messageId", "senderId", "seq", "streamId",
            };

            var declared = Inventory()["payloadTypes"]["StreamDelta"];
            var delta = declared.IsObject ? Members("StreamDelta") : pinned;

            var frames = new SortedSet<string>(StringComparer.Ordinal);
            frames.UnionWith(Keys(DeltaFrame(1, "x")));
            frames.UnionWith(Keys(CompletedFrame(2, 6)));
            frames.UnionWith(Keys(AbortedFrame(2, "r")));
            Assert.That(frames, Is.EqualTo(delta));

            var opening = new SortedSet<string>(delta);
            opening.Remove("delta");
            opening.Remove("messageId");
            opening.Remove("seq");
            opening.Remove("abortReason");
            opening.Add("placeholder");
            Assert.That(Keys(BeginFrame()), Is.EqualTo(opening), "the opening: StreamDelta's always-present members plus placeholder");
        }

        private static List<string> Members(string type)
        {
            var names = new List<string>();
            foreach (var property in Inventory()["payloadTypes"][type]["properties"].Items)
            {
                names.Add(property["name"].AsString());
            }

            names.Sort(StringComparer.Ordinal);
            return names;
        }

        private static JsonValue Inventory()
        {
            return JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "endpoint-inventory.json")));
        }

        private static string SdkRoot([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);
            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                if (File.Exists(Path.Combine(directory, "endpoint-inventory.json")))
                {
                    return directory;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }
    }
}
