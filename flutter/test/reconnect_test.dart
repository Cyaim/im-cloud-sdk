import 'dart:async';
import 'dart:math';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('full-jitter backoff', () {
    test('draws uniformly from zero to the ceiling rather than clustering', () {
      final FullJitterBackoff backoff = FullJitterBackoff(random: Random(42));
      const int attempt = 6;
      final int ceiling = backoff.ceilingFor(attempt).inMicroseconds;

      final List<int> buckets = List<int>.filled(10, 0);
      const int draws = 5000;
      int total = 0;

      for (int i = 0; i < draws; i++) {
        final int micros = backoff.delayFor(attempt).inMicroseconds;
        expect(micros, inInclusiveRange(0, ceiling));
        total += micros;
        buckets[(micros * 10 ~/ ceiling).clamp(0, 9)]++;
      }

      // Every bucket populated and none dominant: that is what "uniform" has to mean. A fixed
      // backoff would put every draw in one bucket, and a ±10% jitter in two.
      for (final int count in buckets) {
        expect(count, greaterThan(0));
        expect(count, lessThan(draws ~/ 5));
      }

      // Mean of a uniform draw is half the ceiling.
      expect((total / draws) / ceiling, closeTo(0.5, 0.05));
    });

    test('ceiling doubles then stops growing', () {
      final FullJitterBackoff backoff = FullJitterBackoff(random: Random(1));

      expect(
          backoff.ceilingFor(1).inMicroseconds, equals(backoff.ceilingFor(0).inMicroseconds * 2));
      expect(backoff.ceilingFor(30), equals(backoff.ceilingFor(60)));
    });
  });

  group('kick handling', () {
    test('a terminal kick stops reconnecting', () async {
      final FakeTransport transport = FakeTransport();
      final ImConnection connection = ImConnection(optionsFor(transport.call));

      final List<ImKickEvent> kicks = <ImKickEvent>[];
      connection.kicks.listen(kicks.add);

      unawaited(connection.connect());
      await pumpUntil(() => transport.created.isNotEmpty);
      transport.latest.open();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      await transport.latest.die(code: 1000, reason: 'im-kick:MultiLoginPolicy');
      await pumpUntil(() => connection.state == ImConnectionState.closed);

      expect(kicks.single.reason, ImKickReason.multiLoginPolicy);
      expect(kicks.single.isTerminal, isTrue);

      // Reconnecting would be refused identically, forever.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(transport.created, hasLength(1));
    });

    test('a refused handshake reconnects, since it produces no close frame', () async {
      final FakeTransport transport = FakeTransport();
      final ImConnection connection = ImConnection(optionsFor(transport.call));

      unawaited(connection.connect());
      await pumpUntil(() => transport.created.isNotEmpty);

      // A 401 or a captive portal fails `ready` and never sends a close frame, so nothing but
      // this path would ever notice the attempt died.
      transport.latest.refuse(StateError('handshake refused'));
      await pumpUntil(() => transport.created.length >= 2);

      expect(connection.state, ImConnectionState.reconnecting);
    });

    test('an ordinary network death reconnects', () async {
      final FakeTransport transport = FakeTransport();
      final ImConnection connection = ImConnection(optionsFor(transport.call));

      unawaited(connection.connect());
      await pumpUntil(() => transport.created.isNotEmpty);
      transport.latest.open();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      await transport.latest.die();
      await pumpUntil(() => transport.created.length >= 2);

      expect(connection.state, isNot(ImConnectionState.closed));
    });

    test('an expired token is refreshed before reconnecting', () async {
      final FakeTransport transport = FakeTransport();
      int refreshes = 0;

      final ImConnection connection = ImConnection(optionsFor(
        transport.call,
        onTokenExpired: () async {
          refreshes++;
          return 'token-2';
        },
      ));

      unawaited(connection.connect());
      await pumpUntil(() => transport.created.isNotEmpty);
      transport.latest.open();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      await transport.latest.die(code: 1000, reason: 'im-kick:TokenExpired');
      await pumpUntil(() => transport.created.length >= 2);

      expect(refreshes, 1);
      expect(transport.latest.url.queryParameters['token'], 'token-2');
    });

    test('a refused token refresh closes instead of looping', () async {
      final FakeTransport transport = FakeTransport();
      final ImConnection connection =
          ImConnection(optionsFor(transport.call, onTokenExpired: () async => null));

      unawaited(connection.connect());
      await pumpUntil(() => transport.created.isNotEmpty);
      transport.latest.open();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      await transport.latest.die(code: 1000, reason: 'im-kick:TokenExpired');
      await pumpUntil(() => connection.state == ImConnectionState.closed);

      expect(transport.created, hasLength(1));
    });
  });

  group('gap repair', () {
    test('a skipped seq is fetched before the triggering message is delivered', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.sync',
        (FakeRequest _) => FakeData(syncPage(
          conversationId: 's_a_b',
          seqs: <int>[2, 3],
          hasMore: false,
        )),
      );

      final ImClient client = await connectedClient(gateway);
      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      gateway.socket.deliver(push('evt.message', message('s_a_b', 1)));
      await pumpUntil(() => delivered.length == 1);

      // Now skip 2 and 3.
      gateway.socket.deliver(push('evt.message', message('s_a_b', 4)));
      await pumpUntil(() => delivered.length == 4);

      final FakeRequest repair = gateway.requestsTo('msg.sync').single;
      expect(repair.body['conversationId'], 's_a_b');
      expect(repair.body['fromSeq'], 2);
      expect(repair.body['toSeq'], 3);
      expect(delivered.map((ImMessage m) => m.seq), <int>[1, 2, 3, 4]);
    });

    test('a duplicate seq is dropped silently', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      gateway.socket.deliver(push('evt.message', message('s_a_b', 1)));
      await pumpUntil(() => delivered.length == 1);

      gateway.socket.deliver(push('evt.message', message('s_a_b', 1)));
      await settle();

      expect(delivered, hasLength(1));
    });

    test('an unpersisted message (seq 0) is delivered without moving the cursor', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      gateway.socket.deliver(push('evt.message', message('s_a_b', 0)));
      gateway.socket.deliver(push('evt.message', message('s_a_b', 1)));

      await pumpUntil(() => delivered.length == 2);
      expect(delivered.map((ImMessage m) => m.seq), <int>[0, 1]);
    });
  });

  group('requests', () {
    test('a request while offline fails immediately instead of queueing', () async {
      final FakeTransport transport = FakeTransport();
      final ImConnection connection = ImConnection(optionsFor(transport.call));

      await expectLater(
        connection.request<Object?>('msg.send'),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.serviceUnavailable)),
      );
    });

    test('a non-zero business code becomes an ImException carrying the trace id', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.send',
        (FakeRequest _) => const FakeFail(
          ImErrorCode.notFriend,
          message: 'not friends',
          traceId: 'trace-9',
        ),
      );

      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.invoke<Object?>('msg.send', <String, dynamic>{}),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.notFriend)
            .having((ImException e) => e.traceId, 'traceId', 'trace-9')
            .having((ImException e) => e.target, 'target', 'msg.send')),
      );
    });
  });
}
