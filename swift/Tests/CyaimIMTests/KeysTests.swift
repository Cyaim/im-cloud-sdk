import Foundation
import Testing

@testable import CyaimIM

/// `keys.publish` / `keys.upload` / `keys.remaining` / `keys.claim` / `keys.devices` / `keys.revoke` /
/// `keys.safetyNumber` — the end-to-end encryption key directory.
///
/// Every call is asserted on the frame it puts on the wire — target and the whole body, compared as a
/// ``JSONValue`` so a string, a number and an absent key are told apart, the nested `signedPreKey` /
/// `oneTimePreKeys[]` / `keys[]` members by their exact camelCase names, since the server matches
/// those case-sensitively and refuses (`1000`) a missing required one — and on what it makes of a
/// reply with every field set; fixtures and requests are held to `endpoint-inventory.json`'s
/// `payloadTypes`. Rules with tests of their own: key material leaves byte for byte as given and is
/// never logged; `keys.publish` carries no device id and no platform; a claim on an empty pool decodes
/// with no one-time prekey; a claim is sent once and never reissued; the refusals reach the caller as
/// readable ``ImError``s. Mirrors the Kotlin `KeysTest`.
///
/// 每个调用断言发出的整帧（嵌套成员按服务端区分大小写的名字）与对满字段答复的解码，夹具与请求对着清单的 payloadTypes 钉住。
/// 另有几条规则单独测：密钥材料原样发出、从不写进日志；keys.publish 不带设备与平台；池子空了的领取解码为没有一次性预密钥；
/// 领取只发一次、不重发；拒绝以可读的 ImError 交给调用方。
@Suite("Keys")
struct KeysTests {

    // Standard base64 with '+', '/' and padding, so any re-encoding (base64url, unpadded) would show.
    private static let identityKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    private static let spkPublic = "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A="
    private static let spkSignature = "+/+/c2lnbmF0dXJlLW92ZXItc3BrLXB1YmxpYy1rZXk/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pw=="
    private static let otk1 = "b3RrLTEr/w=="
    private static let otk2 = "b3RrLTIr/w=="

    private static let algorithm = "x3dh-ed25519-aes256gcm-v1"
    private static let safety = "12345 67890 13579 24680 11223 34455 66778 89900 10293 84756 56473 82910"

    // MARK: - Fixtures

    /// Every member of the server's SignedPreKey, each with a value no default reads as.
    private static func signedPreKey() -> JSONValue {
        .object([
            "keyId": .string("spk_1"),
            "publicKey": .string(Self.spkPublic),
            "signature": .string(Self.spkSignature),
            "createdAt": .int(1_758_412_800_000),
        ])
    }

    /// Every member of the server's PreKeyBundle; the server omits `oneTimePreKey` (never null) when
    /// the pool is empty. `fixturesCarryEveryServerMember` holds the list to the inventory.
    private static func bundle(withOneTimeKey: Bool = true) -> JSONValue {
        var members: [String: JSONValue] = [
            "userId": .string("bob"),
            "deviceId": .string("device-9"),
            "identityKey": .string(Self.identityKey),
            "signedPreKey": Self.signedPreKey(),
            "algorithm": .string(Self.algorithm),
        ]
        if withOneTimeKey {
            members["oneTimePreKey"] = .object(["keyId": .string("otk_1"), "publicKey": .string(Self.otk1)])
        }
        return .object(members)
    }

    /// Every member of the server's DeviceKeyInfo.
    private static func device(_ deviceId: String, platform: Int64, remaining: Int64) -> JSONValue {
        .object([
            "deviceId": .string(deviceId),
            "platform": .int(platform),
            "identityKey": .string(Self.identityKey),
            "publishedAt": .int(1_758_412_800_123),
            "remainingOneTimeKeys": .int(remaining),
        ])
    }

    /// One refusal a gateway answers for one target: status 0, a business code, its message.
    private struct Refusal: Sendable {
        let target: String
        let code: ImErrorCode
        let message: String
    }

    /// The directory as the server answers it. Two claims are scripted by device id: `device-busy`
    /// is refused with `1005`, retryable in general, and `device-silent` is never answered.
    private static func gateway(emptyPool: Bool = false, refusing refusal: Refusal? = nil) -> MockGateway {
        MockGateway(responder: { request, channel in
            if MockGateway.answerHousekeeping(request, channel) { return }

            if let refusal, request.target == refusal.target {
                channel.reply(to: request, code: refusal.code, message: refusal.message, traceId: "trace-refused")
                return
            }

            switch request.target {
            case "keys.remaining":
                // Bare values, as the server answers these three: a number, an array, a string.
                channel.reply(to: request, data: .int(3))
            case "keys.devices":
                if request["userId"]?.stringValue == "nobody" {
                    channel.reply(to: request, data: .array([]))
                } else {
                    channel.reply(to: request, data: .array([
                        Self.device("device-9", platform: 5, remaining: 3),
                        Self.device("device-2", platform: 1, remaining: 0),
                    ]))
                }
            case "keys.safetyNumber":
                channel.reply(to: request, data: .string(Self.safety))
            case "keys.claim":
                switch request["deviceId"]?.stringValue ?? "" {
                case "device-busy":
                    channel.reply(to: request, code: .serviceUnavailable, message: "key directory is unavailable", traceId: "trace-refused")
                case "device-silent":
                    break
                default:
                    channel.reply(to: request, data: Self.bundle(withOneTimeKey: !emptyPool))
                }
            case "keys.revoke":
                if (request["deviceId"]?.stringValue ?? "").isEmpty {
                    channel.reply(to: request, code: .invalidArgument, message: "deviceId is required", traceId: "trace-refused")
                } else {
                    channel.reply(to: request, data: .null)
                }
            default:
                // publish and upload acknowledge the way the server does: no payload.
                channel.reply(to: request, data: .null)
            }
        })
    }

    private static func fullPublish() -> PublishKeysRequest {
        PublishKeysRequest(
            identityKey: Self.identityKey,
            signedPreKey: SignedPreKey(
                keyId: "spk_1",
                publicKey: Self.spkPublic,
                signature: Self.spkSignature,
                createdAt: 1_758_412_800_000
            ),
            oneTimePreKeys: [
                OneTimePreKey(keyId: "otk_1", publicKey: Self.otk1),
                OneTimePreKey(keyId: "otk_2", publicKey: Self.otk2),
            ],
            algorithm: Self.algorithm
        )
    }

    /// A request encoded exactly as ``ImConnection`` encodes a frame's body, read back as JSON.
    private static func wire(_ request: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    }

    /// A reply decoded through the public type alone, the way ``ImConnection`` decodes a payload.
    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func keys(_ value: JSONValue?) -> Set<String> {
        guard case let .object(members)? = value else { return [] }
        return Set(members.keys)
    }

    /// The ``ImError`` a call fails with, or `nil` when it succeeded (or failed some other way).
    private static func failure(_ call: () async throws -> Void) async -> ImError? {
        do {
            try await call()
            return nil
        } catch let error as ImError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - keys.publish

    @Test("keys.publish sends every member but the two the server takes from the connection, nested names exact")
    func publishSendsEveryMemberButDeviceAndPlatform() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.keys.publish(Self.fullPublish())

        let sent = channel.requests(for: "keys.publish")
        #expect(sent.map(\.target) == ["keys.publish"])
        let body = try #require(sent.first?.body)
        #expect(body == .object([
            "identityKey": .string(Self.identityKey),
            "signedPreKey": .object([
                "keyId": .string("spk_1"),
                "publicKey": .string(Self.spkPublic),
                "signature": .string(Self.spkSignature),
                "createdAt": .int(1_758_412_800_000),
            ]),
            "oneTimePreKeys": .array([
                .object(["keyId": .string("otk_1"), "publicKey": .string(Self.otk1)]),
                .object(["keyId": .string("otk_2"), "publicKey": .string(Self.otk2)]),
            ]),
            "algorithm": .string(Self.algorithm),
        ]))

        let publishMembers = try Self.members("PublishKeysRequest")
        let signedMembers = try Self.members("SignedPreKey")
        let oneTimeMembers = try Self.members("OneTimePreKey")
        #expect(Self.keys(body) == publishMembers.subtracting(["deviceId", "platform"]))
        #expect(body["deviceId"] == nil, "the server overwrites it with the connection's; it is not an input")
        #expect(body["platform"] == nil)
        #expect(Self.keys(body["signedPreKey"]) == signedMembers, "nested: matched case-sensitively, so exactly these names")
        let pool = body["oneTimePreKeys"]?.arrayValue ?? []
        #expect(pool.map { Self.keys($0) } == [oneTimeMembers, oneTimeMembers])

        await client.disconnect()
    }

    @Test("keys.publish without one-time prekeys or an algorithm leaves the server's defaults")
    func publishMinimalLeavesTheServerDefaults() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.keys.publish(PublishKeysRequest(
            identityKey: Self.identityKey,
            signedPreKey: SignedPreKey(keyId: "spk_1", publicKey: Self.spkPublic, signature: Self.spkSignature)
        ))

        let body = try #require(channel.requests(for: "keys.publish").first?.body)
        // No algorithm, never null: absent keeps the server's default. createdAt goes as 0, which the
        // server reads as now; the pool as an empty list.
        #expect(body == .object([
            "identityKey": .string(Self.identityKey),
            "signedPreKey": .object([
                "keyId": .string("spk_1"),
                "publicKey": .string(Self.spkPublic),
                "signature": .string(Self.spkSignature),
                "createdAt": .int(0),
            ]),
            "oneTimePreKeys": .array([]),
        ]))

        await client.disconnect()
    }

    // MARK: - keys.upload

    @Test("keys.upload sends only the keys, on both overloads, nested names exact")
    func uploadSendsOnlyTheKeys() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.keys.upload(UploadOneTimeKeysRequest(keys: [OneTimePreKey(keyId: "otk_3", publicKey: Self.otk1)]))
        try await client.keys.upload([
            OneTimePreKey(keyId: "otk_4", publicKey: Self.otk2),
            OneTimePreKey(keyId: "otk_5", publicKey: Self.otk1),
        ])

        let bodies = channel.requests(for: "keys.upload").map(\.body)
        // No device: it is the connection's.
        #expect(bodies == [
            .object(["keys": .array([
                .object(["keyId": .string("otk_3"), "publicKey": .string(Self.otk1)]),
            ])]),
            .object(["keys": .array([
                .object(["keyId": .string("otk_4"), "publicKey": .string(Self.otk2)]),
                .object(["keyId": .string("otk_5"), "publicKey": .string(Self.otk1)]),
            ])]),
        ])

        await client.disconnect()
    }

    // MARK: - keys.remaining

    @Test("keys.remaining sends an empty body for this device, a named one otherwise, and decodes the bare number")
    func remainingDecodesTheBareNumber() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let mine = try await client.keys.remaining()
        let other = try await client.keys.remaining("device-2")
        _ = try await client.keys.remaining(RemainingKeysRequest(deviceId: "device-3"))

        let bodies = channel.requests(for: "keys.remaining").map(\.body)
        #expect(bodies == [
            // Absent means the connected device; never a null, never this device's id filled in.
            .object([:]),
            .object(["deviceId": .string("device-2")]),
            .object(["deviceId": .string("device-3")]),
        ])
        #expect(mine == 3)
        #expect(other == 3)

        await client.disconnect()
    }

    // MARK: - keys.claim

    @Test("keys.claim sends user and device on both overloads and decodes every member of the bundle")
    func claimDecodesTheWholeBundle() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let bundle = try await client.keys.claim(ClaimBundleRequest(userId: "bob", deviceId: "device-9"))
        _ = try await client.keys.claim(userId: "bob", deviceId: "device-2")

        let bodies = channel.requests(for: "keys.claim").map(\.body)
        #expect(bodies == [
            .object(["userId": .string("bob"), "deviceId": .string("device-9")]),
            .object(["userId": .string("bob"), "deviceId": .string("device-2")]),
        ])

        #expect(bundle.userId == "bob")
        #expect(bundle.deviceId == "device-9")
        #expect(bundle.identityKey == Self.identityKey, "byte for byte as the server sent it")
        #expect(bundle.signedPreKey == SignedPreKey(
            keyId: "spk_1",
            publicKey: Self.spkPublic,
            signature: Self.spkSignature,
            createdAt: 1_758_412_800_000
        ))
        #expect(bundle.oneTimePreKey == OneTimePreKey(keyId: "otk_1", publicKey: Self.otk1))
        #expect(bundle.algorithm == Self.algorithm)

        await client.disconnect()
    }

    @Test("a claim on an empty pool still succeeds, with no one-time prekey")
    func emptyPoolClaimSucceeds() async throws {
        let gateway = Self.gateway(emptyPool: true)
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let bundle = try await client.keys.claim(userId: "bob", deviceId: "device-9")

        #expect(bundle.oneTimePreKey == nil, "absent on the wire decodes as nil, not as a throw or an empty key")
        #expect(bundle.identityKey == Self.identityKey)
        #expect(bundle.signedPreKey.keyId == "spk_1")

        await client.disconnect()
    }

    /// A claim spends a one-time prekey, so the SDK must never send it twice on its own: not after a
    /// refusal that ``ImError/isRetryable`` calls retryable, and not after a reply that never came.
    @Test("a claim is sent exactly once, refused or unanswered")
    func claimIsSentExactlyOnce() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, requestTimeout: .milliseconds(150)))
        try await client.connect()

        let unavailableError = await Self.failure {
            _ = try await client.keys.claim(userId: "bob", deviceId: "device-busy")
        }
        let unavailable = try #require(unavailableError)
        #expect(unavailable.code == .serviceUnavailable)
        #expect(unavailable.message == "key directory is unavailable")
        #expect(unavailable.target == "keys.claim")
        #expect(unavailable.isRetryable, "retryable in general, which is exactly why the SDK must not act on it here")

        let lostError = await Self.failure {
            _ = try await client.keys.claim(userId: "bob", deviceId: "device-silent")
        }
        let lost = try #require(lostError)
        #expect(lost.code == .timeout)
        #expect(lost.target == "keys.claim")

        // One frame per call, across every socket the client opened; neither was reissued.
        await settle()
        let claims = gateway.openedChannels.flatMap { $0.requests(for: "keys.claim") }
        #expect(claims.map { $0["deviceId"]?.stringValue ?? "" } == ["device-busy", "device-silent"])

        await client.disconnect()
    }

    // MARK: - keys.devices

    @Test("keys.devices sends an empty body for the caller's own, a named user otherwise, and decodes the bare array")
    func devicesDecodesTheBareArray() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let own = try await client.keys.devices()
        let bobs = try await client.keys.devices("bob")
        _ = try await client.keys.devices(DeviceKeysRequest(userId: "carol"))

        let bodies = channel.requests(for: "keys.devices").map(\.body)
        #expect(bodies == [
            // Absent means the caller's own devices.
            .object([:]),
            .object(["userId": .string("bob")]),
            .object(["userId": .string("carol")]),
        ])
        #expect(own == bobs)

        // Unspecified order on the server: sort before asserting.
        let sorted = bobs.sorted { $0.deviceId < $1.deviceId }
        #expect(sorted.map(\.deviceId) == ["device-2", "device-9"])
        let two = try #require(sorted.first)
        let nine = try #require(sorted.last)
        #expect(nine.id == "device-9")
        #expect(nine.platform == .web, "an integer on the wire")
        #expect(nine.identityKey == Self.identityKey)
        #expect(nine.publishedAt == 1_758_412_800_123)
        #expect(nine.remainingOneTimeKeys == 3)
        #expect(two.platform == .iOS)
        #expect(two.remainingOneTimeKeys == 0)

        await client.disconnect()
    }

    @Test("an unknown user's devices are an empty list, not an error")
    func unknownUsersDevicesAreEmpty() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()

        let devices = try await client.keys.devices("nobody")
        #expect(devices.isEmpty)

        await client.disconnect()
    }

    // MARK: - keys.revoke

    @Test("keys.revoke sends only the device id on both overloads, and a blank one is the server's 1001")
    func revokeSendsOnlyTheDeviceId() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.keys.revoke(RevokeDeviceRequest(deviceId: "device-2"))
        try await client.keys.revoke("device-gone")

        // The SDK does not default a blank id to this device; it sends what it was given.
        let blankError = await Self.failure { try await client.keys.revoke("") }
        let blank = try #require(blankError)
        #expect(blank.code == .invalidArgument)
        #expect(blank.message == "deviceId is required")
        #expect(blank.target == "keys.revoke")

        let bodies = channel.requests(for: "keys.revoke").map(\.body)
        #expect(bodies == [
            .object(["deviceId": .string("device-2")]),
            .object(["deviceId": .string("device-gone")]),
            .object(["deviceId": .string("")]),
        ])

        await client.disconnect()
    }

    // MARK: - keys.safetyNumber

    @Test("keys.safetyNumber sends the peer on both overloads and decodes the bare string")
    func safetyNumberDecodesTheBareString() async throws {
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        let number = try await client.keys.safetyNumber("bob")
        _ = try await client.keys.safetyNumber(SafetyNumberRequest(peerUserId: "carol"))

        let bodies = channel.requests(for: "keys.safetyNumber").map(\.body)
        #expect(bodies == [
            .object(["peerUserId": .string("bob")]),
            .object(["peerUserId": .string("carol")]),
        ])
        #expect(number == Self.safety)

        // 12 groups of 5 digits, single spaces.
        let groups = number.split(separator: " ", omittingEmptySubsequences: false)
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { group in group.count == 5 && group.allSatisfy { $0.isASCII && $0.isNumber } })

        await client.disconnect()
    }

    // MARK: - Refusals

    @Test("the directory's refusals reach the caller as readable ImErrors and leave the connection usable")
    func refusalsAreReadableErrors() async throws {
        let cases: [Refusal] = [
            Refusal(target: "keys.publish", code: .invalidArgument, message: "signedPreKey signature does not verify against identityKey"),
            Refusal(target: "keys.publish", code: .unsupportedOperation, message: "unsupported algorithm"),
            Refusal(target: "keys.publish", code: .quotaExceeded, message: "a user may publish at most 10 devices"),
            Refusal(target: "keys.upload", code: .notFound, message: "device has not published its identity key"),
            Refusal(target: "keys.claim", code: .notFound, message: "device has published no keys"),
            Refusal(target: "keys.safetyNumber", code: .notFound, message: "one of the parties has published no keys"),
        ]

        for refusal in cases {
            let gateway = Self.gateway(refusing: refusal)
            let client = ImClient(options: makeOptions(connector: gateway))
            try await client.connect()
            let channel = try #require(gateway.lastChannel)

            let refusedError = await Self.failure {
                switch refusal.target {
                case "keys.publish":
                    try await client.keys.publish(Self.fullPublish())
                case "keys.upload":
                    try await client.keys.upload([OneTimePreKey(keyId: "otk_9", publicKey: Self.otk1)])
                case "keys.claim":
                    _ = try await client.keys.claim(userId: "bob", deviceId: "device-unknown")
                default:
                    _ = try await client.keys.safetyNumber("bob")
                }
            }
            let refused = try #require(refusedError, "\(refusal.target) should have been refused")
            #expect(refused.code == refusal.code, "\(refusal.target)")
            #expect(refused.message == refusal.message, "the server's own words, for \(refusal.target)")
            #expect(refused.target == refusal.target)
            #expect(refused.traceId == "trace-refused")
            #expect(!refused.isRetryable, "\(refusal.target) \(refusal.code): retrying the same call cannot change the answer")

            // Asked once, and the refusal is the call's, not the connection's.
            #expect(channel.requests(for: refusal.target).count == 1)
            #expect(try await client.keys.remaining() == 3)
            #expect(gateway.openedChannels.count == 1, "no reconnect")

            await client.disconnect()
        }
    }

    @Test("key material is passed through unchanged and never written to the log")
    func keyMaterialIsNeverLogged() async throws {
        let warnings = WarningLog()
        let gateway = Self.gateway()
        let client = ImClient(options: makeOptions(connector: gateway, warningHandler: warnings.handler))
        try await client.connect()
        let channel = try #require(gateway.lastChannel)

        try await client.keys.publish(Self.fullPublish())
        try await client.keys.upload([OneTimePreKey(keyId: "otk_3", publicKey: Self.otk2)])
        _ = try await client.keys.claim(userId: "bob", deviceId: "device-9")
        _ = try await client.keys.devices("bob")

        let sent = try #require(channel.requests(for: "keys.publish").first)
        #expect(sent["signedPreKey"]?["signature"] == .string(Self.spkSignature), "no re-encoding, padding kept")
        #expect(channel.wireLog.contains { $0.contains("keys.publish") }, "the publish frame went out")

        let material = [Self.identityKey, Self.spkPublic, Self.spkSignature, Self.otk1, Self.otk2]
        let logged = await client.log.read().map(\.msg) + warnings.messages
        let leaked = logged.filter { line in material.contains { line.contains($0) } }
        #expect(leaked.isEmpty, "the SDK never logs key material: \(leaked)")

        await client.disconnect()
    }

    // MARK: - Decoding through the public types

    /// The decoded shapes, member for member, so a renamed Swift property cannot read a default.
    @Test("a bundle and a device decode through the public types alone, an unknown platform as itself")
    func bundleAndDeviceDecodeAlone() throws {
        let bundle = try Self.decode(PreKeyBundle.self, from: Self.bundle())
        #expect(bundle.userId == "bob")
        #expect(bundle.deviceId == "device-9")
        #expect(bundle.identityKey == Self.identityKey)
        #expect(bundle.signedPreKey.keyId == "spk_1")
        #expect(bundle.signedPreKey.publicKey == Self.spkPublic)
        #expect(bundle.signedPreKey.signature == Self.spkSignature)
        #expect(bundle.signedPreKey.createdAt == 1_758_412_800_000)
        #expect(bundle.oneTimePreKey?.keyId == "otk_1")
        #expect(bundle.oneTimePreKey?.publicKey == Self.otk1)
        #expect(bundle.algorithm == Self.algorithm)

        let server = try Self.decode(DeviceKeyInfo.self, from: Self.device("device-9", platform: 100, remaining: 7))
        #expect(server.deviceId == "device-9")
        #expect(server.platform == Platform(100))
        #expect(server.identityKey == Self.identityKey)
        #expect(server.publishedAt == 1_758_412_800_123)
        #expect(server.remainingOneTimeKeys == 7)

        let unknown = try Self.decode(DeviceKeyInfo.self, from: Self.device("device-x", platform: 42, remaining: 0))
        #expect(unknown.platform.rawValue == 42, "an open enum keeps a code it does not know")
    }

    @Test("replies with numbers written as strings still decode, and an absent member reads as its default")
    func lenientDecoding() throws {
        let quoted = try Self.decode(DeviceKeyInfo.self, from: .object([
            "deviceId": .string("device-9"),
            "platform": .string("5"),
            "identityKey": .string(Self.identityKey),
            "publishedAt": .string("1758412800123"),
            "remainingOneTimeKeys": .string("3"),
        ]))
        #expect(quoted.platform == .web)
        #expect(quoted.publishedAt == 1_758_412_800_123)
        #expect(quoted.remainingOneTimeKeys == 3)

        let sparse = try Self.decode(PreKeyBundle.self, from: .object(["userId": .string("bob")]))
        #expect(sparse.userId == "bob")
        #expect(sparse.deviceId == "")
        #expect(sparse.signedPreKey == SignedPreKey(keyId: "", publicKey: "", signature: ""))
        #expect(sparse.oneTimePreKey == nil)
        #expect(sparse.algorithm == "")

        let stamped = try Self.decode(SignedPreKey.self, from: .object([
            "keyId": .string("spk_1"),
            "publicKey": .string(Self.spkPublic),
            "signature": .string(Self.spkSignature),
            "createdAt": .string("1758412800000"),
        ]))
        #expect(stamped.createdAt == 1_758_412_800_000)
    }

    // MARK: - Held to the inventory

    /// The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
    /// decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
    /// member the server's type declares, and the requests send every member a client may send, held
    /// here to `endpoint-inventory.json`'s `payloadTypes`.
    @Test("the full fixtures and requests carry every member the server declares")
    func fixturesCarryEveryServerMember() throws {
        let bundleMembers = try Self.members("PreKeyBundle")
        let signedMembers = try Self.members("SignedPreKey")
        let oneTimeMembers = try Self.members("OneTimePreKey")
        let deviceMembers = try Self.members("DeviceKeyInfo")

        #expect(!bundleMembers.isEmpty, "the inventory lists no members for PreKeyBundle")
        #expect(Self.keys(Self.bundle()) == bundleMembers)
        #expect(Self.keys(Self.signedPreKey()) == signedMembers)
        #expect(Self.keys(Self.bundle()["oneTimePreKey"]) == oneTimeMembers)
        #expect(Self.keys(Self.device("d", platform: 5, remaining: 1)) == deviceMembers)

        let publish = try Self.keys(Self.wire(Self.fullPublish()))
        let signed = try Self.keys(Self.wire(SignedPreKey(keyId: "k", publicKey: "p", signature: "s")))
        let oneTime = try Self.keys(Self.wire(OneTimePreKey(keyId: "k", publicKey: "p")))
        let upload = try Self.keys(Self.wire(UploadOneTimeKeysRequest([])))
        let remaining = try Self.keys(Self.wire(RemainingKeysRequest("d")))
        let claim = try Self.keys(Self.wire(ClaimBundleRequest(userId: "u", deviceId: "d")))
        let devices = try Self.keys(Self.wire(DeviceKeysRequest("u")))
        let revoke = try Self.keys(Self.wire(RevokeDeviceRequest("d")))
        let safety = try Self.keys(Self.wire(SafetyNumberRequest("u")))

        let publishMembers = try Self.members("PublishKeysRequest")
        let uploadMembers = try Self.members("UploadOneTimeKeysRequest")
        let remainingMembers = try Self.members("RemainingKeysRequest")
        let claimMembers = try Self.members("ClaimBundleRequest")
        let devicesMembers = try Self.members("DeviceKeysRequest")
        let revokeMembers = try Self.members("RevokeDeviceRequest")
        let safetyMembers = try Self.members("SafetyNumberRequest")

        #expect(publish == publishMembers.subtracting(["deviceId", "platform"]), "every member but the two the server takes from the connection")
        #expect(publishMembers.isSuperset(of: ["deviceId", "platform"]), "the server still declares both; the SDK leaves them out on purpose")
        #expect(signed == signedMembers)
        #expect(oneTime == oneTimeMembers)
        #expect(upload == uploadMembers)
        #expect(remaining == remainingMembers)
        #expect(claim == claimMembers)
        #expect(devices == devicesMembers)
        #expect(revoke == revokeMembers)
        #expect(safety == safetyMembers)
    }

    private static func members(_ type: String) throws -> Set<String> {
        let types = try Self.payloadTypes()
        let properties = (types[type] as? [String: Any])?["properties"] as? [[String: Any]] ?? []
        return Set(properties.compactMap { $0["name"] as? String })
    }

    private static func payloadTypes() throws -> [String: Any] {
        let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.inventoryURL())) as? [String: Any]
        return inventory?["payloadTypes"] as? [String: Any] ?? [:]
    }

    private static func inventoryURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("endpoint-inventory.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
