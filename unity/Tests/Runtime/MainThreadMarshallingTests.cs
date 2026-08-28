using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using Cyaim.Im.Threading;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Where callbacks run.
    /// </summary>
    /// <remarks>
    /// A Unity SDK that raises events on a socket thread crashes every game that integrates it,
    /// because the first thing anyone writes in a message handler touches a <c>GameObject</c>. These
    /// tests hold the SDK to the rule that nothing reaches application code except from the thread
    /// that pumps the dispatcher.
    /// </remarks>
    public sealed class MainThreadMarshallingTests
    {
        [Test]
        public void A_frame_that_arrives_on_a_worker_thread_is_delivered_on_the_pumping_thread()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var pumpThread = Thread.CurrentThread.ManagedThreadId;
                var handlerThread = 0;
                harness.Client.MessageReceived += delegate { handlerThread = Thread.CurrentThread.ManagedThreadId; };

                // A real socket reads on its own thread; the fake one borrows a pool thread to be
                // just as inconvenient.
                var socketThread = Task.Run(delegate
                {
                    harness.Socket.Deliver(ImFrames.Message("c1", 1));
                    return Thread.CurrentThread.ManagedThreadId;
                });

                socketThread.Wait(TimeSpan.FromSeconds(5));
                Assert.That(socketThread.Result, Is.Not.EqualTo(pumpThread), "the test needs a genuinely different thread");
                Assert.That(handlerThread, Is.Zero, "nothing may run before the dispatcher is pumped");

                harness.Pump();

                Assert.That(handlerThread, Is.EqualTo(pumpThread));
            }
        }

        [Test]
        public void State_changes_are_marshalled_too()
        {
            using (var harness = new ImTestHarness())
            {
                var pumpThread = Thread.CurrentThread.ManagedThreadId;
                var states = new List<ImConnectionState>();
                var threads = new List<int>();

                harness.Client.StateChanged += delegate(ImConnectionState state)
                {
                    states.Add(state);
                    threads.Add(Thread.CurrentThread.ManagedThreadId);
                };

                harness.Connect();

                var closing = Task.Run(delegate { harness.Socket.ServerCloses(1006, string.Empty); });
                closing.Wait(TimeSpan.FromSeconds(5));
                harness.Pump();

                Assert.That(states, Is.EqualTo(new[]
                {
                    ImConnectionState.Connecting,
                    ImConnectionState.Open,
                    ImConnectionState.Reconnecting,
                }));

                for (int i = 0; i < threads.Count; i++)
                {
                    Assert.That(threads[i], Is.EqualTo(pumpThread));
                }
            }
        }

        [Test]
        public void A_dispatcher_action_that_throws_does_not_stop_the_queue()
        {
            var dispatcher = new ManualDispatcher();
            var ran = new List<int>();
            var previousLevel = ImLog.Level;
            var previousSink = ImLog.Sink;

            ImLog.Level = ImLogLevel.None;
            ImLog.Sink = null;

            try
            {
                dispatcher.Post(delegate { ran.Add(1); });
                dispatcher.Post(delegate { throw new InvalidOperationException("bad handler"); });

                // The next item in the queue may be the frame that repairs a gap. Dropping it to
                // punish someone else's typo would corrupt a conversation.
                dispatcher.Post(delegate { ran.Add(3); });
                dispatcher.Pump();

                Assert.That(ran, Is.EqualTo(new[] { 1, 3 }));
            }
            finally
            {
                ImLog.Level = previousLevel;
                ImLog.Sink = previousSink;
            }
        }

        [Test]
        public void Scheduled_work_runs_on_the_virtual_clock_and_can_be_cancelled()
        {
            var dispatcher = new ManualDispatcher();
            var fired = 0;

            var handle = dispatcher.Schedule(TimeSpan.FromSeconds(5), delegate { fired++; });
            dispatcher.Advance(TimeSpan.FromSeconds(4));
            Assert.That(fired, Is.Zero);

            dispatcher.Advance(TimeSpan.FromSeconds(1));
            Assert.That(fired, Is.EqualTo(1));

            var cancelled = dispatcher.Schedule(TimeSpan.FromSeconds(1), delegate { fired++; });
            cancelled.Dispose();
            dispatcher.Advance(TimeSpan.FromSeconds(5));
            Assert.That(fired, Is.EqualTo(1), "a disposed timer must not fire");

            // Disposing twice, or after it fired, is how the connection cleans up unconditionally.
            handle.Dispose();
            handle.Dispose();
        }

        [Test]
        public void Push_subscriptions_can_be_unsubscribed()
        {
            using (var harness = new ImTestHarness())
            {
                harness.Connect();

                var seen = new List<string>();
                var subscription = harness.Client.On(ImPushTarget.Typing, delegate(JsonValue data)
                {
                    seen.Add(data["conversationId"].AsString());
                });

                harness.Socket.Deliver(ImFrames.Push(
                    ImPushTarget.Typing,
                    JsonValue.NewObject().Set("conversationId", "c1").Set("typing", true)));
                harness.Pump();

                subscription.Dispose();

                harness.Socket.Deliver(ImFrames.Push(
                    ImPushTarget.Typing,
                    JsonValue.NewObject().Set("conversationId", "c2").Set("typing", true)));
                harness.Pump();

                Assert.That(seen, Is.EqualTo(new[] { "c1" }));
            }
        }
    }
}
