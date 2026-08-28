/**
 * The version-drift guard: five manifests, five constants, one number.
 *
 * CONTRACT §9.1 makes the SDK version lockstep across all five platforms, because a version number
 * that identifies a *contract* answers "which endpoints do you have" without anyone having to ask
 * which platform the customer is on. Lockstep that nothing checks is a convention, and a convention
 * survives exactly until the first release where only one platform changed.
 *
 * So this reads every version source in the repository — four manifests plus Swift's constant,
 * which SPM has no manifest field for — and fails if any two disagree. The same assertion exists in
 * all five suites (`sdk/kotlin` `VersionGuardTest`, `sdk/flutter` `version_test.dart`,
 * `sdk/swift` `VersionGuardTests`, `sdk/unity` `VersionGuardTests`), so a drift introduced on any
 * platform is caught by whichever suite runs first rather than by whichever registry publishes
 * first.
 *
 * **It hangs off `test`, not off a lint or a `check` task.** The Kotlin guard this generalises was
 * wired to `check` while CI ran `test`, so it had never once executed. A guard the pipeline does not
 * run is a comment.
 *
 * 五个平台的版本号必须一致（契约 §9.1）。这条断言挂在 test 上而不是 check 上：
 * 之前 Kotlin 那条挂在 check，而 CI 跑的是 test，于是它一次都没跑过。
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';

import { CONTRACT_VERSION, ImSdk, SDK_VERSION } from '../src/version.js';

/** Walks up from this compiled test file until the directory holding the inventory turns up. */
function sdkRoot(): string {
  let directory = dirname(fileURLToPath(import.meta.url));

  for (let hop = 0; hop < 8; hop++) {
    try {
      readFileSync(join(directory, 'endpoint-inventory.json'), 'utf8');
      return directory;
    } catch {
      directory = dirname(directory);
    }
  }

  throw new Error('could not locate sdk/endpoint-inventory.json from ' + import.meta.url);
}

const root = sdkRoot();
const read = (...parts: string[]): string => readFileSync(join(root, ...parts), 'utf8');

function capture(text: string, pattern: RegExp, what: string): string {
  const match = pattern.exec(text);
  assert.ok(match, `could not read ${what}`);
  return match[1]!;
}

/** Every place a package version is written down. Swift has no manifest field; SPM uses git tags. */
function declaredVersions(): Record<string, string> {
  return {
    'typescript/package.json': JSON.parse(read('typescript', 'package.json')).version,
    'unity/package.json': JSON.parse(read('unity', 'package.json')).version,
    'kotlin/build.gradle.kts': capture(
      read('kotlin', 'build.gradle.kts'),
      /^version\s*=\s*"([^"]+)"/m,
      'the Gradle version',
    ),
    'flutter/pubspec.yaml': capture(read('flutter', 'pubspec.yaml'), /^version:\s*(\S+)/m, 'the pubspec version'),
    'swift/Sources/CyaimIM/ImSdk.swift': capture(
      read('swift', 'Sources', 'CyaimIM', 'ImSdk.swift'),
      /packageVersion\s*=\s*"([^"]+)"/,
      "Swift's packageVersion",
    ),
  };
}

describe('version drift', () => {
  it('keeps ImSdk.packageVersion equal to package.json', () => {
    const manifest = JSON.parse(read('typescript', 'package.json'));
    assert.equal(
      ImSdk.packageVersion,
      manifest.version,
      'src/version.ts and package.json disagree; npm publishes the manifest and the handshake sends the constant',
    );
    assert.equal(SDK_VERSION, manifest.version);
  });

  it('keeps all five platforms on one version (CONTRACT §9.1 lockstep)', () => {
    const declared = declaredVersions();
    const distinct = [...new Set(Object.values(declared))];

    assert.equal(
      distinct.length,
      1,
      `the five SDKs must ship one version number, found ${JSON.stringify(declared, null, 2)}`,
    );
    assert.equal(ImSdk.packageVersion, distinct[0]);
  });

  it('keeps ImSdk.contractVersion equal to endpoint-inventory.json', () => {
    const inventory = JSON.parse(read('endpoint-inventory.json'));
    assert.equal(
      CONTRACT_VERSION,
      inventory.contractVersion,
      'the contract version is generated into the inventory; the constant must follow it, not lead it',
    );
    assert.equal(ImSdk.contractVersion, inventory.contractVersion);
  });

  it('still answers to the deprecated ImSdk.version alias', () => {
    // 0.9.0 is unpublished, but §4.2's rule is that a renamed public name keeps an alias until 2.0
    // and being consistent about that rule is half of what the rule is for.
    assert.equal(ImSdk.version, ImSdk.packageVersion);
  });
});
