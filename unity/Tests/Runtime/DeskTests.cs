using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// <c>desk.*</c> — the nine customer-service verbs, the <c>evt.desk</c> frame, and the 1801–1807
    /// notices read out of ordinary messages.
    /// </summary>
    /// <remarks>
    /// Every verb is asserted on the frame it puts on the wire — target and the whole body, by JSON
    /// kind — and on what it makes of a representative reply. Three properties carry the weight and
    /// none is visible from a signature: a transfer names exactly one target, an absent optional
    /// member is not the same as one set to a value (<c>inviteRating</c> omitted <i>invites</i>), and
    /// <c>endReason</c> is a string where its neighbour <c>state</c> is an integer.
    /// 每个动词都断言它发出的整帧，以及它对一个代表性答复的解码。
    /// </remarks>
    public sealed class DeskTests
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

        private static JsonValue Session(bool full)
        {
            var session = JsonValue.NewObject()
                .Set("sessionId", "ds_1")
                .Set("appId", "demo")
                .Set("customerId", "v_01hh")
                .Set("conversationId", "s_desk_v_01hh")
                .Set("state", full ? 1L : 0L)
                .Set("priority", full ? 3L : 0L)
                .Set("queuedAt", 1755000000000L);

            if (full)
            {
                // Every member of the server's DeskSession, each with a value no default reads as — so
                // a key spelled wrong in Read decodes to null or a default and an assertion below fails.
                // The_full_fixtures_carry_every_member_the_server_declares holds the list to the inventory.
                session
                    .Set("agentId", "a_7")
                    .Set("skill", "billing")
                    .Set("assignedAt", 1755000060000L)
                    .Set("closedAt", 1755000900000L)
                    .Set("resolution", "refunded")
                    .Set("context", JsonValue.NewObject().Set("desk.channel", "app"))
                    .Set("history", JsonValue.ArrayOf(new[] { "a_3" }))
                    .Set("firstAgentMessageAt", 1755000070000L)
                    .Set("rating", 4L)
                    .Set("ratingInvitedAt", 1755000910000L)
                    .Set("ratingComment", "quick")
                    .Set("ratedAt", 1755000920000L)
                    .Set("channel", "app")
                    .Set("visitorId", "v_01hh")
                    .Set("deskId", "dk_1")
                    .Set("groupId", "g_billing")
                    .Set("disposition", "resolved")
                    .Set("ratingReason", "slow at first")
                    .Set("ratingTags", JsonValue.ArrayOf(new[] { "polite" }))
                    .Set("snoozedUntil", 1755001000000L)
                    .Set("summary", JsonValue.NewObject()
                        .Set("issue", "refund")
                        .Set("state", "waiting on finance")
                        .Set("nextStep", "check the order")
                        .Set("generatedAt", 1755000050000L)
                        .Set("model", "demo/model"))
                    .Set("tags", JsonValue.ArrayOf(new[] { "billing/refund" }))
                    .Set("endReason", "bot-handoff")
                    .Set("ratingResolved", false)
                    .Set("star", true)
                    .Set("responseSamples", JsonValue.NewArray().Add(JsonValue.NewObject()
                        .Set("customerAt", 1L)
                        .Set("agentAt", 2L)
                        .Set("agentId", "a_7")));
            }

            return session;
        }

        private static JsonValue QueueView(bool measured)
        {
            var view = JsonValue.NewObject()
                .Set("waiting", 3L)
                .Set("assigned", 2L)
                .Set("availableAgents", 1L)
                .Set("headWaitSeconds", 95L)
                .Set("waitingBySkill", JsonValue.NewObject().Set("billing", 3L));
            return measured ? view.Set("avgFirstResponseSeconds", 12.5) : view;
        }

        private static JsonValue CannedRow()
        {
            return JsonValue.NewObject()
                .Set("id", "cr_1")
                .Set("title", "Refunds")
                .Set("content", "Refunds take 3-5 days.")
                .Set("skill", "billing")
                .Set("scope", "personal")
                .Set("folder", "refunds")
                .Set("ownerMemberId", "m_1")
                .Set("updatedAt", 1755000000000L);
        }

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

        [Test]
        public void Request_sends_an_empty_body_by_default_and_decodes_a_queued_session_with_its_absences()
        {
            var queued = Answered(_harness.Client.Desk.RequestAsync(), "desk.request", Session(false));

            Assert.That(Keys(_harness.Socket.LastBody("desk.request")), Is.Empty,
                "the plain \"talk to a human\" button sends nothing");
            Assert.That(queued.SessionId, Is.EqualTo("ds_1"));
            Assert.That(queued.State, Is.EqualTo(ImDeskSessionState.Queued));
            Assert.That(queued.AgentId, Is.Null, "absent while queued");
            Assert.That(queued.EndReason, Is.Null);
            Assert.That(queued.Summary, Is.Null);
            Assert.That(queued.Context, Is.Null);
            Assert.That(queued.Tags, Is.Empty);
            Assert.That(queued.Star, Is.False);
            Assert.That(queued.RatingResolved, Is.Null);
            Assert.That(queued.AssignedAt, Is.Null);

            Answered(_harness.Client.Desk.RequestAsync(new ImDeskRequest
            {
                Skill = "billing",
                Priority = 2,
                Context = JsonValue.NewObject().Set("desk.page", "/orders/9"),
            }), "desk.request", Session(false));

            var full = _harness.Socket.LastBody("desk.request");
            Assert.That(Keys(full), Is.EqualTo(new[] { "context", "priority", "skill" }));
            Assert.That(full["skill"].WireString(), Is.EqualTo("billing"));
            Assert.That(full["priority"].WireInt(), Is.EqualTo(2));
            Assert.That(full["context"]["desk.page"].WireString(), Is.EqualTo("/orders/9"));
        }

        [Test]
        public void Accept_names_the_session_or_nothing_and_decodes_every_product_field()
        {
            Answered(_harness.Client.Desk.AcceptAsync(), "desk.accept", Session(true));
            Assert.That(Keys(_harness.Socket.LastBody("desk.accept")), Is.Empty,
                "\"give me the next\" names no session");

            var taken = Answered(
                _harness.Client.Desk.AcceptAsync(new ImDeskAcceptRequest { SessionId = "ds_1" }),
                "desk.accept",
                Session(true));

            var named = _harness.Socket.LastBody("desk.accept");
            Assert.That(Keys(named), Is.EqualTo(new[] { "sessionId" }));
            Assert.That(named["sessionId"].WireString(), Is.EqualTo("ds_1"));

            Assert.That(taken.SessionId, Is.EqualTo("ds_1"));
            Assert.That(taken.AppId, Is.EqualTo("demo"));
            Assert.That(taken.CustomerId, Is.EqualTo("v_01hh"));
            Assert.That(taken.AgentId, Is.EqualTo("a_7"));
            Assert.That(taken.ConversationId, Is.EqualTo("s_desk_v_01hh"));
            Assert.That(taken.State, Is.EqualTo(ImDeskSessionState.Assigned));
            Assert.That(taken.Skill, Is.EqualTo("billing"));
            Assert.That(taken.Priority, Is.EqualTo(3));
            Assert.That(taken.QueuedAt, Is.EqualTo(1755000000000L));
            Assert.That(taken.AssignedAt, Is.EqualTo(1755000060000L));
            Assert.That(taken.ClosedAt, Is.EqualTo(1755000900000L));
            Assert.That(taken.Resolution, Is.EqualTo("refunded"));
            Assert.That(taken.Context["desk.channel"].AsString(), Is.EqualTo("app"));
            Assert.That(taken.History, Is.EqualTo(new[] { "a_3" }));
            Assert.That(taken.FirstAgentMessageAt, Is.EqualTo(1755000070000L));
            Assert.That(taken.Rating, Is.EqualTo(4));
            Assert.That(taken.RatingInvitedAt, Is.EqualTo(1755000910000L));
            Assert.That(taken.RatingComment, Is.EqualTo("quick"));
            Assert.That(taken.RatedAt, Is.EqualTo(1755000920000L));
            Assert.That(taken.Summary.Issue, Is.EqualTo("refund"));
            Assert.That(taken.Summary.State, Is.EqualTo("waiting on finance"));
            Assert.That(taken.Summary.NextStep, Is.EqualTo("check the order"));
            Assert.That(taken.Summary.GeneratedAt, Is.EqualTo(1755000050000L));
            Assert.That(taken.Summary.Model, Is.EqualTo("demo/model"));
            Assert.That(taken.Tags, Is.EqualTo(new[] { "billing/refund" }));
            Assert.That(taken.Channel, Is.EqualTo("app"));
            Assert.That(taken.VisitorId, Is.EqualTo("v_01hh"));
            Assert.That(taken.DeskId, Is.EqualTo("dk_1"));
            Assert.That(taken.GroupId, Is.EqualTo("g_billing"));
            Assert.That(taken.Disposition, Is.EqualTo(ImDeskDisposition.Resolved));

            // A string on the wire, unlike State beside it.
            Assert.That(taken.EndReason, Is.EqualTo(ImDeskEndReason.BotHandoff));
            Assert.That(taken.RatingReason, Is.EqualTo("slow at first"));
            Assert.That(taken.RatingResolved, Is.False);
            Assert.That(taken.RatingTags, Is.EqualTo(new[] { "polite" }));
            Assert.That(taken.Star, Is.True);
            Assert.That(taken.SnoozedUntil, Is.EqualTo(1755001000000L));
            Assert.That(taken.ResponseSamples, Has.Count.EqualTo(1));
            Assert.That(taken.ResponseSamples[0].CustomerAt, Is.EqualTo(1));
            Assert.That(taken.ResponseSamples[0].AgentAt, Is.EqualTo(2));
            Assert.That(taken.ResponseSamples[0].AgentId, Is.EqualTo("a_7"));
        }

        [Test]
        public void Transfer_sends_exactly_the_one_target_its_factory_names()
        {
            var agent = Acknowledged(
                _harness.Client.Desk.TransferAsync(ImDeskTransferRequest.Agent("ds_1", "a_9", "VIP, be gentle")),
                "desk.transfer");
            Assert.That(Keys(agent), Is.EqualTo(new[] { "note", "sessionId", "toAgentId" }));
            Assert.That(agent["toAgentId"].WireString(), Is.EqualTo("a_9"));
            Assert.That(agent["note"].WireString(), Is.EqualTo("VIP, be gentle"));

            var skill = Acknowledged(
                _harness.Client.Desk.TransferAsync(ImDeskTransferRequest.Skill("ds_1", "billing")),
                "desk.transfer");
            Assert.That(Keys(skill), Is.EqualTo(new[] { "sessionId", "toSkill" }));

            // ToQueue is a C# bool: true/false, never "true" or 1, and only when it is the target.
            var queue = Acknowledged(
                _harness.Client.Desk.TransferAsync(ImDeskTransferRequest.Queue("ds_1")),
                "desk.transfer");
            Assert.That(Keys(queue), Is.EqualTo(new[] { "sessionId", "toQueue" }));
            Assert.That(queue["toQueue"].WireBool(), Is.True);
        }

        [Test]
        public void A_refused_transfer_fails_with_the_server_code()
        {
            var pending = _harness.Client.Desk.TransferAsync(ImDeskTransferRequest.Queue("ds_1"));
            _harness.Pump();
            _harness.Socket.Reply("desk.transfer", JsonValue.Null, ImErrorCode.InvalidArgument);
            _harness.Pump();

            Assert.That(pending.IsFaulted, Is.True);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null);
            Assert.That(error.Code, Is.EqualTo(ImErrorCode.InvalidArgument));
        }

        [Test]
        public void Close_sends_only_what_the_agent_filled_in_and_invite_rating_only_when_said_out_loud()
        {
            var bare = Acknowledged(
                _harness.Client.Desk.CloseAsync(new ImDeskCloseRequest { SessionId = "ds_1" }),
                "desk.close");

            // Omitting inviteRating invites; sending false would be a different request.
            Assert.That(Keys(bare), Is.EqualTo(new[] { "sessionId" }));

            var drawer = Acknowledged(_harness.Client.Desk.CloseAsync(new ImDeskCloseRequest
            {
                SessionId = "ds_1",
                Resolution = "refunded",
                Tags = new List<string> { "billing/refund" },
                Disposition = ImDeskDisposition.ToLead,
                Summary = "wants a refund, passed to sales",
                InviteRating = false,
            }), "desk.close");

            Assert.That(Keys(drawer), Is.EqualTo(new[] { "disposition", "inviteRating", "resolution", "sessionId", "summary", "tags" }));
            Assert.That(drawer["tags"].WireStrings(), Is.EqualTo(new[] { "billing/refund" }));
            Assert.That(drawer["disposition"].WireString(), Is.EqualTo("to-lead"));
            Assert.That(drawer["inviteRating"].WireBool(), Is.False);
        }

        [Test]
        public void Status_sends_the_agent_status_as_its_integer()
        {
            var heartbeat = Acknowledged(
                _harness.Client.Desk.StatusAsync(new ImDeskStatusRequest(ImAgentStatus.Available)),
                "desk.status");

            // An enum by name is refused with 1000 before the endpoint runs.
            Assert.That(Keys(heartbeat), Is.EqualTo(new[] { "status" }));
            Assert.That(heartbeat["status"].WireInt(), Is.EqualTo(1));

            var busy = Acknowledged(
                _harness.Client.Desk.StatusAsync(new ImDeskStatusRequest(ImAgentStatus.Busy) { MaxConcurrent = 4 }),
                "desk.status");
            Assert.That(busy["status"].WireInt(), Is.EqualTo(2));
            Assert.That(busy["maxConcurrent"].WireInt(), Is.EqualTo(4));
        }

        /// <summary>
        /// The default of <see cref="ImAgentStatus"/> is Offline (0), and the server accepts it: a
        /// status request that could be built without a status would sign the agent out on every
        /// heartbeat, silently. So there is no parameterless constructor, as the other four SDKs
        /// require the status at compile time.
        /// </summary>
        [Test]
        public void A_status_request_cannot_be_built_without_a_status()
        {
            Assert.That(typeof(ImDeskStatusRequest).GetConstructor(Type.EmptyTypes), Is.Null,
                "new ImDeskStatusRequest { MaxConcurrent = 4 } would send status 0, which is Offline");
            Assert.That(typeof(ImDeskStatusRequest).GetConstructors(), Has.Length.EqualTo(1));
            Assert.That(typeof(ImDeskStatusRequest).GetConstructors()[0].GetParameters()[0].ParameterType,
                Is.EqualTo(typeof(ImAgentStatus)));
        }

        [Test]
        public void Queue_sends_no_body_and_keeps_an_unmeasured_average_null()
        {
            var view = Answered(_harness.Client.Desk.QueueAsync(), "desk.queue", QueueView(false));

            var body = _harness.Socket.LastBody("desk.queue");
            Assert.That(body == null || Keys(body).Count == 0, Is.True, "desk.queue takes no body");
            Assert.That(view.Waiting, Is.EqualTo(3));
            Assert.That(view.Assigned, Is.EqualTo(2));
            Assert.That(view.AvailableAgents, Is.EqualTo(1));
            Assert.That(view.HeadWaitSeconds, Is.EqualTo(95));
            Assert.That(view.AvgFirstResponseSeconds, Is.Null, "absent is \"not measured\", and must not read as 0");
            Assert.That(view.WaitingBySkill["billing"], Is.EqualTo(3));
        }

        [Test]
        public void Queue_decodes_a_measured_average()
        {
            var view = Answered(_harness.Client.Desk.QueueAsync(), "desk.queue", QueueView(true));

            Assert.That(view.AvgFirstResponseSeconds, Is.EqualTo(12.5));
        }

        [Test]
        public void Rate_omits_what_the_survey_did_not_ask()
        {
            var quiet = Acknowledged(
                _harness.Client.Desk.RateAsync(new ImDeskRateRequest { SessionId = "ds_1", Score = 5 }),
                "desk.rate");

            // resolved absent = the survey never asked; resolved false = "no".
            Assert.That(Keys(quiet), Is.EqualTo(new[] { "score", "sessionId" }));
            Assert.That(quiet["score"].WireInt(), Is.EqualTo(5));

            var answered = Acknowledged(_harness.Client.Desk.RateAsync(new ImDeskRateRequest
            {
                SessionId = "ds_1",
                Score = 2,
                Resolved = false,
                StarTags = new List<string> { "slow" },
                Comment = "twenty minutes",
            }), "desk.rate");

            Assert.That(Keys(answered), Is.EqualTo(new[] { "comment", "resolved", "score", "sessionId", "starTags" }));
            Assert.That(answered["resolved"].WireBool(), Is.False);
            Assert.That(answered["starTags"].WireStrings(), Is.EqualTo(new[] { "slow" }));
        }

        [Test]
        public void Canned_filters_by_what_it_is_given_and_decodes_each_tier()
        {
            var list = JsonValue.NewArray()
                .Add(CannedRow())
                .Add(JsonValue.NewObject()
                    .Set("id", "cr_2")
                    .Set("title", "Hello")
                    .Set("content", "Hi!")
                    .Set("scope", "all")
                    .Set("updatedAt", 1L));

            Answered(_harness.Client.Desk.CannedAsync(), "desk.canned", list);
            Assert.That(Keys(_harness.Socket.LastBody("desk.canned")), Is.Empty);

            var replies = Answered(_harness.Client.Desk.CannedAsync(new ImDeskCannedRequest
            {
                Skill = "billing",
                Scope = ImDeskCannedReplyScope.Personal,
                OwnerMemberId = "m_1",
            }), "desk.canned", list);

            var mine = _harness.Socket.LastBody("desk.canned");
            Assert.That(Keys(mine), Is.EqualTo(new[] { "ownerMemberId", "scope", "skill" }));
            Assert.That(mine["scope"].WireString(), Is.EqualTo("personal"));

            Assert.That(replies, Has.Count.EqualTo(2));
            Assert.That(replies[0].Id, Is.EqualTo("cr_1"));
            Assert.That(replies[0].Title, Is.EqualTo("Refunds"));
            Assert.That(replies[0].Content, Is.EqualTo("Refunds take 3-5 days."));
            Assert.That(replies[0].Skill, Is.EqualTo("billing"));
            Assert.That(replies[0].Scope, Is.EqualTo(ImDeskCannedReplyScope.Personal));
            Assert.That(replies[0].Folder, Is.EqualTo("refunds"));
            Assert.That(replies[0].OwnerMemberId, Is.EqualTo("m_1"));
            Assert.That(replies[0].UpdatedAt, Is.EqualTo(1755000000000L));
            Assert.That(replies[1].Scope, Is.EqualTo(ImDeskCannedReplyScope.All));
            Assert.That(replies[1].OwnerMemberId, Is.Null);
            Assert.That(replies[1].Skill, Is.Null);
            Assert.That(replies[1].Folder, Is.Null);
        }

        [Test]
        public void Suggest_names_the_session_and_returns_the_drafts()
        {
            var drafts = Answered(
                _harness.Client.Desk.SuggestAsync(new ImDeskSuggestRequest { SessionId = "ds_1" }),
                "desk.suggest",
                JsonValue.ArrayOf(new[] { "Sure, one moment." }));

            var body = _harness.Socket.LastBody("desk.suggest");
            Assert.That(Keys(body), Is.EqualTo(new[] { "sessionId" }));
            Assert.That(body["sessionId"].WireString(), Is.EqualTo("ds_1"));
            Assert.That(drafts, Is.EqualTo(new[] { "Sure, one moment." }));
        }

        [Test]
        public void Desk_frames_decode_a_forced_release_carries_no_session_and_an_unknown_event_is_dropped()
        {
            var received = new List<ImDeskEvent>();
            using (_harness.Client.OnDeskEvent(received.Add))
            {
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.session")
                    .Set("change", "message")
                    .Set("session", Session(true))
                    .Set("message", JsonValue.NewObject().Set("messageId", "360381357961969667"))));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.session")
                    .Set("change", "released")
                    .Set("reason", "supervisor")
                    .Set("forced", true)));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.agent")
                    .Set("change", "takeover")
                    .Set("connectionId", "conn-2")
                    .Set("memberId", "m_1")));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.somethingNew")));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.session")
                    .Set("change", "overdue")
                    .Set("session", Session(true))
                    .Set("kind", "first-response")
                    .Set("assignedAt", 1755000060000L)
                    .Set("minutes", 5L)));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.session")
                    .Set("change", "inactive")
                    .Set("session", Session(true))
                    .Set("minutes", 10L)
                    .Set("silentSince", 1755000500000L)
                    .Set("star", true)));
                _harness.Socket.Deliver(ImFrames.Push(ImPushTarget.Desk, JsonValue.NewObject()
                    .Set("event", "desk.session")
                    .Set("change", "note")
                    .Set("session", Session(true))
                    .Set("note", JsonValue.NewObject().Set("text", "called back"))
                    .Set("author", JsonValue.NewObject().Set("memberId", "m_2"))));
                _harness.Pump();
            }

            Assert.That(received, Has.Count.EqualTo(6), "the unknown event is dropped, not delivered half-built");

            Assert.That(received[0].Change, Is.EqualTo(ImDeskSessionChange.Message));
            Assert.That(received[0].Session.SessionId, Is.EqualTo("ds_1"));
            Assert.That(received[0].Message["messageId"].WireString(), Is.EqualTo("360381357961969667"));

            Assert.That(received[1].Change, Is.EqualTo(ImDeskSessionChange.Released));
            Assert.That(received[1].Session, Is.Null, "a forced release carries no session");
            Assert.That(received[1].Forced, Is.True);
            Assert.That(received[1].Reason, Is.EqualTo("supervisor"));

            Assert.That(received[2].Event, Is.EqualTo(ImDeskEvent.AgentEvent));
            Assert.That(received[2].Change, Is.EqualTo(ImDeskSessionChange.Takeover));
            Assert.That(received[2].ConnectionId, Is.EqualTo("conn-2"));
            Assert.That(received[2].MemberId, Is.EqualTo("m_1"));
            Assert.That(received[2].Session, Is.Null);

            Assert.That(received[3].Change, Is.EqualTo(ImDeskSessionChange.Overdue));
            Assert.That(received[3].Kind, Is.EqualTo("first-response"));
            Assert.That(received[3].AssignedAt, Is.EqualTo(1755000060000L));
            Assert.That(received[3].Minutes, Is.EqualTo(5));

            Assert.That(received[4].Change, Is.EqualTo(ImDeskSessionChange.Inactive));
            Assert.That(received[4].Minutes, Is.EqualTo(10));
            Assert.That(received[4].SilentSince, Is.EqualTo(1755000500000L));
            Assert.That(received[4].Star, Is.True);

            Assert.That(received[5].Change, Is.EqualTo(ImDeskSessionChange.Note));
            Assert.That(received[5].Note["text"].AsString(), Is.EqualTo("called back"));
            Assert.That(received[5].Author["memberId"].AsString(), Is.EqualTo("m_2"));
        }

        /// <summary>
        /// The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
        /// decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
        /// member the server's type declares, held here to the inventory's <c>payloadTypes</c>.
        /// </summary>
        [Test]
        public void The_full_fixtures_carry_every_member_the_server_declares()
        {
            var inventory = JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "endpoint-inventory.json")));

            List<string> Members(string type)
            {
                var names = new List<string>();
                foreach (var property in inventory["payloadTypes"][type]["properties"].Items)
                {
                    names.Add(property["name"].AsString());
                }

                names.Sort(StringComparer.Ordinal);
                return names;
            }

            Assert.That(Members("DeskSession"), Is.Not.Empty);
            Assert.That(Keys(Session(true)), Is.EqualTo(Members("DeskSession")));
            Assert.That(Keys(QueueView(true)), Is.EqualTo(Members("DeskQueueView")));
            Assert.That(Keys(CannedRow()), Is.EqualTo(Members("DeskCannedReply")));
        }

        /// <summary>CONTRACT §4.5: the change values are held to the server's list, order included.</summary>
        [Test]
        public void The_change_values_are_the_servers_thirteen_in_its_order()
        {
            var inventory = JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "endpoint-inventory.json")));

            var server = new List<string>();
            foreach (var member in inventory["deskChanges"].Members)
            {
                server.Add(member.Value.AsString());
            }

            Assert.That(server, Has.Count.EqualTo(13), "the inventory's deskChanges parsed to the wrong size");
            Assert.That(ImDeskSessionChange.All, Is.EqualTo(server));
        }

        // ------------------------------------------------------------------ 1801-1807 notices
        //
        // Translated from typescript/test/desk.test.ts ("the 1801-1807 notices are messages and have
        // to be read as such"), plus this SDK's lenient decoding: quoted numbers, members of the
        // wrong kind, member names in another case.
        // 照 TypeScript 的测试逐条对译，外加本 SDK 的宽松解码。

        /// <summary>A desk notice, as it arrives inside an ordinary message on the customer's transcript.</summary>
        private static ImMessage Notice(JsonValue content, ImMessageContentType contentType = ImMessageContentType.Notification)
        {
            return ImMessage.FromJson(JsonValue.NewObject()
                .Set("appId", "demo")
                .Set("conversationId", "c1")
                .Set("conversationType", 1L)
                .Set("seq", 4L)
                .Set("messageId", "350598345233801216")
                .Set("clientMsgId", "desk-1801-x")
                .Set("senderId", "desk")
                .Set("senderPlatform", 100L)
                .Set("contentType", (long)contentType)
                .Set("content", content)
                .Set("sendTime", 1755000000000L)
                .Set("createTime", 1755000000000L));
        }

        /// <summary>The members every notice carries, with <c>skill</c> written as a null.</summary>
        private static JsonValue NoticeContent(JsonValue code)
        {
            return JsonValue.NewObject()
                .Set("code", code)
                .Set("sessionId", "ds_1")
                .Set("customerId", "v_1")
                .Set("skill", JsonValue.Null);
        }

        private static JsonValue NoticeContent(long code)
        {
            return NoticeContent(JsonValue.Of(code));
        }

        [Test]
        public void Notices_read_all_seven_codes_with_the_extras_each_one_carries()
        {
            var queued = ImDeskNotification.Read(Notice(NoticeContent(1801).Set("skill", "billing")));
            Assert.That(queued, Is.InstanceOf<ImDeskQueuedNotification>());
            Assert.That(queued.Code, Is.EqualTo(ImDeskNotificationCode.Queued));
            Assert.That(queued.SessionId, Is.EqualTo("ds_1"));
            Assert.That(queued.CustomerId, Is.EqualTo("v_1"));
            Assert.That(queued.Skill, Is.EqualTo("billing"));
            Assert.That(queued.AgentId, Is.Null, "agentId is only written when there is one");

            var assigned = ImDeskNotification.Read(Notice(NoticeContent(1802).Set("agentId", "a_7")));
            Assert.That(assigned, Is.InstanceOf<ImDeskAssignedNotification>());
            Assert.That(assigned.Code, Is.EqualTo(ImDeskNotificationCode.Assigned));
            Assert.That(assigned.AgentId, Is.EqualTo("a_7"));
            // `skill` is written into a dictionary, where "omit nulls" does not reach, so the key is
            // there and the value is null. `agentId` is only written when there is one.
            // skill 是写进字典的，「省略 null」管不到它：键在、值是 null。agentId 则是有才写。
            Assert.That(assigned.Skill, Is.Null);

            var transferred = ImDeskNotification.Read(Notice(NoticeContent(1803)
                .Set("agentId", "a_8")
                .Set("fromAgentId", "a_7"))) as ImDeskTransferredNotification;
            Assert.That(transferred, Is.Not.Null);
            Assert.That(transferred.Code, Is.EqualTo(ImDeskNotificationCode.Transferred));
            Assert.That(transferred.AgentId, Is.EqualTo("a_8"));
            Assert.That(transferred.FromAgentId, Is.EqualTo("a_7"));

            var closed = ImDeskNotification.Read(Notice(NoticeContent(1804).Set("reason", "timeout"))) as ImDeskClosedNotification;
            Assert.That(closed, Is.Not.Null);
            Assert.That(closed.Code, Is.EqualTo(ImDeskNotificationCode.Closed));
            Assert.That(closed.Reason, Is.EqualTo(ImDeskEndReason.Timeout));
            Assert.That(closed.Resolution, Is.Null);

            var requeued = ImDeskNotification.Read(Notice(NoticeContent(1805).Set("previousAgentId", "a_7"))) as ImDeskRequeuedNotification;
            Assert.That(requeued, Is.Not.Null);
            Assert.That(requeued.Code, Is.EqualTo(ImDeskNotificationCode.Requeued));
            Assert.That(requeued.PreviousAgentId, Is.EqualTo("a_7"));

            var abandoned = ImDeskNotification.Read(Notice(NoticeContent(1806).Set("waitedSeconds", 903L))) as ImDeskAbandonedNotification;
            Assert.That(abandoned, Is.Not.Null);
            Assert.That(abandoned.Code, Is.EqualTo(ImDeskNotificationCode.Abandoned));
            Assert.That(abandoned.WaitedSeconds, Is.EqualTo(903));

            var rating = ImDeskNotification.Read(Notice(NoticeContent(1807)
                .Set("windowHours", 24L)
                .Set("askResolved", true)
                .Set("starTags", JsonValue.ArrayOf(new[] { "slow", "wrong answer" })))) as ImDeskRatingRequestedNotification;
            Assert.That(rating, Is.Not.Null);
            Assert.That(rating.Code, Is.EqualTo(ImDeskNotificationCode.RatingRequested));
            Assert.That(rating.StarTags, Is.EqualTo(new[] { "slow", "wrong answer" }));
            Assert.That(rating.AskResolved, Is.True);
            Assert.That(rating.WindowHours, Is.EqualTo(24));

            var bareRating = ImDeskNotification.Read(Notice(NoticeContent(1807))) as ImDeskRatingRequestedNotification;
            Assert.That(bareRating.StarTags, Is.Not.Null.And.Empty, "no tags configured reads as empty, never null");
            Assert.That(bareRating.AskResolved, Is.False);
            Assert.That(bareRating.WindowHours, Is.EqualTo(0));
        }

        [Test]
        public void A_closed_notice_keeps_a_typed_resolution_and_leaves_both_null_when_nothing_was_filled_in()
        {
            var typed = (ImDeskClosedNotification)ImDeskNotification.Read(Notice(NoticeContent(1804)
                .Set("agentId", "a_7")
                .Set("resolution", "refunded")));
            Assert.That(typed.Resolution, Is.EqualTo("refunded"));
            Assert.That(typed.Reason, Is.Null);
            Assert.That(typed.AgentId, Is.EqualTo("a_7"));

            var bare = (ImDeskClosedNotification)ImDeskNotification.Read(Notice(NoticeContent(1804)));
            Assert.That(bare.Resolution, Is.Null);
            Assert.That(bare.Reason, Is.Null);
        }

        [Test]
        public void Notices_coerce_the_counts_and_the_code_the_server_may_have_written_as_strings()
        {
            // `NumberHandling.AllowReadingFromString` runs in both directions in practice: a 64-bit
            // value can arrive quoted.
            // 服务端可以把 64 位数字写成字符串。
            var abandoned = (ImDeskAbandonedNotification)ImDeskNotification.Read(Notice(NoticeContent(1806).Set("waitedSeconds", "903")));
            Assert.That(abandoned.WaitedSeconds, Is.EqualTo(903));

            var large = (ImDeskAbandonedNotification)ImDeskNotification.Read(Notice(NoticeContent(1806).Set("waitedSeconds", "4294967296")));
            Assert.That(large.WaitedSeconds, Is.EqualTo(4294967296L), "a count past 32 bits is kept whole");

            var rating = (ImDeskRatingRequestedNotification)ImDeskNotification.Read(Notice(NoticeContent(1807).Set("windowHours", "24")));
            Assert.That(rating.WindowHours, Is.EqualTo(24));

            foreach (var spelling in new[] { JsonValue.Of("9.03e2"), JsonValue.Of(" 903 "), JsonValue.Of(903.0), JsonValue.Of("903.7"), JsonValue.Of(903.7) })
            {
                var read = (ImDeskAbandonedNotification)ImDeskNotification.Read(Notice(NoticeContent(1806).Set("waitedSeconds", spelling)));
                Assert.That(read.WaitedSeconds, Is.EqualTo(903), "waitedSeconds " + spelling.ToJson() + " (a fraction is cut off)");
            }

            foreach (var code in new[] { JsonValue.Of("1806"), JsonValue.Of(" 1806 "), JsonValue.Of("+1806"), JsonValue.Of("1.806e3"), JsonValue.Of(1806.0) })
            {
                Assert.That(ImDeskNotification.Read(Notice(NoticeContent(code))), Is.InstanceOf<ImDeskAbandonedNotification>(), "code " + code.ToJson());
            }
        }

        [Test]
        public void A_notice_member_of_the_wrong_kind_reads_as_its_default_and_never_throws()
        {
            // A notice is half of a customer's transcript: one odd member must not make the whole
            // line vanish, and it must not throw out of the message handler either.
            // 一个字段类型不对，不能让整条通知消失，更不能从消息回调里抛出去。
            var transferred = (ImDeskTransferredNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                .Set("code", 1803L)
                .Set("sessionId", 360381357961969667L) // an older server's numeric id: kept as its literal
                // customerId absent
                .Set("skill", 7L)
                .Set("agentId", "")
                .Set("fromAgentId", JsonValue.NewObject().Set("id", "a_7"))));
            Assert.That(transferred.SessionId, Is.EqualTo("360381357961969667"));
            Assert.That(transferred.CustomerId, Is.EqualTo(string.Empty));
            Assert.That(transferred.Skill, Is.Null, "a number is not a skill; AsString would have said \"7\"");
            Assert.That(transferred.AgentId, Is.Null, "an empty agentId is no agent");
            Assert.That(transferred.FromAgentId, Is.EqualTo(string.Empty), "an object where an id belongs is no id");

            var closed = (ImDeskClosedNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                .Set("code", 1804L)
                .Set("sessionId", "ds_1")
                .Set("resolution", 3L)
                .Set("reason", true)
                .Set("agentId", 9L)));
            Assert.That(closed.SessionId, Is.EqualTo("ds_1"));
            Assert.That(closed.Resolution, Is.Null);
            Assert.That(closed.Reason, Is.Null);
            Assert.That(closed.AgentId, Is.Null);

            var requeued = (ImDeskRequeuedNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                .Set("code", 1805L)
                .Set("previousAgentId", JsonValue.Null)
                .Set("customerId", JsonValue.NewArray().Add(JsonValue.Of("v_1")))));
            Assert.That(requeued.PreviousAgentId, Is.EqualTo(string.Empty));
            Assert.That(requeued.SessionId, Is.EqualTo(string.Empty));
            Assert.That(requeued.CustomerId, Is.EqualTo(string.Empty), "an array where an id belongs is no id");
            Assert.That(requeued.Skill, Is.Null);

            foreach (var waited in new[] { JsonValue.Of("soon"), JsonValue.NewObject(), JsonValue.Of(true), JsonValue.Of("NaN"), JsonValue.Of("Infinity"), JsonValue.Of(""), JsonValue.Of("1e40") })
            {
                var abandoned = (ImDeskAbandonedNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                    .Set("code", 1806L)
                    .Set("waitedSeconds", waited)));
                Assert.That(abandoned.WaitedSeconds, Is.EqualTo(0), "a count that is not a finite number in range (" + waited.ToJson() + ") reads as 0");
            }

            var rating = (ImDeskRatingRequestedNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                .Set("code", 1807L)
                .Set("windowHours", "a day")
                .Set("askResolved", "true") // a string is not the JSON true
                .Set("starTags", JsonValue.NewArray()
                    .Add(JsonValue.Of("slow"))
                    .Add(JsonValue.Of(5L))
                    .Add(JsonValue.Null)
                    .Add(JsonValue.NewObject().Set("tag", "x"))
                    .Add(JsonValue.Of("rude")))));
            Assert.That(rating.WindowHours, Is.EqualTo(0));
            Assert.That(rating.AskResolved, Is.False);
            Assert.That(rating.StarTags, Is.EqualTo(new[] { "slow", "rude" }), "AsStringList would have kept 5 as \"5\"");

            var tagsNotAList = (ImDeskRatingRequestedNotification)ImDeskNotification.Read(Notice(JsonValue.NewObject()
                .Set("code", 1807L)
                .Set("starTags", "slow")
                .Set("askResolved", 1L)));
            Assert.That(tagsNotAList.StarTags, Is.Not.Null.And.Empty);
            Assert.That(tagsNotAList.AskResolved, Is.False, "only the JSON true is true, not 1");
        }

        [Test]
        public void Notices_leave_an_ordinary_chat_message_alone()
        {
            // Desk notices travel down the same MessageReceived path as chat, so the handler asks
            // this first and falls through. A reader keyed on `code` alone would eventually hit a
            // tenant's own notification and draw a support line into the wrong conversation.
            var chat = Notice(NoticeContent(1801).Set("text", "hello"), ImMessageContentType.Text);
            Assert.That(ImDeskNotification.Read(chat), Is.Null, "the code is right but the content type is not a notification");
            Assert.That(ImDeskNotification.Read(Notice(JsonValue.NewObject().Set("text", "hello"))), Is.Null,
                "a notification with no code is not a desk notice");
            Assert.That(ImDeskNotification.Read(null), Is.Null);

            foreach (var content in new[] { JsonValue.Null, JsonValue.Of("1801"), JsonValue.NewArray().Add(NoticeContent(1801)) })
            {
                Assert.That(ImDeskNotification.Read(Notice(content)), Is.Null, "content " + content.ToJson() + " is not an object");
            }
        }

        [Test]
        public void Notices_refuse_the_account_error_codes_that_share_these_seven_numbers()
        {
            // 1801 is `AccountLocked` on the server's own error table and 1804 is `PasswordTooWeak`.
            // They never appear in `message.content`, and this is the assertion that keeps the two
            // tables apart: a code outside the band is not a desk notice however plausible it looks.
            // 1801 在服务端错误码表里是「账号已锁定」。这条断言守住的就是「两张表不能合并」。
            foreach (var code in new[] { 1800L, 1808L, 1500L })
            {
                Assert.That(ImDeskNotification.Read(Notice(NoticeContent(code))), Is.Null, code.ToString());
            }

            // And a code that is not a whole number is no code.
            foreach (var code in new[]
            {
                JsonValue.Of("18o1"), JsonValue.Of(true), JsonValue.Null, JsonValue.Of(1801.5), JsonValue.Of("1806.5"),
                JsonValue.Of("NaN"), JsonValue.Of("Infinity"), JsonValue.Of(""),
                JsonValue.NewObject().Set("value", 1801L), JsonValue.NewArray().Add(JsonValue.Of(1801L)),
            })
            {
                Assert.That(ImDeskNotification.Read(Notice(NoticeContent(code))), Is.Null, "code " + code.ToJson());
            }
        }

        [Test]
        public void A_notice_decoded_off_the_wire_is_read_and_a_switch_over_it_names_every_subclass()
        {
            var message = ImMessage.FromJson(JsonValue.Parse(
                "{\"conversationId\":\"c1\",\"seq\":\"4\",\"messageId\":\"350598345233801216\",\"contentType\":9,"
                + "\"senderId\":\"desk\",\"content\":{\"code\":1802,\"sessionId\":\"ds_1\",\"customerId\":\"v_1\","
                + "\"skill\":null,\"agentId\":\"a_7\"}}"));

            string Sentence(ImDeskNotification notice)
            {
                // C# does not check a switch over subclasses for exhaustiveness, so it needs a default:
                // a code a newer server adds is null from Read today, never a half-built notice.
                switch (notice)
                {
                    case ImDeskQueuedNotification _: return "queued";
                    case ImDeskAssignedNotification assigned: return "with " + assigned.AgentId;
                    case ImDeskTransferredNotification _: return "transferred";
                    case ImDeskClosedNotification _: return "closed";
                    case ImDeskRequeuedNotification _: return "requeued";
                    case ImDeskAbandonedNotification _: return "abandoned";
                    case ImDeskRatingRequestedNotification _: return "rate";
                    default: return "chat";
                }
            }

            Assert.That(Sentence(ImDeskNotification.Read(message)), Is.EqualTo("with a_7"));

            // Member names are matched as everywhere in this SDK's JsonValue: without regard to case.
            // 成员名与本 SDK 的 JsonValue 一样不分大小写。
            var pascal = ImDeskNotification.Read(ImMessage.FromJson(JsonValue.Parse(
                "{\"contentType\":9,\"content\":{\"Code\":\"1806\",\"SessionId\":\"ds_1\",\"WaitedSeconds\":12}}")));
            Assert.That(pascal, Is.InstanceOf<ImDeskAbandonedNotification>());
            Assert.That(pascal.SessionId, Is.EqualTo("ds_1"));
            Assert.That(((ImDeskAbandonedNotification)pascal).WaitedSeconds, Is.EqualTo(12));
        }

        /// <summary>
        /// The constants are held to TypeScript's, where they were first written down: a key spelled
        /// differently here is a context value the engine silently fails to copy out.
        /// </summary>
        [Test]
        public void The_notice_codes_and_the_context_keys_are_typescripts_name_for_name()
        {
            Dictionary<string, string> Block(string path, string start, string linePattern)
            {
                var text = File.ReadAllText(Path.Combine(SdkRoot(), path));
                var from = text.IndexOf(start, StringComparison.Ordinal);
                Assert.That(from, Is.GreaterThanOrEqualTo(0), start + " is not in " + path);

                var entries = new Dictionary<string, string>();
                var lines = text.Substring(from).Replace("\r\n", "\n").Split('\n');
                for (var i = 1; i < lines.Length && !lines[i].TrimStart().StartsWith("}", StringComparison.Ordinal); i++)
                {
                    var match = Regex.Match(lines[i], linePattern);
                    if (match.Success)
                    {
                        entries[match.Groups[1].Value] = match.Groups[2].Value;
                    }
                }

                return entries;
            }

            var keys = Block(Path.Combine("typescript", "src", "desk.ts"), "export const DeskContextKeys = {", @"^\s*(\w+): '([^']*)',\s*$");
            Assert.That(keys, Has.Count.EqualTo(9), "parsed TypeScript's DeskContextKeys to the wrong size");
            Assert.That(new Dictionary<string, string>
            {
                { "Channel", ImDeskContextKeys.Channel },
                { "VisitorId", ImDeskContextKeys.VisitorId },
                { "DeskId", ImDeskContextKeys.DeskId },
                { "GroupId", ImDeskContextKeys.GroupId },
                { "Origin", ImDeskContextKeys.Origin },
                { "OriginBot", ImDeskContextKeys.OriginBot },
                { "Page", ImDeskContextKeys.Page },
                { "VisitorName", ImDeskContextKeys.VisitorName },
                { "VisitorEmail", ImDeskContextKeys.VisitorEmail },
            }, Is.EquivalentTo(keys));

            var codes = Block(Path.Combine("typescript", "src", "protocol.ts"), "export const DeskNotificationCode = {", @"^\s*(\w+): (\d+),\s*$");
            Assert.That(codes, Has.Count.EqualTo(7), "parsed TypeScript's DeskNotificationCode to the wrong size");
            Assert.That(new Dictionary<string, string>
            {
                { "Queued", ImDeskNotificationCode.Queued.ToString() },
                { "Assigned", ImDeskNotificationCode.Assigned.ToString() },
                { "Transferred", ImDeskNotificationCode.Transferred.ToString() },
                { "Closed", ImDeskNotificationCode.Closed.ToString() },
                { "Requeued", ImDeskNotificationCode.Requeued.ToString() },
                { "Abandoned", ImDeskNotificationCode.Abandoned.ToString() },
                { "RatingRequested", ImDeskNotificationCode.RatingRequested.ToString() },
            }, Is.EquivalentTo(codes));

            // And each subclass answers the code its name says.
            Assert.That(new ImDeskQueuedNotification().Code, Is.EqualTo(1801));
            Assert.That(new ImDeskAssignedNotification().Code, Is.EqualTo(1802));
            Assert.That(new ImDeskTransferredNotification().Code, Is.EqualTo(1803));
            Assert.That(new ImDeskClosedNotification().Code, Is.EqualTo(1804));
            Assert.That(new ImDeskRequeuedNotification().Code, Is.EqualTo(1805));
            Assert.That(new ImDeskAbandonedNotification().Code, Is.EqualTo(1806));
            Assert.That(new ImDeskRatingRequestedNotification().Code, Is.EqualTo(1807));
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
