import Foundation
import Testing

@testable import CyaimIM

/// Every method on a namespace is an endpoint. Nothing else may live there.
///
/// `sdk/CONTRACT.md` §4.1–4.2: the typed surface is the endpoint list transliterated, so a reader
/// who knows an endpoint name knows the call, in every language, without a lookup table — and a
/// support engineer can grep a bug report for the target that failed. A convenience method with no
/// endpoint behind it breaks both halves of that.
///
/// This is here because it happened. `sdk/unity` grew an `ImMsgApi.SendTextAsync` for which
/// `msg.sendText` is not and never was an endpoint, and its own deprecation messages pointed at the
/// invented method, so the SDK was actively teaching the wrong shape. A per-target coverage test
/// cannot see that — a phantom that delegates to a real endpoint puts a legitimate target on the
/// wire — so the check has to be on the *name*.
///
/// **This one reads the source, where the other four use reflection.** Swift has no runtime
/// reflection over a type's methods: `Mirror` reports stored properties and nothing else, and
/// `NSObject`'s Objective-C introspection does not reach a `struct`. So the check parses
/// `Namespaces.swift` for its `public func` declarations. That is a weaker mechanism than the other
/// four have, and it is a real limitation rather than a preference — it holds only because that
/// file is one uniformly-formatted file, which the assertion on the namespace count below is there
/// to keep true.
///
/// Swift 没有针对方法的运行时反射，所以这一条是扫源码的；其余四端用的都是反射。
@Suite("The namespaced surface is endpoints only")
struct NamespacedSurfaceTests {

    /// Namespace type name to the target prefix it mirrors.
    private static let prefixes: [String: String] = [
        "ImConnNamespace": "conn",
        "ImMsgNamespace": "msg",
        "ImConvNamespace": "conv",
        "ImUserNamespace": "user",
        "ImFriendNamespace": "friend",
        "ImGroupNamespace": "group",
        "ImMediaNamespace": "media",
        "ImPushNamespace": "push",
        "ImModerationNamespace": "moderation",
    ]

    /// The push token cache is the only non-endpoint the contract puts on a namespace: §6.2
    /// requires re-registering on every connect, which needs somewhere to keep the token.
    /// `setToken` / `clearToken` is the pair, spelled that way in all five SDKs.
    private static let allowed: Set<String> = ["setToken", "clearToken"]

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

    /// Every target the generator found on the server, read out of the inventory rather than listed
    /// here — a list here would be the very thing that goes stale.
    private static func endpointTargets() throws -> Set<String> {
        let url = sdkRoot().appendingPathComponent("endpoint-inventory.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: "\"target\"\\s*:\\s*\"([^\"]+)\"")
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)

        var targets: Set<String> = []
        for match in expression.matches(in: text, range: range) {
            if let captured = Range(match.range(at: 1), in: text) {
                targets.insert(String(text[captured]))
            }
        }
        return targets
    }

    /// `[(namespace type name, method name)]`, in declaration order.
    private static func declaredMethods() throws -> [(type: String, method: String)] {
        let url = sdkRoot()
            .appendingPathComponent("swift")
            .appendingPathComponent("Sources")
            .appendingPathComponent("CyaimIM")
            .appendingPathComponent("Namespaces.swift")

        var current: String?
        var found: [(type: String, method: String)] = []

        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("public struct Im"), let name = line.dropFirst("public struct ".count).split(separator: ":").first {
                current = String(name).trimmingCharacters(in: .whitespaces)
                continue
            }

            // A top-level declaration ends the struct; nothing else starts at column zero here.
            if line.hasPrefix("}") {
                current = nil
                continue
            }

            guard
                let type = current,
                line.hasPrefix("    public func "),
                let signature = line.dropFirst("    public func ".count).split(separator: "(").first
            else { continue }

            found.append((type: type, method: String(signature)))
        }

        return found
    }

    @Test("the source scan actually found the namespaces it is meant to check")
    func scanIsNotVacuous() throws {
        let methods = try Self.declaredMethods()
        let seen = Set(methods.map { $0.type })

        #expect(
            seen == Set(Self.prefixes.keys),
            "the scan found \(seen.sorted()); if Namespaces.swift was split or reformatted this "
                + "check has quietly stopped covering part of the surface"
        )
        #expect(methods.count >= 40, "found only \(methods.count) methods, which cannot be right")
    }

    @Test("names no endpoint the server does not have")
    func everyNamespacedMethodIsAnEndpoint() throws {
        let endpoints = try Self.endpointTargets()
        #expect(!endpoints.isEmpty, "the inventory parsed to no targets at all")

        var strays: [String] = []

        for entry in try Self.declaredMethods() {
            guard let prefix = Self.prefixes[entry.type] else { continue }
            if Self.allowed.contains(entry.method) { continue }

            let target = "\(prefix).\(entry.method)"
            if !endpoints.contains(target) {
                strays.append("\(entry.type).\(entry.method) implies \(target)")
            }
        }

        #expect(
            strays.isEmpty,
            "these namespaced methods name endpoints the server does not have. Either the endpoint "
                + "exists and endpoint-inventory.json needs regenerating, or the method is an "
                + "invention and belongs on ImClient as a flat alias (CONTRACT §4.2): \(strays)"
        )
    }

    @Test("keeps sendText off the namespaced surface")
    func sendTextIsNotNamespaced() throws {
        // The specific regression, named, so the failure says what went wrong rather than making a
        // reader re-derive it from a list of strays. The flat `im.sendText` alias is where it
        // belongs and stays until 2.0.
        let namespaced = try Self.declaredMethods().filter { $0.type == "ImMsgNamespace" && $0.method == "sendText" }
        #expect(namespaced.isEmpty, "msg.sendText is not an endpoint")
    }
}
