using System;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The reconnect policy, tested as a distribution rather than as a value.
    /// </summary>
    /// <remarks>
    /// A test that asserts "the delay is about 500 ms" passes for a fixed backoff, for a ±10%
    /// jittered one, and for full jitter — and only one of those three keeps a gateway alive when a
    /// node's worth of players reconnect at once. So the assertions here are about spread: the
    /// samples have to cover the whole range below the ceiling, and two clients that started in the
    /// same instant have to disagree.
    /// </remarks>
    public sealed class FullJitterBackoffTests
    {
        private const int Samples = 20000;

        [Test]
        public void Ceiling_doubles_from_the_base_and_caps_at_thirty_seconds()
        {
            var backoff = new FullJitterBackoff();

            Assert.That(backoff.CeilingMsFor(1), Is.EqualTo(1000));
            Assert.That(backoff.CeilingMsFor(2), Is.EqualTo(2000));
            Assert.That(backoff.CeilingMsFor(3), Is.EqualTo(4000));
            Assert.That(backoff.CeilingMsFor(4), Is.EqualTo(8000));
            Assert.That(backoff.CeilingMsFor(5), Is.EqualTo(16000));

            // 500 << 6 is 32 s, clipped to the 30 s cap, and every later attempt shares it. Waiting
            // longer than half a minute does not help a service that is already back.
            Assert.That(backoff.CeilingMsFor(6), Is.EqualTo(30000));
            Assert.That(backoff.CeilingMsFor(7), Is.EqualTo(30000));
            Assert.That(backoff.CeilingMsFor(50), Is.EqualTo(30000));
        }

        [Test]
        public void Every_delay_lands_inside_its_ceiling()
        {
            var backoff = new FullJitterBackoff(500, 30000, new Random(20260819));

            for (int attempt = 1; attempt <= 8; attempt++)
            {
                var ceiling = backoff.CeilingMsFor(attempt);
                for (int i = 0; i < 2000; i++)
                {
                    var delay = backoff.NextDelay(attempt).TotalMilliseconds;
                    Assert.That(delay, Is.GreaterThanOrEqualTo(0.0));
                    Assert.That(delay, Is.LessThanOrEqualTo(ceiling));
                }
            }
        }

        /// <summary>
        /// The test that a narrow jitter fails. Ten thousand sockets dropped in the same millisecond
        /// have to come back spread over the whole window, not clustered at one point in it.
        /// </summary>
        [Test]
        public void Delays_cover_the_whole_range_below_the_ceiling()
        {
            var backoff = new FullJitterBackoff(500, 30000, new Random(7));
            const int attempt = 4;
            var ceiling = backoff.CeilingMsFor(attempt);

            var buckets = new int[10];
            for (int i = 0; i < Samples; i++)
            {
                var delay = backoff.NextDelay(attempt).TotalMilliseconds;
                var bucket = (int)(delay / ceiling * buckets.Length);
                if (bucket >= buckets.Length)
                {
                    bucket = buckets.Length - 1;
                }

                buckets[bucket]++;
            }

            var expected = Samples / buckets.Length;
            for (int i = 0; i < buckets.Length; i++)
            {
                // Uniform to within 20%: every decile of [0, ceiling) carries roughly the same share
                // of the fleet. A delay of ceiling±10% would leave eight of these ten empty.
                Assert.That(
                    buckets[i],
                    Is.EqualTo(expected).Within(expected * 0.2),
                    "decile " + i + " of the reconnect window is not being used");
            }
        }

        [Test]
        public void Mean_delay_is_half_the_ceiling()
        {
            var backoff = new FullJitterBackoff(500, 30000, new Random(99));
            const int attempt = 3;
            var ceiling = backoff.CeilingMsFor(attempt);

            double total = 0;
            for (int i = 0; i < Samples; i++)
            {
                total += backoff.NextDelay(attempt).TotalMilliseconds;
            }

            // Half the ceiling, which is also why full jitter reconnects a fleet sooner on average
            // than the fixed backoff people reach for instead.
            Assert.That(total / Samples, Is.EqualTo(ceiling / 2.0).Within(ceiling * 0.02));
        }

        [Test]
        public void Two_clients_created_in_the_same_instant_do_not_agree()
        {
            // The failure this class exists to prevent: a whole gateway node's worth of players
            // launching, dropping and retrying in lockstep because their randomness was seeded from
            // a clock that read the same for all of them.
            var first = new FullJitterBackoff();
            var second = new FullJitterBackoff();

            var agreements = 0;
            for (int i = 0; i < 64; i++)
            {
                if (first.NextDelay(4) == second.NextDelay(4))
                {
                    agreements++;
                }
            }

            Assert.That(agreements, Is.LessThan(2));
        }

        [Test]
        public void Attempt_zero_is_treated_as_the_first_retry()
        {
            var backoff = new FullJitterBackoff();

            Assert.That(backoff.CeilingMsFor(0), Is.EqualTo(backoff.CeilingMsFor(1)));
            Assert.That(backoff.CeilingMsFor(-5), Is.EqualTo(backoff.CeilingMsFor(1)));
        }

        [Test]
        public void A_custom_base_and_cap_are_honoured()
        {
            var backoff = new FullJitterBackoff(100, 800, new Random(1));

            Assert.That(backoff.CeilingMsFor(1), Is.EqualTo(200));
            Assert.That(backoff.CeilingMsFor(4), Is.EqualTo(800));
            Assert.That(backoff.CeilingMsFor(9), Is.EqualTo(800));
        }

        [Test]
        public void Nonsense_bounds_are_rejected_at_construction()
        {
            Assert.Throws<ArgumentOutOfRangeException>(delegate { new FullJitterBackoff(0); });
            Assert.Throws<ArgumentOutOfRangeException>(delegate { new FullJitterBackoff(5000, 1000); });
        }
    }
}
