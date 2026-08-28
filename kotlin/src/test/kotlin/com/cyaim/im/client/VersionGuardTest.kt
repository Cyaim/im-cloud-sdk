package com.cyaim.im.client

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The version-drift guard: five manifests, five constants, one number.
 *
 * CONTRACT.md §9.1 makes the SDK version lockstep across all five platforms, because a version
 * number that identifies a *contract* answers "which endpoints do you have" without anyone having
 * to ask which platform the customer is on. Lockstep that nothing checks is a convention, and a
 * convention survives exactly until the first release where only one platform changed.
 *
 * **This lives in `test`, not in a Gradle task hanging off `check`.** The `checkVersionConstant`
 * task that came before it was wired to `check` while CI ran `./gradlew test`, so from the day it
 * was written to the day the cross-SDK gate found it, it had never once executed. That task still
 * exists and now also runs on `test`; this class carries the same assertion into the suite, plus
 * the cross-platform half a Gradle task cannot express without reaching outside this project.
 *
 * The identical assertion exists in the other four suites (`sdk/typescript` `version.test.ts`,
 * `sdk/flutter` `version_test.dart`, `sdk/swift` `VersionGuardTests`, `sdk/unity`
 * `VersionGuardTests`), so a drift introduced on any platform is caught by whichever suite runs
 * first rather than by whichever registry publishes first.
 *
 * 五个平台的版本号必须一致（契约 §9.1）。这条断言挂在 test 上：
 * 之前那条挂在 check，而 CI 跑的是 test，于是它一次都没跑过。
 */
class VersionGuardTest {

    /**
     * Gradle runs tests with the project directory as the working directory, but the walk costs
     * nothing and means the guard does not silently stop working the day somebody runs it from
     * elsewhere.
     */
    private fun sdkRoot(): File {
        var directory: File? = File(".").absoluteFile

        repeat(8) {
            val candidate = directory ?: return@repeat
            if (File(candidate, "endpoint-inventory.json").isFile) return candidate
            directory = candidate.parentFile
        }

        error("could not locate sdk/endpoint-inventory.json from ${File(".").absolutePath}")
    }

    private fun read(relative: String): String = File(sdkRoot(), relative).readText()

    private fun capture(text: String, pattern: Regex, what: String): String {
        val match = pattern.find(text) ?: error("could not read $what")
        return match.groupValues[1]
    }

    /**
     * Every place a package version is written down. Swift has no manifest field — SPM takes its
     * version from a git tag — so its constant is the source of truth there and is read from source.
     *
     * The JSON and YAML are read with regexes rather than a parser on purpose: this artifact is a
     * plain `java-library` with no test-time JSON dependency, and adding one so a guard can read
     * four numbers would be a worse trade than four regexes with named failure messages.
     */
    private fun declaredVersions(): Map<String, String> = mapOf(
        "typescript/package.json" to capture(
            read("typescript/package.json"),
            Regex(""""version"\s*:\s*"([^"]+)""""),
            "the npm version",
        ),
        "unity/package.json" to capture(
            read("unity/package.json"),
            Regex(""""version"\s*:\s*"([^"]+)""""),
            "the UPM version",
        ),
        "kotlin/build.gradle.kts" to capture(
            read("kotlin/build.gradle.kts"),
            Regex("""^version\s*=\s*"([^"]+)"""", RegexOption.MULTILINE),
            "the Gradle version",
        ),
        "flutter/pubspec.yaml" to capture(
            read("flutter/pubspec.yaml"),
            Regex("""^version:\s*(\S+)""", RegexOption.MULTILINE),
            "the pubspec version",
        ),
        "swift/Sources/CyaimIM/ImSdk.swift" to capture(
            read("swift/Sources/CyaimIM/ImSdk.swift"),
            Regex("""packageVersion\s*=\s*"([^"]+)""""),
            "Swift's packageVersion",
        ),
    )

    @Test
    fun `ImSdk packageVersion equals the Gradle version`() {
        val gradle = capture(
            read("kotlin/build.gradle.kts"),
            Regex("""^version\s*=\s*"([^"]+)"""", RegexOption.MULTILINE),
            "the Gradle version",
        )

        assertEquals(
            gradle,
            ImSdk.packageVersion,
            "Maven Central publishes the Gradle version and the handshake sends the constant; " +
                "a disagreement means a support ticket quotes a version that was never released",
        )
    }

    @Test
    fun `all five platforms ship one version`() {
        val declared = declaredVersions()
        val distinct = declared.values.toSet()

        assertEquals(
            1,
            distinct.size,
            "the five SDKs must ship one version number (CONTRACT.md §9.1), found $declared",
        )
        assertEquals(distinct.single(), ImSdk.packageVersion)
    }

    @Test
    fun `ImSdk contractVersion equals endpoint-inventory json`() {
        val inventory = capture(
            read("endpoint-inventory.json"),
            Regex(""""contractVersion"\s*:\s*"([^"]+)""""),
            "the inventory's contractVersion",
        )

        assertEquals(
            inventory,
            ImSdk.contractVersion,
            "the contract version is generated into the inventory; the constant follows it",
        )
    }

    @Test
    fun `the deprecated version alias still answers`() {
        // 0.9.0 is unpublished, but §4.2's rule is that a renamed public name keeps an alias until
        // 2.0, and being consistent about that rule is half of what the rule is for.
        @Suppress("DEPRECATION")
        assertTrue(ImSdk.version == ImSdk.packageVersion)
    }
}
