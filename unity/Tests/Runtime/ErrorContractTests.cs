using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Error mapping, classification, cancellation and reentrancy — <c>sdk/CONTRACT.md</c> §7.
    /// </summary>
    /// <remarks>
    /// These rules exist because five SDKs each picking a legal-but-different behaviour is worse
    /// than any one of the choices. They are asserted rather than documented for the same reason.
    /// </remarks>
    public sealed class ErrorContractTests
    {
        /// <summary>§10.19 <c>retryClassificationMatchesTable</c>.</summary>
        /// <remarks>
        /// Both flags are computed from the code alone and must agree across all five SDKs, because
        /// an application that branches on them is writing logic it expects to port.
        /// </remarks>
        [TestCase(ImErrorCode.InternalError, true, false)]
        [TestCase(ImErrorCode.RateLimited, true, false)]
        [TestCase(ImErrorCode.Timeout, true, false)]
        [TestCase(ImErrorCode.ServiceUnavailable, true, false)]
        [TestCase(ImErrorCode.Unauthorized, false, true)]
        [TestCase(ImErrorCode.TokenExpired, false, true)]
        [TestCase(ImErrorCode.TokenInvalid, false, true)]
        [TestCase(ImErrorCode.InvalidArgument, false, false)]
        [TestCase(ImErrorCode.NotFound, false, false)]
        [TestCase(ImErrorCode.UnsupportedOperation, false, false)]
        [TestCase(ImErrorCode.Forbidden, false, false)]
        [TestCase(ImErrorCode.QuotaExceeded, false, false)]
        [TestCase(ImErrorCode.FeatureNotEnabled, false, false)]
        [TestCase(ImErrorCode.PlanExpired, false, false)]
        [TestCase(ImErrorCode.ModerationRejected, false, false)]
        [TestCase(ImErrorCode.KickedByOtherDevice, false, false)]
        public void Retry_classification_matches_the_table(int code, bool retryable, bool reauth)
        {
            var error = new ImException(code, "whatever");

            Assert.That(error.IsRetryable, Is.EqualTo(retryable));
            Assert.That(error.RequiresReauth, Is.EqualTo(reauth));
        }

        /// <summary>A code this build has never heard of is terminal, not a crash.</summary>
        [Test]
        public void An_unknown_code_is_carried_verbatim_and_treated_as_terminal()
        {
            var error = new ImException(1999, "a code from a newer server");

            Assert.That(error.Code, Is.EqualTo(1999));
            Assert.That(error.IsRetryable, Is.False);
            Assert.That(error.RequiresReauth, Is.False);
        }

        /// <summary>§10.23 <c>featureNotEnabledIsNotLatched</c>.</summary>
        /// <remarks>
        /// A tenant can flip <c>EnableTypingIndicator</c> at runtime. A client that remembers
        /// "typing is off" stays broken until the app restarts, which is a support ticket nobody can
        /// reproduce.
        /// </remarks>
        [Test]
        public void A_disabled_feature_is_reported_every_time_and_never_remembered()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var first = harness.Client.Msg.TypingAsync(new ImTypingRequest { ConversationId = "c1" });
                harness.Pump();
                harness.Socket.Reply("msg.typing", JsonValue.Null, ImErrorCode.FeatureNotEnabled);
                harness.Pump();

                Assert.That(Failure(first).Code, Is.EqualTo(ImErrorCode.FeatureNotEnabled));

                var second = harness.Client.Msg.TypingAsync(new ImTypingRequest { ConversationId = "c1" });
                harness.Pump();

                Assert.That(harness.Socket.CountOf("msg.typing"), Is.EqualTo(2),
                    "the flag belongs to the tenant, not to this process");

                harness.Socket.Reply("msg.typing", JsonValue.Null);
                harness.Pump();
                Assert.That(second.IsCompleted, Is.True);
                Assert.That(second.IsFaulted, Is.False);
            }
        }

        /// <summary>§10.21 <c>cancellationRemovesPendingEntry</c>.</summary>
        [Test]
        public void Cancelling_abandons_the_reply_and_leaves_no_entry_behind()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                using (var cancellation = new CancellationTokenSource())
                {
                    var pending = harness.Client.InvokeAsync("msg.search", null, cancellation.Token);
                    harness.Pump();

                    Assert.That(harness.Client.Connection.PendingRequests, Is.EqualTo(1));

                    cancellation.Cancel();
                    harness.Pump();

                    Assert.That(pending.IsCanceled, Is.True,
                        "cancellation is not a server outcome, so it is not an ImException");
                    Assert.That(harness.Client.Connection.PendingRequests, Is.Zero,
                        "an entry left in the map is a leak that grows for the life of the connection");
                }
            }
        }

        /// <summary>Cancelling never touches a cursor, and never cancels the server-side effect.</summary>
        [Test]
        public void A_cancelled_send_leaves_the_cursors_alone()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                harness.PushMessage("c1", 4);

                using (var cancellation = new CancellationTokenSource())
                {
                    var pending = harness.Client.Msg.SendAsync(
                        ImTestHarness.TextMessage(ImRecipient.Conversation("c1"), "hi"),
                        cancellation.Token);
                    harness.Pump();

                    cancellation.Cancel();
                    harness.Pump();

                    Assert.That(pending.IsCanceled, Is.True);
                    Assert.That(harness.Client.DeliveredSeqOf("c1"), Is.EqualTo(4));
                    Assert.That(harness.Client.CommittedSeqOf("c1"), Is.Zero);
                }
            }
        }

        /// <summary>§7.4: an expired token is renewed in place and the failed call is retried once.</summary>
        /// <remarks>
        /// Before <c>conn.reauth</c>, a token expiring mid-session cost a full reconnect — on the
        /// flaky network where tokens tend to expire, which is the reconnect anyone was trying to
        /// avoid. Retrying the send is safe because <c>clientMsgId</c> was generated before the
        /// first attempt.
        /// </remarks>
        [Test]
        public void An_expired_token_is_renewed_on_the_open_socket_and_the_call_is_retried()
        {
            using (var harness = new ImTestHarness())
            {
                harness.NextToken = "token-fresh";
                harness.Connect();

                var pending = harness.Client.Conv.UnreadTotalAsync();
                harness.Pump();

                harness.Socket.Reply("conv.unreadTotal", JsonValue.Null, ImErrorCode.TokenExpired);
                harness.Pump();

                var reauth = harness.Socket.LastBody("conn.reauth");
                Assert.That(reauth, Is.Not.Null, "the SDK has to try renewing before giving up on the call");
                Assert.That(reauth["token"].AsString(), Is.EqualTo("token-fresh"));
                Assert.That(harness.Transports, Has.Count.EqualTo(1), "and it must not drop the socket to do it");

                harness.Socket.Reply("conn.reauth", JsonValue.Null);
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conv.unreadTotal"), Is.EqualTo(2), "then the call is tried again");

                harness.Socket.Reply("conv.unreadTotal", JsonValue.Of(7L));
                harness.Pump();

                Assert.That(pending.IsCompleted, Is.True);
                Assert.That(pending.Result, Is.EqualTo(7));
            }
        }

        /// <summary>A renewal the host app refuses surfaces the original failure rather than looping.</summary>
        [Test]
        public void A_refused_renewal_surfaces_the_expiry_to_the_caller()
        {
            using (var harness = new ImTestHarness())
            {
                harness.NextToken = null;
                harness.Connect();

                var pending = harness.Client.Conv.UnreadTotalAsync();
                harness.Pump();

                harness.Socket.Reply("conv.unreadTotal", JsonValue.Null, ImErrorCode.TokenExpired);
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conn.reauth"), Is.Zero, "there was no token to send");
                Assert.That(Failure(pending).Code, Is.EqualTo(ImErrorCode.TokenExpired));
                Assert.That(Failure(pending).RequiresReauth, Is.True);
            }
        }

        /// <summary>A burst of expiries renews once, not once per call in flight.</summary>
        [Test]
        public void Concurrent_expiries_share_one_renewal()
        {
            using (var harness = new ImTestHarness())
            {
                harness.NextToken = "token-fresh";
                harness.Connect();

                var first = harness.Client.Conv.UnreadTotalAsync();
                var second = harness.Client.Msg.HistoryAsync(new ImHistoryRequest { ConversationId = "c1" });
                harness.Pump();

                harness.Socket.Reply("conv.unreadTotal", JsonValue.Null, ImErrorCode.TokenExpired);
                harness.Socket.Reply("msg.history", JsonValue.Null, ImErrorCode.TokenExpired);
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conn.reauth"), Is.EqualTo(1));

                harness.Socket.Reply("conn.reauth", JsonValue.Null);
                harness.Pump();

                Assert.That(harness.Socket.CountOf("conv.unreadTotal"), Is.EqualTo(2));
                Assert.That(harness.Socket.CountOf("msg.history"), Is.EqualTo(2));

                ImTestHarness.Forget(first);
                ImTestHarness.Forget(second);
            }
        }

        /// <summary>§10.26 <c>reentrantCallFromListenerDoesNotDeadlock</c>.</summary>
        /// <remarks>
        /// The first thing anyone writes in a message handler is a read-cursor update, so calling
        /// back into the SDK from inside a callback is the normal case rather than an abuse of it.
        /// </remarks>
        [Test]
        public void Calling_the_sdk_from_inside_a_handler_does_not_deadlock()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                harness.Client.MessageReceived += delegate(ImMessage message)
                {
                    harness.Client.Commit(message.ConversationId, message.Seq);
                    ImTestHarness.Forget(harness.Client.Conv.ReadAsync(message.ConversationId, message.Seq));
                };

                harness.PushMessage("c1", 1);
                harness.PushMessage("c1", 2);

                Assert.That(harness.Socket.CountOf("conv.read"), Is.EqualTo(2));
                Assert.That(harness.Client.CommittedSeqOf("c1"), Is.EqualTo(2));
            }
        }

        /// <summary>§10.20 <c>offlineRequestRejectsImmediately</c>, on the typed surface.</summary>
        [Test]
        public void A_typed_call_with_no_socket_rejects_rather_than_queueing()
        {
            using (var harness = new ImTestHarness())
            {
                var pending = harness.Client.User.MeAsync();
                harness.Pump();

                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.ServiceUnavailable));
                Assert.That(error.Target, Is.EqualTo("user.me"));
            }
        }

        /// <summary>§10.18 <c>businessCodeThrowsWithTraceId</c>, on the typed surface.</summary>
        [Test]
        public void A_typed_call_carries_the_trace_id_and_the_target_onto_the_error()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pending = harness.Client.Group.InfoAsync("g1");
                harness.Pump();

                harness.Socket.Reply("group.info", JsonValue.Null, ImErrorCode.NotGroupMember, "trace-9f2");
                harness.Pump();

                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.NotGroupMember));
                Assert.That(error.TraceId, Is.EqualTo("trace-9f2"), "a bug report with this is a one-query investigation");
                Assert.That(error.Target, Is.EqualTo("group.info"));
            }
        }

        private static ImException Failure(Task pending)
        {
            Assert.That(pending.IsCompleted, Is.True, "the call should have finished");
            Assert.That(pending.Exception, Is.Not.Null, "the call should have failed");

            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null, "failures reach the app as ImException");
            return error;
        }
    }
}
