import Foundation
import Testing

@testable import CyaimIM

/// The version-drift guard: five manifests, five constants, one number.
///
/// `sdk/CONTRACT.md` §9.1 makes the SDK version lockstep across all five platforms, because a
/// version number that identifies a *contract* answers "which endpoints do you have" without anyone
/// having to ask which platform the customer is on. Lockstep that nothing checks is a convention,
/// and a convention survives exactly until the first release where only one platform changed.
///
/// SPM has nowhere to write a version — a Swift package's version *is* its git tag — so this SDK is
/// the one with no manifest to compare against, and ``ImSdk/packageVersion`` is the source of truth
/// here. That makes the cross-platform half of this guard the only thing keeping this constant
/// honest, which is why it reads the other four manifests rather than only its own.
///
/// The identical assertion exists in the other four suites, and in all five it hangs off the command
/// CI actually runs. The Kotlin guard this generalises was wired to Gradle's `check` while CI ran
/// `test`, so from the day it was written it had never once executed.
///
/// 五个平台的版本号必须一致（契约 §9.1）；Swift 没有清单文件可写版本号，
/// 所以这条跨平台断言就是这个常量唯一的约束。
@Suite("Version drift")
struct VersionGuardTests {

    /// The repository is located from `#filePath`, not from the working directory: `swift test`
    /// runs from the package root, Xcode runs from somewhere else entirely, and neither is
    /// something this file can count on. The compiler bakes in the path of this source file, which
    /// is inside the repository by construction.
    private static func sdkRoot(from here: String = #filePath) -> URL {
        var directory = URL(fileURLWithPath: here).deletingLastPathComponent()

        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("endpoint-inventory.json").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }

        fatalError("could not locate sdk/endpoint-inventory.json from \(here)")
    }

    private static func read(_ relative: String) throws -> String {
        var url = sdkRoot()
        for component in relative.split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func capture(_ text: String, _ pattern: String, _ what: String) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)

        guard
            let match = expression.firstMatch(in: text, range: range),
            let captured = Range(match.range(at: 1), in: text)
        else {
            Issue.record("could not read \(what)")
            return ""
        }

        return String(text[captured])
    }

    /// Every place a package version is written down.
    private static func declaredVersions() throws -> [String: String] {
        [
            "typescript/package.json": try capture(
                read("typescript/package.json"), "\"version\"\\s*:\\s*\"([^\"]+)\"", "the npm version"
            ),
            "unity/package.json": try capture(
                read("unity/package.json"), "\"version\"\\s*:\\s*\"([^\"]+)\"", "the UPM version"
            ),
            "kotlin/build.gradle.kts": try capture(
                read("kotlin/build.gradle.kts"), "^version\\s*=\\s*\"([^\"]+)\"", "the Gradle version"
            ),
            "flutter/pubspec.yaml": try capture(
                read("flutter/pubspec.yaml"), "^version:\\s*(\\S+)", "the pubspec version"
            ),
            "swift/Sources/CyaimIM/ImSdk.swift": try capture(
                read("swift/Sources/CyaimIM/ImSdk.swift"),
                "packageVersion\\s*=\\s*\"([^\"]+)\"",
                "Swift's packageVersion"
            ),
        ]
    }

    @Test("all five platforms ship one version")
    func lockstep() throws {
        let declared = try Self.declaredVersions()
        let distinct = Set(declared.values)

        #expect(
            distinct.count == 1,
            "the five SDKs must ship one version number (CONTRACT §9.1), found \(declared)"
        )
        #expect(distinct.first == ImSdk.packageVersion)
    }

    @Test("the constant in this source is the one the lockstep check reads")
    func constantMatchesItsOwnSource() throws {
        // Belt and braces, and not redundant: `declaredVersions()` reads this constant out of the
        // file with a regex, so a change to how it is written — a computed property, a string
        // interpolation — would make that read silently wrong rather than fail.
        let fromSource = try Self.capture(
            Self.read("swift/Sources/CyaimIM/ImSdk.swift"),
            "packageVersion\\s*=\\s*\"([^\"]+)\"",
            "Swift's packageVersion"
        )

        #expect(fromSource == ImSdk.packageVersion)
    }

    @Test("ImSdk.contractVersion equals endpoint-inventory.json")
    func contractVersionFollowsTheInventory() throws {
        let inventory = try Self.capture(
            Self.read("endpoint-inventory.json"),
            "\"contractVersion\"\\s*:\\s*\"([^\"]+)\"",
            "the inventory's contractVersion"
        )

        #expect(
            ImSdk.contractVersion == inventory,
            "the contract version is generated into the inventory; the constant follows it"
        )
    }
}
