import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `keys.publish` / `keys.upload` / `keys.remaining` / `keys.claim` / `keys.devices` /
/// `keys.revoke` / `keys.safetyNumber` — the end-to-end-encryption key directory.
///
/// Every call is asserted on the whole frame it puts on the wire (with every member set, and
/// minimal), on what it makes of a reply with every member set, and on its refusals by code and
/// message. The rules a signature cannot say are asserted too: the nested key objects go out under
/// exact camelCase names (the server binds them case-sensitively and throws on a miss), key material
/// is passed through byte for byte, the device and platform are never sent (the server takes them
/// from the connection), a bundle from an empty pool decodes with no one-time key instead of
/// throwing, `remaining` / `devices` / `safetyNumber` read the server's bare number, array and
/// string, and no key material reaches the SDK's log. The full fixtures and bodies are held to
/// `endpoint-inventory.json`'s payloadTypes.
///
/// 每个调用断言整帧（全字段与最小）、全字段答复的解码、按码与原话的拒绝；另断言签名说不出的规则：嵌套的密钥
/// 对象按精确的 camelCase 发出（服务端区分大小写、名字对不上直接抛）、密钥材料原样透传、设备与平台从不发送
/// （服务端取自连接）、空池的密钥包解码为没有一次性密钥而不是抛错、remaining / devices / safetyNumber 读裸
/// 数字 / 数组 / 字符串、密钥材料不进 SDK 日志。全字段夹具与请求体对着 endpoint-inventory.json 钉住。
void main() {
  // Standard base64 with the characters base64url would change ('+', '/', '=' padding), so a client
  // that re-encoded anything would be caught by the whole-frame comparisons below.
  // 故意带上 base64url 会改写的字符（+ / 与 = 填充）：客户端若改写编码，整帧比较会抓到。
  const String identityKey = 'BXv+3Qk/9mZy0aB1c2d3e4f5g6h7i8j9k0l1m2n3o4p5';
  const String spkPublic = 'q+8/Zm9vYmFyYmF6cXV4cXV1eHF1dXhxdXV4cXV1eA==';
  const String spkSignature =
      'c2lnbmF0dXJl+/c2lnbmF0dXJlc2lnbmF0dXJlc2lnbmF0dXJlc2lnbmF0dXJlc2lnbmF0dXJlc2lnbmE=';
  const String otk1 = 'b3RrLTEtcHVibGlj+/a2V5LWJ5dGVzLWZvci10ZXN0aW5nIQ==';
  const String otk2 = 'b3RrLTItcHVibGlj+/a2V5LWJ5dGVzLWZvci10ZXN0aW5nIQ==';

  // Every member of the server's PreKeyBundle / SignedPreKey / OneTimePreKey / DeviceKeyInfo, each
  // with a value no default reads as, held to the inventory below.
  const Map<String, dynamic> signedPreKey = <String, dynamic>{
    'keyId': 'spk-7',
    'publicKey': spkPublic,
    'signature': spkSignature,
    'createdAt': 1755000300000,
  };

  const Map<String, dynamic> oneTimePreKey = <String, dynamic>{
    'keyId': 'otk-1',
    'publicKey': otk1,
  };

  const Map<String, dynamic> bundle = <String, dynamic>{
    'userId': 'bob',
    'deviceId': 'bob-phone',
    'identityKey': identityKey,
    'signedPreKey': signedPreKey,
    'oneTimePreKey': oneTimePreKey,
    'algorithm': 'x3dh-ed25519-aes256gcm-v1',
  };

  const Map<String, dynamic> device = <String, dynamic>{
    'deviceId': 'bob-phone',
    'platform': 2,
    'identityKey': identityKey,
    'publishedAt': 1755000300123,
    'remainingOneTimeKeys': 42,
  };

  const ImPublishKeysRequest fullPublish = ImPublishKeysRequest(
    identityKey: identityKey,
    signedPreKey: ImSignedPreKey(
      keyId: 'spk-7',
      publicKey: spkPublic,
      signature: spkSignature,
      createdAt: 1755000300000,
    ),
    oneTimePreKeys: <ImOneTimePreKey>[
      ImOneTimePreKey(keyId: 'otk-1', publicKey: otk1),
      ImOneTimePreKey(keyId: 'otk-2', publicKey: otk2),
    ],
    algorithm: 'x3dh-ed25519-aes256gcm-v1',
  );

  Matcher refusedWith(int code, [String? message]) => throwsA(isA<ImException>()
      .having((ImException e) => e.code, 'code', code)
      .having((ImException e) => e.message, 'message', message ?? isNotEmpty));

  group('keys.publish', () {
    test('sends every member, nested keys under exact camelCase names, key material unchanged, and '
        'no device or platform', () async {
      final FakeGateway gateway = FakeGateway()..on('keys.publish', (FakeRequest _) => const FakeData());
      final ImClient client = await connectedClient(gateway);

      await client.keys.publish(fullPublish);

      final Map<String, dynamic> body = gateway.requestsTo('keys.publish').single.body;
      expect(body, <String, dynamic>{
        'identityKey': identityKey,
        'signedPreKey': <String, dynamic>{
          'keyId': 'spk-7',
          'publicKey': spkPublic,
          'signature': spkSignature,
          'createdAt': 1755000300000,
        },
        'oneTimePreKeys': <Map<String, dynamic>>[
          <String, dynamic>{'keyId': 'otk-1', 'publicKey': otk1},
          <String, dynamic>{'keyId': 'otk-2', 'publicKey': otk2},
        ],
        'algorithm': 'x3dh-ed25519-aes256gcm-v1',
      });
      // The server overwrites both from the connection; sending them would only suggest otherwise.
      expect(body.containsKey('deviceId'), isFalse);
      expect(body.containsKey('platform'), isFalse);
      // createdAt is a JSON integer, not a quoted long: the nested binder does not coerce.
      expect((body['signedPreKey'] as Map<String, dynamic>)['createdAt'], isA<int>());

      await client.dispose();
    });

    test('a minimal publish sends the identity and the signed prekey only: no createdAt (now), no '
        'empty one-time list, no algorithm (the server default)', () async {
      final FakeGateway gateway = FakeGateway()..on('keys.publish', (FakeRequest _) => const FakeData());
      final ImClient client = await connectedClient(gateway);

      await client.keys.publish(const ImPublishKeysRequest(
        identityKey: identityKey,
        signedPreKey: ImSignedPreKey(keyId: 'spk-1', publicKey: spkPublic, signature: spkSignature),
      ));

      expect(gateway.requestsTo('keys.publish').single.body, <String, dynamic>{
        'identityKey': identityKey,
        'signedPreKey': <String, dynamic>{
          'keyId': 'spk-1',
          'publicKey': spkPublic,
          'signature': spkSignature,
        },
      });
      expect(ImPublishKeysRequest.defaultAlgorithm, 'x3dh-curve25519-aes256gcm-v1');

      await client.dispose();
    });

    test('surfaces the publish refusals by code and message', () async {
      const List<(int, String)> refusals = <(int, String)>[
        (1001, 'identityKey is required'),
        (1001, 'signedPreKey is required'),
        (1001, 'identityKey is not valid for this algorithm'),
        (1001, 'signedPreKey is incomplete'),
        (1001, 'signedPreKey signature does not verify against identityKey'),
        (1001, 'at most 100 one-time prekeys per call'),
        (1008, "unknown algorithm 'x3dh-rsa-v1'"),
        (1202, 'a user may publish at most 10 devices'),
      ];
      final FakeGateway gateway = FakeGateway()
        ..script('keys.publish', <FakeReply>[
          for (final (int code, String message) in refusals) FakeFail(code, message: message),
        ]);
      final ImClient client = await connectedClient(gateway);

      for (final (int code, String message) in refusals) {
        await expectLater(client.keys.publish(fullPublish), refusedWith(code, message));
      }
      expect(ImErrorCode.unsupportedOperation, 1008);
      expect(ImErrorCode.quotaExceeded, 1202);

      await client.dispose();
    });
  });

  group('keys.upload', () {
    test('sends the keys under exact camelCase names and surfaces its refusals', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('keys.upload', const <FakeReply>[
          FakeData(),
          FakeFail(ImErrorCode.invalidArgument, message: 'keys is required'),
          FakeFail(ImErrorCode.invalidArgument, message: 'no valid one-time prekeys supplied'),
          FakeFail(ImErrorCode.notFound, message: 'device has not published its identity key'),
        ]);
      final ImClient client = await connectedClient(gateway);

      const ImUploadOneTimeKeysRequest upload = ImUploadOneTimeKeysRequest(keys: <ImOneTimePreKey>[
        ImOneTimePreKey(keyId: 'otk-3', publicKey: otk1),
        ImOneTimePreKey(keyId: 'otk-4', publicKey: otk2),
      ]);
      await client.keys.upload(upload);
      expect(gateway.requestsTo('keys.upload').single.body, <String, dynamic>{
        'keys': <Map<String, dynamic>>[
          <String, dynamic>{'keyId': 'otk-3', 'publicKey': otk1},
          <String, dynamic>{'keyId': 'otk-4', 'publicKey': otk2},
        ],
      });

      // An empty list still goes out as an empty array: the server's refusal names it.
      await expectLater(
        client.keys.upload(const ImUploadOneTimeKeysRequest(keys: <ImOneTimePreKey>[])),
        refusedWith(1001, 'keys is required'),
      );
      expect(gateway.requestsTo('keys.upload')[1].body, <String, dynamic>{'keys': <Object?>[]});
      await expectLater(client.keys.upload(upload), refusedWith(1001, 'no valid one-time prekeys supplied'));
      await expectLater(
          client.keys.upload(upload), refusedWith(1002, 'device has not published its identity key'));

      await client.dispose();
    });
  });

  group('keys.remaining', () {
    test('without a request asks about the connected device with an empty body; with one names the '
        'device; reads the bare number, quoted or not', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('keys.remaining', const <FakeReply>[
          FakeData(37),
          FakeData('0'),
        ]);
      final ImClient client = await connectedClient(gateway);

      expect(await client.keys.remaining(), 37);
      expect(await client.keys.remaining(const ImRemainingKeysRequest(deviceId: 'alice-tablet')), 0);

      final List<FakeRequest> frames = gateway.requestsTo('keys.remaining');
      expect(frames[0].body, isEmpty);
      expect(frames[1].body, <String, dynamic>{'deviceId': 'alice-tablet'});

      await client.dispose();
    });
  });

  group('keys.claim', () {
    test('sends both ids and decodes every member of the bundle, key material unchanged', () async {
      final FakeGateway gateway = FakeGateway()..on('keys.claim', (FakeRequest _) => const FakeData(bundle));
      final ImClient client = await connectedClient(gateway);

      final ImPreKeyBundle b =
          await client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: 'bob-phone'));

      expect(gateway.requestsTo('keys.claim').single.body,
          <String, dynamic>{'userId': 'bob', 'deviceId': 'bob-phone'});
      expect(b.userId, 'bob');
      expect(b.deviceId, 'bob-phone');
      expect(b.identityKey, identityKey);
      expect(b.signedPreKey.keyId, 'spk-7');
      expect(b.signedPreKey.publicKey, spkPublic);
      expect(b.signedPreKey.signature, spkSignature);
      expect(b.signedPreKey.createdAt, 1755000300000);
      expect(b.oneTimePreKey, isNotNull);
      expect(b.oneTimePreKey!.keyId, 'otk-1');
      expect(b.oneTimePreKey!.publicKey, otk1);
      expect(b.algorithm, 'x3dh-ed25519-aes256gcm-v1');

      await client.dispose();
    });

    test('a bundle from an empty pool — oneTimePreKey absent, as the server omits nulls — decodes '
        'with no one-time key instead of throwing', () async {
      final Map<String, dynamic> drained = Map<String, dynamic>.of(bundle)..remove('oneTimePreKey');
      final FakeGateway gateway = FakeGateway()
        ..script('keys.claim', <FakeReply>[
          FakeData(drained),
          FakeData(<String, dynamic>{...drained, 'oneTimePreKey': null}),
        ]);
      final ImClient client = await connectedClient(gateway);

      for (int i = 0; i < 2; i++) {
        final ImPreKeyBundle b =
            await client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: 'bob-phone'));
        expect(b.oneTimePreKey, isNull);
        expect(b.signedPreKey.publicKey, spkPublic);
      }

      await client.dispose();
    });

    test('is not retried: one call is one frame (each claim consumes a key), and its refusals reach '
        'the caller by code and message', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('keys.claim', const <FakeReply>[
          FakeFail(ImErrorCode.invalidArgument, message: 'userId is required'),
          FakeFail(ImErrorCode.invalidArgument, message: 'deviceId is required'),
          FakeFail(ImErrorCode.notFound, message: 'device has published no keys'),
          FakeFail(ImErrorCode.serviceUnavailable, message: 'key directory is unavailable'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await expectLater(client.keys.claim(const ImClaimBundleRequest(userId: '', deviceId: 'd')),
          refusedWith(1001, 'userId is required'));
      await expectLater(client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: '')),
          refusedWith(1001, 'deviceId is required'));
      await expectLater(
          client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: 'gone')),
          refusedWith(1002, 'device has published no keys'));
      await expectLater(
          client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: 'bob-phone')),
          refusedWith(1005, 'key directory is unavailable'));

      await settle();
      expect(gateway.callsTo('keys.claim'), 4);
      expect(client.state, ImConnectionState.open);

      await client.dispose();
    });
  });

  group('keys.devices', () {
    test('without a request lists the caller\'s own with an empty body; with one names the user; '
        'decodes the bare array with every member', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('keys.devices', const <FakeReply>[
          FakeData(<Map<String, dynamic>>[
            device,
            <String, dynamic>{
              'deviceId': 'bob-web',
              'platform': 5,
              'identityKey': 'AAAA',
              'publishedAt': '1755000300999',
              'remainingOneTimeKeys': 0,
            },
          ]),
          FakeData(<Object?>[]),
        ]);
      final ImClient client = await connectedClient(gateway);

      final List<ImDeviceKeyInfo> devices =
          await client.keys.devices(const ImDeviceKeysRequest(userId: 'bob'));
      final List<ImDeviceKeyInfo> mine = await client.keys.devices();

      final List<FakeRequest> frames = gateway.requestsTo('keys.devices');
      expect(frames[0].body, <String, dynamic>{'userId': 'bob'});
      expect(frames[1].body, isEmpty);

      // The server's order is unspecified; sort before reading.
      devices.sort((ImDeviceKeyInfo a, ImDeviceKeyInfo b) => a.deviceId.compareTo(b.deviceId));
      final ImDeviceKeyInfo phone = devices[0];
      expect(phone.deviceId, 'bob-phone');
      expect(phone.platform, ImPlatform.android);
      expect(phone.identityKey, identityKey);
      expect(phone.publishedAt, 1755000300123);
      expect(phone.remainingOneTimeKeys, 42);
      expect(devices[1].platform, ImPlatform.web);
      expect(devices[1].publishedAt, 1755000300999);

      // An unknown user, or nobody published: an empty list, not an error.
      expect(mine, isEmpty);

      await client.dispose();
    });
  });

  group('keys.revoke', () {
    test('sends the device id; an unknown device succeeds; a blank one is refused', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('keys.revoke', const <FakeReply>[
          FakeData(),
          FakeData(),
          FakeFail(ImErrorCode.invalidArgument, message: 'deviceId is required'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await client.keys.revoke(const ImRevokeDeviceRequest(deviceId: 'alice-lost-phone'));
      await client.keys.revoke(const ImRevokeDeviceRequest(deviceId: 'never-existed'));
      await expectLater(client.keys.revoke(const ImRevokeDeviceRequest(deviceId: '')),
          refusedWith(1001, 'deviceId is required'));

      final List<FakeRequest> frames = gateway.requestsTo('keys.revoke');
      expect(frames[0].body, <String, dynamic>{'deviceId': 'alice-lost-phone'});
      expect(frames[1].body, <String, dynamic>{'deviceId': 'never-existed'});
      // Blank is sent as blank, never filled in with this device.
      expect(frames[2].body, <String, dynamic>{'deviceId': ''});

      await client.dispose();
    });
  });

  group('keys.safetyNumber', () {
    test('sends the peer and reads the bare string; refusals by code and message', () async {
      const String number = '12345 67890 12345 67890 12345 67890 12345 67890 12345 67890 12345 67890';
      final FakeGateway gateway = FakeGateway()
        ..script('keys.safetyNumber', const <FakeReply>[
          FakeData(number),
          FakeFail(ImErrorCode.invalidArgument, message: 'peerUserId is required'),
          FakeFail(ImErrorCode.notFound, message: 'one of the parties has published no keys'),
        ]);
      final ImClient client = await connectedClient(gateway);

      final String safety =
          await client.keys.safetyNumber(const ImSafetyNumberRequest(peerUserId: 'bob'));
      expect(gateway.requestsTo('keys.safetyNumber').single.body,
          <String, dynamic>{'peerUserId': 'bob'});
      expect(safety, number);
      expect(RegExp(r'^\d{5}( \d{5}){11}$').hasMatch(safety), isTrue);

      await expectLater(client.keys.safetyNumber(const ImSafetyNumberRequest(peerUserId: '')),
          refusedWith(1001, 'peerUserId is required'));
      await expectLater(client.keys.safetyNumber(const ImSafetyNumberRequest(peerUserId: 'carol')),
          refusedWith(1002, 'one of the parties has published no keys'));

      await client.dispose();
    });
  });

  test('no key material reaches the SDK log or the logger', () async {
    final List<String> logged = <String>[];
    final FakeGateway gateway = FakeGateway()
      ..on('keys.publish', (FakeRequest _) => const FakeData())
      ..on('keys.upload', (FakeRequest _) => const FakeFail(ImErrorCode.notFound))
      ..on('keys.claim', (FakeRequest _) => const FakeData(bundle))
      ..on('keys.devices', (FakeRequest _) => const FakeData(<Map<String, dynamic>>[device]));
    final ImClient client = await connectedClient(gateway, logger: logged.add);

    await client.keys.publish(fullPublish);
    await expectLater(
      client.keys.upload(const ImUploadOneTimeKeysRequest(
          keys: <ImOneTimePreKey>[ImOneTimePreKey(keyId: 'otk-9', publicKey: otk2)])),
      throwsA(isA<ImException>()),
    );
    await client.keys.claim(const ImClaimBundleRequest(userId: 'bob', deviceId: 'bob-phone'));
    await client.keys.devices(const ImDeviceKeysRequest(userId: 'bob'));
    await settle();

    final String everything =
        '${logged.join('\n')}\n${renderLogBundle(await client.log.read())}';
    for (final String secret in <String>[identityKey, spkPublic, spkSignature, otk1, otk2]) {
      expect(everything.contains(secret), isFalse, reason: 'key material in the log');
    }

    await client.dispose();
  });

  // The decoding tests above are only as wide as their fixtures, and the frame tests only as wide as
  // the bodies they build: so the full fixtures and bodies carry every member the server's type
  // declares, held here to endpoint-inventory.json's payloadTypes.
  // 解码测试只覆盖夹具里的字段、整帧测试只覆盖构造出的请求体：所以全字段夹具与请求体对着清单钉住。
  test('the full fixtures and bodies carry every member the server declares', () {
    final Map<String, dynamic> types = inventory()['payloadTypes'] as Map<String, dynamic>;
    Set<String> members(String type) => <String>{
          for (final dynamic property
              in (types[type] as Map<String, dynamic>)['properties'] as List<dynamic>)
            (property as Map<String, dynamic>)['name'] as String,
        };

    expect(bundle.keys.toSet(), members('PreKeyBundle'));
    expect(signedPreKey.keys.toSet(), members('SignedPreKey'));
    expect(oneTimePreKey.keys.toSet(), members('OneTimePreKey'));
    expect(device.keys.toSet(), members('DeviceKeyInfo'));

    // Every member but the two the server takes from the connection.
    // 除了服务端取自连接的设备与平台，其余每个成员都发。
    final Map<String, Object?> publish = fullPublish.toJson();
    expect(publish.keys.toSet(), members('PublishKeysRequest').difference(<String>{'deviceId', 'platform'}));
    expect(members('PublishKeysRequest'), containsAll(<String>['deviceId', 'platform']));
    expect((publish['signedPreKey'] as Map<String, Object?>).keys.toSet(), members('SignedPreKey'));
    expect(((publish['oneTimePreKeys'] as List<Object?>).first as Map<String, Object?>).keys.toSet(),
        members('OneTimePreKey'));
    expect(
        const ImUploadOneTimeKeysRequest(
                keys: <ImOneTimePreKey>[ImOneTimePreKey(keyId: 'k', publicKey: 'AA==')])
            .toJson()
            .keys
            .toSet(),
        members('UploadOneTimeKeysRequest'));
    expect(const ImRemainingKeysRequest(deviceId: 'd').toJson().keys.toSet(),
        members('RemainingKeysRequest'));
    expect(const ImClaimBundleRequest(userId: 'u', deviceId: 'd').toJson().keys.toSet(),
        members('ClaimBundleRequest'));
    expect(const ImDeviceKeysRequest(userId: 'u').toJson().keys.toSet(), members('DeviceKeysRequest'));
    expect(const ImRevokeDeviceRequest(deviceId: 'd').toJson().keys.toSet(),
        members('RevokeDeviceRequest'));
    expect(const ImSafetyNumberRequest(peerUserId: 'p').toJson().keys.toSet(),
        members('SafetyNumberRequest'));

    // The decoded side, every member read back as the fixture holds it.
    final ImPreKeyBundle b = ImPreKeyBundle.fromJson(bundle);
    expect(<String, Object?>{
      'userId': b.userId,
      'deviceId': b.deviceId,
      'identityKey': b.identityKey,
      'signedPreKey': b.signedPreKey.toJson(),
      'oneTimePreKey': b.oneTimePreKey!.toJson(),
      'algorithm': b.algorithm,
    }, bundle);
    final ImDeviceKeyInfo d = ImDeviceKeyInfo.fromJson(device);
    expect(<String, Object?>{
      'deviceId': d.deviceId,
      'platform': d.platform.wireValue,
      'identityKey': d.identityKey,
      'publishedAt': d.publishedAt,
      'remainingOneTimeKeys': d.remainingOneTimeKeys,
    }, device);
  });

  test('the seven targets are the inventory\'s, with their DTOs', () {
    final Map<String, Map<String, dynamic>> endpoints = <String, Map<String, dynamic>>{
      for (final dynamic endpoint in inventory()['endpoints'] as List<dynamic>)
        (endpoint as Map<String, dynamic>)['target'] as String: endpoint,
    };

    const Map<String, List<String?>> expected = <String, List<String?>>{
      'keys.publish': <String?>['PublishKeysRequest', null],
      'keys.upload': <String?>['UploadOneTimeKeysRequest', null],
      'keys.remaining': <String?>['RemainingKeysRequest', 'int'],
      'keys.claim': <String?>['ClaimBundleRequest', 'PreKeyBundle'],
      'keys.devices': <String?>['DeviceKeysRequest', 'List<DeviceKeyInfo>'],
      'keys.revoke': <String?>['RevokeDeviceRequest', null],
      'keys.safetyNumber': <String?>['SafetyNumberRequest', 'string'],
    };

    for (final MapEntry<String, List<String?>> entry in expected.entries) {
      final Map<String, dynamic>? endpoint = endpoints[entry.key];
      expect(endpoint, isNotNull, reason: '${entry.key} is not in the inventory');
      expect(endpoint!['requestType'], entry.value[0], reason: entry.key);
      expect(endpoint['responseType'], entry.value[1], reason: entry.key);
    }
  });
}

Map<String, dynamic> inventory() {
  Directory directory = Directory.current.absolute;
  for (int hop = 0; hop < 8; hop++) {
    final File candidate = File('${directory.path}/endpoint-inventory.json');
    if (candidate.existsSync()) {
      return jsonDecode(candidate.readAsStringSync()) as Map<String, dynamic>;
    }
    directory = directory.parent;
  }
  fail('could not locate sdk/endpoint-inventory.json');
}
