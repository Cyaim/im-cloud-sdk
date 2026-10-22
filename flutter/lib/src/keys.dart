/// `keys.publish` / `keys.upload` / `keys.remaining` / `keys.claim` / `keys.devices` /
/// `keys.revoke` / `keys.safetyNumber` — the end-to-end-encryption key directory. [ImKeysApi] sends
/// them; this file holds their request and reply types.
///
/// **This package performs no cryptography.** It stores nothing and computes nothing: every key,
/// prekey and signature here is an opaque string the application's own crypto library produced, in
/// **standard base64** (base64url is refused), and it goes out and comes back **unchanged** — the
/// server compares identity keys by exact string equality and the safety number hashes the strings,
/// so re-encoding one (padding, alphabet, a leading `0x05`) is a different key. Do not log them.
///
/// **No event follows any of these calls.** A device being revoked, an identity key changing, or a
/// one-time pool running low push nothing; a client sees them by calling `keys.devices`,
/// `keys.safetyNumber` or `keys.remaining` again.
///
/// **No add-on, plan or app setting gates the directory**, `e2ee.enabled` included: these calls work
/// whether or not the app has end-to-end encryption switched on.
///
/// 端到端加密的密钥目录。本包不做任何加密运算：密钥、预密钥、签名都是应用自己的加密库产出的不透明字符串
/// （标准 base64，不收 base64url），原样发出、原样收回——服务端按字符串逐字比较身份密钥，安全码也是对字符串
/// 做哈希，所以换一种编码就是另一把密钥。不要把它们写进日志。这些调用之后都没有推送事件；也不受任何增值项、
/// 套餐或应用设置（包括 e2ee.enabled）约束。
library;

import 'api.dart' show ImKeysApi;
import 'json.dart';
import 'protocol.dart';
import 'requests.dart';

// ---------------------------------------------------------------------------- key material

/// A signed prekey: the medium-term key a peer's first message is built on, signed by the identity
/// key. The server's `SignedPreKey`.
///
/// Its members are matched **case-sensitively** by the server (it is a nested object), and [keyId],
/// [publicKey] and [signature] are required there — which is why this type always sends all three.
///
/// 嵌套对象：服务端按大小写精确匹配成员名，keyId / publicKey / signature 在服务端是必填的。
class ImSignedPreKey implements ImRequestBody {
  const ImSignedPreKey({
    required this.keyId,
    required this.publicKey,
    required this.signature,
    this.createdAt,
  });

  factory ImSignedPreKey.fromJson(Map<String, dynamic> json) => ImSignedPreKey(
        keyId: imStringOr(json['keyId']),
        publicKey: imStringOr(json['publicKey']),
        signature: imStringOr(json['signature']),
        createdAt: imInt(json['createdAt']),
      );

  /// The application's own id for this prekey, so a peer's first message can say which one it used.
  final String keyId;

  /// Standard base64. Decoded, 1 to 128 bytes.
  final String publicKey;

  /// Standard base64: the identity key's signature over the **decoded bytes of [publicKey]** — not
  /// over [keyId] or [createdAt]. Decoded, 1 to 96 bytes. The server verifies it against
  /// [ImPublishKeysRequest.identityKey] with the algorithm's scheme (XEdDSA, Ed25519 or ECDSA P-256).
  /// 身份密钥对 publicKey 解码后字节的签名（不含 keyId、createdAt）；服务端按算法验签。
  final String signature;

  /// Unix ms. Null (left out) or 0 means "now" when publishing; always set in a claimed bundle.
  final int? createdAt;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'keyId': keyId,
        'publicKey': publicKey,
        'signature': signature,
        'createdAt': createdAt,
      });
}

/// A one-time prekey: used for one first contact, then gone. The server's `OneTimePreKey`.
///
/// Nested, so matched case-sensitively; both members are required by the server.
class ImOneTimePreKey implements ImRequestBody {
  const ImOneTimePreKey({required this.keyId, required this.publicKey});

  factory ImOneTimePreKey.fromJson(Map<String, dynamic> json) => ImOneTimePreKey(
        keyId: imStringOr(json['keyId']),
        publicKey: imStringOr(json['publicKey']),
      );

  /// Unique within one call. A blank one, one containing U+001F, or a repeat within the call is
  /// **dropped silently** by the server, as is a [publicKey] that is not valid base64.
  /// 空的、含 U+001F 的、同一次调用里重复的 keyId，以及不是合法 base64 的 publicKey，服务端都静默丢弃。
  final String keyId;

  /// Standard base64.
  final String publicKey;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'keyId': keyId, 'publicKey': publicKey};
}

// ---------------------------------------------------------------------------- keys.publish

/// `keys.publish`. The server's `PublishKeysRequest`: this device's identity key, its signed prekey,
/// and (optionally) a first batch of one-time prekeys.
///
/// **The device and platform are the connection's.** The server overwrites both from the session,
/// so this type has no member for them: a device can publish only its own keys.
///
/// **Publishing again replaces** the identity key, the signed prekey, the algorithm and the publish
/// time, and **keeps the one-time pool**, appending [oneTimePreKeys] to it — unless [identityKey]
/// changed, in which case the old pool is deleted first (its keys belong to the old identity).
/// Rotating the signed prekey is therefore a publish with the same identity key and no one-time keys.
///
/// **Rules:** a blank [identityKey] is `1001` ("identityKey is required"), a blank signed prekey
/// `1001` ("signedPreKey is required"); an [algorithm] the server does not know is `1008`. The
/// identity key must suit the algorithm (Curve25519 / Ed25519: 32 bytes, or 33 with a leading 0x05;
/// P-256: at least 33) — `1001` "identityKey is not valid for this algorithm" — and the signature
/// must verify — `1001` "signedPreKey signature does not verify against identityKey". More than 100
/// one-time keys in one call is `1001`; an 11th device for one user is `1202`.
///
/// **Limits:** 100 one-time keys a call; 100 kept per device (the oldest are kept, extra ones
/// trimmed); 10 devices a user; a device's keys are kept 180 days.
///
/// 设备与平台取自连接，本类型没有这两个成员。再次发布会替换身份密钥、签名预密钥、算法与发布时间，保留一次性
/// 密钥池并追加新的——除非身份密钥变了，那时旧池先被删掉。每次最多 100 个一次性密钥、每台设备最多存 100 个
/// （保留最早的）、每个用户最多 10 台设备（第 11 台 1202）、保留 180 天。
class ImPublishKeysRequest implements ImRequestBody {
  const ImPublishKeysRequest({
    required this.identityKey,
    required this.signedPreKey,
    this.oneTimePreKeys = const <ImOneTimePreKey>[],
    this.algorithm,
  });

  /// The server's default [algorithm], used when it is left out.
  static const String defaultAlgorithm = 'x3dh-curve25519-aes256gcm-v1';

  /// This device's long-lived public identity key, standard base64, at most 256 characters and 128
  /// decoded bytes. Changing it is a visible security event: the safety number changes.
  final String identityKey;

  final ImSignedPreKey signedPreKey;

  /// Up to 100. An empty list is left out of the frame — the server reads a missing list as empty.
  /// 空列表不发：服务端把缺省读作空列表。
  final List<ImOneTimePreKey> oneTimePreKeys;

  /// Null for [defaultAlgorithm]. The server reads the signature scheme off it by substring:
  /// `curve25519`, `x25519` or `xed25519` is XEdDSA; `ed25519` is Ed25519; `p256`, `p-256`,
  /// `secp256r1` or `prime256v1` is ECDSA P-256. Anything else is `1008`.
  final String? algorithm;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'identityKey': identityKey,
        'signedPreKey': signedPreKey.toJson(),
        'oneTimePreKeys': oneTimePreKeys.isEmpty
            ? null
            : <Map<String, Object?>>[
                for (final ImOneTimePreKey key in oneTimePreKeys) key.toJson(),
              ],
        'algorithm': algorithm,
      });
}

// ---------------------------------------------------------------------------- keys.upload

/// `keys.upload`. The server's `UploadOneTimeKeysRequest`: tops up **this device's** one-time pool.
///
/// It **appends**; the pool is capped at 100 per device (the oldest are kept). The device is the
/// connection's and cannot be named. An empty [keys] is `1001` ("keys is required"), a list in which
/// none survives the checks on [ImOneTimePreKey.keyId] `1001` ("no valid one-time prekeys
/// supplied"), more than 100 `1001`; a device that never published is `1002` ("device has not
/// published its identity key").
///
/// 追加到当前设备的一次性密钥池（每台最多 100 个，保留最早的）；设备取自连接，不能指定。没发布过的设备是 1002。
class ImUploadOneTimeKeysRequest implements ImRequestBody {
  const ImUploadOneTimeKeysRequest({required this.keys});

  final List<ImOneTimePreKey> keys;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'keys': <Map<String, Object?>>[for (final ImOneTimePreKey key in keys) key.toJson()],
      };
}

// ---------------------------------------------------------------------------- keys.remaining

/// `keys.remaining`. The server's `RemainingKeysRequest`.
///
/// The count is always looked up under the **caller's own** user, so [deviceId] can only name one of
/// the caller's devices; an unknown one answers 0, never an error.
class ImRemainingKeysRequest implements ImRequestBody {
  const ImRemainingKeysRequest({this.deviceId});

  /// Null (left out) or blank for the connected device — what a client asks about on every launch.
  final String? deviceId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{'deviceId': deviceId});
}

// ---------------------------------------------------------------------------- keys.claim

/// `keys.claim`. The server's `ClaimBundleRequest`: which of a peer's devices to open a session with.
///
/// Both members are required (`1001` "userId is required" / "deviceId is required"); neither
/// defaults to the caller. Take them from [ImDeviceKeyInfo] (`keys.devices`).
class ImClaimBundleRequest implements ImRequestBody {
  const ImClaimBundleRequest({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'userId': userId, 'deviceId': deviceId};
}

/// What `keys.claim` answers: everything needed to open a session with one device. The server's
/// `PreKeyBundle`.
///
/// **Claiming consumed [oneTimePreKey]** — the server removed it from the device's pool as it handed
/// it out (oldest first), so `keys.remaining` on that device dropped by one. When the pool was
/// already empty the claim still succeeds and [oneTimePreKey] is **null**: open the session from the
/// signed prekey alone.
///
/// 领取时一次性密钥已被取走（先进先出），对方的余量减一。池子空了照样成功，此时 oneTimePreKey 为 null。
class ImPreKeyBundle {
  const ImPreKeyBundle({
    required this.userId,
    required this.deviceId,
    required this.identityKey,
    required this.signedPreKey,
    this.oneTimePreKey,
    required this.algorithm,
  });

  factory ImPreKeyBundle.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? oneTime = imMapOrNull(json['oneTimePreKey']);
    return ImPreKeyBundle(
      userId: imStringOr(json['userId']),
      deviceId: imStringOr(json['deviceId']),
      identityKey: imStringOr(json['identityKey']),
      signedPreKey: ImSignedPreKey.fromJson(imMap(json['signedPreKey'])),
      oneTimePreKey: oneTime == null ? null : ImOneTimePreKey.fromJson(oneTime),
      algorithm: imStringOr(json['algorithm']),
    );
  }

  final String userId;
  final String deviceId;

  /// The device's identity key, exactly as it published it.
  final String identityKey;

  final ImSignedPreKey signedPreKey;

  /// Null when the device's pool was empty — the server leaves the member out.
  final ImOneTimePreKey? oneTimePreKey;

  /// As the device published it.
  final String algorithm;
}

// ---------------------------------------------------------------------------- keys.devices

/// `keys.devices`. The server's `DeviceKeysRequest`.
class ImDeviceKeysRequest implements ImRequestBody {
  const ImDeviceKeysRequest({this.userId});

  /// Whose devices. Null (left out) or blank for the caller's own — a "linked devices" screen.
  final String? userId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{'userId': userId});
}

/// One device a user has keys published for. The server's `DeviceKeyInfo`. There is no signed
/// prekey here; `keys.claim` hands that out.
class ImDeviceKeyInfo {
  const ImDeviceKeyInfo({
    required this.deviceId,
    this.platform = ImPlatform.unknown,
    required this.identityKey,
    required this.publishedAt,
    this.remainingOneTimeKeys = 0,
  });

  factory ImDeviceKeyInfo.fromJson(Map<String, dynamic> json) => ImDeviceKeyInfo(
        deviceId: imStringOr(json['deviceId']),
        platform: ImPlatform(imIntOr(json['platform'])),
        identityKey: imStringOr(json['identityKey']),
        publishedAt: imIntOr(json['publishedAt']),
        remainingOneTimeKeys: imIntOr(json['remainingOneTimeKeys']),
      );

  final String deviceId;

  /// The platform of the connection that published, as the server recorded it.
  final ImPlatform platform;

  final String identityKey;

  /// Unix ms of the last `keys.publish`.
  final int publishedAt;

  /// One-time prekeys left in the device's pool.
  final int remainingOneTimeKeys;
}

// ---------------------------------------------------------------------------- keys.revoke

/// `keys.revoke`. The server's `RevokeDeviceRequest`: forget one of the **caller's own** devices'
/// keys, so nobody opens a new session with it.
///
/// [deviceId] is required (`1001` "deviceId is required") and never defaults to the connected
/// device, though revoking the connected device is allowed. The id is resolved under the caller's
/// own user, so it can only ever revoke the caller's own devices. Revoking an unknown device
/// **succeeds**. Afterwards a claim on it is `1002`, it is gone from `keys.devices`, and the safety
/// number changes; no event says so, and existing sessions are the clients' business.
///
/// 只能吊销调用者自己的设备；deviceId 必填、不默认成当前设备（但吊销当前设备是允许的）。吊销不存在的设备照样成功。
class ImRevokeDeviceRequest implements ImRequestBody {
  const ImRevokeDeviceRequest({required this.deviceId});

  final String deviceId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'deviceId': deviceId};
}

// ---------------------------------------------------------------------------- keys.safetyNumber

/// `keys.safetyNumber`. The server's `SafetyNumberRequest`.
class ImSafetyNumberRequest implements ImRequestBody {
  const ImSafetyNumberRequest({required this.peerUserId});

  /// Required (`1001` "peerUserId is required"). The caller's own id is allowed.
  final String peerUserId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'peerUserId': peerUserId};
}
