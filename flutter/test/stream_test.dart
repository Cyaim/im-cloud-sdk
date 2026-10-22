import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `msg.streamBegin` / `streamAppend` / `streamComplete` / `streamAbort`, the `evt.stream` frames,
/// and the rule a signature cannot say: **a stream's frames are not messages — no seq, no cursor, no
/// repair — while the message a completed stream becomes goes through the normal path like any
/// other.**
///
/// Every call is asserted on the whole frame it puts on the wire and on what it makes of a reply
/// with every member set; every frame phase is decoded; the assembler is driven through the orders
/// the server can actually produce (its outbound queue lets the opening frame, the terminal frame
/// and the finished message jump ahead of queued low-priority fragments, and sheds those fragments
/// under backpressure). The last group feeds frames through the real delivery path and asserts on
/// the wire (no `msg.sync`) and on the cursors.
///
/// 每个调用断言整帧与全字段答复的解码；每种帧都解码；拼装按服务端真能产生的顺序走（出站队列里
/// 开流帧、终帧、最终消息会越过排队中的低优先级分片，背压时分片会被丢弃）；最后一组走真实投递路径，
/// 断言流帧不触发 msg.sync、不动游标，而最终消息照常走游标与补洞。
void main() {
  // Every member of the server's StreamHandle / SendMessageResult, each with a value no default
  // reads as, held to the inventory by 'the full fixtures and bodies carry every member'.
  const Map<String, dynamic> streamHandle = <String, dynamic>{
    'streamId': 'st_360381357961969001',
    'conversationId': 's_alice_bob',
    'startedAt': 1755000300000,
    'idleTimeoutSeconds': 30,
  };

  const Map<String, dynamic> sendResult = <String, dynamic>{
    'messageId': '360381357961969667',
    'seq': 11,
    'conversationId': 's_alice_bob',
    'clientMsgId': 'cm-stream-1',
    'createTime': 1755000304000,
    'deduplicated': true,
    'contentModified': true,
  };

  const ImMessageOptions everyOption = ImMessageOptions(
    persistent: false,
    updateConversation: false,
    countUnread: false,
    offlinePush: false,
    pushConfig: ImPushConfig(
      title: 'New reply',
      body: 'Assistant: …',
      sound: 'chime',
      payload: <String, String>{'route': '/chat/s_alice_bob'},
      badgeCount: false,
      channelId: 'im_messages',
    ),
    needReceipt: true,
    priority: ImMessagePriority.high,
    onlineOnly: true,
    noSelfSync: true,
    expireIn: 5000,
    moderationBypass: true,
  );

  ImBeginStreamRequest fullBegin() => ImBeginStreamRequest(
        conversationId: 's_alice_bob',
        receiverId: 'bob',
        groupId: 'team',
        clientMsgId: 'cm-stream-1',
        contentType: ImMessageContentType.custom,
        placeholder: const <String, dynamic>{
          'name': 'Assistant',
          'avatar': 'https://cdn.test/a.png'
        },
        options: everyOption,
        extensions: const <String, dynamic>{'model': 'house-7b'},
      );

  FakeGateway streamGateway() => FakeGateway()
    ..on('msg.streamBegin', (FakeRequest _) => const FakeData(streamHandle))
    ..on('msg.streamComplete', (FakeRequest _) => const FakeData(sendResult));

  /// One `evt.stream` frame as the server pushes it: camelCase, nulls omitted.
  Map<String, dynamic> frame(
    int index, {
    String streamId = 'st_1',
    String? delta,
    bool done = false,
    Object? messageId,
    Object? seq,
    String? abortReason,
    Map<String, dynamic>? placeholder,
  }) =>
      <String, dynamic>{
        'streamId': streamId,
        'conversationId': 's_alice_bob',
        'senderId': 'bot-1',
        'index': index,
        if (delta != null) 'delta': delta,
        'done': done,
        if (messageId != null) 'messageId': messageId,
        if (seq != null) 'seq': seq,
        if (abortReason != null) 'abortReason': abortReason,
        if (placeholder != null) 'placeholder': placeholder,
      };

  ImStreamEvent event(Map<String, dynamic> data) => ImStreamEvent.tryParse(data)!;

  group('msg.streamBegin', () {
    test('sends every member under exact camelCase keys and decodes the handle', () async {
      final FakeGateway gateway = streamGateway();
      final ImClient client = await connectedClient(gateway);

      final ImStreamHandle handle = await client.msg.streamBegin(fullBegin());

      expect(gateway.requestsTo('msg.streamBegin').single.body, <String, dynamic>{
        'conversationId': 's_alice_bob',
        'receiverId': 'bob',
        'groupId': 'team',
        'clientMsgId': 'cm-stream-1',
        'contentType': 100,
        'placeholder': <String, dynamic>{'name': 'Assistant', 'avatar': 'https://cdn.test/a.png'},
        // Nested, where the binder matches names case-sensitively and drops a miscased one silently.
        'options': <String, dynamic>{
          'persistent': false,
          'updateConversation': false,
          'countUnread': false,
          'offlinePush': false,
          'pushConfig': <String, dynamic>{
            'title': 'New reply',
            'body': 'Assistant: …',
            'sound': 'chime',
            'payload': <String, dynamic>{'route': '/chat/s_alice_bob'},
            'badgeCount': false,
            'channelId': 'im_messages',
          },
          'needReceipt': true,
          'priority': 2,
          'onlineOnly': true,
          'noSelfSync': true,
          'expireIn': 5000,
          'moderationBypass': true,
        },
        'extensions': <String, dynamic>{'model': 'house-7b'},
      });

      expect(handle.streamId, 'st_360381357961969001');
      expect(handle.conversationId, 's_alice_bob');
      expect(handle.startedAt, 1755000300000);
      expect(handle.idleTimeoutSeconds, 30);

      await client.dispose();
    });

    test('a minimal begin sends the address, a generated client message id and the content type',
        () async {
      final FakeGateway gateway = FakeGateway()
        ..on(
          'msg.streamBegin',
          (FakeRequest _) => const FakeData(<String, dynamic>{
            'streamId': 'st_2',
            'conversationId': 's_alice_bob',
            'startedAt': '1755000300000',
          }),
        );
      final ImClient client = await connectedClient(gateway);

      final ImStreamHandle handle =
          await client.msg.streamBegin(ImBeginStreamRequest(receiverId: 'bob'));

      final Map<String, dynamic> body = gateway.requestsTo('msg.streamBegin').single.body;
      expect(body.keys.toSet(), <String>{'receiverId', 'clientMsgId', 'contentType'},
          reason: 'nulls are omitted, not sent');
      expect(body['clientMsgId'],
          isA<String>().having((String s) => s.isNotEmpty, 'non-empty', isTrue),
          reason: 'the server answers 1001 without one and does not make one up');
      expect(body['contentType'], 1, reason: 'text, as an integer');
      expect(handle.startedAt, 1755000300000, reason: 'a long may arrive as a string');
      expect(handle.idleTimeoutSeconds, 0);

      await client.dispose();
    });

    test('surfaces the begin-time refusals as their codes', () async {
      final List<int> codes = <int>[1001, 1008, 1003, 1103, 1104, 1302, 1503];
      final FakeGateway gateway = FakeGateway()
        ..script('msg.streamBegin', <FakeReply>[for (final int code in codes) FakeFail(code)]);
      final ImClient client = await connectedClient(gateway);

      for (final int code in codes) {
        await expectLater(
          client.msg.streamBegin(ImBeginStreamRequest(groupId: 'team')),
          throwsA(isA<ImException>().having((ImException e) => e.code, 'code', code)),
        );
      }

      await client.dispose();
    });
  });

  group('msg.streamAppend', () {
    test('sends the stream id and the fragment, empty or not', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.msg.streamAppend(const ImStreamAppendRequest(streamId: 'st_1', delta: 'Hel'));
      await client.msg.streamAppend(const ImStreamAppendRequest(streamId: 'st_1', delta: ''));

      final List<FakeRequest> frames = gateway.requestsTo('msg.streamAppend');
      expect(frames[0].body, <String, dynamic>{'streamId': 'st_1', 'delta': 'Hel'});
      // The server accepts an empty fragment and drops it; refusing it here would invent a rule.
      expect(frames[1].body, <String, dynamic>{'streamId': 'st_1', 'delta': ''});

      await client.dispose();
    });

    test('surfaces the append refusals as their codes', () async {
      final List<int> codes = <int>[1401, 1002, 1103, 1003, 1001];
      final FakeGateway gateway = FakeGateway()
        ..script('msg.streamAppend', <FakeReply>[for (final int code in codes) FakeFail(code)]);
      final ImClient client = await connectedClient(gateway);

      for (final int code in codes) {
        await expectLater(
          client.msg.streamAppend(const ImStreamAppendRequest(streamId: 'st_1', delta: 'x')),
          throwsA(isA<ImException>().having((ImException e) => e.code, 'code', code)),
        );
      }

      await client.dispose();
    });
  });

  group('msg.streamComplete', () {
    test('sends the stream id, content and extensions, decodes the result, and writes no cursor',
        () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'s_alice_bob': 10}),
      );
      final FakeGateway gateway = streamGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final ImSendResult result = await client.msg.streamComplete(const ImCompleteStreamRequest(
        streamId: 'st_1',
        content: <String, dynamic>{'text': 'Hello, world.'},
        extensions: <String, dynamic>{'tokens': 42},
      ));

      expect(gateway.requestsTo('msg.streamComplete').single.body, <String, dynamic>{
        'streamId': 'st_1',
        'content': <String, dynamic>{'text': 'Hello, world.'},
        'extensions': <String, dynamic>{'tokens': 42},
      });

      expect(result.messageId, '360381357961969667');
      expect(result.seq, 11);
      expect(result.conversationId, 's_alice_bob');
      expect(result.clientMsgId, 'cm-stream-1');
      expect(result.createTime, 1755000304000);
      expect(result.deduplicated, isTrue);
      expect(result.contentModified, isTrue);

      // The message itself arrives on evt.message and moves the cursor there; the result does not.
      expect(client.deliveredSeq('s_alice_bob'), 10);
      expect(gateway.callsTo('msg.sync'), 0);

      await client.dispose();
    });

    test('a bare complete sends only the stream id, so the server joins the fragments', () async {
      final FakeGateway gateway = streamGateway();
      final ImClient client = await connectedClient(gateway);

      await client.msg.streamComplete(const ImCompleteStreamRequest(streamId: 'st_1'));
      expect(gateway.requestsTo('msg.streamComplete').single.body,
          <String, dynamic>{'streamId': 'st_1'});

      await client.dispose();
    });

    test('surfaces a second complete and a send-pipeline refusal as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('msg.streamComplete', const <FakeReply>[
          FakeFail(ImErrorCode.notFound, message: 'stream not found; it has finished or expired'),
          FakeFail(ImErrorCode.forbidden),
        ]);
      final ImClient client = await connectedClient(gateway);

      for (final int code in <int>[1002, 1103]) {
        await expectLater(
          client.msg.streamComplete(const ImCompleteStreamRequest(streamId: 'st_1')),
          throwsA(isA<ImException>().having((ImException e) => e.code, 'code', code)),
        );
      }

      await client.dispose();
    });
  });

  group('msg.streamAbort', () {
    test('sends the stream id and the reason, and leaves a blank reason out', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.msg.streamAbort(
          const ImStreamAbortRequest(streamId: 'st_1', reason: 'the user pressed stop'));
      await client.msg.streamAbort(const ImStreamAbortRequest(streamId: 'st_2'));

      final List<FakeRequest> frames = gateway.requestsTo('msg.streamAbort');
      expect(
          frames[0].body, <String, dynamic>{'streamId': 'st_1', 'reason': 'the user pressed stop'});
      expect(frames[1].body, <String, dynamic>{'streamId': 'st_2'});

      await client.dispose();
    });
  });

  group('ImStreamWriter', () {
    test('begin, append, complete: the raw calls in order, on the stream id begin returned',
        () async {
      final FakeGateway gateway = streamGateway();
      final ImClient client = await connectedClient(gateway);

      final ImStreamWriter writer = await ImStreamWriter.begin(
          client.msg, ImBeginStreamRequest(receiverId: 'bob', clientMsgId: 'cm-stream-1'));
      expect(writer.streamId, 'st_360381357961969001');
      expect(writer.handle.idleTimeoutSeconds, 30);

      await writer.append('Hello');
      await writer.append(', world.');
      final ImSendResult result =
          await writer.complete(extensions: const <String, dynamic>{'tokens': 2});

      expect(gateway.targets.where((String t) => t.startsWith('msg.')), <String>[
        'msg.streamBegin',
        'msg.streamAppend',
        'msg.streamAppend',
        'msg.streamComplete',
      ]);
      expect(gateway.requestsTo('msg.streamAppend').map((FakeRequest r) => r.body), <Object>[
        <String, dynamic>{'streamId': 'st_360381357961969001', 'delta': 'Hello'},
        <String, dynamic>{'streamId': 'st_360381357961969001', 'delta': ', world.'},
      ]);
      expect(gateway.requestsTo('msg.streamComplete').single.body, <String, dynamic>{
        'streamId': 'st_360381357961969001',
        'extensions': <String, dynamic>{'tokens': 2},
      });
      expect(result.messageId, '360381357961969667');

      await client.dispose();
    });

    test('abort sends the reason on the stream id', () async {
      final FakeGateway gateway = streamGateway();
      final ImClient client = await connectedClient(gateway);

      final ImStreamWriter writer =
          await ImStreamWriter.begin(client.msg, ImBeginStreamRequest(groupId: 'team'));
      await writer.abort('model timed out');

      expect(gateway.requestsTo('msg.streamAbort').single.body,
          <String, dynamic>{'streamId': 'st_360381357961969001', 'reason': 'model timed out'});

      await client.dispose();
    });
  });

  group('evt.stream frames decode', () {
    test('each phase, with every member it carries', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);
      final List<ImStreamEvent> received = <ImStreamEvent>[];
      final StreamSubscription<ImStreamEvent> subscription =
          client.streamEvents.listen(received.add);

      gateway.socket
        ..deliver(push(ImPushTarget.stream,
            frame(0, placeholder: const <String, dynamic>{'name': 'Assistant'})))
        ..deliver(push(ImPushTarget.stream, frame(1, delta: 'Hel')))
        ..deliver(push(
            ImPushTarget.stream, frame(2, done: true, messageId: '360381357961969667', seq: 11)))
        ..deliver(push(ImPushTarget.stream,
            frame(1, streamId: 'st_2', done: true, abortReason: 'aborted by the producer')))
        // Not stream frames: no stream id, not an object.
        ..deliver(push(ImPushTarget.stream, const <String, dynamic>{'index': 3, 'done': false}))
        ..deliver(<String, dynamic>{
          'id': 'srv-x',
          'target': 'evt.stream',
          'status': 0,
          'body': <String, dynamic>{
            'code': 0,
            'serverTime': 1,
            'data': <dynamic>[1, 2]
          },
        });

      await pumpUntil(() => received.length >= 4, because: 'four stream frames were pushed');
      await settle();
      expect(received, hasLength(4));

      final ImStreamEvent begin = received[0];
      expect(begin.phase, ImStreamPhase.begin);
      expect(begin.streamId, 'st_1');
      expect(begin.conversationId, 's_alice_bob');
      expect(begin.senderId, 'bot-1');
      expect(begin.index, 0);
      expect(begin.done, isFalse);
      expect(begin.delta, isNull, reason: 'the opening frame carries no delta key');
      expect(begin.placeholder, <String, dynamic>{'name': 'Assistant'});

      final ImStreamEvent delta = received[1];
      expect(delta.phase, ImStreamPhase.delta);
      expect(delta.index, 1, reason: 'the first append is index 1');
      expect(delta.delta, 'Hel');
      expect(delta.placeholder, isNull);
      expect(delta.messageId, isNull);

      final ImStreamEvent completed = received[2];
      expect(completed.phase, ImStreamPhase.completed);
      expect(completed.done, isTrue);
      expect(completed.index, 2, reason: 'one past the last fragment');
      expect(completed.messageId, '360381357961969667');
      expect(completed.seq, 11);
      expect(completed.abortReason, isNull);

      final ImStreamEvent aborted = received[3];
      expect(aborted.phase, ImStreamPhase.aborted);
      expect(aborted.streamId, 'st_2');
      expect(aborted.messageId, isNull);
      expect(aborted.seq, isNull);
      expect(aborted.abortReason, 'aborted by the producer');

      await subscription.cancel();
      await client.dispose();
    });

    test('a message id is read as a string even when it arrives as a number', () {
      final ImStreamEvent quoted = event(frame(3, done: true, messageId: '360381357961969667'));
      final ImStreamEvent bare = event(frame(3, done: true, messageId: 1234, seq: '12'));

      expect(quoted.messageId, '360381357961969667');
      expect(bare.messageId, '1234');
      expect(bare.seq, 12);
      expect(bare.phase, ImStreamPhase.completed);
    });

    test('a field this build does not type is kept in data', () {
      final ImStreamEvent decoded = event(<String, dynamic>{...frame(1, delta: 'x'), 'tokens': 1});
      expect(decoded.data['tokens'], 1);
    });

    test('evt.stream frames do not reach any other stream on the client', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);
      final List<ImRoomEvent> rooms = <ImRoomEvent>[];
      final List<ImMessage> messages = <ImMessage>[];
      final List<ImStreamEvent> streams = <ImStreamEvent>[];
      final List<StreamSubscription<Object>> subscriptions = <StreamSubscription<Object>>[
        client.roomEvents.listen(rooms.add),
        client.messages.listen(messages.add),
        client.streamEvents.listen(streams.add),
      ];

      gateway.socket.deliver(push(ImPushTarget.stream, frame(1, delta: 'x')));
      await pumpUntil(() => streams.isNotEmpty, because: 'the stream frame was not delivered');
      await settle();

      expect(rooms, isEmpty);
      expect(messages, isEmpty);

      for (final StreamSubscription<Object> subscription in subscriptions) {
        await subscription.cancel();
      }
      await client.dispose();
    });
  });

  group('ImStreamAssembler', () {
    test('in order: placeholder, fragments joined by index, completed with the message id', () {
      final ImStreamAssembler assembler = ImStreamAssembler();

      final ImStreamState opened = assembler
          .add(event(frame(0, placeholder: const <String, dynamic>{'name': 'Assistant'})))!;
      expect(opened.status, ImStreamStatus.streaming);
      expect(opened.sawBegin, isTrue);
      expect(opened.placeholder, <String, dynamic>{'name': 'Assistant'});
      expect(opened.text, '');

      assembler.add(event(frame(1, delta: 'Hel')));
      assembler.add(event(frame(2, delta: 'lo, ')));
      final ImStreamState third = assembler.add(event(frame(3, delta: 'world.')))!;
      expect(third.text, 'Hello, world.');
      expect(third.fragments, 3);
      expect(third.hasGap, isFalse);
      expect(assembler.active.map((ImStreamState s) => s.streamId), <String>['st_1']);

      final ImStreamState done =
          assembler.add(event(frame(4, done: true, messageId: '360381357961969667', seq: 11)))!;
      expect(done.status, ImStreamStatus.completed);
      expect(done.isFinished, isTrue);
      expect(done.text, 'Hello, world.',
          reason: 'what the server stores when complete has no content');
      expect(done.messageId, '360381357961969667');
      expect(done.seq, 11);
      expect(done.hasGap, isFalse);
      expect(done.conversationId, 's_alice_bob');
      expect(done.senderId, 'bot-1');
      expect(assembler.active, isEmpty);
      expect(assembler.stateOf('st_1')!.status, ImStreamStatus.completed);
    });

    test('an abort ends the stream with its reason and no message', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0)));
      assembler.add(event(frame(1, delta: 'Thinking')));

      final ImStreamState aborted = assembler
          .add(event(frame(2, done: true, abortReason: 'the producer stopped sending for 30s')))!;
      expect(aborted.status, ImStreamStatus.aborted);
      expect(aborted.abortReason, 'the producer stopped sending for 30s');
      expect(aborted.messageId, isNull);
      expect(aborted.seq, isNull);
      expect(aborted.text, 'Thinking');
      expect(aborted.hasGap, isFalse);
    });

    test('a stream completed with no fragment at all is whole and empty', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0)));
      final ImStreamState done =
          assembler.add(event(frame(1, done: true, messageId: '7', seq: 3)))!;

      expect(done.fragments, 0);
      expect(done.missingFragments, 0);
      expect(done.text, '');
    });

    test('fragments overtaken by the terminal frame fill the finished stream in when they land',
        () {
      // The server's per-connection queue sends normal frames before queued low ones: the terminal
      // frame (normal) can overtake fragments 2 and 3 (low).
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0)));
      assembler.add(event(frame(1, delta: 'A')));

      final ImStreamState early =
          assembler.add(event(frame(4, done: true, messageId: '360381357961969667', seq: 11)))!;
      expect(early.status, ImStreamStatus.completed);
      expect(early.text, 'A');
      expect(early.missingFragments, 2,
          reason: 'the terminal index says three fragments were sent');
      expect(early.hasGap, isTrue);

      final ImStreamState partly = assembler.add(event(frame(3, delta: 'C')))!;
      expect(partly.text, 'AC', reason: 'holes are skipped, order kept');
      expect(partly.missingFragments, 1);
      expect(partly.status, ImStreamStatus.completed, reason: 'a late fragment does not reopen it');

      final ImStreamState whole = assembler.add(event(frame(2, delta: 'B')))!;
      expect(whole.text, 'ABC');
      expect(whole.hasGap, isFalse);
      expect(assembler.active, isEmpty, reason: 'no stream was opened for the late fragments');
    });

    test('a duplicate fragment, opening frame or terminal frame changes nothing', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0)));
      assembler.add(event(frame(1, delta: 'A')));

      expect(assembler.add(event(frame(0))), isNull);
      expect(assembler.add(event(frame(1, delta: 'A'))), isNull);
      assembler.add(event(frame(3, delta: 'C')));
      expect(assembler.add(event(frame(3, delta: 'C'))), isNull, reason: 'a pending fragment too');

      assembler.add(event(frame(4, done: true, abortReason: 'stop')));
      expect(assembler.add(event(frame(4, done: true, abortReason: 'stop'))), isNull);
      expect(assembler.add(event(frame(0))), isNull, reason: 'a late opening frame is ignored');
      expect(assembler.add(event(frame(1, delta: 'A'))), isNull);
      expect(assembler.stateOf('st_1')!.text, 'AC');
    });

    test('a shed fragment is a hole, counted and not repaired', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0)));
      assembler.add(event(frame(1, delta: 'A')));
      final ImStreamState holed = assembler.add(event(frame(3, delta: 'C')))!;

      expect(holed.text, 'AC');
      expect(holed.fragments, 2);
      expect(holed.missingFragments, 1);
      expect(holed.hasGap, isTrue);

      final ImStreamState done =
          assembler.add(event(frame(4, done: true, messageId: '9', seq: 5)))!;
      expect(done.hasGap, isTrue,
          reason: 'the stored message, not this text, is the whole reply: wait for it');
    });

    test('joining midway: no opening frame, the earlier fragments counted missing', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      final ImStreamState joined = assembler.add(event(frame(3, delta: 'C')))!;

      expect(joined.sawBegin, isFalse);
      expect(joined.placeholder, isNull);
      expect(joined.text, 'C');
      expect(joined.missingFragments, 2);
      expect(joined.status, ImStreamStatus.streaming);
    });

    test('streams are kept apart by stream id', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0, streamId: 'st_a')));
      assembler.add(event(frame(0, streamId: 'st_b')));
      assembler.add(event(frame(1, streamId: 'st_a', delta: 'one')));
      assembler.add(event(frame(1, streamId: 'st_b', delta: 'two')));
      assembler.add(event(frame(2, streamId: 'st_a', done: true, messageId: '1', seq: 1)));

      expect(assembler.stateOf('st_a')!.text, 'one');
      expect(assembler.stateOf('st_a')!.isFinished, isTrue);
      expect(assembler.stateOf('st_b')!.text, 'two');
      expect(assembler.active.map((ImStreamState s) => s.streamId), <String>['st_b']);
    });

    test('forget and clear stop tracking a stream, and its later frames are ignored', () {
      final ImStreamAssembler assembler = ImStreamAssembler();
      assembler.add(event(frame(0, streamId: 'st_a')));
      assembler.add(event(frame(1, streamId: 'st_a', delta: 'x')));
      assembler.add(event(frame(0, streamId: 'st_b')));
      assembler.add(event(frame(0, streamId: 'st_c')));

      expect(assembler.forget('st_a')!.text, 'x');
      expect(assembler.add(event(frame(2, streamId: 'st_a', delta: 'y'))), isNull);
      expect(assembler.add(event(frame(3, streamId: 'st_a', done: true, messageId: '1'))), isNull);
      expect(assembler.forget('st_unknown'), isNull);

      final List<ImStreamState> cleared = assembler.clear();
      expect(
          cleared.map((ImStreamState s) => s.streamId), unorderedEquals(<String>['st_b', 'st_c']));
      expect(assembler.active, isEmpty);
      expect(assembler.add(event(frame(1, streamId: 'st_b', delta: 'late'))), isNull);
    });

    test('only the last rememberFinished finished streams are kept', () {
      final ImStreamAssembler assembler = ImStreamAssembler(rememberFinished: 2);
      for (final String id in <String>['st_1', 'st_2', 'st_3']) {
        assembler.add(event(frame(1, streamId: id, done: true, abortReason: 'stop')));
      }

      expect(assembler.stateOf('st_1'), isNull, reason: 'the oldest was evicted');
      expect(assembler.stateOf('st_2'), isNotNull);
      expect(assembler.stateOf('st_3'), isNotNull);
    });

    test('transforms ImClient.streamEvents into states', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);
      final List<ImStreamState> states = <ImStreamState>[];
      final StreamSubscription<ImStreamState> subscription =
          client.streamEvents.transform(ImStreamAssembler()).listen(states.add);

      gateway.socket
        ..deliver(push(ImPushTarget.stream, frame(0)))
        ..deliver(push(ImPushTarget.stream, frame(1, delta: 'Hi')))
        ..deliver(push(ImPushTarget.stream, frame(1, delta: 'Hi')))
        ..deliver(push(ImPushTarget.stream, frame(2, done: true, messageId: '42', seq: 3)));

      await pumpUntil(() => states.length >= 3, because: 'three frames changed the stream');
      await settle();

      expect(
          states.map((ImStreamState s) => s.status),
          <ImStreamStatus>[
            ImStreamStatus.streaming,
            ImStreamStatus.streaming,
            ImStreamStatus.completed,
          ],
          reason: 'the duplicate fragment produced no state');
      expect(states.last.text, 'Hi');

      await subscription.cancel();
      await client.dispose();
    });
  });

  group('stream frames stay out of the message path; the finished message does not', () {
    Map<String, dynamic> finished(int seq) => <String, dynamic>{
          ...message('s_alice_bob', seq),
          'messageId': '360381357961969667',
          'clientMsgId': 'cm-stream-1',
          'senderId': 'bot-1',
          'content': <String, dynamic>{'text': 'Hello, world.'},
        };

    test('frames move no cursor and ask for no repair; the message moves the cursor', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'s_alice_bob': 10}),
      );
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<ImMessage> delivered = <ImMessage>[];
      final List<ImStreamState> states = <ImStreamState>[];
      final List<StreamSubscription<Object>> subscriptions = <StreamSubscription<Object>>[
        client.messages.listen(delivered.add),
        client.streamEvents.transform(ImStreamAssembler()).listen(states.add),
      ];

      gateway.socket
        ..deliver(push(ImPushTarget.stream, frame(0)))
        ..deliver(push(ImPushTarget.stream, frame(1, delta: 'Hello, ')))
        ..deliver(push(ImPushTarget.stream, frame(2, delta: 'world.')))
        // The terminal frame names seq 13 — two past the cursor. It is the message's seq, for
        // matching; read as a position it would open a false gap over 11 and 12.
        ..deliver(push(
            ImPushTarget.stream, frame(3, done: true, messageId: '360381357961969667', seq: 13)));

      await pumpUntil(() => states.length == 4, because: 'four stream frames were pushed');
      await settle();

      expect(delivered, isEmpty, reason: 'a stream frame is not a message');
      expect(gateway.callsTo('msg.sync'), 0, reason: 'a stream frame has no range to repair');
      expect(client.deliveredSeq('s_alice_bob'), 10);
      expect(states.last.text, 'Hello, world.');

      // The finished message, contiguous with the cursor: delivered, cursor moved, no repair.
      gateway.socket.deliver(push(ImPushTarget.message, finished(11)));
      await pumpUntil(() => delivered.isNotEmpty,
          because: 'the finished message was not delivered');
      await settle();

      expect(delivered.single.messageId, states.last.messageId,
          reason: 'the terminal frame names the message that replaces the placeholder');
      expect(delivered.single.content['text'], states.last.text);
      expect(client.deliveredSeq('s_alice_bob'), 11);
      expect(gateway.callsTo('msg.sync'), 0);

      for (final StreamSubscription<Object> subscription in subscriptions) {
        await subscription.cancel();
      }
      await client.dispose();
    });

    test('the finished message goes through gap repair like any other', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'s_alice_bob': 10}),
      );
      final FakeGateway gateway = FakeGateway()
        ..on(
          'msg.sync',
          (FakeRequest _) => FakeData(
              syncPage(conversationId: 's_alice_bob', seqs: <int>[11, 12], hasMore: false)),
        );
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<int> delivered = <int>[];
      final StreamSubscription<ImMessage> subscription =
          client.messages.listen((ImMessage m) => delivered.add(m.seq));

      // The message arrives before its own terminal frame — the order is not guaranteed.
      gateway.socket.deliver(push(ImPushTarget.message, finished(13)));
      gateway.socket.deliver(push(
          ImPushTarget.stream, frame(3, done: true, messageId: '360381357961969667', seq: 13)));

      await pumpUntil(() => delivered.length == 3, because: '11 and 12 were repaired, then 13');
      await settle();

      expect(delivered, <int>[11, 12, 13]);
      expect(gateway.callsTo('msg.sync'), 1);
      expect(client.deliveredSeq('s_alice_bob'), 13);

      await subscription.cancel();
      await client.dispose();
    });
  });

  // The decoding tests above are only as wide as their fixtures, and the frame tests only as wide as
  // the bodies they build: so the full fixtures and bodies carry every member the server's type
  // declares, held here to endpoint-inventory.json's payloadTypes.
  test('the full fixtures and bodies carry every member the server declares', () {
    final Map<String, dynamic> types = inventory()['payloadTypes'] as Map<String, dynamic>;
    Set<String> members(String type) => <String>{
          for (final dynamic property
              in (types[type] as Map<String, dynamic>)['properties'] as List<dynamic>)
            (property as Map<String, dynamic>)['name'] as String,
        };

    expect(streamHandle.keys.toSet(), members('StreamHandle'));
    expect(sendResult.keys.toSet(), members('SendMessageResult'));

    final Map<String, Object?> begin = fullBegin().toJson();
    expect(begin.keys.toSet(), members('BeginStreamRequest'));
    final Map<String, Object?> options = begin['options']! as Map<String, Object?>;
    expect(options.keys.toSet(), members('MessageOptions'));
    expect((options['pushConfig']! as Map<String, Object?>).keys.toSet(), members('PushConfig'));

    expect(const ImStreamAppendRequest(streamId: 's', delta: 'd').toJson().keys.toSet(),
        members('StreamAppendRequest'));
    expect(
        const ImCompleteStreamRequest(
          streamId: 's',
          content: <String, dynamic>{'text': 't'},
          extensions: <String, dynamic>{'k': 'v'},
        ).toJson().keys.toSet(),
        members('CompleteStreamRequest'));
    expect(const ImStreamAbortRequest(streamId: 's', reason: 'r').toJson().keys.toSet(),
        members('StreamAbortRequest'));

    // The push payload is not in payloadTypes (no endpoint returns it). Its members are the
    // server's StreamDelta (IStreamingMessageService.cs) plus StreamBeginFrame's placeholder; a
    // frame carrying all of them decodes every one.
    // 推送载荷不在 payloadTypes 里：成员取自服务端 StreamDelta，外加开流帧的 placeholder。
    const Map<String, dynamic> everyMember = <String, dynamic>{
      'streamId': 'st_1',
      'conversationId': 's_alice_bob',
      'senderId': 'bot-1',
      'index': 5,
      'delta': 'd',
      'done': true,
      'messageId': '360381357961969667',
      'seq': 11,
      'abortReason': 'r',
      'placeholder': <String, dynamic>{'name': 'n'},
    };
    final ImStreamEvent decoded = event(everyMember);
    expect(<String, Object?>{
      'streamId': decoded.streamId,
      'conversationId': decoded.conversationId,
      'senderId': decoded.senderId,
      'index': decoded.index,
      'delta': decoded.delta,
      'done': decoded.done,
      'messageId': decoded.messageId,
      'seq': decoded.seq,
      'abortReason': decoded.abortReason,
      'placeholder': decoded.placeholder,
    }, everyMember);
  });

  test('the four stream targets are the inventory\'s, with their DTOs, and evt.stream its push',
      () {
    final Map<String, dynamic> parsed = inventory();
    final Map<String, Map<String, dynamic>> streams = <String, Map<String, dynamic>>{
      for (final dynamic endpoint in parsed['endpoints'] as List<dynamic>)
        if (((endpoint as Map<String, dynamic>)['target'] as String).startsWith('msg.stream'))
          endpoint['target'] as String: endpoint,
    };

    expect(streams.keys.toSet(), <String>{
      'msg.streamBegin',
      'msg.streamAppend',
      'msg.streamComplete',
      'msg.streamAbort',
    });
    expect(streams['msg.streamBegin']!['requestType'], 'BeginStreamRequest');
    expect(streams['msg.streamBegin']!['responseType'], 'StreamHandle');
    expect(streams['msg.streamAppend']!['requestType'], 'StreamAppendRequest');
    expect(streams['msg.streamAppend']!['responseType'], isNull);
    expect(streams['msg.streamComplete']!['requestType'], 'CompleteStreamRequest');
    expect(streams['msg.streamComplete']!['responseType'], 'SendMessageResult');
    expect(streams['msg.streamAbort']!['requestType'], 'StreamAbortRequest');
    expect(streams['msg.streamAbort']!['responseType'], isNull);

    expect((parsed['pushTargets'] as Map<String, dynamic>)['Stream'], ImPushTarget.stream);
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
