import Foundation

// `keys.*` — the end-to-end encryption key directory (T4). The seven calls live on
// ``ImKeysNamespace``; what they send and get back is here.
//
// **This SDK stores and transports keys; it performs no cryptography.** Every key, prekey and
// signature below is an opaque string the application produced with its own crypto library — public
// material only, standard base64 (not base64url) — and the SDK passes it through unchanged, byte for
// byte. That is load-bearing: the server compares identity keys by exact string equality and hashes
// the strings themselves into the safety number, so re-encoding a key (padding, the URL-safe
// alphabet, a trailing newline) reads as a different key. Nothing here ever holds a private key, and
// the SDK never logs key material.
//
// **Not gated by `e2ee.enabled`.** All seven calls answer on every tenant, whether or not the app's
// `e2ee.enabled` setting is on; that switch constrains settings writes and translation only. There is
// no `1203` / `1204` on this surface, no REST route to the directory, and **no event**: a revoked
// device, a changed identity key or a pool running low is never pushed — read `keys.devices` /
// `keys.remaining` again.
//
// SDK 只存取与搬运密钥，不做任何加密运算：下面每个密钥、预密钥与签名都是应用用自己的加密库算出的不透明字符串
// （只有公钥材料，标准 base64，不是 base64url），SDK 原样透传。服务端按字符串逐字比较身份公钥、并把字符串本身散列进安全码，
// 所以任何重新编码都会被读成另一把钥匙。SDK 不持有私钥、不记录任何密钥材料。
// 七个调用不受 e2ee.enabled 约束（那个开关只管设置写入与翻译），没有 1203 / 1204，没有 REST 路由，也没有任何事件推送。

// MARK: - Requests

/// `keys.publish`: this device's identity key, its signed prekey and, optionally, a first batch of
/// one-time prekeys. Called at first login on a device, and again whenever the client rotates its
/// signed prekey.
///
/// **No device id and no platform**: the server takes both from the connection and overwrites
/// whatever a body says, so a device can only ever publish for itself. They are not on this type.
///
/// **A re-publish replaces** ``identityKey``, ``signedPreKey``, ``algorithm`` and the publish time,
/// and **keeps the one-time pool**, appending ``oneTimePreKeys`` to it — unless ``identityKey``
/// changed, in which case the old pool is deleted first (its keys belong to the old identity).
///
/// **Refusals:** `1001` "identityKey is required" / "signedPreKey is required" for a blank
/// ``identityKey`` or ``SignedPreKey/publicKey``; `1001` "identityKey is not valid for this algorithm"
/// (Curve25519 / Ed25519: 32 decoded bytes, or 33 with a leading `0x05`; P-256: at least 33);
/// `1001` "signedPreKey is incomplete" (decoded public key 1–128 bytes, signature 1–96);
/// `1001` "signedPreKey signature does not verify against identityKey"; `1001` for more than 100
/// one-time prekeys; `1008` for an ``algorithm`` the server cannot classify; `1202 QuotaExceeded`
/// for an eleventh device of the same user. A device's keys expire 180 days after its last publish
/// or upload.
///
/// 发布本设备的身份公钥、签名预密钥与（可选）一批一次性预密钥。设备与平台由服务端从连接取，类型上没有这两个字段。
/// 重新发布会替换身份公钥、签名预密钥、算法与发布时间，保留一次性池并追加新键；身份公钥变了则先清掉旧池。
public struct PublishKeysRequest: Encodable, Sendable, Hashable {
    /// The device's long-lived public identity key, standard base64, at most 256 characters.
    public var identityKey: String

    /// The current signed prekey; its signature is the identity key's over
    /// ``SignedPreKey/publicKey``.
    public var signedPreKey: SignedPreKey

    /// Optional first batch, at most 100 per call; always written, an empty list when there is none.
    /// Entries with a blank `keyId`, a `keyId` containing U+001F, a `publicKey` that is not base64,
    /// or a `keyId` repeated within the call are **dropped without an error**. The pool holds at most
    /// 100 per device, keeping the oldest.
    public var oneTimePreKeys: [OneTimePreKey]

    /// The key-agreement suite. `nil` is left out of the body and keeps the server's default,
    /// `"x3dh-curve25519-aes256gcm-v1"`. The server reads the signature scheme off this name:
    /// `curve25519` / `x25519` / `xed25519` mean XEdDSA, `ed25519` Ed25519, `p256` / `p-256` /
    /// `secp256r1` / `prime256v1` ECDSA P-256; anything else is `1008`.
    public var algorithm: String?

    public init(
        identityKey: String,
        signedPreKey: SignedPreKey,
        oneTimePreKeys: [OneTimePreKey] = [],
        algorithm: String? = nil
    ) {
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.oneTimePreKeys = oneTimePreKeys
        self.algorithm = algorithm
    }
}

/// A signed prekey, as `keys.publish` sends it and `keys.claim` returns it. All four names are
/// matched **case-sensitively** by the server (it is a nested object), and the first three are
/// required there — a missing one fails the whole call with `1000`. This type always writes all four.
///
/// 嵌套对象：服务端按大小写精确匹配，前三个成员必填，缺一个整次调用就是 1000。本类型四个成员都会写出。
public struct SignedPreKey: Codable, Sendable, Hashable {
    /// The application's own id for this prekey.
    public var keyId: String

    /// Standard base64; 1–128 bytes decoded.
    public var publicKey: String

    /// The identity key's signature over the decoded bytes of ``publicKey`` only; 1–96 bytes decoded.
    public var signature: String

    /// Unix ms. 0 means "now" to the server, which stamps it.
    public var createdAt: Int64

    public init(keyId: String, publicKey: String, signature: String, createdAt: Int64 = 0) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.signature = signature
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case keyId, publicKey, signature, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyId = c.imString(.keyId) ?? ""
        publicKey = c.imString(.publicKey) ?? ""
        signature = c.imString(.signature) ?? ""
        createdAt = c.imInt64(.createdAt) ?? 0
    }
}

/// A one-time prekey: handed out once by `keys.claim`, then gone. Both names are case-sensitive and
/// required.
public struct OneTimePreKey: Codable, Sendable, Hashable {
    public var keyId: String

    /// Standard base64.
    public var publicKey: String

    public init(keyId: String, publicKey: String) {
        self.keyId = keyId
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case keyId, publicKey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyId = c.imString(.keyId) ?? ""
        publicKey = c.imString(.publicKey) ?? ""
    }
}

/// `keys.upload`: tops up the **connected** device's one-time pool — the device cannot be named.
/// Appends; the pool is capped at 100 per device (the oldest kept).
///
/// `1001` "keys is required" for an empty list, "no valid one-time prekeys supplied" when every entry
/// was dropped (see ``PublishKeysRequest/oneTimePreKeys`` for what is dropped), or for more than 100;
/// `1002` "device has not published its identity key" before this device's first `keys.publish`.
public struct UploadOneTimeKeysRequest: Encodable, Sendable, Hashable {
    public var keys: [OneTimePreKey]

    public init(keys: [OneTimePreKey]) {
        self.keys = keys
    }

    public init(_ keys: [OneTimePreKey]) {
        self.keys = keys
    }
}

/// `keys.remaining`: how many one-time prekeys one of the caller's **own** devices has left. `nil`
/// (left out of the body) or blank means the connected device. An unknown device answers 0, never an
/// error.
public struct RemainingKeysRequest: Encodable, Sendable, Hashable {
    public var deviceId: String?

    public init(deviceId: String? = nil) {
        self.deviceId = deviceId
    }

    public init(_ deviceId: String) {
        self.deviceId = deviceId
    }
}

/// `keys.claim`: the bundle for one device of a user. Both members are required (`1001` "userId is
/// required" / "deviceId is required"); neither defaults to the caller.
///
/// **Not idempotent — it consumes.** See ``ImKeysNamespace/claim(_:)``.
public struct ClaimBundleRequest: Encodable, Sendable, Hashable {
    public var userId: String
    public var deviceId: String

    public init(userId: String, deviceId: String) {
        self.userId = userId
        self.deviceId = deviceId
    }
}

/// `keys.devices`: whose devices to list. `nil` (left out of the body) or blank means the caller's
/// own.
public struct DeviceKeysRequest: Encodable, Sendable, Hashable {
    public var userId: String?

    public init(userId: String? = nil) {
        self.userId = userId
    }

    public init(_ userId: String) {
        self.userId = userId
    }
}

/// `keys.revoke`: one of the caller's **own** devices, by id. Required — blank is `1001` "deviceId is
/// required", and it never defaults to the connected device (revoking this one is allowed, by naming
/// it). An id the caller does not have succeeds and changes nothing.
public struct RevokeDeviceRequest: Encodable, Sendable, Hashable {
    public var deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }

    public init(_ deviceId: String) {
        self.deviceId = deviceId
    }
}

/// `keys.safetyNumber`: the user to compare with. Blank is `1001`; the caller's own id is allowed.
public struct SafetyNumberRequest: Encodable, Sendable, Hashable {
    public var peerUserId: String

    public init(peerUserId: String) {
        self.peerUserId = peerUserId
    }

    public init(_ peerUserId: String) {
        self.peerUserId = peerUserId
    }
}

// MARK: - Responses

/// What `keys.claim` answers: everything needed to open a session with one device.
///
/// ``oneTimePreKey`` is **`nil` when the device's pool was empty** — the claim still succeeds, and the
/// session is opened without one (X3DH allows it, with weaker forward secrecy for the first message).
public struct PreKeyBundle: Decodable, Sendable, Hashable {
    public let userId: String

    public let deviceId: String

    /// Standard base64, exactly as the device published it.
    public let identityKey: String

    public let signedPreKey: SignedPreKey

    /// The one-time prekey this claim consumed; `nil` when the pool was empty.
    public let oneTimePreKey: OneTimePreKey?

    public let algorithm: String

    enum CodingKeys: String, CodingKey {
        case userId, deviceId, identityKey, signedPreKey, oneTimePreKey, algorithm
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.imString(.userId) ?? ""
        deviceId = c.imString(.deviceId) ?? ""
        identityKey = c.imString(.identityKey) ?? ""
        signedPreKey = c.imValue(SignedPreKey.self, .signedPreKey)
            ?? SignedPreKey(keyId: "", publicKey: "", signature: "")
        oneTimePreKey = c.imValue(OneTimePreKey.self, .oneTimePreKey)
        algorithm = c.imString(.algorithm) ?? ""
    }
}

/// One device with published keys, as `keys.devices` lists it. There is no signed prekey here; take
/// that from `keys.claim`.
public struct DeviceKeyInfo: Decodable, Sendable, Hashable, Identifiable {
    /// `Identifiable` uses it.
    public let deviceId: String

    /// The platform of the connection that last published, an integer on the wire. One this build
    /// does not name still decodes, as itself.
    public let platform: Platform

    public let identityKey: String

    /// Unix ms of the last `keys.publish`.
    public let publishedAt: Int64

    public let remainingOneTimeKeys: Int

    public var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId, platform, identityKey, publishedAt, remainingOneTimeKeys
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = c.imString(.deviceId) ?? ""

        // Read as an integer, a quoted one included, rather than through Platform's own strict
        // decoder: an unreadable platform must not cost the device its place in the list.
        platform = c.imInt(.platform).map { Platform(rawValue: $0) } ?? .unknown

        identityKey = c.imString(.identityKey) ?? ""
        publishedAt = c.imInt64(.publishedAt) ?? 0
        remainingOneTimeKeys = c.imInt(.remainingOneTimeKeys) ?? 0
    }
}
