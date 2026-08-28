import 'dart:async';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Conformance tests 17–23 from `sdk/CONTRACT.md` §10, "Errors".
///
/// Two of the mappings here are choices rather than deductions, and both are the kind that only
/// hurt once they are in a customer's hands: `status: 2` is 1008 and not 1002, and a socket that
/// drops with requests in flight fails them 1004 and not 1005.
void main() {
  group('error mapping', () {
    test('17. statusTwoMapsToUnsupportedOperation', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('group.transfer', (FakeRequest _) => const FakeStatus(2));

      final ImClient client = await connectedClient(gateway);

      // 1002 means "your group does not exist". 1008 means "this deployment has never heard of
      // group.transfer" — the exact signal an SDK newer than a private-deployment server produces,
      // and the one an integrator needs verbatim.
      await expectLater(
        client.invoke<Object?>('group.transfer', <String, Object?>{'groupId': 'g1'}),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.unsupportedOperation)
            .having((ImException e) => e.message, 'message', contains('group.transfer'))
            .having((ImException e) => e.isRetryable, 'isRetryable', isFalse)),
      );

      await client.dispose();
    });

    test('an endpoint that threw maps to 1000 with the transport message', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.send', (FakeRequest _) => const FakeStatus(1, msg: 'NullReferenceException'));

      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.invoke<Object?>('msg.send'),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.internalError)
            .having((ImException e) => e.message, 'message', 'NullReferenceException')),
      );

      await client.dispose();
    });

    test('18. businessCodeThrowsWithTraceId', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.send',
        (FakeRequest _) => const FakeFail(
          ImErrorCode.moderationRejected,
          message: 'blocked by moderation',
          traceId: 'trace-42',
        ),
      );

      final ImClient client = await connectedClient(gateway);

      // A bug report carrying traceId and target is a one-query investigation; without them it is
      // a guess.
      await expectLater(
        client.msg.send(ImSendMessageRequest.text('hi', receiverId: 'bob')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.moderationRejected)
            .having((ImException e) => e.traceId, 'traceId', 'trace-42')
            .having((ImException e) => e.target, 'target', 'msg.send')),
      );

      await client.dispose();
    });

    test('19. retryClassificationMatchesTable', () {
      const List<int> retryable = <int>[
        ImErrorCode.internalError,
        ImErrorCode.rateLimited,
        ImErrorCode.timeout,
        ImErrorCode.serviceUnavailable,
      ];
      const List<int> reauth = <int>[
        ImErrorCode.unauthorized,
        ImErrorCode.tokenExpired,
        ImErrorCode.tokenInvalid,
      ];

      for (final int code in retryable) {
        expect(ImErrorCode.isRetryable(code), isTrue, reason: 'code $code');
        expect(ImException(code, 'x').isRetryable, isTrue, reason: 'code $code');
      }
      for (final int code in reauth) {
        expect(ImErrorCode.requiresReauth(code), isTrue, reason: 'code $code');
        expect(ImException(code, 'x').requiresReauth, isTrue, reason: 'code $code');
      }

      // Everything else is terminal: retrying it produces the same answer, so a retry loop around
      // it turns one failure into many.
      const List<int> terminal = <int>[
        ImErrorCode.invalidArgument,
        ImErrorCode.notFound,
        ImErrorCode.conflict,
        ImErrorCode.payloadTooLarge,
        ImErrorCode.unsupportedOperation,
        ImErrorCode.forbidden,
        ImErrorCode.userBanned,
        ImErrorCode.kickedByOtherDevice,
        ImErrorCode.quotaExceeded,
        ImErrorCode.featureNotEnabled,
        ImErrorCode.planExpired,
        ImErrorCode.notFriend,
        ImErrorCode.moderationRejected,
        ImErrorCode.notGroupMember,
      ];
      for (final int code in terminal) {
        expect(ImErrorCode.isRetryable(code), isFalse, reason: 'code $code');
        expect(ImErrorCode.requiresReauth(code), isFalse, reason: 'code $code');
      }

      // connectionLost is the client-side name for 1005, not a second code.
      expect(ImErrorCode.connectionLost, ImErrorCode.serviceUnavailable);
    });

    test('20. offlineRequestRejectsImmediately', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = ImClient(optionsFor(gateway.connect));

      // Not queued. A chat client that buffers a send across a five-minute outage delivers it into
      // a conversation that has moved on; the application, which knows whether the message is
      // still worth sending, decides.
      await expectLater(
        client.msg.send(ImSendMessageRequest.text('hi', receiverId: 'bob')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.serviceUnavailable)),
      );
      expect(gateway.sockets, isEmpty);

      await client.dispose();
    });

    test('a socket that drops with a request in flight fails it 1004, not 1005', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.send', (FakeRequest _) => const FakeSilence());

      final ImConnection connection = ImConnection(optionsFor(gateway.connect));
      unawaited(connection.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      final Future<Object?> pending = connection.request<Object?>('msg.send', <String, Object?>{});
      await pumpUntil(() => connection.pendingRequestCount == 1);
      await gateway.socket.die();

      // 1005 would claim the call was never delivered, and the SDK does not know that — the
      // request may well have executed. 1004 is the honest answer, and the one that makes a caller
      // reach for clientMsgId idempotency instead of blindly resending.
      await expectLater(
        pending,
        throwsA(isA<ImException>().having((ImException e) => e.code, 'code', ImErrorCode.timeout)),
      );
    });

    test('21. cancellationRemovesPendingEntry', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.history', (FakeRequest _) => const FakeSilence());

      final ImConnection connection = ImConnection(optionsFor(gateway.connect));
      unawaited(connection.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      final ImCancelToken token = ImCancelToken();
      final Future<Object?> pending =
          connection.request<Object?>('msg.history', <String, Object?>{}, token);

      await pumpUntil(() => connection.pendingRequestCount == 1);
      token.cancel('the screen was disposed');

      // Cancellation raises the language's cancellation type, not an ImException with a made-up
      // code: it is a local decision, not a server outcome.
      await expectLater(
        pending,
        throwsA(isA<ImCancelledException>()
            .having((ImCancelledException e) => e.target, 'target', 'msg.history')
            .having((ImCancelledException e) => e.reason, 'reason', 'the screen was disposed')),
      );

      // An entry left in the map is a leak that grows for the life of the connection.
      expect(connection.pendingRequestCount, 0);
    });

    test('a request started with an already-cancelled token never reaches the wire', () async {
      final FakeGateway gateway = FakeGateway();
      final ImConnection connection = ImConnection(optionsFor(gateway.connect));
      unawaited(connection.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => connection.state == ImConnectionState.open);

      final ImCancelToken token = ImCancelToken()..cancel();

      await expectLater(
        connection.request<Object?>('msg.send', <String, Object?>{}, token),
        throwsA(isA<ImCancelledException>()),
      );
      expect(gateway.callsTo('msg.send'), 0);
      expect(connection.pendingRequestCount, 0);
    });

    test('22. kickStopsReconnecting', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final List<ImKickEvent> kicks = <ImKickEvent>[];
      client.kicks.listen(kicks.add);

      // 1107 arrives both as a conn.kick push and as a close reason. Both must stop the reconnect
      // loop — reconnecting into a kick is a loop, and an invisible one.
      gateway.socket.deliver(<String, dynamic>{
        'id': 'srv-kick',
        'target': 'conn.kick',
        'status': 0,
        'body': <String, dynamic>{
          'code': ImErrorCode.kickedByOtherDevice,
          'serverTime': 1,
          'data': <String, dynamic>{'reason': 'MultiLoginPolicy'},
        },
      });

      await pumpUntil(() => client.state == ImConnectionState.closed);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(kicks.single.reason, ImKickReason.multiLoginPolicy);
      expect(kicks.single.isTerminal, isTrue);
      expect(gateway.sockets, hasLength(1), reason: 'no reconnect may follow a kick');

      await client.dispose();
    });

    test('23. featureNotEnabledIsNotLatched', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.typing', (FakeRequest _) => const FakeFail(ImErrorCode.featureNotEnabled));

      final ImClient client = await connectedClient(gateway);

      // A tenant can flip EnableTypingIndicator at runtime. A client that remembers "typing is
      // off" stays broken until the app restarts.
      for (int i = 0; i < 2; i++) {
        await expectLater(
          client.msg.typing(const ImTypingRequest(conversationId: 'c1')),
          throwsA(isA<ImException>()
              .having((ImException e) => e.code, 'code', ImErrorCode.featureNotEnabled)),
        );
      }

      expect(gateway.callsTo('msg.typing'), 2);

      await client.dispose();
    });
  });

  group('reauth', () {
    test('an expired token is renewed on the live socket and the call retried once', () async {
      final FakeGateway gateway = FakeGateway();
      int sends = 0;

      gateway.on('msg.send', (FakeRequest _) {
        sends++;
        return sends == 1 ? const FakeFail(ImErrorCode.tokenExpired) : const FakeData();
      });

      int mints = 0;
      final ImClient client = await connectedClient(
        gateway,
        onTokenExpired: () async {
          mints++;
          return 'token-2';
        },
      );

      await client.invoke<Object?>('msg.send', <String, Object?>{});

      // One frame, not a reconnect. On the flaky network where tokens tend to expire, a reconnect
      // is exactly what you were trying to avoid.
      expect(mints, 1);
      expect(gateway.callsTo('conn.reauth'), 1);
      expect(gateway.requestsTo('conn.reauth').single.body['token'], 'token-2');
      expect(gateway.callsTo('msg.send'), 2);
      expect(gateway.sockets, hasLength(1));

      await client.dispose();
    });

    test('a failed reauth surfaces the original error instead of looping', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.send', (FakeRequest _) => const FakeFail(ImErrorCode.tokenExpired));
      gateway.on('conn.reauth', (FakeRequest _) => const FakeFail(ImErrorCode.tokenInvalid));

      final ImClient client = await connectedClient(gateway, onTokenExpired: () async => 'token-2');

      await expectLater(
        client.invoke<Object?>('msg.send', <String, Object?>{}),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.tokenExpired)
            .having((ImException e) => e.requiresReauth, 'requiresReauth', isTrue)),
      );

      expect(gateway.callsTo('conn.reauth'), 1);
      expect(gateway.callsTo('msg.send'), 1);

      await client.dispose();
    });
  });

  group('escape hatch', () {
    test('invoke shares the typed surface\'s error mapping and moves no cursor', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.sync',
        (FakeRequest _) => FakeData(syncPage(
          conversationId: 'c1',
          seqs: <int>[1, 2, 3],
          hasMore: false,
        )),
      );

      final ImClient client = await connectedClient(gateway);
      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      final Map<String, dynamic> raw = await client.invoke<Map<String, dynamic>>(
        'msg.sync',
        const ImSyncMessagesRequest(conversationId: 'c1', fromSeq: 1, toSeq: 3).toJson(),
      );

      await settle();

      expect((raw['messages'] as List<dynamic>).length, 3);
      expect(delivered, isEmpty, reason: 'invoke never participates in cursor logic');
      expect(client.deliveredSeq('c1'), 0);

      await client.dispose();
    });
  });
}
