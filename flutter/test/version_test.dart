// The version-drift guard: five manifests, five constants, one number.
//
// CONTRACT §9.1 makes the SDK version lockstep across all five platforms, because a version number
// that identifies a *contract* answers "which endpoints do you have" without anyone having to ask
// which platform the customer is on. Lockstep that nothing checks is a convention, and a convention
// survives exactly until the first release where only one platform changed.
//
// The same assertion exists in all five suites, and in all five it hangs off the command CI
// actually runs. The Kotlin guard this generalises was wired to Gradle's `check` while CI ran
// `test`, so it had never once executed — a guard the pipeline does not run is a comment.
//
// 五个平台的版本号必须一致（契约 §9.1）；这条断言挂在 test 上，而不是某个 CI 不会执行的任务上。

import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// Walks up from the working directory until the directory holding the inventory turns up.
///
/// `dart test` runs with the package root as the working directory, but a walk costs nothing and
/// means the guard does not silently stop working the day somebody runs it from elsewhere.
Directory sdkRoot() {
  Directory directory = Directory.current.absolute;

  for (int hop = 0; hop < 8; hop++) {
    if (File('${directory.path}/endpoint-inventory.json').existsSync()) return directory;
    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }

  throw StateError('could not locate sdk/endpoint-inventory.json from ${Directory.current.path}');
}

String read(String relative) => File('${sdkRoot().path}/$relative').readAsStringSync();

String capture(String text, RegExp pattern, String what) {
  final RegExpMatch? match = pattern.firstMatch(text);
  expect(match, isNotNull, reason: 'could not read $what');
  return match!.group(1)!;
}

/// Every place a package version is written down. Swift has no manifest field — SPM versions come
/// from git tags — so its constant is the source of truth there and is read from the source.
Map<String, String> declaredVersions() => <String, String>{
      'typescript/package.json':
          (jsonDecode(read('typescript/package.json')) as Map<String, dynamic>)['version'] as String,
      'unity/package.json':
          (jsonDecode(read('unity/package.json')) as Map<String, dynamic>)['version'] as String,
      'kotlin/build.gradle.kts': capture(
        read('kotlin/build.gradle.kts'),
        RegExp(r'^version\s*=\s*"([^"]+)"', multiLine: true),
        'the Gradle version',
      ),
      'flutter/pubspec.yaml': capture(
        read('flutter/pubspec.yaml'),
        RegExp(r'^version:\s*(\S+)', multiLine: true),
        'the pubspec version',
      ),
      'swift/Sources/CyaimIM/ImSdk.swift': capture(
        read('swift/Sources/CyaimIM/ImSdk.swift'),
        RegExp(r'packageVersion\s*=\s*"([^"]+)"'),
        "Swift's packageVersion",
      ),
    };

void main() {
  group('version drift', () {
    test('ImSdk.packageVersion equals pubspec.yaml', () {
      final String manifest = capture(
        read('flutter/pubspec.yaml'),
        RegExp(r'^version:\s*(\S+)', multiLine: true),
        'the pubspec version',
      );

      expect(
        ImSdk.packageVersion,
        manifest,
        reason: 'pub.dev publishes the manifest and the handshake sends the constant; '
            'a disagreement means a support ticket quotes a version that was never released',
      );
    });

    test('all five platforms ship one version (CONTRACT §9.1 lockstep)', () {
      final Map<String, String> declared = declaredVersions();

      expect(
        declared.values.toSet(),
        hasLength(1),
        reason: 'the five SDKs must ship one version number, found $declared',
      );
      expect(ImSdk.packageVersion, declared.values.first);
    });

    test('ImSdk.contractVersion equals endpoint-inventory.json', () {
      final Map<String, dynamic> inventory =
          jsonDecode(read('endpoint-inventory.json')) as Map<String, dynamic>;

      expect(
        ImSdk.contractVersion,
        inventory['contractVersion'],
        reason: 'the contract version is generated into the inventory; '
            'the constant follows it rather than leading it',
      );
    });
  });
}
