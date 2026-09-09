using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The typed endpoint surface: tiers T0, T1 and T2 of <c>sdk/CONTRACT.md</c> §3.
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
            Assert.That(reauth["token"].AsString(), Is.EqualTo("token-2"));

            var sync = Sent("conn.sync", _harness.Client.Conn.SyncAsync(new ImResumeRequest
            {
                ConvSeqs = new Dictionary<string, long> { { "c1", 40 } },
                ConversationCursor = 99,
                Limit = 200,
            }));

            Assert.That(sync["convSeqs"]["c1"].AsLong(), Is.EqualTo(40));
            Assert.That(sync["conversationCursor"].AsLong(), Is.EqualTo(99));
            Assert.That(sync["limit"].AsInt(), Is.EqualTo(200));
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
            Assert.That(send["receiverId"].AsString(), Is.EqualTo("bob"));
            Assert.That(send["contentType"].AsInt(), Is.EqualTo((int)ImMessageContentType.Text));

            var sync = Sent("msg.sync", _harness.Client.Msg.SyncAsync(new ImSyncMessagesRequest
            {
                ConversationId = "c1",
                FromSeq = 10,
                ToSeq = 20,
                Limit = 11,
            }));
            Assert.That(sync["fromSeq"].AsLong(), Is.EqualTo(10));
            Assert.That(sync["toSeq"].AsLong(), Is.EqualTo(20));
            Assert.That(sync["ascending"].AsBool(), Is.True);

            var history = Sent("msg.history", _harness.Client.Msg.HistoryAsync(new ImHistoryRequest
            {
                ConversationId = "c1",
                BeforeSeq = 40,
                Limit = 30,
            }));
            Assert.That(history["beforeSeq"].AsLong(), Is.EqualTo(40));
            Assert.That(history["limit"].AsInt(), Is.EqualTo(30));

            var recall = Sent("msg.recall", _harness.Client.Msg.RecallAsync(new ImRecallMessageRequest
            {
                ConversationId = "c1",
                MessageId = "900",
                Reason = "typo",
            }));
            Assert.That(recall["messageId"].AsString(), Is.EqualTo("900"));
            Assert.That(recall.Has("asAdmin"), Is.False,
                "the server forces admin recall off for a client, so a field for it would be a lie");

            var delete = Sent("msg.delete", _harness.Client.Msg.DeleteAsync(new ImDeleteMessagesRequest
            {
                ConversationId = "c1",
                MessageIds = new List<string> { "9007199254740993" },
            }));
            Assert.That(delete["messageIds"][0].AsString(), Is.EqualTo("9007199254740993"),
                "a snowflake id past 2^53 must not be rounded on the way out, which is why it "
                + "travels as a JSON string rather than a JSON number");
            Assert.That(delete["forEveryone"].AsBool(), Is.False);

            var typing = Sent("msg.typing", _harness.Client.Msg.TypingAsync(
                new ImTypingRequest { ConversationId = "c1" }));
            Assert.That(typing["typing"].AsBool(), Is.True);
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
            Assert.That(list["updatedAfter"].AsLong(), Is.EqualTo(1767225600000L));
            Assert.That(list["cursor"].AsString(), Is.EqualTo("page-2"));

            var get = Sent("conv.get", _harness.Client.Conv.GetAsync("c1"));
            Assert.That(get["conversationId"].AsString(), Is.EqualTo("c1"));

            var read = Sent("conv.read", _harness.Client.Conv.ReadAsync("c1", 42));
            Assert.That(read["readSeq"].AsLong(), Is.EqualTo(42));

            Sent("conv.unreadTotal", _harness.Client.Conv.UnreadTotalAsync());
        }

        [Test]
        public void The_user_endpoints_are_reachable()
        {
            Sent("user.me", _harness.Client.User.MeAsync());

            var profile = Sent("user.profile", _harness.Client.User.ProfileAsync("bob"));
            Assert.That(profile["userId"].AsString(), Is.EqualTo("bob"));

            var batch = Sent("user.batchProfile",
                _harness.Client.User.BatchProfileAsync(new[] { "bob", "carol" }));
            Assert.That(batch["userIds"].Count, Is.EqualTo(2));

            var update = Sent("user.updateProfile", _harness.Client.User.UpdateProfileAsync(
                new ImUpdateProfileRequest(JsonValue.NewObject().Set("nickname", "Alice"))));
            Assert.That(update["patch"]["nickname"].AsString(), Is.EqualTo("Alice"));
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
            Assert.That(ticket["fileName"].AsString(), Is.EqualTo("screenshot.png"));
            Assert.That(ticket["size"].AsLong(), Is.EqualTo(12345));

            var download = Sent("media.downloadUrl", _harness.Client.Media.DownloadUrlAsync("app/alice/x.png"));
            Assert.That(download["objectKey"].AsString(), Is.EqualTo("app/alice/x.png"));
            Assert.That(download["lifetimeSeconds"].AsInt(), Is.EqualTo(3600));
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
            Assert.That(register["provider"].AsString(), Is.EqualTo("huawei"));
            Assert.That(register["language"].AsString(), Is.EqualTo("zh-CN"));

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
            Assert.That(create["name"].AsString(), Is.EqualTo("Raid party"));
            Assert.That(create["type"].AsInt(), Is.EqualTo((int)ImGroupType.Normal));
            Assert.That(create["joinMode"].AsInt(), Is.EqualTo((int)ImGroupJoinMode.NeedApproval));
            Assert.That(create["maxMemberCount"].AsInt(), Is.EqualTo(200));

            Sent("group.info", _harness.Client.Group.InfoAsync("g1"));

            var update = Sent("group.update", _harness.Client.Group.UpdateAsync(new ImUpdateGroupCommand(
                "g1",
                new ImUpdateGroupRequest { Name = "Raiders", InviteMode = ImGroupInviteMode.AdminsOnly })));
            Assert.That(update["update"]["name"].AsString(), Is.EqualTo("Raiders"));
            Assert.That(update["update"]["inviteMode"].AsInt(), Is.EqualTo((int)ImGroupInviteMode.AdminsOnly));
            Assert.That(update["update"].Has("avatar"), Is.False, "a member left null is not a member set to null");

            Sent("group.dismiss", _harness.Client.Group.DismissAsync(new ImGroupIdRequest("g1")));

            var members = Sent("group.memberList", _harness.Client.Group.MemberListAsync(
                new ImGroupCursorRequest("g1") { Cursor = "m2", Limit = 100 }));
            Assert.That(members["cursor"].AsString(), Is.EqualTo("m2"));

            Sent("group.joined", _harness.Client.Group.JoinedAsync());

            var invite = Sent("group.invite", _harness.Client.Group.InviteAsync(new ImGroupMembersRequest
            {
                GroupId = "g1",
                UserIds = new List<string> { "dave" },
                Reason = "guild recruit",
            }));
            Assert.That(invite["userIds"][0].AsString(), Is.EqualTo("dave"));
            Assert.That(invite["reason"].AsString(), Is.EqualTo("guild recruit"));

            Sent("group.kick", _harness.Client.Group.KickAsync(new ImGroupMembersRequest
            {
                GroupId = "g1",
                UserIds = new List<string> { "dave" },
            }));

            Sent("group.quit", _harness.Client.Group.QuitAsync(new ImGroupIdRequest("g1")));

            var join = Sent("group.join", _harness.Client.Group.JoinAsync(new ImJoinGroupRequest("g1", "let me in")));
            Assert.That(join["reason"].AsString(), Is.EqualTo("let me in"));
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
            Assert.That(add["greeting"].AsString(), Is.EqualTo("hi"));

            var handle = Sent("friend.handleRequest", _harness.Client.Friend.HandleRequestAsync(
                new ImHandleFriendRequest { FromUserId = "bob", Accept = true }));
            Assert.That(handle["accept"].AsBool(), Is.True);

            var requests = Sent("friend.requestList", _harness.Client.Friend.RequestListAsync(
                new ImFriendRequestListRequest { Incoming = false }));
            Assert.That(requests["incoming"].AsBool(), Is.False);

            Sent("friend.delete", _harness.Client.Friend.DeleteAsync(new ImUserIdRequest("bob")));
            Sent("friend.blockList", _harness.Client.Friend.BlockListAsync());

            var block = Sent("friend.block", _harness.Client.Friend.BlockAsync("bob", "harassment"));
            Assert.That(block["reason"].AsString(), Is.EqualTo("harassment"));

            Sent("friend.unblock", _harness.Client.Friend.UnblockAsync("bob"));
        }

        [Test]
        public void The_presence_endpoints_are_reachable()
        {
            Sent("user.presence", _harness.Client.User.PresenceAsync(new[] { "bob" }));

            var subscribe = Sent("user.subscribePresence", _harness.Client.User.SubscribePresenceAsync(
                new ImSubscribePresenceRequest { UserIds = new List<string> { "bob" }, TtlSeconds = 900 }));
            Assert.That(subscribe["ttlSeconds"].AsInt(), Is.EqualTo(900));

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
            Assert.That(setting["setting"]["pinned"].AsBool(), Is.True);
            Assert.That(setting["setting"]["muted"].AsInt(), Is.EqualTo((int)ImMuteMode.NoPush));
            Assert.That(setting["setting"].Has("draft"), Is.False);

            Sent("conv.delete", _harness.Client.Conv.DeleteAsync(new ImConversationIdRequest("c1")));
            Sent("conv.clear", _harness.Client.Conv.ClearAsync(new ImConversationIdRequest("c1")));

            var edit = Sent("msg.edit", _harness.Client.Msg.EditAsync(new ImEditMessageRequest
            {
                ConversationId = "c1",
                MessageId = "5",
                Content = JsonValue.NewObject().Set("text", "fixed"),
            }));
            Assert.That(edit["content"]["text"].AsString(), Is.EqualTo("fixed"));

            var forward = Sent("msg.forward", _harness.Client.Msg.ForwardAsync(new ImForwardMessagesRequest
            {
                SourceConversationId = "c1",
                MessageIds = new List<string> { "5", "6" },
                TargetConversationIds = new List<string> { "c2" },
                Merge = true,
                MergeTitle = "yesterday",
            }));
            Assert.That(forward["merge"].AsBool(), Is.True);
            Assert.That(forward["clientMsgId"].AsString(), Is.Not.Empty,
                "a forward is a send, so it gets an idempotency key without being asked");

            var react = Sent("msg.react", _harness.Client.Msg.ReactAsync(new ImReactRequest
            {
                ConversationId = "c1",
                MessageId = "5",
                Emoji = "👍",
            }));
            Assert.That(react["emoji"].AsString(), Is.EqualTo("👍"));
            Assert.That(react["add"].AsBool(), Is.True);

            var receipt = Sent("msg.receipt", _harness.Client.Msg.ReceiptAsync(new ImReceiptRequest
            {
                ConversationId = "c1",
                MessageIds = new List<string> { "5" },
            }));
            Assert.That(receipt["messageIds"][0].AsString(), Is.EqualTo("5"));
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

            Assert.That(report["targetUserId"].AsString(), Is.EqualTo("bob"));
            Assert.That(report["category"].AsString(), Is.EqualTo("harassment"));
            Assert.That(report["messageId"].AsString(), Is.EqualTo("9007199254740993"),
                "a snowflake id past 2^53 travels quoted, so it must not be written as a number");
            Assert.That(report.Has("reporterId"), Is.False,
                "the reporter is the socket; a field for it is a way to file in somebody else's name");
            Assert.That(report.Has("userId"), Is.False);
        }

        /// <summary>Reporting the account rather than one message is spelled "no message id".</summary>
        /// <remarks>
        /// A report screen with the message box left blank is the ordinary way to report an account,
        /// and the server reads this member as a number written as a string — so an empty one would
        /// come back <c>1000 InternalError</c> on a field nobody filled in.
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

            Assert.That(clicked["pushId"].AsString(), Is.EqualTo("pu_7f3"));
            Assert.That(clicked["messageId"].AsString(), Is.EqualTo("9007199254740993"));
            Assert.That(clicked.Has("deviceId"), Is.False, "the row is found from the socket, never from the body");
            Assert.That(clicked.Has("userId"), Is.False);

            // A tap that opened the game without naming anything is the common case on Android,
            // where the vendor batches notifications and the extras the app gets back are whatever
            // survived that. The server credits this device's newest delivery.
            var bare = Sent("push.clicked", _harness.Client.Push.ClickedAsync());
            Assert.That(bare.Has("messageId"), Is.False);
            Assert.That(bare.Has("pushId"), Is.False);
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
            // group.transfer is tier 3. The escape hatch is how a customer ships on Friday rather
            // than waiting for the next SDK release, so it has to be as typed as the rest.
            var pending = _harness.Client.InvokeAsync<ImGroup>(
                "group.transfer",
                JsonValue.NewObject().Set("groupId", "g1").Set("newOwnerId", "bob"));
            _harness.Pump();

            var request = _harness.Socket.LastBody("group.transfer");
            Assert.That(request["newOwnerId"].AsString(), Is.EqualTo("bob"));

            _harness.Socket.Reply("group.transfer", JsonValue.NewObject()
                .Set("groupId", "g1")
                .Set("ownerId", "bob"));
            _harness.Pump();

            Assert.That(pending.Result.OwnerId, Is.EqualTo("bob"));
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
