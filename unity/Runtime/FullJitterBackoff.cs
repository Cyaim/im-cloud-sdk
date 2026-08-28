using System;

namespace Cyaim.Im
{
    /// <summary>How long to wait before reconnect attempt N.</summary>
    public interface IReconnectBackoff
    {
        /// <summary>
        /// Delay before attempt <paramref name="attempt"/>, which is 1 for the first retry after a
        /// drop and increments until a connection succeeds.
        /// </summary>
        TimeSpan NextDelay(int attempt);
    }

    /// <summary>
    /// Exponentially growing ceiling, uniformly random delay below it. The default, and the one
    /// worth understanding before replacing.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A gateway holds sockets, so it deploys rarely — but when it does, every socket on the node
    /// being replaced closes in the same millisecond. Ten thousand players on that node then
    /// reconnect together, at the service that has just finished starting up, and knock it over
    /// again. That is the failure this class exists to prevent.
    /// </para>
    /// <para>
    /// Full jitter means the delay is drawn uniformly from <c>[0, ceiling)</c>, where the ceiling
    /// doubles from 500 ms up to a 30 s cap. Only the ceiling is exponential; the delay itself is
    /// random across its whole range. A fixed backoff reconnects the entire fleet in one second. A
    /// "jittered" backoff of ±10% reconnects it in a 200 ms window instead of a 1 ms one, which for
    /// ten thousand clients is the same outage with extra steps. Drawing from the full range is
    /// what actually spreads the herd out, and it is why the first retry may come back in 40 ms or
    /// in 900 ms — that spread is the feature.
    /// </para>
    /// <para>
    /// 全抖动：延迟从 <c>[0, 上限)</c> 均匀取样，上限从 500ms 翻倍到 30s 封顶。
    /// 固定退避会让整个节点的客户端在同一秒回来；±10% 的抖动只是把 1ms 变成 200ms 的窗口。
    /// 只有在整个区间上取样才能真正打散重连洪峰。
    /// </para>
    /// </remarks>
    public sealed class FullJitterBackoff : IReconnectBackoff
    {
        /// <summary>Ceiling for the first retry, in milliseconds.</summary>
        public const int DefaultBaseDelayMs = 500;

        /// <summary>Largest ceiling, in milliseconds. Past this, waiting longer helps nobody.</summary>
        public const int DefaultMaxDelayMs = 30000;

        /// <summary>
        /// How many times the ceiling doubles before it stops. 500 ms doubled six times is 32 s,
        /// which the cap clips to 30 s — so attempt six and everything after it share a ceiling.
        /// </summary>
        public const int MaxDoublings = 6;

        private readonly int _baseDelayMs;
        private readonly int _maxDelayMs;
        private readonly Random _random;
        private readonly object _gate = new object();

        /// <summary>
        /// Creates the standard policy: a 500 ms ceiling doubling to 30 s, full jitter underneath.
        /// </summary>
        /// <param name="baseDelayMs">Ceiling for the first retry.</param>
        /// <param name="maxDelayMs">Largest ceiling.</param>
        /// <param name="random">
        /// Source of randomness. Leave it null for a per-instance <see cref="Random"/>. Note that
        /// <c>UnityEngine.Random</c> is deliberately not used: it is main-thread-only global state,
        /// and seeding it for a shader effect would change reconnect timing across the fleet.
        /// </param>
        public FullJitterBackoff(
            int baseDelayMs = DefaultBaseDelayMs,
            int maxDelayMs = DefaultMaxDelayMs,
            Random random = null)
        {
            if (baseDelayMs < 1)
            {
                throw new ArgumentOutOfRangeException("baseDelayMs", "base delay must be at least 1 ms");
            }

            if (maxDelayMs < baseDelayMs)
            {
                throw new ArgumentOutOfRangeException("maxDelayMs", "max delay must be at least the base delay");
            }

            _baseDelayMs = baseDelayMs;
            _maxDelayMs = maxDelayMs;

            // Seeding from the clock alone gives every client that started in the same tick the
            // same sequence — the exact correlation this class exists to destroy. Mixing in an
            // object identity separates two clients booted in the same millisecond.
            _random = random ?? new Random(Environment.TickCount ^ (Guid.NewGuid().GetHashCode() * 397));
        }

        /// <summary>The ceiling for a given attempt, in milliseconds. Exposed because it is the
        /// half of the policy worth asserting on.</summary>
        public int CeilingMsFor(int attempt)
        {
            if (attempt < 1)
            {
                attempt = 1;
            }

            int doublings = attempt < MaxDoublings ? attempt : MaxDoublings;
            long ceiling = (long)_baseDelayMs << doublings;
            return ceiling > _maxDelayMs ? _maxDelayMs : (int)ceiling;
        }

        /// <inheritdoc/>
        public TimeSpan NextDelay(int attempt)
        {
            int ceiling = CeilingMsFor(attempt);

            double sample;
            lock (_gate)
            {
                // System.Random is not thread-safe, and the socket thread is not always the one
                // asking. A lock around a single NextDouble costs nothing at this frequency.
                sample = _random.NextDouble();
            }

            return TimeSpan.FromMilliseconds(sample * ceiling);
        }
    }
}
