package com.cyaim.im.client

/**
 * What this artifact is, so a support ticket carries it without anyone having to ask.
 *
 * [version] is this package's own version and travels to the gateway as the `cv` handshake
 * parameter. [contractVersion] is the version of `sdk/CONTRACT.md` it implements, and it is the
 * number that actually answers "which endpoints do you have": all five SDKs move in lockstep, so
 * one number identifies a contract rather than a platform.
 */
public object ImSdk {

    /**
     * Semantic version of `com.cyaim.im:im-client`. Keep it equal to `build.gradle.kts` —
     * `VersionGuardTest` fails the suite when they drift, and the same test exists in all five SDKs.
     *
     * Spelled `packageVersion` because that is what the other four call it. It was `version` here
     * and in Swift, `packageVersion` in Dart and `PackageVersion` in C#: three names for one
     * number, which turns "quote your SDK version" into a per-platform lookup at exactly the moment
     * nobody has time for one.
     */
    public const val packageVersion: String = "0.9.0"

    @Deprecated(
        "Renamed to packageVersion, the name the other four SDKs use. Removed in 2.0.",
        ReplaceWith("ImSdk.packageVersion"),
    )
    public const val version: String = "0.9.0"

    /** From `sdk/endpoint-inventory.json`'s `contractVersion`. */
    public const val contractVersion: String = "1.0"

    /**
     * Tiers of `sdk/CONTRACT.md` §3 this build types in full.
     *
     * Published because a customer choosing a platform on a feature matrix should be able to read
     * the matrix off the artifact instead of a README that may be a release behind.
     */
    public val tiers: List<String> = listOf("T0", "T1", "T2")
}
