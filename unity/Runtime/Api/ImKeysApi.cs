using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>keys.*</c> — the end-to-end encryption key directory (T4): publishing this device's public
    /// keys, fetching a peer's so a session can be opened, and the safety number two players compare.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The SDK performs no cryptography.</b> It moves opaque, standard-base64 strings the game's own
    /// crypto library produced, unchanged, and never logs them (the Verbose frame trace elides
    /// <c>keys.*</c> bodies). Generating key pairs, signing the signed prekey, verifying a claimed
    /// bundle, running X3DH and encrypting messages are the game's; no private key can cross this
    /// surface. See <see cref="ImPublishKeysRequest"/> for the encodings.
    /// </para>
    /// <para>
    /// <b>Writes speak only for the connected device</b> (<c>publish</c>, <c>upload</c>); reads name
    /// their target; <c>revoke</c> names a device but resolves it under the caller's own user.
    /// <b>Callable whether or not the app's <c>e2ee.enabled</c> is set</b> — that switch constrains
    /// settings writes and translation, not the directory, so there is no <c>1203</c> / <c>1204</c>
    /// here. <b>No event is pushed</b> for a revoked device, a changed identity key or a pool running
    /// low: ask <see cref="RemainingAsync"/> on launch, and re-read <see cref="DevicesAsync"/> /
    /// <see cref="SafetyNumberAsync(ImSafetyNumberRequest, CancellationToken)"/> when it matters.
    /// </para>
    /// <para>
    /// SDK 不做任何加密运算，只原样搬运游戏自己算出的标准 base64 字符串，也不记录它们。写操作只能替当前连接的设备说话，
    /// 读操作在请求体里点名目标。不论 e2ee.enabled 开没开都能调用；吊销、身份变更、池子见底都不推送事件。
    /// </para>
    /// </remarks>
    public sealed class ImKeysApi : ImApiNamespace
    {
        internal ImKeysApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Publishes this device's identity key and signed prekey, with an optional first batch of
        /// one-time prekeys. Call it at a device's first login and whenever the game rotates its signed
        /// prekey.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>Replaces</b> identity key, signed prekey, algorithm and publish time; <b>keeps</b> the
        /// one-time pool and appends to it (a changed identity key deletes the old pool first). The
        /// device and platform are the connection's. Every refusal is listed on
        /// <see cref="ImPublishKeysRequest"/>.
        /// </para>
        /// <para>
        /// A blank <see cref="ImPublishKeysRequest.IdentityKey"/> or
        /// <see cref="ImSignedPreKey.PublicKey"/>, and a null member of the signed prekey or of a
        /// one-time prekey, are refused before sending: the first two are the server's <c>1001</c>, the
        /// rest a body that fails to bind (<c>1000</c>).
        /// 替换身份公钥、签名预密钥与算法，保留一次性池并追加；设备与平台取自连接。
        /// </para>
        /// </remarks>
        public Task PublishAsync(
            ImPublishKeysRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.IdentityKey, "identityKey");
            if (request.SignedPreKey == null)
            {
                throw new ArgumentException("signedPreKey is required", "request");
            }

            Require(request.SignedPreKey.PublicKey, "signedPreKey.publicKey");
            RequirePresent(request.SignedPreKey.KeyId, "signedPreKey.keyId");
            RequirePresent(request.SignedPreKey.Signature, "signedPreKey.signature");
            ImOneTimePreKey.RequireAll(request.OneTimePreKeys, "oneTimePreKeys");
            return ExecuteAsync("keys.publish", request, cancellationToken);
        }

        /// <summary>
        /// Appends one-time prekeys to the connected device's pool — at most 100 per call, 100 held.
        /// Call it when <see cref="RemainingAsync"/> runs low.
        /// </summary>
        /// <remarks>
        /// <c>1002</c> before this device has published; <c>1001</c> when no key was valid. An empty
        /// list, and a null entry or member, are refused before sending.
        /// </remarks>
        public Task UploadAsync(
            ImUploadOneTimeKeysRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            if (request.Keys == null || request.Keys.Count == 0)
            {
                throw new ArgumentException("keys is required", "request");
            }

            ImOneTimePreKey.RequireAll(request.Keys, "keys");
            return ExecuteAsync("keys.upload", request, cancellationToken);
        }

        /// <summary>
        /// One-time prekeys left on one of the caller's own devices — the connected one when
        /// <paramref name="request"/> or its <see cref="ImRemainingKeysRequest.DeviceId"/> is null.
        /// A bare number.
        /// </summary>
        /// <remarks>
        /// An unknown device is 0, not an error. Nothing is pushed when the pool runs low (the server
        /// only logs it at 20); ask on launch.
        /// 未知设备回 0，不报错。池子见底不推送，启动时自己查。
        /// </remarks>
        public async Task<int> RemainingAsync(
            ImRemainingKeysRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var data = await RequestAsync(
                    "keys.remaining",
                    request != null ? request : new ImRemainingKeysRequest(),
                    cancellationToken)
                .ConfigureAwait(false);
            return data.AsInt();
        }

        /// <summary>
        /// Fetches a bundle to open a session with one device of
        /// <see cref="ImClaimBundleRequest.UserId"/>.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>A write dressed as a read: it consumes one one-time prekey</b>, atomically and first-in
        /// first-out, so that device's <c>remaining</c> drops by one. <b>Never retry it as if it were
        /// idempotent, and never prefetch</b>: a call whose reply was lost (a <c>1004</c> timeout) may
        /// already have spent a key, and a retry spends the next; a prefetched bundle spends one a real
        /// first contact needed. Use a bundle for one session only. The SDK sends it exactly once.
        /// </para>
        /// <para>
        /// When the pool is empty the claim <b>still succeeds</b>, with
        /// <see cref="ImPreKeyBundle.OneTimePreKey"/> null. Claiming one's own device is allowed and
        /// drains one's own pool. <c>1002</c> "device has published no keys" (also for an unknown user,
        /// and after a revoke); <c>1005</c> when the directory is unavailable. A blank user or device id
        /// is refused before sending.
        /// 看起来是读，实质是写：每次领取原子地消耗一个一次性预密钥（先进先出）。不能当幂等请求重试，也不能预取。
        /// 池子空了照样成功，只是 OneTimePreKey 为 null。
        /// </para>
        /// </remarks>
        public Task<ImPreKeyBundle> ClaimAsync(
            ImClaimBundleRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            Require(request.DeviceId, "deviceId");
            return RequestAsync<ImPreKeyBundle>("keys.claim", request, cancellationToken);
        }

        /// <summary>
        /// Shorthand for <see cref="ClaimAsync(ImClaimBundleRequest, CancellationToken)"/>. Consumes a
        /// one-time prekey like it.
        /// </summary>
        public Task<ImPreKeyBundle> ClaimAsync(
            string userId,
            string deviceId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return ClaimAsync(new ImClaimBundleRequest(userId, deviceId), cancellationToken);
        }

        /// <summary>
        /// Every device of a user that has keys published — the caller's own when
        /// <paramref name="request"/> or its <see cref="ImDeviceKeysRequest.UserId"/> is null. A bare
        /// list, in no particular order: one ciphertext per device in it.
        /// </summary>
        /// <remarks>
        /// An unknown user is an empty list, not an error. No signed prekey here; claim has it.
        /// </remarks>
        public Task<List<ImDeviceKeyInfo>> DevicesAsync(
            ImDeviceKeysRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestListAsync<ImDeviceKeyInfo>(
                "keys.devices",
                request != null ? request : new ImDeviceKeysRequest(),
                cancellationToken);
        }

        /// <summary>
        /// Forgets one of the caller's own devices: its record, its pool, its place in
        /// <see cref="DevicesAsync"/>.
        /// </summary>
        /// <remarks>
        /// After it, a claim for that device is <c>1002</c> and both sides' safety numbers change;
        /// existing sessions are the clients' business, and <b>no event</b> tells peers. The id is
        /// required (refused before sending when blank; the server would answer <c>1001</c>) and never
        /// defaulted; an id the caller does not have <b>succeeds</b>. Revoking the connected device is
        /// allowed.
        /// 吊销调用者自己的一台设备。设备 id 必填、不会默认成当前设备；吊销不存在的设备照样成功。不推送任何事件。
        /// </remarks>
        public Task RevokeAsync(
            ImRevokeDeviceRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.DeviceId, "deviceId");
            return ExecuteAsync("keys.revoke", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="RevokeAsync(ImRevokeDeviceRequest, CancellationToken)"/>.</summary>
        public Task RevokeAsync(
            string deviceId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RevokeAsync(new ImRevokeDeviceRequest(deviceId), cancellationToken);
        }

        /// <summary>
        /// The fingerprint two players read to each other to confirm nobody is in the middle: 12 groups
        /// of 5 digits separated by single spaces, <b>the same from either side</b>. A bare string.
        /// </summary>
        /// <remarks>
        /// Built from both user ids and every identity key of each, so it changes when a device is added
        /// or revoked or an identity key changes — not on signed-prekey rotation or one-time-key use.
        /// <c>1002</c> when either side has nothing published. A blank peer is refused before sending;
        /// the caller's own id is allowed.
        /// 两端互读核对的指纹：12 组 5 位数字、单个空格分隔，两边算出来一样。增删设备或身份公钥变更时改变。
        /// </remarks>
        public async Task<string> SafetyNumberAsync(
            ImSafetyNumberRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.PeerUserId, "peerUserId");
            var data = await RequestAsync("keys.safetyNumber", request, cancellationToken).ConfigureAwait(false);
            return data.AsString(string.Empty);
        }

        /// <summary>Shorthand for <see cref="SafetyNumberAsync(ImSafetyNumberRequest, CancellationToken)"/>.</summary>
        public Task<string> SafetyNumberAsync(
            string peerUserId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return SafetyNumberAsync(new ImSafetyNumberRequest(peerUserId), cancellationToken);
        }

        /// <summary>Throws when a member the server requires is absent; an empty one is the server's to judge.</summary>
        private static void RequirePresent(string value, string name)
        {
            if (value == null)
            {
                throw new ArgumentException(
                    name + " is required: the server requires the member, and a body without it fails to bind (1000)",
                    name);
            }
        }
    }
}
