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
    /// <c>msg.schedule</c> / <c>msg.scheduled</c> / <c>msg.cancelScheduled</c>, <c>conv.folders</c> /
    /// <c>conv.upsertFolder</c> / <c>conv.deleteFolder</c> and <c>msg.translate</c>.
    /// </summary>
    /// <remarks>
    /// Every call is asserted on the frame it puts on the wire — target and the whole body, by JSON kind —
    /// and every reply is decoded from a fixture with every member set; both are held to the inventory's
    /// <c>payloadTypes</c>. Then the rules an integrator cannot read off a signature: the schedule body is
    /// flat and has no options; a schedule moves no cursor and fires as an ordinary message; a cancelled
    /// schedule stays listed; translation refusals are ordinary errors with the server's words.
    /// 每个调用断言整帧（按 JSON 形态），每个答复用全字段夹具解码，两者都对着清单的 payloadTypes 钉住；
    /// 再加签名上看不出的规则：定时请求是平铺的、没有 options；定时不动游标、发出时是普通消息；取消后仍在列表里；
    /// 翻译被拒是带服务端原文的普通错误。
    /// </remarks>
    public sealed class ScheduleTests
    {
        private const string Conversation = "s_alice_bob";

        private const string ScheduleId = "sch_360381357961969700";

        private const string Big = "360381357961969667";

        private const long BigValue = 360381357961969667L;

        private const long SendAt = 1767225612000L;

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

        private static ImScheduleRequest FullSchedule(ImRecipient recipient, ImConversationType type)
        {
            return new ImScheduleRequest(
                recipient,
                SendAt,
                JsonValue.NewObject().Set("url", "demo/alice/a.png").Set("width", 640L))
            {
                ConversationType = type,
                ClientMsgId = "cm-later",
                ContentType = ImMessageContentType.Image,
                MentionAll = true,
                MentionedUserIds = new[] { "bob", "carol" },
                QuoteMessageId = BigValue,
                ThreadRootId = BigValue,
                Extensions = JsonValue.NewObject().Set("campaign", "birthday"),
            };
        }

        private static JsonValue Scheduled(string scheduleId = ScheduleId)
        {
            return JsonValue.NewObject()
                .Set("scheduleId", scheduleId)
                .Set("appId", "demo")
                .Set("senderId", "u_alice")
                .Set("conversationId", Conversation)
                .Set("sendAt", SendAt)
                .Set("createdAt", 1767225600123L);
        }

        /// <summary>Every member set, as the server writes a sent one: the message id quoted.</summary>
        private static JsonValue SentSchedule()
        {
            return Scheduled("sch_sent").Set("messageId", Big);
        }

        private static JsonValue FailedSchedule()
        {
            return Scheduled("sch_failed").Set("error", "you are not a member of this group");
        }

        private static JsonValue CancelledSchedule()
        {
            return Scheduled("sch_cancelled").Set("error", ImScheduledMessage.CancelledBySender);
        }

        /// <summary>
        /// Not a state the server produces (a sent schedule carries no error), but the union of every member
        /// it declares, for the payloadTypes check.
        /// </summary>
        private static JsonValue EveryMemberSchedule()
        {
            return SentSchedule().Set("error", "x");
        }

        private static ImUpsertFolderRequest FullFolder()
        {
            return new ImUpsertFolderRequest("Work", "work", "clients")
            {
                FolderId = "f_work",
                Order = 2,
                UnreadOnly = true,
                Types = new List<ImConversationType> { ImConversationType.Single, ImConversationType.Group },
            };
        }

        private static JsonValue Folder(string folderId = "f_work", bool withTypes = true)
        {
            var folder = JsonValue.NewObject()
                .Set("folderId", folderId)
                .Set("name", "Work")
                .Set("order", 2L)
                .Set("tags", JsonValue.ArrayOf(new[] { "work", "clients" }))
                .Set("unreadOnly", true);

            if (withTypes)
            {
                folder.Set("types", JsonValue.NewArray().Add(JsonValue.Of(1L)).Add(JsonValue.Of(2L)));
            }

            return folder;
        }

        private static ImTranslateRequest FullTranslate()
        {
            return new ImTranslateRequest(Conversation, "zh-CN", Big, "7") { SourceLanguage = "en" };
        }

        private static JsonValue Translation()
        {
            return JsonValue.NewObject()
                .Set("targetLanguage", "zh-CN")
                .Set("items", JsonValue.NewArray()
                    .Add(JsonValue.NewObject().Set("messageId", Big).Set("text", "你好").Set("cached", true))
                    .Add(JsonValue.NewObject().Set("messageId", "7").Set("cached", false).Set("error", "message not found")));
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

        /// <summary>
        /// Answers the newest request for a target with the envelope the server writes for a failure:
        /// a code, its own message, and no <c>data</c> member at all.
        /// </summary>
        private ImException RefusedInWords(Task pending, string target, int code, string message)
        {
            AnswerNewest(target, JsonValue.NewObject()
                .Set("code", (long)code)
                .Set("message", message)
                .Set("serverTime", 1767225600000L)
                .Set("traceId", "tr-translate"));

            Assert.That(pending.IsFaulted, Is.True, target + " should have failed with " + code);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null, "an ordinary ImException, not a decoding failure");
            return error;
        }

        /// <summary>Delivers a reply envelope, exactly as given, to the newest request for a target.</summary>
        private void AnswerNewest(string target, JsonValue envelope)
        {
            _harness.Pump();

            string id = null;
            foreach (var request in _harness.Socket.Requests)
            {
                if (request.Target == target)
                {
                    id = request.Id;
                }
            }

            Assert.That(id, Is.Not.Null, target + " never reached the socket");

            var frame = JsonValue.NewObject()
                .Set("id", id)
                .Set("target", target)
                .Set("status", 0L)
                .Set("body", envelope);
            _harness.Socket.Deliver(frame.ToJson());
            _harness.Pump();
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

        // ------------------------------------------------------------------ msg.schedule

        [Test]
        public void Schedule_with_every_member_sends_each_in_the_servers_kind_and_no_options()
        {
            var schedule = Answered(
                _harness.Client.Msg.ScheduleAsync(FullSchedule(ImRecipient.User("u_bob"), ImConversationType.Single)),
                "msg.schedule",
                Scheduled());

            var body = _harness.Socket.LastBody("msg.schedule");
            Assert.That(Keys(body), Is.EqualTo(new[]
            {
                "clientMsgId", "content", "contentType", "conversationType", "extensions", "mentionAll",
                "mentionedUserIds", "quoteMessageId", "receiverId", "sendAt", "threadRootId",
            }), "flat: the members of msg.send beside sendAt; no options, no sendTime");
            Assert.That(body["sendAt"].WireLong(), Is.EqualTo(SendAt));
            Assert.That(body["receiverId"].WireString(), Is.EqualTo("u_bob"));
            Assert.That(body["conversationType"].WireInt(), Is.EqualTo(1), "an enum member takes its integer");
            Assert.That(body["clientMsgId"].WireString(), Is.EqualTo("cm-later"));
            Assert.That(body["contentType"].WireInt(), Is.EqualTo(2), "an enum member takes its integer");
            Assert.That(body["content"]["url"].WireString(), Is.EqualTo("demo/alice/a.png"));
            Assert.That(body["content"]["width"].WireLong(), Is.EqualTo(640L));
            Assert.That(body["mentionAll"].WireBool(), Is.True);
            Assert.That(body["mentionedUserIds"].WireStrings(), Is.EqualTo(new[] { "bob", "carol" }));
            Assert.That(body["quoteMessageId"].WireString(), Is.EqualTo(Big), "a string? on the server; a JSON number there is 1000");
            Assert.That(body["threadRootId"].WireString(), Is.EqualTo(Big), "a string? on the server; a JSON number there is 1000");
            Assert.That(body["extensions"]["campaign"].WireString(), Is.EqualTo("birthday"));

            Assert.That(schedule.ScheduleId, Is.EqualTo(ScheduleId));
            Assert.That(schedule.AppId, Is.EqualTo("demo"));
            Assert.That(schedule.SenderId, Is.EqualTo("u_alice"));
            Assert.That(schedule.ConversationId, Is.EqualTo(Conversation));
            Assert.That(schedule.SendAt, Is.EqualTo(SendAt));
            Assert.That(schedule.CreatedAt, Is.EqualTo(1767225600123L));
            Assert.That(schedule.MessageId, Is.Null, "not sent yet: absent, not 0");
            Assert.That(schedule.Error, Is.Null);
            Assert.That(schedule.IsPending, Is.True);
        }

        [Test]
        public void Each_address_sends_one_string_id_and_nothing_unset_goes_out()
        {
            var modes = new Dictionary<string, ImRecipient>
            {
                { "receiverId", ImRecipient.User("u_bob") },
                { "groupId", ImRecipient.Group("g_team") },
                { "conversationId", ImRecipient.Conversation(Conversation) },
            };

            foreach (var mode in modes)
            {
                ImTestHarness.Forget(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(mode.Value, SendAt, "later")));
                _harness.Pump();

                var body = _harness.Socket.LastBody("msg.schedule");
                Assert.That(Keys(body), Is.EqualTo(new SortedSet<string>(StringComparer.Ordinal)
                {
                    "content", "contentType", "sendAt", mode.Key,
                }), "a minimal schedule: no clientMsgId (the server uses sch-<scheduleId>), no mention keys, no options");
                Assert.That(body[mode.Key].WireString(), Is.Not.Empty);
                Assert.That(body["contentType"].WireInt(), Is.EqualTo(1), "Text, the server's default, said out loud");
                Assert.That(body["content"]["text"].WireString(), Is.EqualTo("later"));
            }
        }

        [Test]
        public void Schedule_without_an_address_or_content_is_refused_before_anything_is_sent()
        {
            var before = _harness.Socket.Requests.Count;

            Assert.Throws<ArgumentNullException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.ScheduleAsync(null)); });
            Assert.Throws<ArgumentException>(delegate
            {
                ImTestHarness.Forget(_harness.Client.Msg.ScheduleAsync(new ImScheduleRequest
                {
                    SendAt = SendAt,
                    Content = JsonValue.NewObject().Set("text", "x"),
                }));
            }, "no address: the server answers 1001");
            Assert.Throws<ArgumentException>(delegate
            {
                ImTestHarness.Forget(_harness.Client.Msg.ScheduleAsync(new ImScheduleRequest(ImRecipient.User("u_bob"), SendAt, null)));
            }, "no content: the server answers 1001 \"content is required\"");
            Assert.Throws<ArgumentException>(delegate
            {
                ImTestHarness.Forget(_harness.Client.Msg.ScheduleAsync(new ImScheduleRequest(ImRecipient.User("u_bob"), SendAt, JsonValue.NewObject())));
            }, "an empty object is no content too");
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.CancelScheduledAsync(string.Empty)); });

            _harness.Pump();
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before));
        }

        [Test]
        public void Schedule_refusals_carry_the_server_code()
        {
            Assert.That(Refused(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.User("u_bob"), 1L, "x")), "msg.schedule", ImErrorCode.InvalidArgument).Code,
                Is.EqualTo(ImErrorCode.InvalidArgument), "sendAt less than 10 s ahead, or past 90 days");
            Assert.That(Refused(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.User("u_bob"), SendAt, "x")), "msg.schedule", ImErrorCode.Conflict).Code,
                Is.EqualTo(ImErrorCode.Conflict), "100 pending already");
            Assert.That(Refused(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.User("u_bob"), SendAt, "x")), "msg.schedule", ImErrorCode.RateLimited).Code,
                Is.EqualTo(ImErrorCode.RateLimited), "120 created this hour");
            Assert.That(Refused(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.Group("g_team"), SendAt, "x")), "msg.schedule", ImErrorCode.NotGroupMember).Code,
                Is.EqualTo(ImErrorCode.NotGroupMember), "the access rules of msg.send");
        }

        /// <summary>
        /// A schedule is not a message: its reply names no seq, so nothing moves, and nothing is pushed for it.
        /// When it fires, the receiver — the sender's other devices too — gets an ordinary <c>evt.message</c>,
        /// which goes through <see cref="ImClient.MessageReceived"/> and the cursor like any other.
        /// </summary>
        [Test]
        public void Scheduling_moves_no_cursor_and_the_fired_message_arrives_as_an_ordinary_one()
        {
            _harness.PushMessage(Conversation, 5);

            Answered(_harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.Conversation(Conversation), SendAt, "later")), "msg.schedule", Scheduled());
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(5), "the schedule reconciles no cursor");
            Assert.That(_delivered, Has.Count.EqualTo(1));

            _harness.PushMessage(Conversation, 6, "later");

            Assert.That(_delivered, Has.Count.EqualTo(2));
            Assert.That(_delivered[1].Seq, Is.EqualTo(6L));
            Assert.That(_harness.Client.DeliveredSeqOf(Conversation), Is.EqualTo(6));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
        }

        // ------------------------------------------------------------------ msg.scheduled

        [Test]
        public void Scheduled_pages_and_decodes_every_state_a_listed_schedule_can_be_in()
        {
            var page = Answered(
                _harness.Client.Msg.ScheduledAsync(new ImPageRequest { Cursor = "sch:2", Limit = 50 }),
                "msg.scheduled",
                JsonValue.NewObject()
                    .Set("items", JsonValue.NewArray().Add(Scheduled()).Add(SentSchedule()).Add(CancelledSchedule()).Add(FailedSchedule()))
                    .Set("nextCursor", "sch:3")
                    .Set("hasMore", true));

            var body = _harness.Socket.LastBody("msg.scheduled");
            Assert.That(Keys(body), Is.EqualTo(new[] { "cursor", "limit" }));
            Assert.That(body["cursor"].WireString(), Is.EqualTo("sch:2"));
            Assert.That(body["limit"].WireInt(), Is.EqualTo(50));

            Assert.That(page.Items, Has.Count.EqualTo(4));
            Assert.That(page.NextCursor, Is.EqualTo("sch:3"));
            Assert.That(page.HasMore, Is.True);
            Assert.That(page.Total, Is.Null);

            var pending = page.Items[0];
            Assert.That(new[] { pending.IsPending, pending.IsSent, pending.IsCancelled, pending.IsFailed }, Is.EqualTo(new[] { true, false, false, false }));

            var sent = page.Items[1];
            Assert.That(sent.MessageId, Is.EqualTo(BigValue), "a quoted snowflake past 2^53 keeps every digit");
            Assert.That(new[] { sent.IsPending, sent.IsSent, sent.IsCancelled, sent.IsFailed }, Is.EqualTo(new[] { false, true, false, false }));

            var cancelled = page.Items[2];
            Assert.That(cancelled.Error, Is.EqualTo("cancelled by sender"), "a cancelled schedule stays listed; the reason is the only marker");
            Assert.That(new[] { cancelled.IsPending, cancelled.IsSent, cancelled.IsCancelled, cancelled.IsFailed }, Is.EqualTo(new[] { false, false, true, false }));

            var failed = page.Items[3];
            Assert.That(failed.Error, Is.EqualTo("you are not a member of this group"));
            Assert.That(new[] { failed.IsPending, failed.IsSent, failed.IsCancelled, failed.IsFailed }, Is.EqualTo(new[] { false, false, false, true }));

            ImTestHarness.Forget(_harness.Client.Msg.ScheduledAsync());
            _harness.Pump();
            var first = _harness.Socket.LastBody("msg.scheduled");
            Assert.That(Keys(first), Is.EqualTo(new[] { "limit" }), "the first page: no cursor");
            Assert.That(first["limit"].WireInt(), Is.EqualTo(20));
        }

        [Test]
        public void A_bare_numeric_message_id_is_read_as_well()
        {
            var sent = ImPayload.Read<ImScheduledMessage>(Scheduled().Set("messageId", 42L));
            Assert.That(sent.MessageId, Is.EqualTo(42L));
            Assert.That(sent.IsSent, Is.True);
        }

        // ------------------------------------------------------------------ msg.cancelScheduled

        [Test]
        public void CancelScheduled_sends_the_schedule_id_and_nothing_else()
        {
            var body = Acknowledged(_harness.Client.Msg.CancelScheduledAsync(new ImScheduleIdRequest(ScheduleId)), "msg.cancelScheduled");
            Assert.That(Keys(body), Is.EqualTo(new[] { "scheduleId" }));
            Assert.That(body["scheduleId"].WireString(), Is.EqualTo(ScheduleId));

            var shorthand = Acknowledged(_harness.Client.Msg.CancelScheduledAsync("sch_2"), "msg.cancelScheduled");
            Assert.That(shorthand["scheduleId"].WireString(), Is.EqualTo("sch_2"));
        }

        [Test]
        public void CancelScheduled_refusals_carry_the_server_code()
        {
            Assert.That(Refused(_harness.Client.Msg.CancelScheduledAsync(ScheduleId), "msg.cancelScheduled", ImErrorCode.NotFound).Code,
                Is.EqualTo(ImErrorCode.NotFound), "unknown, or someone else's");
            Assert.That(Refused(_harness.Client.Msg.CancelScheduledAsync(ScheduleId), "msg.cancelScheduled", ImErrorCode.Conflict).Code,
                Is.EqualTo(ImErrorCode.Conflict), "already being sent");
        }

        // ------------------------------------------------------------------ conv.folders

        [Test]
        public void Folders_sends_no_body_and_decodes_a_bare_list()
        {
            var folders = Answered(
                _harness.Client.Conv.FoldersAsync(),
                "conv.folders",
                JsonValue.NewArray().Add(Folder()).Add(Folder("f_all", false)));

            var body = _harness.Socket.LastBody("conv.folders");
            Assert.That(body == null || body.IsNull || Keys(body).Count == 0, Is.True, "conv.folders takes no request");

            Assert.That(folders, Has.Count.EqualTo(2), "a bare array, not a page");

            var work = folders[0];
            Assert.That(work.FolderId, Is.EqualTo("f_work"));
            Assert.That(work.Name, Is.EqualTo("Work"));
            Assert.That(work.Order, Is.EqualTo(2));
            Assert.That(work.Tags, Is.EqualTo(new[] { "work", "clients" }));
            Assert.That(work.UnreadOnly, Is.True);
            Assert.That(work.Types, Is.EqualTo(new[] { ImConversationType.Single, ImConversationType.Group }));

            Assert.That(folders[1].Types, Is.Null, "absent means every kind");

            Assert.That(Answered(_harness.Client.Conv.FoldersAsync(), "conv.folders", JsonValue.NewArray()), Is.Empty, "no folders is an empty list");
        }

        // ------------------------------------------------------------------ conv.upsertFolder

        [Test]
        public void UpsertFolder_writes_every_member_in_the_servers_kind_and_decodes_the_saved_folder()
        {
            var saved = Answered(_harness.Client.Conv.UpsertFolderAsync(FullFolder()), "conv.upsertFolder", Folder());

            var body = _harness.Socket.LastBody("conv.upsertFolder");
            Assert.That(Keys(body), Is.EqualTo(new[] { "folderId", "name", "order", "tags", "types", "unreadOnly" }));
            Assert.That(body["folderId"].WireString(), Is.EqualTo("f_work"));
            Assert.That(body["name"].WireString(), Is.EqualTo("Work"));
            Assert.That(body["order"].WireInt(), Is.EqualTo(2));
            Assert.That(body["tags"].WireStrings(), Is.EqualTo(new[] { "work", "clients" }));
            Assert.That(body["unreadOnly"].WireBool(), Is.True);
            Assert.That(body["types"].Kind, Is.EqualTo(JsonKind.Array));
            Assert.That(body["types"][0].WireInt(), Is.EqualTo(1), "ConversationType as its integer");
            Assert.That(body["types"][1].WireInt(), Is.EqualTo(2), "ConversationType as its integer");

            Assert.That(saved.FolderId, Is.EqualTo("f_work"));
            Assert.That(saved.Types, Has.Count.EqualTo(2));

            ImTestHarness.Forget(_harness.Client.Conv.UpsertFolderAsync(new ImUpsertFolderRequest { Name = "Inbox" }));
            _harness.Pump();
            var created = _harness.Socket.LastBody("conv.upsertFolder");
            Assert.That(Keys(created), Is.EqualTo(new[] { "name", "order", "tags", "unreadOnly" }),
                "no folderId creates one; the rest is written because the call replaces the folder");
            Assert.That(created["order"].WireInt(), Is.Zero);
            Assert.That(created["tags"].WireStrings(), Is.Empty);
            Assert.That(created["unreadOnly"].WireBool(), Is.False);
        }

        [Test]
        public void UpsertFolder_without_a_name_is_refused_before_anything_is_sent_and_server_refusals_carry_the_code()
        {
            var before = _harness.Socket.Requests.Count;
            Assert.Throws<ArgumentNullException>(delegate { ImTestHarness.Forget(_harness.Client.Conv.UpsertFolderAsync(null)); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Conv.UpsertFolderAsync(new ImUpsertFolderRequest { Name = "  " })); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Conv.DeleteFolderAsync((string)null)); });
            _harness.Pump();
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before));

            Assert.That(Refused(_harness.Client.Conv.UpsertFolderAsync(new ImUpsertFolderRequest("Work", "never-used")), "conv.upsertFolder", ImErrorCode.InvalidArgument).Code,
                Is.EqualTo(ImErrorCode.InvalidArgument), "a tag no conversation of the caller's carries");
            Assert.That(Refused(_harness.Client.Conv.UpsertFolderAsync(new ImUpsertFolderRequest("Work")), "conv.upsertFolder", ImErrorCode.Conflict).Code,
                Is.EqualTo(ImErrorCode.Conflict), "20 folders already");
        }

        // ------------------------------------------------------------------ conv.deleteFolder

        [Test]
        public void DeleteFolder_sends_the_folder_id_and_an_unknown_one_is_not_found()
        {
            var body = Acknowledged(_harness.Client.Conv.DeleteFolderAsync(new ImFolderIdRequest("f_work")), "conv.deleteFolder");
            Assert.That(Keys(body), Is.EqualTo(new[] { "folderId" }));
            Assert.That(body["folderId"].WireString(), Is.EqualTo("f_work"));

            var shorthand = Acknowledged(_harness.Client.Conv.DeleteFolderAsync("f_2"), "conv.deleteFolder");
            Assert.That(shorthand["folderId"].WireString(), Is.EqualTo("f_2"));

            Assert.That(Refused(_harness.Client.Conv.DeleteFolderAsync("f_work"), "conv.deleteFolder", ImErrorCode.NotFound).Code,
                Is.EqualTo(ImErrorCode.NotFound));
        }

        // ------------------------------------------------------------------ msg.translate

        [Test]
        public void Translate_sends_ids_as_strings_and_decodes_every_item()
        {
            var result = Answered(_harness.Client.Msg.TranslateAsync(FullTranslate()), "msg.translate", Translation());

            var body = _harness.Socket.LastBody("msg.translate");
            Assert.That(Keys(body), Is.EqualTo(new[] { "conversationId", "messageIds", "sourceLanguage", "targetLanguage" }));
            Assert.That(body["conversationId"].WireString(), Is.EqualTo(Conversation));
            Assert.That(body["messageIds"].WireStrings(), Is.EqualTo(new[] { Big, "7" }), "a List<string> on the server; a number there is 1000");
            Assert.That(body["targetLanguage"].WireString(), Is.EqualTo("zh-CN"));
            Assert.That(body["sourceLanguage"].WireString(), Is.EqualTo("en"));

            Assert.That(result.TargetLanguage, Is.EqualTo("zh-CN"));
            Assert.That(result.Items, Has.Count.EqualTo(2));
            Assert.That(result.Items[0].MessageId, Is.EqualTo(BigValue), "a quoted snowflake past 2^53 keeps every digit");
            Assert.That(result.Items[0].Text, Is.EqualTo("你好"));
            Assert.That(result.Items[0].Cached, Is.True);
            Assert.That(result.Items[0].Error, Is.Null);
            Assert.That(result.Items[1].MessageId, Is.EqualTo(7L));
            Assert.That(result.Items[1].Text, Is.Null);
            Assert.That(result.Items[1].Cached, Is.False);
            Assert.That(result.Items[1].Error, Is.EqualTo("message not found"), "one message's failure rides on its item; the call succeeds");

            ImTestHarness.Forget(_harness.Client.Msg.TranslateAsync(new ImTranslateRequest(Conversation, "ja", "7")));
            _harness.Pump();
            Assert.That(Keys(_harness.Socket.LastBody("msg.translate")), Is.EqualTo(new[] { "conversationId", "messageIds", "targetLanguage" }),
                "no source language: the provider detects it");
        }

        /// <summary>
        /// The answer most deployments give. Each reaches the caller as an ordinary <see cref="ImException"/>
        /// with the code, the server's own words and the trace id — from an envelope with no <c>data</c> at all.
        /// </summary>
        [Test]
        public void Translate_without_a_provider_or_the_add_on_is_a_readable_refusal()
        {
            var noProvider = RefusedInWords(
                _harness.Client.Msg.TranslateAsync(FullTranslate()),
                "msg.translate",
                ImErrorCode.FeatureNotEnabled,
                "no translation provider is configured (IM:Translation:Provider)");
            Assert.That(noProvider.Code, Is.EqualTo(1203));
            Assert.That(noProvider.Message, Is.EqualTo("no translation provider is configured (IM:Translation:Provider)"));
            Assert.That(noProvider.Target, Is.EqualTo("msg.translate"));
            Assert.That(noProvider.TraceId, Is.EqualTo("tr-translate"));
            Assert.That(noProvider.IsRetryable, Is.False, "a configuration answer, not a transient one");

            var noAddOn = RefusedInWords(
                _harness.Client.Msg.TranslateAsync(FullTranslate()),
                "msg.translate",
                ImErrorCode.PlanExpired,
                "message translation is not included in this plan; start its trial or enable the add-on in the console");
            Assert.That(noAddOn.Code, Is.EqualTo(1204));
            Assert.That(noAddOn.Message, Does.StartWith("message translation is not included in this plan"));

            // The client stays usable: the next call goes out and succeeds.
            var next = _harness.Client.Msg.TranslateAsync(FullTranslate());
            AnswerNewest("msg.translate", JsonValue.NewObject().Set("code", 0L).Set("data", Translation()));
            Assert.That(next.IsCompleted && !next.IsFaulted, Is.True);
            Assert.That(next.Result.Items, Has.Count.EqualTo(2));
        }

        [Test]
        public void Translate_without_a_conversation_or_a_target_language_is_refused_before_anything_is_sent()
        {
            var before = _harness.Socket.Requests.Count;

            Assert.Throws<ArgumentNullException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.TranslateAsync(null)); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.TranslateAsync(new ImTranslateRequest(null, "ja", "7"))); });
            Assert.Throws<ArgumentException>(delegate { ImTestHarness.Forget(_harness.Client.Msg.TranslateAsync(new ImTranslateRequest(Conversation, null, "7"))); },
                "a required member of the server's type: without it the body fails to bind, 1000");

            _harness.Pump();
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before));
        }

        // ------------------------------------------------------------------ inventory

        private static readonly string[] Seven =
        {
            "msg.schedule", "msg.scheduled", "msg.cancelScheduled",
            "conv.folders", "conv.upsertFolder", "conv.deleteFolder",
            "msg.translate",
        };

        /// <summary>
        /// "The seven are typed" is something this suite can fail on: every method is driven, and the targets
        /// that reach the wire are compared with the inventory's own entries.
        /// </summary>
        [Test]
        public void Every_one_of_the_seven_is_in_the_inventory_and_typed_here()
        {
            var calls = new List<Task>
            {
                _harness.Client.Msg.ScheduleAsync(ImScheduleRequest.Text(ImRecipient.User("u_bob"), SendAt, "x")),
                _harness.Client.Msg.ScheduledAsync(),
                _harness.Client.Msg.CancelScheduledAsync(ScheduleId),
                _harness.Client.Conv.FoldersAsync(),
                _harness.Client.Conv.UpsertFolderAsync(new ImUpsertFolderRequest("Work")),
                _harness.Client.Conv.DeleteFolderAsync("f_work"),
                _harness.Client.Msg.TranslateAsync(new ImTranslateRequest(Conversation, "ja", "7")),
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

            var listed = new HashSet<string>(StringComparer.Ordinal);
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                listed.Add(endpoint["target"].AsString());
            }

            foreach (var target in Seven)
            {
                Assert.That(listed, Does.Contain(target), target + " is not an endpoint in the inventory");
                Assert.That(sent, Does.Contain(target), "no typed method sends " + target);
            }
        }

        /// <summary>
        /// The frame tests are only as wide as the bodies they build and the decoding tests only as wide as
        /// their fixtures, so both are held to the inventory's <c>payloadTypes</c>. A schedule body names one
        /// address, so the three addressing modes together must cover the type.
        /// </summary>
        [Test]
        public void The_full_fixtures_and_bodies_carry_every_member_the_server_declares()
        {
            var schedule = new SortedSet<string>(StringComparer.Ordinal);
            schedule.UnionWith(Keys(FullSchedule(ImRecipient.User("u_bob"), ImConversationType.Single).ToJson()));
            schedule.UnionWith(Keys(FullSchedule(ImRecipient.Group("g_team"), ImConversationType.Group).ToJson()));
            schedule.UnionWith(Keys(FullSchedule(ImRecipient.Conversation(Conversation), ImConversationType.Single).ToJson()));
            Assert.That(schedule, Is.EqualTo(Members("ScheduleRequest")));

            Assert.That(Keys(new ImPageRequest { Cursor = "sch:2" }.ToJson()), Is.EqualTo(Members("PageRequest")));
            Assert.That(Keys(new ImScheduleIdRequest(ScheduleId).ToJson()), Is.EqualTo(Members("ScheduleIdRequest")));
            Assert.That(Keys(FullFolder().ToJson()), Is.EqualTo(Members("UpsertFolderRequest")));
            Assert.That(Keys(new ImFolderIdRequest("f_work").ToJson()), Is.EqualTo(Members("FolderIdRequest")));
            Assert.That(Keys(FullTranslate().ToJson()), Is.EqualTo(Members("TranslateRequest")));

            Assert.That(Keys(EveryMemberSchedule()), Is.EqualTo(Members("ScheduledMessage")));
            Assert.That(Keys(Folder()), Is.EqualTo(Members("ConversationFolder")));
            Assert.That(Keys(Translation()), Is.EqualTo(Members("TranslationResult")));

            var item = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var entry in Translation()["items"].Items)
            {
                item.UnionWith(Keys(entry));
            }

            Assert.That(item, Is.EqualTo(Members("TranslatedMessage")));
        }

        /// <summary>The decoders read every member the fixtures carry — a member read under the wrong name is null or 0.</summary>
        [Test]
        public void Every_declared_member_of_the_replies_is_read()
        {
            var schedule = ImPayload.Read<ImScheduledMessage>(EveryMemberSchedule());
            Assert.That(new object[] { schedule.ScheduleId, schedule.AppId, schedule.SenderId, schedule.ConversationId, schedule.SendAt, schedule.CreatedAt, schedule.MessageId, schedule.Error },
                Is.EqualTo(new object[] { "sch_sent", "demo", "u_alice", Conversation, SendAt, 1767225600123L, BigValue, "x" }));

            var folder = ImPayload.Read<ImConversationFolder>(Folder());
            Assert.That(new object[] { folder.FolderId, folder.Name, folder.Order, folder.UnreadOnly, folder.Tags.Count, folder.Types.Count },
                Is.EqualTo(new object[] { "f_work", "Work", 2, true, 2, 2 }));
        }

        private static List<string> Members(string type)
        {
            var declared = Inventory()["payloadTypes"][type];
            Assert.That(declared.IsObject, Is.True, type + " is not in the inventory's payloadTypes");

            var names = new List<string>();
            foreach (var property in declared["properties"].Items)
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
