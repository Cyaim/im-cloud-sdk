using System;
using System.Threading.Tasks;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>Opening, giving up, and coming back after the server said no.</summary>
    public sealed class ConnectLifecycleTests
    {
        [Test]
        public void A_connect_that_never_opens_fails_on_its_deadline()
        {
            using (var harness = new ImTestHarness())
            {
                // The handshake hangs — a gateway that accepts TCP and then does nothing, or a
                // captive portal that swallows the upgrade.
                harness.AutoOpenSockets = false;

                var connecting = harness.Client.ConnectAsync();
                harness.Pump();
                Assert.That(connecting.IsCompleted, Is.False);

                harness.Advance(TimeSpan.FromSeconds(30));

                // A task that never completes would leave a loading screen up forever, so the
                // deadline fails it and stops the client. The app can call ConnectAsync again.
                Assert.That(connecting.IsFaulted, Is.True);
                var error = connecting.Exception.GetBaseException() as ImException;
                Assert.That(error, Is.Not.Null);
                Assert.That(error.Code, Is.EqualTo(ImErrorCode.Timeout));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));
            }
        }

        [Test]
        public void Connecting_twice_gives_both_callers_the_same_answer()
        {
            using (var harness = new ImTestHarness())
            {
                var first = harness.Client.ConnectAsync();
                var second = harness.Client.ConnectAsync();
                harness.Pump();

                Assert.That(first.IsCompleted, Is.True);
                Assert.That(second.IsCompleted, Is.True);
                Assert.That(harness.Transports, Has.Count.EqualTo(1), "one connection, one socket");
            }
        }

        [Test]
        public void Connecting_after_a_terminal_kick_uses_the_token_you_set()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                harness.Socket.ServerCloses(1000, "im-kick:UserBanned");
                harness.Pump();
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Closed));

                // The documented recovery path: whatever the app did about the kick — a fresh
                // login, an appeal, a different account — it comes back with a new token.
                harness.Client.Connection.SetToken("token-after-appeal");
                var reconnecting = harness.Client.ConnectAsync();
                harness.Pump();

                Assert.That(reconnecting.IsCompleted, Is.True);
                Assert.That(harness.Transports, Has.Count.EqualTo(2));
                Assert.That(harness.Socket.Url.Query, Does.Contain("token=token-after-appeal"));
                Assert.That(harness.Client.State, Is.EqualTo(ImConnectionState.Open));
            }
        }

        [Test]
        public void Disposing_releases_the_socket()
        {
            var harness = new ImTestHarness();
            harness.Connect();
            var socket = harness.Socket;

            harness.Dispose();
            harness.Advance(TimeSpan.FromSeconds(5));

            Assert.That(socket.PolitelyClosed, Is.True, "a shutdown gets a close frame, not an abort");
            Assert.That(socket.DisposeCalled, Is.True, "the socket has to be released, close handshake or not");
        }
    }
}
