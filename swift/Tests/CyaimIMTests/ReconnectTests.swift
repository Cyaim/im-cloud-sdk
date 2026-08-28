import Foundation
import Testing

@testable import CyaimIM

/// "You were kicked" and "the network died" look identical at the socket level and need opposite
/// responses. Getting this wrong in one direction hammers the gateway forever with a connection
/// that can never succeed; getting it wrong in the other leaves a user staring at a chat that will
/// never reconnect. Both directions are asserted here.
@Suite("Reconnect and kick handling")
struct ReconnectTests {

    @Test(
        "a terminal kick stops the client for good",
        arguments: [
            KickReason.multiLoginPolicy,
            KickReason.tokenRevoked,
            KickReason.userBanned,
            KickReason.appDisabled,
            KickReason.adminKick,
        ]
    )
    func terminalKicksDoNotReconnect(reason: KickReason) async throws {
        let gateway = MockGateway(onOpen: { _, channel in
            channel.serverClose(code: 4001, reason: "im-kick:\(reason.rawValue)")
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        let kicks = Collector(client.kicks())
        let states = Collector(client.states())

        try? await client.connect()

        _ = await waitUntil("the client to give up") {
            await client.connection.currentState == .closed
        }

        // Long enough for several jittered retries to have happened, had any been scheduled.
        await settle()

        #expect(gateway.attempts == 1, "\(reason) reconnected \(gateway.attempts) times")
        #expect(kicks.items.first?.reason == reason)
        #expect(states.items.last == .closed)

        await client.disconnect()
    }

    @Test("a socket that dies without a kick reason reconnects")
    func networkFailureReconnects() async throws {
        let gateway = MockGateway(onOpen: { attempt, channel in
            // Two dead sockets, then a good one.
            if attempt <= 2 {
                channel.serverClose(code: 1006, reason: nil)
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try? await client.connect()

        _ = await waitUntil("a third handshake") { gateway.attempts >= 3 }
        _ = await waitUntil("the connection to settle open") {
            await client.connection.currentState == .open
        }

        #expect(await client.connection.currentState == .open)
        await client.disconnect()
    }

    /// The single most important reason *not* to treat a kick as terminal: this is a deploy, and
    /// the node is coming back.
    @Test("ServerShutdown is a deploy, not an eviction, and reconnects")
    func serverShutdownReconnects() async throws {
        let gateway = MockGateway(onOpen: { attempt, channel in
            if attempt == 1 {
                channel.serverClose(code: 4000, reason: "im-kick:ServerShutdown")
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try? await client.connect()

        _ = await waitUntil("a second handshake") { gateway.attempts >= 2 }
        #expect(gateway.attempts >= 2)

        await client.disconnect()
    }

    /// A reason this build has never heard of. Reconnecting is the safe guess: at worst the server
    /// says it again, at best the client recovers from something transient.
    @Test("an unknown kick reason is treated as recoverable")
    func unknownKickReasonReconnects() async throws {
        let gateway = MockGateway(onOpen: { attempt, channel in
            if attempt == 1 {
                channel.serverClose(code: 4009, reason: "im-kick:SomethingInventedNextQuarter")
            }
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try? await client.connect()

        _ = await waitUntil("a second handshake") { gateway.attempts >= 2 }
        #expect(gateway.attempts >= 2)

        await client.disconnect()
    }

    @Test("TokenExpired asks the host app for a new token and reconnects with it")
    func tokenExpiredRefreshesAndReconnects() async throws {
        let gateway = MockGateway(onOpen: { attempt, channel in
            if attempt == 1 {
                channel.serverClose(code: 4002, reason: "im-kick:TokenExpired")
            }
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            token: "token-1",
            tokenProvider: { "token-2" }
        ))

        try? await client.connect()

        _ = await waitUntil("a second handshake") { gateway.attempts >= 2 }

        #expect(gateway.queryValue("token", ofAttempt: 1) == "token-1")
        #expect(gateway.queryValue("token", ofAttempt: 2) == "token-2")

        await client.disconnect()
    }

    @Test("TokenExpired with no replacement token stops, rather than looping on a dead token")
    func tokenExpiredWithoutReplacementCloses() async throws {
        let gateway = MockGateway(onOpen: { _, channel in
            channel.serverClose(code: 4002, reason: "im-kick:TokenExpired")
        })

        // `nil` is the right answer when the user has been signed out of the host app entirely.
        let client = ImClient(options: makeOptions(connector: gateway, tokenProvider: { nil }))
        let kicks = Collector(client.kicks())

        try? await client.connect()

        _ = await waitUntil("the client to give up") {
            await client.connection.currentState == .closed
        }
        await settle()

        #expect(gateway.attempts == 1)
        #expect(kicks.items.first?.reason == .tokenExpired)

        await client.disconnect()
    }

    @Test("a 401 on the upgrade is a stale token, not a dead network")
    func unauthorizedHandshakeRefreshesToken() async throws {
        let gateway = MockGateway(handshake: { attempt in
            attempt == 1 ? .refuse(status: 401) : .accept
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            token: "token-1",
            tokenProvider: { "token-2" }
        ))

        try? await client.connect()

        _ = await waitUntil("a second handshake") { gateway.attempts >= 2 }
        #expect(gateway.queryValue("token", ofAttempt: 2) == "token-2")

        await client.disconnect()
    }

    @Test("a 403 on the upgrade is terminal")
    func forbiddenHandshakeIsTerminal() async throws {
        let gateway = MockGateway(handshake: { _ in .refuse(status: 403) })

        let client = ImClient(options: makeOptions(connector: gateway))
        let kicks = Collector(client.kicks())

        try? await client.connect()

        _ = await waitUntil("the client to give up") {
            await client.connection.currentState == .closed
        }
        await settle()

        #expect(gateway.attempts == 1)
        #expect(kicks.items.first?.reason == .handshakeRejected)

        await client.disconnect()
    }

    @Test("a 503 on the upgrade comes back")
    func serverErrorHandshakeRetries() async throws {
        let gateway = MockGateway(handshake: { attempt in
            attempt <= 2 ? .refuse(status: 503) : .accept
        })

        let client = ImClient(options: makeOptions(connector: gateway))
        try? await client.connect()

        _ = await waitUntil("a third handshake") { gateway.attempts >= 3 }
        #expect(gateway.attempts >= 3)

        await client.disconnect()
    }

    /// The half-open socket: the OS still reports a healthy connection because nothing has been
    /// sent to prove otherwise. The failed beat is that proof.
    @Test("a heartbeat that goes unanswered forces the socket down and reconnects")
    func failedHeartbeatForcesReconnect() async throws {
        let gateway = MockGateway(responder: { request, channel in
            // Answer everything except the heartbeat, which vanishes exactly as it does on a
            // connection a middlebox has quietly dropped.
            if request.target == "conn.heartbeat" { return }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            requestTimeout: .milliseconds(120),
            heartbeatInterval: .milliseconds(40)
        ))

        try? await client.connect()

        _ = await waitUntil("the dead socket to be abandoned") { gateway.attempts >= 2 }

        #expect(gateway.openedChannels.first?.closeCode == 4000)
        #expect(gateway.attempts >= 2)

        await client.disconnect()
    }

    @Test("returning to the foreground probes an open socket instead of waiting for the next beat")
    func foregroundProbesTheSocket() async throws {
        let gateway = MockGateway()

        // A 30 second heartbeat, so nothing scheduled can be responsible for what we observe.
        let client = ImClient(options: makeOptions(connector: gateway, heartbeatInterval: .seconds(30)))
        try await client.connect()

        let channel = try #require(gateway.lastChannel)
        #expect(channel.requests(for: "conn.heartbeat").isEmpty)

        await client.enterForeground()

        _ = await waitUntil("an immediate probe") {
            !channel.requests(for: "conn.heartbeat").isEmpty
        }

        await client.disconnect()
    }

    @Test("a foreground probe on a socket that is already dead forces a reconnect")
    func foregroundProbeReconnectsWhenTheSocketIsGone() async throws {
        let gateway = MockGateway(responder: { request, channel in
            if request.target == "conn.heartbeat" { return }
            _ = MockGateway.answerHousekeeping(request, channel)
        })

        let client = ImClient(options: makeOptions(
            connector: gateway,
            requestTimeout: .milliseconds(120),
            heartbeatInterval: .seconds(30)
        ))

        try await client.connect()
        await client.enterForeground()

        _ = await waitUntil("a fresh socket") { gateway.attempts >= 2 }

        #expect(gateway.openedChannels.first?.closeCode == 4001)

        await client.disconnect()
    }

    @Test("disconnecting stops the reconnect loop")
    func disconnectStopsReconnecting() async throws {
        let gateway = MockGateway()

        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let openedBefore = gateway.attempts
        await client.disconnect()

        // Kill the socket the way a network would, after the client has stopped caring.
        gateway.lastChannel?.serverClose(code: 1006, reason: nil)
        await settle()

        #expect(gateway.attempts == openedBefore)
        #expect(await client.connection.currentState == .closed)
    }
}
