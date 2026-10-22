import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled`, `conv.folders` / `conv.upsertFolder` /
/// `conv.deleteFolder` and `msg.translate`.
///
/// Every call is asserted on the whole frame it puts on the wire (with every member set, and
/// minimal), on what it makes of a reply with every member set, and on its refusals by code. The
/// rules a signature cannot say are asserted too: a schedule's state is read off `messageId` and
/// `error` (a cancelled one stays listed), a folder save is a replacement (so `.edit` carries every
/// member forward), and `msg.translate` on a deployment without translation is an ordinary,
/// readable refusal — `1203` or `1204` with the server's message — not a crash. The full fixtures
/// and bodies are held to `endpoint-inventory.json`'s payloadTypes.
///
/// 每个调用断言整帧（全字段与最小）、全字段答复的解码、按码的拒绝；另断言签名说不出的规则：定时消息的状态由
/// messageId 与 error 推出（取消的仍在列表里）、文件夹保存是整份替换（所以 edit 把每个成员带上）、
/// 没配翻译的部署上 msg.translate 是普通的可读拒绝（1203 / 1204 带服务端原话）而不是崩溃。
/// 全字段夹具与请求体对着 endpoint-inventory.json 的 payloadTypes 钉住。
void main() {
  // Every member of the server's ScheduledMessage / ConversationFolder / TranslationResult /
  // TranslatedMessage, each with a value no default reads as, held to the inventory by
  // 'the full fixtures and bodies carry every member'.
  const Map<String, dynamic> scheduled = <String, dynamic>{
    'scheduleId': 'sch_360381357961969001',
    'appId': 'demo',
    'senderId': 'alice',
    'conversationId': 's_alice_bob',
    'sendAt': 1755000312000,
    'createdAt': 1755000300000,
    // A snowflake above 2^53 and odd, quoted as the server writes a long it may not fit.
    'messageId': '360381357961969667',
    'error': 'send failed',
  };

  const Map<String, dynamic> folder = <String, dynamic>{
    'folderId': 'work',
    'name': 'Work',
    'order': 3,
    'tags': <String>['client', 'urgent'],
    'unreadOnly': true,
    'types': <int>[1, 2],
  };

  const Map<String, dynamic> translatedItem = <String, dynamic>{
    'messageId': '360381357961969667',
    'text': 'Hello',
    'cached': true,
    'error': 'quota exhausted',
  };

  const Map<String, dynamic> translation = <String, dynamic>{
    'targetLanguage': 'zh-CN',
    'items': <Map<String, dynamic>>[translatedItem],
  };

  ImScheduleRequest fullSchedule() => const ImScheduleRequest(
        sendAt: 1755000312000,
        conversationId: 's_alice_bob',
        receiverId: 'bob',
        groupId: 'team',
        conversationType: ImConversationType.group,
        clientMsgId: 'cm-sched-1',
        contentType: ImMessageContentType.custom,
        content: <String, dynamic>{'kind': 'reminder', 'text': 'stand-up'},
        mentionAll: true,
        mentionedUserIds: <String>['bob', 'carol'],
        quoteMessageId: '360381357961969001',
        threadRootId: '360381357961969002',
        extensions: <String, dynamic>{'origin': 'planner'},
      );

  const ImUpsertFolderRequest fullFolder = ImUpsertFolderRequest(
    folderId: 'work',
    name: 'Work',
    order: 3,
    tags: <String>['client', 'urgent'],
    unreadOnly: true,
    types: <ImConversationType>[ImConversationType.single, ImConversationType.group],
  );

  const ImTranslateRequest fullTranslate = ImTranslateRequest(
    conversationId: 's_alice_bob',
    messageIds: <String>['360381357961969667', '360381357961969669'],
    targetLanguage: 'zh-CN',
    sourceLanguage: 'en',
  );

  Matcher refusedWith(int code, [String? message]) => throwsA(isA<ImException>()
      .having((ImException e) => e.code, 'code', code)
      .having((ImException e) => e.message, 'message', message ?? isNotEmpty));

  group('msg.schedule', () {
    test('sends every member flat, under exact camelCase keys, and decodes the schedule', () async {
      final FakeGateway gateway = FakeGateway()
        ..on('msg.schedule', (FakeRequest _) => const FakeData(scheduled));
      final ImClient client = await connectedClient(gateway);

      final ImScheduledMessage result = await client.msg.schedule(fullSchedule());

      expect(gateway.requestsTo('msg.schedule').single.body, <String, dynamic>{
        'sendAt': 1755000312000,
        'conversationId': 's_alice_bob',
        'receiverId': 'bob',
        'groupId': 'team',
        'conversationType': 2,
        'clientMsgId': 'cm-sched-1',
        'contentType': 100,
        'content': <String, dynamic>{'kind': 'reminder', 'text': 'stand-up'},
        'mentionAll': true,
        'mentionedUserIds': <String>['bob', 'carol'],
        'quoteMessageId': '360381357961969001',
        'threadRootId': '360381357961969002',
        'extensions': <String, dynamic>{'origin': 'planner'},
      });

      expect(result.scheduleId, 'sch_360381357961969001');
      expect(result.appId, 'demo');
      expect(result.senderId, 'alice');
      expect(result.conversationId, 's_alice_bob');
      expect(result.sendAt, 1755000312000);
      expect(result.createdAt, 1755000300000);
      expect(result.messageId, '360381357961969667');
      expect(result.error, 'send failed');

      await client.dispose();
    });

    test('a minimal schedule sends the time, the address, the content type and the content, and '
        'no client message id: the server derives one', () async {
      final FakeGateway gateway = FakeGateway()
        ..on('msg.schedule', (FakeRequest _) => const FakeData(<String, dynamic>{
              'scheduleId': 'sch_1',
              'appId': 'demo',
              'senderId': 'alice',
              'conversationId': 's_alice_bob',
              'sendAt': 1755000312000,
              'createdAt': 1755000300000,
            }));
      final ImClient client = await connectedClient(gateway);

      final ImScheduledMessage pending = await client.msg
          .schedule(ImScheduleRequest.text('stand-up', sendAt: 1755000312000, receiverId: 'bob'));

      // No options and no sendTime: the server's ScheduleRequest has neither.
      expect(gateway.requestsTo('msg.schedule').single.body, <String, dynamic>{
        'sendAt': 1755000312000,
        'receiverId': 'bob',
        'contentType': 1,
        'content': <String, dynamic>{'text': 'stand-up'},
        'mentionAll': false,
      });

      expect(pending.messageId, isNull);
      expect(pending.error, isNull);
      expect(pending.state, ImScheduleState.pending);

      await client.dispose();
    });

    test('surfaces the schedule refusals as their codes', () async {
      final List<int> codes = <int>[1001, 1003, 1006, 1303, 1503];
      final FakeGateway gateway = FakeGateway()
        ..script('msg.schedule', <FakeReply>[
          const FakeFail(ImErrorCode.invalidArgument,
              message: 'sendAt must be at least 10 seconds in the future'),
          for (final int code in codes.skip(1)) FakeFail(code),
        ]);
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.msg.schedule(ImScheduleRequest.text('x', sendAt: 1, receiverId: 'bob')),
        refusedWith(1001, 'sendAt must be at least 10 seconds in the future'),
      );
      for (final int code in codes.skip(1)) {
        await expectLater(
          client.msg.schedule(ImScheduleRequest.text('x', sendAt: 1, receiverId: 'bob')),
          refusedWith(code),
        );
      }

      await client.dispose();
    });
  });

  group('msg.scheduled', () {
    test('sends the page request, decodes the page, and reads each entry\'s state', () async {
      final FakeGateway gateway = FakeGateway()
        ..on(
            'msg.scheduled',
            (FakeRequest _) => const FakeData(<String, dynamic>{
                  'items': <Map<String, dynamic>>[
                    scheduled,
                    <String, dynamic>{
                      'scheduleId': 'sch_2',
                      'appId': 'demo',
                      'senderId': 'alice',
                      'conversationId': 's_alice_bob',
                      'sendAt': 1755000312000,
                      'createdAt': 1755000300000,
                      'error': 'cancelled by sender',
                    },
                    <String, dynamic>{
                      'scheduleId': 'sch_3',
                      'appId': 'demo',
                      'senderId': 'alice',
                      'conversationId': 's_alice_bob',
                      'sendAt': 1755000312000,
                      // A quoted long and a bare id: both are read as the server may write them.
                      'createdAt': '1755000300000',
                      'messageId': 1234567,
                    },
                    <String, dynamic>{
                      'scheduleId': 'sch_4',
                      'appId': 'demo',
                      'senderId': 'alice',
                      'conversationId': 's_alice_bob',
                      'sendAt': 1755000312000,
                      'createdAt': 1755000300000,
                      'error': 'content rejected by moderation',
                    },
                  ],
                  'nextCursor': 'sch-c2',
                  'hasMore': true,
                }));
      final ImClient client = await connectedClient(gateway);

      final ImPage<ImScheduledMessage> page =
          await client.msg.scheduled(const ImPageRequest(cursor: 'sch-c1', limit: 100));
      await client.msg.scheduled();

      final List<FakeRequest> frames = gateway.requestsTo('msg.scheduled');
      expect(frames[0].body, <String, dynamic>{'cursor': 'sch-c1', 'limit': 100});
      expect(frames[1].body, <String, dynamic>{'limit': 20});

      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'sch-c2');
      expect(page.total, isNull);
      expect(page.items.map((ImScheduledMessage s) => s.scheduleId),
          <String>['sch_360381357961969001', 'sch_2', 'sch_3', 'sch_4']);

      // A message id wins over an error; the cancellation string is the server's fixed one.
      expect(page.items[0].state, ImScheduleState.sent);
      expect(page.items[1].state, ImScheduleState.cancelled);
      expect(page.items[1].error, ImScheduledMessage.cancelledBySender);
      expect(page.items[2].state, ImScheduleState.sent);
      expect(page.items[2].messageId, '1234567');
      expect(page.items[2].createdAt, 1755000300000);
      expect(page.items[3].state, ImScheduleState.failed);

      await client.dispose();
    });
  });

  group('msg.cancelScheduled', () {
    test('sends the schedule id and surfaces unknown and already-sending as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('msg.cancelScheduled', const <FakeReply>[
          FakeData(),
          FakeFail(ImErrorCode.notFound, message: 'no such scheduled message'),
          FakeFail(ImErrorCode.conflict,
              message: 'this message is already being sent and can no longer be cancelled'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await client.msg.cancelScheduled(const ImScheduleIdRequest(scheduleId: 'sch_1'));
      expect(gateway.requestsTo('msg.cancelScheduled').single.body,
          <String, dynamic>{'scheduleId': 'sch_1'});

      await expectLater(
        client.msg.cancelScheduled(const ImScheduleIdRequest(scheduleId: 'sch_x')),
        refusedWith(1002, 'no such scheduled message'),
      );
      await expectLater(
        client.msg.cancelScheduled(const ImScheduleIdRequest(scheduleId: 'sch_1')),
        refusedWith(1006, 'this message is already being sent and can no longer be cancelled'),
      );

      await client.dispose();
    });
  });

  group('conv.folders', () {
    test('sends no body and decodes the bare array, every member set', () async {
      final FakeGateway gateway = FakeGateway()
        ..on(
            'conv.folders',
            (FakeRequest _) => const FakeData(<Map<String, dynamic>>[
                  folder,
                  // types omitted: the server stores "every type" as null and leaves it out.
                  <String, dynamic>{
                    'folderId': 'f_2',
                    'name': 'All unread',
                    'order': 4,
                    'tags': <String>[],
                    'unreadOnly': true,
                  },
                ]));
      final ImClient client = await connectedClient(gateway);

      final List<ImConversationFolder> folders = await client.conv.folders();

      expect(gateway.requestsTo('conv.folders').single.body, isEmpty);
      expect(folders, hasLength(2));

      final ImConversationFolder work = folders[0];
      expect(work.folderId, 'work');
      expect(work.name, 'Work');
      expect(work.order, 3);
      expect(work.tags, <String>['client', 'urgent']);
      expect(work.unreadOnly, isTrue);
      expect(work.types, <ImConversationType>[ImConversationType.single, ImConversationType.group]);

      expect(folders[1].types, isNull);
      expect(folders[1].tags, isEmpty);

      await client.dispose();
    });
  });

  group('conv.upsertFolder', () {
    test('sends every member, types as integers, and decodes the saved folder', () async {
      final FakeGateway gateway = FakeGateway()
        ..on('conv.upsertFolder', (FakeRequest _) => const FakeData(folder));
      final ImClient client = await connectedClient(gateway);

      final ImConversationFolder saved = await client.conv.upsertFolder(fullFolder);

      expect(gateway.requestsTo('conv.upsertFolder').single.body, <String, dynamic>{
        'folderId': 'work',
        'name': 'Work',
        'order': 3,
        'tags': <String>['client', 'urgent'],
        'unreadOnly': true,
        'types': <int>[1, 2],
      });
      expect(saved.folderId, 'work');
      expect(saved.types, <ImConversationType>[ImConversationType.single, ImConversationType.group]);

      await client.dispose();
    });

    test('a minimal create sends the name, the order and the unread flag; no tags is no tags key, '
        'which the server reads as empty', () async {
      final FakeGateway gateway = FakeGateway()
        ..on('conv.upsertFolder', (FakeRequest _) => const FakeData(folder));
      final ImClient client = await connectedClient(gateway);

      await client.conv.upsertFolder(const ImUpsertFolderRequest(name: 'Work'));

      expect(gateway.requestsTo('conv.upsertFolder').single.body, <String, dynamic>{
        'name': 'Work',
        'order': 0,
        'unreadOnly': false,
      });

      await client.dispose();
    });

    test('edit keeps every member it is not told to change, because a save replaces the folder',
        () async {
      final FakeGateway gateway = FakeGateway()
        ..on('conv.upsertFolder', (FakeRequest _) => const FakeData(folder));
      final ImClient client = await connectedClient(gateway);

      final ImConversationFolder held = ImConversationFolder.fromJson(folder);
      await client.conv.upsertFolder(ImUpsertFolderRequest.edit(held, name: 'Clients'));
      await client.conv.upsertFolder(
          ImUpsertFolderRequest.edit(held, tags: <String>['client'], unreadOnly: false));
      await client.conv.upsertFolder(ImUpsertFolderRequest.edit(held, tags: const <String>[]));

      final List<FakeRequest> frames = gateway.requestsTo('conv.upsertFolder');
      expect(frames[0].body, <String, dynamic>{
        'folderId': 'work',
        'name': 'Clients',
        'order': 3,
        'tags': <String>['client', 'urgent'],
        'unreadOnly': true,
        'types': <int>[1, 2],
      });
      expect(frames[1].body, <String, dynamic>{
        'folderId': 'work',
        'name': 'Work',
        'order': 3,
        'tags': <String>['client'],
        'unreadOnly': false,
        'types': <int>[1, 2],
      });
      // Clearing the tags leaves the key out, which the server stores as an empty list: cleared.
      expect(frames[2].body, <String, dynamic>{
        'folderId': 'work',
        'name': 'Work',
        'order': 3,
        'unreadOnly': true,
        'types': <int>[1, 2],
      });

      await client.dispose();
    });

    test('surfaces the folder refusals as their codes', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('conv.upsertFolder', const <FakeReply>[
          FakeFail(ImErrorCode.invalidArgument,
              message: 'none of your conversations are tagged vip; tag them before filing them'),
          FakeFail(ImErrorCode.conflict, message: 'you already have 20 folders; delete one first'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.conv.upsertFolder(const ImUpsertFolderRequest(name: 'VIP', tags: <String>['vip'])),
        refusedWith(1001, 'none of your conversations are tagged vip; tag them before filing them'),
      );
      await expectLater(
        client.conv.upsertFolder(const ImUpsertFolderRequest(name: 'One more')),
        refusedWith(1006, 'you already have 20 folders; delete one first'),
      );

      await client.dispose();
    });
  });

  group('conv.deleteFolder', () {
    test('sends the folder id and surfaces an unknown one as 1002', () async {
      final FakeGateway gateway = FakeGateway()
        ..script('conv.deleteFolder', const <FakeReply>[
          FakeData(),
          FakeFail(ImErrorCode.notFound, message: 'no such folder'),
        ]);
      final ImClient client = await connectedClient(gateway);

      await client.conv.deleteFolder(const ImFolderIdRequest(folderId: 'work'));
      expect(gateway.requestsTo('conv.deleteFolder').single.body,
          <String, dynamic>{'folderId': 'work'});

      await expectLater(
        client.conv.deleteFolder(const ImFolderIdRequest(folderId: 'work')),
        refusedWith(1002, 'no such folder'),
      );

      await client.dispose();
    });
  });

  group('msg.translate', () {
    test('sends every member, ids as strings, and decodes every member of the result', () async {
      final FakeGateway gateway = FakeGateway()
        ..on('msg.translate', (FakeRequest _) => const FakeData(translation));
      final ImClient client = await connectedClient(gateway);

      final ImTranslationResult result = await client.msg.translate(fullTranslate);

      expect(gateway.requestsTo('msg.translate').single.body, <String, dynamic>{
        'conversationId': 's_alice_bob',
        'messageIds': <String>['360381357961969667', '360381357961969669'],
        'targetLanguage': 'zh-CN',
        'sourceLanguage': 'en',
      });

      expect(result.targetLanguage, 'zh-CN');
      final ImTranslatedMessage item = result.items.single;
      expect(item.messageId, '360381357961969667');
      expect(item.text, 'Hello');
      expect(item.cached, isTrue);
      expect(item.error, 'quota exhausted');

      await client.dispose();
    });

    test('a minimal request leaves the source language out; per-message failures ride in items',
        () async {
      final FakeGateway gateway = FakeGateway()
        ..on(
            'msg.translate',
            (FakeRequest _) => const FakeData(<String, dynamic>{
                  'targetLanguage': 'zh-CN',
                  'items': <Map<String, dynamic>>[
                    <String, dynamic>{'messageId': 1001, 'text': '你好', 'cached': false},
                    <String, dynamic>{'messageId': '1002', 'cached': false, 'error': 'not readable'},
                  ],
                }));
      final ImClient client = await connectedClient(gateway);

      final ImTranslationResult result = await client.msg.translate(const ImTranslateRequest(
        conversationId: 's_alice_bob',
        messageIds: <String>['1001', '1002'],
        targetLanguage: 'zh-CN',
      ));

      expect(gateway.requestsTo('msg.translate').single.body, <String, dynamic>{
        'conversationId': 's_alice_bob',
        'messageIds': <String>['1001', '1002'],
        'targetLanguage': 'zh-CN',
      });
      expect(result.items[0].messageId, '1001');
      expect(result.items[0].text, '你好');
      expect(result.items[0].error, isNull);
      expect(result.items[1].text, isNull);
      expect(result.items[1].error, 'not readable');

      await client.dispose();
    });

    test('no provider (1203) and no add-on (1204) reach the caller as readable refusals, and the '
        'client keeps working', () async {
      const String noProvider = 'no translation provider is configured (IM:Translation:Provider)';
      const String notInPlan = 'message translation is not included in this plan; start its trial '
          'or enable the add-on in the console';
      final FakeGateway gateway = FakeGateway()
        ..script('msg.translate', const <FakeReply>[
          FakeFail(ImErrorCode.featureNotEnabled, message: noProvider, traceId: 'tr-1203'),
          FakeFail(ImErrorCode.planExpired, message: notInPlan),
          FakeFail(ImErrorCode.invalidArgument, message: 'messageIds is required'),
          FakeFail(ImErrorCode.rateLimited),
        ]);
      final ImClient client = await connectedClient(gateway);
      final List<ImException> raised = <ImException>[];
      client.errors.listen(raised.add);

      final List<ImException> errors = <ImException>[];
      for (int i = 0; i < 4; i++) {
        try {
          await client.msg.translate(fullTranslate);
          fail('msg.translate succeeded against a refusal');
        } on ImException catch (error) {
          errors.add(error);
        }
      }

      expect(errors[0].code, ImErrorCode.featureNotEnabled);
      expect(errors[0].code, 1203);
      expect(errors[0].message, noProvider);
      expect(errors[0].traceId, 'tr-1203');
      expect(errors[0].target, 'msg.translate');
      expect(errors[1].code, 1204);
      expect(errors[1].message, notInPlan);
      expect(errors[2].code, 1001);
      expect(errors[3].code, 1003);

      // A refusal is not a session failure: nothing raised, the socket still open, and the next
      // call goes out (not latched).
      await settle();
      expect(raised, isEmpty);
      expect(client.state, ImConnectionState.open);
      expect(gateway.callsTo('msg.translate'), 4);

      await client.dispose();
    });
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

    expect(scheduled.keys.toSet(), members('ScheduledMessage'));
    expect(folder.keys.toSet(), members('ConversationFolder'));
    expect(translation.keys.toSet(), members('TranslationResult'));
    expect(translatedItem.keys.toSet(), members('TranslatedMessage'));

    expect(fullSchedule().toJson().keys.toSet(), members('ScheduleRequest'));
    expect(fullFolder.toJson().keys.toSet(), members('UpsertFolderRequest'));
    expect(fullTranslate.toJson().keys.toSet(), members('TranslateRequest'));
    expect(const ImScheduleIdRequest(scheduleId: 's').toJson().keys.toSet(),
        members('ScheduleIdRequest'));
    expect(const ImFolderIdRequest(folderId: 'f').toJson().keys.toSet(), members('FolderIdRequest'));
    expect(const ImPageRequest(cursor: 'c').toJson().keys.toSet(), members('PageRequest'));

    // The decoded side, every member read back as the fixture holds it.
    final ImScheduledMessage s = ImScheduledMessage.fromJson(scheduled);
    expect(<String, Object?>{
      'scheduleId': s.scheduleId,
      'appId': s.appId,
      'senderId': s.senderId,
      'conversationId': s.conversationId,
      'sendAt': s.sendAt,
      'createdAt': s.createdAt,
      'messageId': s.messageId,
      'error': s.error,
    }, scheduled);
    final ImConversationFolder f = ImConversationFolder.fromJson(folder);
    expect(<String, Object?>{
      'folderId': f.folderId,
      'name': f.name,
      'order': f.order,
      'tags': f.tags,
      'unreadOnly': f.unreadOnly,
      'types': <int>[for (final ImConversationType t in f.types!) t.wireValue],
    }, folder);
    final ImTranslatedMessage t = ImTranslationResult.fromJson(translation).items.single;
    expect(<String, Object?>{
      'messageId': t.messageId,
      'text': t.text,
      'cached': t.cached,
      'error': t.error,
    }, translatedItem);
  });

  test('the seven targets are the inventory\'s, with their DTOs', () {
    final Map<String, Map<String, dynamic>> endpoints = <String, Map<String, dynamic>>{
      for (final dynamic endpoint in inventory()['endpoints'] as List<dynamic>)
        (endpoint as Map<String, dynamic>)['target'] as String: endpoint,
    };

    const Map<String, List<String?>> expected = <String, List<String?>>{
      'msg.schedule': <String?>['ScheduleRequest', 'ScheduledMessage'],
      'msg.scheduled': <String?>['PageRequest', 'PagedResult<ScheduledMessage>'],
      'msg.cancelScheduled': <String?>['ScheduleIdRequest', null],
      'conv.folders': <String?>[null, 'List<ConversationFolder>'],
      'conv.upsertFolder': <String?>['UpsertFolderRequest', 'ConversationFolder'],
      'conv.deleteFolder': <String?>['FolderIdRequest', null],
      'msg.translate': <String?>['TranslateRequest', 'TranslationResult'],
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
