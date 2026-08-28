import Foundation
import Testing

@testable import CyaimIM

/// The wire is camelCase JSON from a server that ships more often than any app that talks to it.
/// A frame that fails to decode is a message the user never sees, so these tests are mostly about
/// what happens when the payload is not quite what this build expected.
@Suite("Wire protocol")
struct ProtocolTests {

    private static func decodeFrame(_ json: String) throws -> ImFrame {
        try JSONDecoder().decode(ImFrame.self, from: Data(json.utf8))
    }

    @Test("a reply decodes, including the nested business body")
    func decodesAReply() throws {
        let frame = try Self.decodeFrame("""
        {
          "id": "c1-abc",
          "target": "msg.send",
          "status": 0,
          "msg": null,
          "requestTime": 1767225600000,
          "completeTime": 1767225600042,
          "body": {
            "code": 0,
            "message": null,
            "traceId": "trace-1",
            "serverTime": 1767225600042,
            "data": { "messageId": 90071992547409931, "seq": 7, "conversationId": "s_alice_bob" }
          }
        }
        """)

        #expect(frame.id == "c1-abc")
        #expect(frame.target == "msg.send")
        #expect(frame.status == 0)
        #expect(frame.body?.code == .ok)
        #expect(frame.body?.traceId == "trace-1")

        let result: SendMessageResult = try frame.requireData()
        #expect(result.seq == 7)

        // 64-bit ids must not round-trip through a Double: above 2^53 that silently loses digits.
        #expect(result.messageId == 90_071_992_547_409_931)
    }

    @Test("an unknown field does not cost the frame")
    func toleratesUnknownFields() throws {
        let frame = try Self.decodeFrame("""
        {
          "id": "srv-9",
          "target": "evt.message",
          "status": 0,
          "somethingAddedNextQuarter": { "nested": true },
          "body": { "code": 0, "serverTime": 1, "data": { "conversationId": "c1", "seq": 3 } }
        }
        """)

        let message: ImMessage = try frame.requireData()
        #expect(message.conversationId == "c1")
        #expect(message.seq == 3)
    }

    @Test("a missing optional field does not cost the frame either")
    func toleratesMissingFields() throws {
        let frame = try Self.decodeFrame(#"{ "id": "srv-9", "target": "evt.typing" }"#)

        #expect(frame.status == 0)
        #expect(frame.msg == nil)
        #expect(frame.body == nil)
    }

    @Test("a message decodes from the fields the server always sends")
    func decodesAMinimalMessage() throws {
        let json = """
        { "conversationId": "s_alice_bob", "seq": 12, "messageId": 7, "senderId": "alice",
          "contentType": 1, "content": { "text": "hello" } }
        """

        let message = try JSONDecoder().decode(ImMessage.self, from: Data(json.utf8))

        #expect(message.seq == 12)
        #expect(message.text == "hello")
        #expect(message.contentType == .text)
        #expect(message.mentionedUserIds.isEmpty)
        #expect(message.reactions.isEmpty)
        #expect(!message.isRecalled)
    }

    @Test("an unrecognised enumerated value survives instead of throwing")
    func unknownEnumeratedValuesRoundTrip() throws {
        let json = """
        { "conversationId": "c1", "seq": 1, "contentType": 777, "senderPlatform": 42,
          "content": { "kind": "something-new" } }
        """

        let message = try JSONDecoder().decode(ImMessage.self, from: Data(json.utf8))

        #expect(message.contentType.rawValue == 777)
        #expect(message.senderPlatform.rawValue == 42)
        #expect(message.content["kind"]?.stringValue == "something-new")
    }

    @Test("a page with no items decodes as an empty page")
    func decodesAnEmptyPage() throws {
        let page = try JSONDecoder().decode(
            Page<ConversationView>.self,
            from: Data(#"{ "hasMore": false }"#.utf8)
        )

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(!page.hasMore)
    }

    @Test("a draft encodes its target as the field the server expects")
    func draftTargets() throws {
        func encode(_ draft: MessageDraft) throws -> JSONValue {
            let data = try JSONEncoder().encode(draft)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }

        let toUser = try encode(.text("hi", to: .user("bob")))
        #expect(toUser["receiverId"]?.stringValue == "bob")
        #expect(toUser["groupId"] == nil)
        #expect(toUser["conversationId"] == nil)

        let toGroup = try encode(.text("hi", to: .group("g-1")))
        #expect(toGroup["groupId"]?.stringValue == "g-1")

        let toConversation = try encode(.text("hi", to: .conversation("s_alice_bob")))
        #expect(toConversation["conversationId"]?.stringValue == "s_alice_bob")

        // Always present, always non-empty: this is the idempotency key.
        #expect(toUser["clientMsgId"]?.stringValue?.isEmpty == false)
        #expect((toUser["sendTime"]?.intValue ?? 0) > 0)

        // Absent rather than false, so a message never carries an @everyone flag it did not mean.
        #expect(toUser["mentionAll"] == nil)
    }

    @Test("a close reason is parsed into a kick, and only a kick")
    func parsesCloseReasons() {
        #expect(KickReason(closeReason: "im-kick:MultiLoginPolicy") == .multiLoginPolicy)
        #expect(KickReason(closeReason: "im-kick:TokenExpired") == .tokenExpired)
        #expect(KickReason(closeReason: "im-kick:SomethingNew")?.rawValue == "SomethingNew")

        // Everything that is not a deliberate eviction.
        #expect(KickReason(closeReason: nil) == nil)
        #expect(KickReason(closeReason: "") == nil)
        #expect(KickReason(closeReason: "im-kick:") == nil)
        #expect(KickReason(closeReason: "going away") == nil)
        #expect(KickReason(closeReason: "1006") == nil)
    }

    @Test("the terminal set is exactly the reasons that can never succeed again")
    func terminalReasons() {
        for reason in [KickReason.multiLoginPolicy, .tokenRevoked, .userBanned, .appDisabled, .adminKick] {
            #expect(reason.isTerminal, "\(reason) should stop the client")
        }

        // Recoverable: the host app can mint a new token.
        #expect(!KickReason.tokenExpired.isTerminal)

        // A deploy. The node is coming back, and this is the case full jitter exists for.
        #expect(!KickReason.serverShutdown.isTerminal)

        // Unknown to this build: reconnecting is the safe guess.
        #expect(!KickReason("InventedNextQuarter").isTerminal)
    }

    @Test("errors carry what a support ticket needs")
    func errorsAreDescriptive() {
        let error = ImError(code: .moderationRejected, message: "rejected", traceId: "t-9", target: "msg.send")

        #expect(error.code.rawValue == 1402)
        #expect(error.description.contains("1402"))
        #expect(error.description.contains("msg.send"))
        #expect(error.description.contains("t-9"))
        #expect(error.errorDescription == error.description)

        #expect(ImError(code: .timeout, message: "").isRetryable)
        #expect(ImError(code: .tokenExpired, message: "").isAuthFailure)
        #expect(!ImError(code: .forbidden, message: "").isRetryable)
    }

    @Test("both layers of the envelope are checked")
    func bothFailureLayersThrow() throws {
        // Transport said the endpoint does not exist.
        let missing = ImFrame(id: "1", target: "msg.nope", status: 2, msg: "endpoint not found")
        #expect(throws: ImError.self) { try missing.throwIfFailed() }

        // Transport succeeded; the endpoint refused.
        let refused = ImFrame(
            id: "2",
            target: "msg.send",
            status: 0,
            body: ImBody(code: .groupMuted, message: "group is muted", traceId: "t-2", serverTime: 1)
        )

        do {
            try refused.throwIfFailed()
            Issue.record("a non-zero business code must throw")
        } catch let error as ImError {
            #expect(error.code == .groupMuted)
            #expect(error.traceId == "t-2")
        }

        // And a clean frame throws nothing.
        let fine = ImFrame(id: "3", target: "conv.read", status: 0, body: ImBody(code: .ok, serverTime: 1))
        try fine.throwIfFailed()
    }

    @Test("JSON values keep integers exact")
    func jsonValueKeepsIntegersExact() throws {
        let value = JSONValue.object([
            "messageId": .int(9_007_199_254_740_993),
            "ratio": .double(0.25),
            "flag": .bool(true),
            "name": .string("alice"),
            "tags": .array([.string("a"), .string("b")]),
            "nothing": .null,
        ])

        let data = try JSONEncoder().encode(value)
        let round = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(round["messageId"]?.intValue == 9_007_199_254_740_993)
        #expect(round["ratio"]?.doubleValue == 0.25)
        #expect(round["flag"]?.boolValue == true)
        #expect(round["name"]?.stringValue == "alice")
        #expect(round["tags"]?[1]?.stringValue == "b")
        #expect(round["nothing"]?.isNull == true)
    }

    /// visionOS and tvOS report as iOS on purpose: an app shipped for all of them should not have
    /// its iPhone session evicted by its Vision Pro session under `OnePerPlatform`.
    @Test("platform reports the family the multi-login policy buckets by")
    func platformForThisBuild() {
        #if os(macOS)
        #expect(Platform.current == .macOS)
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        #expect(Platform.current == .iOS)
        #else
        #expect(Platform.current != .unknown)
        #endif
    }
}
