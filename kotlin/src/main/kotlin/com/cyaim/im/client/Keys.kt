package com.cyaim.im.client

import kotlinx.serialization.Serializable

/*
 * `keys.*` — the end-to-end encryption key directory (T4). The seven calls live on [KeysApi]; what
 * they send and get back is here.
 *
 * **This SDK stores and transports keys; it performs no cryptography.** Every key, prekey and
 * signature below is an opaque string the application produced with its own crypto library —
 * public material only, standard base64 (not base64url) — and the SDK passes it through unchanged,
 * byte for byte. That is load-bearing: the server compares identity keys by exact string equality
 * and hashes the strings themselves into the safety number, so re-encoding a key (padding, URL-safe
 * alphabet, a trailing newline) reads as a different key. Nothing here ever holds a private key,
 * and the SDK never logs key material.
 *
 * **Not gated by `e2ee.enabled`.** All seven calls answer on every tenant, whether or not the
 * app's `e2ee.enabled` setting is on; that switch constrains settings writes and translation only.
 * There is no `1203` / `1204` on this surface, no REST route to the directory, and **no event**: a
 * revoked device, a changed identity key or a pool running low is never pushed — re-read with
 * `keys.devices` / `keys.remaining`.
 *
 * SDK 只存取与搬运密钥，不做任何加密运算：下面每个密钥、预密钥与签名都是应用用自己的加密库算出的不透明字符串
 * （只有公钥材料，标准 base64，不是 base64url），SDK 原样透传。服务端按字符串逐字比较身份公钥、并把字符串本身散列进安全码，
 * 所以任何重新编码都会被读成另一把钥匙。SDK 不持有私钥、不记录任何密钥材料。
 * 七个调用不受 e2ee.enabled 约束（那个开关只管设置写入与翻译），没有 1203 / 1204，没有 REST 路由，也没有任何事件推送。
 */

// ---------------------------------------------------------------------------------- requests

/**
 * `keys.publish`: this device's identity key, its signed prekey and, optionally, a first batch of
 * one-time prekeys. Called at first login on a device, and again whenever the client rotates its
 * signed prekey.
 *
 * **No device id and no platform**: the server takes both from the connection and overwrites
 * whatever a body says, so a device can only ever publish for itself. They are not on this type.
 *
 * **A re-publish replaces** [identityKey], [signedPreKey], [algorithm] and the publish time, and
 * **keeps the one-time pool**, appending [oneTimePreKeys] to it — unless [identityKey] changed, in
 * which case the old pool is deleted first (its keys belong to the old identity).
 *
 * **Refusals:** `1001` "identityKey is required" / "signedPreKey is required" for a blank
 * [identityKey] or [SignedPreKey.publicKey]; `1001` "identityKey is not valid for this algorithm"
 * (Curve25519 / Ed25519: 32 decoded bytes, or 33 with a leading `0x05`; P-256: at least 33);
 * `1001` "signedPreKey is incomplete" (decoded public key 1–128 bytes, signature 1–96);
 * `1001` "signedPreKey signature does not verify against identityKey"; `1001` for more than 100
 * one-time prekeys; `1008` for an [algorithm] the server cannot classify; `1202 QuotaExceeded` for
 * an eleventh device of the same user. A device's keys expire 180 days after its last publish or
 * upload.
 *
 * 发布本设备的身份公钥、签名预密钥与（可选）一批一次性预密钥。设备与平台由服务端从连接取，类型上没有这两个字段。
 * 重新发布会替换身份公钥、签名预密钥、算法与发布时间，保留一次性池并追加新键；身份公钥变了则先清掉旧池。
 */
@Serializable
public data class PublishKeysRequest(
    /** The device's long-lived public identity key, standard base64, at most 256 characters. */
    public val identityKey: String,
    /** The current signed prekey; its signature is the identity key's over [SignedPreKey.publicKey]. */
    public val signedPreKey: SignedPreKey,
    /**
     * Optional first batch, at most 100 per call. Entries with a blank `keyId`, a `keyId` containing
     * U+001F, a `publicKey` that is not base64, or a `keyId` repeated within the call are **dropped
     * without an error**. The pool holds at most 100 per device, keeping the oldest.
     */
    public val oneTimePreKeys: List<OneTimePreKey> = emptyList(),
    /**
     * The key-agreement suite. Null leaves the server's default, `"x3dh-curve25519-aes256gcm-v1"`.
     * The server reads the signature scheme off this name: `curve25519` / `x25519` / `xed25519` mean
     * XEdDSA, `ed25519` Ed25519, `p256` / `p-256` / `secp256r1` / `prime256v1` ECDSA P-256; anything
     * else is `1008`.
     */
    public val algorithm: String? = null,
)

/**
 * A signed prekey, as `keys.publish` sends it and `keys.claim` returns it. All four names are
 * matched **case-sensitively** by the server (it is a nested object), and the first three are
 * required there — a missing one fails the whole call with `1000`.
 *
 * 嵌套对象：服务端按大小写精确匹配，前三个成员必填，缺一个整次调用就是 1000。
 */
@Serializable
public data class SignedPreKey(
    /** The application's own id for this prekey. */
    public val keyId: String,
    /** Standard base64; 1–128 bytes decoded. */
    public val publicKey: String,
    /** The identity key's signature over the decoded bytes of [publicKey] only; 1–96 bytes decoded. */
    public val signature: String,
    /** Unix ms. 0 means "now" to the server, which stamps it. */
    public val createdAt: Long = 0,
)

/** A one-time prekey: handed out once by `keys.claim`, then gone. Both names are case-sensitive and required. */
@Serializable
public data class OneTimePreKey(
    public val keyId: String,
    /** Standard base64. */
    public val publicKey: String,
)

/**
 * `keys.upload`: tops up the **connected** device's one-time pool — the device cannot be named.
 * Appends; the pool is capped at 100 per device (the oldest kept).
 *
 * `1001` "keys is required" for an empty list, "no valid one-time prekeys supplied" when every entry
 * was dropped (see [PublishKeysRequest.oneTimePreKeys] for what is dropped), or for more than 100;
 * `1002` "device has not published its identity key" before this device's first `keys.publish`.
 */
@Serializable
public data class UploadOneTimeKeysRequest(
    public val keys: List<OneTimePreKey>,
)

/**
 * `keys.remaining`: how many one-time prekeys one of the caller's **own** devices has left. Null
 * (or blank) means the connected device. An unknown device answers 0, never an error.
 */
@Serializable
public data class RemainingKeysRequest(
    public val deviceId: String? = null,
)

/**
 * `keys.claim`: the bundle for one device of a user. Both members are required (`1001` "userId is
 * required" / "deviceId is required"); neither defaults to the caller.
 *
 * **Not idempotent — it consumes.** See [KeysApi.claim].
 */
@Serializable
public data class ClaimBundleRequest(
    public val userId: String,
    public val deviceId: String,
)

/** `keys.devices`: whose devices to list. Null (or blank) means the caller's own. */
@Serializable
public data class DeviceKeysRequest(
    public val userId: String? = null,
)

/**
 * `keys.revoke`: one of the caller's **own** devices, by id. Required — blank is `1001` "deviceId is
 * required", and it never defaults to the connected device (revoking this one is allowed, by naming
 * it). An id the caller does not have succeeds and changes nothing.
 */
@Serializable
public data class RevokeDeviceRequest(
    public val deviceId: String,
)

/** `keys.safetyNumber`: the user to compare with. Blank is `1001`; the caller's own id is allowed. */
@Serializable
public data class SafetyNumberRequest(
    public val peerUserId: String,
)

// --------------------------------------------------------------------------------- responses

/**
 * What `keys.claim` answers: everything needed to open a session with one device.
 *
 * [oneTimePreKey] is **null when the device's pool was empty** — the claim still succeeds, and the
 * session is opened without one (X3DH allows it, with weaker forward secrecy for the first message).
 */
@Serializable
public data class PreKeyBundle(
    public val userId: String = "",
    public val deviceId: String = "",
    public val identityKey: String = "",
    public val signedPreKey: SignedPreKey = SignedPreKey("", "", ""),
    /** The one-time prekey this claim consumed; null when the pool was empty. */
    public val oneTimePreKey: OneTimePreKey? = null,
    public val algorithm: String = "",
)

/**
 * One device with published keys, as `keys.devices` lists it. There is no signed prekey here; take
 * that from `keys.claim`.
 */
@Serializable
public data class DeviceKeyInfo(
    public val deviceId: String = "",
    /** The platform of the connection that last published, an integer on the wire. */
    public val platform: Platform = Platform.Unknown,
    public val identityKey: String = "",
    /** Unix ms of the last `keys.publish`. */
    public val publishedAt: Long = 0,
    public val remainingOneTimeKeys: Int = 0,
)
