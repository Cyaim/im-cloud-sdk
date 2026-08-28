import Foundation
import Testing

@testable import CyaimIM

/// The provided ``ImCursorStore`` implementations.
///
/// These are the pieces an integrator does not have to write, so they have to be right: a store
/// that loses a snapshot on a hard kill, or that hands one user another's cursors after an account
/// switch, reproduces the very bug §5 exists to close.
@Suite("Cursor stores")
struct CursorStoreTests {

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyaimIMTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("a file store round-trips a snapshot")
    func fileStoreRoundTrips() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImCursorStore.file(at: directory.appendingPathComponent("cursors.json"))

        // A path that does not exist yet is a fresh install, which is the one case where an empty
        // snapshot is the honest answer rather than a failure.
        #expect(try await store.load() == .empty)

        try await store.save(ImCursorSnapshot(
            convSeqs: ["c1": 41, "c2": 9_007_199_254_740_993],
            conversationCursor: 1_700_000_000_000
        ))

        let reloaded = try await ImCursorStore
            .file(at: directory.appendingPathComponent("cursors.json"))
            .load()

        #expect(reloaded.convSeqs["c1"] == 41)
        #expect(reloaded.convSeqs["c2"] == 9_007_199_254_740_993, "64-bit seqs must survive a round trip")
        #expect(reloaded.conversationCursor == 1_700_000_000_000)
    }

    @Test("a corrupt file is a failure, not an empty snapshot")
    func corruptFileThrows() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cursors.json")
        try Data("{ this is not json".utf8).write(to: url)

        // Reporting "empty" here would be indistinguishable from a fresh install, and the adoption
        // branch would then destroy history sitting intact in the app's own database.
        await #expect(throws: (any Error).self) {
            _ = try await ImCursorStore.file(at: url).load()
        }
    }

    @Test("only the SDK's own in-memory store counts as volatile")
    func onlyTheSdksOwnStoreIsVolatile() async throws {
        let store = ImCursorStore.inMemory()

        // Volatility is the SDK's judgement, not the store's claim. The public initialiser used to
        // take `isPersistent`, so any store — including one an integrator wrote over Core Data —
        // could announce itself volatile; and the only thing that answer drives is the one warning
        // standing between a misconfigured client and a ticket about missing history.
        #expect(store.isVolatile)
        #expect(ImCursorStore(load: { .empty }, save: { _ in }).isVolatile == false)

        try await store.save(ImCursorSnapshot(convSeqs: ["c1": 3]))
        #expect(try await store.load().convSeqs["c1"] == 3)

        // A second one shares nothing with the first: "in memory" means this process, this client.
        #expect(try await ImCursorStore.inMemory().load() == .empty)
    }

    @Test("a scope names a file per (host, appId, userId)")
    func scopeFileNames() {
        let endpoint = URL(string: "wss://im.example.com/gateway")!
        let alice = ImCursorScope(endpoint: endpoint, appId: "app-1", userId: "alice")
        let bob = ImCursorScope(endpoint: endpoint, appId: "app-1", userId: "bob")

        // Two accounts on one handset must not share a file. Without the user id, signing in as the
        // second one hands it the first one's cursors and every conversation looks already-read up
        // to somebody else's seq.
        #expect(alice.fileName != bob.fileName)
        #expect(alice.fileName.contains("alice"))
        #expect(alice.fileName.contains("im.example.com"))
        #expect(alice.fileName.contains("app-1"))

        // And the file name is safe to write even when the ids are not.
        let awkward = ImCursorScope(host: "im.example.com:8443", appId: "app/../..", userId: "a b?c")
        #expect(!awkward.fileName.contains("/"))
        #expect(!awkward.fileName.contains("?"))
        #expect(!awkward.fileName.contains(":"))
    }

    @Test("a snapshot decodes from a partial or unfamiliar file")
    func snapshotDecodingIsForgiving() throws {
        let onlyCursors = try JSONDecoder().decode(
            ImCursorSnapshot.self,
            from: Data(#"{"convSeqs":{"c1":7}}"#.utf8)
        )
        #expect(onlyCursors.convSeqs["c1"] == 7)
        #expect(onlyCursors.conversationCursor == 0)

        // A file written by a later SDK must not stop this one from starting.
        let withExtras = try JSONDecoder().decode(
            ImCursorSnapshot.self,
            from: Data(#"{"convSeqs":{},"conversationCursor":5,"somethingNew":true}"#.utf8)
        )
        #expect(withExtras.conversationCursor == 5)
    }

    @Test("a client writes through to its store as the application commits")
    func clientWritesThroughToTheStore() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("cursors.json")
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway, cursorStore: .file(at: url)))

        try await client.connect()
        await client.commit("c1", seq: 17)
        await client.enterBackground()

        // The suspend signal is one of the three mandatory flush points; the other two are before
        // `conn.sync` and the debounce deadline.
        let reloaded = try await ImCursorStore.file(at: url).load()
        #expect(reloaded.convSeqs["c1"] == 17)

        await client.disconnect()
    }
}
