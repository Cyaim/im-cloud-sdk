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
    /// <c>room.*</c> — the seven chat-room verbs, the <c>room.*</c> events inside <c>evt.system</c>,
    /// and the one rule an integrator cannot guess: a room message has <c>seq</c> 0 and never reaches
    /// a cursor or the gap repair.
    /// </summary>
    /// <remarks>
    /// Every verb is asserted on the frame it puts on the wire — target and the whole body, by JSON
    /// kind — and on what it makes of a reply with every member set. The keys inside
    /// <c>room.send</c>'s <c>message</c> carry the weight: the socket binder matches them
    /// case-sensitively and drops a miscased one without a word, so a body that is wrong there still
    /// answers success.
    /// 每个动词都断言它发出的整帧与它对满字段答复的解码；room.send 的 message 内的键大小写敏感、写错静默丢弃。
    /// </remarks>
    public sealed class RoomTests
    {
        private ImTestHarness _harness;
        private List<ImMessage> _delivered;

        [SetUp]
        public void SetUp()
        {
            _harness = new ImTestHarness();
            _delivered = new List<ImMessage>();
            _harness.Client.MessageReceived += _delivered.Add;
            _harness.Connect();
        }

        [TearDown]
        public void TearDown()
        {
            _harness.Dispose();
        }

        // ------------------------------------------------------------------ fixtures

        private static JsonValue ChatRoom(bool full)
        {
            var room = JsonValue.NewObject()
                .Set("appId", "demo")
                .Set("roomId", "lobby")
                .Set("name", "Lobby")
                .Set("ownerId", "u_alice")
                .Set("admins", JsonValue.NewArray())
                .Set("maxOnline", 0L)
                .Set("historyBufferSize", 50L)
                .Set("rateLimitPerSecond", 200L)
                .Set("muteAll", false)
                .Set("destroyed", false)
                .Set("createdAt", 1755000000000L);

            if (full)
            {
                // Every member of the server's ChatRoom, each with a value no default reads as — so a
                // key spelled wrong in ReadFrom decodes to a default and an assertion below fails. The
                // last test holds the list to the inventory.
                room
                    .Set("avatar", "rooms/lobby.png")
                    .Set("admins", JsonValue.ArrayOf(new[] { "u_mod" }))
                    .Set("maxOnline", 5000L)
                    .Set("historyBufferSize", 20L)
                    .Set("rateLimitPerSecond", 30L)
                    .Set("muteAll", true)
                    .Set("destroyed", true)
                    .Set("extensions", JsonValue.NewObject().Set("theme", "night"));
            }

            return room;
        }

        /// <summary>A room message as the server fans it out: seq 0, <c>r_&lt;roomId&gt;</c>, type 3.</summary>
        private static JsonValue RoomMessage(string roomId, string text, long messageId = 360381357961969667L)
        {
            return ImFrames.MessageJson("r_" + roomId, 0, JsonValue.NewObject().Set("text", text))
                .Set("conversationType", 3L)
                .Set("messageId", messageId)
                .Set("clientMsgId", "cm-" + text);
        }

        private static JsonValue JoinResult()
        {
            return JsonValue.NewObject()
                .Set("room", ChatRoom(true))
                .Set("onlineCount", 1234L)
                .Set("recent", JsonValue.NewArray()
                    .Add(RoomMessage("lobby", "first", 360381357961969601L))
                    .Add(RoomMessage("lobby", "second", 360381357961969602L)));
        }

        private static JsonValue SendResult()
        {
            return JsonValue.NewObject()
                .Set("messageId", "360381357961969667")
                .Set("seq", 0L)
                .Set("conversationId", "r_lobby")
                .Set("clientMsgId", "room-1")
                .Set("createTime", 1755000000123L)
                .Set("deduplicated", true)
                .Set("contentModified", true);
        }

        private void PushRoomMessage(string roomId, string text)
        {
            _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Message, RoomMessage(roomId, text)));
            _harness.Pump();
        }

        private void PushSystem(JsonValue data)
        {
            _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.System, data));
        }

        private static JsonValue SystemEvent(string name, JsonValue body)
        {
            return JsonValue.NewObject().Set("event", name).Set("body", body);
        }

        // ------------------------------------------------------------------ helpers

        /// <summary>Starts a call, answers it with <paramref name="data"/>, and returns its result.</summary>
        private T Answered<T>(Task<T> pending, string target, JsonValue data)
        {
            _harness.Pump();
            _harness.Socket.Reply(target, data);
            _harness.Pump();

            Assert.That(pending.IsCompleted, Is.True, target + " did not complete");
            return pending.Result;
        }

        /// <summary>Starts a call, answers it with no payload, and returns the body it sent.</summary>
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

        private RecordingCursorStore Store
        {
            get { return (RecordingCursorStore)_harness.CursorStore; }
        }

        // ------------------------------------------------------------------ the verbs

        [Test]
        public void Join_sends_the_room_and_decodes_the_room_its_head_count_and_recent_messages()
        {
            var joined = Answered(_harness.Client.Room.JoinAsync(new ImRoomIdRequest("lobby")), "room.join", JoinResult());

            var body = _harness.Socket.LastBody("room.join");
            Assert.That(Keys(body), Is.EqualTo(new[] { "roomId" }));
            Assert.That(body["roomId"].WireString(), Is.EqualTo("lobby"));

            var room = joined.Room;
            Assert.That(room.AppId, Is.EqualTo("demo"));
            Assert.That(room.RoomId, Is.EqualTo("lobby"));
            Assert.That(room.Name, Is.EqualTo("Lobby"));
            Assert.That(room.Avatar, Is.EqualTo("rooms/lobby.png"));
            Assert.That(room.OwnerId, Is.EqualTo("u_alice"));
            Assert.That(room.Admins, Is.EqualTo(new[] { "u_mod" }));
            Assert.That(room.MaxOnline, Is.EqualTo(5000L));
            Assert.That(room.HistoryBufferSize, Is.EqualTo(20));
            Assert.That(room.RateLimitPerSecond, Is.EqualTo(30));
            Assert.That(room.MuteAll, Is.True);
            Assert.That(room.Destroyed, Is.True);
            Assert.That(room.CreatedAt, Is.EqualTo(1755000000000L));
            Assert.That(room.Extensions["theme"].AsString(), Is.EqualTo("night"));

            Assert.That(joined.OnlineCount, Is.EqualTo(1234L));
            Assert.That(joined.Recent, Has.Count.EqualTo(2));
            Assert.That(joined.Recent[0].Text, Is.EqualTo("first"));
            Assert.That(joined.Recent[0].MessageId, Is.EqualTo(360381357961969601L), "a snowflake past 2^53 keeps every digit");
            Assert.That(joined.Recent[1].Seq, Is.Zero);
            Assert.That(joined.Recent[1].ConversationId, Is.EqualTo("r_lobby"));
            Assert.That(joined.Recent[1].ConversationType, Is.EqualTo(ImConversationType.ChatRoom));

            // Returned here only: the ring buffer is not replayed as live traffic, and touches nothing.
            Assert.That(_delivered, Is.Empty, "join's recent messages are not replayed on MessageReceived");
            Assert.That(_harness.Client.DeliveredSeqOf("r_lobby"), Is.Zero);
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);

            Answered(_harness.Client.Room.JoinAsync("hall"), "room.join", JoinResult());
            Assert.That(_harness.Socket.LastBody("room.join")["roomId"].WireString(), Is.EqualTo("hall"));
        }

        [Test]
        public void Join_decodes_a_room_with_its_absences()
        {
            var joined = Answered(
                _harness.Client.Room.JoinAsync("lobby"),
                "room.join",
                JsonValue.NewObject().Set("room", ChatRoom(false)).Set("onlineCount", 1L));

            Assert.That(joined.Room.Avatar, Is.Null);
            Assert.That(joined.Room.Extensions, Is.Null);
            Assert.That(joined.Room.Admins, Is.Empty);
            Assert.That(joined.Room.MaxOnline, Is.Zero, "0 is unlimited");
            Assert.That(joined.Recent, Is.Empty, "an absent buffer is an empty list, never null");
        }

        [Test]
        public void A_full_room_fails_with_the_server_code()
        {
            var pending = _harness.Client.Room.JoinAsync("lobby");
            _harness.Pump();
            _harness.Socket.Reply("room.join", JsonValue.Null, ImErrorCode.RoomFull);
            _harness.Pump();

            Assert.That(pending.IsFaulted, Is.True);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null);
            Assert.That(error.Code, Is.EqualTo(ImErrorCode.RoomFull));
        }

        [Test]
        public void Quit_sends_only_the_room()
        {
            var body = Acknowledged(_harness.Client.Room.QuitAsync(new ImRoomIdRequest("lobby")), "room.quit");
            Assert.That(Keys(body), Is.EqualTo(new[] { "roomId" }));
            Assert.That(body["roomId"].WireString(), Is.EqualTo("lobby"));

            var shorthand = Acknowledged(_harness.Client.Room.QuitAsync("hall"), "room.quit");
            Assert.That(shorthand["roomId"].WireString(), Is.EqualTo("hall"));
        }

        [Test]
        public void Send_fills_in_the_idempotency_key_and_clock_inside_the_nested_message()
        {
            var request = new ImRoomSendRequest("lobby", ImRoomMessage.Text("hi"));
            var pending = _harness.Client.Room.SendAsync(request);
            _harness.Pump();

            var body = _harness.Socket.LastBody("room.send");
            Assert.That(body, Is.Not.Null);
            Assert.That(_harness.Socket.CountOf("msg.send"), Is.Zero, "a room send is not a msg.send");

            Assert.That(Keys(body), Is.EqualTo(new[] { "message", "roomId" }));
            Assert.That(body["roomId"].WireString(), Is.EqualTo("lobby"));

            // Exact camelCase: the binder drops a nested key in any other case, silently.
            var message = body["message"];
            Assert.That(Keys(message), Is.EqualTo(new[] { "clientMsgId", "content", "contentType", "sendTime" }));
            Assert.That(message["contentType"].WireInt(), Is.EqualTo(1), "an enum member takes its integer");
            Assert.That(message["content"]["text"].WireString(), Is.EqualTo("hi"));
            Assert.That(message["clientMsgId"].WireString(), Is.Not.Empty, "the server answers 1001 without one");
            Assert.That(message["sendTime"].WireLong(), Is.GreaterThan(0));
            Assert.That(request.Message.ClientMsgId, Is.Null, "the caller's request is not modified");

            _harness.Socket.Reply("room.send", SendResult());
            _harness.Pump();
            Assert.That(pending.IsCompleted && !pending.IsFaulted, Is.True);
        }

        [Test]
        public void Send_with_every_member_sends_each_in_the_servers_kind_and_nothing_else()
        {
            ImTestHarness.Forget(_harness.Client.Room.SendAsync(new ImRoomSendRequest
            {
                RoomId = "lobby",
                Message = new ImRoomMessage
                {
                    ContentType = ImMessageContentType.Custom,
                    Content = JsonValue.NewObject().Set("gift", "rocket"),
                    ClientMsgId = "room-1",
                    MentionAll = true,
                    MentionedUserIds = new[] { "u_bob" },
                    Options = JsonValue.NewObject().Set("priority", 0L),
                    SendTime = 1758412790000L,
                    Extensions = JsonValue.NewObject().Set("combo", 7L),
                },
            }));
            _harness.Pump();

            var message = _harness.Socket.LastBody("room.send")["message"];

            // No recipient, no quote, no thread: a room is addressed by roomId alone.
            Assert.That(Keys(message), Is.EqualTo(new[]
            {
                "clientMsgId", "content", "contentType", "extensions", "mentionAll", "mentionedUserIds", "options", "sendTime",
            }));
            Assert.That(message["contentType"].WireInt(), Is.EqualTo(100));
            Assert.That(message["clientMsgId"].WireString(), Is.EqualTo("room-1"), "a key the caller gave is kept");
            Assert.That(message["mentionAll"].WireBool(), Is.True);
            Assert.That(message["mentionedUserIds"].WireStrings(), Is.EqualTo(new[] { "u_bob" }));
            Assert.That(message["options"]["priority"].WireInt(), Is.Zero);
            Assert.That(message["sendTime"].WireLong(), Is.EqualTo(1758412790000L), "a clock the caller gave is kept");
            Assert.That(message["extensions"]["combo"].WireLong(), Is.EqualTo(7));
            Assert.That(message["content"]["gift"].WireString(), Is.EqualTo("rocket"));
        }

        /// <summary>
        /// The result of a room send carries seq 0. Handed to the cursor bookkeeping <c>msg.send</c>
        /// does, it would at best do nothing and at worst invent a conversation for <c>r_lobby</c>.
        /// </summary>
        [Test]
        public void A_room_send_result_has_seq_zero_and_moves_no_cursor()
        {
            var savesBefore = Store.Saves;

            var result = Answered(
                _harness.Client.Room.SendAsync(new ImRoomSendRequest("lobby", ImRoomMessage.Text("hi"))),
                "room.send",
                SendResult());

            Assert.That(result.MessageId, Is.EqualTo(360381357961969667L), "a quoted snowflake keeps every digit");
            Assert.That(result.Seq, Is.Zero);
            Assert.That(result.ConversationId, Is.EqualTo("r_lobby"));
            Assert.That(result.ClientMsgId, Is.EqualTo("room-1"));
            Assert.That(result.CreateTime, Is.EqualTo(1755000000123L));
            Assert.That(result.Deduplicated, Is.True);
            Assert.That(result.ContentModified, Is.True);

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "nothing to repair");
            Assert.That(_harness.Client.DeliveredSeqOf("r_lobby"), Is.Zero);
            Assert.That(_harness.Client.CommittedSeqOf("r_lobby"), Is.Zero);
            Assert.That(_harness.Client.CurrentCursors.ConvSeqs.ContainsKey("r_lobby"), Is.False);
            Assert.That(Store.Saves, Is.EqualTo(savesBefore), "a room send writes nothing to the cursor store");
        }

        [Test]
        public void A_refused_send_fails_with_the_server_code()
        {
            var pending = _harness.Client.Room.SendAsync(new ImRoomSendRequest("lobby", ImRoomMessage.Text("hi")));
            _harness.Pump();
            _harness.Socket.Reply("room.send", JsonValue.Null, ImErrorCode.NotInRoom);
            _harness.Pump();

            Assert.That(pending.IsFaulted, Is.True);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null);
            Assert.That(error.Code, Is.EqualTo(ImErrorCode.NotInRoom));
        }

        [Test]
        public void Online_count_reads_a_bare_number()
        {
            var count = Answered(_harness.Client.Room.OnlineCountAsync(new ImRoomIdRequest("lobby")), "room.onlineCount", JsonValue.Of(4294967296L));

            var body = _harness.Socket.LastBody("room.onlineCount");
            Assert.That(Keys(body), Is.EqualTo(new[] { "roomId" }));
            Assert.That(body["roomId"].WireString(), Is.EqualTo("lobby"));
            Assert.That(count, Is.EqualTo(4294967296L), "a long, not an int");

            var shorthand = Answered(_harness.Client.Room.OnlineCountAsync("hall"), "room.onlineCount", JsonValue.Of(0L));
            Assert.That(_harness.Socket.LastBody("room.onlineCount")["roomId"].WireString(), Is.EqualTo("hall"));
            Assert.That(shorthand, Is.Zero, "an unknown room answers 0, not 1600");
        }

        [Test]
        public void Member_list_sends_the_default_limit_and_returns_a_page_of_user_ids()
        {
            var first = Answered(
                _harness.Client.Room.MemberListAsync(new ImRoomCursorRequest("lobby")),
                "room.memberList",
                JsonValue.NewObject()
                    .Set("items", JsonValue.ArrayOf(new[] { "u_alice", "u_bob" }))
                    .Set("nextCursor", "members:2")
                    .Set("hasMore", true));

            var body = _harness.Socket.LastBody("room.memberList");
            Assert.That(Keys(body), Is.EqualTo(new[] { "limit", "roomId" }));
            Assert.That(body["limit"].WireInt(), Is.EqualTo(50));

            Assert.That(first.Items, Is.EqualTo(new[] { "u_alice", "u_bob" }));
            Assert.That(first.NextCursor, Is.EqualTo("members:2"));
            Assert.That(first.HasMore, Is.True);
            Assert.That(first.Total, Is.Null, "a sample has no total, and null is not zero");

            var next = Answered(
                _harness.Client.Room.MemberListAsync(new ImRoomCursorRequest("lobby") { Cursor = first.NextCursor, Limit = 20 }),
                "room.memberList",
                JsonValue.NewObject().Set("items", JsonValue.NewArray()).Set("hasMore", false));

            var paged = _harness.Socket.LastBody("room.memberList");
            Assert.That(Keys(paged), Is.EqualTo(new[] { "cursor", "limit", "roomId" }));
            Assert.That(paged["cursor"].WireString(), Is.EqualTo("members:2"));
            Assert.That(paged["limit"].WireInt(), Is.EqualTo(20));
            Assert.That(next.Items, Is.Empty);
            Assert.That(next.HasMore, Is.False);
        }

        [Test]
        public void Mute_sends_each_optional_member_only_when_it_is_set()
        {
            var member = Acknowledged(
                _harness.Client.Room.MuteAsync(new ImRoomMuteRequest("lobby", "u_bob", 1758499200000L)),
                "room.mute");
            Assert.That(Keys(member), Is.EqualTo(new[] { "roomId", "untilMs", "userId" }));
            Assert.That(member["userId"].WireString(), Is.EqualTo("u_bob"));
            Assert.That(member["untilMs"].WireLong(), Is.EqualTo(1758499200000L));

            // userId absent is the whole room; untilMs present is "until then".
            var room = Acknowledged(
                _harness.Client.Room.MuteAsync(new ImRoomMuteRequest("lobby", null, 1758499200000L)),
                "room.mute");
            Assert.That(Keys(room), Is.EqualTo(new[] { "roomId", "untilMs" }));

            // untilMs absent lifts it.
            var lift = Acknowledged(_harness.Client.Room.MuteAsync(ImRoomMuteRequest.Unmute("lobby", "u_bob")), "room.mute");
            Assert.That(Keys(lift), Is.EqualTo(new[] { "roomId", "userId" }));

            var liftAll = Acknowledged(_harness.Client.Room.MuteAsync(ImRoomMuteRequest.Unmute("lobby")), "room.mute");
            Assert.That(Keys(liftAll), Is.EqualTo(new[] { "roomId" }));
        }

        /// <summary>
        /// Both optional members of a mute mean something when absent, and the absence is the
        /// dangerous half: <c>new ImRoomMuteRequest { RoomId = "lobby", UserId = "bob" }</c> would lift
        /// Bob's mute. So the type has no parameterless constructor.
        /// </summary>
        [Test]
        public void A_mute_request_cannot_be_built_without_saying_who_and_until_when()
        {
            Assert.That(typeof(ImRoomMuteRequest).GetConstructor(Type.EmptyTypes), Is.Null);
            var constructors = typeof(ImRoomMuteRequest).GetConstructors();
            Assert.That(constructors, Has.Length.EqualTo(1));
            Assert.That(constructors[0].GetParameters(), Has.Length.EqualTo(3));
        }

        [Test]
        public void Kick_sends_the_room_and_the_member_and_kicking_the_owner_fails_with_its_code()
        {
            var body = Acknowledged(_harness.Client.Room.KickAsync(new ImRoomKickRequest("lobby", "u_bob")), "room.kick");
            Assert.That(Keys(body), Is.EqualTo(new[] { "roomId", "userId" }));
            Assert.That(body["userId"].WireString(), Is.EqualTo("u_bob"));

            var owner = _harness.Client.Room.KickAsync(new ImRoomKickRequest("lobby", "u_alice"));
            _harness.Pump();
            _harness.Socket.Reply("room.kick", JsonValue.Null, ImErrorCode.CannotOperateOwner);
            _harness.Pump();

            Assert.That(owner.IsFaulted, Is.True);
            Assert.That(((ImException)owner.Exception.GetBaseException()).Code, Is.EqualTo(ImErrorCode.CannotOperateOwner));
        }

        [Test]
        public void A_call_missing_a_required_member_is_refused_before_anything_is_sent()
        {
            var before = _harness.Socket.Requests.Count;

            Assert.Throws<ArgumentException>(delegate { _harness.Client.Room.JoinAsync(string.Empty); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Room.QuitAsync(new ImRoomIdRequest()); });
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Room.JoinAsync((ImRoomIdRequest)null); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Room.MuteAsync(ImRoomMuteRequest.Unmute(null)); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Room.KickAsync(new ImRoomKickRequest("lobby", null)); });

            var faulted = new List<Task>
            {
                _harness.Client.Room.SendAsync(new ImRoomSendRequest("lobby", null)),
                _harness.Client.Room.SendAsync(new ImRoomSendRequest(null, ImRoomMessage.Text("hi"))),
                _harness.Client.Room.OnlineCountAsync(string.Empty),
                _harness.Client.Room.MemberListAsync(new ImRoomCursorRequest()),
            };
            _harness.Pump();

            foreach (var task in faulted)
            {
                Assert.That(task.IsFaulted, Is.True);
                Assert.That(task.Exception.GetBaseException(), Is.InstanceOf<ArgumentException>());
            }

            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before), "nothing reached the socket");
        }

        // ------------------------------------------------------------------ events

        [Test]
        public void Room_events_are_decoded_out_of_evt_system_and_nothing_else_there_is_taken()
        {
            var received = new List<ImRoomEvent>();
            var everything = new List<JsonValue>();

            using (_harness.Client.On(ImPushTarget.System, everything.Add))
            using (_harness.Client.OnRoomEvent(received.Add))
            {
                PushSystem(SystemEvent(ImRoomEvent.Muted, JsonValue.NewObject()
                    .Set("roomId", "lobby")
                    .Set("operatorId", "u_alice")
                    .Set("userId", "u_bob")
                    .Set("untilMs", 1758499200000L)));
                PushSystem(SystemEvent(ImRoomEvent.Muted, JsonValue.NewObject()
                    .Set("roomId", "lobby")
                    .Set("operatorId", "u_mod")));
                PushSystem(SystemEvent(ImRoomEvent.Kicked, JsonValue.NewObject()
                    .Set("roomId", "lobby")
                    .Set("operatorId", "u_alice")
                    .Set("userId", "u_bob")));
                PushSystem(SystemEvent(ImRoomEvent.Destroyed, JsonValue.NewObject()
                    .Set("roomId", "lobby")
                    .Set("operatorId", "ops")));
                PushSystem(SystemEvent("room.renamed", JsonValue.NewObject()
                    .Set("roomId", "lobby")
                    .Set("operatorId", "ops")
                    .Set("name", "Main hall")));

                // Not a room's: another reader of evt.system owns each of these.
                PushSystem(SystemEvent("device.logRequest", JsonValue.NewObject().Set("requestId", "dl_1").Set("expiresAt", 1L)));
                PushSystem(SystemEvent("roomy.thing", JsonValue.NewObject()));
                PushSystem(JsonValue.NewObject().Set("action", "quota.warning"));
                PushSystem(JsonValue.Of("not an object"));
                _harness.Pump();
            }

            Assert.That(everything, Has.Count.EqualTo(9), "the room reader takes nothing away from other subscribers");
            Assert.That(received, Has.Count.EqualTo(5), "only the room.* events come out here");

            Assert.That(received[0].Event, Is.EqualTo(ImRoomEvent.Muted));
            Assert.That(received[0].RoomId, Is.EqualTo("lobby"));
            Assert.That(received[0].OperatorId, Is.EqualTo("u_alice"));
            Assert.That(received[0].UserId, Is.EqualTo("u_bob"));
            Assert.That(received[0].UntilMs, Is.EqualTo(1758499200000L));
            Assert.That(received[0].IsWholeRoom, Is.False);
            Assert.That(received[0].IsMuteInForceAt(1758499199999L), Is.True);
            Assert.That(received[0].IsMuteInForceAt(1758499200000L), Is.False, "a mute ends at untilMs");

            // No member is the whole room; no untilMs is a lift, not an indefinite mute.
            Assert.That(received[1].UserId, Is.Null);
            Assert.That(received[1].UntilMs, Is.Null);
            Assert.That(received[1].IsWholeRoom, Is.True);
            Assert.That(received[1].IsMuteInForceAt(0), Is.False, "an absent untilMs lifted the mute");

            Assert.That(received[2].Event, Is.EqualTo(ImRoomEvent.Kicked));
            Assert.That(received[2].UserId, Is.EqualTo("u_bob"));
            Assert.That(received[2].IsMuteInForceAt(0), Is.False);

            Assert.That(received[3].Event, Is.EqualTo(ImRoomEvent.Destroyed));
            Assert.That(received[3].OperatorId, Is.EqualTo("ops"));
            Assert.That(received[3].UserId, Is.Null);

            // A name this build does not know is delivered with its body, not dropped.
            Assert.That(received[4].Event, Is.EqualTo("room.renamed"));
            Assert.That(received[4].RoomId, Is.EqualTo("lobby"));
            Assert.That(received[4].Body["name"].AsString(), Is.EqualTo("Main hall"));
        }

        /// <summary>
        /// The device-log request rides <c>evt.system</c> too, and the runner that answers it must
        /// still see it with a room reader subscribed. An expired request is the observable case: the
        /// runner logs that it arrived too late, and uploads nothing.
        /// </summary>
        [Test]
        public void A_room_reader_leaves_the_device_log_request_to_its_own_handler()
        {
            var received = new List<ImRoomEvent>();
            using (_harness.Client.OnRoomEvent(received.Add))
            {
                PushSystem(SystemEvent("device.logRequest", JsonValue.NewObject()
                    .Set("requestId", "dl_room")
                    .Set("deviceId", "device-1")
                    .Set("expiresAt", 1L)));
                _harness.Pump();
            }

            Assert.That(received, Is.Empty);
            Assert.That(_harness.Log.Exists(line => line.Contains("dl_room arrived after its window closed")), Is.True,
                "the device-log runner never saw the request; log was:\n" + string.Join("\n", _harness.Log));
        }

        [Test]
        public void A_disposed_room_reader_receives_nothing()
        {
            var received = new List<ImRoomEvent>();
            _harness.Client.OnRoomEvent(received.Add).Dispose();

            PushSystem(SystemEvent(ImRoomEvent.Kicked, JsonValue.NewObject().Set("roomId", "lobby").Set("userId", "u_bob")));
            _harness.Pump();

            Assert.That(received, Is.Empty);
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.OnRoomEvent(null); });
        }

        // ------------------------------------------------------------------ seq 0

        /// <summary>
        /// The rule the inventory writes on <c>room.join</c>: chat rooms are best effort, carry seq 0,
        /// and must bypass the gap-repair path entirely. A seq-0 message fed into repair would either
        /// ask <c>msg.sync</c> for a range that does not exist or be dropped as "already seen".
        /// </summary>
        [Test]
        public void A_room_message_is_delivered_without_a_repair_and_moves_no_cursor()
        {
            var savesBefore = Store.Saves;

            _harness.PushMessage("c1", 5);
            PushRoomMessage("lobby", "gg");
            PushRoomMessage("lobby", "gg again");
            _harness.PushMessage("c1", 6);

            Assert.That(Seqs(), Is.EqualTo(new long[] { 5, 0, 0, 6 }),
                "both room messages are delivered — two seq 0 in a row are not a duplicate");
            Assert.That(_delivered[1].ConversationId, Is.EqualTo("r_lobby"));
            Assert.That(_delivered[1].ConversationType, Is.EqualTo(ImConversationType.ChatRoom));
            Assert.That(_delivered[2].Text, Is.EqualTo("gg again"));

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "a room message asks for no repair");
            Assert.That(_harness.Client.DeliveredSeqOf("r_lobby"), Is.Zero);
            Assert.That(_harness.Client.CommittedSeqOf("r_lobby"), Is.Zero);
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(6), "the real conversation beside it is untouched");
            Assert.That(Store.Saves, Is.EqualTo(savesBefore), "nothing was committed, so nothing was written");
        }

        [Test]
        public void A_room_message_is_not_held_behind_a_repair_in_flight_elsewhere()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 4);
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.EqualTo(1), "c1 is repairing 2..3");

            PushRoomMessage("lobby", "live");

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 0 }), "the room message did not wait for c1's repair");
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.EqualTo(1), "and asked for no repair of its own");

            _harness.Socket.Reply("msg.sync", JsonValue.NewObject().Set("messages", JsonValue.NewArray()
                .Add(ImFrames.MessageJson("c1", 2))
                .Add(ImFrames.MessageJson("c1", 3))));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 0, 2, 3, 4 }));
        }

        /// <summary>
        /// A game that commits everything it stores will commit a room message too. That must not
        /// register <c>r_lobby</c> as a conversation the server is asked about on the next resume.
        /// </summary>
        [Test]
        public void Committing_a_room_message_is_ignored_and_the_room_is_absent_from_the_next_resume()
        {
            _harness.PushMessage("c1", 3);
            _harness.Commit("c1", 3);
            PushRoomMessage("lobby", "gg");

            _harness.Commit(_delivered[1].ConversationId, _delivered[1].Seq);

            Assert.That(_harness.Client.CommittedSeqOf("r_lobby"), Is.Zero);
            Assert.That(Store.StoredSeq("r_lobby"), Is.Zero);
            Assert.That(Store.Stored.ConvSeqs.ContainsKey("r_lobby"), Is.False);

            _harness.Reconnect();

            var resume = _harness.LastResume;
            Assert.That(resume, Is.Not.Null);
            Assert.That(resume["convSeqs"]["c1"].WireLong(), Is.EqualTo(3));
            Assert.That(resume["convSeqs"].Has("r_lobby"), Is.False, "a room has no seq to resume from");
        }

        // ------------------------------------------------------------------ inventory

        /// <summary>
        /// "room.* is typed" is something this suite can fail on: every method is driven, and the
        /// targets that reach the wire are compared with the inventory's own room list.
        /// </summary>
        [Test]
        public void Every_room_endpoint_in_the_inventory_is_typed_here()
        {
            var calls = new List<Task>
            {
                _harness.Client.Room.JoinAsync("lobby"),
                _harness.Client.Room.QuitAsync("lobby"),
                _harness.Client.Room.SendAsync(new ImRoomSendRequest("lobby", ImRoomMessage.Text("hi"))),
                _harness.Client.Room.OnlineCountAsync("lobby"),
                _harness.Client.Room.MemberListAsync(new ImRoomCursorRequest("lobby")),
                _harness.Client.Room.MuteAsync(ImRoomMuteRequest.Unmute("lobby")),
                _harness.Client.Room.KickAsync(new ImRoomKickRequest("lobby", "u_bob")),
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

            var rooms = new List<string>();
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                var target = endpoint["target"].AsString();
                if (target.StartsWith("room.", StringComparison.Ordinal))
                {
                    rooms.Add(target);
                }
            }

            Assert.That(rooms, Has.Count.EqualTo(7), "the inventory's room list parsed to the wrong size");

            var missing = rooms.FindAll(target => !sent.Contains(target));
            Assert.That(missing, Is.Empty, "room endpoints no typed method sends: " + string.Join(", ", missing.ToArray()));
        }

        /// <summary>
        /// The decoding tests above are only as wide as their fixtures, and the frame tests only as wide
        /// as the bodies they build: so the full fixtures carry every member the server's response types
        /// declare, and the full request bodies every member its request types declare — both held here
        /// to the inventory's <c>payloadTypes</c>.
        /// </summary>
        [Test]
        public void The_full_fixtures_and_bodies_carry_every_member_the_server_declares()
        {
            Assert.That(Members("ChatRoom"), Is.Not.Empty);
            Assert.That(Keys(ChatRoom(true)), Is.EqualTo(Members("ChatRoom")));
            Assert.That(Keys(JoinResult()), Is.EqualTo(Members("RoomJoinResult")));
            Assert.That(Keys(SendResult()), Is.EqualTo(Members("SendMessageResult")));

            Assert.That(Keys(new ImRoomIdRequest("lobby").ToJson()), Is.EqualTo(Members("RoomIdRequest")));
            Assert.That(Keys(new ImRoomCursorRequest("lobby") { Cursor = "c" }.ToJson()), Is.EqualTo(Members("RoomCursorRequest")));
            Assert.That(Keys(new ImRoomMuteRequest("lobby", "u_bob", 1L).ToJson()), Is.EqualTo(Members("RoomMuteRequest")));
            Assert.That(Keys(new ImRoomKickRequest("lobby", "u_bob").ToJson()), Is.EqualTo(Members("RoomKickRequest")));
            Assert.That(Keys(new ImRoomSendRequest("lobby", ImRoomMessage.Text("hi")).ToJson()), Is.EqualTo(Members("RoomSendRequest")));
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
