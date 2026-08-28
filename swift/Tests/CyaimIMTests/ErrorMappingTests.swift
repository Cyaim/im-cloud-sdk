import Foundation
import Testing

@testable import CyaimIM

/// Error mapping and classification, from `sdk/CONTRACT.md` §7.
///
/// Two layers arrive on every frame and they mean different things: `status` is the transport's
/// verdict — did the frame reach an endpoint at all — and `body.code` is the endpoint's. Collapsing
/// them loses the distinction a support engineer needs most, which is whether the call happened.
@Suite("Errors and classification")
struct ErrorMappingTests {

    @Test("no such target is 1008, not 1002")
    func statusTwoMapsToUnsupportedOperation() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            channel.replyUnroutable(to: request)
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            let _: EmptyBody = try await client.invoke("msg.pin", body: EmptyBody())
            Issue.record("an unroutable target should not have succeeded")
        } catch let error as ImError {
            // 1002 means "your group does not exist". 1008 means "this deployment does not have
            // this endpoint" — the exact signal an SDK newer than a private-deployment server
            // produces, and the one an integrator needs verbatim rather than paraphrased.
            #expect(error.code == .unsupportedOperation)
            #expect(error.code != .notFound)
            #expect(error.target == "msg.pin")
            #expect(!error.isRetryable)
        }

        await client.disconnect()
    }

    @Test("an endpoint that threw is 1000, with the transport's own message")
    func statusOneMapsToInternalError() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            channel.replyEndpointThrew(to: request, message: "NullReferenceException")
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            _ = try await client.conv.unreadTotal()
            Issue.record("a thrown endpoint should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("NullReferenceException"))
            #expect(error.target == "conv.unreadTotal")
            #expect(error.isRetryable)
        }

        await client.disconnect()
    }

    @Test("a business failure carries the trace id and the target onto the error")
    func businessCodeThrowsWithTraceId() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }
            channel.reply(to: request, code: .quotaExceeded, message: "monthly MAU exceeded", traceId: "trace-9")
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        do {
            _ = try await client.user.me()
            Issue.record("a quota failure should not have succeeded")
        } catch let error as ImError {
            // Both of these are what turn "sending fails sometimes" into one query on one node.
            #expect(error.traceId == "trace-9")
            #expect(error.target == "user.me")
            #expect(error.code == .quotaExceeded)
            #expect(!error.isRetryable, "billing never gets retried")
        }

        await client.disconnect()
    }

    @Test("isRetryable and requiresReauth match the table exactly")
    func retryClassificationMatchesTable() {
        let retryable: [ImErrorCode] = [.internalError, .rateLimited, .timeout, .serviceUnavailable]
        let reauth: [ImErrorCode] = [.unauthorized, .tokenExpired, .tokenInvalid]

        for code in retryable {
            #expect(ImError(code: code, message: "x").isRetryable, "\(code) must be retryable")
        }

        for code in reauth {
            #expect(ImError(code: code, message: "x").requiresReauth, "\(code) must require reauth")
            #expect(ImError(code: code, message: "x").isAuthFailure, "the legacy spelling must agree")
        }

        // Everything else is terminal: retrying produces the same answer, and an SDK that retried
        // 1003 on its own would hide rate limiting from the UI that has to explain it.
        let terminal: [ImErrorCode] = [
            .invalidArgument, .notFound, .conflict, .payloadTooLarge, .unsupportedOperation,
            .forbidden, .userBanned, .kickedByOtherDevice, .appDisabled, .quotaExceeded,
            .featureNotEnabled, .planExpired, .messageTooLong, .moderationRejected,
            .recallWindowExpired, .editWindowExpired, .groupFull, .notGroupMember, .fileTooLarge,
        ]

        for code in terminal {
            let error = ImError(code: code, message: "x")
            #expect(!error.isRetryable, "\(code) must not be retryable")
            #expect(!error.requiresReauth, "\(code) must not ask for a new token")
        }

        // 1005 is shared: to a caller deciding whether to retry, "the server is not there" and
        // "the pipe to it is not there" are the same answer.
        #expect(ImErrorCode.notConnected == ImErrorCode.serviceUnavailable)
    }

    @Test("a request made while offline rejects immediately rather than queueing")
    func offlineRequestRejectsImmediately() async throws {
        let gateway = MockGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        do {
            _ = try await client.conv.unreadTotal()
            Issue.record("a request without a socket should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .notConnected)
        }

        // Nothing was buffered for later: a chat client that queues a send across a five-minute
        // outage delivers it into a conversation that has moved on.
        #expect(gateway.openedChannels.isEmpty)
    }

    @Test("a socket that drops with requests in flight fails them 1004, not 1005")
    func socketLossFailsPendingWithTimeout() async throws {
        let gateway = MockGateway(responder: { request, channel in
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .seconds(5)))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let pending = Task { try await client.conv.unreadTotal() }
        _ = await waitUntil("the request on the wire") { !channel.requests(for: "conv.unreadTotal").isEmpty }

        channel.serverClose(code: 1006, reason: nil)

        do {
            _ = try await pending.value
            Issue.record("the pending request should not have succeeded")
        } catch let error as ImError {
            // 1005 would claim the call was never delivered, and the SDK does not know that — the
            // request may well have executed. 1004 is the honest answer, and it is the one that
            // makes a caller reach for clientMsgId idempotency instead of blindly resending.
            #expect(error.code == .timeout)
            #expect(error.target == "conv.unreadTotal")
        }

        await client.disconnect()
    }

    @Test("cancelling removes the pending entry rather than leaking it")
    func cancellationRemovesPendingEntry() async throws {
        let gateway = MockGateway(responder: { request, channel in
            // Housekeeping answered; everything else falls into a hole so the call stays pending.
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .seconds(30)))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let call = Task { try await client.conv.unreadTotal() }
        _ = await waitUntil("the request on the wire") { !channel.requests(for: "conv.unreadTotal").isEmpty }
        _ = await waitUntil("the pending entry") { await client.connection.pendingRequestCount == 1 }

        call.cancel()

        do {
            _ = try await call.value
            Issue.record("a cancelled call should not have produced a value")
        } catch is CancellationError {
            // Cancellation is not a server outcome, so it is not an ImError with a made-up code.
        }

        // A cancellation path that leaves the entry behind is a leak that grows for the life of the
        // connection.
        _ = await waitUntil("the pending map to empty") { await client.connection.pendingRequestCount == 0 }
        #expect(await client.connection.pendingRequestCount == 0)

        await client.disconnect()
    }

    @Test("1203 is reported every time and never latched locally")
    func featureNotEnabledIsNotLatched() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "msg.typing" {
                channel.reply(to: request, code: .featureNotEnabled, message: "typing indicator is disabled")
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        for _ in 0 ..< 2 {
            do {
                try await client.msg.typing(TypingRequest(conversationId: "c1"))
                Issue.record("a disabled feature should not have succeeded")
            } catch let error as ImError {
                #expect(error.code == .featureNotEnabled)
            }
        }

        // A tenant can flip the flag at runtime; a client that remembered "typing is off" would
        // stay broken until the app restarted.
        #expect(channel.requests(for: "msg.typing").count == 2)

        await client.disconnect()
    }

    @Test("1101 renews the token on the open socket and retries the call once")
    func tokenExpiredReauthsInPlace() async throws {
        let refreshed = Holder<Bool>()

        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.reauth":
                refreshed.set(true)
                channel.reply(to: request, data: .null)

            case "conv.unreadTotal":
                // Expired the first time, fine once the socket carries a fresh token.
                if channel.requests(for: "conn.reauth").isEmpty {
                    channel.reply(to: request, code: .tokenExpired, message: "token has expired")
                } else {
                    channel.reply(to: request, data: .int(7))
                }

            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            tokenProvider: { "token-2" }
        ))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // The caller never sees the expiry: a token that ages out mid-session costs one extra
        // round trip rather than a full reconnect, which on a flaky network is the whole point of
        // holding a long-lived socket.
        let total = try await client.conv.unreadTotal()
        #expect(total == 7)
        #expect(refreshed.take() == true)
        #expect(channel.requests(for: "conn.reauth").count == 1)
        #expect(channel.requests(for: "conn.reauth").first?["token"]?.stringValue == "token-2")
        #expect(channel.requests(for: "conv.unreadTotal").count == 2)

        // And the socket stayed up throughout.
        #expect(gateway.attempts == 1)

        await client.disconnect()
    }

    @Test("a reauth that fails leaves the original error untouched")
    func failedReauthSurfacesTheOriginalError() async throws {
        let gateway = MockGateway(responder: { request, channel in
            switch request.target {
            case "conn.reauth":
                channel.reply(to: request, code: .tokenInvalid, message: "that token is not valid either")
            case "conv.unreadTotal":
                channel.reply(to: request, code: .tokenExpired, message: "token has expired")
            default:
                _ = MockGateway.answerHousekeeping(request, channel)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, tokenProvider: { "token-2" }))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        do {
            _ = try await client.conv.unreadTotal()
            Issue.record("the call should not have succeeded")
        } catch let error as ImError {
            #expect(error.code == .tokenExpired)
            #expect(error.requiresReauth)
        }

        // Once, not in a loop.
        #expect(channel.requests(for: "conn.reauth").count == 1)
        #expect(channel.requests(for: "conv.unreadTotal").count == 1)

        await client.disconnect()
    }
}
