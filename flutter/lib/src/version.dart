/// Version constants a support ticket needs, and the gateway is told about.
///
/// Two numbers, not one, because they answer different questions. [ImSdk.contractVersion] says
/// *which client contract* this build implements — the same number in all five SDKs, so "we are on
/// contract 1.0" answers "which endpoints do you have" without anyone asking which platform.
/// [ImSdk.packageVersion] says which pub.dev release this is, and is what goes on the wire as the
/// handshake's `cv` parameter.
///
/// 两个版本号回答两个不同的问题：契约版本五端一致，回答"你有哪些端点"；包版本回答"你是哪个发行版"。
library;

/// Identity of this SDK build.
abstract final class ImSdk {
  /// The client contract this build implements, from `sdk/endpoint-inventory.json`.
  ///
  /// Bumped in lockstep across all five SDKs by `sdk/CONTRACT.md` §11. It is deliberately not
  /// derived from [packageVersion]: a patch release changes the package version and not the
  /// contract, and conflating them is how a support engineer ends up comparing the wrong numbers.
  static const String contractVersion = '1.0';

  /// This package's own version. Keep in step with `pubspec.yaml` — the release checklist in
  /// `sdk/CONTRACT.md` §9.5 bumps both, and pub.dev will publish whatever the manifest says
  /// regardless of what this constant claims.
  static const String packageVersion = '0.9.0';
}
