import 'dart:async';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The handshake query string, from `sdk/CONTRACT.md` §2 and §9.1.
///
/// Small surface, and easy to break without noticing: nothing in the SDK reads these back, the
/// gateway accepts a connection that is missing most of them, and the two that matter at support
/// time — `cv` and `deviceId` — only ever get looked at when something has already gone wrong.
/// A `cv` that silently stopped being sent costs a support engineer the one question they would
/// not otherwise have to ask.
///
/// 握手参数没人回读，缺了也能连上；`cv` 悄悄不发了，只有出事时才会发现。
void main() {
  group('handshake', () {
    test('carries every parameter the gateway and a support ticket need', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final Uri url = gateway.socket.url;
      expect(url.scheme, 'wss');
      expect(url.path, '/im');
      expect(url.queryParameters['appId'], 'demo');
      expect(url.queryParameters['token'], 'token-1');
      expect(url.queryParameters['deviceId'], 'device-1');
      expect(url.queryParameters['platform'], ImPlatform.web.wireValue.toString());
      expect(url.queryParameters['v'], '1');

      // §9.1: the SDK sends its own package version as `cv` when the host app did not name one, so
      // a ticket carries the build without anyone having to ask which one the customer is on.
      expect(url.queryParameters['cv'], ImSdk.packageVersion);
      expect(ImSdk.packageVersion, '0.9.0');
      expect(ImSdk.contractVersion, '1.0');

      await client.dispose();
    });

    test('a host app version overrides cv, and language is only sent when set', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = ImClient(ImOptions(
        endpoint: 'wss://im.test/',
        appId: 'demo',
        token: 'token-1',
        deviceId: 'device-1',
        userId: 'alice',
        cursorStore: ImCursorStore.inMemory(),
        clientVersion: '3.2.1+host',
        language: 'zh-CN',
        socketFactory: gateway.connect,
      ));

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty, because: 'no socket was created');

      final Uri url = gateway.socket.url;
      expect(url.queryParameters['cv'], '3.2.1+host');
      expect(url.queryParameters['lang'], 'zh-CN');

      // A trailing slash on the endpoint must not produce `//im`; a deployment that configures one
      // is common and a doubled slash is a 404 from most reverse proxies.
      expect(url.path, '/im');

      await client.dispose();
    });
  });
}
