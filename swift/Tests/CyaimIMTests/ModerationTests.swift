import Foundation
import Testing

@testable import CyaimIM

/// `moderation.report`, the other half of what `friend.block` is here for.
///
/// App Store review treats both as mandatory for an app carrying user-generated content: a way to
/// block an abusive user *and* a way to report objectionable content. An SDK that types one and not
/// the other still leaves the customer with nowhere to point the reviewer.
///
/// What these tests pin is the shape of the body rather than the round trip, because the whole
/// safety property of this endpoint lives in what the body does **not** contain. The reporter is
/// the socket; a field for it would let one account file in another's name.
///
/// 举报人是连接本身：这一组测的是请求体里没有什么，因为该端点的全部安全性就在这一点上。
@Suite("Reporting")
struct ModerationTests {

    private static func moderationGateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "moderation.report" {
                channel.reply(to: request, data: .object([
                    "reportId": .string("rp_2f8c1d4e"),
                    "createdAt": .int(1_700_000_000_000),
                ]))
            }
        })
    }

    @Test("the report names a target and never a reporter")
    func reportCarriesNoReporter() async throws {
        let gateway = Self.moderationGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let receipt = try await client.moderation.report(SubmitReportRequest(
            targetUserId: "mallory",
            conversationId: "s_alice_mallory",
            messageId: 350_598_345_233_801_216,
            category: ImReportCategory.harassment,
            note: "kept messaging after I asked them to stop"
        ))

        let report = try #require(channel.requests(for: "moderation.report").first)
        #expect(report["targetUserId"]?.stringValue == "mallory")
        #expect(report["conversationId"]?.stringValue == "s_alice_mallory")
        #expect(report["category"]?.stringValue == "harassment")
        #expect(report["note"]?.stringValue == "kept messaging after I asked them to stop")

        // The one that matters. A reporter field would be a way to get somebody banned in their own
        // name, and a way to poison the count a moderator decides on.
        #expect(report["reporterId"] == nil)
        #expect(report["userId"] == nil)
        #expect(report["appId"] == nil)

        #expect(receipt.reportId == "rp_2f8c1d4e")
        #expect(receipt.createdAt == 1_700_000_000_000)

        await client.disconnect()
    }

    @Test("the message id leaves as a quoted string")
    func messageIdIsWrittenAsAString() async throws {
        let gateway = Self.moderationGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // Snowflakes: epoch 2024-01-01 with the timestamp shifted 22 bits, so every id minted since
        // 2024-01-25 is past 2^53 — today by a factor of 38. The server writes them quoted for that
        // reason and reads them back the same way; an SDK that quoted ids everywhere except here
        // would be an SDK with an exception to remember.
        _ = try await client.moderation.report(SubmitReportRequest(
            targetUserId: "mallory",
            messageId: 350_598_345_233_801_216
        ))

        let report = try #require(channel.requests(for: "moderation.report").first)
        #expect(report["messageId"]?.stringValue == "350598345233801216")
        #expect(report["messageId"]?.intValue == nil, "a JSON number here is the bug this pins")

        // Unset optionals are still absent rather than null — the hand-written encoder keeps the
        // gateway's writing policy the synthesised one would have given it.
        #expect(report["conversationId"] == nil)
        #expect(report["category"] == nil)
        #expect(report["note"] == nil)

        await client.disconnect()
    }

    @Test("a report with no message id reports the account")
    func zeroMessageIdReportsTheAccount() async throws {
        let gateway = Self.moderationGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // "This person is a problem" is a different report from "this message is a problem", and
        // the endpoint takes both. The field is sent rather than omitted so that the two readings
        // of an absent id — account report, or a client that forgot the field — cannot be confused.
        _ = try await client.moderation.report(SubmitReportRequest(targetUserId: "mallory"))

        let report = try #require(channel.requests(for: "moderation.report").first)
        #expect(report["messageId"]?.stringValue == "0")

        await client.disconnect()
    }

    @Test("a refused report reaches the caller with its code")
    func refusedReportThrows() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "moderation.report" {
                channel.reply(
                    to: request,
                    code: .invalidArgument,
                    message: "a user cannot report themselves",
                    traceId: "trace-8802"
                )
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        // Unlike `push.clicked`, this one throws: the user pressed a button and is waiting to be
        // told their report was filed. Swallowing the refusal would show them a confirmation for a
        // report that does not exist.
        do {
            _ = try await client.moderation.report(SubmitReportRequest(targetUserId: "alice"))
            Issue.record("reporting yourself should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .invalidArgument)
            #expect(error.target == "moderation.report")
            #expect(error.traceId == "trace-8802")
            #expect(!error.isRetryable)
        }

        await client.disconnect()
    }
}
