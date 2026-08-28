using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Telling "you were kicked" apart from "the network died", which at the socket level look
    /// identical and need opposite responses.
    /// </summary>
    public sealed class KickHandlingTests
    {
        [TestCase("MultiLoginPolicy", ImKickReason.MultiLoginPolicy)]
        [TestCase("TokenRevoked", ImKickReason.TokenRevoked)]
        [TestCase("UserBanned", ImKickReason.UserBanned)]
        [TestCase("AppDisabled", ImKickReason.AppDisabled)]
        [TestCase("AdminKick", ImKickReason.AdminKick)]
        public void Terminal_reasons_are_terminal(string raw, ImKickReason expected)
        {
            ImKick kick;

            Assert.That(ImKicks.TryParse("im-kick:" + raw, out kick), Is.True);
            Assert.That(kick.Reason, Is.EqualTo(expected));
            Assert.That(kick.IsTerminal, Is.True, raw + " must not reconnect");
            Assert.That(kick.RawReason, Is.EqualTo(raw));
        }

        [TestCase("TokenExpired", ImKickReason.TokenExpired)]
        [TestCase("QuotaExceeded", ImKickReason.QuotaExceeded)]
        [TestCase("ServerShutdown", ImKickReason.ServerShutdown)]
        public void Recoverable_reasons_are_not_terminal(string raw, ImKickReason expected)
        {
            ImKick kick;

            Assert.That(ImKicks.TryParse("im-kick:" + raw, out kick), Is.True);
            Assert.That(kick.Reason, Is.EqualTo(expected));
            Assert.That(kick.IsTerminal, Is.False, raw + " clears on its own and must reconnect");
        }

        [Test]
        public void An_unknown_reason_is_reported_but_still_reconnects()
        {
            ImKick kick;

            Assert.That(ImKicks.TryParse("im-kick:SomethingNewerThanThisBuild", out kick), Is.True);
            Assert.That(kick.Reason, Is.EqualTo(ImKickReason.Unknown));
            Assert.That(kick.RawReason, Is.EqualTo("SomethingNewerThanThisBuild"));

            // One new reason on a newer server must not be able to strand every shipped client.
            Assert.That(kick.IsTerminal, Is.False);
        }

        [Test]
        public void A_numeric_reason_is_not_mistaken_for_an_enum_member()
        {
            // Enum.TryParse would decode "4" as UserBanned and strand a player who was never
            // banned. The parser is an explicit switch for exactly this reason.
            Assert.That(ImKicks.ParseReason("4"), Is.EqualTo(ImKickReason.Unknown));
        }

        [TestCase((string)null)]
        [TestCase("")]
        [TestCase("going away")]
        [TestCase("im-kicked:UserBanned")]
        public void Anything_without_the_marker_is_a_network_failure(string reason)
        {
            ImKick kick;

            Assert.That(ImKicks.TryParse(reason, out kick), Is.False);
            Assert.That(kick.Reason, Is.EqualTo(ImKickReason.None));
        }

        [Test]
        public void A_terminal_kick_stops_the_reconnect_loop()
        {
            using (var harness = new ImTestHarness())
            {
                var kicks = new List<ImKick>();
                harness.Client.Kicked += kicks.Add;
                harness.Connect();

                harness.Socket.ServerCloses(1000, "im-kick:MultiLoginPolicy");
                harness.Pump();

                Assert.That(kicks, Has.Count.EqualTo(1));
                Assert.That(kicks[0].Reason, Is.EqualTo(ImKickReason.MultiLoginPolicy));
                Assert.That(kicks[0].IsTerminal, Is.True);
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));

                // Give it more than enough time to have reconnected, and check that it did not.
                harness.Advance(TimeSpan.FromMinutes(5));
                Assert.That(harness.Transports, Has.Count.EqualTo(1), "a terminal kick must not open a new socket");
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        [Test]
        public void A_network_failure_reconnects()
        {
            using (var harness = new ImTestHarness())
            {
                var kicks = new List<ImKick>();
                harness.Client.Kicked += kicks.Add;
                harness.Connect();

                // 1006 with no reason is what a dropped connection looks like: no close frame, so
                // no reason to read.
                harness.Socket.ServerCloses(1006, string.Empty);
                harness.Pump();

                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Reconnecting));

                harness.Advance(ImTestHarness.ReconnectDelay);

                Assert.That(harness.Transports, Has.Count.EqualTo(2));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Open));
                Assert.That(kicks, Is.Empty, "a dropped socket is not a kick");
            }
        }

        [Test]
        public void A_server_shutdown_reconnects_because_the_node_is_coming_back()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                // The rolling-update case: every socket on the node closes at once, which is when
                // full jitter earns its keep.
                harness.Socket.ServerCloses(1001, "im-kick:ServerShutdown");
                harness.Pump();
                harness.Advance(ImTestHarness.ReconnectDelay);

                Assert.That(harness.Transports, Has.Count.EqualTo(2));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Open));
            }
        }

        [Test]
        public void An_expired_token_is_replaced_before_reconnecting()
        {
            using (var harness = new ImTestHarness())
            {
                harness.NextToken = "token-fresh";
                harness.Connect();

                Assert.That(harness.Socket.Url.Query, Does.Contain("token=token-1"));

                harness.Socket.ServerCloses(1000, "im-kick:TokenExpired");
                harness.Pump();
                harness.Advance(ImTestHarness.ReconnectDelay);

                Assert.That(harness.TokenRequests, Has.Count.EqualTo(1));
                Assert.That(harness.Transports, Has.Count.EqualTo(2));
                Assert.That(harness.Socket.Url.Query, Does.Contain("token=token-fresh"));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Open));
            }
        }

        [Test]
        public void Refusing_to_supply_a_token_stops_the_client()
        {
            using (var harness = new ImTestHarness())
            {
                var kicks = new List<ImKick>();
                harness.Client.Kicked += kicks.Add;

                // Returning null is how an app says "this user is logged out now".
                harness.NextToken = null;
                harness.Connect();

                harness.Socket.ServerCloses(1000, "im-kick:TokenExpired");
                harness.Pump();
                harness.Advance(TimeSpan.FromMinutes(5));

                Assert.That(kicks, Has.Count.EqualTo(1));
                Assert.That(kicks[0].Reason, Is.EqualTo(ImKickReason.TokenExpired));
                Assert.That(harness.Transports, Has.Count.EqualTo(1));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        [Test]
        public void A_failing_token_provider_is_treated_as_a_refusal()
        {
            using (var harness = new ImTestHarness(delegate(ImClientOptions options)
            {
                options.TokenProvider = delegate(CancellationToken token)
                {
                    // The host app's own token endpoint is down. Looping on a token the server has
                    // already rejected would be worse than stopping.
                    var failed = new TaskCompletionSource<string>();
                    failed.SetException(new InvalidOperationException("token endpoint unreachable"));
                    return failed.Task;
                };
            }))
            {
                harness.Connect();

                harness.Socket.ServerCloses(1000, "im-kick:TokenExpired");
                harness.Pump();
                harness.Advance(TimeSpan.FromMinutes(5));

                Assert.That(harness.Transports, Has.Count.EqualTo(1));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        [Test]
        public void The_kick_push_is_reported_even_before_the_socket_closes()
        {
            using (var harness = new ImTestHarness())
            {
                var kicks = new List<ImKick>();
                harness.Client.Kicked += kicks.Add;
                harness.Connect();

                harness.Socket.Deliver(ImFrames.Push(
                    ImPushTarget.Kick,
                    JsonValue.NewObject().Set("reason", "AdminKick")));
                harness.Pump();

                Assert.That(kicks, Has.Count.EqualTo(1));
                Assert.That(kicks[0].Reason, Is.EqualTo(ImKickReason.AdminKick));

                // The close that follows carries the same reason; the player is told once.
                harness.Socket.ServerCloses(1000, "im-kick:AdminKick");
                harness.Pump();

                Assert.That(kicks, Has.Count.EqualTo(1));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        [Test]
        public void A_client_close_is_not_a_kick_and_does_not_reconnect()
        {
            using (var harness = new ImTestHarness())
            {
                var kicks = new List<ImKick>();
                harness.Client.Kicked += kicks.Add;
                harness.Connect();

                harness.Client.Disconnect();
                harness.Pump();
                harness.Advance(TimeSpan.FromMinutes(5));

                Assert.That(harness.Socket.PolitelyClosed, Is.True);
                Assert.That(harness.Transports, Has.Count.EqualTo(1));
                Assert.That(kicks, Is.Empty);
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }
    }
}
