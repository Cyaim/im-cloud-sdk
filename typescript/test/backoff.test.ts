import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { BASE_DELAY_MS, MAX_DELAY_MS, fullJitterCeiling, fullJitterDelay } from '../src/backoff.js';

describe('full-jitter backoff', () => {
  it('draws uniformly from zero to the ceiling rather than clustering', () => {
    const attempt = 6;
    const ceiling = fullJitterCeiling(attempt);

    // A deterministic sequence, so a failure here is a real change in the policy and not a bad day
    // for the PRNG.
    let seed = 42;
    const random = () => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };

    const buckets = new Array<number>(10).fill(0);
    const draws = 5000;
    let total = 0;

    for (let i = 0; i < draws; i++) {
      const delay = fullJitterDelay(attempt, random);
      assert.ok(delay >= 0 && delay <= ceiling, `${delay} outside 0..${ceiling}`);
      total += delay;
      buckets[Math.min(9, Math.floor((delay / ceiling) * 10))]!++;
    }

    // Every decile populated and none dominant: that is what "uniform" has to mean. A fixed
    // backoff puts every draw in one bucket; a ±10% jitter puts them in two.
    for (const count of buckets) {
      assert.ok(count > 0, 'a decile of the interval was never drawn');
      assert.ok(count < draws / 5, 'draws clustered into one part of the interval');
    }

    // Mean of a uniform draw is half the ceiling.
    assert.ok(Math.abs(total / draws / ceiling - 0.5) < 0.05);
  });

  it('doubles the ceiling per attempt and then stops growing', () => {
    assert.equal(fullJitterCeiling(0), BASE_DELAY_MS);
    assert.equal(fullJitterCeiling(1), BASE_DELAY_MS * 2);
    assert.equal(fullJitterCeiling(2), BASE_DELAY_MS * 4);

    // Pinned, so a device offline for a week cannot run the exponent away.
    assert.equal(fullJitterCeiling(6), MAX_DELAY_MS);
    assert.equal(fullJitterCeiling(600), MAX_DELAY_MS);
  });

  it('matches the constants the other client SDKs use', () => {
    // A fleet of mixed clients only de-synchronises evenly if every SDK draws from the same
    // interval. These three numbers are duplicated in the Dart and Kotlin SDKs on purpose.
    assert.equal(BASE_DELAY_MS, 500);
    assert.equal(MAX_DELAY_MS, 30_000);
  });
});
