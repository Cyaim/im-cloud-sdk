using System;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The heartbeat, and the half-open socket it exists to find.
    /// </summary>
    public sealed class HeartbeatTests
    {
        [Test]
        public void The_first_beat_goes_out_on_the_default_cadence()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                harness.Advance(TimeSpan.FromSeconds(29));
                Assert.That(harness.Socket.CountOf("conn.heartbeat"), Is.Zero);

                harness.Advance(TimeSpan.FromSeconds(1));
                Assert.That(harness.Socket.CountOf("conn.heartbeat"), Is.EqualTo(1));
            }
        }

        [Test]
        public void The_server_owns_the_cadence()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                harness.Advance(TimeSpan.FromSeconds(30));

                // A gateway under load can widen the interval, and a client that kept its own would
                // either be dropped for being too slow or waste a phone's battery being too fast.
                harness.Socket.Reply("conn.heartbeat", JsonValue.NewObject()
                    .Set("serverTime", 1767225600000L)
                    .Set("intervalSeconds", 10L));
                harness.Pump();

                harness.Advance(TimeSpan.FromSeconds(9));
                Assert.That(harness.Socket.CountOf("conn.heartbeat"), Is.EqualTo(1));

                harness.Advance(TimeSpan.FromSeconds(1));
                Assert.That(harness.Socket.CountOf("conn.heartbeat"), Is.EqualTo(2));
            }
        }

        [Test]
        public void A_beat_that_is_never_answered_forces_the_socket_down()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var dying = harness.Socket;
                harness.Advance(TimeSpan.FromSeconds(30));
                Assert.That(dying.CountOf("conn.heartbeat"), Is.EqualTo(1));

                // Nothing answers. This is the half-open case: the phone changed network or a
                // middlebox dropped the flow, and the OS still reports a perfectly good socket
                // because nothing was ever sent to prove otherwise.
                harness.Advance(TimeSpan.FromSeconds(15));

                Assert.That(dying.Aborted, Is.True, "a polite close would wait for a reply that is never coming");
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Reconnecting));

                harness.Advance(ImTestHarness.ReconnectDelay);

                Assert.That(harness.Transports, Has.Count.EqualTo(2));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Open));
            }
        }

        [Test]
        public void Beating_stops_with_the_socket()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var closed = harness.Socket;
                closed.ServerCloses(1006, string.Empty);
                harness.Pump();

                harness.Advance(TimeSpan.FromMinutes(2));

                // The dead socket must not be beaten on, and the new one starts its own cadence
                // rather than inheriting a timer from its predecessor.
                Assert.That(closed.CountOf("conn.heartbeat"), Is.Zero);
                Assert.That(harness.Socket, Is.Not.SameAs(closed));
            }
        }

        [Test]
        public void A_cadence_the_server_asked_for_survives_a_reconnect()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                harness.Advance(TimeSpan.FromSeconds(30));

                harness.Socket.Reply("conn.heartbeat", JsonValue.NewObject()
                    .Set("serverTime", 1767225600000L)
                    .Set("intervalSeconds", 5L));
                harness.Pump();

                harness.Socket.ServerCloses(1006, string.Empty);
                harness.Pump();
                harness.Advance(ImTestHarness.ReconnectDelay);

                var reconnected = harness.Socket;
                harness.Advance(TimeSpan.FromSeconds(5));

                // Going back to the 30 s default here would be a regression, not a reset: a server
                // that asked for 5 s would drop this session before its first beat.
                Assert.That(reconnected.CountOf("conn.heartbeat"), Is.EqualTo(1));
            }
        }

        [Test]
        public void A_reconnect_resumes_from_the_cursors_this_device_already_had()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();
                harness.PushMessage("c1", 12);

                // convSeqs reports the committed cursor, not the delivered one, so the application
                // has to say it stored the message. A message that is only in memory is exactly the
                // one a crash loses, and reporting it as stored is what makes the server skip it.
                harness.Commit("c1", 12);

                harness.Socket.ServerCloses(1006, string.Empty);
                harness.Pump();
                harness.Advance(ImTestHarness.ReconnectDelay);

                // Not a replay of everything: the server is told where this device is and answers
                // with the difference. A client that has been offline for a week is behind by more
                // messages than it can usefully receive at once.
                var sync = harness.Socket.LastBody("conn.sync");
                Assert.That(sync["convSeqs"]["c1"].WireLong(), Is.EqualTo(12));
                Assert.That(sync["limit"].WireInt(), Is.EqualTo(200));
            }
        }
    }
}
