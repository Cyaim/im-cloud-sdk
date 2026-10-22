package com.cyaim.im.client

/**
 * `keys.*` — the end-to-end encryption key directory (T4): publishing this device's public keys,
 * and fetching a peer's so a session can be opened.
 *
 * **The SDK performs no cryptography.** It moves opaque, standard-base64 strings the application's
 * own crypto library produced, unchanged, and never logs them; generating keys, signing the signed
 * prekey, running X3DH and encrypting messages are the application's. See `Keys.kt` for the types.
 *
 * **Writes speak only for the connected device** (publish, upload); reads name their target.
 * **Callable whether or not the app's `e2ee.enabled` is set** — that switch does not gate the
 * directory. **No event is pushed** for a revoked device, an identity change or a low pool.
 *
 * SDK 不做任何加密运算，只原样搬运应用自己算出的字符串，也不记录它们。写操作只能替当前连接的设备说话，读操作在请求体里点名目标。
 * 不论 e2ee.enabled 开没开都能调用；吊销、身份变更、池子见底都不推送事件。
 */
public class KeysApi internal constructor(private val connection: ImConnection) {

    /**
     * Publishes this device's identity key and signed prekey, with an optional first batch of
     * one-time prekeys. **Replaces** identity, signed prekey and algorithm; **keeps** the one-time
     * pool and appends to it (a changed identity key deletes the old pool first). The device and
     * platform are the connection's. See [PublishKeysRequest] for every refusal.
     *
     * 替换身份公钥、签名预密钥与算法，保留一次性池并追加；设备与平台取自连接。
     */
    public suspend fun publish(request: PublishKeysRequest) {
        connection.execute("keys.publish", request.asBody())
    }

    /**
     * Appends one-time prekeys to the connected device's pool (at most 100 per call, 100 held).
     * `1002` before this device has published. Call it when [remaining] runs low.
     */
    public suspend fun upload(request: UploadOneTimeKeysRequest) {
        connection.execute("keys.upload", request.asBody())
    }

    /** [upload] for the one-field case. */
    public suspend fun upload(keys: List<OneTimePreKey>): Unit = upload(UploadOneTimeKeysRequest(keys))

    /**
     * One-time prekeys left on one of the caller's own devices — the connected one by default. An
     * unknown device is 0, not an error. Nothing is pushed when the pool runs low; ask on launch.
     */
    public suspend fun remaining(request: RemainingKeysRequest = RemainingKeysRequest()): Int =
        connection.request("keys.remaining", request.asBody())

    /** [remaining] for one named device of the caller's own. */
    public suspend fun remaining(deviceId: String): Int = remaining(RemainingKeysRequest(deviceId))

    /**
     * Fetches a bundle to open a session with one device of [ClaimBundleRequest.userId].
     *
     * **A write dressed as a read: it consumes one one-time prekey**, atomically and first-in
     * first-out, so the device's [remaining] drops by one. **Never retry it as if it were
     * idempotent, and never prefetch**: a call whose reply was lost (a `1004` timeout, which
     * [ImException.isRetryable] calls retryable in general) may already have spent a key, and a retry
     * spends the next; a prefetched bundle spends one a real first contact needed. Use a bundle for
     * one session only — two sessions opened from the same one-time prekey get no forward secrecy
     * from it. The SDK never reissues it, beyond the one renewal on `1101 TokenExpired` that every
     * call gets (a call refused for its token did not run). When the pool is empty the claim **still
     * succeeds**, with [PreKeyBundle.oneTimePreKey] null. Claiming one's own device is allowed and
     * drains one's own pool.
     *
     * `1001` for a blank user or device id; `1002` "device has published no keys" (also for an unknown
     * user, and after a revoke); `1005` when the directory is unavailable.
     *
     * 看起来是读，实质是写：每次领取原子地消耗一个一次性预密钥（先进先出），余量减一。不能当幂等请求重试，也不能预取。
     * 池子空了照样成功，只是 oneTimePreKey 为空。
     */
    public suspend fun claim(request: ClaimBundleRequest): PreKeyBundle =
        connection.request("keys.claim", request.asBody())

    /** [claim] for the two-field case. Consumes a one-time prekey like the other overload. */
    public suspend fun claim(userId: String, deviceId: String): PreKeyBundle = claim(ClaimBundleRequest(userId, deviceId))

    /**
     * Every device of a user that has keys published — the caller's own by default — in no
     * particular order: one ciphertext per device in this list. An unknown user is an empty list.
     * No signed prekey here; [claim] has it.
     */
    public suspend fun devices(request: DeviceKeysRequest = DeviceKeysRequest()): List<DeviceKeyInfo> =
        connection.request("keys.devices", request.asBody())

    /** [devices] for one named user. */
    public suspend fun devices(userId: String): List<DeviceKeyInfo> = devices(DeviceKeysRequest(userId))

    /**
     * Forgets one of the caller's own devices: its record, its pool, its place in [devices]. After
     * it, [claim] for that device is `1002` and both sides' safety numbers change; existing sessions
     * are the clients' business, and **no event** tells peers. The id is required (`1001` when
     * blank, never defaulted); an id the caller does not have **succeeds**. Revoking the connected
     * device is allowed.
     *
     * 吊销调用者自己的一台设备。设备 id 必填、不会默认成当前设备；吊销不存在的设备照样成功。不推送任何事件。
     */
    public suspend fun revoke(request: RevokeDeviceRequest) {
        connection.execute("keys.revoke", request.asBody())
    }

    /** [revoke] for the one-field case. */
    public suspend fun revoke(deviceId: String): Unit = revoke(RevokeDeviceRequest(deviceId))

    /**
     * The fingerprint two users read to each other to confirm nobody is in the middle: 12 groups of
     * 5 digits separated by single spaces, **the same from either side**. It is built from both user
     * ids and every identity key of each, so it changes when a device is added or revoked or an
     * identity key changes — not on signed-prekey rotation or one-time-key use. `1001` for a blank
     * peer; `1002` when either side has no devices published.
     *
     * 两端互读核对的指纹：12 组 5 位数字、单个空格分隔，两边算出来一样。增删设备或身份公钥变更时改变，轮换签名预密钥或消耗一次性预密钥不变。
     */
    public suspend fun safetyNumber(request: SafetyNumberRequest): String =
        connection.request("keys.safetyNumber", request.asBody())

    /** [safetyNumber] for the one-field case. */
    public suspend fun safetyNumber(peerUserId: String): String = safetyNumber(SafetyNumberRequest(peerUserId))
}
