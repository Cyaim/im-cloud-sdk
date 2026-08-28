using System.Collections.Generic;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Offline push registration, <c>sdk/CONTRACT.md</c> §6.
    /// </summary>
    /// <remarks>
    /// The server side of this shipped and no client SDK called it, which made offline push
    /// unreachable from every official client — the one feature every mobile deal turns on. The
    /// rules that are easy to get wrong and silent when you do: register on <i>every</i> connect
    /// rather than once at install, and unregister <i>before</i> disconnecting rather than after.
    /// </remarks>
    public sealed class PushRegistrationTests
    {
        /// <summary>§10.14 <c>registersOnEveryConnect</c>.</summary>
        /// <remarks>
        /// Not once at install: the vendor may replace a token while the process is frozen, and the
        /// server has no other way to learn that. Re-registering an unchanged token costs no write —
        /// the server debounces it — so the cheap thing is also the correct thing.
        /// </remarks>
        [Test]
        public void The_token_is_registered_again_on_every_connect()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Fcm, "vendor-token-1");
                harness.Pump();

                harness.Connect();
                AnswerRegister(harness);
                Assert.That(harness.Socket.CountOf("push.register"), Is.EqualTo(1));

                harness.Reconnect();
                harness.AnswerResume();
                AnswerRegister(harness);

                harness.Reconnect();
                harness.AnswerResume();
                AnswerRegister(harness);

                Assert.That(harness.Socket.CountOf("push.register"), Is.EqualTo(1),
                    "each socket is a fresh transport, so each one carries its own registration");
                Assert.That(harness.Transports, Has.Count.EqualTo(3));
                Assert.That(harness.Client.Push.IsRegistered, Is.True);
            }
        }

        /// <summary>Identity comes from the socket; there is no field in the body for it.</summary>
        [Test]
        public void Registration_carries_the_provider_and_the_token_and_nothing_else()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Apns, "abc123", "en-GB");
                harness.Pump();
                harness.Connect();

                var body = harness.Socket.LastBody("push.register");
                Assert.That(body, Is.Not.Null);
                Assert.That(body["provider"].AsString(), Is.EqualTo("apns"));
                Assert.That(body["token"].AsString(), Is.EqualTo("abc123"));
                Assert.That(body["language"].AsString(), Is.EqualTo("en-GB"));
                Assert.That(body.Has("userId"), Is.False, "the server would ignore it; sending it is a lie");
                Assert.That(body.Has("deviceId"), Is.False);
            }
        }

        /// <summary>§10.15 <c>unregisterPrecedesDisconnect</c>.</summary>
        /// <remarks>
        /// After the socket closes there is no authenticated channel and the token cannot be removed
        /// at all, so the order is the whole feature. Getting it backwards leaves a signed-out
        /// handset receiving the next user's notifications until the tenant backend cleans it up.
        /// </remarks>
        [Test]
        public void Logging_out_unregisters_before_the_socket_closes()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Fcm, "vendor-token-1");
                harness.Pump();
                harness.Connect();
                AnswerRegister(harness);

                var socket = harness.Socket;
                var logout = harness.Client.LogoutAsync();
                harness.Pump();

                Assert.That(socket.CountOf("push.unregister"), Is.EqualTo(1),
                    "the unregister has to be on the wire while the socket is still authenticated");
                Assert.That(socket.PolitelyClosed, Is.False, "and it has to get there before the close");

                socket.Reply("push.unregister", JsonValue.Null);
                harness.Pump();

                Assert.That(logout.IsCompleted, Is.True);
                Assert.That(socket.PolitelyClosed, Is.True);
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        /// <summary>Disconnecting on its own must never unregister.</summary>
        /// <remarks>
        /// A dead socket is precisely the state offline push exists to serve. An SDK that dropped
        /// the token on every disconnect would deliver notifications only to devices that did not
        /// need them.
        /// </remarks>
        [Test]
        public void Disconnecting_leaves_the_registration_alone()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Fcm, "vendor-token-1");
                harness.Pump();
                harness.Connect();
                AnswerRegister(harness);

                var socket = harness.Socket;
                harness.Client.Disconnect();
                harness.Pump();

                Assert.That(socket.CountOf("push.unregister"), Is.Zero);
            }
        }

        /// <summary>§10.16 <c>tokenRefreshWhileOfflineRegistersOnNextConnect</c>.</summary>
        [Test]
        public void A_token_that_arrives_while_offline_is_registered_on_the_next_connect()
        {
            using (var harness = new ImTestHarness())
            {
                // The vendor callback fires before anything is connected, which on a cold launch is
                // the ordinary order rather than the unusual one.
                harness.Client.Push.SetToken(ImPushProvider.Xiaomi, "oem-token");
                harness.Pump();

                Assert.That(harness.Client.Push.HasToken, Is.True);
                Assert.That(harness.Client.Push.IsRegistered, Is.False);

                harness.Connect();

                var body = harness.Socket.LastBody("push.register");
                Assert.That(body, Is.Not.Null);
                Assert.That(body["token"].AsString(), Is.EqualTo("oem-token"));
                Assert.That(body["provider"].AsString(), Is.EqualTo("xiaomi"),
                    "Android fragments across five OEM channels and the server cannot guess which one");
            }
        }

        /// <summary>A refresh on a live socket goes out immediately rather than waiting.</summary>
        [Test]
        public void A_token_that_changes_while_connected_is_registered_at_once()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                Assert.That(harness.Socket.CountOf("push.register"), Is.Zero, "there was no token to register");

                harness.Client.Push.SetToken(ImPushProvider.Fcm, "first");
                harness.Pump();
                AnswerRegister(harness);

                harness.Client.Push.SetToken(ImPushProvider.Fcm, "second");
                harness.Pump();

                Assert.That(harness.Socket.CountOf("push.register"), Is.EqualTo(2));
                Assert.That(harness.Socket.LastBody("push.register")["token"].AsString(), Is.EqualTo("second"));
            }
        }

        /// <summary>
        /// A token the server would not take is said out loud once, because a silently unregistered
        /// device is indistinguishable from a broken push provider.
        /// </summary>
        [Test]
        public void A_registration_that_never_succeeds_warns_once_and_says_where_to_read()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Fcm, "stale-token");
                harness.Pump();
                harness.Connect();

                harness.Socket.Reply("push.register", JsonValue.Null, ImErrorCode.InvalidArgument);
                harness.Pump();

                Assert.That(harness.Client.Push.IsRegistered, Is.False);
                Assert.That(Warnings(harness), Has.Some.Contains("§6"));
                Assert.That(Warnings(harness), Has.Count.EqualTo(1), "one warning, not one per reconnect");

                harness.Reconnect();
                harness.AnswerResume();
                harness.Socket.Reply("push.register", JsonValue.Null, ImErrorCode.InvalidArgument);
                harness.Pump();

                Assert.That(Warnings(harness), Has.Count.EqualTo(1));
            }
        }

        /// <summary>A logout whose unregister fails still logs the player out.</summary>
        [Test]
        public void A_failed_unregister_does_not_block_the_logout()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Client.Push.SetToken(ImPushProvider.Fcm, "vendor-token-1");
                harness.Pump();
                harness.Connect();
                AnswerRegister(harness);

                var socket = harness.Socket;
                var logout = harness.Client.LogoutAsync();
                harness.Pump();

                socket.Reply("push.unregister", JsonValue.Null, ImErrorCode.InternalError);
                harness.Pump();

                Assert.That(logout.IsCompleted, Is.True);
                Assert.That(logout.IsFaulted, Is.False, "a logout a network error can refuse is worse than a stale token");
                Assert.That(socket.PolitelyClosed, Is.True);
                Assert.That(harness.Log, Has.Some.Contains("push-tokens"),
                    "the log has to name the REST route the tenant backend cleans up with");
            }
        }

        private static void AnswerRegister(ImTestHarness harness)
        {
            harness.Socket.Reply("push.register", JsonValue.Null);
            harness.Pump();
        }

        private static List<string> Warnings(ImTestHarness harness)
        {
            var lines = new List<string>();
            for (int i = 0; i < harness.Log.Count; i++)
            {
                if (harness.Log[i].StartsWith("Warning ") && harness.Log[i].Contains("push token"))
                {
                    lines.Add(harness.Log[i]);
                }
            }

            return lines;
        }
    }
}
