import 'dart:async';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Conformance tests 24–26 from `sdk/CONTRACT.md` §10, "Ordering".
///
/// One rule sits above the other two: **for a given conversation, messages reach the application
/// in `seq` order, and never concurrently with each other.** Everything the client does with lanes
/// exists to serve it. The interesting case is not the quiet one — it is a live message arriving
/// while a gap repair for the same conversation is still fetching the messages that belong in
/// front of it. An application that sees a conversation jump forward and then fill in behind it
/// has to sort the UI itself, which is exactly the work an SDK is bought to remove.
///
/// The other two are the ones that only show up in production: a handler that throws on one
/// message must not stop the next one arriving, and a handler that calls back into the SDK must
/// not deadlock — both are things a real application does within a week of integrating.
///
/// 同一会话内必须按 seq 顺序、互不并发地投递；补洞进行中到达的实时消息要压后。
/// 另外两条是上线后才会暴露的：一个回调抛异常不能停掉整条投递链，回调里再调 SDK 不能死锁。
void main() {
  group('ordering', () {
    test('24. messagesArriveInSeqOrder', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );

      final FakeGateway gateway = FakeGateway();

      // Two repair pages, so the ordering has to survive a `msg.sync` loop rather than a single
      // call — a repair that delivers page 2 before page 1 would pass a one-page test.
      gateway.on('msg.sync', (FakeRequest request) {
        final int from = request.body['fromSeq'] as int;
        return FakeData(from <= 11
            ? syncPage(conversationId: 'c1', seqs: <int>[11, 12], hasMore: true)
            : syncPage(conversationId: 'c1', seqs: <int>[13, 14], hasMore: false));
      });

      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<int> received = <int>[];
      final StreamSubscription<ImMessage> subscription =
          client.messages.listen((ImMessage m) => received.add(m.seq));

      // 15 opens a gap over 11…14. 16 arrives while that repair is still in flight and must be
      // held behind it — not delivered the moment it decodes.
      gateway.socket
        ..deliver(push(ImPushTarget.message, message('c1', 15)))
        ..deliver(push(ImPushTarget.message, message('c1', 16)));

      await pumpUntil(() => received.length >= 6, because: 'the repair never completed');
      await settle();

      // In order, gap first, and each exactly once.
      expect(received, <int>[11, 12, 13, 14, 15, 16]);
      expect(client.deliveredSeq('c1'), 16);

      // And **one** repair, not two. This is the assertion the ordering rule actually rests on:
      // without a per-conversation lane, 16 starts its own repair over the same range while 15's
      // is still in flight — `[11-14, 11-15, 13-14, 13-15]` on the wire instead of `[11-14,
      // 13-14]`. Deduplication hides that from the delivered order most of the time, which is
      // exactly why the wire is the thing to assert on: doubled traffic and two writers racing
      // over one conversation's cursor, with the interleaving deciding who wins.
      expect(
        gateway.requestsTo('msg.sync').map((FakeRequest r) => r.body['fromSeq']),
        <int>[11, 13],
        reason: 'a second repair for the same conversation ran concurrently with the first',
      );

      await subscription.cancel();
      await client.dispose();
    });

    test('a repair that arrives out of order is still delivered in seq order', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );

      final FakeGateway gateway = FakeGateway();

      // The server is allowed to answer `ascending: true` with whatever order it likes; the SDK
      // asks for ascending and the repair loop pages on seq, so what the application sees is the
      // page order. This pins that the client requests ascending in the first place.
      gateway.on(
        'msg.sync',
        (FakeRequest _) =>
            FakeData(syncPage(conversationId: 'c1', seqs: <int>[11, 12], hasMore: false)),
      );

      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<int> received = <int>[];
      final StreamSubscription<ImMessage> subscription =
          client.messages.listen((ImMessage m) => received.add(m.seq));

      gateway.socket.deliver(push(ImPushTarget.message, message('c1', 13)));
      await pumpUntil(() => received.length >= 3);

      expect(received, <int>[11, 12, 13]);
      expect(gateway.requestsTo('msg.sync').single.body['ascending'], isTrue);

      await subscription.cancel();
      await client.dispose();
    });

    test('25. throwingListenerDoesNotStopDelivery', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final List<Object> escaped = <Object>[];
      final List<int> survivor = <int>[];
      late final StreamSubscription<ImMessage> thrower;
      late final StreamSubscription<ImMessage> healthy;

      // Registered inside a guarded zone because that is where a Dart stream sends a listener's
      // exception: the pump is not the place it surfaces, and a test that let it reach the root
      // zone would fail for the wrong reason. What matters is that it goes *somewhere* visible
      // rather than being swallowed.
      runZonedGuarded(
        () {
          thrower = client.messages.listen((ImMessage _) => throw StateError('app bug'));
          healthy = client.messages.listen((ImMessage m) => survivor.add(m.seq));
        },
        (Object error, StackTrace _) => escaped.add(error),
      );

      for (int seq = 1; seq <= 3; seq++) {
        gateway.socket.deliver(push(ImPushTarget.message, message('c1', seq)));
      }

      await pumpUntil(() => survivor.length >= 3, because: 'delivery stopped at the first throw');
      await settle();

      // One application bug in one handler must not stop delivery for every conversation…
      expect(survivor, <int>[1, 2, 3]);
      expect(escaped, hasLength(3));
      expect(escaped.every((Object e) => e is StateError), isTrue);

      // …and must never lose a cursor. This half is the one that costs messages: a delivery loop
      // that aborted on the throw would leave deliveredSeq at 1 and the next live message would
      // look like a gap over data the application had already been handed.
      expect(client.deliveredSeq('c1'), 3);

      await thrower.cancel();
      await healthy.cancel();
      await client.dispose();
    });

    test('a throwing listener does not stop a gap repair either', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.sync',
        (FakeRequest _) =>
            FakeData(syncPage(conversationId: 'c1', seqs: <int>[11, 12], hasMore: false)),
      );

      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<Object> escaped = <Object>[];
      final List<int> survivor = <int>[];
      late final StreamSubscription<ImMessage> thrower;
      late final StreamSubscription<ImMessage> healthy;

      runZonedGuarded(
        () {
          thrower = client.messages.listen((ImMessage _) => throw StateError('app bug'));
          healthy = client.messages.listen((ImMessage m) => survivor.add(m.seq));
        },
        (Object error, StackTrace _) => escaped.add(error),
      );

      gateway.socket.deliver(push(ImPushTarget.message, message('c1', 13)));
      await pumpUntil(() => survivor.length >= 3);

      expect(survivor, <int>[11, 12, 13]);
      expect(client.deliveredSeq('c1'), 13);

      await thrower.cancel();
      await healthy.cancel();
      await client.dispose();
    });

    test('26. reentrantCallFromListenerDoesNotDeadlock', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.on('conv.unreadTotal', (FakeRequest _) => const FakeData(7));
      gateway.on(
        'msg.sync',
        (FakeRequest _) =>
            FakeData(syncPage(conversationId: 'c1', seqs: <int>[11, 12], hasMore: false)),
      );

      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<int> unreadSeen = <int>[];
      Object? failure;

      // The realistic shape: write the message, tell the SDK it is durable, refresh the badge —
      // all from inside the delivery callback, which is where an application naturally puts it.
      // A client that held a lock across the callback, or that delivered on a thread it then
      // blocked, would hang here rather than fail.
      final StreamSubscription<ImMessage> subscription =
          client.messages.listen((ImMessage m) async {
        try {
          await client.commit(m.conversationId, m.seq);
          unreadSeen.add(await client.conv.unreadTotal());
          await client.invoke<Object?>('msg.typing', <String, Object?>{
            'conversationId': m.conversationId,
            'typing': false,
          });
        } catch (error) {
          failure = error;
        }
      });

      // Delivered through a gap repair, so the reentrant calls happen while the conversation's
      // lane is still the active one — the case a naive `await` inside the lane would deadlock on.
      gateway.socket.deliver(push(ImPushTarget.message, message('c1', 13)));

      await pumpUntil(
        () => unreadSeen.length >= 3,
        because: 'a reentrant call from a listener never completed',
      );

      expect(failure, isNull);
      expect(unreadSeen, <int>[7, 7, 7]);
      expect(client.committedSeq('c1'), 13);

      await subscription.cancel();
      await client.dispose();
    });
  });
}
