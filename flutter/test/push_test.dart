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

    test('push.clicked reports a tap and names nobody', () async {
      // APNs and FCM do not report delivery at all, so on most deployments the click is the only
      // evidence a notification arrived — and with neither field the server attributes this
      // device's newest delivery, which is what a tap that opened the app without naming a message
      // can only mean.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.push.clicked();

      final FakeRequest request = gateway.requestsTo('push.clicked').single;
      expect(request.body, isEmpty);
      expect(request.body.containsKey('userId'), isFalse);
      expect(request.body.containsKey('deviceId'), isFalse);

      await client.dispose();
    });

    test('push.clicked carries the payload msgId as a string', () async {
      // The notification payload's `msgId` is a snowflake past 2^53. It goes back the way it came,
      // quoted: parsed into a Dart `int` it would be a different id on the web, and the row it
      // narrowed to would be somebody else's or nobody's.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.push.clicked(const ImPushClickedRequest(messageId: '350598345233801216'));

      final String frame = gateway.socket.sent.firstWhere(
        (String payload) => payload.contains('push.clicked'),
      );
      expect(frame, contains('"messageId":"350598345233801216"'));

      await client.dispose();
    });

    test('a failed push.clicked is logged, never thrown and never retried', () async {
      // Best-effort statistics: nothing in the app depends on the answer, and the natural way to
      // call it is to fire and not await — which in Dart turns a rejection into an unhandled
      // asynchronous error for a notification that was tapped perfectly successfully.
      final List<String> warnings = <String>[];
      final FakeGateway gateway = FakeGateway();

      // 2401 PushDeliveryNotFound: the row expired after seven days, or the notification did not
      // come from this platform. Neither is the caller's fault.
      gateway.on(
        'push.clicked',
        (FakeRequest _) => const FakeFail(ImErrorCode.pushDeliveryNotFound, message: 'no delivery record matches this device'),
      );

      final ImClient client = await connectedClient(gateway, logger: warnings.add);

      await client.push.clicked(const ImPushClickedRequest(pushId: 'pu_expired'));

      expect(warnings.single, contains('push.clicked'));
      expect(gateway.callsTo('push.clicked'), 1,
          reason: 'a click reported twice is worse than one '
              'reported never');

      await client.dispose();
    });

    test('a cancelled push.clicked throws, because cancellation is not a server outcome', () async {
      // The one failure this call does not absorb, and the one most likely to be lost by accident:
      // the rethrow is a single `on ImCancelledException { rethrow; }` sitting inside a catch whose
      // whole purpose is to swallow, so the next person tidying that block removes it and no other
      // test goes red. CONTRACT §7.5 rule 3 — the caller cancelled, and a future that completes
      // normally tells them it finished instead.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final ImCancelToken token = ImCancelToken()..cancel();

      await expectLater(
        client.push.clicked(const ImPushClickedRequest(pushId: 'pu_1'), token),
        throwsA(isA<ImCancelledException>()),
      );

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
