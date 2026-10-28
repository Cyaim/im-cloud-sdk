import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `desk.*` — the nine customer-service verbs, and the `evt.desk` frame.
///
/// Every verb is asserted on the frame it puts on the wire — target and the whole body — and on what
/// it makes of a representative reply. Three properties carry the weight and none is visible from a
/// signature: a transfer names exactly one target, an absent optional member is not the same as one
/// set to a value (`inviteRating` omitted *invites*), and `endReason` is a string where its
/// neighbour `state` is an integer.
///
/// 每个动词都断言它发出的整帧，以及它对一个代表性答复的解码。
void main() {
  Map<String, dynamic> session({required bool full}) => <String, dynamic>{
        'sessionId': 'ds_1',
        'appId': 'demo',
        'customerId': 'v_01hh',
        'conversationId': 's_desk_v_01hh',
        'state': full ? 1 : 0,
        'priority': full ? 3 : 0,
        'queuedAt': 1755000000000,
        // Every member of the server's DeskSession, each with a value no default reads as — so a key
        // spelled wrong in fromJson decodes to null or a default and an expectation below fails.
        // 'the full fixtures carry every member the server declares' holds the list to the inventory.
        if (full) ...<String, dynamic>{
          'agentId': 'a_7',
          'skill': 'billing',
          'assignedAt': 1755000060000,
          'closedAt': 1755000900000,
          'resolution': 'refunded',
          'context': <String, dynamic>{'desk.channel': 'app'},
          'history': <dynamic>['a_3'],
          'firstAgentMessageAt': 1755000070000,
          'rating': 4,
          'ratingInvitedAt': 1755000910000,
          'ratingComment': 'quick',
          'ratedAt': 1755000920000,
          'channel': 'app',
          'visitorId': 'v_01hh',
          'deskId': 'dk_1',
          'groupId': 'g_billing',
          'disposition': 'resolved',
          'ratingReason': 'slow at first',
          'ratingTags': <dynamic>['polite'],
          'snoozedUntil': 1755001000000,
          'summary': <String, dynamic>{
            'issue': 'refund',
            'state': 'waiting on finance',
            'nextStep': 'check the order',
            'generatedAt': 1755000050000,
            'model': 'demo/model',
          },
          'tags': <dynamic>['billing/refund'],
          'endReason': 'bot-handoff',
          'ratingResolved': false,
          'star': true,
          'responseSamples': <dynamic>[
            <String, dynamic>{'customerAt': 1, 'agentAt': 2, 'agentId': 'a_7'},
          ],
        },
      };

  Map<String, dynamic> queueView({required bool measured}) => <String, dynamic>{
        'waiting': 3,
        'assigned': 2,
        'availableAgents': 1,
        'headWaitSeconds': 95,
        if (measured) 'avgFirstResponseSeconds': 12.5,
        'waitingBySkill': <String, dynamic>{'billing': 3},
      };

  const Map<String, dynamic> cannedRow = <String, dynamic>{
    'id': 'cr_1',
    'title': 'Refunds',
    'content': 'Refunds take 3–5 days.',
    'skill': 'billing',
    'scope': 'personal',
    'folder': 'refunds',
    'ownerMemberId': 'm_1',
    'updatedAt': 1755000000000,
  };

  FakeGateway deskGateway({bool measuredQueue = false}) => FakeGateway()
    ..on('desk.request', (FakeRequest _) => FakeData(session(full: false)))
    ..on('desk.accept', (FakeRequest _) => FakeData(session(full: true)))
    ..on('desk.queue', (FakeRequest _) => FakeData(queueView(measured: measuredQueue)))
    ..on(
      'desk.canned',
      (FakeRequest _) => const FakeData(<dynamic>[
        cannedRow,
        <String, dynamic>{'id': 'cr_2', 'title': 'Hello', 'content': 'Hi!', 'scope': 'all', 'updatedAt': 1},
      ]),
    )
    ..on('desk.suggest', (FakeRequest _) => const FakeData(<dynamic>['Sure — one moment.']));

  group('desk.request', () {
    test('sends an empty body by default and decodes a queued session with its absences', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      final ImDeskSession queued = await client.desk.request();
      expect(gateway.requestsTo('desk.request').single.body, isEmpty,
          reason: 'the plain "talk to a human" button sends nothing');

      expect(queued.sessionId, 'ds_1');
      expect(queued.state, ImDeskSessionState.queued);
      expect(queued.agentId, isNull, reason: 'absent while queued');
      expect(queued.endReason, isNull);
      expect(queued.summary, isNull);
      expect(queued.tags, isEmpty);
      expect(queued.star, isFalse);
      expect(queued.ratingResolved, isNull);

      await client.desk.request(const ImDeskRequest(
        skill: 'billing',
        priority: 2,
        context: <String, Object?>{'desk.page': '/orders/9'},
      ));
      expect(gateway.requestsTo('desk.request').last.body, <String, dynamic>{
        'skill': 'billing',
        'priority': 2,
        'context': <String, dynamic>{'desk.page': '/orders/9'},
      });

      await client.dispose();
    });
  });

  group('desk.accept', () {
    test('names the session or nothing, and decodes every product field', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.accept();
      final ImDeskSession taken = await client.desk.accept(const ImDeskAcceptRequest(sessionId: 'ds_1'));

      final List<FakeRequest> sent = gateway.requestsTo('desk.accept');
      expect(sent[0].body, isEmpty, reason: '"give me the next" names no session');
      expect(sent[1].body, <String, dynamic>{'sessionId': 'ds_1'});

      expect(taken.sessionId, 'ds_1');
      expect(taken.appId, 'demo');
      expect(taken.customerId, 'v_01hh');
      expect(taken.agentId, 'a_7');
      expect(taken.conversationId, 's_desk_v_01hh');
      expect(taken.state, ImDeskSessionState.assigned);
      expect(taken.skill, 'billing');
      expect(taken.priority, 3);
      expect(taken.queuedAt, 1755000000000);
      expect(taken.assignedAt, 1755000060000);
      expect(taken.closedAt, 1755000900000);
      expect(taken.resolution, 'refunded');
      expect(taken.context, <String, dynamic>{'desk.channel': 'app'});
      expect(taken.history, <String>['a_3']);
      expect(taken.firstAgentMessageAt, 1755000070000);
      expect(taken.rating, 4);
      expect(taken.ratingInvitedAt, 1755000910000);
      expect(taken.ratingComment, 'quick');
      expect(taken.ratedAt, 1755000920000);
      expect(taken.summary?.issue, 'refund');
      expect(taken.summary?.state, 'waiting on finance');
      expect(taken.summary?.nextStep, 'check the order');
      expect(taken.summary?.generatedAt, 1755000050000);
      expect(taken.summary?.model, 'demo/model');
      expect(taken.tags, <String>['billing/refund']);
      expect(taken.channel, 'app');
      expect(taken.visitorId, 'v_01hh');
      expect(taken.deskId, 'dk_1');
      expect(taken.groupId, 'g_billing');
      expect(taken.disposition, ImDeskDisposition.resolved);
      // A string on the wire, unlike `state` beside it.
      expect(taken.endReason, ImDeskEndReason.botHandoff);
      expect(taken.ratingReason, 'slow at first');
      expect(taken.ratingResolved, isFalse);
      expect(taken.ratingTags, <String>['polite']);
      expect(taken.star, isTrue);
      expect(taken.snoozedUntil, 1755001000000);
      expect(taken.responseSamples.single.customerAt, 1);
      expect(taken.responseSamples.single.agentAt, 2);
      expect(taken.responseSamples.single.agentId, 'a_7');

      await client.dispose();
    });
  });

  group('desk.transfer', () {
    test('sends exactly the one target its constructor names', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.transfer(
          const ImDeskTransferRequest.agent(sessionId: 'ds_1', agentId: 'a_9', note: 'VIP, be gentle'));
      await client.desk.transfer(const ImDeskTransferRequest.skill(sessionId: 'ds_1', skill: 'billing'));
      await client.desk.transfer(const ImDeskTransferRequest.queue(sessionId: 'ds_1'));

      final List<FakeRequest> sent = gateway.requestsTo('desk.transfer');
      expect(sent[0].body,
          <String, dynamic>{'sessionId': 'ds_1', 'toAgentId': 'a_9', 'note': 'VIP, be gentle'});
      expect(sent[1].body, <String, dynamic>{'sessionId': 'ds_1', 'toSkill': 'billing'});
      // `toQueue` is a C# bool: true/false, never "true" or 1, and only when it is the target.
      expect(sent[2].body, <String, dynamic>{'sessionId': 'ds_1', 'toQueue': true});

      await client.dispose();
    });

    test('surfaces the server refusal', () async {
      final FakeGateway gateway = deskGateway()
        ..on('desk.transfer', (FakeRequest _) => const FakeFail(ImErrorCode.invalidArgument));
      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.desk.transfer(const ImDeskTransferRequest.queue(sessionId: 'ds_1')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.invalidArgument)
            .having((ImException e) => e.target, 'target', 'desk.transfer')),
      );

      await client.dispose();
    });
  });

  group('desk.close', () {
    test('sends only what the agent filled in, and inviteRating only when said out loud', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.close(const ImDeskCloseRequest(sessionId: 'ds_1'));
      await client.desk.close(const ImDeskCloseRequest(
        sessionId: 'ds_1',
        resolution: 'refunded',
        tags: <String>['billing/refund'],
        disposition: ImDeskDisposition.toLead,
        summary: 'wants a refund, passed to sales',
        inviteRating: false,
      ));

      final List<FakeRequest> sent = gateway.requestsTo('desk.close');
      // Omitting inviteRating invites; sending false would be a different request.
      expect(sent[0].body, <String, dynamic>{'sessionId': 'ds_1'});
      expect(sent[1].body, <String, dynamic>{
        'sessionId': 'ds_1',
        'resolution': 'refunded',
        'tags': <dynamic>['billing/refund'],
        'disposition': 'to-lead',
        'summary': 'wants a refund, passed to sales',
        'inviteRating': false,
      });

      await client.dispose();
    });
  });

  group('desk.status', () {
    test('sends the agent status as its integer', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.status(const ImDeskStatusRequest(status: ImAgentStatus.available));
      await client.desk.status(const ImDeskStatusRequest(status: ImAgentStatus.busy, maxConcurrent: 4));

      final List<FakeRequest> sent = gateway.requestsTo('desk.status');
      // An enum by name is refused with 1000 before the endpoint runs.
      expect(sent[0].body, <String, dynamic>{'status': 1});
      expect(sent[1].body, <String, dynamic>{'status': 2, 'maxConcurrent': 4});

      await client.dispose();
    });
  });

  group('desk.queue', () {
    test('sends no body and keeps an unmeasured average null', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      final ImDeskQueueView view = await client.desk.queue();

      expect(gateway.requestsTo('desk.queue').single.body, isEmpty);
      expect(view.waiting, 3);
      expect(view.assigned, 2);
      expect(view.availableAgents, 1);
      expect(view.headWaitSeconds, 95);
      expect(view.avgFirstResponseSeconds, isNull,
          reason: 'absent is "not measured", and must not read as 0');
      expect(view.waitingBySkill, <String, int>{'billing': 3});

      await client.dispose();
    });

    test('decodes a measured average', () async {
      final FakeGateway gateway = deskGateway(measuredQueue: true);
      final ImClient client = await connectedClient(gateway);

      final ImDeskQueueView view = await client.desk.queue();

      expect(view.avgFirstResponseSeconds, 12.5);

      await client.dispose();
    });
  });

  group('desk.rate', () {
    test('omits what the survey did not ask', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.rate(const ImDeskRateRequest(sessionId: 'ds_1', score: 5));
      await client.desk.rate(const ImDeskRateRequest(
        sessionId: 'ds_1',
        score: 2,
        resolved: false,
        starTags: <String>['slow'],
        comment: 'twenty minutes',
      ));

      final List<FakeRequest> sent = gateway.requestsTo('desk.rate');
      // resolved absent = the survey never asked; resolved false = "no".
      expect(sent[0].body, <String, dynamic>{'sessionId': 'ds_1', 'score': 5});
      expect(sent[1].body, <String, dynamic>{
        'sessionId': 'ds_1',
        'score': 2,
        'resolved': false,
        'starTags': <dynamic>['slow'],
        'comment': 'twenty minutes',
      });

      await client.dispose();
    });
  });

  group('desk.canned', () {
    test('filters by what it is given and decodes each tier', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      await client.desk.canned();
      final List<ImDeskCannedReply> replies = await client.desk.canned(const ImDeskCannedRequest(
        skill: 'billing',
        scope: ImDeskCannedReplyScope.personal,
        ownerMemberId: 'm_1',
      ));

      final List<FakeRequest> sent = gateway.requestsTo('desk.canned');
      expect(sent[0].body, isEmpty);
      expect(sent[1].body,
          <String, dynamic>{'skill': 'billing', 'scope': 'personal', 'ownerMemberId': 'm_1'});

      expect(replies.map((ImDeskCannedReply r) => r.id), <String>['cr_1', 'cr_2']);
      expect(replies[0].title, 'Refunds');
      expect(replies[0].content, 'Refunds take 3–5 days.');
      expect(replies[0].skill, 'billing');
      expect(replies[0].scope, ImDeskCannedReplyScope.personal);
      expect(replies[0].folder, 'refunds');
      expect(replies[0].ownerMemberId, 'm_1');
      expect(replies[0].updatedAt, 1755000000000);
      expect(replies[1].scope, ImDeskCannedReplyScope.all);
      expect(replies[1].ownerMemberId, isNull);
      expect(replies[1].skill, isNull);
      expect(replies[1].folder, isNull);

      await client.dispose();
    });
  });

  group('desk.suggest', () {
    test('names the session and returns the drafts', () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);

      final List<String> drafts =
          await client.desk.suggest(const ImDeskSuggestRequest(sessionId: 'ds_1'));

      expect(gateway.requestsTo('desk.suggest').single.body, <String, dynamic>{'sessionId': 'ds_1'});
      expect(drafts, <String>['Sure — one moment.']);

      await client.dispose();
    });
  });

  group('evt.desk', () {
    test('frames decode, a forced release carries no session, and an unknown event is dropped',
        () async {
      final FakeGateway gateway = deskGateway();
      final ImClient client = await connectedClient(gateway);
      final List<ImDeskEvent> received = <ImDeskEvent>[];
      final subscription = client.deskEvents.listen(received.add);

      void push(Map<String, dynamic> data) => gateway.socket.deliver(<String, dynamic>{
            'id': 'srv-${received.length}',
            'target': 'evt.desk',
            'status': 0,
            'body': <String, dynamic>{'code': 0, 'serverTime': 1, 'data': data},
          });

      push(<String, dynamic>{
        'event': 'desk.session',
        'change': 'message',
        'session': session(full: true),
        'message': <String, dynamic>{'messageId': '360381357961969667'},
      });
      push(<String, dynamic>{
        'event': 'desk.session',
        'change': 'released',
        'reason': 'supervisor',
        'forced': true,
      });
      push(<String, dynamic>{
        'event': 'desk.agent',
        'change': 'takeover',
        'connectionId': 'conn-2',
        'memberId': 'm_1',
      });
      push(<String, dynamic>{'event': 'desk.somethingNew'});
      push(<String, dynamic>{
        'event': 'desk.session',
        'change': 'overdue',
        'session': session(full: true),
        'kind': 'first-response',
        'assignedAt': 1755000060000,
        'minutes': 5,
      });
      push(<String, dynamic>{
        'event': 'desk.session',
        'change': 'inactive',
        'session': session(full: true),
        'minutes': 10,
        'silentSince': 1755000500000,
        'star': true,
      });
      push(<String, dynamic>{
        'event': 'desk.session',
        'change': 'note',
        'session': session(full: true),
        'note': <String, dynamic>{'text': 'called back'},
        'author': <String, dynamic>{'memberId': 'm_2'},
      });

      await pumpUntil(() => received.length >= 6, because: 'six desk frames were pushed');
      await settle();
      await subscription.cancel();

      expect(received, hasLength(6), reason: 'the unknown event is dropped, not delivered half-built');
      expect(received[0].change, ImDeskSessionChange.message);
      expect(received[0].session?.sessionId, 'ds_1');
      expect(received[0].message?['messageId'], '360381357961969667');

      expect(received[1].change, ImDeskSessionChange.released);
      expect(received[1].session, isNull, reason: 'a forced release carries no session');
      expect(received[1].forced, isTrue);
      expect(received[1].reason, 'supervisor');

      expect(received[2].event, ImDeskEvent.agentEvent);
      expect(received[2].change, ImDeskSessionChange.takeover);
      expect(received[2].connectionId, 'conn-2');
      expect(received[2].memberId, 'm_1');
      expect(received[2].session, isNull);

      expect(received[3].change, ImDeskSessionChange.overdue);
      expect(received[3].kind, 'first-response');
      expect(received[3].assignedAt, 1755000060000);
      expect(received[3].minutes, 5);

      expect(received[4].change, ImDeskSessionChange.inactive);
      expect(received[4].minutes, 10);
      expect(received[4].silentSince, 1755000500000);
      expect(received[4].star, isTrue);

      expect(received[5].change, ImDeskSessionChange.note);
      expect(received[5].note, <String, dynamic>{'text': 'called back'});
      expect(received[5].author, <String, dynamic>{'memberId': 'm_2'});

      await client.dispose();
    });

    test("the change values are the server's thirteen, in its order (CONTRACT §4.5)", () {
      final Map<String, dynamic> changes = inventory()['deskChanges'] as Map<String, dynamic>;
      expect(ImDeskSessionChange.all, changes.values.toList());
    });
  });

  // Translated case for case from typescript/test/desk.test.ts, plus this package's lenient decoding:
  // numbers in strings, members of the wrong kind, a notice decoded off the wire.
  group('the 1801-1807 notices are messages and have to be read as such', () {
    /// A desk notice, as it arrives inside an ordinary message on the customer's transcript.
    ImMessage notice(
      Map<String, dynamic> content, {
      ImMessageContentType contentType = ImMessageContentType.notification,
    }) =>
        ImMessage.fromJson(<String, dynamic>{
          'appId': 'demo',
          'conversationId': 'c1',
          'conversationType': 1,
          'seq': 4,
          'messageId': '350598345233801216',
          'clientMsgId': 'desk-1801-x',
          'senderId': 'desk',
          'senderPlatform': 100,
          'contentType': contentType.wireValue,
          'content': content,
          'sendTime': 1755000000000,
          'createTime': 1755000000000,
        });

    test('reads all seven codes with the extras each one carries', () {
      final ImDeskNotification? queued = readDeskNotification(notice(<String, dynamic>{
        'code': 1801,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': 'billing',
      }));
      expect(queued, isA<ImDeskQueuedNotification>());
      expect(queued!.code, ImDeskNotificationCode.queued);
      expect(queued.sessionId, 'ds_1');
      expect(queued.customerId, 'v_1');
      expect(queued.skill, 'billing');
      expect(queued.agentId, isNull);

      final ImDeskNotification? assigned = readDeskNotification(notice(<String, dynamic>{
        'code': 1802,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'agentId': 'a_7',
      }));
      expect(assigned, isA<ImDeskAssignedNotification>());
      expect(assigned!.code, ImDeskNotificationCode.assigned);
      expect(assigned.agentId, 'a_7');
      // `skill` is written into a dictionary, where "omit nulls" does not reach, so the key is there
      // and the value is null. `agentId` is only written when there is one. Two different absences.
      // skill 是写进字典的，「省略 null」管不到它：键在、值是 null。agentId 则是有才写。两种不同的「没有」。
      expect(assigned.skill, isNull);

      final ImDeskNotification? transferred = readDeskNotification(notice(<String, dynamic>{
        'code': 1803,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'agentId': 'a_8',
        'fromAgentId': 'a_7',
      }));
      expect(transferred, isA<ImDeskTransferredNotification>());
      expect(transferred!.code, ImDeskNotificationCode.transferred);
      expect(transferred.agentId, 'a_8');
      expect((transferred as ImDeskTransferredNotification).fromAgentId, 'a_7');

      final ImDeskNotification? closed = readDeskNotification(notice(<String, dynamic>{
        'code': 1804,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'reason': 'timeout',
      }));
      expect(closed, isA<ImDeskClosedNotification>());
      expect(closed!.code, ImDeskNotificationCode.closed);
      expect((closed as ImDeskClosedNotification).reason, ImDeskEndReason.timeout);
      expect(closed.resolution, isNull);

      final ImDeskNotification? requeued = readDeskNotification(notice(<String, dynamic>{
        'code': 1805,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'previousAgentId': 'a_7',
      }));
      expect(requeued, isA<ImDeskRequeuedNotification>());
      expect(requeued!.code, ImDeskNotificationCode.requeued);
      expect((requeued as ImDeskRequeuedNotification).previousAgentId, 'a_7');

      final ImDeskNotification? abandoned = readDeskNotification(notice(<String, dynamic>{
        'code': 1806,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'waitedSeconds': 903,
      }));
      expect(abandoned, isA<ImDeskAbandonedNotification>());
      expect(abandoned!.code, ImDeskNotificationCode.abandoned);
      expect((abandoned as ImDeskAbandonedNotification).waitedSeconds, 903);

      final ImDeskNotification? rating = readDeskNotification(notice(<String, dynamic>{
        'code': 1807,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'windowHours': 24,
        'askResolved': true,
        'starTags': <dynamic>['slow', 'wrong answer'],
      }));
      expect(rating, isA<ImDeskRatingRequestedNotification>());
      expect(rating!.code, ImDeskNotificationCode.ratingRequested);
      final ImDeskRatingRequestedNotification survey = rating as ImDeskRatingRequestedNotification;
      expect(survey.starTags, <String>['slow', 'wrong answer']);
      expect(survey.askResolved, isTrue);
      expect(survey.windowHours, 24);
    });

    test('keeps a typed resolution and leaves both absent when nothing was filled in', () {
      final ImDeskNotification? typed = readDeskNotification(notice(<String, dynamic>{
        'code': 1804,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': 'billing',
        'agentId': 'a_7',
        'resolution': 'refunded',
      }));
      expect(typed, isA<ImDeskClosedNotification>());
      final ImDeskClosedNotification closed = typed! as ImDeskClosedNotification;
      expect(closed.resolution, 'refunded');
      expect(closed.reason, isNull);
      expect(closed.skill, 'billing');
      expect(closed.agentId, 'a_7');

      final ImDeskClosedNotification bare = readDeskNotification(notice(<String, dynamic>{
        'code': 1804,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
      }))! as ImDeskClosedNotification;
      expect(bare.resolution, isNull);
      expect(bare.reason, isNull);
      expect(bare.agentId, isNull);
    });

    test('coerces the counts the server may have written as strings', () {
      // `NumberHandling.AllowReadingFromString` runs in both directions in practice: a 64-bit value
      // can arrive quoted. The code itself is read the same way.
      // 服务端可以把 64 位数字写成字符串；码值与计数都按同一条规则读。
      final ImDeskNotification? abandoned = readDeskNotification(notice(<String, dynamic>{
        'code': '1806',
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'skill': null,
        'waitedSeconds': '903',
      }));
      expect(abandoned, isA<ImDeskAbandonedNotification>());
      expect((abandoned! as ImDeskAbandonedNotification).waitedSeconds, 903);

      final ImDeskNotification? rating = readDeskNotification(notice(<String, dynamic>{
        'code': 1807,
        'sessionId': 'ds_1',
        'customerId': 'v_1',
        'windowHours': '48',
      }));
      expect((rating! as ImDeskRatingRequestedNotification).windowHours, 48);

      // A whole number in any spelling TypeScript's `Number(…)` also reads as one.
      expect(readDeskNotification(notice(<String, dynamic>{'code': 1802.0})), isA<ImDeskAssignedNotification>());
      expect(readDeskNotification(notice(<String, dynamic>{'code': '1.805e3'})), isA<ImDeskRequeuedNotification>());
      final ImDeskNotification? fractional =
          readDeskNotification(notice(<String, dynamic>{'code': 1806, 'waitedSeconds': '903.9'}));
      expect((fractional! as ImDeskAbandonedNotification).waitedSeconds, 903,
          reason: 'a fractional count is truncated: the field is an int');
      final ImDeskNotification? large = readDeskNotification(
          notice(<String, dynamic>{'code': 1806, 'waitedSeconds': '4294967296'}));
      expect((large! as ImDeskAbandonedNotification).waitedSeconds, 4294967296);
    });

    test('reads a member of the wrong kind as its default and never throws', () {
      // A notice is half of a customer's transcript: one odd member must not make the whole line
      // vanish, and it must not throw out of the message handler either.
      // 一个字段类型不对，不能让整条通知消失，更不能从消息回调里抛出去。
      final ImDeskNotification? odd = readDeskNotification(notice(<String, dynamic>{
        'code': 1803,
        'sessionId': 360381357961969667, // an older server's numeric id: kept as its literal
        // customerId absent
        'skill': 7,
        'agentId': '',
        'fromAgentId': <String, dynamic>{'id': 'a_7'},
      }));
      expect(odd, isA<ImDeskTransferredNotification>());
      final ImDeskTransferredNotification transferred = odd! as ImDeskTransferredNotification;
      expect(transferred.sessionId, '360381357961969667');
      expect(transferred.customerId, '');
      expect(transferred.skill, isNull, reason: 'a number is not a skill; imString would have said "7"');
      expect(transferred.agentId, isNull, reason: 'an empty agentId is no agent');
      expect(transferred.fromAgentId, '', reason: 'an object where an id belongs is no id');

      final ImDeskClosedNotification closed = readDeskNotification(notice(<String, dynamic>{
        'code': 1804,
        'sessionId': 'ds_1',
        'resolution': 3,
        'reason': true,
        'agentId': 9,
      }))! as ImDeskClosedNotification;
      expect(closed.sessionId, 'ds_1');
      expect(closed.resolution, isNull);
      expect(closed.reason, isNull);
      expect(closed.agentId, isNull);

      final ImDeskRequeuedNotification requeued = readDeskNotification(
          notice(<String, dynamic>{'code': 1805, 'previousAgentId': null}))! as ImDeskRequeuedNotification;
      expect(requeued.previousAgentId, '');
      expect(requeued.sessionId, '');
      expect(requeued.skill, isNull);

      for (final Object? waited in <Object?>['soon', <String, dynamic>{}, true, 'NaN', 'Infinity', '']) {
        final ImDeskNotification? abandoned =
            readDeskNotification(notice(<String, dynamic>{'code': 1806, 'waitedSeconds': waited}));
        expect((abandoned! as ImDeskAbandonedNotification).waitedSeconds, 0,
            reason: 'a count that is not a finite number ($waited) reads as 0');
      }

      final ImDeskRatingRequestedNotification rating = readDeskNotification(notice(<String, dynamic>{
        'code': 1807,
        'windowHours': 'a day',
        'askResolved': 'true', // a string is not the JSON true
        'starTags': <dynamic>['slow', 5, null, <String, dynamic>{'tag': 'x'}, 'rude'],
      }))! as ImDeskRatingRequestedNotification;
      expect(rating.windowHours, 0);
      expect(rating.askResolved, isFalse);
      expect(rating.starTags, <String>['slow', 'rude']);

      final ImDeskRatingRequestedNotification tagsNotAList = readDeskNotification(notice(
          <String, dynamic>{'code': 1807, 'starTags': 'slow', 'askResolved': 1}))! as ImDeskRatingRequestedNotification;
      expect(tagsNotAList.starTags, isEmpty);
      expect(tagsNotAList.askResolved, isFalse, reason: 'only the JSON true is true, not 1');
    });

    test('leaves an ordinary chat message alone', () {
      // The reason this matters: desk notices travel down the same `messages` stream as chat, so the
      // handler asks this first and falls through. A reader keyed on `code` alone would eventually
      // hit a tenant's own notification and draw a support line into the wrong conversation.
      final ImMessage chat = notice(
        <String, dynamic>{'code': 1801, 'text': 'hello'},
        contentType: ImMessageContentType.text,
      );
      expect(readDeskNotification(chat), isNull,
          reason: 'the code is right but the content type is not a notification');
      expect(readDeskNotification(notice(<String, dynamic>{'text': 'hello'})), isNull,
          reason: 'a notification with no code is not a desk notice');
      expect(readDeskNotification(null), isNull);
    });

    test('refuses the account error codes that share these seven numbers', () {
      // 1801 is `AccountLocked` on the server's own error table and 1804 is `PasswordTooWeak`. They
      // never appear in `message.content`, and this is the assertion that keeps the two tables apart:
      // a code outside the band is not a desk notice however plausible it looks.
      // 1801 在服务端错误码表里是「账号已锁定」。这条断言守住的就是「两张表不能合并」。
      for (final int code in <int>[1800, 1808, 1500]) {
        expect(
          readDeskNotification(
              notice(<String, dynamic>{'code': code, 'sessionId': 'ds_1', 'customerId': 'v_1'})),
          isNull,
          reason: '$code',
        );
      }
      // And a code that is not a whole number is no code.
      for (final Object? code in <Object?>[
        '18o1',
        true,
        null,
        1801.5,
        '1806.5',
        'NaN',
        <String, dynamic>{'value': 1801},
        <dynamic>[1801],
      ]) {
        expect(readDeskNotification(notice(<String, dynamic>{'code': code})), isNull, reason: '$code');
      }
    });

    test('reads a notice decoded off the wire, and a switch over it needs no default', () {
      final ImMessage message = ImMessage.fromJson(jsonDecode(
        '{"conversationId":"c1","seq":"4","messageId":"350598345233801216","contentType":9,'
        '"senderId":"desk","content":{"code":1802,"sessionId":"ds_1","customerId":"v_1",'
        '"skill":null,"agentId":"a_7"}}',
      ) as Map<String, dynamic>);
      final ImDeskNotification read = readDeskNotification(message)!;

      // Exhaustive without a default: a new subtype is a compile error here, not a silent miss.
      final String sentence = switch (read) {
        ImDeskQueuedNotification() => 'queued',
        ImDeskAssignedNotification(:final String? agentId) => 'with $agentId',
        ImDeskTransferredNotification() => 'transferred',
        ImDeskClosedNotification() => 'closed',
        ImDeskRequeuedNotification() => 'requeued',
        ImDeskAbandonedNotification() => 'abandoned',
        ImDeskRatingRequestedNotification() => 'rate',
      };
      expect(sentence, 'with a_7');
    });

    // The constants are held to TypeScript's, where they were first written down: a key spelled
    // differently here is a context value the engine silently fails to copy out.
    test("ImDeskContextKeys and ImDeskNotificationCode are TypeScript's, name for name", () {
      List<String> block(String path, String start) {
        final String text = sdkFile(path).readAsStringSync();
        final int from = text.indexOf(start);
        expect(from, greaterThanOrEqualTo(0), reason: '$start is not in $path');
        return const LineSplitter()
            .convert(text.substring(from))
            .skip(1)
            .takeWhile((String line) => !line.trimLeft().startsWith('}'))
            .toList();
      }

      String dartName(String name) => name[0].toLowerCase() + name.substring(1);

      final Map<String, String> tsKeys = <String, String>{
        for (final String line in block('typescript/src/desk.ts', 'export const DeskContextKeys = {'))
          if (RegExp(r"^\s*(\w+): '([^']*)',\s*$").firstMatch(line) case final RegExpMatch match)
            dartName(match.group(1)!): match.group(2)!,
      };
      final Map<String, int> tsCodes = <String, int>{
        for (final String line
            in block('typescript/src/protocol.ts', 'export const DeskNotificationCode = {'))
          if (RegExp(r'^\s*(\w+): (\d+),\s*$').firstMatch(line) case final RegExpMatch match)
            dartName(match.group(1)!): int.parse(match.group(2)!),
      };

      expect(tsKeys, hasLength(9), reason: "parsed TypeScript's DeskContextKeys: $tsKeys");
      expect(<String, String>{
        'channel': ImDeskContextKeys.channel,
        'visitorId': ImDeskContextKeys.visitorId,
        'deskId': ImDeskContextKeys.deskId,
        'groupId': ImDeskContextKeys.groupId,
        'origin': ImDeskContextKeys.origin,
        'originBot': ImDeskContextKeys.originBot,
        'page': ImDeskContextKeys.page,
        'visitorName': ImDeskContextKeys.visitorName,
        'visitorEmail': ImDeskContextKeys.visitorEmail,
      }, tsKeys);

      expect(tsCodes, hasLength(7), reason: "parsed TypeScript's DeskNotificationCode: $tsCodes");
      expect(<String, int>{
        'queued': ImDeskNotificationCode.queued,
        'assigned': ImDeskNotificationCode.assigned,
        'transferred': ImDeskNotificationCode.transferred,
        'closed': ImDeskNotificationCode.closed,
        'requeued': ImDeskNotificationCode.requeued,
        'abandoned': ImDeskNotificationCode.abandoned,
        'ratingRequested': ImDeskNotificationCode.ratingRequested,
      }, tsCodes);
      expect(tsCodes.values.toList()..sort(), <int>[for (int code = 1801; code <= 1807; code++) code]);
    });
  });

  // The decoding tests above are only as wide as their fixtures: a member a fixture leaves out decodes
  // to its default whatever key fromJson reads it from. So the full fixtures carry every member the
  // server's type declares, held here to endpoint-inventory.json's payloadTypes.
  test('the full fixtures carry every member the server declares', () {
    final Map<String, dynamic> types = inventory()['payloadTypes'] as Map<String, dynamic>;
    Set<String> members(String type) => <String>{
          for (final dynamic property
              in (types[type] as Map<String, dynamic>)['properties'] as List<dynamic>)
            (property as Map<String, dynamic>)['name'] as String,
        };

    expect(session(full: true).keys.toSet(), members('DeskSession'));
    expect(queueView(measured: true).keys.toSet(), members('DeskQueueView'));
    expect(cannedRow.keys.toSet(), members('DeskCannedReply'));
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

/// A file of the SDK repository, by its path from the root (where `endpoint-inventory.json` is).
File sdkFile(String path) {
  Directory directory = Directory.current.absolute;
  for (int hop = 0; hop < 8; hop++) {
    if (File('${directory.path}/endpoint-inventory.json').existsSync()) {
      return File('${directory.path}/$path');
    }
    directory = directory.parent;
  }
  fail('could not locate the SDK repository root from ${Directory.current.path}');
}
