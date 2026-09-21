using System;
using System.Collections.Generic;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The cold-start cursor model from <c>sdk/CONTRACT.md</c> §5 — the section with a live
    /// data-loss bug behind it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The bug, stated exactly: a client that starts with no cursors reports nothing in
    /// <c>conn.sync</c>'s <c>convSeqs</c>; the server computes a gap only for conversations the
    /// client reported, so it reports none; the client then hits its own first-sight branch and
    /// adopts the server's <c>maxSeq</c>. Every message that arrived while the app was closed is now
    /// behind the cursor, will never be requested, and will never arrive. There is no error, no log
    /// line and no later event that corrects it.
    /// </para>
    /// <para>
    /// Which is why these tests assert on what goes onto the wire and on what reaches the store,
    /// rather than on what the client happens to hold in memory. Every one of them corresponds to a
    /// numbered conformance test in §10, named in its comment so the five SDKs can be compared row
    /// by row.
    /// </para>
    /// </remarks>
    public sealed class CursorStoreTests
    {
        private const long Newest = 1767225600000L;

        /// <summary>§10.1 <c>coldStartRestoresCursors</c>. Fails without the cursor store.</summary>
        /// <remarks>
        /// This is the one that catches the original defect. Without a restored cursor the first
        /// <c>conn.sync</c> carries an empty <c>convSeqs</c>, the server has nothing to diff
        /// against, and 101…104 are adopted away silently.
        /// </remarks>
        [Test]
        public void A_cold_start_reports_what_it_restored_instead_of_re_baselining()
        {
            var store = new RecordingCursorStore().Seed("c1", 100);

            using (var harness = new ImTestHarness(null, store))
            {
                var delivered = new List<long>();
                harness.Client.MessageReceived += delegate(ImMessage m) { delivered.Add(m.Seq); };

                harness.Connect(answerResume: false);

                var sync = harness.LastResume;
                Assert.That(sync, Is.Not.Null, "a connect must resume");
                Assert.That(sync["convSeqs"]["c1"].WireLong(), Is.EqualTo(100),
                    "the position the last run committed has to be the position reported");

                harness.AnswerResume(ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 104, Newest)),
                    JsonValue.NewObject().Set("c1", 101L)));

                var repair = harness.Socket.LastBody("msg.sync");
                Assert.That(repair, Is.Not.Null, "the four messages that arrived while we were shut have to be asked for");
                Assert.That(repair["fromSeq"].WireLong(), Is.EqualTo(101));
                Assert.That(repair["toSeq"].WireLong(), Is.EqualTo(104));

                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", false, 104, 101, 102, 103, 104));
                harness.Pump();

                Assert.That(delivered, Is.EqualTo(new long[] { 101, 102, 103, 104 }));
            }
        }

        /// <summary>§10.2 <c>coldStartWithoutStoreDoesNotSilentlyAdopt</c>.</summary>
        [Test]
        public void Opting_out_of_persistence_says_so_once_and_is_observable()
        {
            using (var harness = new ImTestHarness(null, ImCursorStore.InMemory()))
            {
                Assert.That(harness.Client.CursorsPersisted, Is.False,
                    "a build that is not persisting cursors has to be able to say so");
                Assert.That(harness.Client.RestoredCursors.ConvSeqs, Is.Empty);
                Assert.That(harness.Log, Has.Some.Contains("§5.3"),
                    "the opt-out warning has to name the section that explains what it costs");
            }
        }

        /// <summary>
        /// CONTRACT §5.3, the account-switch guarantee, on the path a shared device actually takes.
        /// </summary>
        /// <remarks>
        /// Alice signed out, Bob signed in, and the game pointed both at one store. Handing Bob
        /// Alice's position marks messages Bob has never seen as already consumed — one person's
        /// cursors replaying into another person's client, silently and permanently.
        /// <para>
        /// The guarantee is structural: it comes from the identity the SDK stamped into the
        /// snapshot, so a store that does nothing to keep two accounts apart still cannot defeat it.
        /// </para>
        /// </remarks>
        [Test]
        public void Cursors_belonging_to_another_account_are_refused_rather_than_replayed()
        {
            var shared = new RecordingCursorStore()
                .Seed("c1", 100)
                .SeedConversationCursor(4242);

            shared.Stamp("im.test|app|alice");

            using (var harness = new ImTestHarness(null, shared, "bob"))
            {
                harness.Connect();

                Assert.That(harness.Client.CursorScopeRejected, Is.True);
                Assert.That(harness.Client.CursorsPersisted, Is.True,
                    "another account's cursors are not a broken store");
                Assert.That(harness.Client.RestoredCursors.ConvSeqs, Is.Empty);
                Assert.That(harness.LastResume["convSeqs"].Count, Is.Zero,
                    "Bob must not report Alice's position to the server");
                Assert.That(harness.Log, Has.Some.Contains("im.test|app|alice"));
            }
        }

        /// <summary>The same store, the same account: nothing changes.</summary>
        [Test]
        public void Cursors_stamped_with_this_account_are_used_as_they_always_were()
        {
            var mine = new RecordingCursorStore().Seed("c1", 100);
            mine.Stamp("im.test|app|alice");

            using (var harness = new ImTestHarness(null, mine))
            {
                harness.Connect();

                Assert.That(harness.Client.CursorScopeRejected, Is.False);
                Assert.That(harness.LastResume["convSeqs"]["c1"].WireLong(), Is.EqualTo(100));
            }
        }

        /// <summary>A store is not optional, and the message says what to do about it.</summary>
        [Test]
        public void A_client_without_a_cursor_store_refuses_to_be_built()
        {
            // The compiler is the enforcement now: ImClientOptions takes the store as a
            // constructor argument, so `new ImClientOptions { ... }` does not compile at all and
            // this test can only assert the residual runtime case, a caller passing null. Unity was
            // the one SDK of the five enforcing this at runtime; the other four have always refused
            // to compile without a store, and now so does this one.
            var error = Assert.Throws<ArgumentNullException>(
                delegate { new ImClientOptions(null, "alice"); });

            Assert.That(error.Message, Does.Contain("cursor store"));
            Assert.That(error.Message, Does.Contain("InMemory"), "refusing has to name the escape hatch");

            var missingUser = Assert.Throws<ArgumentException>(
                delegate { new ImClientOptions(ImCursorStore.InMemory(), string.Empty); });

            Assert.That(missingUser.Message, Does.Contain("userId"));
            Assert.That(missingUser.Message, Does.Contain("§5.3"));
        }

        /// <summary>§10.3 <c>firstSightAdoptsAndPersistsSynchronously</c>.</summary>
        /// <remarks>
        /// The debounce is set to thirty seconds here precisely so that an ordinary commit could not
        /// have reached the store. If an adoption write is lost, the next cold start sees no entry,
        /// adopts a <i>newer</i> <c>maxSeq</c>, and drops everything in between — the original bug,
        /// re-created by the optimisation.
        /// </remarks>
        [Test]
        public void First_sight_is_adopted_and_written_through_before_the_next_page_is_asked_for()
        {
            var store = new RecordingCursorStore();

            using (var harness = new ImTestHarness(
                delegate(ImClientOptions options) { options.CursorFlushInterval = TimeSpan.FromSeconds(30); },
                store))
            {
                var delivered = new List<long>();
                harness.Client.MessageReceived += delegate(ImMessage m) { delivered.Add(m.Seq); };

                harness.Connect(answerResume: false);

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("brand-new", 812, Newest)),
                    hasMore: true,
                    nextCursor: "page-2"));
                harness.Pump();

                Assert.That(store.StoredSeq("brand-new"), Is.EqualTo(812),
                    "the adoption must be on disk before the next page goes out, debounce or no debounce");
                Assert.That(harness.Socket.CountOf("conn.sync"), Is.EqualTo(2), "the run has to keep paging");
                Assert.That(delivered, Is.Empty, "adopting must not replay a history nobody has seen");
                Assert.That(harness.Socket.CountOf("msg.sync"), Is.Zero);
            }
        }

        /// <summary>§10.4 <c>resumePagesUntilHasMoreFalse</c>.</summary>
        [Test]
        public void A_three_page_resume_repairs_gaps_from_every_page()
        {
            var store = new RecordingCursorStore().Seed("c1", 10).Seed("c2", 20).Seed("c3", 30);

            using (var harness = new ImTestHarness(null, store))
            {
                harness.Connect(answerResume: false);

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 12, 3000)),
                    JsonValue.NewObject().Set("c1", 11L),
                    hasMore: true,
                    nextCursor: "p2"));
                harness.Pump();

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c2", 22, 2000)),
                    JsonValue.NewObject().Set("c2", 21L),
                    hasMore: true,
                    nextCursor: "p3"));
                harness.Pump();

                Assert.That(harness.LastResume["cursor"].WireString(), Is.EqualTo("p3"),
                    "each page has to be asked for with the cursor the last one handed back");

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c3", 32, 1000)),
                    JsonValue.NewObject().Set("c3", 31L)));
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conn.sync"), Is.EqualTo(3));
                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(3),
                    "a user with more than one page of conversations must not have pages two onward skipped");
            }
        }

        /// <summary>§10.5 <c>conversationCursorAdvancesOnlyAfterFullRun</c>.</summary>
        /// <remarks>
        /// The list is sorted by <c>updatedAt</c> descending, so page one holds the newest value.
        /// Taking it and stopping pushes the cursor past every conversation on the pages that were
        /// never read, and <c>ListUserConversationsAsync</c> filters on <c>updatedAt &gt; cursor</c>
        /// — so the server will not offer them again. Re-reading a page is free; skipping one is
        /// permanent.
        /// </remarks>
        [Test]
        public void An_interrupted_run_leaves_the_conversation_cursor_where_it_was()
        {
            var store = new RecordingCursorStore().Seed("c1", 10);

            using (var harness = new ImTestHarness(null, store))
            {
                harness.Connect(answerResume: false);

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 10, 9_000_000L)),
                    hasMore: true,
                    nextCursor: "p2"));
                harness.Pump();

                // Page two never lands: the socket dies mid-run, which on a phone is the ordinary
                // way a resume ends rather than an exotic one.
                harness.Socket.Reply("conn.sync", JsonValue.Null, ImErrorCode.InternalError);
                harness.Pump();

                Assert.That(harness.Client.CurrentCursors.ConversationCursor, Is.Zero,
                    "page one's timestamp must not be adopted on behalf of pages nobody read");
                Assert.That(store.Stored.ConversationCursor, Is.Zero);
            }
        }

        /// <summary>The other half of §10.5: a run that finishes does move it.</summary>
        [Test]
        public void A_completed_run_advances_the_conversation_cursor_to_the_newest_it_saw()
        {
            var store = new RecordingCursorStore().Seed("c1", 10);

            using (var harness = new ImTestHarness(null, store))
            {
                harness.Connect(answerResume: false);

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 10, 9_000_000L)),
                    hasMore: true,
                    nextCursor: "p2"));
                harness.Pump();

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 10, 4_000_000L))));
                harness.Pump();

                Assert.That(store.Stored.ConversationCursor, Is.EqualTo(9_000_000L),
                    "the maximum across the whole run, not the maximum on the last page");
            }
        }

        /// <summary>§10.6 <c>pageWithFewerItemsThanLimitStillPages</c>.</summary>
        /// <remarks>
        /// <c>ConversationService.ListAsync</c> computes the paging cursor on the raw page, before
        /// deleted conversations are filtered out, so a page can return fewer items than the limit
        /// while <c>hasMore</c> is true. Stopping on the item count loses everything after it.
        /// </remarks>
        [Test]
        public void A_short_page_does_not_end_the_run()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect(answerResume: false);

                Assert.That(harness.LastResume["limit"].WireInt(), Is.EqualTo(200));

                harness.Socket.Reply("conn.sync", ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 5, Newest)),
                    hasMore: true,
                    nextCursor: "p2"));
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conn.sync"), Is.EqualTo(2),
                    "one item against a limit of 200 is not the end of the list");
            }
        }

        /// <summary>§10.7 <c>deliveredResetsToCommittedOnReconnect</c>.</summary>
        /// <remarks>
        /// Without the rewind the repaired messages are dropped as duplicates by the very cursor
        /// that was too far ahead, and the repair achieves nothing at all.
        /// </remarks>
        [Test]
        public void A_message_delivered_but_never_committed_is_delivered_again_after_a_reconnect()
        {
            using (var harness = new ImTestHarness())
            {
                var delivered = new List<long>();
                harness.Client.MessageReceived += delegate(ImMessage m) { delivered.Add(m.Seq); };
                harness.Connect();

                harness.PushMessage("c1", 4);
                harness.PushMessage("c1", 5);

                // The application stored 4 and was killed before it stored 5.
                harness.Commit("c1", 4);

                harness.Reconnect();

                Assert.That(harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4),
                    "the delivered cursor rewinds to what was actually stored");
                Assert.That(harness.LastResume["convSeqs"]["c1"].WireLong(), Is.EqualTo(4));

                harness.AnswerResume(ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 5, Newest)),
                    JsonValue.NewObject().Set("c1", 5L)));

                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", false, 5, 5));
                harness.Pump();

                Assert.That(delivered, Is.EqualTo(new long[] { 4, 5, 5 }),
                    "delivery is at-least-once; be idempotent on messageId");
            }
        }

        /// <summary>
        /// A conversation this process has seen but never committed is not first sight, whatever the
        /// snapshot says.
        /// </summary>
        /// <remarks>
        /// This is the trap hiding inside "first sight means no entry in the loaded snapshot". A
        /// conversation delivered live and not yet stored has no snapshot entry either, and adopting
        /// it on the next reconnect would skip everything the application had not written down —
        /// re-creating the original defect on the reconnect path instead of the cold-start one.
        /// </remarks>
        [Test]
        public void A_conversation_seen_live_but_not_committed_is_repaired_rather_than_adopted()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                harness.PushMessage("c1", 3);

                harness.Reconnect();

                // Nothing was committed, so convSeqs cannot mention c1 and the server cannot
                // compute a gap for it. The client has to work the range out for itself.
                Assert.That(harness.LastResume["convSeqs"].Has("c1"), Is.False);

                harness.AnswerResume(ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 6, Newest))));

                var repair = harness.Socket.LastBody("msg.sync");
                Assert.That(repair, Is.Not.Null, "adopting 6 here would drop 1 through 6 without a word");
                Assert.That(repair["fromSeq"].WireLong(), Is.EqualTo(1));
                Assert.That(repair["toSeq"].WireLong(), Is.EqualTo(6));
            }
        }

        /// <summary>§10.8 <c>oversizedGapAdvancesCursorAndRaisesReload</c>, on the resume path.</summary>
        [Test]
        public void An_oversized_resume_gap_moves_both_cursors_and_asks_for_a_reload()
        {
            var store = new RecordingCursorStore().Seed("c1", 1);

            using (var harness = new ImTestHarness(null, store))
            {
                var reload = new List<string>();
                harness.Client.ConversationNeedsReload += reload.Add;

                harness.Connect(answerResume: false);
                harness.AnswerResume(ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 40000, Newest)),
                    JsonValue.NewObject().Set("c1", 2L)));

                Assert.That(harness.Socket.CountOf("msg.sync"), Is.Zero, "40k messages must not be pulled one by one");
                Assert.That(reload, Is.EqualTo(new[] { "c1" }), "a hole nobody is told about is still a hole");
                Assert.That(harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(40000));
                Assert.That(store.StoredSeq("c1"), Is.EqualTo(40000),
                    "not committing here would re-request a range we have already declined, forever");
            }
        }

        /// <summary>§10.13 <c>oversizedLiveGapRaisesReload</c>, on the live path.</summary>
        [Test]
        public void An_oversized_live_gap_raises_the_same_event_as_a_resume_gap()
        {
            var store = new RecordingCursorStore();

            using (var harness = new ImTestHarness(null, store))
            {
                var reload = new List<string>();
                harness.Client.ConversationNeedsReload += reload.Add;
                harness.Connect();

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 9000);

                Assert.That(reload, Is.EqualTo(new[] { "c1" }));
                Assert.That(store.StoredSeq("c1"), Is.EqualTo(8999),
                    "the skipped span is committed; the message that revealed it is the app's to commit");
            }
        }

        /// <summary>§10.9 <c>seqZeroNeverMovesCursor</c>.</summary>
        [Test]
        public void Chat_room_traffic_moves_neither_cursor()
        {
            var store = new RecordingCursorStore();

            using (var harness = new ImTestHarness(null, store))
            {
                harness.Connect();

                harness.PushMessage("room-1", 0);
                harness.PushMessage("room-1", 0);

                Assert.That(harness.Client.DeliveredSeqOf("room-1"), Is.Zero);
                Assert.That(harness.Client.CommittedSeqOf("room-1"), Is.Zero);
                Assert.That(store.Saves, Is.Zero, "seq 0 is never persisted, so it has nothing to write");
            }
        }

        /// <summary>§10.10 <c>storeLoadFailureDoesNotAdopt</c>.</summary>
        /// <remarks>
        /// A failed load and a fresh install are indistinguishable to the adoption branch, and
        /// adopting on a failed load destroys history that is sitting intact in the app's own
        /// database. So the SDK does neither: it says so, adopts nothing, and writes nothing.
        /// </remarks>
        [Test]
        public void A_store_that_cannot_be_read_is_not_treated_as_a_fresh_install()
        {
            var store = new RecordingCursorStore { FailLoad = true };

            using (var harness = new ImTestHarness(null, store))
            {
                var failures = new List<ImCursorStoreException>();
                harness.Client.CursorStoreFailed += failures.Add;

                Assert.That(harness.Client.CursorsPersisted, Is.False);

                harness.Connect(answerResume: false);

                Assert.That(failures, Has.Count.EqualTo(1), "this is a session-wide degradation, not a log line");
                Assert.That(failures[0].Message, Does.Contain("§5.8"));

                harness.AnswerResume(ImFrames.ResumePage(
                    JsonValue.NewArray().Add(ImFrames.Conversation("c1", 500, Newest))));

                Assert.That(harness.Client.DeliveredSeqOf("c1"), Is.Zero, "nothing may be adopted");
                Assert.That(store.Saves, Is.Zero, "and nothing may be written over what could not be read");
            }
        }

        /// <summary>The recovery path §5.8 points at: the app hands its own cursors back.</summary>
        [Test]
        public void Committing_is_monotonic_so_cursors_can_be_re_derived_in_any_order()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Commit("c1", 40);
                harness.Commit("c1", 12);
                harness.Commit("c1", 41);

                Assert.That(harness.Client.CommittedSeqOf("c1"), Is.EqualTo(41));
                Assert.That(harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(41),
                    "committed can never exceed delivered, so delivered comes up to meet it");
            }
        }

        /// <summary>§10.11 <c>repairPagesUntilSyncHasMoreFalse</c>.</summary>
        /// <remarks>
        /// <c>MessageService.SyncAsync</c> clamps the limit to 500 and reports <c>hasMore</c>. A
        /// client that asks for a 900-seq range in one call gets 500 messages and, if it ignores
        /// <c>hasMore</c>, leaves the other 400 as a permanent hole — the exact failure the repair
        /// was for.
        /// </remarks>
        [Test]
        public void A_repair_keeps_asking_while_the_server_says_there_is_more()
        {
            using (var harness = new ImTestHarness(
                delegate(ImClientOptions options) { options.MaxAutoRepairSeq = 5000; }))
            {
                var delivered = new List<long>();
                harness.Client.MessageReceived += delegate(ImMessage m) { delivered.Add(m.Seq); };
                harness.Connect();

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 1202);

                Assert.That(harness.Socket.LastBody("msg.sync")["limit"].WireInt(), Is.EqualTo(500),
                    "the server clamps to 500, so asking for 1201 would silently get 500");

                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", true, 1202, 2, 3));
                harness.Pump();
                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", true, 1202, 4, 5));
                harness.Pump();
                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", false, 1202, 6));
                harness.Pump();

                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(3));
                Assert.That(delivered, Is.EqualTo(new long[] { 1, 2, 3, 4, 5, 6, 1202 }));
            }
        }

        /// <summary>§10.12 <c>repairPagesWhenPageIsShorterThanLimit</c>.</summary>
        /// <remarks>
        /// <c>hasMore</c> is computed on the raw window before per-user hidden rows are filtered
        /// out, so a page can come back empty with more still to come. The loop has to advance past
        /// the window it just read — seq is gap-free, so stepping by the limit is exact — rather
        /// than jumping to the conversation's newest seq and abandoning the rest of the range.
        /// </remarks>
        [Test]
        public void An_empty_page_with_more_to_come_does_not_end_the_repair()
        {
            using (var harness = new ImTestHarness(
                delegate(ImClientOptions options) { options.MaxAutoRepairSeq = 5000; }))
            {
                harness.Connect();

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 1101);

                // Every row of the first window is hidden from this user. Nothing to deliver, and
                // still 599 seqs of the range left to read.
                harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", true, 1101));
                harness.Pump();

                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(2), "an empty page is not an answer");
                Assert.That(harness.Socket.LastBody("msg.sync")["fromSeq"].WireLong(), Is.EqualTo(502),
                    "the next window starts past the one just read, not at the end of the conversation");
            }
        }

        /// <summary>A server stuck on <c>hasMore</c> is a hole, and is reported as one.</summary>
        [Test]
        public void A_repair_that_never_finishes_gives_up_loudly_rather_than_spinning()
        {
            using (var harness = new ImTestHarness(delegate(ImClientOptions options)
            {
                options.MaxAutoRepairSeq = 5000;
                options.MaxRepairPages = 3;
            }))
            {
                var reload = new List<string>();
                harness.Client.ConversationNeedsReload += reload.Add;
                harness.Connect();

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 2000);

                for (int i = 0; i < 3; i++)
                {
                    harness.Socket.Reply("msg.sync", ImFrames.SyncPage("c1", true, 2000));
                    harness.Pump();
                }

                Assert.That(harness.Socket.CountOf("msg.sync"), Is.EqualTo(3), "the cap has to bind");
                Assert.That(reload, Is.EqualTo(new[] { "c1" }));
            }
        }

        /// <summary>Ordinary commits may be coalesced; the flush points are not optional.</summary>
        [Test]
        public void Ordinary_commits_are_debounced_and_flushed_before_the_next_resume()
        {
            var store = new RecordingCursorStore();

            using (var harness = new ImTestHarness(
                delegate(ImClientOptions options) { options.CursorFlushInterval = TimeSpan.FromSeconds(1); },
                store))
            {
                harness.Connect();
                harness.PushMessage("c1", 1);

                harness.Commit("c1", 1);
                Assert.That(store.Saves, Is.Zero, "a player scrolling a busy group must not write once per message");

                harness.Advance(TimeSpan.FromSeconds(1));
                Assert.That(store.StoredSeq("c1"), Is.EqualTo(1));

                harness.Commit("c1", 2);
                Assert.That(store.StoredSeq("c1"), Is.EqualTo(1), "still waiting on the debounce");

                harness.Reconnect();

                Assert.That(store.StoredSeq("c1"), Is.EqualTo(2),
                    "whatever the debounce is holding has to be on disk before the server is asked what we missed");
                Assert.That(harness.LastResume["convSeqs"]["c1"].WireLong(), Is.EqualTo(2));
            }
        }

        /// <summary>The scope is what stops two accounts on one handset sharing a position.</summary>
        [Test]
        public void The_store_is_keyed_by_host_app_and_user()
        {
            var store = new RecordingCursorStore();

            using (var harness = new ImTestHarness(null, store))
            {
                harness.Connect();
                harness.Client.Commit("c1", 5);
                harness.Pump();

                // The identity is in the payload, not in the store's signature. A store never sees
                // a scope argument and therefore cannot ignore one.
                Assert.That(store.Stored.Scope, Is.EqualTo("im.test|app|alice"));
            }

            var mine = ImCursorScope.Of("wss://im.test", "app", "alice");

            // A second account on the same device must not read the first one's cursors.
            Assert.That(ImCursorScope.Of("wss://im.test", "app", "bob").Key, Is.Not.EqualTo(mine.Key));

            // The scheme and port are not part of the key: moving a deployment from ws:// to wss://
            // must not orphan what is already on the device.
            Assert.That(ImCursorScope.Of("ws://im.test:8080", "app", "alice").Key, Is.EqualTo(mine.Key));
        }

        /// <summary>Ids are tenant-chosen, and a slash in a file name lands somewhere else.</summary>
        [Test]
        public void A_scope_key_is_safe_to_use_as_a_file_name()
        {
            var key = ImCursorScope.Of("wss://im.test", "acme/prod", "user:42").StorageKey;

            Assert.That(key, Does.Not.Contain("/"));
            Assert.That(key, Does.Not.Contain(":"));
            Assert.That(key, Is.EqualTo("im.test_acme_prod_user_42"));
        }

        /// <summary>A snapshot survives the round trip, 64-bit seqs and quoted numbers included.</summary>
        [Test]
        public void A_snapshot_round_trips_through_its_own_json()
        {
            var snapshot = new ImCursorSnapshot { ConversationCursor = 1767225600000L };
            snapshot.ConvSeqs["c1"] = 9007199254740993L;
            snapshot.ConvSeqs["empty-conversation"] = 0;

            var restored = ImCursorSnapshot.FromJson(snapshot.ToJson());

            Assert.That(restored.ConversationCursor, Is.EqualTo(1767225600000L));
            Assert.That(restored.ConvSeqs["c1"], Is.EqualTo(9007199254740993L),
                "a seq past 2^53 must not be rounded on the way to disk");
            Assert.That(restored.ConvSeqs.ContainsKey("empty-conversation"), Is.True,
                "a conversation known to be empty is still a conversation we have been told about");
        }

        /// <summary>Unreadable text throws rather than reading as an empty snapshot.</summary>
        [Test]
        public void A_truncated_snapshot_throws_instead_of_pretending_to_be_empty()
        {
            Assert.Throws<ImJsonException>(delegate { ImCursorSnapshot.FromJson("{\"convSeqs\":{\"c1\":1"); });
        }
    }
}
