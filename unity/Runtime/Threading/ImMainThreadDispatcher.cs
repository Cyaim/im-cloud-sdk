using System;
using System.Diagnostics;
using UnityEngine;

namespace Cyaim.Im.Threading
{
    /// <summary>
    /// The default dispatcher: a hidden, scene-independent behaviour that drains the SDK queue from
    /// <c>Update</c>, so every callback the SDK raises lands on the Unity main thread.
    /// </summary>
    /// <remarks>
    /// <para>
    /// It creates itself the first time an <see cref="ImClient"/> is constructed and survives scene
    /// loads. There is nothing to add to a scene and nothing to remember to do.
    /// </para>
    /// <para>
    /// Two consequences worth knowing about:
    /// </para>
    /// <list type="bullet">
    /// <item><description>
    /// The clock is a wall clock, not <c>Time.time</c>. A game that sets <c>Time.timeScale = 0</c>
    /// for a pause menu still has to send heartbeats, or the gateway will decide it went away.
    /// </description></item>
    /// <item><description>
    /// When the OS suspends the app, <c>Update</c> stops and so does everything here. The socket
    /// dies quietly in the background; on resume the first missed heartbeat forces a close and the
    /// normal reconnect-and-resume path runs. That is the intended behaviour on mobile — the
    /// alternative is a background thread the platform will kill anyway.
    /// </description></item>
    /// </list>
    /// </remarks>
    [AddComponentMenu("")]
    [DisallowMultipleComponent]
    public sealed class ImMainThreadDispatcher : MonoBehaviour, IImDispatcher
    {
        private static ImMainThreadDispatcher _instance;
        private static readonly Stopwatch Clock = Stopwatch.StartNew();

        private readonly ImDispatcherCore _core = new ImDispatcherCore();

        /// <summary>
        /// Unity is about to stop calling <c>Update</c>: the app is going to the background, losing
        /// focus, or quitting.
        /// </summary>
        /// <remarks>
        /// <para>
        /// This is the last moment anything queued is guaranteed to run, which makes it the moment
        /// an SDK has to write through whatever it was still holding — <see cref="ImClient"/>
        /// flushes its cursor store here. Handlers run synchronously on the main thread and must be
        /// short; posting to the dispatcher instead is exactly the mistake this event exists to
        /// avoid, because the pump may never run again.
        /// </para>
        /// <para>
        /// Raised from <c>OnApplicationPause(true)</c>, <c>OnApplicationFocus(false)</c> and
        /// <c>OnApplicationQuit</c>. All three, because no one of them fires on every platform:
        /// mobile gets pause, the editor and desktop get focus, and a clean exit gets quit. Handlers
        /// see it more than once per suspension and must be idempotent.
        /// </para>
        /// <para>
        /// Static because a client can outlive any one dispatcher instance and because subscribing
        /// must not force the behaviour into existence — touching
        /// <see cref="Instance"/> outside play mode throws.
        /// </para>
        /// </remarks>
        public static event Action ApplicationSuspending;

        /// <summary>
        /// The process-wide dispatcher, created on first use.
        /// </summary>
        /// <exception cref="InvalidOperationException">
        /// Accessed outside play mode. There is no <c>Update</c> loop in the editor when the game is
        /// not running, so a dispatcher created there would silently never fire; tests and editor
        /// tooling should use <see cref="ManualDispatcher"/> and pump it themselves.
        /// </exception>
        public static ImMainThreadDispatcher Instance
        {
            get
            {
                if (_instance != null)
                {
                    return _instance;
                }

                if (!Application.isPlaying)
                {
                    throw new InvalidOperationException(
                        "ImMainThreadDispatcher needs a running player loop. Outside play mode, " +
                        "construct the client with ImClientOptions.Dispatcher = new ManualDispatcher() " +
                        "and pump it yourself.");
                }

                var host = new GameObject("Cyaim.Im Main Thread Dispatcher");
                _instance = host.AddComponent<ImMainThreadDispatcher>();
                DontDestroyOnLoad(host);
                return _instance;
            }
        }

        /// <inheritdoc/>
        public void Post(Action action)
        {
            _core.Post(action);
        }

        /// <inheritdoc/>
        public IDisposable Schedule(TimeSpan delay, Action action)
        {
            return _core.Schedule(delay, action);
        }

        private void Update()
        {
            _core.Pump(Clock.Elapsed.TotalSeconds);
        }

        private void OnApplicationPause(bool paused)
        {
            if (paused)
            {
                RaiseSuspending();
            }
        }

        private void OnApplicationFocus(bool focused)
        {
            if (!focused)
            {
                RaiseSuspending();
            }
        }

        private void OnApplicationQuit()
        {
            RaiseSuspending();
        }

        private static void RaiseSuspending()
        {
            var handlers = ApplicationSuspending;
            if (handlers == null)
            {
                return;
            }

            var subscribers = handlers.GetInvocationList();
            for (int i = 0; i < subscribers.Length; i++)
            {
                try
                {
                    ((Action)subscribers[i])();
                }
                catch (Exception error)
                {
                    // One subscriber failing here must not stop the others: the next one along is
                    // the one that still has an unwritten cursor.
                    ImLog.Error("an ApplicationSuspending handler threw and was ignored", error);
                }
            }
        }

        private void OnDestroy()
        {
            if (ReferenceEquals(_instance, this))
            {
                _instance = null;
            }

            _core.Clear();
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        private static void ResetStatics()
        {
            // With domain reload disabled ("Enter Play Mode Options"), statics survive leaving play
            // mode and this field would point at a destroyed object on the next run.
            _instance = null;
        }
    }

    /// <summary>
    /// A dispatcher with a clock you turn by hand. Tests use it to make reconnect backoff and
    /// heartbeat cadence deterministic; a headless build (a dedicated server, a bot) can use it to
    /// run the SDK on its own loop with no Unity player loop at all.
    /// </summary>
    public sealed class ManualDispatcher : IImDispatcher
    {
        private readonly ImDispatcherCore _core = new ImDispatcherCore();
        private double _now;

        /// <summary>The virtual clock, in seconds since this dispatcher was created.</summary>
        public double Now
        {
            get { return _now; }
        }

        /// <summary>Actions queued and not yet run.</summary>
        public int PendingActions
        {
            get { return _core.PendingActions; }
        }

        /// <summary>Timers armed and not yet fired.</summary>
        public int PendingTimers
        {
            get { return _core.PendingTimers; }
        }

        /// <inheritdoc/>
        public void Post(Action action)
        {
            _core.Post(action);
        }

        /// <inheritdoc/>
        public IDisposable Schedule(TimeSpan delay, Action action)
        {
            return _core.Schedule(delay, action);
        }

        /// <summary>Runs everything queued, without moving the clock.</summary>
        public void Pump()
        {
            _core.Pump(_now);
        }

        /// <summary>
        /// Runs everything queued, repeatedly, until the queue stops growing. Callbacks here post
        /// further callbacks — a reply resolves a request, whose continuation sends the next one —
        /// so a single pump is rarely the whole story.
        /// </summary>
        public void PumpUntilIdle(int maxRounds = 64)
        {
            for (int i = 0; i < maxRounds; i++)
            {
                _core.Pump(_now);
                if (_core.PendingActions == 0)
                {
                    return;
                }
            }
        }

        /// <summary>Moves the virtual clock forward and runs whatever that made due.</summary>
        public void Advance(TimeSpan delta)
        {
            if (delta > TimeSpan.Zero)
            {
                _now += delta.TotalSeconds;
            }

            PumpUntilIdle();
        }

        /// <summary>Moves the virtual clock forward by seconds and runs whatever that made due.</summary>
        public void Advance(double seconds)
        {
            Advance(TimeSpan.FromSeconds(seconds));
        }
    }
}
