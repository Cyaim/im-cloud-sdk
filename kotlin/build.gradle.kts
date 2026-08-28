import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    `java-library`
    `maven-publish`
    signing
}

group = "com.cyaim.im"

// Central requires a project URL, an SCM block and an issue tracker, and rejects the bundle at
// validation if any is missing. One constant so they cannot disagree with each other.
val PROJECT_URL = "https://github.com/Cyaim/IM"

// SemVer 2.0.0, in lockstep with the other four SDKs: one number identifies a *contract*, so
// "we're on 0.9.0" answers "which endpoints do you have" without anyone having to ask which
// platform. 0.9.0 rather than 1.0.0 on purpose — 1.0.0 is reserved for T0+T1 complete on all five
// SDKs plus CONTRACT.md §5 and §6 implemented everywhere. Doing that before the first publication
// costs nothing; doing it after costs a major-version apology.
// Keep this equal to ImSdk.packageVersion; VersionGuardTest fails the suite when they drift.
version = "0.9.0"

// A plain JVM library, not an Android library. There is not one Android import in this SDK — the
// Android-specific parts (Doze, App Standby, foreground resume, FCM token delivery) are
// behavioural or documentation, not API — so the same artifact serves an Android app, a desktop
// client and a JVM service without a second build.
java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
    withSourcesJar()
    // Maven Central rejects a bundle without one. For a Kotlin project this jar is close to empty
    // — the real reference is the KDoc in the sources jar — but the requirement is the requirement,
    // and adding Dokka would pull a plugin into a build that currently resolves three dependencies.
    withJavadocJar()
}

kotlin {
    // Explicit API mode: every public declaration must state its visibility and return type.
    // This is a published SDK; accidentally leaking an internal type into the ABI is a breaking
    // change we would have to live with forever.
    explicitApi()

    compilerOptions {
        // 11, not 17: Android's D8 accepts class file version 55 everywhere AGP is supported,
        // and plenty of tenant apps still build against a JDK 11 toolchain.
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    // `api`, not `implementation`: Flow, Duration and JsonElement all appear in the public
    // signatures below, so consumers must compile against these anyway. Hiding them would only
    // produce "cannot access class" errors at the call site.
    api(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    api(libs.okhttp)

    testImplementation(kotlin("test"))
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.kotlinx.coroutines.test)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            artifactId = "im-client"
            from(components["java"])

            // Central's own checklist, in order: name, description, url, licence, developers, scm.
            // A POM missing any of them is rejected at validation, after the upload, which is a
            // slow way to find out.
            pom {
                name.set("Cyaim IM Client (Kotlin)")
                description.set(
                    "Kotlin/Android client SDK for Cyaim IM Cloud: multiplexed WebSocket, " +
                        "full-jitter reconnect, kick-aware close handling, durable two-cursor " +
                        "cold-start repair, and typed coverage of contract tiers T0-T2.",
                )
                url.set(PROJECT_URL)
                inceptionYear.set("2026")

                licenses {
                    license {
                        // Apache-2.0 rather than MIT for the express patent grant in §3: enterprise
                        // and integrator buyers run legal review, and MIT's silence on patents is a
                        // recurring redline. It also matches the transport submodule
                        // (external/Cyaim.WebSocketServer), so there is one licence to explain.
                        name.set("The Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                        distribution.set("repo")
                    }
                }

                developers {
                    developer {
                        id.set("cyaim")
                        name.set("Cyaim")
                        url.set(PROJECT_URL)
                    }
                }

                scm {
                    connection.set("scm:git:$PROJECT_URL.git")
                    developerConnection.set("scm:git:ssh://git@github.com/Cyaim/IM.git")
                    url.set(PROJECT_URL)
                }

                issueManagement {
                    system.set("GitHub")
                    url.set("$PROJECT_URL/issues")
                }
            }
        }
    }
}

// Signing is required by Central and impossible in CI without a key, so it turns itself on only
// when one is present. `./gradlew build` on a laptop with no GPG key must still work, or the first
// thing every contributor does is delete this block.
signing {
    val signingKey: String? = findProperty("signingInMemoryKey") as String?
    val signingPassword: String? = findProperty("signingInMemoryKeyPassword") as String?
    isRequired = gradle.taskGraph.hasTask("publish")
    if (signingKey != null) {
        useInMemoryPgpKeys(signingKey, signingPassword.orEmpty())
        sign(publishing.publications["maven"])
    }
}

/**
 * Fails the build if the version here and the constant the SDK reports have drifted.
 *
 * They travel to the gateway as the `cv` handshake parameter and into every support ticket, so a
 * mismatch is not cosmetic: it makes the one number a support engineer can rely on unreliable.
 */
val checkVersionConstant by tasks.registering {
    val source = layout.projectDirectory.file("src/main/kotlin/com/cyaim/im/client/ImSdk.kt")
    val declared = version.toString()
    inputs.file(source)
    inputs.property("version", declared)
    outputs.upToDateWhen { true }
    doLast {
        val text = source.asFile.readText()
        val match = Regex("""val packageVersion: String = "([^"]+)"""").find(text)
            ?: error("ImSdk.packageVersion not found in ${source.asFile}")
        val constant = match.groupValues[1]
        check(constant == declared) {
            "ImSdk.packageVersion is \"$constant\" but the Gradle version is \"$declared\". " +
                "They are published together and must match."
        }
    }
}

// `test`, not `check`. This guard hung off `check` while CI ran `./gradlew test`, so from the day
// it was written to the day the cross-SDK gate found it, it had never once executed. A guard the
// pipeline does not run is a comment with a build file around it. `check` still depends on it for
// a local `./gradlew check`, and `VersionGuardTest` carries the same assertion into the suite
// itself — plus the lockstep check across all five manifests, which a Gradle task cannot express
// without reaching outside this project.
// 这条守卫原本挂在 check 上，而 CI 跑的是 test，于是它一次都没执行过。
tasks.named("test") { dependsOn(checkVersionConstant) }
tasks.named("check") { dependsOn(checkVersionConstant) }
