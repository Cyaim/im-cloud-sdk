import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `room.*` — the seven chat-room verbs, the `room.*` events inside `evt.system`, and the rule a
/// signature cannot say: **a room message carries `seq` 0 and must never reach gap repair or a
/// cursor.**
///
/// Every verb is asserted on the frame it puts on the wire — target and the whole body — and on what
/// it makes of a reply with every member set. The seq-0 group feeds room messages through the real
/// delivery path and asserts on the wire (no `msg.sync`) and on the cursors (nothing moved), because
/// a room message that slipped into the repair path would look fine on the message stream: it is the
/// extra traffic and the corrupted next-message gap check that give it away.
///
/// 每个动词断言它发出的整帧与对全字段答复的解码；seq 为 0 的聊天室消息走真实的投递路径，
/// 断言线路上没有 msg.sync、游标一个都没动——混进补洞路径的聊天室消息在消息流上看不出来。
void main() {
  // Every member of the server's ChatRoom, each with a value no default reads as, so a key spelled
  // wrong in fromJson decodes to a default and an expectation below fails. Held to the inventory
  // by 'the full fixtures carry every member the server declares'.
  const Map<String, dynamic> chatRoom = <String, dynamic>{
    'appId': 'demo',
    'roomId': 'live-1',
    'name': 'Launch night',
    'avatar': 'https://cdn.test/live-1.png',
    'ownerId': 'host',
    'admins': <dynamic>['mod-1', 'mod-2'],
    'maxOnline': 100000,
    'historyBufferSize': 30,
    'rateLimitPerSecond': 250,
    'muteAll': true,
    'destroyed': false,
    'createdAt': 1755000000000,
    'extensions': <String, dynamic>{'theme': 'dark'},
  };

  /// A room message as the server pushes it and buffers it: seq 0, `r_<roomId>`, type 3.
  Map<String, dynamic> roomMessage(String roomId, int n) => <String, dynamic>{
        'appId': 'demo',
        'conversationId': 'r_$roomId',
        'conversationType': 3,
        'seq': 0,
        'messageId': '36038135796196${9660 + n}',
        'clientMsgId': 'room-$n',
        'senderId': 'viewer-$n',
        'senderPlatform': 1,
        'contentType': 1,
        'content': <String, dynamic>{'text': 'hello $n'},
        'mentionAll': false,
        'options': <String, dynamic>{
          'persistent': false,
          'updateConversation': false,
          'countUnread': false,
          'offlinePush': false,
          'onlineOnly': true,
          'priority': 1,
        },
        'status': 1,
        'sendTime': 1755000100000 + n,
        'createTime': 1755000100500 + n,
      };

  final Map<String, dynamic> joinResult = <String, dynamic>{
    'room': chatRoom,
    'onlineCount': 4321,
    'recent': <dynamic>[roomMessage('live-1', 1), roomMessage('live-1', 2)],
  };

  const Map<String, dynamic> sendResult = <String, dynamic>{
    'messageId': '360381357961969667',
    'seq': 0,
    'conversationId': 'r_live-1',
    'clientMsgId': 'cm-room-1',
    'createTime': 1755000200000,
    'deduplicated': true,
    'contentModified': true,
  };

  FakeGateway roomGateway() => FakeGateway()
    ..on('room.join', (FakeRequest _) => FakeData(joinResult))
    ..on('room.send', (FakeRequest _) => const FakeData(sendResult))
    ..on('room.onlineCount', (FakeRequest _) => const FakeData(4321))
    ..on(
      'room.memberList',
      (FakeRequest request) => FakeData(request.body['cursor'] == null
          ? const <String, dynamic>{
              'items': <dynamic>['viewer-1', 'viewer-2'],
              'nextCursor': '1',
              'hasMore': true,
            }
          : const <String, dynamic>{'items': <dynamic>[], 'hasMore': false}),
    );

  group('room.join', () {
    test('sends the room id and decodes the room, its count and its buffer', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      final ImRoomJoinResult joined = await client.room.join(const ImRoomIdRequest(roomId: 'live-1'));
      expect(gateway.requestsTo('room.join').single.body, <String, dynamic>{'roomId': 'live-1'});

      final ImChatRoom room = joined.room;
      expect(room.appId, 'demo');
      expect(room.roomId, 'live-1');
      expect(room.name, 'Launch night');
      expect(room.avatar, 'https://cdn.test/live-1.png');
      expect(room.ownerId, 'host');
      expect(room.admins, <String>['mod-1', 'mod-2']);
      expect(room.maxOnline, 100000);
      expect(room.historyBufferSize, 30);
      expect(room.rateLimitPerSecond, 250);
      expect(room.muteAll, isTrue);
      expect(room.destroyed, isFalse);
      expect(room.createdAt, 1755000000000);
      expect(room.extensions, <String, dynamic>{'theme': 'dark'});

      expect(joined.onlineCount, 4321);
      expect(joined.recent.map((ImMessage m) => m.clientMsgId), <String>['room-1', 'room-2'],
          reason: 'the ring buffer is oldest first');
      expect(joined.recent.first.seq, 0);
      expect(joined.recent.first.conversationId, 'r_live-1');
      expect(joined.recent.first.conversationType, ImConversationType.chatRoom);
      expect(joined.recent.first.messageId, '360381357961969661');

      // The buffer is handed to the caller and that is all: not replayed onto the message stream,
      // not a cursor.
      expect(client.cursors.convSeqs, isEmpty);
      expect(gateway.callsTo('msg.sync'), 0);

      await client.dispose();
    });

    test('decodes a room with its optional members absent', () async {
      final FakeGateway gateway = FakeGateway()
        ..on(
          'room.join',
          (FakeRequest _) => const FakeData(<String, dynamic>{
            'room': <String, dynamic>{'appId': 'demo', 'roomId': 'live-2', 'ownerId': 'host'},
            'onlineCount': '7',
          }),
        );
      final ImClient client = await connectedClient(gateway);

      final ImRoomJoinResult joined = await client.room.join(const ImRoomIdRequest(roomId: 'live-2'));
      expect(joined.room.avatar, isNull);
      expect(joined.room.admins, isEmpty);
      expect(joined.room.extensions, isEmpty);
      expect(joined.onlineCount, 7, reason: 'a long may arrive as a string');
      expect(joined.recent, isEmpty);

      await client.dispose();
    });

    test('surfaces RoomFull and RoomNotFound as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('room.join', const <FakeReply>[
          FakeFail(ImErrorCode.roomFull, message: 'room is full'),
          FakeFail(ImErrorCode.roomNotFound, message: 'room not found'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.room.join(const ImRoomIdRequest(roomId: 'live-1')),
        throwsA(isA<ImException>().having((ImException e) => e.code, 'code', 1601)),
      );
      await expectLater(
        client.room.join(const ImRoomIdRequest(roomId: 'nobody-made-this')),
        throwsA(isA<ImException>().having((ImException e) => e.code, 'code', 1600)),
      );

      await client.dispose();
    });
  });

  group('room.quit', () {
    test('sends the room id', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      await client.room.quit(const ImRoomIdRequest(roomId: 'live-1'));
      expect(gateway.requestsTo('room.quit').single.body, <String, dynamic>{'roomId': 'live-1'});

      await client.dispose();
    });
  });

  group('room.send', () {
    test('nests the message under exact camelCase keys and writes no cursor from seq 0', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      final ImSendResult sent = await client.room.send(ImRoomSendRequest(
        roomId: 'live-1',
        message: ImRoomMessage(
          content: const <String, dynamic>{'gift': 'rose', 'count': 3},
          contentType: const ImMessageContentType(100),
          clientMsgId: 'cm-room-1',
          mentionAll: true,
          mentionedUserIds: const <String>['host'],
          priority: ImMessagePriority.high,
          sendTime: 1755000199000,
          extensions: const <String, dynamic>{'origin': 'gift-bar'},
        ),
      ));

      expect(gateway.requestsTo('room.send').single.body, <String, dynamic>{
        'roomId': 'live-1',
        'message': <String, dynamic>{
          'clientMsgId': 'cm-room-1',
          'contentType': 100,
          'content': <String, dynamic>{'gift': 'rose', 'count': 3},
          'mentionAll': true,
          'mentionedUserIds': <dynamic>['host'],
          'options': <String, dynamic>{'priority': 2},
          'sendTime': 1755000199000,
          'extensions': <String, dynamic>{'origin': 'gift-bar'},
        },
      });

      expect(sent.messageId, '360381357961969667');
      expect(sent.seq, 0);
      expect(sent.conversationId, 'r_live-1');
      expect(sent.clientMsgId, 'cm-room-1');
      expect(sent.createTime, 1755000200000);
      expect(sent.deduplicated, isTrue);
      expect(sent.contentModified, isTrue);

      // The legacy flat send marks its result's seq as delivered so our own message is not read as
      // a gap; a room send must not — there is no position to mark.
      expect(client.deliveredSeq('r_live-1'), 0);
      expect(client.committedSeq('r_live-1'), 0);
      expect(client.cursors.convSeqs, isEmpty);
      expect(gateway.targets.where((String t) => t.startsWith('msg.')), isEmpty,
          reason: 'room.send is its own target, not msg.send with a different address');

      await client.dispose();
    });

    test('text() fills in a client message id and sends the priority a room sheds by', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      await client.room.send(ImRoomSendRequest.text('live-1', '🌹', priority: ImMessagePriority.low));
      await client.room.send(ImRoomSendRequest.text('live-1', 'plain', clientMsgId: 'cm-2'));

      final List<FakeRequest> frames = gateway.requestsTo('room.send');
      final Map<String, dynamic> low = frames[0].body['message'] as Map<String, dynamic>;
      expect(low['clientMsgId'], isA<String>().having((String s) => s.isNotEmpty, 'non-empty', isTrue),
          reason: 'the server answers 1001 without one');
      expect(low['contentType'], 1);
      expect(low['content'], <String, dynamic>{'text': '🌹'});
      expect(low['sendTime'], isA<int>());
      expect(low['options'], <String, dynamic>{'priority': 0},
          reason: 'priority goes out as the integer the server enum declares, and it is the only '
              'option a room reads');
      expect(low.keys.toSet(), <String>{'clientMsgId', 'contentType', 'content', 'mentionAll', 'options', 'sendTime'},
          reason: 'no address, quote or thread member: the room is the address');

      final Map<String, dynamic> plain = frames[1].body['message'] as Map<String, dynamic>;
      expect(plain['clientMsgId'], 'cm-2');
      expect(plain.containsKey('options'), isFalse, reason: 'no priority, no options object');
      expect(frames[1].body.keys, <String>['roomId', 'message']);

      await client.dispose();
    });

    test('surfaces the room refusals as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('room.send', const <FakeReply>[
          FakeFail(ImErrorCode.notInRoom, message: 'join the room before sending to it'),
          FakeFail(ImErrorCode.memberMuted, message: 'you are muted in this room'),
          FakeFail(ImErrorCode.roomMuted, message: 'the room is muted'),
        ]);
      final ImClient client = await connectedClient(gateway);

      for (final int code in <int>[1602, 1506, 1603]) {
        await expectLater(
          client.room.send(ImRoomSendRequest.text('live-1', 'hi')),
          throwsA(isA<ImException>().having((ImException e) => e.code, 'code', code)),
        );
      }

      await client.dispose();
    });
  });

  group('room.onlineCount', () {
    test('sends the room id and reads the bare number the server answers', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      expect(await client.room.onlineCount(const ImRoomIdRequest(roomId: 'live-1')), 4321);
      expect(gateway.requestsTo('room.onlineCount').single.body, <String, dynamic>{'roomId': 'live-1'});

      gateway.on('room.onlineCount', (FakeRequest _) => const FakeData('9007199254740993'));
      expect(await client.room.onlineCount(const ImRoomIdRequest(roomId: 'live-1')), 9007199254740993,
          reason: 'a long may arrive as a string');

      await client.dispose();
    });
  });

  group('room.memberList', () {
    test('sends the default limit, pages on the cursor, and decodes a page of user ids', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      final ImPage<String> first =
          await client.room.memberList(const ImRoomCursorRequest(roomId: 'live-1'));
      expect(gateway.requestsTo('room.memberList').single.body,
          <String, dynamic>{'roomId': 'live-1', 'limit': 50});
      expect(first.items, <String>['viewer-1', 'viewer-2']);
      expect(first.hasMore, isTrue);
      expect(first.nextCursor, '1');
      expect(first.total, isNull);

      final ImPage<String> last = await client.room.memberList(
          ImRoomCursorRequest(roomId: 'live-1', cursor: first.nextCursor, limit: 100));
      expect(gateway.requestsTo('room.memberList').last.body,
          <String, dynamic>{'roomId': 'live-1', 'cursor': '1', 'limit': 100});
      expect(last.items, isEmpty);
      expect(last.hasMore, isFalse);
      expect(last.nextCursor, isNull);

      await client.dispose();
    });
  });

  group('room.mute', () {
    test('mutes a member or the room until a time, and unmutes by leaving the time out', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      await client.room
          .mute(const ImRoomMuteRequest(roomId: 'live-1', userId: 'viewer-9', untilMs: 1755000600000));
      await client.room.mute(const ImRoomMuteRequest(roomId: 'live-1', untilMs: 1755000600000));
      await client.room.mute(const ImRoomMuteRequest.unmute(roomId: 'live-1', userId: 'viewer-9'));
      await client.room.mute(const ImRoomMuteRequest.unmute(roomId: 'live-1'));

      expect(gateway.requestsTo('room.mute').map((FakeRequest r) => r.body), <Map<String, dynamic>>[
        <String, dynamic>{'roomId': 'live-1', 'userId': 'viewer-9', 'untilMs': 1755000600000},
        <String, dynamic>{'roomId': 'live-1', 'untilMs': 1755000600000},
        <String, dynamic>{'roomId': 'live-1', 'userId': 'viewer-9'},
        <String, dynamic>{'roomId': 'live-1'},
      ]);

      await client.dispose();
    });

    test('surfaces Forbidden and CannotOperateOwner as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('room.mute', const <FakeReply>[
          FakeFail(ImErrorCode.forbidden, message: 'administrator permission required'),
          FakeFail(ImErrorCode.cannotOperateOwner, message: 'the room owner cannot be muted'),
        ]);
      final ImClient client = await connectedClient(gateway);

      for (final int code in <int>[1103, 1511]) {
        await expectLater(
          client.room.mute(const ImRoomMuteRequest(roomId: 'live-1', userId: 'host', untilMs: 1)),
          throwsA(isA<ImException>().having((ImException e) => e.code, 'code', code)),
        );
      }

      await client.dispose();
    });
  });

  group('room.kick', () {
    test('sends the room and the member', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);

      await client.room.kick(const ImRoomKickRequest(roomId: 'live-1', userId: 'viewer-9'));
      expect(gateway.requestsTo('room.kick').single.body,
          <String, dynamic>{'roomId': 'live-1', 'userId': 'viewer-9'});

      await client.dispose();
    });
  });

  // The inventory's note on room.join: "Chat rooms are best-effort and carry seq 0: they must
  // bypass the gap-repair path entirely."
  // 清单 room.join 的注释：聊天室尽力而为、seq 恒为 0，必须完全绕过补洞路径。
  group('a room message (seq 0) never reaches gap repair', () {
    test('it is delivered, asks for no repair, and moves no cursor', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);
      final int writesBefore = store.writes.length;

      final List<ImMessage> delivered = <ImMessage>[];
      final StreamSubscription<ImMessage> subscription = client.messages.listen(delivered.add);

      gateway.socket
        ..deliver(push(ImPushTarget.message, roomMessage('live-1', 1)))
        ..deliver(push(ImPushTarget.message, roomMessage('live-1', 2)))
        // The same room frame twice: with no seq there is nothing to deduplicate on, so both go
        // through — deduplicating is the application's, on messageId.
        ..deliver(push(ImPushTarget.message, roomMessage('live-1', 2)));

      await pumpUntil(() => delivered.length == 3, because: 'the room messages were never delivered');
      await settle();

      expect(delivered.map((ImMessage m) => m.seq), <int>[0, 0, 0]);
      expect(delivered.map((ImMessage m) => ImRoom.roomIdOf(m.conversationId)),
          <String>['live-1', 'live-1', 'live-1']);
      expect(delivered.first.conversationType, ImConversationType.chatRoom);

      expect(gateway.callsTo('msg.sync'), 0, reason: 'a seq-0 message has no range to repair');
      expect(client.deliveredSeq('r_live-1'), 0);
      expect(client.committedSeq('r_live-1'), 0);
      expect(client.cursors.convSeqs.keys, <String>['c1'],
          reason: 'no cursor was created for the room');
      expect(client.deliveredSeq('c1'), 10, reason: 'and no other conversation moved');

      // Committing a room message is a no-op rather than a cursor, so an app that commits every
      // message it stores cannot plant one by accident.
      await client.commit('r_live-1', 0);
      await settle();
      expect(client.cursors.convSeqs.keys, <String>['c1']);
      expect(store.writes.skip(writesBefore).where((ImCursorSnapshot s) => s.convSeqs.containsKey('r_live-1')),
          isEmpty,
          reason: 'nothing about the room was ever persisted');

      await subscription.cancel();
      await client.dispose();
    });

    test('it does not make the next conversation message look like a gap', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<String> delivered = <String>[];
      final StreamSubscription<ImMessage> subscription =
          client.messages.listen((ImMessage m) => delivered.add('${m.conversationId}#${m.seq}'));

      gateway.socket
        ..deliver(push(ImPushTarget.message, message('c1', 11)))
        ..deliver(push(ImPushTarget.message, roomMessage('live-1', 1)))
        ..deliver(push(ImPushTarget.message, message('c1', 12)));

      await pumpUntil(() => delivered.length == 3, because: 'three messages were pushed');
      await settle();

      expect(delivered, unorderedEquals(<String>['c1#11', 'r_live-1#0', 'c1#12']));
      expect(delivered.where((String d) => d.startsWith('c1')), <String>['c1#11', 'c1#12']);
      expect(gateway.callsTo('msg.sync'), 0,
          reason: 'c1 went 10 → 11 → 12 with a room message in between: contiguous, no repair');
      expect(client.deliveredSeq('c1'), 12);
      expect(client.deliveredSeq('r_live-1'), 0);

      await subscription.cancel();
      await client.dispose();
    });

    test('it is delivered even past a stale cursor under the room\'s conversation id', () async {
      // A cursor no correct build writes — say, from a build that ran room traffic through the
      // cursor path. Through that path a seq-0 message reads as "already seen" (0 <= 7) and is
      // dropped without a word; the bypass delivers it and leaves the cursor exactly as it was.
      // 正确的版本不会写出这条游标；走游标路径时 seq 0 会被当成「已收过」而静默丢弃。
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'r_live-1': 7}),
      );
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final List<ImMessage> delivered = <ImMessage>[];
      final StreamSubscription<ImMessage> subscription = client.messages.listen(delivered.add);

      gateway.socket.deliver(push(ImPushTarget.message, roomMessage('live-1', 1)));
      await pumpUntil(() => delivered.isNotEmpty, because: 'the room message was dropped');
      await settle();

      expect(delivered.single.clientMsgId, 'room-1');
      expect(client.deliveredSeq('r_live-1'), 7);
      expect(gateway.callsTo('msg.sync'), 0);

      await subscription.cancel();
      await client.dispose();
    });

    test('it is not held behind a repair in flight', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 10}),
      );
      // The repair never answers: anything queued behind it would wait out the request timeout.
      final FakeGateway gateway = FakeGateway()..on('msg.sync', (FakeRequest _) => const FakeSilence());
      final ImClient client = await connectedClient(gateway, cursorStore: store);
      final StreamSubscription<ImException> errors = client.errors.listen((ImException _) {});

      final List<ImMessage> delivered = <ImMessage>[];
      final StreamSubscription<ImMessage> subscription = client.messages.listen(delivered.add);

      gateway.socket.deliver(push(ImPushTarget.message, message('c1', 15)));
      await pumpUntil(() => gateway.callsTo('msg.sync') == 1, because: '15 opens a gap over 11…14');

      gateway.socket.deliver(push(ImPushTarget.message, roomMessage('live-1', 1)));
      await pumpUntil(() => delivered.isNotEmpty, because: 'the room message was held');

      expect(delivered.single.conversationId, 'r_live-1',
          reason: 'delivered while c1 is still waiting on its repair');
      expect(gateway.callsTo('msg.sync'), 1, reason: 'and it started no repair of its own');

      await subscription.cancel();
      await errors.cancel();
      await client.dispose();
    });
  });

  group('room.* events (evt.system)', () {
    test('the three room events decode, an unknown room event is kept, and other events are not '
        'room events', () async {
      final FakeGateway gateway = roomGateway();
      final ImClient client = await connectedClient(gateway);
      final List<ImRoomEvent> received = <ImRoomEvent>[];
      final StreamSubscription<ImRoomEvent> subscription = client.roomEvents.listen(received.add);

      void system(Object data) => gateway.socket.deliver(<String, dynamic>{
            'id': 'srv-sys',
            'target': 'evt.system',
            'status': 0,
            'body': <String, dynamic>{'code': 0, 'serverTime': 1, 'data': data},
          });

      system(<String, dynamic>{
        'event': 'room.muted',
        'body': <String, dynamic>{
          'roomId': 'live-1',
          'operatorId': 'host',
          'userId': 'viewer-9',
          'untilMs': '1755000600000',
        },
      });
      system(<String, dynamic>{
        'event': 'room.muted',
        'body': <String, dynamic>{'roomId': 'live-1', 'operatorId': 'mod-1'},
      });
      system(<String, dynamic>{
        'event': 'device.logRequest',
        'body': <String, dynamic>{'requestId': 'lr-1', 'deviceId': 'another-device'},
      });
      system(<String, dynamic>{
        'event': 'room.kicked',
        'body': <String, dynamic>{'roomId': 'live-1', 'operatorId': 'host', 'userId': 'alice'},
      });
      system(<String, dynamic>{'event': 'roomy.notARoomEvent', 'body': <String, dynamic>{}});
      system(<dynamic>['not', 'an', 'object']);
      system(<String, dynamic>{
        'event': 'room.renamed',
        'body': <String, dynamic>{'roomId': 'live-1', 'operatorId': 'tenant', 'name': 'After party'},
      });
      system(<String, dynamic>{
        'event': 'room.destroyed',
        'body': <String, dynamic>{'roomId': 'live-1', 'operatorId': 'tenant'},
      });

      await pumpUntil(() => received.length >= 5, because: 'five room events were pushed');
      await settle();

      expect(received.map((ImRoomEvent e) => e.event), <String>[
        ImRoomEvent.muted,
        ImRoomEvent.muted,
        ImRoomEvent.kicked,
        'room.renamed',
        ImRoomEvent.destroyed,
      ]);

      final ImRoomEvent member = received[0];
      expect(member.roomId, 'live-1');
      expect(member.operatorId, 'host');
      expect(member.userId, 'viewer-9');
      expect(member.untilMs, 1755000600000, reason: 'a long may arrive as a string');
      expect(member.isKnown, isTrue);

      final ImRoomEvent roomWideUnmute = received[1];
      expect(roomWideUnmute.userId, isNull, reason: 'no userId: the room-wide mute');
      expect(roomWideUnmute.untilMs, isNull, reason: 'no untilMs: it was lifted');
      expect(roomWideUnmute.operatorId, 'mod-1');

      expect(received[2].userId, 'alice');

      final ImRoomEvent unknown = received[3];
      expect(unknown.isKnown, isFalse);
      expect(unknown.roomId, 'live-1');
      expect(unknown.body['name'], 'After party', reason: 'an untyped event keeps its whole body');

      expect(received[4].operatorId, 'tenant');
      expect(received[4].userId, isNull);

      await subscription.cancel();
      await client.dispose();
    });

    test('listening for room events leaves the device-log request to its own handler', () async {
      final FakeGateway gateway = FakeGateway();
      final List<String> uploaded = <String>[];
      final ImClient client = ImClient(ImOptions(
        endpoint: 'wss://im.test',
        appId: 'demo',
        token: 'token-1',
        deviceId: 'device-1',
        userId: 'alice',
        cursorStore: RecordingCursorStore(),
        platform: ImPlatform.web,
        requestTimeout: const Duration(milliseconds: 200),
        cursorSaveDebounce: Duration.zero,
        logger: (String _) {},
        deviceLogUploader: (ImPendingDeviceLog request, String body) async =>
            uploaded.add(request.requestId),
        socketFactory: gateway.connect,
      ));
      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty, because: 'no socket was created');
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('conn.sync') > 0, because: 'the resume never ran');
      await settle();

      final List<ImRoomEvent> received = <ImRoomEvent>[];
      final StreamSubscription<ImRoomEvent> subscription = client.roomEvents.listen(received.add);

      gateway.socket.deliver(push(ImPushTarget.system, <String, dynamic>{
        'event': 'device.logRequest',
        'body': <String, dynamic>{
          'requestId': 'lr-7',
          'deviceId': 'device-1',
          'uploadUrl': 'https://storage.test/upload',
          'objectKey': 'logs/lr-7',
        },
      }));
      gateway.socket.deliver(push(ImPushTarget.system, <String, dynamic>{
        'event': 'room.destroyed',
        'body': <String, dynamic>{'roomId': 'live-1', 'operatorId': 'tenant'},
      }));

      await pumpUntil(() => gateway.callsTo('diag.logUploaded') == 1,
          because: 'the device-log request went unanswered while room events were listened to');
      await pumpUntil(() => received.isNotEmpty, because: 'the room event was not delivered');

      expect(uploaded, <String>['lr-7']);
      expect(gateway.requestsTo('diag.logUploaded').single.body['requestId'], 'lr-7');
      expect(received.single.event, ImRoomEvent.destroyed);

      await subscription.cancel();
      await client.dispose();
    });
  });

  test('ImRoom maps a room id to its conversation id and back', () {
    expect(ImRoom.conversationIdOf('live-1'), 'r_live-1');
    expect(ImRoom.roomIdOf('r_live-1'), 'live-1');
    expect(ImRoom.roomIdOf('r_with_underscores'), 'with_underscores');
    expect(ImRoom.roomIdOf('s_alice_bob'), isNull);
    expect(ImRoom.roomIdOf('g_team'), isNull);
    expect(ImRoom.roomIdOf('r_'), isNull);
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

    expect(chatRoom.keys.toSet(), members('ChatRoom'));
    expect(joinResult.keys.toSet(), members('RoomJoinResult'));
    expect(sendResult.keys.toSet(), members('SendMessageResult'));

    expect(const ImRoomIdRequest(roomId: 'r').toJson().keys.toSet(), members('RoomIdRequest'));
    expect(const ImRoomCursorRequest(roomId: 'r', cursor: 'c').toJson().keys.toSet(),
        members('RoomCursorRequest'));
    expect(const ImRoomMuteRequest(roomId: 'r', userId: 'u', untilMs: 1).toJson().keys.toSet(),
        members('RoomMuteRequest'));
    expect(const ImRoomKickRequest(roomId: 'r', userId: 'u').toJson().keys.toSet(),
        members('RoomKickRequest'));
    expect(ImRoomSendRequest.text('r', 'x').toJson().keys.toSet(), members('RoomSendRequest'));

    // The nested message is a deliberate subset of SendMessageRequest: every key it sends must be a
    // member the server declares (a nested miscased key is dropped silently), and the subset is
    // exactly the members RoomService reads.
    // 嵌套的 message 是 SendMessageRequest 的有意子集：每个键都必须是服务端声明的成员。
    final Set<String> roomMessage = ImRoomMessage(
      content: const <String, dynamic>{'text': 'x'},
      mentionedUserIds: const <String>['u'],
      priority: ImMessagePriority.low,
      extensions: const <String, dynamic>{'k': 'v'},
    ).toJson().keys.toSet();
    expect(members('SendMessageRequest').containsAll(roomMessage), isTrue,
        reason: '${roomMessage.difference(members('SendMessageRequest'))} is not a SendMessageRequest member');
    expect(roomMessage, <String>{
      'clientMsgId',
      'contentType',
      'content',
      'mentionAll',
      'mentionedUserIds',
      'options',
      'sendTime',
      'extensions',
    });
  });

  test('the seven room targets are the inventory\'s, and its room note is the seq-0 rule', () {
    final List<Map<String, dynamic>> rooms = <Map<String, dynamic>>[
      for (final dynamic endpoint in inventory()['endpoints'] as List<dynamic>)
        if (((endpoint as Map<String, dynamic>)['target'] as String).startsWith('room.')) endpoint,
    ];

    expect(rooms.map((Map<String, dynamic> e) => e['target']).toSet(), <String>{
      'room.join',
      'room.quit',
      'room.send',
      'room.onlineCount',
      'room.memberList',
      'room.mute',
      'room.kick',
    });
    final Map<String, dynamic> join =
        rooms.singleWhere((Map<String, dynamic> e) => e['target'] == 'room.join');
    expect(join['note'], contains('seq 0'));
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
