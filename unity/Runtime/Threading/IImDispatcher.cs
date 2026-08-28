using System;
using System.Collections.Generic;

namespace Cyaim.Im.Threading
{
    /// <summary>
    /// The thing that decides where SDK work runs, and when delayed work runs.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Every piece of SDK logic — decoding a frame, resolving a request, deciding to reconnect,
    /// raising an event — is posted here. In a game that means the Unity main thread. Socket I/O is
    /// the only thing that happens off it.
    /// </para>
    /// <para>
    /// This is not a nicety. Touching a <c>GameObject</c>, a <c>Transform</c>, or almost any Unity
    /// API from a worker thread is undefined behaviour that usually presents as a hard crash of the
    /// player process, and the very first thing a developer does in an <c>onMessage</c> handler is
    /// instantiate a chat bubble prefab. An SDK that raises its events on a socket thread is an SDK
    /// that crashes every game that integrates it, on a schedule set by network timing.
    /// </para>
    /// <para>
    /// Making delayed work a dispatcher concern rather than a <c>Task.Delay</c> has a second
    /// benefit: reconnect backoff and heartbeat cadence become testable against a virtual clock
    /// (<see cref="ManualDispatcher"/>) instead of against a stopwatch.
    /// </para>
    /// </remarks>
    public interface IImDispatcher
    {
        /// <summary>
        /// Queues an action to run on the dispatcher thread. Safe to call from any thread. Actions
        /// run in the order they were posted.
        /// </summary>
        void Post(Action action);

        /// <summary>
        /// Queues an action to run once after <paramref name="delay"/>. Disposing the returned
        /// handle cancels it; disposing after it has run is harmless.
        /// </summary>
        IDisposable Schedule(TimeSpan delay, Action action);
    }

    /// <summary>
    /// The queue and timer wheel shared by every <see cref="IImDispatcher"/> in the SDK. Time comes
    /// from outside, which is what lets the editor pump it from <c>Update</c> and a test pump it
    /// from a virtual clock.
    /// </summary>
    public sealed class ImDispatcherCore : IImDispatcher
    {
        private readonly object _gate = new object();
        private readonly Queue<Action> _queue = new Queue<Action>();
        private readonly List<Timer> _timers = new List<Timer>();
        private readonly List<Timer> _due = new List<Timer>();

        private double _now;

        /// <summary>Actions waiting to run. Useful in tests and for a "is the SDK keeping up" gauge.</summary>
        public int PendingActions
        {
            get
            {
                lock (_gate)
                {
                    return _queue.Count;
                }
            }
        }

        /// <summary>Timers armed and not yet fired.</summary>
        public int PendingTimers
        {
            get
            {
                lock (_gate)
                {
                    return _timers.Count;
                }
            }
        }

        /// <inheritdoc/>
        public void Post(Action action)
        {
            if (action == null)
            {
                return;
            }

            lock (_gate)
            {
                _queue.Enqueue(action);
            }
        }

        /// <inheritdoc/>
        public IDisposable Schedule(TimeSpan delay, Action action)
        {
            if (action == null)
            {
                return EmptyDisposable.Instance;
            }

            var seconds = delay.TotalSeconds;
            if (seconds < 0)
            {
                seconds = 0;
            }

            var timer = new Timer(action);

            lock (_gate)
            {
                timer.DueAt = _now + seconds;
                _timers.Add(timer);
            }

            return timer;
        }

        /// <summary>
        /// Runs everything that is ready. <paramref name="now"/> is a monotonically increasing
        /// clock in seconds; its origin does not matter, only that it never goes backwards.
        /// </summary>
        public void Pump(double now)
        {
            lock (_gate)
            {
                if (now > _now)
                {
                    _now = now;
                }
            }

            // Drain only what was already queued. An action that posts another action must not be
            // able to hold this pump — and therefore the frame — hostage.
            int budget;
            lock (_gate)
            {
                budget = _queue.Count;
            }

            while (budget-- > 0)
            {
                Action action;
                lock (_gate)
                {
                    if (_queue.Count == 0)
                    {
                        break;
                    }

                    action = _queue.Dequeue();
                }

                Run(action);
            }

            _due.Clear();
            lock (_gate)
            {
                for (int i = _timers.Count - 1; i >= 0; i--)
                {
                    var timer = _timers[i];
                    if (timer.Cancelled)
                    {
                        _timers.RemoveAt(i);
                        continue;
                    }

                    if (timer.DueAt <= _now)
                    {
                        _timers.RemoveAt(i);
                        _due.Add(timer);
                    }
                }
            }

            for (int i = 0; i < _due.Count; i++)
            {
                var timer = _due[i];
                if (!timer.Cancelled)
                {
                    Run(timer.Action);
                }
            }

            _due.Clear();
        }

        /// <summary>Drops everything queued. Used when a client is disposed mid-frame.</summary>
        public void Clear()
        {
            lock (_gate)
            {
                _queue.Clear();
                _timers.Clear();
            }
        }

        private static void Run(Action action)
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                // One handler throwing must not stop the queue: the next item may be the frame that
                // repairs a gap, and dropping it would corrupt a conversation to punish a typo.
                ImLog.Error("dispatcher action threw", error);
            }
        }

        private sealed class Timer : IDisposable
        {
            internal readonly Action Action;
            internal double DueAt;
            internal volatile bool Cancelled;

            internal Timer(Action action)
            {
                Action = action;
            }

            public void Dispose()
            {
                Cancelled = true;
            }
        }

        private sealed class EmptyDisposable : IDisposable
        {
            internal static readonly EmptyDisposable Instance = new EmptyDisposable();

            public void Dispose()
            {
            }
        }
    }
}
