import Foundation
import Testing

@testable import CyaimIM

/// ``singleConversationId(_:_:)`` against the shared vectors in `single-chat-id-vectors.json` at the
/// root of the SDK repository — the same file the server's `SingleChatIdVectorTests`, the widget and
/// every other SDK read.
///
/// A single-chat id one side builds differently is not an error anywhere: it is a second
/// conversation, or one nobody can read. So the expected ids come from the file, written out from the
/// grammar, never from this implementation — implementations that only check each other agree
/// forever, including on the day they are all wrong.
///
/// Ids are compared code unit by code unit, not with `==`: Swift's `==` on `String` is canonical
/// equivalence, so it would call two differently encoded ids equal that the server, comparing
/// ordinally, holds apart.
///
/// 单聊 id 对着共享向量断言：一端拼得不一样不会报错，得到的是第二个会话或谁也读不了的会话。
/// 期望值来自那份文件，不来自被测实现。比较按 UTF-16 码元逐个比，不用 `==`（它按规范等价比）。
@Suite("Single-chat ids")
struct SingleChatIdTests {

    private struct VectorFile: Decodable {
        struct Build: Decodable {
            let a: String
            let b: String
            let id: String
            let note: String?
        }

        struct Parse: Decodable {
            let id: String
            let ok: Bool
            let a: String?
            let b: String?
        }

        let build: [Build]
        let parse: [Parse]
    }

    @Test("builds every build vector, whichever end comes first")
    func buildsEveryBuildVector() throws {
        let vectors = try Self.vectors()
        #expect(!vectors.build.isEmpty, "single-chat-id-vectors.json has no build vectors")

        for v in vectors.build {
            let forward = singleConversationId(v.a, v.b)
            let swapped = singleConversationId(v.b, v.a)
            #expect(Self.same(forward, v.id), "'\(v.a)' + '\(v.b)' built '\(forward)', expected '\(v.id)' (\(v.note ?? ""))")
            #expect(Self.same(swapped, v.id), "'\(v.b)' + '\(v.a)', ends swapped, built '\(swapped)', expected '\(v.id)'")
        }
    }

    @Test("rebuilds every id the file says parses from the pair it parses to")
    func rebuildsEveryParsedId() throws {
        let parsed = try Self.vectors().parse.filter(\.ok)
        #expect(!parsed.isEmpty, "single-chat-id-vectors.json has no parse vectors that parse")

        for v in parsed {
            let a = try #require(v.a, "parse vector '\(v.id)' is ok but names no pair")
            let b = try #require(v.b, "parse vector '\(v.id)' is ok but names no pair")
            let built = singleConversationId(a, b)
            #expect(Self.same(built, v.id), "built '\(built)', expected '\(v.id)'")
        }
    }

    @Test("never builds an id the file refuses")
    func neverBuildsARefusedId() throws {
        let vectors = try Self.vectors()
        let refused = vectors.parse.filter { !$0.ok }.map { Array($0.id.utf16) }
        #expect(!refused.isEmpty, "single-chat-id-vectors.json has no refused parse vectors")

        for v in vectors.build {
            let id = singleConversationId(v.a, v.b)
            #expect(!refused.contains(Array(id.utf16)), "'\(v.a)' + '\(v.b)' built '\(id)', which the file lists as malformed")
        }
    }

    @Test("still has the vectors this implementation is easiest to get wrong on")
    func namedVectorsStillPresent() throws {
        // Named rather than counted: a file trimmed to make a failure go away keeps a count plausible.
        // The last one is the reason this SDK compares `utf16` rather than using `String`'s `<`.
        // 点名而不是数数：为了让失败消失而删掉几条之后，数量照样说得过去。
        let built = try Self.vectors().build.map { Array($0.id.utf16) }
        for id in ["s_alice_bob", "s_u~1alice_u~1bob", "s_a~01_c", "s_user~11_user~110", "s_\u{1F600}_\u{FF21}"] {
            #expect(built.contains(Array(id.utf16)), "build vector '\(id)' is missing from single-chat-id-vectors.json")
        }
    }

    /// Not a shared vector, because only Swift can get it wrong: `replacing(_:with:)` and
    /// `replacingOccurrences(of:with:)` work on `Character`s, and a `~` or `_` that a combining mark
    /// follows is one `Character` with it. The escape is per code unit, as on the server.
    @Test("a ~ or _ that a combining mark follows is still escaped")
    func combiningMarkAfterAnEscapedCharacter() {
        let built = singleConversationId("a~\u{301}", "b_\u{301}")
        #expect(Self.same(built, "s_a~0\u{301}_b~1\u{301}"), "built '\(built)'")
    }

    private static func same(_ x: String, _ y: String) -> Bool {
        x.utf16.elementsEqual(y.utf16)
    }

    private static func vectors() throws -> VectorFile {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("single-chat-id-vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: candidate))
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
