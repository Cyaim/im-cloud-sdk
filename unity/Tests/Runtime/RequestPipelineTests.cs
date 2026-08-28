using System;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Request/response multiplexing over the one socket: correlation by id, a deadline per request,
    /// and idempotency keys that make a retry safe.
    /// </summary>
    public sealed class RequestPipelineTests
    {
        [Test]
        public void Replies_find_their_own_caller_whatever_order_they_arrive_in()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var first = harness.Client.InvokeAsync("user.profile", JsonValue.NewObject().Set("userId", "alice"));
                var second = harness.Client.InvokeAsync("conv.unreadTotal");
                harness.Pump();

                Assert.That(harness.Socket.Requests[1].Id, Is.Not.EqualTo(harness.Socket.Requests[2].Id),
                    "two in-flight requests cannot share an id");

                // Answered in the opposite order, which is the normal case: a cheap endpoint
                // overtakes an expensive one.
                harness.Socket.Reply("conv.unreadTotal", JsonValue.Of(7L));
                harness.Pump();

                Assert.That(second.IsCompleted, Is.True);
                Assert.That(second.Result.AsInt(), Is.EqualTo(7));
                Assert.That(first.IsCompleted, Is.False, "an unrelated reply must not complete this one");

                harness.Socket.Reply("user.profile", JsonValue.NewObject().Set("nickname", "Alice"));
                harness.Pump();

                Assert.That(first.Result["nickname"].AsString(), Is.EqualTo("Alice"));
            }
        }

        [Test]
        public void A_request_that_is_never_answered_fails_on_its_own_deadline()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pending = harness.Client.InvokeAsync("msg.search");
                harness.Pump();
                Assert.That(pending.IsCompleted, Is.False);

                harness.Advance(TimeSpan.FromSeconds(15));

                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.Timeout));
                Assert.That(error.Target, Is.EqualTo("msg.search"));
            }
        }

        [Test]
        public void A_request_with_no_socket_fails_immediately_instead_of_queueing()
        {
            using (var harness = new ImTestHarness())
            {
                // Never connected. A chat client that silently buffers sends produces messages that
                // arrive minutes late with no explanation.
                var pending = harness.Client.TotalUnreadAsync();
                harness.Pump();

                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.ServiceUnavailable));
            }
        }

        [Test]
        public void A_dropped_socket_fails_everything_in_flight()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pending = harness.Client.HistoryAsync("c1");
                harness.Pump();

                harness.Socket.ServerCloses(1006, string.Empty);
                harness.Pump();

                // Failing now rather than at the deadline lets the game show its retry affordance
                // while the player is still looking at the screen.
                //
                // 1004 Timeout and deliberately not 1005 ServiceUnavailable: 1005 would claim the
                // call was never delivered, and nothing here knows that — the request may well have
                // executed before the socket went. 1004 is the honest answer, and it is the one
                // that points a caller at clientMsgId idempotency rather than a blind resend.
                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.Timeout));
                Assert.That(error.IsRetryable, Is.True);
            }
        }

        [Test]
        public void A_business_error_becomes_a_typed_exception_with_its_trace_id()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pending = harness.Client.SendTextAsync(ImRecipient.User("bob"), "hello");
                harness.Pump();

                harness.Socket.Reply("msg.send", JsonValue.Null, ImErrorCode.ModerationRejected, "trace-abc123");
                harness.Pump();

                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.ModerationRejected));
                Assert.That(error.Target, Is.EqualTo("msg.send"));

                // The one field a support ticket should quote.
                Assert.That(error.TraceId, Is.EqualTo("trace-abc123"));
            }
        }

        [Test]
        public void A_transport_level_failure_is_reported_too()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pending = harness.Client.InvokeAsync("msg.doesNotExist");
                harness.Pump();

                // Status 2 is "no such endpoint" (SPEC-02 §1.2) — a different layer from the
                // business code, and it must not be reported as success.
                harness.Socket.ReplyTransportError("msg.doesNotExist", 2, "endpoint not found");
                harness.Pump();

                // 1008 UnsupportedOperation, not 1002 NotFound. 1002 would say "your group does not
                // exist"; this says "this deployment does not have this call", which is what an SDK
                // newer than a private-deployment server produces and what the integrator staring
                // at it needs told verbatim.
                var error = Failure(pending);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.UnsupportedOperation));
                Assert.That(error.Target, Is.EqualTo("msg.doesNotExist"));
                Assert.That(error.Message, Does.Contain("msg.doesNotExist"));
                Assert.That(error.IsRetryable, Is.False, "a missing endpoint will still be missing next time");
            }
        }

        [Test]
        public void Every_send_gets_an_idempotency_key_without_being_asked()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                ImTestHarness.Forget(harness.Client.SendTextAsync(ImRecipient.User("bob"), "one"));
                harness.Pump();
                var first = harness.Socket.LastBody("msg.send")["clientMsgId"].AsString();

                harness.Socket.Reply("msg.send", SendResult("c1", 1, first));
                harness.Pump();

                ImTestHarness.Forget(harness.Client.SendTextAsync(ImRecipient.User("bob"), "two"));
                harness.Pump();
                var second = harness.Socket.LastBody("msg.send")["clientMsgId"].AsString();

                // (appId, conversationId, senderId, clientMsgId) is unique server-side, so this is
                // what makes a retry after a timeout return the first result instead of posting
                // twice — and generating it here means a caller who never thought about idempotency
                // still gets it.
                Assert.That(first, Is.Not.Null.And.Not.Empty);
                Assert.That(second, Is.Not.EqualTo(first));
            }
        }

        [Test]
        public void A_caller_supplied_idempotency_key_is_kept()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                // A key from the game's own domain survives a process restart, which a generated
                // one cannot.
                ImTestHarness.Forget(harness.Client.SendAsync(new ImSendRequest
                {
                    Recipient = ImRecipient.Group("guild-7"),
                    ClientMsgId = "quest-complete-4711",
                    Content = JsonValue.NewObject().Set("text", "cleared"),
                }));

                harness.Pump();

                Assert.That(harness.Socket.LastBody("msg.send")["clientMsgId"].AsString(),
                    Is.EqualTo("quest-complete-4711"));
            }
        }

        [Test]
        public void A_send_carries_its_addressing_mode_and_content_type()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                ImTestHarness.Forget(harness.Client.SendAsync(new ImSendRequest
                {
                    Recipient = ImRecipient.Group("guild-7"),
                    ContentType = ImMessageContentType.Image,
                    Content = JsonValue.NewObject().Set("url", "objects/abc").Set("width", 1080L),
                    MentionAll = true,
                }));

                harness.Pump();

                var body = harness.Socket.LastBody("msg.send");
                Assert.That(body["groupId"].AsString(), Is.EqualTo("guild-7"));
                Assert.That(body.Has("receiverId"), Is.False);
                Assert.That(body["contentType"].AsInt(), Is.EqualTo((int)ImMessageContentType.Image));
                Assert.That(body["content"]["url"].AsString(), Is.EqualTo("objects/abc"));
                Assert.That(body["mentionAll"].AsBool(), Is.True);
                Assert.That(body["sendTime"].AsLong(), Is.GreaterThan(0));
            }
        }

        [Test]
        public void The_handshake_carries_the_fields_the_gateway_authenticates_on()
        {
            using (var harness = new ImTestHarness(delegate(ImClientOptions options)
            {
                options.ClientVersion = "1.4.2";
                options.Language = "zh-CN";
            }))
            {
                harness.Connect();

                var url = harness.Socket.Url;
                Assert.That(url.AbsolutePath, Is.EqualTo("/im"));
                Assert.That(url.Query, Does.Contain("appId=app"));
                Assert.That(url.Query, Does.Contain("deviceId=device-1"));
                Assert.That(url.Query, Does.Contain("platform=3"));
                Assert.That(url.Query, Does.Contain("v=1"));
                Assert.That(url.Query, Does.Contain("cv=1.4.2"));
                Assert.That(url.Query, Does.Contain("lang=zh-CN"));
            }
        }

        [Test]
        public void Connecting_without_the_essentials_fails_at_construction()
        {
            var incomplete = new ImClientOptions(ImCursorStore.InMemory(), "alice")
            {
                Endpoint = "wss://im.test",
            };

            // Better here, with the name of the missing field, than as a 401 in a player build.
            Assert.Throws<ArgumentException>(delegate { new ImClient(incomplete); });
        }

        private static ImException Failure(Task task)
        {
            Assert.That(task.IsFaulted, Is.True, "expected the request to fail");
            var error = task.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null, "expected an ImException, got " + task.Exception.GetBaseException());
            return error;
        }

        private static JsonValue SendResult(string conversationId, long seq, string clientMsgId)
        {
            return JsonValue.NewObject()
                .Set("messageId", 4600000000000000001L)
                .Set("seq", seq)
                .Set("conversationId", conversationId)
                .Set("clientMsgId", clientMsgId)
                .Set("createTime", 1767225600000L);
        }
    }
}
