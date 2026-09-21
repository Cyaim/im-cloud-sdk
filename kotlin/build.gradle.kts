import org.gradle.api.publish.maven.tasks.PublishToMavenRepository
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.concurrent.Callable
import java.util.zip.ZipFile

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
//
// This pointed at `Cyaim/IM` until 2026-09-14. The SDKs moved out to their own public repository
// on 2026-08-31 and `Cyaim/IM` is private, so every link the POM published -- project url, scm,
// issue tracker, developer url -- was a 404 for the only people who would ever follow it: someone
// holding the jar and looking for the source. A dead url in a POM is not caught by any build:
// Central validates that the field is *present*, never that it resolves.
// POM 里的四条链接全指向拆仓前的私有仓，对外是 404——而 Central 只校验字段在不在，不校验能不能打开。
val PROJECT_URL = "https://github.com/Cyaim/im-cloud-sdk"

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

// The POM has declared Apache-2.0 since this file was written, and the jar still carried none of it:
// measured on 2026-09-14, the published jar held 406 entries and `licen|notice` matched zero of them.
// A POM is metadata a resolver reads; the licence question is asked by a human who unpacks the jar,
// and that person found no terms at all. CONTRACT.md §9.2 names exactly this as the one per-package
// check owed before the first Maven Central push.
//
// The text is the repository's own copy rather than a fifth duplicate that can drift away from it.
// `require` here and not a bare `from()`: Gradle skips a `from()` whose path does not exist without a
// word, so a moved LICENSE would take the licence back out of the jar and the build would stay green.
// Gradle 对不存在的 `from()` 路径是默不作声地跳过，所以这里必须显式断言。
val licenseFile: File = rootDir.parentFile.resolve("LICENSE")
require(licenseFile.isFile) {
    "Apache-2.0 text not found at $licenseFile -- the jar would be published without licence terms."
}

// All three jars we publish: the binary, the sources jar an IDE unpacks, and the javadoc jar.
listOf("jar", "sourcesJar", "javadocJar").forEach { jarTask ->
    tasks.named<Jar>(jarTask) {
        metaInf { from(licenseFile) }

        // The assertion opens the archive that was just written, because "is the file on disk?" is not
        // the question -- `dotnet pack` proves the same point on the other SDK by producing a
        // licence-less package from a directory that has a LICENSE in it. It hangs off the jar tasks
        // themselves and not off `check`, for the reason recorded below `checkVersionConstant`: a guard
        // the publish path does not run is a comment with a build file around it.
        val archive = archiveFile
        doLast {
            val jar = archive.get().asFile
            val entries = ZipFile(jar).use { zip -> zip.entries().asSequence().map { it.name }.toList() }
            check("META-INF/LICENSE" in entries) {
                "META-INF/LICENSE is missing from ${jar.name} (${entries.size} entries)."
            }
        }
    }
}

// The javadoc jar Central requires is, for a Kotlin project, an empty box: there is no Java to
// document, so `:javadoc` runs NO-SOURCE and `withJavadocJar()` archives nothing. Measured on
// 2026-09-14 before the licence went in: two entries, 25 bytes, one of them the directory. Central
// accepts a placeholder and asks in the same sentence that it "include a README.md file in the
// .jar that directs the user to where they can get further information" -- so it carries the one
// document that does. The real reference is the KDoc in the sources jar; the alternative is Dokka,
// a plugin this build has no other reason to resolve.
// javadoc jar 此前是 25 字节的空壳：Kotlin 没有 Java 源可供 javadoc 处理。
val readmeFile: File = rootDir.resolve("README.md")
require(readmeFile.isFile) {
    "README.md not found at $readmeFile -- the javadoc jar would ship empty."
}

tasks.named<Jar>("javadocJar") {
    from(readmeFile)

    val archive = archiveFile
    doLast {
        val jar = archive.get().asFile
        val entries = ZipFile(jar).use { zip -> zip.entries().asSequence().map { it.name }.toList() }
        check("README.md" in entries) {
            "README.md is missing from ${jar.name} (${entries.size} entries) -- the javadoc jar is " +
                "a placeholder, and a placeholder that points nowhere is worse than none."
        }
    }
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
    // Several tests judge this SDK against ../endpoint-inventory.json (RequestWireKindTest checks every
    // request field's JSON kind against the server types in it). It lives outside this project, so
    // without this line a regenerated inventory with unchanged sources is answered from the build
    // cache — the verdict for the old inventory, replayed. IM_ENDPOINT_INVENTORY points the tests at
    // another copy, and that copy is then the input.
    // 清单在本工程之外；不声明为输入，重新生成清单而源码未变时，build cache 会重放旧清单下的结论。
    inputs.files(
        providers.environmentVariable("IM_ENDPOINT_INVENTORY")
            .orElse(file("../endpoint-inventory.json").path),
    ).withPropertyName("endpointInventory").withPathSensitivity(PathSensitivity.NONE)
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
                        "cold-start repair, and typed coverage of contract tiers T0-T3.",
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
                    developerConnection.set("scm:git:ssh://git@github.com/Cyaim/im-cloud-sdk.git")
                    url.set(PROJECT_URL)
                }

                issueManagement {
                    system.set("GitHub")
                    url.set("$PROJECT_URL/issues")
                }
            }
        }
    }

    repositories {
        // Before this block existed there were none, and `publish` was a door with nothing behind it:
        // measured on 2026-09-14, `./gradlew publish --dry-run` printed one line -- `:publish SKIPPED`,
        // a lifecycle task with no dependencies -- and BUILD SUCCESSFUL, while `publishToMavenLocal
        // --dry-run` printed thirteen tasks. A release job calling it would have gone green forever
        // without one byte leaving the runner.
        // `publish` 以前是个空操作：没有任何仓库，它跑完就绿了，而什么都没上传。
        //
        // Maven Central has no official Gradle plugin (central.sonatype.org/publish/publish-portal-gradle).
        // For the built-in `maven-publish` the supported route is the Portal's OSSRH Staging API
        // compatibility service, and it is only half the job: the upload lands in a staging repository
        // that stays invisible in the Portal until the same IP calls
        // `POST https://ossrh-staging-api.central.sonatype.com/manual/upload/defaultRepository/com.cyaim`
        // at the end of the run. That call belongs to the release workflow; this block cannot make it,
        // and a green `publish` without it still publishes nothing.
        maven {
            name = "centralPortal"
            url = uri("https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/")
            credentials {
                // Central Portal *user tokens*. Not the account password, and not a legacy OSSRH token:
                // a namespace migrated to the Portal answers those with 401.
                username = providers.gradleProperty("centralPortalUsername")
                    .orElse(providers.environmentVariable("CENTRAL_PORTAL_USERNAME")).orNull
                password = providers.gradleProperty("centralPortalPassword")
                    .orElse(providers.environmentVariable("CENTRAL_PORTAL_PASSWORD")).orNull
            }
        }
    }
}

// An unsigned upload is not refused by the repository; it is accepted and then refused by Central at
// validation, after the release job has already reported success on the upload step. Fail here instead,
// before anything is transmitted, so "we forgot the key" is a build failure and not a support ticket.
val hasSigningKey: Boolean = findProperty("signingInMemoryKey") != null
tasks.withType<PublishToMavenRepository>().configureEach {
    doFirst {
        check(hasSigningKey) {
            "No signing key: set -PsigningInMemoryKey (ASCII-armoured private key) and " +
                "-PsigningInMemoryKeyPassword. Maven Central rejects an unsigned bundle at validation."
        }
    }
}

// Signing is required by Central and impossible in CI without a key, so it turns itself on only
// when one is present. `./gradlew build` on a laptop with no GPG key must still work, or the first
// thing every contributor does is delete this block.
signing {
    val signingKey: String? = findProperty("signingInMemoryKey") as String?
    val signingPassword: String? = findProperty("signingInMemoryKeyPassword") as String?
    // This read `isRequired = gradle.taskGraph.hasTask("publish")` and was a dead statement:
    // Kotlin evaluates the right-hand side eagerly, at configuration time, before the task graph
    // is populated, so it was `false` on every invocation -- measured 2026-09-14 by printing it,
    // `false` under `gradlew publish --dry-run` exactly as under `gradlew help`. A line that reads
    // as a guarantee and never provided one is worse than no line at all. Gradle unpacks a
    // `Callable` lazily (it does not unpack a bare Kotlin lambda), so this one is asked at
    // execution time, when there is a graph to ask. The predicate is "something is being uploaded
    // to a remote repository", not "the task is called publish": `publishToMavenLocal` needs no
    // signature, and Central needs one for every file it receives.
    // 原来那一行在配置期求值，任务图还不存在，因此恒为 false——它看着像保险，其实从未生效。
    setRequired(Callable { gradle.taskGraph.allTasks.any { task -> task is PublishToMavenRepository } })
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
