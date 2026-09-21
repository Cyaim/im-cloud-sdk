import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Tier T3 — competitive parity, typed whole: twenty endpoints, asserted on the wire.
///
/// Naming the right target is not the half that breaks. What breaks is the *body*: the server's
/// socket binder does not go through the JSON options the rest of the platform uses, so a field of
/// the wrong JSON kind is not coerced — it throws, and the caller gets `1000 internal error` with
/// nothing to say which field. A message id sent as a number, an `untilMs` sent as a string, a role
/// sent as `"admin"`: all three are that same opaque 1000. So every case below pins the exact body
/// — key set, values, and through `equals` on the decoded frame the JSON kind of each value — and
/// every payload endpoint pins what comes back.
///
/// T3 的二十个端点逐一断言线上的请求体：服务端套接字绑定器不走平台的 JSON 选项，
/// 字段类型不对不会被转换，而是直接抛、回一个说不出是哪个字段的 1000。
/// 所以每条都钉住键集合、取值与 JSON 类型；有载荷的端点再钉住解出来的结果。
void main() {
  /// A real snowflake: about 2^58, far past what a web `int` (a JavaScript number) holds exactly.
  const String snowflake = '360306324097966080';

  /// The frame as the client wrote it, before any decoding. The quotes around an id exist only
  /// here: once decoded, `"360306324097966080"` and `360306324097966080` are told apart only by
  /// the Dart type, and on the web not even by that.
  String rawFrame(FakeGateway gateway, String target) => gateway.socket.sent.lastWhere(
        (String payload) => (jsonDecode(payload) as Map<String, dynamic>)['target'] == target,
      );

  /// The one request sent to [target], asserted to be exactly one.
  Map<String, dynamic> sentBody(FakeGateway gateway, String target) =>
      gateway.requestsTo(target).single.body;

  Map<String, dynamic> wireMessage(String messageId, {int seq = 7, bool recalled = false}) =>
      <String, dynamic>{
        'appId': 'demo',
        'conversationId': 'g_team',
        'conversationType': 2,
        'seq': seq,
        'messageId': messageId,
        'clientMsgId': 'c$seq',
        'senderId': 'bob',
        'senderPlatform': 1,
        'contentType': 1,
        'content': <String, dynamic>{'text': 'invoice #$seq'},
        'mentionAll': false,
        'options': <String, dynamic>{},
        'status': 1,
        if (recalled)
          'recalled': <String, dynamic>{
            'operatorId': 'bob',
            'recallTime': 1758412700000,
            'byAdmin': false,
          },
        'sendTime': 1758412600000,
        'createTime': 1758412600001,
      };

  group('msg (T3)', () {
    test('the five single-message calls send the id as a string, digits intact', () async {
      // pin, unpin, favourite, unfavourite and burn share the server's ConversationMessageRequest,
      // whose messageId is a C# string. A JSON number there is not rounded — it is refused, as
      // `1000`, which is worse because nothing says why.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);
      const ImConversationMessageRequest request =
          ImConversationMessageRequest(conversationId: 'g_team', messageId: snowflake);

      final Map<String, Future<void> Function()> calls = <String, Future<void> Function()>{
        'msg.pin': () => client.msg.pin(request),
        'msg.unpin': () => client.msg.unpin(request),
        'msg.favourite': () => client.msg.favourite(request),
        'msg.unfavourite': () => client.msg.unfavourite(request),
        'msg.burn': () => client.msg.burn(request),
      };

      for (final MapEntry<String, Future<void> Function()> call in calls.entries) {
        await call.value();

        expect(
          sentBody(gateway, call.key),
          <String, dynamic>{'conversationId': 'g_team', 'messageId': snowflake},
          reason: call.key,
        );
        expect(rawFrame(gateway, call.key), contains('"messageId":"$snowflake"'), reason: call.key);
      }

      await client.dispose();
    });

    test('a refusal on a plain-ack call throws rather than returning quietly', () async {
      // The board is full: the one refusal a pin screen has to explain, and it arrives as a code in
      // a routed frame — CONTRACT §4.4 says that throws.
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.pin',
        (FakeRequest _) => const FakeFail(
          ImErrorCode.conflict,
          message: 'this conversation already has 20 pinned messages; unpin one first',
        ),
      );
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.msg.pin(
          const ImConversationMessageRequest(conversationId: 'g_team', messageId: snowflake),
        ),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.conflict)
            .having((ImException e) => e.target, 'target', 'msg.pin')),
      );

      await client.dispose();
    });

    test('msg.pins sends the conversation and decodes a plain list, ids as strings', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.pins',
        (FakeRequest _) => const FakeData(<Map<String, dynamic>>[
          <String, dynamic>{
            'messageId': snowflake,
            'seq': 41,
            'pinnedBy': 'alice',
            'pinnedAt': 1758412800000,
            'brief': <String, dynamic>{
              'messageId': snowflake,
              'seq': 41,
              'senderId': 'bob',
              'contentType': 2,
              'digest': '[Image]',
              'createTime': 1758412700000,
              'recalled': false,
            },
          },
          <String, dynamic>{
            'messageId': '360306324097966081',
            'seq': 12,
            'pinnedBy': 'bob',
            'pinnedAt': 1758412000000,
            // The server type allows no brief; msg.pins always fills it, but absence must decode.
          },
        ]),
      );
      final ImClient client = await connectedClient(gateway);

      final List<ImPinnedMessage> pins =
          await client.msg.pins(const ImConversationIdRequest(conversationId: 'g_team'));

      expect(sentBody(gateway, 'msg.pins'), <String, dynamic>{'conversationId': 'g_team'});

      expect(pins, hasLength(2));
      expect(pins[0].messageId, snowflake);
      expect(pins[0].seq, 41);
      expect(pins[0].pinnedBy, 'alice');
      expect(pins[0].pinnedAt, 1758412800000);
      expect(pins[0].brief, isNotNull);
      expect(pins[0].brief!.messageId, snowflake);
      expect(pins[0].brief!.contentType, ImMessageContentType.image);
      expect(pins[0].brief!.digest, '[Image]');
      expect(pins[0].brief!.recalled, isFalse);
      expect(pins[1].messageId, '360306324097966081');
      expect(pins[1].brief, isNull);

      await client.dispose();
    });

    test('msg.pins answers an empty list, not a failure, when nothing is pinned', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on('msg.pins', (FakeRequest _) => const FakeData(<dynamic>[]));
      final ImClient client = await connectedClient(gateway);

      expect(
        await client.msg.pins(const ImConversationIdRequest(conversationId: 'g_team')),
        isEmpty,
      );

      await client.dispose();
    });

    test('msg.favourites needs no request and keeps the cursor of a short page', () async {
      // A page can come back short — even empty — with more behind it, because favourites in chats
      // the caller can no longer read are hidden rather than returned. The page type is what keeps
      // the cursor in the caller's hands.
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.favourites',
        (FakeRequest _) => FakeData(<String, dynamic>{
          'items': <Map<String, dynamic>>[wireMessage(snowflake, recalled: true)],
          'nextCursor': 'fav-2',
          'hasMore': true,
        }),
      );
      final ImClient client = await connectedClient(gateway);

      final ImPage<ImMessage> first = await client.msg.favourites();
      await client.msg.favourites(const ImPageRequest(cursor: 'fav-2', limit: 50));

      final List<FakeRequest> sent = gateway.requestsTo('msg.favourites');
      expect(sent[0].body, <String, dynamic>{'limit': 20});
      expect(sent[1].body, <String, dynamic>{'cursor': 'fav-2', 'limit': 50});

      expect(first.items.single.messageId, snowflake);
      expect(first.items.single.seq, 7);
      expect(first.items.single.recalled, isNotNull, reason: 'recalled favourites are listed');
      expect(first.nextCursor, 'fav-2');
      expect(first.hasMore, isTrue);
      expect(first.total, isNull, reason: 'the server never counts favourites; null is not zero');

      await client.dispose();
    });

    test('msg.search sends every filter as its own JSON kind', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.search',
        (FakeRequest _) => FakeData(<String, dynamic>{
          'items': <Map<String, dynamic>>[wireMessage(snowflake, seq: 99)],
          'hasMore': false,
        }),
      );
      final ImClient client = await connectedClient(gateway);

      final ImPage<ImMessage> page = await client.msg.search(const ImSearchMessagesRequest(
        keyword: 'invoice',
        conversationId: 'g_team',
        contentTypes: <ImMessageContentType>[ImMessageContentType.text, ImMessageContentType.file],
        senderId: 'bob',
        startTime: 1756684800000,
        endTime: 1758412800000,
        cursor: 's-1',
        limit: 50,
      ));
      await client.msg.search(const ImSearchMessagesRequest(keyword: 'invoice'));

      final List<FakeRequest> sent = gateway.requestsTo('msg.search');
      expect(sent[0].body, <String, dynamic>{
        'keyword': 'invoice',
        'conversationId': 'g_team',
        // Integers, never names: the binder refuses "text" for a MessageContentType.
        'contentTypes': <int>[1, 5],
        'senderId': 'bob',
        'startTime': 1756684800000,
        'endTime': 1758412800000,
        'cursor': 's-1',
        'limit': 50,
      });
      // Unset filters are absent, not null: an absent field is the server's own default.
      expect(sent[1].body, <String, dynamic>{'keyword': 'invoice', 'limit': 20});

      expect(page.items.single.messageId, snowflake);
      expect(page.items.single.seq, 99);
      expect(page.items.single.content['text'], 'invoice #99');
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);

      await client.dispose();
    });

    test('msg.search surfaces search being off, and the rate limit, as codes', () async {
      // Neither is latched: a tenant can switch search on while the app is running (CONTRACT §7.4),
      // and the limiter runs before that check, so both reach the caller every time.
      final FakeGateway gateway = FakeGateway();
      gateway.script('msg.search', <FakeReply>[
        const FakeFail(ImErrorCode.featureNotEnabled, message: 'search is not enabled'),
        const FakeFail(ImErrorCode.rateLimited, message: 'search rate limit exceeded'),
      ]);
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.msg.search(const ImSearchMessagesRequest(keyword: 'x')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.featureNotEnabled)
            .having((ImException e) => e.isRetryable, 'isRetryable', isFalse)),
      );
      await expectLater(
        client.msg.search(const ImSearchMessagesRequest(keyword: 'x')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.rateLimited)
            .having((ImException e) => e.isRetryable, 'isRetryable', isTrue)),
      );
      expect(gateway.callsTo('msg.search'), 2, reason: 'the SDK must not retry on its own');

      await client.dispose();
    });

    test('msg.receiptDetail sends a string id and decodes the receipt', () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.receiptDetail',
        (FakeRequest _) => const FakeData(<String, dynamic>{
          'appId': 'a1',
          'conversationId': 'g_team',
          'messageId': snowflake,
          'readUserIds': <String>['u2', 'u3'],
          'readCount': 2,
          'totalCount': 8,
          'updatedAt': 1758412790000,
        }),
      );
      final ImClient client = await connectedClient(gateway);

      final ImMessageReceipt receipt = await client.msg.receiptDetail(
        const ImReceiptDetailRequest(conversationId: 'g_team', messageId: snowflake),
      );

      expect(
        sentBody(gateway, 'msg.receiptDetail'),
        <String, dynamic>{'conversationId': 'g_team', 'messageId': snowflake},
      );
      expect(rawFrame(gateway, 'msg.receiptDetail'), contains('"messageId":"$snowflake"'));

      expect(receipt.appId, 'a1');
      expect(receipt.conversationId, 'g_team');
      expect(receipt.messageId, snowflake);
      expect(receipt.readUserIds, <String>['u2', 'u3']);
      expect(receipt.readCount, 2);
      expect(receipt.totalCount, 8, reason: 'the sender is counted here and never in readUserIds');
      expect(receipt.updatedAt, 1758412790000);

      await client.dispose();
    });

    test('msg.receiptDetail decodes a receipt nobody has read as empty, not as a failure',
        () async {
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'msg.receiptDetail',
        (FakeRequest _) => const FakeData(<String, dynamic>{
          'appId': 'a1',
          'conversationId': 'c1',
          'messageId': snowflake,
          'readUserIds': <String>[],
          'readCount': 0,
          'totalCount': 2,
          'updatedAt': 1758412600001,
        }),
      );
      final ImClient client = await connectedClient(gateway);

      final ImMessageReceipt receipt = await client.msg.receiptDetail(
        const ImReceiptDetailRequest(conversationId: 'c1', messageId: snowflake),
      );

      expect(receipt.readUserIds, isEmpty);
      expect(receipt.readCount, 0);
      expect(receipt.totalCount, 2);

      await client.dispose();
    });
  });

  group('conv / user / friend (T3)', () {
    test('conv.markUnread always sends the flag, because absent means true', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.conv.markUnread(const ImMarkUnreadRequest(conversationId: 'c1'));
      await client.conv.markUnread(const ImMarkUnreadRequest(conversationId: 'c1', unread: false));

      final List<FakeRequest> sent = gateway.requestsTo('conv.markUnread');
      expect(sent[0].body, <String, dynamic>{'conversationId': 'c1', 'unread': true});
      expect(sent[1].body, <String, dynamic>{'conversationId': 'c1', 'unread': false});

      await client.dispose();
    });

    test('user.setStatus sends the status, and an empty body to clear it', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.user.setStatus(const ImSetStatusRequest(status: 'in a meeting'));
      await client.user.setStatus(const ImSetStatusRequest());

      final List<FakeRequest> sent = gateway.requestsTo('user.setStatus');
      expect(sent[0].body, <String, dynamic>{'status': 'in a meeting'});
      expect(sent[1].body, isEmpty, reason: 'no status is how the server hears "clear it"');

      await client.dispose();
    });

    test('friend.setRemark leaves out what is null — which clears a remark and keeps tags',
        () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.friend.setRemark(const ImSetRemarkRequest(
        userId: 'bob',
        remark: 'Bob (accounts)',
        tags: <String>['work', 'finance'],
      ));
      await client.friend.setRemark(const ImSetRemarkRequest(userId: 'bob'));
      await client.friend.setRemark(const ImSetRemarkRequest(userId: 'bob', tags: <String>[]));

      final List<FakeRequest> sent = gateway.requestsTo('friend.setRemark');
      expect(sent[0].body, <String, dynamic>{
        'userId': 'bob',
        'remark': 'Bob (accounts)',
        'tags': <String>['work', 'finance'],
      });
      expect(sent[1].body, <String, dynamic>{'userId': 'bob'});
      expect(sent[2].body, <String, dynamic>{'userId': 'bob', 'tags': <String>[]});

      await client.dispose();
    });
  });

  group('group (T3)', () {
    test('group.transfer names the group and the new owner', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.transfer(const ImTransferOwnerRequest(groupId: 'team', newOwnerId: 'bob'));

      expect(
        sentBody(gateway, 'group.transfer'),
        <String, dynamic>{'groupId': 'team', 'newOwnerId': 'bob'},
      );

      await client.dispose();
    });

    test('group.applicationList defaults to every group managed, and keeps every status', () async {
      // The server returns applications of every status, not only pending, and an unknown status
      // must survive decoding with its own number rather than collapse into one the SDK knows.
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'group.applicationList',
        (FakeRequest _) => const FakeData(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'appId': 'a1',
              'groupId': 'team',
              'applicantId': 'carol',
              'inviterId': 'bob',
              'reason': 'from the offsite',
              'status': 0,
              'createdAt': 1758412000000,
            },
            <String, dynamic>{
              'appId': 'a1',
              'groupId': 'ops',
              'applicantId': 'dave',
              'status': 2,
              'handlerId': 'alice',
              'handleReason': 'wrong team',
              'createdAt': 1758411000000,
              'handledAt': 1758411500000,
            },
            <String, dynamic>{
              'appId': 'a1',
              'groupId': 'ops',
              'applicantId': 'erin',
              'status': 9,
              'createdAt': 1758410000000,
            },
          ],
          'nextCursor': 'app-2',
          'hasMore': true,
        }),
      );
      final ImClient client = await connectedClient(gateway);

      final ImPage<ImGroupApplication> page = await client.group.applicationList();
      await client.group.applicationList(
        const ImGroupCursorRequest(groupId: 'team', cursor: 'app-2', limit: 200),
      );

      final List<FakeRequest> sent = gateway.requestsTo('group.applicationList');
      expect(sent[0].body, <String, dynamic>{'groupId': '', 'limit': 50});
      expect(sent[1].body, <String, dynamic>{'groupId': 'team', 'cursor': 'app-2', 'limit': 200});

      expect(page.items, hasLength(3));
      final ImGroupApplication pending = page.items[0];
      expect(pending.groupId, 'team');
      expect(pending.applicantId, 'carol');
      expect(pending.inviterId, 'bob');
      expect(pending.reason, 'from the offsite');
      expect(pending.status, ImApplicationStatus.pending);
      expect(pending.handlerId, isNull);
      expect(pending.handledAt, isNull);
      expect(pending.createdAt, 1758412000000);

      final ImGroupApplication rejected = page.items[1];
      expect(rejected.status, ImApplicationStatus.rejected);
      expect(rejected.handlerId, 'alice');
      expect(rejected.handleReason, 'wrong team');
      expect(rejected.handledAt, 1758411500000);

      expect(page.items[2].status.wireValue, 9);
      expect(page.items[2].status.isKnown, isFalse);

      expect(page.nextCursor, 'app-2');
      expect(page.hasMore, isTrue);

      await client.dispose();
    });

    test('group.handleApplication sends the decision as a bool, both ways', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.handleApplication(const ImHandleApplicationRequest(
        groupId: 'team',
        applicantId: 'carol',
        accept: true,
      ));
      await client.group.handleApplication(const ImHandleApplicationRequest(
        groupId: 'team',
        applicantId: 'dave',
        accept: false,
        reason: 'wrong team',
      ));

      final List<FakeRequest> sent = gateway.requestsTo('group.handleApplication');
      expect(sent[0].body, <String, dynamic>{
        'groupId': 'team',
        'applicantId': 'carol',
        'accept': true,
      });
      expect(sent[1].body, <String, dynamic>{
        'groupId': 'team',
        'applicantId': 'dave',
        'accept': false,
        'reason': 'wrong team',
      });

      await client.dispose();
    });

    test('group.setRole sends the role as an integer', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.setRole(
        const ImSetRoleRequest(groupId: 'team', userId: 'u7', role: ImGroupRole.admin),
      );
      await client.group.setRole(
        const ImSetRoleRequest(groupId: 'team', userId: 'u7', role: ImGroupRole.member),
      );

      final List<FakeRequest> sent = gateway.requestsTo('group.setRole');
      expect(sent[0].body, <String, dynamic>{'groupId': 'team', 'userId': 'u7', 'role': 2});
      expect(sent[1].body, <String, dynamic>{'groupId': 'team', 'userId': 'u7', 'role': 1});
      expect(rawFrame(gateway, 'group.setRole'), contains('"role":1'));

      await client.dispose();
    });

    test('group.setRole refuses anything but member or admin before it reaches the wire', () {
      // The server refuses owner but stores any other integer, and 0 escapes a group-wide mute
      // while 4 outranks every admin. Asserted, so it trips in development and compiles away in
      // release — `dart test` runs with assertions on.
      for (final ImGroupRole role in <ImGroupRole>[
        ImGroupRole.owner,
        const ImGroupRole(0),
        const ImGroupRole(4),
      ]) {
        expect(
          () => ImSetRoleRequest(groupId: 'team', userId: 'u7', role: role),
          throwsA(isA<AssertionError>()),
          reason: 'role ${role.wireValue}',
        );
      }
    });

    test('group.mute always sends the switch, and the deadline as a number', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.mute(const ImMuteGroupRequest(groupId: 'team'));
      await client.group.mute(const ImMuteGroupRequest(groupId: 'team', untilMs: 1758499200000));
      await client.group.mute(const ImMuteGroupRequest(groupId: 'team', mute: false));

      final List<FakeRequest> sent = gateway.requestsTo('group.mute');
      expect(sent[0].body, <String, dynamic>{'groupId': 'team', 'mute': true});
      expect(sent[1].body, <String, dynamic>{
        'groupId': 'team',
        'mute': true,
        'untilMs': 1758499200000,
      });
      expect(sent[2].body, <String, dynamic>{'groupId': 'team', 'mute': false});
      expect(rawFrame(gateway, 'group.mute'), contains('"mute":false'));

      await client.dispose();
    });

    test('group.muteMember sends a deadline as a number, and none to unmute', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.muteMember(
        const ImMuteMemberRequest(groupId: 'team', userId: 'u7', untilMs: 1758499200000),
      );
      await client.group.muteMember(const ImMuteMemberRequest(groupId: 'team', userId: 'u7'));

      final List<FakeRequest> sent = gateway.requestsTo('group.muteMember');
      expect(sent[0].body, <String, dynamic>{
        'groupId': 'team',
        'userId': 'u7',
        'untilMs': 1758499200000,
      });
      expect(sent[1].body, <String, dynamic>{'groupId': 'team', 'userId': 'u7'});

      await client.dispose();
    });

    test('group.setNickname leaves userId out for the caller\'s own', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.setNickname(
        const ImSetGroupNicknameRequest(groupId: 'team', nickname: 'Al'),
      );
      await client.group.setNickname(
        const ImSetGroupNicknameRequest(groupId: 'team', userId: 'u7', nickname: 'Seven'),
      );
      await client.group.setNickname(const ImSetGroupNicknameRequest(groupId: 'team'));

      final List<FakeRequest> sent = gateway.requestsTo('group.setNickname');
      expect(sent[0].body, <String, dynamic>{'groupId': 'team', 'nickname': 'Al'});
      expect(sent[1].body, <String, dynamic>{
        'groupId': 'team',
        'userId': 'u7',
        'nickname': 'Seven',
      });
      expect(sent[2].body, <String, dynamic>{'groupId': 'team'});

      await client.dispose();
    });

    test('group.announcement sends the text, and nothing to clear it', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.group.announcement(
        const ImAnnouncementRequest(groupId: 'team', announcement: 'Standup moves to 10:00'),
      );
      await client.group.announcement(const ImAnnouncementRequest(groupId: 'team'));

      final List<FakeRequest> sent = gateway.requestsTo('group.announcement');
      expect(sent[0].body, <String, dynamic>{
        'groupId': 'team',
        'announcement': 'Standup moves to 10:00',
      });
      expect(sent[1].body, <String, dynamic>{'groupId': 'team'});

      await client.dispose();
    });
  });

  group('tier coverage', () {
    test('every T3 target in the inventory has a typed method, and only T3 targets are hit',
        () async {
      // Measured, not claimed: each typed T3 method is driven once against a gateway that answers
      // everything with an empty result, and the targets that reach the wire are compared with
      // the inventory's own T3 list. A missing target, a misspelt one ('msg.favorites') or a
      // near-name ('msg.pin' for 'msg.pins') fails here by name.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);
      const ImConversationMessageRequest message =
          ImConversationMessageRequest(conversationId: 'c1', messageId: snowflake);

      final List<Future<Object?> Function()> calls = <Future<Object?> Function()>[
        () => client.msg.pin(message),
        () => client.msg.unpin(message),
        () => client.msg.pins(const ImConversationIdRequest(conversationId: 'c1')),
        () => client.msg.favourite(message),
        () => client.msg.unfavourite(message),
        () => client.msg.favourites(),
        () => client.msg.burn(message),
        () => client.msg.search(const ImSearchMessagesRequest(keyword: 'k')),
        () => client.msg.receiptDetail(
              const ImReceiptDetailRequest(conversationId: 'c1', messageId: snowflake),
            ),
        () => client.conv.markUnread(const ImMarkUnreadRequest(conversationId: 'c1')),
        () => client.user.setStatus(const ImSetStatusRequest()),
        () => client.friend.setRemark(const ImSetRemarkRequest(userId: 'bob')),
        () => client.group.transfer(const ImTransferOwnerRequest(groupId: 'g', newOwnerId: 'b')),
        () => client.group.applicationList(),
        () => client.group.handleApplication(
              const ImHandleApplicationRequest(groupId: 'g', applicantId: 'b', accept: true),
            ),
        () => client.group.setRole(
              const ImSetRoleRequest(groupId: 'g', userId: 'b', role: ImGroupRole.admin),
            ),
        () => client.group.mute(const ImMuteGroupRequest(groupId: 'g')),
        () => client.group.muteMember(const ImMuteMemberRequest(groupId: 'g', userId: 'b')),
        () => client.group.setNickname(const ImSetGroupNicknameRequest(groupId: 'g')),
        () => client.group.announcement(const ImAnnouncementRequest(groupId: 'g')),
      ];

      final int before = gateway.requests.length;
      for (final Future<Object?> Function() call in calls) {
        await call();
      }
      final List<String> hit = <String>[
        for (final FakeRequest request in gateway.requests.skip(before)) request.target,
      ];

      expect(hit, hasLength(calls.length), reason: 'one call, one frame');
      expect(hit.toSet(), hasLength(calls.length), reason: 'no two methods share a target');
      expect(hit.toSet(), t3Targets());

      await client.dispose();
    });
  });
}

/// The inventory's own T3 list, read from `sdk/endpoint-inventory.json` rather than copied here —
/// a copy would agree with this file forever and with the server only by luck.
Set<String> t3Targets() {
  Directory directory = Directory.current.absolute;

  for (int hop = 0; hop < 8; hop++) {
    final File inventory = File('${directory.path}/endpoint-inventory.json');
    if (inventory.existsSync()) {
      final Map<String, dynamic> parsed =
          jsonDecode(inventory.readAsStringSync()) as Map<String, dynamic>;
      final Map<String, dynamic> tiers = parsed['tiers'] as Map<String, dynamic>;
      final Map<String, dynamic> t3 = tiers['T3'] as Map<String, dynamic>;
      return <String>{
        for (final dynamic target in t3['targets'] as List<dynamic>) target as String
      };
    }

    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }

  throw StateError('could not locate sdk/endpoint-inventory.json from ${Directory.current.path}');
}
