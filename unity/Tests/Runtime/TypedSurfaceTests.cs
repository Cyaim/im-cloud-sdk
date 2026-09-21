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
    /// The typed endpoint surface: tiers T0, T1, T2 and T3 of <c>sdk/CONTRACT.md</c> §3.
    /// </summary>
    /// <remarks>
    /// <para>
    /// These assert the target string every method puts on the wire, because the endpoint name is
    /// the contract and a rename is a silent break — the call compiles, ships, and comes back
    /// <c>1008 UnsupportedOperation</c> against the customer's server. The naming rule is that the
    /// method is the method half of the target and nothing else: <c>msg.cancelScheduled</c> becomes
    /// <c>CancelScheduledAsync</c>, never <c>UnscheduleAsync</c>, however much better that reads.
    /// </para>
    /// <para>
    /// They also pin the request bodies, since a field name is as load-bearing as a target and just
    /// as invisible when wrong: the server ignores what it does not recognise, so a misspelled
    /// <c>beforeSeq</c> is a history call that quietly returns the wrong page.
    /// </para>
    /// </remarks>
    public sealed class TypedSurfaceTests
    {
        private ImTestHarness _harness;

        [SetUp]
        public void SetUp()
        {
            _harness = new ImTestHarness();
            _harness.Connect();
        }

        [TearDown]
        public void TearDown()
        {
            _harness.Dispose();
        }

        // -------------------------------------------------------------------- T0

        [Test]
        public void The_session_floor_is_reachable()
        {
            Sent("conn.heartbeat", _harness.Client.Conn.HeartbeatAsync());

            var reauth = Sent("conn.reauth", _harness.Client.Conn.ReauthAsync("token-2"));
            Assert.That(reauth["token"].WireString(), Is.EqualTo("token-2"));

            var sync = Sent("conn.sync", _harness.Client.Conn.SyncAsync(new ImResumeRequest
            {
                ConvSeqs = new Dictionary<string, long> { { "c1", 40 } },
                ConversationCursor = 99,
                Limit = 200,
            }));

            Assert.That(sync["convSeqs"]["c1"].WireLong(), Is.EqualTo(40));
            Assert.That(sync["conversationCursor"].WireLong(), Is.EqualTo(99));
            Assert.That(sync["limit"].WireInt(), Is.EqualTo(200));
        }

        [Test]
        public void A_heartbeat_result_carries_what_a_support_ticket_needs()
        {
            var pending = _harness.Client.Conn.HeartbeatAsync();
            _harness.Pump();

            _harness.Socket.Reply("conn.heartbeat", JsonValue.NewObject()
                .Set("serverTime", 1767225600000L)
                .Set("intervalSeconds", 45L)
                .Set("healed", true)
                .Set("connectionId", "conn-7")
                .Set("nodeId", "gw-2"));
            _harness.Pump();

            var result = pending.Result;
            Assert.That(result.IntervalSeconds, Is.EqualTo(45));
            Assert.That(result.Healed, Is.True);
            Assert.That(result.ConnectionId, Is.EqualTo("conn-7"));
            Assert.That(result.NodeId, Is.EqualTo("gw-2"));
        }

        // -------------------------------------------------------------------- T1

        [Test]
        public void The_message_endpoints_are_reachable()
        {
            var send = Sent(
                "msg.send",
                _harness.Client.Msg.SendAsync(ImTestHarness.TextMessage(ImRecipient.User("bob"), "hi")));
            Assert.That(send["receiverId"].WireString(), Is.EqualTo("bob"));
            Assert.That(send["contentType"].WireInt(), Is.EqualTo((int)ImMessageContentType.Text));

            var sync = Sent("msg.sync", _harness.Client.Msg.SyncAsync(new ImSyncMessagesRequest
            {
                ConversationId = "c1",
                FromSeq = 10,
                ToSeq = 20,
                Limit = 11,
            }));
            Assert.That(sync["fromSeq"].WireLong(), Is.EqualTo(10));
            Assert.That(sync["toSeq"].WireLong(), Is.EqualTo(20));
            Assert.That(sync["ascending"].WireBool(), Is.True);

            var history = Sent("msg.history", _harness.Client.Msg.HistoryAsync(new ImHistoryRequest
            {
                ConversationId = "c1",
                BeforeSeq = 40,
                Limit = 30,
            }));
            Assert.That(history["beforeSeq"].WireLong(), Is.EqualTo(40));
            Assert.That(history["limit"].WireInt(), Is.EqualTo(30));

            var recall = Sent("msg.recall", _harness.Client.Msg.RecallAsync(new ImRecallMessageRequest
            {
                ConversationId = "c1",
                MessageId = "900",
                Reason = "typo",
            }));
            Assert.That(recall["messageId"].WireString(), Is.EqualTo("900"));
            Assert.That(recall.Has("asAdmin"), Is.False,
                "the server forces admin recall off for a client, so a field for it would be a lie");

            var delete = Sent("msg.delete", _harness.Client.Msg.DeleteAsync(new ImDeleteMessagesRequest
            {
                ConversationId = "c1",
                MessageIds = new List<string> { "9007199254740993" },
            }));
            Assert.That(delete["messageIds"][0].WireString(), Is.EqualTo("9007199254740993"),
                "a snowflake id past 2^53 must not be rounded on the way out, which is why it "
                + "travels as a JSON string rather than a JSON number");
            Assert.That(delete["forEveryone"].WireBool(), Is.False);

            var typing = Sent("msg.typing", _harness.Client.Msg.TypingAsync(
                new ImTypingRequest { ConversationId = "c1" }));
            Assert.That(typing["typing"].WireBool(), Is.True);
        }

        [Test]
        public void The_conversation_endpoints_are_reachable()
        {
            var list = Sent("conv.list", _harness.Client.Conv.ListAsync(new ImListConversationsRequest
            {
                UpdatedAfter = 1767225600000L,
                Cursor = "page-2",
                Limit = 100,
            }));
            Assert.That(list["updatedAfter"].WireLong(), Is.EqualTo(1767225600000L));
            Assert.That(list["cursor"].WireString(), Is.EqualTo("page-2"));

            var get = Sent("conv.get", _harness.Client.Conv.GetAsync("c1"));
            Assert.That(get["conversationId"].WireString(), Is.EqualTo("c1"));

            var read = Sent("conv.read", _harness.Client.Conv.ReadAsync("c1", 42));
            Assert.That(read["readSeq"].WireLong(), Is.EqualTo(42));

            Sent("conv.unreadTotal", _harness.Client.Conv.UnreadTotalAsync());
        }

        [Test]
        public void The_user_endpoints_are_reachable()
        {
            Sent("user.me", _harness.Client.User.MeAsync());

            var profile = Sent("user.profile", _harness.Client.User.ProfileAsync("bob"));
            Assert.That(profile["userId"].WireString(), Is.EqualTo("bob"));

            var batch = Sent("user.batchProfile",
                _harness.Client.User.BatchProfileAsync(new[] { "bob", "carol" }));
            Assert.That(batch["userIds"].Count, Is.EqualTo(2));

            var update = Sent("user.updateProfile", _harness.Client.User.UpdateProfileAsync(
                new ImUpdateProfileRequest(JsonValue.NewObject().Set("nickname", "Alice"))));
            Assert.That(update["patch"]["nickname"].WireString(), Is.EqualTo("Alice"));
        }

        [Test]
        public void The_media_endpoints_are_reachable()
        {
            var ticket = Sent("media.uploadTicket", _harness.Client.Media.UploadTicketAsync(
                new ImUploadTicketRequest
                {
                    FileName = "screenshot.png",
                    ContentType = "image/png",
                    Size = 12345,
                }));
            Assert.That(ticket["fileName"].WireString(), Is.EqualTo("screenshot.png"));
            Assert.That(ticket["size"].WireLong(), Is.EqualTo(12345));

            var download = Sent("media.downloadUrl", _harness.Client.Media.DownloadUrlAsync("app/alice/x.png"));
            Assert.That(download["objectKey"].WireString(), Is.EqualTo("app/alice/x.png"));
            Assert.That(download["lifetimeSeconds"].WireInt(), Is.EqualTo(3600));
        }

        [Test]
        public void An_upload_ticket_decodes_to_the_key_that_goes_in_the_message()
        {
            var pending = _harness.Client.Media.UploadTicketAsync(new ImUploadTicketRequest
            {
                FileName = "a.png",
                ContentType = "image/png",
                Size = 1,
            });
            _harness.Pump();

            _harness.Socket.Reply("media.uploadTicket", JsonValue.NewObject()
                .Set("objectKey", "app/alice/a.png")
                .Set("uploadUrl", "https://s3.example.com/put")
                .Set("downloadUrl", "https://s3.example.com/get")
                .Set("expiresAt", 1767225600000L));
            _harness.Pump();

            Assert.That(pending.Result.ObjectKey, Is.EqualTo("app/alice/a.png"));
            Assert.That(pending.Result.UploadUrl, Is.EqualTo("https://s3.example.com/put"));
            Assert.That(pending.Result.FormFields, Is.Null, "absent is not empty, and both are legal");
        }

        [Test]
        public void The_push_endpoints_are_reachable()
        {
            var register = Sent("push.register", _harness.Client.Push.RegisterAsync(
                new ImRegisterPushTokenRequest(ImPushProvider.Huawei, "hms-token", "zh-CN")));
            Assert.That(register["provider"].WireString(), Is.EqualTo("huawei"));
            Assert.That(register["language"].WireString(), Is.EqualTo("zh-CN"));

            Sent("push.unregister", _harness.Client.Push.UnregisterAsync());
        }

        // -------------------------------------------------------------------- T2

        [Test]
        public void The_group_endpoints_are_reachable()
        {
            var create = Sent("group.create", _harness.Client.Group.CreateAsync(new ImCreateGroupRequest
            {
                Name = "Raid party",
                Type = ImGroupType.Normal,
                MemberIds = new List<string> { "bob", "carol" },
                JoinMode = ImGroupJoinMode.NeedApproval,
                MaxMemberCount = 200,
            }));
            Assert.That(create["name"].WireString(), Is.EqualTo("Raid party"));
            Assert.That(create["type"].WireInt(), Is.EqualTo((int)ImGroupType.Normal));
            Assert.That(create["joinMode"].WireInt(), Is.EqualTo((int)ImGroupJoinMode.NeedApproval));
            Assert.That(create["maxMemberCount"].WireInt(), Is.EqualTo(200));

            Sent("group.info", _harness.Client.Group.InfoAsync("g1"));

            var update = Sent("group.update", _harness.Client.Group.UpdateAsync(new ImUpdateGroupCommand(
                "g1",
                new ImUpdateGroupRequest { Name = "Raiders", InviteMode = ImGroupInviteMode.AdminsOnly })));
            Assert.That(update["update"]["name"].WireString(), Is.EqualTo("Raiders"));
            Assert.That(update["update"]["inviteMode"].WireInt(), Is.EqualTo((int)ImGroupInviteMode.AdminsOnly));
            Assert.That(update["update"].Has("avatar"), Is.False, "a member left null is not a member set to null");

            Sent("group.dismiss", _harness.Client.Group.DismissAsync(new ImGroupIdRequest("g1")));

            var members = Sent("group.memberList", _harness.Client.Group.MemberListAsync(
                new ImGroupCursorRequest("g1") { Cursor = "m2", Limit = 100 }));
            Assert.That(members["cursor"].WireString(), Is.EqualTo("m2"));

            Sent("group.joined", _harness.Client.Group.JoinedAsync());

            var invite = Sent("group.invite", _harness.Client.Group.InviteAsync(new ImGroupMembersRequest
            {
                GroupId = "g1",
                UserIds = new List<string> { "dave" },
                Reason = "guild recruit",
            }));
            Assert.That(invite["userIds"][0].WireString(), Is.EqualTo("dave"));
            Assert.That(invite["reason"].WireString(), Is.EqualTo("guild recruit"));

            Sent("group.kick", _harness.Client.Group.KickAsync(new ImGroupMembersRequest
            {
                GroupId = "g1",
                UserIds = new List<string> { "dave" },
            }));

            Sent("group.quit", _harness.Client.Group.QuitAsync(new ImGroupIdRequest("g1")));

            var join = Sent("group.join", _harness.Client.Group.JoinAsync(new ImJoinGroupRequest("g1", "let me in")));
            Assert.That(join["reason"].WireString(), Is.EqualTo("let me in"));
        }

        [Test]
        public void The_friend_endpoints_are_reachable()
        {
            Sent("friend.list", _harness.Client.Friend.ListAsync());

            var add = Sent("friend.add", _harness.Client.Friend.AddAsync(new ImAddFriendRequest
            {
                UserId = "bob",
                Greeting = "hi",
                Source = "search",
            }));
            Assert.That(add["greeting"].WireString(), Is.EqualTo("hi"));

            var handle = Sent("friend.handleRequest", _harness.Client.Friend.HandleRequestAsync(
                new ImHandleFriendRequest { FromUserId = "bob", Accept = true }));
            Assert.That(handle["accept"].WireBool(), Is.True);

            var requests = Sent("friend.requestList", _harness.Client.Friend.RequestListAsync(
                new ImFriendRequestListRequest { Incoming = false }));
            Assert.That(requests["incoming"].WireBool(), Is.False);

            Sent("friend.delete", _harness.Client.Friend.DeleteAsync(new ImUserIdRequest("bob")));
            Sent("friend.blockList", _harness.Client.Friend.BlockListAsync());

            var block = Sent("friend.block", _harness.Client.Friend.BlockAsync("bob", "harassment"));
            Assert.That(block["reason"].WireString(), Is.EqualTo("harassment"));

            Sent("friend.unblock", _harness.Client.Friend.UnblockAsync("bob"));
        }

        [Test]
        public void The_presence_endpoints_are_reachable()
        {
            Sent("user.presence", _harness.Client.User.PresenceAsync(new[] { "bob" }));

            var subscribe = Sent("user.subscribePresence", _harness.Client.User.SubscribePresenceAsync(
                new ImSubscribePresenceRequest { UserIds = new List<string> { "bob" }, TtlSeconds = 900 }));
            Assert.That(subscribe["ttlSeconds"].WireInt(), Is.EqualTo(900));

            Sent("user.unsubscribePresence",
                _harness.Client.User.UnsubscribePresenceAsync(new ImUserIdsRequest(new[] { "bob" })));
        }

        [Test]
        public void The_remaining_conversation_and_message_operations_are_reachable()
        {
            var setting = Sent("conv.setting", _harness.Client.Conv.SettingAsync(
                new ImUpdateConversationSettingRequest
                {
                    ConversationId = "c1",
                    Setting = new ImConversationSetting { Pinned = true, Muted = ImMuteMode.NoPush },
                }));
            Assert.That(setting["setting"]["pinned"].WireBool(), Is.True);
            Assert.That(setting["setting"]["muted"].WireInt(), Is.EqualTo((int)ImMuteMode.NoPush));
            Assert.That(setting["setting"].Has("draft"), Is.False);

            Sent("conv.delete", _harness.Client.Conv.DeleteAsync(new ImConversationIdRequest("c1")));
            Sent("conv.clear", _harness.Client.Conv.ClearAsync(new ImConversationIdRequest("c1")));

            var edit = Sent("msg.edit", _harness.Client.Msg.EditAsync(new ImEditMessageRequest
            {
                ConversationId = "c1",
                MessageId = "5",
                Content = JsonValue.NewObject().Set("text", "fixed"),
            }));
            Assert.That(edit["content"]["text"].WireString(), Is.EqualTo("fixed"));

            var forward = Sent("msg.forward", _harness.Client.Msg.ForwardAsync(new ImForwardMessagesRequest
            {
                SourceConversationId = "c1",
                MessageIds = new List<string> { "5", "6" },
                TargetConversationIds = new List<string> { "c2" },
                Merge = true,
                MergeTitle = "yesterday",
            }));
            Assert.That(forward["merge"].WireBool(), Is.True);
            Assert.That(forward["clientMsgId"].WireString(), Is.Not.Empty,
                "a forward is a send, so it gets an idempotency key without being asked");

            var react = Sent("msg.react", _harness.Client.Msg.ReactAsync(new ImReactRequest
            {
                ConversationId = "c1",
                MessageId = "5",
                Emoji = "👍",
            }));
            Assert.That(react["emoji"].WireString(), Is.EqualTo("👍"));
            Assert.That(react["add"].WireBool(), Is.True);

            var receipt = Sent("msg.receipt", _harness.Client.Msg.ReceiptAsync(new ImReceiptRequest
            {
                ConversationId = "c1",
                MessageIds = new List<string> { "5" },
            }));
            Assert.That(receipt["messageIds"][0].WireString(), Is.EqualTo("5"));
        }

        /// <summary>The reporter is the connection, so the body has nowhere to name one.</summary>
        /// <remarks>
        /// A member for the reporter would let one account file in another's name, and the body is
        /// the only place such a member could live — which is why its absence is asserted rather
        /// than assumed. The rest is what a report screen collects.
        /// </remarks>
        [Test]
        public void The_moderation_endpoint_is_reachable()
        {
            var report = Sent("moderation.report", _harness.Client.Moderation.ReportAsync(
                new ImSubmitReportRequest
                {
                    TargetUserId = "bob",
                    ConversationId = "c1",
                    MessageId = "9007199254740993",
                    Category = ImReportCategory.Harassment,
                    Note = "kept whispering after I asked him to stop",
                }));

            Assert.That(report["targetUserId"].WireString(), Is.EqualTo("bob"));
            Assert.That(report["category"].WireString(), Is.EqualTo("harassment"));
            Assert.That(report["messageId"].WireString(), Is.EqualTo("9007199254740993"),
                "a snowflake id past 2^53 travels quoted, so it must not be written as a number");
            Assert.That(report.Has("reporterId"), Is.False,
                "the reporter is the socket; a field for it is a way to file in somebody else's name");
            Assert.That(report.Has("userId"), Is.False);
        }

        /// <summary>Reporting the account rather than one message is spelled "no message id".</summary>
        /// <remarks>
        /// A report screen with the message box left blank is the ordinary way to report an account.
        /// The server reads this member as a string and takes absent, blank or "0" as the account;
        /// an older one took a number and answered <c>1000</c> for "", so the SDK omits it.
        /// </remarks>
        [Test]
        public void A_report_with_no_message_names_no_message()
        {
            var report = Sent("moderation.report", _harness.Client.Moderation.ReportAsync(
                new ImSubmitReportRequest { TargetUserId = "bob", MessageId = string.Empty }));

            Assert.That(report.Has("messageId"), Is.False);
            Assert.That(report.Has("conversationId"), Is.False, "a member left null is not a member set to null");
        }

        /// <summary>The tap that closes the delivery funnel of §6.2.</summary>
        [Test]
        public void A_notification_tap_is_reported_with_what_the_payload_carried()
        {
            var clicked = Sent("push.clicked", _harness.Client.Push.ClickedAsync(
                new ImPushClickedRequest { MessageId = "9007199254740993", PushId = "pu_7f3" }));

            Assert.That(clicked["pushId"].WireString(), Is.EqualTo("pu_7f3"));
            Assert.That(clicked["messageId"].WireString(), Is.EqualTo("9007199254740993"));
            Assert.That(clicked.Has("deviceId"), Is.False, "the row is found from the socket, never from the body");
            Assert.That(clicked.Has("userId"), Is.False);

            // A tap that opened the game without naming anything is the common case on Android,
            // where the vendor batches notifications and the extras the app gets back are whatever
            // survived that. The server credits this device's newest delivery.
            var bare = Sent("push.clicked", _harness.Client.Push.ClickedAsync());
            Assert.That(bare.Has("messageId"), Is.False);
            Assert.That(bare.Has("pushId"), Is.False);
        }

        // -------------------------------------------------------------------- T3
        //
        // These assert the JSON *kind* of every member, not only its value. The gateway binds a
        // socket request member by member and refuses a value of the wrong kind outright — a number
        // for a string member, a quoted number for a long, a name for an enum — so a body that reads
        // correctly and has one member of the wrong kind is a call that comes back
        // 1000 InternalError on every attempt. AsString() on a number reads just fine; only the
        // kind tells the two apart.
        // 这里断言每个字段的 JSON 类型而不只是值：网关的套接字绑定器对类型不对的字段直接回 1000。

        [Test]
        public void The_message_addressing_endpoints_send_the_id_as_a_string()
        {
            var calls = new Dictionary<string, Func<ImConversationMessageRequest, Task>>
            {
                { "msg.pin", r => _harness.Client.Msg.PinAsync(r) },
                { "msg.unpin", r => _harness.Client.Msg.UnpinAsync(r) },
                { "msg.favourite", r => _harness.Client.Msg.FavouriteAsync(r) },
                { "msg.unfavourite", r => _harness.Client.Msg.UnfavouriteAsync(r) },
                { "msg.burn", r => _harness.Client.Msg.BurnAsync(r) },
            };

            foreach (var call in calls)
            {
                var body = Sent(call.Key, call.Value(new ImConversationMessageRequest("c1", Snowflake)));

                AssertKeys(body, "conversationId", "messageId");
                AssertKind(body, "conversationId", JsonKind.String);
                AssertKind(body, "messageId", JsonKind.String);
                Assert.That(body["messageId"].WireString(), Is.EqualTo(Snowflake),
                    call.Key + ": every digit of an id past 2^53 has to arrive");
            }
        }

        [TestCase("")]
        [TestCase(null)]
        [TestCase("0")]
        [TestCase("-5")]
        [TestCase(" 5")]
        [TestCase("5a")]
        [TestCase("1,000")]
        [TestCase("99999999999999999999")]
        public void A_message_id_the_server_could_not_read_is_refused_before_it_is_sent(string messageId)
        {
            // msg.unpin answers 0 — success — for an id it cannot parse, so without this check the
            // caller would be told the pin came off when nothing happened at all.
            var request = new ImConversationMessageRequest("c1", messageId);

            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.UnpinAsync(request); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.UnfavouriteAsync(request); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.PinAsync(request); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.FavouriteAsync(request); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.BurnAsync(request); });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Msg.ReceiptDetailAsync(new ImReceiptDetailRequest("c1", messageId));
            });

            _harness.Pump();
            Assert.That(_harness.Socket.CountOf("msg.unpin") + _harness.Socket.CountOf("msg.unfavourite")
                        + _harness.Socket.CountOf("msg.pin") + _harness.Socket.CountOf("msg.favourite")
                        + _harness.Socket.CountOf("msg.burn") + _harness.Socket.CountOf("msg.receiptDetail"),
                Is.Zero, "a refused id never reaches the wire");
        }

        [Test]
        public void The_pin_board_is_a_list_and_keeps_every_digit_of_the_id()
        {
            var pending = _harness.Client.Msg.PinsAsync(new ImConversationIdRequest("g_team"));
            _harness.Pump();

            var body = _harness.Socket.LastBody("msg.pins");
            AssertKeys(body, "conversationId");
            Assert.That(body["conversationId"].WireString(), Is.EqualTo("g_team"));

            _harness.Socket.Reply("msg.pins", JsonValue.NewArray()
                .Add(JsonValue.NewObject()
                    .Set("messageId", Snowflake)
                    .Set("seq", 88L)
                    .Set("pinnedBy", "alice")
                    .Set("pinnedAt", 1767225600000L)
                    .Set("brief", JsonValue.NewObject()
                        .Set("messageId", Snowflake)
                        .Set("seq", 88L)
                        .Set("senderId", "bob")
                        .Set("contentType", (long)ImMessageContentType.Image)
                        .Set("digest", "[Recalled]")
                        .Set("createTime", 1767225500000L)
                        .Set("recalled", true)))
                .Add(JsonValue.NewObject()
                    .Set("messageId", "7")
                    .Set("seq", 3L)
                    .Set("pinnedBy", "bob")
                    .Set("pinnedAt", 1767225400000L)));
            _harness.Pump();

            var pins = pending.Result;
            Assert.That(pins, Has.Count.EqualTo(2));
            Assert.That(pins[0].MessageId, Is.EqualTo(SnowflakeValue),
                "the id arrives quoted and must not pass through a double on the way in");
            Assert.That(pins[0].Seq, Is.EqualTo(88));
            Assert.That(pins[0].PinnedBy, Is.EqualTo("alice"));
            Assert.That(pins[0].PinnedAt, Is.EqualTo(1767225600000L));
            Assert.That(pins[0].Brief, Is.Not.Null);
            Assert.That(pins[0].Brief.MessageId, Is.EqualTo(SnowflakeValue));
            Assert.That(pins[0].Brief.ContentType, Is.EqualTo(ImMessageContentType.Image));
            Assert.That(pins[0].Brief.Digest, Is.EqualTo("[Recalled]"));
            Assert.That(pins[0].Brief.Recalled, Is.True);
            Assert.That(pins[1].MessageId, Is.EqualTo(7));
            Assert.That(pins[1].Brief, Is.Null, "absent is not an empty brief");
        }

        [Test]
        public void Favourites_page_on_the_cursor_and_decode_as_messages()
        {
            var defaults = Sent("msg.favourites", _harness.Client.Msg.FavouritesAsync());
            AssertKeys(defaults, "limit");
            AssertKind(defaults, "limit", JsonKind.Number);
            Assert.That(defaults["limit"].WireInt(), Is.EqualTo(20), "the server's own default, sent explicitly");

            var pending = _harness.Client.Msg.FavouritesAsync(new ImPageRequest { Cursor = "fav-2", Limit = 50 });
            _harness.Pump();

            var body = _harness.Socket.LastBody("msg.favourites");
            AssertKeys(body, "cursor", "limit");
            AssertKind(body, "cursor", JsonKind.String);
            Assert.That(body["limit"].WireInt(), Is.EqualTo(50));

            // Answer the second request; the first is still waiting and is not the one under test.
            _harness.Socket.ReplyMatching("msg.favourites", b => b.Has("cursor"), JsonValue.NewObject()
                .Set("items", JsonValue.NewArray().Add(ImFrames.MessageJson("c1", 12)
                    .Set("messageId", Snowflake)
                    .Set("recalled", JsonValue.NewObject().Set("operatorId", "bob").Set("recallTime", 1L))))
                .Set("nextCursor", "fav-3")
                .Set("hasMore", true));
            _harness.Pump();

            var page = pending.Result;
            Assert.That(page.Items, Has.Count.EqualTo(1));
            Assert.That(page.Items[0].MessageId, Is.EqualTo(SnowflakeValue));
            Assert.That(page.Items[0].Seq, Is.EqualTo(12));
            Assert.That(page.Items[0].Recalled, Is.Not.Null, "recalled favourites are listed, flagged");
            Assert.That(page.NextCursor, Is.EqualTo("fav-3"));
            Assert.That(page.HasMore, Is.True);
            Assert.That(page.Total, Is.Null, "the server never counts favourites; null is not zero");
        }

        [Test]
        public void A_search_sends_its_filters_as_numbers_and_its_ids_as_strings()
        {
            var full = Sent("msg.search", _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest("invoice")
            {
                ConversationId = "g_team",
                ContentTypes = new List<ImMessageContentType> { ImMessageContentType.Image, ImMessageContentType.File },
                SenderId = "bob",
                StartTime = 1756684800000L,
                EndTime = 1767225600000L,
                Cursor = "s2",
                Limit = 40,
            }));

            AssertKeys(full, "keyword", "conversationId", "contentTypes", "senderId", "startTime", "endTime", "cursor", "limit");
            AssertKind(full, "keyword", JsonKind.String);
            AssertKind(full, "conversationId", JsonKind.String);
            AssertKind(full, "senderId", JsonKind.String);
            AssertKind(full, "startTime", JsonKind.Number);
            AssertKind(full, "endTime", JsonKind.Number);
            AssertKind(full, "limit", JsonKind.Number);
            AssertKind(full, "contentTypes", JsonKind.Array);
            Assert.That(full["contentTypes"].Count, Is.EqualTo(2));
            Assert.That(full["contentTypes"][0].Kind, Is.EqualTo(JsonKind.Number),
                "an enum member takes an integer; the binder refuses the name");
            Assert.That(full["contentTypes"][0].WireInt(), Is.EqualTo(2));
            Assert.That(full["contentTypes"][1].WireInt(), Is.EqualTo(5));
            Assert.That(full["startTime"].WireLong(), Is.EqualTo(1756684800000L));
            Assert.That(full["limit"].WireInt(), Is.EqualTo(40));

            var bare = Sent("msg.search", _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest("invoice")));
            AssertKeys(bare, "keyword", "limit");
        }

        [Test]
        public void A_search_page_decodes_to_messages()
        {
            var pending = _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest("raid"));
            _harness.Pump();

            _harness.Socket.Reply("msg.search", JsonValue.NewObject()
                .Set("items", JsonValue.NewArray().Add(ImFrames.MessageJson("g_team", 30, JsonValue.NewObject().Set("text", "raid at 9"))
                    .Set("messageId", Snowflake)))
                .Set("nextCursor", "s2")
                .Set("hasMore", true));
            _harness.Pump();

            var page = pending.Result;
            Assert.That(page.Items, Has.Count.EqualTo(1));
            Assert.That(page.Items[0].MessageId, Is.EqualTo(SnowflakeValue));
            Assert.That(page.Items[0].Text, Is.EqualTo("raid at 9"));
            Assert.That(page.Items[0].ConversationId, Is.EqualTo("g_team"));
            Assert.That(page.NextCursor, Is.EqualTo("s2"));
            Assert.That(page.Total, Is.Null);
        }

        [Test]
        public void A_search_without_a_keyword_is_refused_before_it_is_sent()
        {
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest()); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest(" \t ")); },
                "blank is refused too: the server answers 1001 for it, but only after its limiter charged the call");
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Msg.SearchAsync(null); });

            _harness.Pump();
            Assert.That(_harness.Socket.CountOf("msg.search"), Is.Zero,
                "a refused search must not spend the user's per-minute search budget");
        }

        [Test]
        public void A_search_that_is_switched_off_fails_with_its_code_every_time()
        {
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var pending = _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest("raid"));
                _harness.Pump();
                _harness.Socket.Reply("msg.search", JsonValue.Null, ImErrorCode.FeatureNotEnabled);
                _harness.Pump();

                Assert.That(pending.IsFaulted, Is.True, "attempt " + attempt);
                var error = pending.Exception.GetBaseException() as ImException;
                Assert.That(error, Is.Not.Null);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.FeatureNotEnabled),
                    "a tenant can switch search on at runtime, so the refusal is never remembered");
            }

            Assert.That(_harness.Socket.CountOf("msg.search"), Is.EqualTo(2));
        }

        [Test]
        public void A_receipt_detail_decodes_a_total_that_counts_the_sender()
        {
            var pending = _harness.Client.Msg.ReceiptDetailAsync(new ImReceiptDetailRequest("g_team", Snowflake));
            _harness.Pump();

            var body = _harness.Socket.LastBody("msg.receiptDetail");
            AssertKeys(body, "conversationId", "messageId");
            AssertKind(body, "messageId", JsonKind.String);
            Assert.That(body["messageId"].WireString(), Is.EqualTo(Snowflake));

            _harness.Socket.Reply("msg.receiptDetail", JsonValue.NewObject()
                .Set("appId", "a1")
                .Set("conversationId", "g_team")
                .Set("messageId", Snowflake)
                .Set("readUserIds", JsonValue.ArrayOf(new[] { "u2", "u3" }))
                .Set("readCount", 2L)
                .Set("totalCount", 8L)
                .Set("updatedAt", 1767225600000L));
            _harness.Pump();

            var receipt = pending.Result;
            Assert.That(receipt.AppId, Is.EqualTo("a1"));
            Assert.That(receipt.ConversationId, Is.EqualTo("g_team"));
            Assert.That(receipt.MessageId, Is.EqualTo(SnowflakeValue));
            Assert.That(receipt.ReadUserIds, Is.EqualTo(new[] { "u2", "u3" }));
            Assert.That(receipt.ReadCount, Is.EqualTo(2));
            Assert.That(receipt.TotalCount, Is.EqualTo(8));
            Assert.That(receipt.UpdatedAt, Is.EqualTo(1767225600000L));
        }

        [Test]
        public void An_empty_receipt_decodes_to_an_empty_list_rather_than_null()
        {
            var pending = _harness.Client.Msg.ReceiptDetailAsync(new ImReceiptDetailRequest("c1", "5"));
            _harness.Pump();

            _harness.Socket.Reply("msg.receiptDetail", JsonValue.NewObject()
                .Set("conversationId", "c1")
                .Set("messageId", "5")
                .Set("readUserIds", JsonValue.NewArray())
                .Set("readCount", 0L)
                .Set("totalCount", 2L));
            _harness.Pump();

            Assert.That(pending.Result.ReadUserIds, Is.Not.Null.And.Empty);
            Assert.That(pending.Result.TotalCount, Is.EqualTo(2), "a single chat counts the sender too");
        }

        [Test]
        public void The_conversation_user_and_friend_T3_endpoints_are_reachable()
        {
            var mark = Sent("conv.markUnread", _harness.Client.Conv.MarkUnreadAsync(new ImMarkUnreadRequest("c1")));
            AssertKeys(mark, "conversationId", "unread");
            AssertKind(mark, "unread", JsonKind.Bool);
            Assert.That(mark["unread"].WireBool(), Is.True);

            var clear = Sent("conv.markUnread", _harness.Client.Conv.MarkUnreadAsync(new ImMarkUnreadRequest("c1", false)));
            AssertKeys(clear, "conversationId", "unread");
            Assert.That(clear["unread"].WireBool(), Is.False,
                "false has to be on the wire: the server's own default for a missing member is true");

            var status = Sent("user.setStatus", _harness.Client.User.SetStatusAsync(new ImSetStatusRequest("in a raid")));
            AssertKeys(status, "status");
            AssertKind(status, "status", JsonKind.String);
            Assert.That(status["status"].WireString(), Is.EqualTo("in a raid"));

            var cleared = Sent("user.setStatus", _harness.Client.User.SetStatusAsync());
            AssertKeys(cleared);

            var remark = Sent("friend.setRemark", _harness.Client.Friend.SetRemarkAsync(
                new ImSetRemarkRequest("bob", "raid healer") { Tags = new List<string> { "raid", "eu" } }));
            AssertKeys(remark, "userId", "remark", "tags");
            AssertKind(remark, "tags", JsonKind.Array);
            Assert.That(remark["tags"].WireStrings(), Is.EqualTo(new[] { "raid", "eu" }));

            var remarkOnly = Sent("friend.setRemark", _harness.Client.Friend.SetRemarkAsync(new ImSetRemarkRequest("bob", "healer")));
            AssertKeys(remarkOnly, "userId", "remark");

            var clearTags = Sent("friend.setRemark", _harness.Client.Friend.SetRemarkAsync(
                new ImSetRemarkRequest("bob", "healer") { Tags = new List<string>() }));
            Assert.That(clearTags["tags"].Kind, Is.EqualTo(JsonKind.Array));
            Assert.That(clearTags["tags"].Count, Is.Zero, "an empty list is how tags are cleared; null leaves them alone");
        }

        [Test]
        public void The_group_administration_endpoints_are_reachable()
        {
            var transfer = Sent("group.transfer", _harness.Client.Group.TransferAsync(new ImTransferOwnerRequest("g1", "bob")));
            AssertKeys(transfer, "groupId", "newOwnerId");
            Assert.That(transfer["newOwnerId"].WireString(), Is.EqualTo("bob"));

            var handle = Sent("group.handleApplication", _harness.Client.Group.HandleApplicationAsync(
                new ImHandleApplicationRequest("g1", "dave", true, "welcome")));
            AssertKeys(handle, "groupId", "applicantId", "accept", "reason");
            AssertKind(handle, "accept", JsonKind.Bool);
            Assert.That(handle["accept"].WireBool(), Is.True);

            var reject = Sent("group.handleApplication", _harness.Client.Group.HandleApplicationAsync(
                new ImHandleApplicationRequest { GroupId = "g1", ApplicantId = "eve", Accept = false }));
            AssertKeys(reject, "groupId", "applicantId", "accept");
            Assert.That(reject["accept"].WireBool(), Is.False);

            var role = Sent("group.setRole", _harness.Client.Group.SetRoleAsync(
                new ImSetRoleRequest("g1", "bob", ImGroupRole.Admin)));
            AssertKeys(role, "groupId", "userId", "role");
            AssertKind(role, "role", JsonKind.Number);
            Assert.That(role["role"].WireInt(), Is.EqualTo(2));

            var mute = Sent("group.mute", _harness.Client.Group.MuteAsync(new ImMuteGroupRequest("g1")));
            AssertKeys(mute, "groupId", "mute");
            AssertKind(mute, "mute", JsonKind.Bool);
            Assert.That(mute["mute"].WireBool(), Is.True);

            var until = Sent("group.mute", _harness.Client.Group.MuteAsync(
                new ImMuteGroupRequest("g1", true, 1767225600000L)));
            AssertKeys(until, "groupId", "mute", "untilMs");
            AssertKind(until, "untilMs", JsonKind.Number);
            Assert.That(until["untilMs"].WireLong(), Is.EqualTo(1767225600000L));

            var unmute = Sent("group.mute", _harness.Client.Group.MuteAsync(new ImMuteGroupRequest { GroupId = "g1", Mute = false }));
            AssertKeys(unmute, "groupId", "mute");
            Assert.That(unmute["mute"].WireBool(), Is.False,
                "false has to be on the wire: the server's own default for a missing member is true");

            var muteMember = Sent("group.muteMember", _harness.Client.Group.MuteMemberAsync(
                new ImMuteMemberRequest("g1", "bob", 1767225600000L)));
            AssertKeys(muteMember, "groupId", "userId", "untilMs");
            AssertKind(muteMember, "untilMs", JsonKind.Number);

            var unmuteMember = Sent("group.muteMember", _harness.Client.Group.MuteMemberAsync(
                new ImMuteMemberRequest("g1", "bob", null)));
            AssertKeys(unmuteMember, "groupId", "userId");

            var own = Sent("group.setNickname", _harness.Client.Group.SetNicknameAsync(
                new ImSetGroupNicknameRequest("g1", "Tank")));
            AssertKeys(own, "groupId", "nickname");

            var theirs = Sent("group.setNickname", _harness.Client.Group.SetNicknameAsync(
                new ImSetGroupNicknameRequest("g1", "Healer", "bob")));
            AssertKeys(theirs, "groupId", "userId", "nickname");
            Assert.That(theirs["userId"].WireString(), Is.EqualTo("bob"));

            var announcement = Sent("group.announcement", _harness.Client.Group.AnnouncementAsync(
                new ImAnnouncementRequest("g1", "Raid at 9")));
            AssertKeys(announcement, "groupId", "announcement");
            Assert.That(announcement["announcement"].WireString(), Is.EqualTo("Raid at 9"));

            var clearAnnouncement = Sent("group.announcement", _harness.Client.Group.AnnouncementAsync(
                new ImAnnouncementRequest("g1", null)));
            AssertKeys(clearAnnouncement, "groupId");
        }

        [Test]
        public void The_application_list_needs_no_group_and_decodes_every_status()
        {
            var everywhere = Sent("group.applicationList", _harness.Client.Group.ApplicationListAsync());
            AssertKeys(everywhere, "limit");
            Assert.That(everywhere["limit"].WireInt(), Is.EqualTo(50));

            var pending = _harness.Client.Group.ApplicationListAsync(new ImGroupCursorRequest("g1") { Cursor = "a2" });
            _harness.Pump();

            var body = _harness.Socket.LastBody("group.applicationList");
            AssertKeys(body, "groupId", "cursor", "limit");

            _harness.Socket.ReplyMatching("group.applicationList", b => b.Has("groupId"), JsonValue.NewObject()
                .Set("items", JsonValue.NewArray()
                    .Add(JsonValue.NewObject()
                        .Set("appId", "a1")
                        .Set("groupId", "g1")
                        .Set("applicantId", "dave")
                        .Set("inviterId", "carol")
                        .Set("reason", "let me in")
                        .Set("status", 0L)
                        .Set("createdAt", 1767225000000L))
                    .Add(JsonValue.NewObject()
                        .Set("appId", "a1")
                        .Set("groupId", "g1")
                        .Set("applicantId", "eve")
                        .Set("status", 1L)
                        .Set("handlerId", "alice")
                        .Set("handleReason", "welcome")
                        .Set("createdAt", 1767224000000L)
                        .Set("handledAt", 1767225600000L)))
                .Set("hasMore", false));
            _harness.Pump();

            var page = pending.Result;
            Assert.That(page.Items, Has.Count.EqualTo(2));

            var waiting = page.Items[0];
            Assert.That(waiting.ApplicantId, Is.EqualTo("dave"));
            Assert.That(waiting.InviterId, Is.EqualTo("carol"));
            Assert.That(waiting.Reason, Is.EqualTo("let me in"));
            Assert.That(waiting.Status, Is.EqualTo(ImApplicationStatus.Pending));
            Assert.That(waiting.HandlerId, Is.Null);
            Assert.That(waiting.HandledAt, Is.Null, "still pending; absent is not the epoch");

            var handled = page.Items[1];
            Assert.That(handled.Status, Is.EqualTo(ImApplicationStatus.Accepted),
                "the list carries every status, not only pending ones");
            Assert.That(handled.HandlerId, Is.EqualTo("alice"));
            Assert.That(handled.HandleReason, Is.EqualTo("welcome"));
            Assert.That(handled.HandledAt, Is.EqualTo(1767225600000L));
            Assert.That(handled.InviterId, Is.Null);
            Assert.That(page.NextCursor, Is.Null);
        }

        [Test]
        public void Handling_an_application_without_saying_which_way_is_refused_before_it_is_sent()
        {
            // The server reads a missing accept as a rejection, and a handled application cannot be
            // handled again — so the forgotten member would turn the player away for good.
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Group.HandleApplicationAsync(
                    new ImHandleApplicationRequest { GroupId = "g1", ApplicantId = "dave" });
            });

            _harness.Pump();
            Assert.That(_harness.Socket.CountOf("group.handleApplication"), Is.Zero);
        }

        [TestCase(ImGroupRole.Owner)]
        [TestCase((ImGroupRole)0)]
        [TestCase((ImGroupRole)4)]
        [TestCase((ImGroupRole)99)]
        public void Only_member_and_admin_are_sent_as_a_role(ImGroupRole role)
        {
            // Owner is group.transfer's job. The server stores any other integer it is given, and 0
            // escapes a group-wide mute while 4 and above outrank every admin.
            Assert.Throws<ArgumentOutOfRangeException>(delegate
            {
                _harness.Client.Group.SetRoleAsync(new ImSetRoleRequest("g1", "bob", role));
            });

            _harness.Pump();
            Assert.That(_harness.Socket.CountOf("group.setRole"), Is.Zero);
        }

        [Test]
        public void A_role_left_unset_is_refused_rather_than_sent_as_zero()
        {
            Assert.Throws<ArgumentOutOfRangeException>(delegate
            {
                _harness.Client.Group.SetRoleAsync(new ImSetRoleRequest { GroupId = "g1", UserId = "bob" });
            });

            var demote = Sent("group.setRole", _harness.Client.Group.SetRoleAsync(
                new ImSetRoleRequest("g1", "bob", ImGroupRole.Member)));
            Assert.That(demote["role"].WireInt(), Is.EqualTo(1));
        }

        [Test]
        public void A_refused_administrative_call_fails_with_the_server_code()
        {
            var pending = _harness.Client.Group.MuteAsync(new ImMuteGroupRequest("g1"));
            _harness.Pump();
            _harness.Socket.Reply("group.mute", JsonValue.Null, ImErrorCode.NoGroupPermission);
            _harness.Pump();

            Assert.That(pending.IsFaulted, Is.True);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null);
            Assert.That(error.Code, Is.EqualTo(ImErrorCode.NoGroupPermission));
        }

        /// <summary>
        /// "T3 is complete" is something this suite can fail on: every method is driven, and the
        /// targets that reach the wire are compared with the inventory's own T3 list.
        /// </summary>
        /// <remarks>
        /// The inventory is read, not copied here — a copy would be the thing that goes stale. The
        /// generator's <c>implementedIn</c> flag only checks that the quoted target appears somewhere
        /// in <c>Runtime/</c>; this checks that a method sends it.
        /// </remarks>
        [Test]
        public void Every_T3_endpoint_in_the_inventory_is_typed_here()
        {
            var id = new ImConversationMessageRequest("c1", "5");
            var calls = new List<Task>
            {
                _harness.Client.Msg.PinAsync(id),
                _harness.Client.Msg.UnpinAsync(id),
                _harness.Client.Msg.PinsAsync(new ImConversationIdRequest("c1")),
                _harness.Client.Msg.FavouriteAsync(id),
                _harness.Client.Msg.UnfavouriteAsync(id),
                _harness.Client.Msg.FavouritesAsync(),
                _harness.Client.Msg.BurnAsync(id),
                _harness.Client.Msg.SearchAsync(new ImSearchMessagesRequest("x")),
                _harness.Client.Msg.ReceiptDetailAsync(new ImReceiptDetailRequest("c1", "5")),
                _harness.Client.Friend.SetRemarkAsync(new ImSetRemarkRequest("bob", "b")),
                _harness.Client.User.SetStatusAsync(),
                _harness.Client.Conv.MarkUnreadAsync(new ImMarkUnreadRequest("c1")),
                _harness.Client.Group.AnnouncementAsync(new ImAnnouncementRequest("g1", "a")),
                _harness.Client.Group.SetNicknameAsync(new ImSetGroupNicknameRequest("g1", "n")),
                _harness.Client.Group.MuteMemberAsync(new ImMuteMemberRequest("g1", "bob", 1L)),
                _harness.Client.Group.MuteAsync(new ImMuteGroupRequest("g1")),
                _harness.Client.Group.SetRoleAsync(new ImSetRoleRequest("g1", "bob", ImGroupRole.Admin)),
                _harness.Client.Group.HandleApplicationAsync(new ImHandleApplicationRequest("g1", "bob", true)),
                _harness.Client.Group.ApplicationListAsync(),
                _harness.Client.Group.TransferAsync(new ImTransferOwnerRequest("g1", "bob")),
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

            var tierThree = InventoryTargets("T3");
            Assert.That(tierThree, Has.Count.EqualTo(20), "the inventory's T3 list parsed to the wrong size");

            var missing = new List<string>();
            foreach (var target in tierThree)
            {
                if (!sent.Contains(target))
                {
                    missing.Add(target);
                }
            }

            Assert.That(missing, Is.Empty, "T3 endpoints no typed method sends: " + string.Join(", ", missing.ToArray()));
        }

        // --------------------------------------------------------------- decoding

        [Test]
        public void A_page_keeps_its_cursor_instead_of_being_flattened_to_a_list()
        {
            var pending = _harness.Client.Friend.ListAsync();
            _harness.Pump();

            _harness.Socket.Reply("friend.list", JsonValue.NewObject()
                .Set("items", JsonValue.NewArray().Add(JsonValue.NewObject()
                    .Set("appId", "app")
                    .Set("userId", "alice")
                    .Set("friendUserId", "bob")
                    .Set("remark", "raid healer")
                    .Set("addTime", 1767225600000L)))
                .Set("nextCursor", "f2")
                .Set("hasMore", true)
                .Set("total", 57L));
            _harness.Pump();

            var page = pending.Result;
            Assert.That(page.Items, Has.Count.EqualTo(1));
            Assert.That(page.Items[0].FriendUserId, Is.EqualTo("bob"));
            Assert.That(page.Items[0].Remark, Is.EqualTo("raid healer"));
            Assert.That(page.NextCursor, Is.EqualTo("f2"));
            Assert.That(page.HasMore, Is.True);
            Assert.That(page.Total, Is.EqualTo(57));
        }

        [Test]
        public void A_missing_total_is_null_and_not_zero()
        {
            var pending = _harness.Client.Group.JoinedAsync();
            _harness.Pump();

            _harness.Socket.Reply("group.joined", JsonValue.NewObject()
                .Set("items", JsonValue.NewArray())
                .Set("hasMore", false));
            _harness.Pump();

            Assert.That(pending.Result.Total, Is.Null, "the store could not answer it cheaply; 0 would be a lie");
        }

        /// <summary>A report answers with a receipt, and a receipt is all the reporter gets.</summary>
        /// <remarks>
        /// The stored row carries who handled it and what they decided; those belong to the tenant's
        /// console, not to the player who filed the report. The id is what a confirmation shows so a
        /// player writing to support has something to quote.
        /// </remarks>
        [Test]
        public void A_report_comes_back_as_a_receipt_rather_than_the_row()
        {
            var pending = _harness.Client.Moderation.ReportAsync(
                new ImSubmitReportRequest { TargetUserId = "bob", Category = ImReportCategory.Spam });
            _harness.Pump();

            _harness.Socket.Reply("moderation.report", JsonValue.NewObject()
                .Set("reportId", "rp_4d1c9f")
                .Set("createdAt", 1767225600000L));
            _harness.Pump();

            Assert.That(pending.Result.ReportId, Is.EqualTo("rp_4d1c9f"));
            Assert.That(pending.Result.CreatedAt, Is.EqualTo(1767225600000L));
        }

        [Test]
        public void An_enum_value_this_build_has_never_heard_of_keeps_its_number()
        {
            var pending = _harness.Client.Group.InfoAsync("g1");
            _harness.Pump();

            _harness.Socket.Reply("group.info", JsonValue.NewObject()
                .Set("groupId", "g1")
                .Set("name", "Raiders")
                .Set("type", 99L)
                .Set("ownerId", "alice"));
            _harness.Pump();

            Assert.That((int)pending.Result.Type, Is.EqualTo(99),
                "the server ships new members without waiting for the app; coercing to a default hides them");
        }

        [Test]
        public void Numbers_sent_as_strings_are_read_as_numbers()
        {
            var pending = _harness.Client.Conv.GetAsync("c1");
            _harness.Pump();

            // NumberHandling.AllowReadingFromString is on server-side, and a 64-bit seq quoted by a
            // gateway written in a language where JSON numbers are doubles must not throw here.
            _harness.Socket.Reply("conv.get", JsonValue.NewObject()
                .Set("conversationId", "c1")
                .Set("type", 1L)
                .Set("maxSeq", "9007199254740993")
                .Set("unreadCount", "3"));
            _harness.Pump();

            Assert.That(pending.Result.MaxSeq, Is.EqualTo(9007199254740993L));
            Assert.That(pending.Result.UnreadCount, Is.EqualTo(3));
        }

        [Test]
        public void Invoke_is_generic_over_the_payload_for_endpoints_that_are_not_typed_yet()
        {
            // msg.streamComplete is tier 4. The escape hatch is how a customer ships on Friday
            // rather than waiting for the next SDK release, so it has to be as typed as the rest.
            var pending = _harness.Client.InvokeAsync<ImSendResult>(
                "msg.streamComplete",
                JsonValue.NewObject().Set("streamId", "st_1"));
            _harness.Pump();

            var request = _harness.Socket.LastBody("msg.streamComplete");
            Assert.That(request["streamId"].WireString(), Is.EqualTo("st_1"));

            _harness.Socket.Reply("msg.streamComplete", JsonValue.NewObject()
                .Set("messageId", Snowflake)
                .Set("seq", 41L)
                .Set("conversationId", "c1"));
            _harness.Pump();

            Assert.That(pending.Result.MessageId, Is.EqualTo(SnowflakeValue));
            Assert.That(pending.Result.Seq, Is.EqualTo(41));
        }

        [Test]
        public void Invoke_never_touches_a_cursor()
        {
            _harness.PushMessage("c1", 4);

            var pending = _harness.Client.InvokeAsync("msg.sync", JsonValue.NewObject()
                .Set("conversationId", "c1")
                .Set("fromSeq", 1L)
                .Set("toSeq", 4L));
            _harness.Pump();

            _harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", false, 40, 1, 2, 3, 4));
            _harness.Pump();

            Assert.That(pending.Result["messages"].Count, Is.EqualTo(4));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4),
                "an escape hatch that quietly mutated sequence state would be unpredictable exactly " +
                "where it gets used");
            Assert.That(_harness.Client.CommittedSeqOf("c1"), Is.Zero);
        }

        [Test]
        public void The_contract_version_is_reported_so_a_ticket_carries_it()
        {
            Assert.That(ImSdk.ContractVersion, Is.EqualTo("1.0"));
            Assert.That(ImSdk.PackageVersion, Is.EqualTo("0.9.0"));
        }

        /// <summary>A real-shaped snowflake: past 2^53, so a double would change its last digits.</summary>
        private const string Snowflake = "360306324097966081";

        private const long SnowflakeValue = 360306324097966081L;

        /// <summary>The exact member names a body carries — no more, and none left out.</summary>
        /// <remarks>
        /// "No more" matters as much as "none left out": a member left null has to be absent rather
        /// than sent as null or empty, because for several T3 endpoints absence is what carries the
        /// meaning (a missing <c>tags</c> keeps the tags, a missing <c>untilMs</c> mutes
        /// indefinitely).
        /// </remarks>
        private static void AssertKeys(JsonValue body, params string[] expected)
        {
            var actual = new List<string>();
            foreach (var member in body.Members)
            {
                actual.Add(member.Key);
            }

            Assert.That(actual, Is.EquivalentTo(expected), "body was " + body.ToJson());
        }

        private static void AssertKind(JsonValue body, string name, JsonKind kind)
        {
            Assert.That(body[name].Kind, Is.EqualTo(kind), name + " in " + body.ToJson());
        }

        /// <summary>Targets of one tier, read out of <c>sdk/endpoint-inventory.json</c>.</summary>
        private static List<string> InventoryTargets(string tier, [CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);

            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                var candidate = Path.Combine(directory, "endpoint-inventory.json");
                if (File.Exists(candidate))
                {
                    var targets = new List<string>();
                    foreach (var endpoint in JsonValue.Parse(File.ReadAllText(candidate))["endpoints"].Items)
                    {
                        if (endpoint["tier"].AsString() == tier)
                        {
                            targets.Add(endpoint["target"].AsString());
                        }
                    }

                    return targets;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }

        /// <summary>Issues a call, checks which endpoint it hit, and hands back the body it sent.</summary>
        private JsonValue Sent(string target, Task pending)
        {
            ImTestHarness.Forget(pending);
            _harness.Pump();

            var requests = _harness.Socket.Requests;
            Assert.That(requests, Is.Not.Empty);

            var last = requests[requests.Count - 1];
            Assert.That(last.Target, Is.EqualTo(target),
                "the method name is the endpoint's method part; a synonym costs every future reader a lookup");

            return last.Body;
        }
    }
}
