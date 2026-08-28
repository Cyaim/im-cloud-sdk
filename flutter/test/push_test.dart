import 'dart:async';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Conformance tests 14–16 from `sdk/CONTRACT.md` §10, "Push".
///
/// The server side of `push.*` shipped and **no SDK called it**, so offline push — which every
/// mobile deal turns on — was unreachable from any official client. These pin the three rules that
/// make it work in practice rather than only in a demo.
///
/// 服务端 push.* 早已上线而五个 SDK 一个都没调用：离线推送在官方客户端里根本够不着。
void main() {
  group('push registration', () {
    test('14. registersOnEveryConnect', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      // The token is known before the socket is even up, which is the ordinary case: the plugin
      // hands it over at startup.
      await client.push.setToken(ImPushProvider.fcm, 'token-abc');
      await pumpUntil(() => gateway.callsTo('push.register') >= 1);

      for (int i = 0; i < 2; i++) {
        await client.disconnect();
        unawaited(client.connect());
        await pumpUntil(() => gateway.sockets.length >= i + 2);
        gateway.openLatest();
        await pumpUntil(() => client.state == ImConnectionState.open);
        await pumpUntil(() => gateway.callsTo('push.register') >= i + 2);
      }

      // Not once at install: the vendor may replace a token while the process is frozen, and the
      // server has no other way to learn it. Re-registering an unchanged token costs no write.
      expect(gateway.callsTo('push.register'), 3);
      for (final FakeRequest request in gateway.requestsTo('push.register')) {
        expect(request.body['provider'], 'fcm');
        expect(request.body['token'], 'token-abc');
        // Identity comes from the socket. There is no field in which to name someone else.
        expect(request.body.containsKey('userId'), isFalse);
        expect(request.body.containsKey('deviceId'), isFalse);
      }

      await client.dispose();
    });

    test('15. unregisterPrecedesDisconnect', () async {
      final FakeGateway gateway = FakeGateway();
      bool socketWasOpenWhenUnregisterArrived = false;

      gateway.on('push.unregister', (FakeRequest _) {
        socketWasOpenWhenUnregisterArrived = !gateway.socket.isClosed;
        return const FakeData();
      });

      final ImClient client = await connectedClient(gateway);
      await client.push.setToken(ImPushProvider.apns, 'apns-token');
      await pumpUntil(() => gateway.callsTo('push.register') >= 1);

      await client.logout();

      // After the socket closes there is no authenticated channel and the token cannot be removed
      // at all — the user keeps getting notifications on a handset they logged out of.
      expect(socketWasOpenWhenUnregisterArrived, isTrue);
      expect(gateway.socket.isClosed, isTrue);
      expect(gateway.targets.last, 'push.unregister');
      expect(client.push.token, isNull);

      await client.dispose();
    });

    test('16. tokenRefreshWhileOfflineRegistersOnNextConnect', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = ImClient(optionsFor(gateway.connect));

      // Offline: the vendor refreshed the token while the socket was down.
      await client.push.setToken(ImPushProvider.huawei, 'hms-1');
      await settle();
      expect(gateway.callsTo('push.register'), 0,
          reason: 'registration is a normal request and is never queued');

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('push.register') >= 1);

      expect(gateway.requestsTo('push.register').single.body['token'], 'hms-1');
      expect(gateway.requestsTo('push.register').single.body['provider'], 'huawei');

      await client.dispose();
    });

    test('a refreshed token while connected registers immediately', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.push.setToken(ImPushProvider.fcm, 'first');
      await pumpUntil(() => gateway.callsTo('push.register') >= 1);

      await client.push.setToken(ImPushProvider.fcm, 'second');
      await pumpUntil(() => gateway.callsTo('push.register') >= 2);

      expect(
        gateway.requestsTo('push.register').map((FakeRequest r) => r.body['token']),
        <String>['first', 'second'],
      );

      await client.dispose();
    });

    test('disconnect never unregisters — a dead socket is what push is for', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.push.setToken(ImPushProvider.fcm, 'token-abc');
      await pumpUntil(() => gateway.callsTo('push.register') >= 1);

      await client.disconnect();

      expect(gateway.callsTo('push.unregister'), 0);
      expect(client.push.token, 'token-abc');

      await client.dispose();
    });

    test('a registration that fails warns once, naming the section', () async {
      final List<String> warnings = <String>[];
      final FakeGateway gateway = FakeGateway();
      gateway.on('push.register', (FakeRequest _) => const FakeFail(ImErrorCode.internalError));

      final ImClient client = await connectedClient(gateway, logger: warnings.add);
      await client.push.setToken(ImPushProvider.fcm, 'token-abc');
      await pumpUntil(() => warnings.isNotEmpty);

      // A silently unregistered device is indistinguishable from a broken push provider, and that
      // misdiagnosis costs a support cycle every time.
      expect(warnings.single, contains('§6.2'));
      expect(warnings.single, contains('never registered'));
      expect(client.push.isRegistered, isFalse);

      await client.dispose();
    });

    test('push.register carries the language when one is given', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.push.register(const ImRegisterPushTokenRequest(
        provider: ImPushProvider.xiaomi,
        token: 'mi-1',
        language: 'zh-Hans-CN',
      ));

      final FakeRequest request = gateway.requestsTo('push.register').single;
      expect(request.body['language'], 'zh-Hans-CN');
      expect(client.push.isRegistered, isTrue);

      await client.dispose();
    });

    test('every OEM channel the server routes has a named constant', () {
      // Empty falls back to the platform default, which is only reliable on iOS: Android fragments
      // across five OEM channels and the server cannot guess which one a token came from.
      expect(ImPushProvider.values, <String>[
        'apns',
        'fcm',
        'huawei',
        'xiaomi',
        'oppo',
        'vivo',
        'honor',
      ]);
    });
  });
}
