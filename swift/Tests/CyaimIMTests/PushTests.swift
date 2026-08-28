import Foundation
import Testing

@testable import CyaimIM

/// Offline push registration, from `sdk/CONTRACT.md` §6.
///
/// The server side of this shipped and no SDK called it, which meant offline push — the feature
/// every mobile deal turns on — was unreachable from any official client. These tests are about the
/// three timing rules that make registration actually work, because a token registered once at
/// install and never again is a token that is wrong by the time it matters.
///
/// 服务端早就有了，五个 SDK 谁都没调用——离线推送从官方客户端根本到不了。
@Suite("Push registration")
struct PushTests {

    /// Answers `push.*` as well as the housekeeping pair.
    private static func pushGateway() -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target.hasPrefix("push.") {
                channel.reply(to: request, data: .null)
            }
        })
    }

    @Test("every connect re-registers the token, not just the first one")
    func registersOnEveryConnect() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        await client.push.setToken(token: "apns-token-1")
        try await client.connect()

        _ = await waitUntil("the first registration") {
            gateway.openedChannels.first?.requests(for: "push.register").count == 1
        }

        // A vendor may replace a token while the process is frozen, and the server has no other way
        // to learn it. Re-registering an unchanged token costs no write server-side, so the only
        // safe cadence is "every connect".
        for _ in 0 ..< 2 {
            let before = gateway.openedChannels.count
            let live = try #require(gateway.lastChannel)
            live.serverClose(code: 1006, reason: nil)

            // Counting opened channels rather than handshake attempts: the attempt is recorded
            // before the channel exists, so waiting on it would hand the next iteration the socket
            // that has just been closed.
            _ = await waitUntil("another socket") { gateway.openedChannels.count > before }
            _ = await waitUntil("its registration") {
                gateway.openedChannels.last?.requests(for: "push.register").isEmpty == false
            }
        }

        _ = await waitUntil("three registrations in total") {
            gateway.openedChannels.reduce(0) { $0 + $1.requests(for: "push.register").count } == 3
        }

        let registrations = gateway.openedChannels.flatMap { $0.requests(for: "push.register") }
        #expect(registrations.count == 3)
        #expect(registrations.allSatisfy { $0["token"]?.stringValue == "apns-token-1" })
        #expect(registrations.allSatisfy { $0["provider"]?.stringValue == "apns" })

        // Identity comes from the socket. A body that carried a user or device id would be a field
        // for something the server ignores.
        #expect(registrations.allSatisfy { $0["userId"] == nil && $0["deviceId"] == nil })

        // And the socket's language is the default, so a client that never sets one still gets
        // notifications in the language it connected with.
        #expect(registrations.allSatisfy { $0["language"]?.stringValue == "en-US" })

        await client.disconnect()
    }

    @Test("logout unregisters before the socket closes")
    func unregisterPrecedesDisconnect() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        await client.push.setToken(token: "apns-token-1")
        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the registration") { !channel.requests(for: "push.register").isEmpty }

        await client.logout()

        // After the socket closes there is no authenticated channel left to remove the token with,
        // and only the tenant backend can then clean up. So the order is the whole rule.
        let log = channel.wireLog
        let unregister = try #require(log.firstIndex(of: "send:push.unregister"))
        let close = try #require(log.firstIndex { $0.hasPrefix("close:") })
        #expect(unregister < close)

        #expect(await client.isPushRegistered == false)
    }

    @Test("disconnect on its own never unregisters")
    func disconnectDoesNotUnregister() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        await client.push.setToken(token: "apns-token-1")
        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the registration") { !channel.requests(for: "push.register").isEmpty }

        await client.disconnect()
        await settle()

        // A dead socket is precisely the state offline push exists to serve. A teardown path that
        // dropped the token would switch notifications off exactly when they start mattering.
        #expect(channel.requests(for: "push.unregister").isEmpty)
    }

    @Test("a token that arrives while offline is registered on the next connect")
    func tokenRefreshWhileOfflineRegistersOnNextConnect() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        // No socket yet: nothing to send it on, and requests are never queued.
        await client.push.setToken(token: "apns-token-refreshed")
        #expect(gateway.attempts == 0)

        try await client.connect()
        let channel = try #require(gateway.lastChannel)
        _ = await waitUntil("the deferred registration") { !channel.requests(for: "push.register").isEmpty }

        let registration = try #require(channel.requests(for: "push.register").first)
        #expect(registration["token"]?.stringValue == "apns-token-refreshed")

        _ = await waitUntil("the reply to land") { await client.isPushRegistered }
        #expect(await client.isPushRegistered)

        await client.disconnect()
    }

    @Test("a refresh while connected goes out immediately")
    func tokenRefreshWhileConnectedRegistersAtOnce() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        await client.push.setToken(token: "apns-token-A")
        _ = await waitUntil("the first token") { channel.requests(for: "push.register").count == 1 }

        await client.push.setToken(token: "apns-token-B")
        _ = await waitUntil("the replacement") { channel.requests(for: "push.register").count == 2 }

        #expect(channel.requests(for: "push.register").map { $0["token"]?.stringValue } == ["apns-token-A", "apns-token-B"])

        // Setting the same token again is not a refresh and must not cost a round trip.
        await client.push.setToken(token: "apns-token-B")
        await settle()
        #expect(channel.requests(for: "push.register").count == 2)

        await client.disconnect()
    }

    @Test("an APNs device token is hex-encoded the way the server expects")
    func deviceTokenDataIsHexEncoded() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        await client.push.setToken(deviceToken: Data([0x00, 0x0f, 0xa0, 0xff]))
        _ = await waitUntil("the registration") { !channel.requests(for: "push.register").isEmpty }

        let registration = try #require(channel.requests(for: "push.register").first)
        #expect(registration["token"]?.stringValue == "000fa0ff")

        await client.disconnect()
    }

    @Test("a registration that fails says so, once, instead of failing silently")
    func failedRegistrationIsSurfaced() async throws {
        let warnings = WarningLog()

        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "push.register" {
                channel.reply(to: request, code: .featureNotEnabled, message: "offline push is disabled")
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway, warningHandler: warnings.handler))
        let events = Collector(client.sessionEvents())

        try await client.connect()
        await client.push.setToken(token: "apns-token-1")

        _ = await waitUntil("the warning") {
            events.items.contains { if case .pushTokenNotRegistered = $0 { return true }; return false }
        }

        // A device holding a token it never registered is indistinguishable from a broken push
        // provider, and that misdiagnosis costs a support cycle every time.
        #expect(warnings.contains("§6"))
        #expect(await client.isPushRegistered == false)

        await client.disconnect()
    }

    @Test("a notification tap reports what the payload gave it, and no identity")
    func clickedCarriesTheTapAndNothingElse() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.push.clicked(PushClickedRequest(messageId: "350598345233801216"))

        let click = try #require(channel.requests(for: "push.clicked").first)

        // The id is past 2^53 and stays a string the whole way out. Handed back as a number it
        // would arrive as a *different* id, and the delivery row this tap belongs to would never
        // be found — which is the same failure that made recall miss.
        #expect(click["messageId"]?.stringValue == "350598345233801216")
        #expect(click["pushId"] == nil, "an unset optional is absent, not null")

        // The row is located from the socket. A body carrying a user or device id would be a field
        // for something the server ignores, and a way to mark somebody else's notification clicked.
        #expect(click["userId"] == nil && click["deviceId"] == nil)

        await client.disconnect()
    }

    @Test("a tap that matches no delivery row is not the app's problem")
    func clickedSwallowsItsFailure() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if request.target == "push.clicked" {
                channel.reply(
                    to: request,
                    code: ImErrorCode.pushDeliveryNotFound,
                    message: "no delivery record matches this device; it may have expired"
                )
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        // `2401 PushDeliveryNotFound` means the row aged out after seven days or the notification
        // did not come from this platform. Neither reaches the caller — a statistic that made a
        // notification tap fail would cost more than the statistic is worth — so the `try` here
        // covers cancellation alone, which is the one thing this call does propagate.
        try await client.push.clicked(PushClickedRequest(pushId: "pu_expired"))
        await settle()

        #expect(channel.requests(for: "push.clicked").count == 1, "best effort means once, not again")

        await client.disconnect()
    }

    @Test("the raw namespace call also teaches the client what to re-send")
    func directRegisterSeedsTheCache() async throws {
        let gateway = Self.pushGateway()
        let client = ImClient(options: makeOptions(connector: gateway))

        try await client.connect()
        try await client.push.register(RegisterPushTokenRequest(provider: ImPushProvider.apns, token: "raw-token"))

        #expect(await client.isPushRegistered)

        let first = try #require(gateway.lastChannel)
        first.serverClose(code: 1006, reason: nil)
        _ = await waitUntil("a second socket") { gateway.attempts >= 2 }

        _ = await waitUntil("the re-registration") {
            gateway.lastChannel?.requests(for: "push.register").isEmpty == false
        }

        let second = try #require(gateway.lastChannel)
        let repeated = try #require(second.requests(for: "push.register").first)
        #expect(repeated["token"]?.stringValue == "raw-token")

        await client.disconnect()
    }

    /// The one failure `clicked` does not swallow.
    ///
    /// **The reason this test exists is that the rethrow is one line inside a `catch` whose entire
    /// job is to swallow**, so a later tidy-up of that block deletes it and nothing else notices.
    /// `CONTRACT.md` §7.5 rule 3: a cancelled call raises the language's cancellation type. A `Task`
    /// cancelled mid-flight that returns normally tells the group that cancelled it the child
    /// finished — which is the opposite of what happened.
    /// 这条用例存在的理由是：那个 rethrow 是一个「本职就是吞异常」的 catch 里的一行，
    /// 之后有人整理这个块时会顺手删掉它，而没有别的东西会发现。
    @Test
    func clickedStillRaisesCancellation() async throws {
        let gateway = MockGateway(responder: { request, channel in
            // Answers housekeeping and nothing else: push.clicked is left hanging on purpose, so the
            // only way this call can finish is the cancellation under test.
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let task = Task {
            try await client.push.clicked(PushClickedRequest(messageId: "350598345233801216"))
        }

        task.cancel()

        var raised = false
        do {
            try await task.value
        } catch is CancellationError {
            raised = true
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(raised, "a cancelled tap report must not complete as though it succeeded")

        await client.disconnect()
    }
}
