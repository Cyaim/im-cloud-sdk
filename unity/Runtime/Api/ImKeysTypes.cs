using System;
using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- the rule
    //
    // keys.* is the end-to-end encryption key directory: each device publishes its PUBLIC keys, and a
    // sender fetches a peer's to open a session (X3DH-style: identity key, signed prekey, one-time
    // prekeys). This SDK stores and transports keys; it performs no cryptography. Every key, prekey and
    // signature below is an opaque string the game produced with its own crypto library, in standard
    // base64 (not base64url), and it goes out and comes back unchanged: the server compares identity
    // keys by exact string equality and hashes the strings themselves into the safety number, so a
    // re-encoded key reads as a different key. Nothing here ever holds a private key, and the SDK does
    // not write key material to any log (the Verbose frame trace elides keys.* bodies).
    // keys.* 是端到端加密的密钥目录：每台设备发布自己的公钥，发送方取对方的公钥建立会话。SDK 只存取与搬运密钥，
    // 不做任何加密运算：这里每个密钥、预密钥与签名都是游戏用自己的加密库算出的不透明字符串（标准 base64，不是 base64url），
    // 原样发出、原样读回。服务端按字符串逐字比较身份公钥、并把字符串本身散列进安全码，任何重新编码都会被读成另一把钥匙。
    // 这里不持有私钥，SDK 也不把密钥材料写进任何日志（Verbose 帧追踪对 keys.* 的请求体与答复一律省略）。

    // ---------------------------------------------------------------------- shared members

    /// <summary>
    /// A signed prekey, as <c>keys.publish</c> sends it and <c>keys.claim</c> returns it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A nested object, so its names are matched case-sensitively by the socket binder, and the
    /// first three are required there</b>: a body without one of them fails to bind and the whole call
    /// answers <c>1000</c>. This type always writes all four, and
    /// <see cref="ImKeysApi.PublishAsync"/> refuses a null one before sending.
    /// </para>
    /// <para>
    /// <see cref="Signature"/> is the identity key's signature over the <b>decoded bytes of
    /// <see cref="PublicKey"/> only</b> — not over <see cref="KeyId"/> or <see cref="CreatedAt"/>. The
    /// server verifies it with the scheme <see cref="ImPublishKeysRequest.Algorithm"/> names.
    /// 嵌套对象：服务端按大小写精确匹配，前三个成员必填，缺一个整次调用就是 1000。签名只覆盖 PublicKey 解码后的字节。
    /// </para>
    /// </remarks>
    public sealed class ImSignedPreKey : IImJsonPayload
    {
        /// <summary>The game's own id for this prekey. Required.</summary>
        public string KeyId { get; set; }

        /// <summary>Standard base64; 1–128 bytes decoded. Required.</summary>
        public string PublicKey { get; set; }

        /// <summary>
        /// Standard base64 of the identity key's signature over the decoded bytes of
        /// <see cref="PublicKey"/>; 1–96 bytes decoded. Required.
        /// </summary>
        public string Signature { get; set; }

        /// <summary>Unix ms. 0 (the default) means "now": the server stamps it.</summary>
        public long CreatedAt { get; set; }

        /// <inheritdoc cref="ImSignedPreKey"/>
        public ImSignedPreKey()
        {
        }

        /// <inheritdoc cref="ImSignedPreKey"/>
        public ImSignedPreKey(string keyId, string publicKey, string signature, long createdAt = 0)
        {
            KeyId = keyId;
            PublicKey = publicKey;
            Signature = signature;
            CreatedAt = createdAt;
        }

        internal JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("keyId", KeyId)
                .Set("publicKey", PublicKey)
                .Set("signature", Signature)
                .Set("createdAt", CreatedAt);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            KeyId = json["keyId"].AsString(string.Empty);
            PublicKey = json["publicKey"].AsString(string.Empty);
            Signature = json["signature"].AsString(string.Empty);
            CreatedAt = json["createdAt"].AsLong();
        }
    }

    /// <summary>
    /// A one-time prekey: handed out once by <c>keys.claim</c>, then gone.
    /// </summary>
    /// <remarks>
    /// Both names are case-sensitive and required on the server (a missing one is <c>1000</c> for the
    /// whole call). An entry with a blank <see cref="KeyId"/>, a <see cref="KeyId"/> containing
    /// U+001F, a <see cref="PublicKey"/> that is not standard base64, or a <see cref="KeyId"/> repeated
    /// within one call is <b>dropped without an error</b>.
    /// 两个成员都区分大小写且必填；keyId 为空、含 U+001F、publicKey 不是 base64、或同一次调用里 keyId 重复的条目被静默丢弃。
    /// </remarks>
    public sealed class ImOneTimePreKey : IImJsonPayload
    {
        /// <summary>The game's own id for this key. Required.</summary>
        public string KeyId { get; set; }

        /// <summary>Standard base64. Required.</summary>
        public string PublicKey { get; set; }

        /// <inheritdoc cref="ImOneTimePreKey"/>
        public ImOneTimePreKey()
        {
        }

        /// <inheritdoc cref="ImOneTimePreKey"/>
        public ImOneTimePreKey(string keyId, string publicKey)
        {
            KeyId = keyId;
            PublicKey = publicKey;
        }

        internal JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("keyId", KeyId)
                .Set("publicKey", PublicKey);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            KeyId = json["keyId"].AsString(string.Empty);
            PublicKey = json["publicKey"].AsString(string.Empty);
        }

        internal static JsonValue ArrayOf(IEnumerable<ImOneTimePreKey> keys)
        {
            var array = JsonValue.NewArray();
            if (keys != null)
            {
                foreach (var key in keys)
                {
                    array.Add(key.ToJson());
                }
            }

            return array;
        }

        /// <summary>
        /// Throws unless every entry and both of its members are present — an absent member is
        /// <c>1000</c> for the whole call, where an empty one is the server's to drop.
        /// </summary>
        internal static void RequireAll(IEnumerable<ImOneTimePreKey> keys, string name)
        {
            if (keys == null)
            {
                return;
            }

            var index = 0;
            foreach (var key in keys)
            {
                if (key == null || key.KeyId == null || key.PublicKey == null)
                {
                    throw new ArgumentException(
                        name + "[" + index + "] needs a keyId and a publicKey: the server requires both members, and a body without one fails to bind (1000)",
                        name);
                }

                index++;
            }
        }
    }

    // ---------------------------------------------------------------------- requests

    /// <summary>
    /// <c>keys.publish</c>: this device's identity key, its signed prekey and, optionally, a first
    /// batch of one-time prekeys.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>No device id and no platform.</b> The server's <c>PublishKeysRequest</c> declares both, and
    /// overwrites them with the connection's: a device can only ever publish for itself. They are not
    /// on this type.
    /// </para>
    /// <para>
    /// <b>A re-publish replaces</b> <see cref="IdentityKey"/>, <see cref="SignedPreKey"/>,
    /// <see cref="Algorithm"/> and the publish time, and <b>keeps the one-time pool</b>, appending
    /// <see cref="OneTimePreKeys"/> to it — unless <see cref="IdentityKey"/> changed, in which case the
    /// old pool is deleted first (its keys belong to the old identity).
    /// </para>
    /// <para>
    /// Refusals: <c>1001</c> "identityKey is not valid for this algorithm" (Curve25519 / Ed25519: 32
    /// decoded bytes, or 33 with a leading <c>0x05</c>; P-256: at least 33); <c>1001</c> "signedPreKey is
    /// incomplete" (decoded public key 1–128 bytes, signature 1–96); <c>1001</c> "signedPreKey signature
    /// does not verify against identityKey"; <c>1001</c> for more than 100 one-time prekeys;
    /// <c>1008</c> for an <see cref="Algorithm"/> the server cannot classify; <c>1202 QuotaExceeded</c>
    /// for an eleventh device of the same user. A device's keys expire 180 days after its last publish
    /// or upload.
    /// 没有设备与平台字段：服务端用连接上的值覆盖。重新发布替换身份公钥、签名预密钥、算法与发布时间，保留一次性池并追加新键；
    /// 身份公钥变了则先清掉旧池。
    /// </para>
    /// </remarks>
    public sealed class ImPublishKeysRequest : IImRequest
    {
        /// <summary>The device's long-lived public identity key, standard base64, at most 256 characters. Required.</summary>
        public string IdentityKey { get; set; }

        /// <summary>The current signed prekey. Required, with its first three members.</summary>
        public ImSignedPreKey SignedPreKey { get; set; }

        /// <summary>
        /// An optional first batch, at most 100 per call; the pool holds at most 100 per device and keeps
        /// the oldest. Never null on a new request; always sent, empty when there are none.
        /// </summary>
        public List<ImOneTimePreKey> OneTimePreKeys { get; set; }

        /// <summary>
        /// The key-agreement suite. Null (not sent) leaves the server's default,
        /// <c>"x3dh-curve25519-aes256gcm-v1"</c>. The server reads the signature scheme off this name:
        /// <c>curve25519</c> / <c>x25519</c> / <c>xed25519</c> mean XEdDSA, <c>ed25519</c> Ed25519,
        /// <c>p256</c> / <c>p-256</c> / <c>secp256r1</c> / <c>prime256v1</c> ECDSA P-256; anything else is
        /// <c>1008</c>.
        /// </summary>
        public string Algorithm { get; set; }

        /// <inheritdoc cref="ImPublishKeysRequest"/>
        public ImPublishKeysRequest()
        {
            OneTimePreKeys = new List<ImOneTimePreKey>();
        }

        /// <inheritdoc cref="ImPublishKeysRequest"/>
        public ImPublishKeysRequest(string identityKey, ImSignedPreKey signedPreKey, params ImOneTimePreKey[] oneTimePreKeys)
        {
            IdentityKey = identityKey;
            SignedPreKey = signedPreKey;
            OneTimePreKeys = new List<ImOneTimePreKey>(oneTimePreKeys ?? new ImOneTimePreKey[0]);
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject().Set("identityKey", IdentityKey);
            if (SignedPreKey != null)
            {
                body.Set("signedPreKey", SignedPreKey.ToJson());
            }

            return body
                .Set("oneTimePreKeys", ImOneTimePreKey.ArrayOf(OneTimePreKeys))
                .Set("algorithm", Algorithm);
        }
    }

    /// <summary>
    /// <c>keys.upload</c>: tops up the <b>connected</b> device's one-time pool. The device cannot be
    /// named. Appends; the pool is capped at 100 per device, keeping the oldest.
    /// </summary>
    /// <remarks>
    /// <c>1001</c> "keys is required" for an empty list, "no valid one-time prekeys supplied" when every
    /// entry was dropped (see <see cref="ImOneTimePreKey"/>), or for more than 100; <c>1002</c> "device
    /// has not published its identity key" before this device's first <c>keys.publish</c>.
    /// 只能给当前连接的设备补充一次性预密钥；追加，每台设备最多保留 100 把（留最早的）。
    /// </remarks>
    public sealed class ImUploadOneTimeKeysRequest : IImRequest
    {
        /// <summary>The keys to append, 1–100. Required.</summary>
        public List<ImOneTimePreKey> Keys { get; set; }

        /// <inheritdoc cref="ImUploadOneTimeKeysRequest"/>
        public ImUploadOneTimeKeysRequest()
        {
            Keys = new List<ImOneTimePreKey>();
        }

        /// <inheritdoc cref="ImUploadOneTimeKeysRequest"/>
        public ImUploadOneTimeKeysRequest(params ImOneTimePreKey[] keys)
        {
            Keys = new List<ImOneTimePreKey>(keys ?? new ImOneTimePreKey[0]);
        }

        /// <inheritdoc cref="ImUploadOneTimeKeysRequest"/>
        public ImUploadOneTimeKeysRequest(IEnumerable<ImOneTimePreKey> keys)
        {
            Keys = keys != null ? new List<ImOneTimePreKey>(keys) : new List<ImOneTimePreKey>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("keys", ImOneTimePreKey.ArrayOf(Keys));
        }
    }

    /// <summary>
    /// <c>keys.remaining</c>: how many one-time prekeys one of the caller's <b>own</b> devices has left.
    /// </summary>
    /// <remarks>
    /// <see cref="DeviceId"/> null (not sent) means the connected device. The count is always looked up
    /// under the caller's own user, so an unknown device answers 0, never an error.
    /// </remarks>
    public sealed class ImRemainingKeysRequest : IImRequest
    {
        /// <summary>One of the caller's own devices; null for the connected one.</summary>
        public string DeviceId { get; set; }

        /// <inheritdoc cref="ImRemainingKeysRequest"/>
        public ImRemainingKeysRequest()
        {
        }

        /// <inheritdoc cref="ImRemainingKeysRequest"/>
        public ImRemainingKeysRequest(string deviceId)
        {
            DeviceId = deviceId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("deviceId", DeviceId);
        }
    }

    /// <summary>
    /// <c>keys.claim</c>: the bundle for one device of a user. Both members are required and neither
    /// defaults to the caller. <b>Not idempotent — it consumes</b>; see <see cref="ImKeysApi.ClaimAsync(ImClaimBundleRequest, System.Threading.CancellationToken)"/>.
    /// </summary>
    public sealed class ImClaimBundleRequest : IImRequest
    {
        /// <summary>Whose device. Required.</summary>
        public string UserId { get; set; }

        /// <summary>Which device, as <c>keys.devices</c> lists it. Required.</summary>
        public string DeviceId { get; set; }

        /// <inheritdoc cref="ImClaimBundleRequest"/>
        public ImClaimBundleRequest()
        {
        }

        /// <inheritdoc cref="ImClaimBundleRequest"/>
        public ImClaimBundleRequest(string userId, string deviceId)
        {
            UserId = userId;
            DeviceId = deviceId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("userId", UserId)
                .Set("deviceId", DeviceId);
        }
    }

    /// <summary><c>keys.devices</c>: whose devices to list. <see cref="UserId"/> null (not sent) means the caller's own.</summary>
    public sealed class ImDeviceKeysRequest : IImRequest
    {
        /// <summary>The user; null for the caller.</summary>
        public string UserId { get; set; }

        /// <inheritdoc cref="ImDeviceKeysRequest"/>
        public ImDeviceKeysRequest()
        {
        }

        /// <inheritdoc cref="ImDeviceKeysRequest"/>
        public ImDeviceKeysRequest(string userId)
        {
            UserId = userId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("userId", UserId);
        }
    }

    /// <summary>
    /// <c>keys.revoke</c>: one of the caller's <b>own</b> devices, by id.
    /// </summary>
    /// <remarks>
    /// Required, and never defaulted to the connected device — revoking this one is allowed, by naming
    /// it. An id the caller does not have <b>succeeds</b> and changes nothing.
    /// 设备 id 必填，不会默认成当前设备；吊销不存在的设备照样成功。
    /// </remarks>
    public sealed class ImRevokeDeviceRequest : IImRequest
    {
        /// <summary>Which of the caller's devices. Required.</summary>
        public string DeviceId { get; set; }

        /// <inheritdoc cref="ImRevokeDeviceRequest"/>
        public ImRevokeDeviceRequest()
        {
        }

        /// <inheritdoc cref="ImRevokeDeviceRequest"/>
        public ImRevokeDeviceRequest(string deviceId)
        {
            DeviceId = deviceId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("deviceId", DeviceId);
        }
    }

    /// <summary><c>keys.safetyNumber</c>: the user to compare with. Required; the caller's own id is allowed.</summary>
    public sealed class ImSafetyNumberRequest : IImRequest
    {
        /// <summary>The other party. Required.</summary>
        public string PeerUserId { get; set; }

        /// <inheritdoc cref="ImSafetyNumberRequest"/>
        public ImSafetyNumberRequest()
        {
        }

        /// <inheritdoc cref="ImSafetyNumberRequest"/>
        public ImSafetyNumberRequest(string peerUserId)
        {
            PeerUserId = peerUserId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("peerUserId", PeerUserId);
        }
    }

    // ---------------------------------------------------------------------- payloads

    /// <summary>What <c>keys.claim</c> answers: everything needed to open a session with one device.</summary>
    /// <remarks>
    /// <see cref="OneTimePreKey"/> is <b>null when the device's pool was empty</b> — the claim still
    /// succeeds (the server omits the member), and the session is opened without one: X3DH allows it,
    /// with weaker forward secrecy for the first message.
    /// 池子空了照样成功，OneTimePreKey 为 null（服务端省略该成员）。
    /// </remarks>
    public sealed class ImPreKeyBundle : IImJsonPayload
    {
        /// <summary>Whose device.</summary>
        public string UserId { get; private set; }

        /// <summary>Which device.</summary>
        public string DeviceId { get; private set; }

        /// <summary>The device's identity key, exactly as it was published.</summary>
        public string IdentityKey { get; private set; }

        /// <summary>The device's current signed prekey. Never null.</summary>
        public ImSignedPreKey SignedPreKey { get; private set; }

        /// <summary>The one-time prekey this claim consumed; null when the pool was empty.</summary>
        public ImOneTimePreKey OneTimePreKey { get; private set; }

        /// <summary>The key-agreement suite the device published with.</summary>
        public string Algorithm { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            UserId = json["userId"].AsString(string.Empty);
            DeviceId = json["deviceId"].AsString(string.Empty);
            IdentityKey = json["identityKey"].AsString(string.Empty);
            SignedPreKey = ImPayload.Read<ImSignedPreKey>(json["signedPreKey"]);
            OneTimePreKey = json["oneTimePreKey"].IsObject ? ImPayload.Read<ImOneTimePreKey>(json["oneTimePreKey"]) : null;
            Algorithm = json["algorithm"].AsString(string.Empty);
        }
    }

    /// <summary>
    /// One device with published keys, as <c>keys.devices</c> lists it. There is no signed prekey here;
    /// <c>keys.claim</c> has it.
    /// </summary>
    public sealed class ImDeviceKeyInfo : IImJsonPayload
    {
        /// <summary>The device.</summary>
        public string DeviceId { get; private set; }

        /// <summary>
        /// The platform of the connection that last published — an integer on the wire. A value this
        /// build does not name (the server's <c>Server</c> is 100) keeps its number.
        /// </summary>
        public ImPlatform Platform { get; private set; }

        /// <summary>The device's identity key, exactly as it was published.</summary>
        public string IdentityKey { get; private set; }

        /// <summary>Unix ms of the last <c>keys.publish</c>.</summary>
        public long PublishedAt { get; private set; }

        /// <summary>One-time prekeys left in the device's pool.</summary>
        public int RemainingOneTimeKeys { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            DeviceId = json["deviceId"].AsString(string.Empty);
            Platform = (ImPlatform)json["platform"].AsInt();
            IdentityKey = json["identityKey"].AsString(string.Empty);
            PublishedAt = json["publishedAt"].AsLong();
            RemainingOneTimeKeys = json["remainingOneTimeKeys"].AsInt();
        }
    }
}
