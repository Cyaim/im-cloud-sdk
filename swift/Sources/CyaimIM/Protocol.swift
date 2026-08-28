import Foundation

// The wire protocol. This file mirrors docs/SPEC-02-protocol.md and is the only place the shape of
// a frame is described on the client side.
//
// The identifier-like types below (error codes, push targets, kick reasons, platforms, content
// types) are `RawRepresentable` structs rather than enums on purpose: the server is a moving
// product and will add a content type, an event or an error code long before a given app is
// rebuilt. An unknown raw value has to decode to *itself*, not throw — a shipped client that
// fails to parse a value added six months later is worse than one that ignores it.

// MARK: - Error codes

/// Business result codes carried inside the response body. Stable API surface: values never move.
public struct ImErrorCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { String(rawValue) }

    public static let ok = ImErrorCode(0)

    // 1000-1099 generic
    public static let internalError = ImErrorCode(1000)
    public static let invalidArgument = ImErrorCode(1001)
    public static let notFound = ImErrorCode(1002)
    public static let rateLimited = ImErrorCode(1003)
    public static let timeout = ImErrorCode(1004)
    public static let serviceUnavailable = ImErrorCode(1005)

    /// Client-side only: the socket was down, so the request never left the device. Shares 1005
    /// with `serviceUnavailable` deliberately — to a caller deciding whether to retry, "the server
    /// is not there" and "the pipe to it is not there" are the same answer, and the other SDKs
    /// report this value under their own name for it.
    public static let notConnected = ImErrorCode(1005)
    public static let conflict = ImErrorCode(1006)
    public static let payloadTooLarge = ImErrorCode(1007)
    public static let unsupportedOperation = ImErrorCode(1008)

    // 1100-1199 auth
    public static let unauthorized = ImErrorCode(1100)
    public static let tokenExpired = ImErrorCode(1101)
    public static let tokenInvalid = ImErrorCode(1102)
    public static let forbidden = ImErrorCode(1103)
    public static let userBanned = ImErrorCode(1104)
    public static let signatureInvalid = ImErrorCode(1105)
    public static let replayDetected = ImErrorCode(1106)
    public static let kickedByOtherDevice = ImErrorCode(1107)

    /// The page's origin is not on the app's web allowlist. A tenant sets that list in the console; it does not vary by user, so retrying or re-authenticating will not help and the SDK must not.
    ///
    /// 页面来源不在该应用的 Web 安全域名表里。这张表由租户在控制台设置、与用户无关——重试或重新登录都没有用，SDK 也不该那么做。
    public static let originNotAllowed = ImErrorCode(1109)

    // 1200-1299 tenant & quota
    public static let appNotFound = ImErrorCode(1200)
    public static let appDisabled = ImErrorCode(1201)

    /// Tenant billing. Never retry, and never bury it in a generic failure: the integrator
    /// debugging this needs the code.
    public static let quotaExceeded = ImErrorCode(1202)

    /// The tenant has this feature switched off, or the module is not deployed.
    ///
    /// **Do not latch it.** A tenant can flip a flag at runtime, and a client that remembers
    /// "typing is off" stays broken until the app restarts. Report it every time and keep calling.
    public static let featureNotEnabled = ImErrorCode(1203)

    public static let planExpired = ImErrorCode(1204)
    public static let concurrencyLimitExceeded = ImErrorCode(1205)

    // 1300-1399 user & relationship
    public static let userNotFound = ImErrorCode(1300)
    public static let userAlreadyExists = ImErrorCode(1301)
    public static let notFriend = ImErrorCode(1302)
    public static let blockedByPeer = ImErrorCode(1303)
    public static let blockedPeer = ImErrorCode(1304)
    public static let friendRequestNotFound = ImErrorCode(1305)
    public static let friendLimitExceeded = ImErrorCode(1306)
    public static let cannotAddSelf = ImErrorCode(1307)

    // 1400-1499 message
    public static let messageNotFound = ImErrorCode(1400)
    public static let messageTooLong = ImErrorCode(1401)
    public static let moderationRejected = ImErrorCode(1402)
    public static let recallWindowExpired = ImErrorCode(1403)
    public static let recallForbidden = ImErrorCode(1404)
    public static let editWindowExpired = ImErrorCode(1405)
    public static let duplicateClientMessageId = ImErrorCode(1406)
    public static let conversationNotFound = ImErrorCode(1407)
    public static let senderMuted = ImErrorCode(1408)
    public static let unsupportedContentType = ImErrorCode(1409)
    public static let receiptDisabled = ImErrorCode(1410)

    // 1500-1599 group
    public static let groupNotFound = ImErrorCode(1500)
    public static let groupDismissed = ImErrorCode(1501)
    public static let groupFull = ImErrorCode(1502)
    public static let notGroupMember = ImErrorCode(1503)
    public static let noGroupPermission = ImErrorCode(1504)
    public static let groupMuted = ImErrorCode(1505)
    public static let memberMuted = ImErrorCode(1506)
    public static let alreadyGroupMember = ImErrorCode(1507)

    /// Not a failure to render as one: `group.join` lodged an application and it is pending.
    public static let joinNeedsApproval = ImErrorCode(1508)

    public static let joinForbidden = ImErrorCode(1509)
    public static let inviteForbidden = ImErrorCode(1510)
    public static let cannotOperateOwner = ImErrorCode(1511)
    public static let applicationNotFound = ImErrorCode(1512)

    // 1600-1699 chat room
    public static let roomNotFound = ImErrorCode(1600)
    public static let roomFull = ImErrorCode(1601)
    public static let notInRoom = ImErrorCode(1602)
    public static let roomMuted = ImErrorCode(1603)

    // 1700-1799 media & storage
    public static let uploadFailed = ImErrorCode(1700)
    public static let fileTypeNotAllowed = ImErrorCode(1701)
    public static let fileTooLarge = ImErrorCode(1702)
    public static let storageQuotaExceeded = ImErrorCode(1703)

    /// No delivery record matches. The row is kept seven days, or the notification did not come from this platform at all. `clicked` swallows it: a click count one short is not an application's problem, and there is nothing a user could do about it.
    ///
    /// 没有匹配的投递记录：记录只保留七天，或者这条通知根本不是本平台发的。
    public static let pushDeliveryNotFound = ImErrorCode(2401)
}

/// Every failure the SDK reports, carrying the code and the server's trace id.
///
/// `traceId` is much of the point of this type. When a tenant opens a support ticket, the trace id
/// is what turns "sending fails sometimes" into one request on one node in one log, so it is
/// surfaced all the way to the caller instead of being logged and dropped.
public struct ImError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// Business code from the response body, or a client-side code for transport failures.
    public let code: ImErrorCode

    public let message: String

    /// Server-side correlation id. Quote it in a support ticket.
    public let traceId: String?

    /// The endpoint that failed, e.g. `msg.send`.
    public let target: String?

    public init(code: ImErrorCode, message: String, traceId: String? = nil, target: String? = nil) {
        self.code = code
        self.message = message
        self.traceId = traceId
        self.target = target
    }

    public var description: String {
        var text = "ImError(\(code.rawValue)): \(message)"
        if let target { text += " [\(target)]" }
        if let traceId { text += " trace=\(traceId)" }
        return text
    }

    public var errorDescription: String? { description }

    /// True when retrying with the *same* payload is safe and sensible — the send may never have
    /// landed, and `clientMsgId` makes a repeat idempotent either way.
    ///
    /// Exactly `1000` InternalError, `1003` RateLimited, `1004` Timeout, `1005`
    /// ServiceUnavailable, and nothing else. Everything outside that list is terminal: retrying it
    /// produces the same answer.
    ///
    /// The SDK **never** retries a business call on your behalf. It retries the *connection*, and
    /// its own `conn.sync` / `msg.sync` repair; everything else surfaces with this flag set and the
    /// application decides. Silently re-sending on `1003` hides rate limiting from the UI that has
    /// to explain it, and silently retrying a send turns a visible failure into an invisible delay.
    public var isRetryable: Bool {
        switch code {
        case .internalError, .rateLimited, .timeout, .serviceUnavailable: return true
        default: return false
        }
    }

    /// True when the host app should mint a new token before trying again.
    ///
    /// `1100` Unauthorized, `1101` TokenExpired, `1102` TokenInvalid. Note that the SDK already
    /// handles `1101` on a live socket by calling `conn.reauth` with a token from
    /// ``ImClientOptions/tokenProvider`` and retrying once — this flag is what is left when that
    /// did not work, or when no provider was configured.
    public var requiresReauth: Bool {
        switch code {
        case .unauthorized, .tokenExpired, .tokenInvalid: return true
        default: return false
        }
    }

    /// The contract's name for this flag is ``requiresReauth``; this spelling shipped first and
    /// stays for source compatibility. Deprecated for 2.0.
    public var isAuthFailure: Bool { requiresReauth }
}

// MARK: - Push targets

/// Server-initiated event names.
public struct PushTarget: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let message = PushTarget("evt.message")
    public static let messageUpdate = PushTarget("evt.messageUpdate")
    public static let conversationUpdate = PushTarget("evt.conversationUpdate")
    public static let read = PushTarget("evt.read")
    public static let typing = PushTarget("evt.typing")
    public static let presence = PushTarget("evt.presence")
    public static let friend = PushTarget("evt.friend")
    public static let group = PushTarget("evt.group")
    public static let system = PushTarget("evt.system")
    public static let stream = PushTarget("evt.stream")
    public static let call = PushTarget("evt.call")
    public static let desk = PushTarget("evt.desk")

    /// Not an `evt.*` event: the server pushes this immediately before closing the socket.
    public static let kick = PushTarget("conn.kick")
}

// MARK: - Kick reasons

/// Why the server closed a connection, parsed from the WebSocket close reason `im-kick:{Reason}`.
///
/// This is the only signal that separates "you were kicked" from "the network died", and the two
/// need opposite responses: one must never reconnect, the other must.
public struct KickReason: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Another device took this identity over under the app's multi-login policy.
    public static let multiLoginPolicy = KickReason("MultiLoginPolicy")
    /// The token aged out. Recoverable: ask the host app for a new one, then reconnect.
    public static let tokenExpired = KickReason("TokenExpired")
    /// The token was revoked server-side (logout elsewhere, credential rotation).
    public static let tokenRevoked = KickReason("TokenRevoked")
    public static let userBanned = KickReason("UserBanned")
    public static let appDisabled = KickReason("AppDisabled")
    public static let quotaExceeded = KickReason("QuotaExceeded")
    /// A gateway going away for a rolling update. Emphatically *not* terminal.
    public static let serverShutdown = KickReason("ServerShutdown")
    public static let adminKick = KickReason("AdminKick")

    /// Synthesised by the SDK, never sent by the server: the HTTP upgrade itself was refused with
    /// 403, which no amount of reconnecting will change.
    public static let handshakeRejected = KickReason("HandshakeRejected")

    /// The close-reason prefix the gateway writes. See `CyaimSocketWriter.CloseAsync` server-side.
    static let closePrefix = "im-kick:"

    /// Parses a WebSocket close reason, returning `nil` when the socket died of anything else.
    public init?(closeReason: String?) {
        guard let closeReason, closeReason.hasPrefix(KickReason.closePrefix) else { return nil }
        let reason = String(closeReason.dropFirst(KickReason.closePrefix.count))
        guard !reason.isEmpty else { return nil }
        self.init(rawValue: reason)
    }

    /// Reasons that mean "do not come back": reconnecting would fail identically, forever, and a
    /// client that keeps trying is a client that hammers the gateway while showing its user
    /// nothing.
    ///
    /// `TokenExpired` is absent because it is recoverable, and `ServerShutdown` is absent because
    /// it is the single most important case to reconnect after — that is a deploy, and the node is
    /// coming back.
    public static let terminalReasons: Set<KickReason> = [
        .multiLoginPolicy,
        .tokenRevoked,
        .userBanned,
        .appDisabled,
        .adminKick,
        .handshakeRejected,
    ]

    /// True when the SDK must stop reconnecting and hand the reason to the app.
    public var isTerminal: Bool { KickReason.terminalReasons.contains(self) }
}

// MARK: - Frames

/// A request the client sends. `id` is mandatory: it is how a reply finds its caller.
struct ImRequestFrame<Body: Encodable & Sendable>: Encodable, Sendable {
    let id: String
    let target: String
    let body: Body
}

/// Body placeholder for endpoints that take no arguments. Encodes as `{}`.
public struct EmptyBody: Codable, Sendable, Hashable {
    public init() {}
}

/// A frame the server sends.
///
/// Replies and server-initiated pushes are structurally identical, which is deliberate: one decoder
/// handles both, and a push can be correlated exactly like a reply.
public struct ImFrame: Sendable, Hashable {
    /// Echoes the request id for a reply; `srv-{snowflake}` for a push.
    public let id: String

    /// Endpoint or event name, e.g. `msg.send`, `evt.message`.
    public let target: String

    /// Transport-level outcome: 0 routed, 1 endpoint threw, 2 endpoint not found.
    public let status: Int

    /// Transport-level error text.
    public let msg: String?

    public let requestTime: Int64?
    public let completeTime: Int64?

    /// Business-level result. Distinct from `status`: the transport can succeed while the endpoint
    /// refuses.
    public let body: ImBody?

    public init(
        id: String,
        target: String,
        status: Int = 0,
        msg: String? = nil,
        requestTime: Int64? = nil,
        completeTime: Int64? = nil,
        body: ImBody? = nil
    ) {
        self.id = id
        self.target = target
        self.status = status
        self.msg = msg
        self.requestTime = requestTime
        self.completeTime = completeTime
        self.body = body
    }
}

/// Business-level result, nested inside the transport frame.
public struct ImBody: Sendable, Hashable {
    public let code: ImErrorCode
    public let message: String?

    /// Server-side correlation id, present on failures and on sampled successes.
    public let traceId: String?

    /// Authoritative server clock, unix ms. Trust this over the device clock.
    public let serverTime: Int64

    public let data: JSONValue?

    public init(
        code: ImErrorCode = .ok,
        message: String? = nil,
        traceId: String? = nil,
        serverTime: Int64 = 0,
        data: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.traceId = traceId
        self.serverTime = serverTime
        self.data = data
    }
}

extension ImFrame: Codable {
    enum CodingKeys: String, CodingKey {
        case id, target, status, msg, requestTime, completeTime, body
    }

    /// Decoded field by field with defaults rather than by synthesis.
    ///
    /// A frame that fails to decode is a message the user never sees. A server that stops sending a
    /// field, or starts sending one this build has never heard of, must cost at most that field —
    /// never the whole frame.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.imString(.id) ?? ""
        target = c.imString(.target) ?? ""
        status = c.imInt(.status) ?? 0
        msg = c.imString(.msg)
        requestTime = c.imInt64(.requestTime)
        completeTime = c.imInt64(.completeTime)
        body = c.imValue(ImBody.self, .body)
    }
}

extension ImBody: Codable {
    enum CodingKeys: String, CodingKey {
        case code, message, traceId, serverTime, data
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.imInt(.code).map(ImErrorCode.init(rawValue:)) ?? .ok
        message = c.imString(.message)
        traceId = c.imString(.traceId)
        serverTime = c.imInt64(.serverTime) ?? 0
        data = c.imValue(JSONValue.self, .data)
    }
}

extension ImFrame {
    /// The payload as `T`, or `nil` when this frame has no payload or it does not fit.
    public func decodedData<T: Decodable>(as type: T.Type = T.self) -> T? {
        try? requireData(as: type)
    }

    /// The payload as `T`, throwing an `ImError` that says what went wrong instead of a
    /// `DecodingError` nobody can act on.
    public func requireData<T: Decodable>(as type: T.Type = T.self) throws -> T {
        guard let payload = body?.data, !payload.isNull else {
            throw ImError(
                code: .internalError,
                message: "\(target) returned no payload",
                traceId: body?.traceId,
                target: target
            )
        }

        do {
            return try payload.decoded(as: T.self)
        } catch {
            throw ImError(
                code: .internalError,
                message: "\(target) payload did not match \(T.self): \(error)",
                traceId: body?.traceId,
                target: target
            )
        }
    }

    /// Throws when either layer reported a failure.
    ///
    /// Both layers have to be checked and they mean different things: `status` is the transport's
    /// verdict (did the frame reach an endpoint at all), `body.code` is the endpoint's (did it
    /// agree to do the work).
    public func throwIfFailed(target requestTarget: String? = nil) throws {
        let endpoint = requestTarget ?? target

        switch status {
        case 0:
            break

        case 2:
            // No such target. Deliberately **1008 UnsupportedOperation, not 1002 NotFound**: 1002
            // means "your group does not exist", 1008 means "this deployment does not have this
            // endpoint" — which is the exact signal an SDK newer than a private-deployment server
            // produces, and the one an integrator needs verbatim rather than paraphrased.
            throw ImError(
                code: .unsupportedOperation,
                message: msg ?? "this deployment has no endpoint named \(endpoint)",
                traceId: body?.traceId,
                target: endpoint
            )

        default:
            // status == 1: the endpoint was reached and threw. The business envelope is usually
            // absent in this case, so the transport's own `msg` is all there is to report.
            throw ImError(
                code: .internalError,
                message: msg ?? "the endpoint failed",
                traceId: body?.traceId,
                target: endpoint
            )
        }

        guard let body else {
            throw ImError(code: .internalError, message: "request failed", target: endpoint)
        }

        guard body.code == .ok else {
            throw ImError(
                code: body.code,
                message: body.message ?? "request failed",
                traceId: body.traceId,
                target: endpoint
            )
        }
    }
}
