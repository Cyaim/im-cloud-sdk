using System;
using System.Collections.Generic;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Per-conversation <c>seq</c> tracking and gap repair: the part of the SDK that turns
    /// at-most-once, unordered WebSocket delivery into an ordered conversation.
    /// </summary>
    public sealed class GapRepairTests
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

        [Test]
        public void Contiguous_messages_are_delivered_untouched()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 2);
            _harness.PushMessage("c1", 3);

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2, 3 }));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "nothing was missing, so nothing should be fetched");
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(3));
        }

        [Test]
        public void A_skipped_seq_is_fetched_before_the_message_that_revealed_it()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 2);

            // The gap. 3 to 6 never arrived.
            _harness.PushMessage("c1", 7);

            var body = _harness.Socket.LastBody("msg.sync");
            Assert.That(body, Is.Not.Null, "a skipped seq must trigger msg.sync");
            Assert.That(body["conversationId"].WireString(), Is.EqualTo("c1"));
            Assert.That(body["fromSeq"].WireLong(), Is.EqualTo(3), "the range starts one past what we hold");
            Assert.That(body["toSeq"].WireLong(), Is.EqualTo(6), "the range stops one short of the message that arrived");
            Assert.That(body["limit"].WireLong(), Is.EqualTo(4));
            Assert.That(body["ascending"].WireBool(), Is.True);

            // Until the backfill lands, the app must not have seen 7: a conversation that jumps
            // forward and fills in behind is the bug this whole mechanism exists to prevent.
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2 }));

            _harness.Socket.Reply("msg.sync", Messages("c1", 3, 4, 5, 6));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2, 3, 4, 5, 6, 7 }));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(7));
        }

        [Test]
        public void A_backfill_that_arrives_out_of_order_is_still_delivered_in_order()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 5);

            // Nothing guarantees the server serialises the page in ascending order, and ordering is
            // the one thing this class promises.
            _harness.Socket.Reply("msg.sync", Messages("c1", 4, 2, 3));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2, 3, 4, 5 }));
        }

        [Test]
        public void Messages_that_arrive_during_a_repair_wait_for_it()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 4);

            // 5 lands while the sync for 2..3 is still in flight. It must queue behind it rather
            // than overtake the repair it would otherwise invalidate.
            _harness.PushMessage("c1", 5);
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1 }));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.EqualTo(1), "one repair at a time per conversation");

            _harness.Socket.Reply("msg.sync", Messages("c1", 2, 3));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2, 3, 4, 5 }));
        }

        [Test]
        public void Two_conversations_repair_independently()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c2", 1);

            _harness.PushMessage("c1", 4);
            _harness.PushMessage("c2", 3);

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.EqualTo(2),
                "one conversation's slow sync must not hold up another's");

            // Answered in the opposite order to make the point that they are not serialised.
            ReplySync("c2", Messages("c2", 2));
            ReplySync("c1", Messages("c1", 2, 3));

            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4));
            Assert.That(_harness.Client.DeliveredSeqOf("c2"), Is.EqualTo(3));
            Assert.That(_delivered, Has.Count.EqualTo(7));
        }

        [Test]
        public void A_gap_larger_than_the_repair_limit_skips_forward_and_reports_the_conversation()
        {
            var stale = new List<string>();
            _harness.Client.ConversationNeedsReload += stale.Add;

            _harness.PushMessage("c1", 1);

            // Away for a week. Replaying this is worse than useless: it costs the tenant money and
            // fills a chat UI nobody will scroll.
            _harness.PushMessage("c1", 20000);

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "20k messages must not be backfilled one by one");
            Assert.That(stale, Is.EqualTo(new[] { "c1" }));
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 20000 }));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(20000), "the cursor still has to be honest");
        }

        [Test]
        public void The_repair_limit_is_configurable()
        {
            using (var harness = new ImTestHarness(delegate(ImClientOptions options)
            {
                options.MaxAutoRepairSeq = 3;
            }))
            {
                var stale = new List<string>();
                harness.Client.ConversationNeedsReload += stale.Add;
                harness.Connect();

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 5);

                // 2..4 is exactly three messages, so it is still repaired.
                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(1));
                Assert.That(stale, Is.Empty);

                harness.Socket.Reply("msg.sync", Messages("c1", 2, 3, 4));
                harness.Pump();

                harness.PushMessage("c1", 10);
                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(1), "6..9 is over the limit");
                Assert.That(stale, Is.EqualTo(new[] { "c1" }));
            }
        }

        [Test]
        public void Duplicates_and_old_messages_are_dropped_silently()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 2);

            // A reconnect replay re-delivers what we already have. Every client sees this; none of
            // it should reach the app.
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 2);

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2 }));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero, "a duplicate is not a gap");
        }

        [Test]
        public void Unpersisted_messages_pass_through_without_moving_the_cursor()
        {
            _harness.PushMessage("c1", 5);

            // seq 0 means the message was never persisted — online-only chat room traffic and the
            // like. Letting it move the cursor would invent a gap on the next real message.
            _harness.PushMessage("c1", 0);
            _harness.PushMessage("c1", 6);

            Assert.That(Seqs(), Is.EqualTo(new long[] { 5, 0, 6 }));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(6));
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
        }

        [Test]
        public void A_failed_repair_still_delivers_the_message_that_arrived()
        {
            _harness.PushMessage("c1", 1);
            _harness.PushMessage("c1", 4);

            _harness.Socket.Reply("msg.sync", JsonValue.Null, ImErrorCode.RateLimited);
            _harness.Pump();

            // A chat that stops updating because one backfill failed is worse than a chat with a
            // hole in it; the conversation keeps moving and the app can reload history.
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 4 }));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4));
        }

        [Test]
        public void A_message_this_device_sent_advances_the_cursor()
        {
            _harness.PushMessage("c1", 1);

            var send = _harness.Client.SendTextAsync(ImRecipient.Conversation("c1"), "hi");
            _harness.Pump();

            _harness.Socket.Reply("msg.send", JsonValue.NewObject()
                .Set("messageId", 700L)
                .Set("seq", 2L)
                .Set("conversationId", "c1")
                .Set("clientMsgId", _harness.Socket.LastBody("msg.send")["clientMsgId"].WireString())
                .Set("createTime", 1767225600000L));
            _harness.Pump();

            Assert.That(send.IsCompleted, Is.True);
            Assert.That(send.Result.Seq, Is.EqualTo(2));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(2));

            // The next message from the peer is 3, and must not look like a gap.
            _harness.PushMessage("c1", 3);
            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 3 }));
        }

        [Test]
        public void A_send_that_lands_beyond_our_cursor_repairs_what_it_skipped()
        {
            _harness.PushMessage("c1", 1);

            var send = _harness.Client.SendTextAsync(ImRecipient.Conversation("c1"), "hi");
            _harness.Pump();

            // Two messages arrived while we were sending and neither push reached us.
            _harness.Socket.Reply("msg.send", JsonValue.NewObject()
                .Set("messageId", 700L)
                .Set("seq", 4L)
                .Set("conversationId", "c1")
                .Set("clientMsgId", "whatever")
                .Set("createTime", 1767225600000L));
            _harness.Pump();

            var body = _harness.Socket.LastBody("msg.sync");
            Assert.That(body, Is.Not.Null, "adopting the higher seq quietly would hide a real hole");
            Assert.That(body["fromSeq"].WireLong(), Is.EqualTo(2));
            Assert.That(body["toSeq"].WireLong(), Is.EqualTo(3));

            _harness.Socket.Reply("msg.sync", Messages("c1", 2, 3));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 1, 2, 3 }));
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4));
            Assert.That(send.IsCompleted, Is.True);
        }

        [Test]
        public void Reconnecting_asks_the_server_what_it_missed_and_repairs_it()
        {
            _harness.PushMessage("c1", 4);

            // What gets reported is the committed cursor, not the delivered one, so the application
            // has to say it stored the message before the server is told about it.
            _harness.Commit("c1", 4);

            _harness.Socket.ServerCloses(1006, string.Empty);
            _harness.Pump();
            _harness.Advance(ImTestHarness.ReconnectDelay);

            // The client tells the server where it is, per conversation.
            var sync = _harness.Socket.LastBody("conn.sync");
            Assert.That(sync, Is.Not.Null);
            Assert.That(sync["convSeqs"]["c1"].WireLong(), Is.EqualTo(4));
            Assert.That(sync["conversationCursor"].WireLong(), Is.EqualTo(0));

            // …and the server answers with what moved. gapsFrom carries only the first seq we are
            // missing (SPEC-02 §3.4); the upper bound is that conversation's maxSeq in the same
            // reply, which is why the repair below asks for 5..7 and not 5..anything.
            _harness.AnswerResume(JsonValue.NewObject()
                .Set("conversations", JsonValue.NewArray().Add(ConversationJson("c1", 7, 1767225600000L)))
                .Set("gapsFrom", JsonValue.NewObject().Set("c1", 5L)));

            var repair = _harness.Socket.LastBody("msg.sync");
            Assert.That(repair, Is.Not.Null);
            Assert.That(repair["fromSeq"].WireLong(), Is.EqualTo(5));
            Assert.That(repair["toSeq"].WireLong(), Is.EqualTo(7));

            _harness.Socket.Reply("msg.sync", Messages("c1", 5, 6, 7));
            _harness.Pump();

            Assert.That(Seqs(), Is.EqualTo(new long[] { 4, 5, 6, 7 }));
        }

        [Test]
        public void A_conversation_seen_for_the_first_time_adopts_its_position()
        {
            _harness.Socket.ServerCloses(1006, string.Empty);
            _harness.Pump();
            _harness.Advance(ImTestHarness.ReconnectDelay);

            // A conversation this device has never opened. Replaying its whole history on connect
            // would be the slowest possible way to show a chat list.
            _harness.AnswerResume(JsonValue.NewObject()
                .Set("conversations", JsonValue.NewArray().Add(ConversationJson("brand-new", 812, 1767225600000L)))
                .Set("gapsFrom", JsonValue.NewObject()));

            Assert.That(_harness.Socket.CountOf("msg.sync"), Is.Zero);
            Assert.That(_harness.Client.DeliveredSeqOf("brand-new"), Is.EqualTo(812));
            Assert.That(_delivered, Is.Empty);

            // And the next real message lands contiguously.
            _harness.PushMessage("brand-new", 813);
            Assert.That(Seqs(), Is.EqualTo(new long[] { 813 }));
        }

        [Test]
        public void A_resume_that_fails_leaves_the_cursors_alone()
        {
            _harness.PushMessage("c1", 4);
            _harness.Commit("c1", 4);

            _harness.Socket.ServerCloses(1006, string.Empty);
            _harness.Pump();
            _harness.Advance(ImTestHarness.ReconnectDelay);

            _harness.Socket.Reply("conn.sync", JsonValue.Null, ImErrorCode.InternalError);
            _harness.Pump();

            // Resume is best effort: the next arriving message detects the gap and repairs it the
            // normal way. The delivered cursor is back at the committed one, which is where the
            // reconnect put it, and the conversation cursor has not moved at all.
            Assert.That(_harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4));
            Assert.That(_harness.Client.CurrentCursors.ConversationCursor, Is.Zero);

            _harness.PushMessage("c1", 6);
            var repair = _harness.Socket.LastBody("msg.sync");
            Assert.That(repair, Is.Not.Null);
            Assert.That(repair["fromSeq"].WireLong(), Is.EqualTo(5));
            Assert.That(repair["toSeq"].WireLong(), Is.EqualTo(5));
        }

        [Test]
        public void A_handler_that_throws_does_not_stop_the_others()
        {
            var second = new List<long>();
            _harness.Client.MessageReceived += delegate { throw new InvalidOperationException("bad prefab"); };
            _harness.Client.MessageReceived += delegate(ImMessage message) { second.Add(message.Seq); };

            _harness.PushMessage("c1", 1);

            Assert.That(second, Is.EqualTo(new long[] { 1 }));
        }

        /// <summary>Answers the repair that a named conversation is waiting on.</summary>
        private void ReplySync(string conversationId, JsonValue messages)
        {
            _harness.Socket.ReplyMatching(
                "msg.sync",
                delegate(JsonValue body) { return body["conversationId"].AsString() == conversationId; },
                messages);

            _harness.Pump();
        }

        private long[] Seqs()
        {
            var seqs = new long[_delivered.Count];
            for (int i = 0; i < _delivered.Count; i++)
            {
                seqs[i] = _delivered[i].Seq;
            }

            return seqs;
        }

        private static JsonValue Messages(string conversationId, params long[] seqs)
        {
            var array = JsonValue.NewArray();
            for (int i = 0; i < seqs.Length; i++)
            {
                array.Add(ImFrames.MessageJson(conversationId, seqs[i]));
            }

            return JsonValue.NewObject().Set("messages", array);
        }

        private static JsonValue ConversationJson(string conversationId, long maxSeq, long updatedAt)
        {
            return JsonValue.NewObject()
                .Set("conversationId", conversationId)
                .Set("type", 1L)
                .Set("maxSeq", maxSeq)
                .Set("readSeq", 0L)
                .Set("unreadCount", 0L)
                .Set("updatedAt", updatedAt);
        }
    }
}
