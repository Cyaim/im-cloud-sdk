// Every request field this package sends, judged by JSON kind against the server's C# type.
//
// The server's socket binder does not go through the JSON options the rest of the platform uses.
// It reads each top-level property of the request DTO itself — `JsonNode.GetValue<T>()` for the
// primitive types, an options-less `Deserialize` for everything else — so a field of the wrong JSON
// kind is never coerced: a number for a C# `string`, a quoted number for a `long`, an enum by name,
// `2.0` for an `int`, `"true"` for a `bool` — each one throws, and the call comes back status 1 /
// code 1000 with nothing to say which field. Four of the five SDKs shipped at least one such field
// (message ids as JSON numbers in Kotlin, Swift and Unity), and every suite involved was green,
// because each asserted what its own SDK sent rather than what the server binds.
//
// So this file does not restate the SDK's intentions. It calls every typed method with every field
// populated, takes the body from the frame the client actually wrote, and judges each value against
// the C# type `endpoint-inventory.json` records for it — which is generated from the server source.
// A new server field, a changed server type, or a new typed endpoint turns it red until the SDK
// follows.
//
// What it does not judge: nested member-name casing. Nested request objects (`conv.setting`'s
// `setting`, `msg.send`'s `options`, `group.update`'s `update`) are matched against the inventory's
// camelCase names; whether the server binds those names is the server's half and is fixed and
// guarded there (IM.Server/tests/IM.Tests.Unit).
//
// 服务端套接字绑定器不走平台的 JSON 选项：字段的 JSON 类型不对不会被转换，而是直接抛、回一个
// 说不出是哪个字段的 1000。这里调用每一个类型化方法、把每个字段都填上，从客户端真正写出的帧里取请求体，
// 再按 endpoint-inventory.json（由服务端源码生成）记录的 C# 类型逐字段判 JSON 类型。

import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A real snowflake: above 2^53 and odd, so any trip through a double changes its last digit.
const String snowflake = '360381357961969667';

/// Server fields this package never sends, each with the reason. An entry must name a real server
/// field and must stay absent from every body; the list is expected to shrink, not grow.
const Map<String, Map<String, String>> omitted = <String, Map<String, String>>{
  'msg.recall': <String, String>{
    'asAdmin': 'forced false by MsgController.Recall for every client call; admin recall is a '
        'server-API capability, so the typed request has no field for it',
  },
};

const String _roomAddress = 'room.send: the room is the address — RoomService stamps r_<roomId> '
    'and type 3 whatever the body says, so ImRoomMessage has no member for it';
const String _roomUnstored = 'room.send: a room message is never stored, so there is nothing to '
    'quote or thread under; RoomService never reads it';
const String _roomOptions = 'room.send: RoomService reads only options.priority and stamps '
    'online-only, unstored options itself; ImRoomMessage carries the priority alone';

/// Members of a type nested in a request body that this package deliberately never sends, keyed
/// by target and then by path. Today only `room.send`'s `message`: [ImRoomMessage] is the subset of
/// `SendMessageRequest` a room reads, as in the TypeScript and Kotlin SDKs.
///
/// Kept apart from [omitted] because it is not recorded into `wire-samples/flutter.json`: the
/// platform's judge keys omissions by type (`SendMessageRequest.groupId`), and `msg.send` sends
/// every one of these members of that same type. Every entry must name a real nested member and
/// must stay absent from every body, exactly like [omitted].
/// 嵌套类型里刻意不发的成员，按 target 与路径列出；不写进录制文件（平台的判定按类型记省略，
/// 而 msg.send 发送了同一类型的这些成员）。
const Map<String, Map<String, String>> nestedOmitted = <String, Map<String, String>>{
  'room.send': <String, String>{
    'message.conversationId': _roomAddress,
    'message.receiverId': _roomAddress,
    'message.groupId': _roomAddress,
    'message.conversationType': _roomAddress,
    'message.quoteMessageId': _roomUnstored,
    'message.threadRootId': _roomUnstored,
    'message.options.persistent': _roomOptions,
    'message.options.updateConversation': _roomOptions,
    'message.options.countUnread': _roomOptions,
    'message.options.offlinePush': _roomOptions,
    'message.options.pushConfig': _roomOptions,
    'message.options.needReceipt': _roomOptions,
    'message.options.onlineOnly': _roomOptions,
    'message.options.noSelfSync': _roomOptions,
    'message.options.expireIn': _roomOptions,
    'message.options.moderationBypass': _roomOptions,
  },
};

/// Fields where the inventory's type is known to be behind the server, each keyed by the one C#
/// type it excuses. An entry is inert as soon as the inventory records anything else, so it cannot
/// hide a later regression, and the test fails once it is inert: otherwise an excuse outlives its
/// reason silently. Empty since 2026-09-21, when the `moderation.report messageId` entry
/// (`long` -> `string?`) was deleted in the same change that regenerated the inventory.
const Map<String, Map<String, String>> serverCatchingUp = <String, Map<String, String>>{};

// ---------------------------------------------------------------------------- the recipes

/// Every typed call path that builds a request body, per target: the namespace method with every
/// field populated with a non-default value, plus each overload and deprecated wrapper that builds
/// its own body. Parameterless endpoints are listed too — their body must be empty.
Map<String, List<Future<void> Function(ImClient im)>> recipes() {
  const ImMessageOptions options = ImMessageOptions(
    persistent: false,
    updateConversation: false,
    countUnread: false,
    offlinePush: false,
    pushConfig: ImPushConfig(
      title: 'New message',
      body: 'Bob: invoice',
      sound: 'chime',
      payload: <String, String>{'route': '/chat/g_wire'},
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

  ImSendMessageRequest send({String? conversationId, String? receiverId, String? groupId}) =>
      ImSendMessageRequest(
        conversationId: conversationId,
        receiverId: receiverId,
        groupId: groupId,
        conversationType: ImConversationType.group,
        contentType: ImMessageContentType.image,
        content: <String, dynamic>{'objectKey': 'o/1.png', 'width': 640},
        clientMsgId: 'cm-wire',
        mentionAll: true,
        mentionedUserIds: <String>['bob', 'carol'],
        quoteMessageId: snowflake,
        threadRootId: snowflake,
        options: options,
        sendTime: 1758412800000,
        extensions: <String, dynamic>{'origin': 'wire'},
      );

  const ImConversationMessageRequest one =
      ImConversationMessageRequest(conversationId: 'g_wire', messageId: snowflake);
  const ImConversationIdRequest conversation = ImConversationIdRequest(conversationId: 'g_wire');
  const ImUserIdRequest user = ImUserIdRequest(userId: 'bob');
  const ImUserIdsRequest users = ImUserIdsRequest(userIds: <String>['bob', 'carol']);
  const ImCursorRequest page = ImCursorRequest(cursor: 'p2', limit: 100);
  const ImGroupIdRequest group = ImGroupIdRequest(groupId: 'team');
  const ImGroupCursorRequest groupPage =
      ImGroupCursorRequest(groupId: 'team', cursor: 'p2', limit: 100);
  const ImGroupMembersRequest members =
      ImGroupMembersRequest(groupId: 'team', userIds: <String>['bob', 'carol'], reason: 'wire');
  const ImStreamHandle stream = ImStreamHandle(streamId: 'st_wire', conversationId: 's_alice_bob');

  return <String, List<Future<void> Function(ImClient im)>>{
    // conn
    'conn.heartbeat': <Future<void> Function(ImClient)>[(ImClient im) => im.conn.heartbeat()],
    'conn.reauth': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conn.reauth(const ImReauthRequest(token: 'token-2')),
    ],
    'conn.sync': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conn.sync(const ImResumeRequest(
            convSeqs: <String, int>{'g_wire': 41, 'c_wire': 7},
            conversationCursor: 1758412800000,
            cursor: 'p2',
            limit: 150,
          )),
    ],

    // msg
    'msg.send': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.send(send(conversationId: 'g_wire')),
      (ImClient im) => im.msg.send(send(receiverId: 'bob')),
      (ImClient im) => im.msg.send(send(groupId: 'team')),
      (ImClient im) => im.sendRequest(ImSendMessageRequest.text(
            'hello',
            conversationId: 'g_wire',
            clientMsgId: 'cm-text',
            mentionedUserIds: <String>['bob'],
            mentionAll: true,
            quoteMessageId: snowflake,
            options: options,
          )),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.send(
            receiverId: 'bob',
            contentType: ImMessageContentType.file,
            content: <String, dynamic>{'objectKey': 'o/a.pdf'},
            clientMsgId: 'cm-old',
            mentionedUserIds: <String>['bob'],
            mentionAll: true,
            quoteMessageId: snowflake,
            // The deprecated wrapper takes the options as a map and round-trips it through
            // ImMessageOptions.fromJson — a transform of its own, so it is judged on its own.
            messageOptions: <String, dynamic>{'priority': 2, 'expireIn': 5000, 'needReceipt': true},
          ),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.sendText(groupId: 'team', text: 'hi'),
    ],
    'msg.sync': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.sync(const ImSyncMessagesRequest(
            conversationId: 'g_wire',
            fromSeq: 3,
            toSeq: 9,
            limit: 100,
            ascending: false,
          )),
    ],
    'msg.history': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg
          .history(const ImHistoryRequest(conversationId: 'g_wire', beforeSeq: 41, limit: 30)),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.history('g_wire', beforeSeq: 41, limit: 30),
    ],
    'msg.recall': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.recall(const ImRecallMessageRequest(
            conversationId: 'g_wire',
            messageId: snowflake,
            reason: 'wire',
          )),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.recall('g_wire', snowflake, reason: 'wire'),
    ],
    'msg.delete': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.delete(const ImDeleteMessagesRequest(
            conversationId: 'g_wire',
            messageIds: <String>[snowflake, '7'],
            forEveryone: true,
          )),
    ],
    'msg.typing': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.msg.typing(const ImTypingRequest(conversationId: 'g_wire', typing: false)),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.setTyping('g_wire', typing: false),
    ],
    'msg.edit': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.edit(const ImEditMessageRequest(
            conversationId: 'g_wire',
            messageId: snowflake,
            content: <String, dynamic>{'text': 'edited'},
          )),
    ],
    'msg.forward': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.forward(ImForwardMessagesRequest(
            sourceConversationId: 'g_wire',
            messageIds: <String>[snowflake, '7'],
            targetConversationIds: <String>['c_wire', 'team'],
            merge: true,
            mergeTitle: 'Chat history',
            clientMsgId: 'fw-wire',
          )),
    ],
    'msg.react': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.react(const ImReactRequest(
            conversationId: 'g_wire',
            messageId: snowflake,
            emoji: '👍',
            add: false,
          )),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.react('g_wire', snowflake, '👍', add: false),
    ],
    'msg.receipt': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.receipt(
          const ImReceiptRequest(conversationId: 'g_wire', messageIds: <String>[snowflake, '7'])),
    ],
    'msg.pin': <Future<void> Function(ImClient)>[(ImClient im) => im.msg.pin(one)],
    'msg.unpin': <Future<void> Function(ImClient)>[(ImClient im) => im.msg.unpin(one)],
    'msg.pins': <Future<void> Function(ImClient)>[(ImClient im) => im.msg.pins(conversation)],
    'msg.favourite': <Future<void> Function(ImClient)>[(ImClient im) => im.msg.favourite(one)],
    'msg.unfavourite': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.unfavourite(one),
    ],
    'msg.favourites': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.favourites(const ImPageRequest(cursor: 'fav-2', limit: 50)),
      (ImClient im) => im.msg.favourites(),
    ],
    'msg.burn': <Future<void> Function(ImClient)>[(ImClient im) => im.msg.burn(one)],
    'msg.search': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.search(const ImSearchMessagesRequest(
            keyword: 'invoice',
            conversationId: 'g_wire',
            contentTypes: <ImMessageContentType>[
              ImMessageContentType.text,
              ImMessageContentType.custom,
            ],
            senderId: 'bob',
            startTime: 1758412000000,
            endTime: 1758412800000,
            cursor: 's2',
            limit: 50,
          )),
    ],
    'msg.receiptDetail': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.receiptDetail(
          const ImReceiptDetailRequest(conversationId: 'g_wire', messageId: snowflake)),
    ],

    // conv
    'conv.list': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conv.list(const ImListConversationsRequest(
            updatedAfter: 1758412800000,
            cursor: 'cv2',
            limit: 100,
          )),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.conversations(updatedAfter: 1758412800000, cursor: 'cv2', limit: 100),
    ],
    'conv.get': <Future<void> Function(ImClient)>[(ImClient im) => im.conv.get(conversation)],
    'conv.read': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conv.read(const ImReadRequest(conversationId: 'g_wire', readSeq: 41)),
      // ignore: deprecated_member_use_from_same_package
      (ImClient im) => im.markRead('g_wire', 41),
    ],
    'conv.unreadTotal': <Future<void> Function(ImClient)>[(ImClient im) => im.conv.unreadTotal()],
    'conv.setting': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conv.setting(const ImUpdateConversationSettingRequest(
            conversationId: 'g_wire',
            setting: ImConversationSetting(
              pinned: true,
              muted: ImMuteMode.silent,
              draft: 'half a thought',
              tags: <String>['work'],
              extensions: <String, dynamic>{'color': 'red'},
            ),
          )),
    ],
    'conv.delete': <Future<void> Function(ImClient)>[(ImClient im) => im.conv.delete(conversation)],
    'conv.clear': <Future<void> Function(ImClient)>[(ImClient im) => im.conv.clear(conversation)],
    'conv.markUnread': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.conv.markUnread(const ImMarkUnreadRequest(conversationId: 'g_wire', unread: false)),
    ],

    // user
    'user.me': <Future<void> Function(ImClient)>[(ImClient im) => im.user.me()],
    'user.profile': <Future<void> Function(ImClient)>[(ImClient im) => im.user.profile(user)],
    'user.batchProfile': <Future<void> Function(ImClient)>[
      (ImClient im) => im.user.batchProfile(users),
    ],
    'user.updateProfile': <Future<void> Function(ImClient)>[
      (ImClient im) => im.user.updateProfile(
          const ImUpdateProfileRequest(patch: <String, dynamic>{'nickname': 'Al', 'age': 30})),
    ],
    'user.presence': <Future<void> Function(ImClient)>[(ImClient im) => im.user.presence(users)],
    'user.subscribePresence': <Future<void> Function(ImClient)>[
      (ImClient im) => im.user.subscribePresence(
          const ImSubscribePresenceRequest(userIds: <String>['bob', 'carol'], ttlSeconds: 300)),
    ],
    'user.unsubscribePresence': <Future<void> Function(ImClient)>[
      (ImClient im) => im.user.unsubscribePresence(users),
    ],
    'user.setStatus': <Future<void> Function(ImClient)>[
      (ImClient im) => im.user.setStatus(const ImSetStatusRequest(status: 'in a meeting')),
    ],

    // friend
    'friend.list': <Future<void> Function(ImClient)>[(ImClient im) => im.friend.list(page)],
    'friend.add': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.friend.add(const ImAddFriendRequest(userId: 'bob', greeting: 'hi', source: 'qrcode')),
    ],
    'friend.handleRequest': <Future<void> Function(ImClient)>[
      (ImClient im) => im.friend.handleRequest(
          const ImHandleFriendRequest(fromUserId: 'bob', accept: true, reason: 'welcome')),
    ],
    'friend.requestList': <Future<void> Function(ImClient)>[
      (ImClient im) => im.friend
          .requestList(const ImFriendRequestListRequest(incoming: false, cursor: 'r2', limit: 100)),
    ],
    'friend.delete': <Future<void> Function(ImClient)>[(ImClient im) => im.friend.delete(user)],
    'friend.blockList': <Future<void> Function(ImClient)>[
      (ImClient im) => im.friend.blockList(page),
    ],
    'friend.block': <Future<void> Function(ImClient)>[
      (ImClient im) => im.friend.block(const ImBlockRequest(userId: 'bob', reason: 'spam')),
    ],
    'friend.unblock': <Future<void> Function(ImClient)>[(ImClient im) => im.friend.unblock(user)],
    'friend.setRemark': <Future<void> Function(ImClient)>[
      (ImClient im) => im.friend.setRemark(
          const ImSetRemarkRequest(userId: 'bob', remark: 'Bob (work)', tags: <String>['work'])),
    ],

    // group
    'group.create': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.create(const ImCreateGroupRequest(
            name: 'Team',
            groupId: 'team',
            avatar: 'https://cdn.test/a.png',
            introduction: 'wire',
            type: ImGroupType.superGroup,
            memberIds: <String>['bob', 'carol'],
            joinMode: ImGroupJoinMode.needApproval,
            inviteMode: ImGroupInviteMode.adminsOnly,
            maxMemberCount: 500,
            extensions: <String, dynamic>{'dept': 'ops'},
          )),
    ],
    'group.info': <Future<void> Function(ImClient)>[(ImClient im) => im.group.info(group)],
    'group.update': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.update(const ImUpdateGroupCommand(
            groupId: 'team',
            update: ImUpdateGroupRequest(
              name: 'Team 2',
              avatar: 'https://cdn.test/b.png',
              introduction: 'renamed',
              joinMode: ImGroupJoinMode.forbidden,
              inviteMode: ImGroupInviteMode.forbidden,
              maxMemberCount: 200,
              extensions: <String, dynamic>{'dept': 'eng'},
            ),
          )),
    ],
    'group.dismiss': <Future<void> Function(ImClient)>[(ImClient im) => im.group.dismiss(group)],
    'group.memberList': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.memberList(groupPage),
    ],
    'group.joined': <Future<void> Function(ImClient)>[(ImClient im) => im.group.joined(page)],
    'group.invite': <Future<void> Function(ImClient)>[(ImClient im) => im.group.invite(members)],
    'group.kick': <Future<void> Function(ImClient)>[(ImClient im) => im.group.kick(members)],
    'group.quit': <Future<void> Function(ImClient)>[(ImClient im) => im.group.quit(group)],
    'group.join': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.join(const ImJoinGroupRequest(groupId: 'team', reason: 'hi')),
    ],
    'group.transfer': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.group.transfer(const ImTransferOwnerRequest(groupId: 'team', newOwnerId: 'bob')),
    ],
    'group.applicationList': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.applicationList(groupPage),
      (ImClient im) => im.group.applicationList(),
    ],
    'group.handleApplication': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.handleApplication(const ImHandleApplicationRequest(
            groupId: 'team',
            applicantId: 'bob',
            accept: true,
            reason: 'welcome',
          )),
    ],
    'group.setRole': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group
          .setRole(const ImSetRoleRequest(groupId: 'team', userId: 'bob', role: ImGroupRole.admin)),
    ],
    'group.mute': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group
          .mute(const ImMuteGroupRequest(groupId: 'team', mute: false, untilMs: 1758412800000)),
    ],
    'group.muteMember': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.muteMember(
          const ImMuteMemberRequest(groupId: 'team', userId: 'bob', untilMs: 1758412800000)),
    ],
    'group.setNickname': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.setNickname(
          const ImSetGroupNicknameRequest(groupId: 'team', userId: 'bob', nickname: 'Bobby')),
    ],
    'group.announcement': <Future<void> Function(ImClient)>[
      (ImClient im) => im.group.announcement(
          const ImAnnouncementRequest(groupId: 'team', announcement: 'Standup at ten')),
    ],

    // media — a size past 2^32 so a 32-bit or floating path would show
    'media.uploadTicket': <Future<void> Function(ImClient)>[
      (ImClient im) => im.media.uploadTicket(const ImUploadTicketRequest(
            fileName: 'a.mp4',
            contentType: 'video/mp4',
            size: 5000000001,
          )),
    ],
    'media.downloadUrl': <Future<void> Function(ImClient)>[
      (ImClient im) => im.media
          .downloadUrl(const ImDownloadUrlRequest(objectKey: 'o/a.mp4', lifetimeSeconds: 600)),
    ],

    // push
    'push.register': <Future<void> Function(ImClient)>[
      (ImClient im) => im.push.register(const ImRegisterPushTokenRequest(
            provider: ImPushProvider.fcm,
            token: 'fcm-token',
            language: 'zh-Hans-CN',
          )),
      (ImClient im) => im.push.setToken(ImPushProvider.huawei, 'hms-token', language: 'en'),
    ],
    'push.unregister': <Future<void> Function(ImClient)>[(ImClient im) => im.push.unregister()],
    'push.clicked': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.push.clicked(const ImPushClickedRequest(pushId: 'pu_1', messageId: snowflake)),
      (ImClient im) => im.push.clicked(),
    ],

    // moderation
    'moderation.report': <Future<void> Function(ImClient)>[
      (ImClient im) => im.moderation.report(const ImSubmitReportRequest(
            targetUserId: 'bob',
            conversationId: 'g_wire',
            messageId: snowflake,
            category: ImReportCategory.spam,
            note: 'wire',
          )),
    ],

    // diag
    'diag.logRequests': <Future<void> Function(ImClient)>[(ImClient im) => im.diag.logRequests()],
    'diag.logUploaded': <Future<void> Function(ImClient)>[
      (ImClient im) => im.diag.logUploaded(const ImDeviceLogAnswer(
            requestId: 'lr_1',
            uploaded: true,
            sizeBytes: 5000000001,
            coveredFromMs: 1758412000000,
            isVolatile: true,
            detail: 'wire',
          )),
    ],

    // desk (T4) — the three transfer paths together send every member of the server's DTO, which
    // no single body may: the server answers two targets at once with 1001.
    'desk.request': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.request(const ImDeskRequest(
            skill: 'billing',
            priority: 2,
            context: <String, Object?>{'desk.channel': 'app'},
          )),
      (ImClient im) => im.desk.request(),
    ],
    'desk.accept': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.accept(const ImDeskAcceptRequest(sessionId: 'ds_1')),
      (ImClient im) => im.desk.accept(),
    ],
    'desk.transfer': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.transfer(
          const ImDeskTransferRequest.agent(sessionId: 'ds_1', agentId: 'a_7', note: 'wire')),
      (ImClient im) =>
          im.desk.transfer(const ImDeskTransferRequest.skill(sessionId: 'ds_1', skill: 'billing')),
      (ImClient im) => im.desk.transfer(const ImDeskTransferRequest.queue(sessionId: 'ds_1')),
    ],
    'desk.close': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.close(const ImDeskCloseRequest(
            sessionId: 'ds_1',
            resolution: 'refunded',
            tags: <String>['billing/refund'],
            disposition: ImDeskDisposition.toLead,
            summary: 'wire',
            inviteRating: false,
          )),
    ],
    'desk.status': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.desk.status(const ImDeskStatusRequest(status: ImAgentStatus.busy, maxConcurrent: 4)),
    ],
    'desk.queue': <Future<void> Function(ImClient)>[(ImClient im) => im.desk.queue()],
    'desk.rate': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.rate(const ImDeskRateRequest(
            sessionId: 'ds_1',
            score: 2,
            resolved: false,
            starTags: <String>['slow'],
            comment: 'wire',
          )),
    ],
    'desk.suggest': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.suggest(const ImDeskSuggestRequest(sessionId: 'ds_1')),
    ],
    'desk.canned': <Future<void> Function(ImClient)>[
      (ImClient im) => im.desk.canned(const ImDeskCannedRequest(
            skill: 'billing',
            scope: ImDeskCannedReplyScope.personal,
            ownerMemberId: 'm_1',
          )),
      (ImClient im) => im.desk.canned(),
    ],

    // room (T4) — `room.send` nests an ImRoomMessage, the subset of SendMessageRequest a room reads;
    // the members it never sends are in `nestedOmitted` with the reason.
    // room.send 嵌套的是 ImRoomMessage（房间实际读取的子集），不发的成员列在 nestedOmitted 里。
    'room.join': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.join(const ImRoomIdRequest(roomId: 'live-wire')),
    ],
    'room.quit': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.quit(const ImRoomIdRequest(roomId: 'live-wire')),
    ],
    'room.send': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.send(ImRoomSendRequest(
            roomId: 'live-wire',
            message: ImRoomMessage(
              contentType: ImMessageContentType.image,
              content: <String, dynamic>{'objectKey': 'o/1.png', 'width': 640},
              clientMsgId: 'cm-room-wire',
              mentionAll: true,
              mentionedUserIds: <String>['bob', 'carol'],
              priority: ImMessagePriority.high,
              sendTime: 1758412800000,
              extensions: <String, dynamic>{'origin': 'wire'},
            ),
          )),
      (ImClient im) => im.room.send(ImRoomSendRequest.text(
            'live-wire',
            'gift',
            clientMsgId: 'cm-room-text',
            mentionedUserIds: <String>['host'],
            priority: ImMessagePriority.low,
          )),
    ],
    'room.onlineCount': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.onlineCount(const ImRoomIdRequest(roomId: 'live-wire')),
    ],
    'room.memberList': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.room.memberList(const ImRoomCursorRequest(roomId: 'live-wire', cursor: '1', limit: 100)),
      (ImClient im) => im.room.memberList(const ImRoomCursorRequest(roomId: 'live-wire')),
    ],
    'room.mute': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.mute(
          const ImRoomMuteRequest(roomId: 'live-wire', userId: 'bob', untilMs: 1758412860000)),
      (ImClient im) => im.room.mute(const ImRoomMuteRequest.unmute(roomId: 'live-wire')),
    ],
    'room.kick': <Future<void> Function(ImClient)>[
      (ImClient im) => im.room.kick(const ImRoomKickRequest(roomId: 'live-wire', userId: 'bob')),
    ],

    // msg.stream* (T4) — one row with every member, nested options and options.pushConfig included,
    // and a minimal row; ImStreamWriter builds the append / complete / abort bodies itself, so its
    // call paths are judged too.
    // 流式四条：一行全字段（含嵌套 options 与 options.pushConfig）、一行最小；ImStreamWriter
    // 自己拼 append / complete / abort 的请求体，所以也单独判。
    'msg.streamBegin': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.streamBegin(ImBeginStreamRequest(
            conversationId: 's_alice_bob',
            receiverId: 'bob',
            groupId: 'team',
            clientMsgId: 'cm-stream-wire',
            contentType: ImMessageContentType.custom,
            placeholder: <String, dynamic>{'name': 'Assistant', 'avatar': 'https://cdn.test/a.png'},
            options: options,
            extensions: <String, dynamic>{'model': 'house-7b'},
          )),
      (ImClient im) =>
          im.msg.streamBegin(ImBeginStreamRequest(receiverId: 'bob', clientMsgId: 'cm-stream-min')),
    ],
    'msg.streamAppend': <Future<void> Function(ImClient)>[
      (ImClient im) =>
          im.msg.streamAppend(const ImStreamAppendRequest(streamId: 'st_wire', delta: 'Hel')),
      (ImClient im) => ImStreamWriter(im.msg, stream).append('lo'),
    ],
    'msg.streamComplete': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.streamComplete(const ImCompleteStreamRequest(
            streamId: 'st_wire',
            content: <String, dynamic>{'text': 'Hello, world.'},
            extensions: <String, dynamic>{'tokens': 42},
          )),
      (ImClient im) => im.msg.streamComplete(const ImCompleteStreamRequest(streamId: 'st_wire')),
      (ImClient im) => ImStreamWriter(im.msg, stream).complete(
            content: <String, dynamic>{'text': 'Hello.'},
            extensions: <String, dynamic>{'n': 1},
          ),
    ],
    'msg.streamAbort': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.streamAbort(
          const ImStreamAbortRequest(streamId: 'st_wire', reason: 'the user pressed stop')),
      (ImClient im) => im.msg.streamAbort(const ImStreamAbortRequest(streamId: 'st_wire')),
      (ImClient im) => ImStreamWriter(im.msg, stream).abort('model timed out'),
    ],

    // scheduled messages, folders, translation (T4) — one row with every member and one minimal row
    // per call. msg.schedule is flat (no nested message), so nothing here needs `nestedOmitted`.
    // 定时消息、文件夹、翻译：每条一行全字段、一行最小。msg.schedule 是扁平的，没有嵌套消息。
    'msg.schedule': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.schedule(const ImScheduleRequest(
            sendAt: 1758412812000,
            conversationId: 's_alice_bob',
            receiverId: 'bob',
            groupId: 'team',
            conversationType: ImConversationType.group,
            clientMsgId: 'cm-sched-wire',
            contentType: ImMessageContentType.custom,
            content: <String, dynamic>{'kind': 'reminder', 'text': 'stand-up'},
            mentionAll: true,
            mentionedUserIds: <String>['bob', 'carol'],
            quoteMessageId: snowflake,
            threadRootId: snowflake,
            extensions: <String, dynamic>{'origin': 'wire'},
          )),
      (ImClient im) => im.msg
          .schedule(ImScheduleRequest.text('stand-up', sendAt: 1758412812000, receiverId: 'bob')),
    ],
    'msg.scheduled': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.scheduled(const ImPageRequest(cursor: 'sch-2', limit: 50)),
      (ImClient im) => im.msg.scheduled(),
    ],
    'msg.cancelScheduled': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.cancelScheduled(const ImScheduleIdRequest(scheduleId: 'sch_wire')),
    ],
    'conv.folders': <Future<void> Function(ImClient)>[(ImClient im) => im.conv.folders()],
    'conv.upsertFolder': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conv.upsertFolder(const ImUpsertFolderRequest(
            folderId: 'work',
            name: 'Work',
            order: 3,
            tags: <String>['client', 'urgent'],
            unreadOnly: true,
            types: <ImConversationType>[ImConversationType.single, ImConversationType.group],
          )),
      (ImClient im) => im.conv.upsertFolder(const ImUpsertFolderRequest(name: 'Work')),
    ],
    'conv.deleteFolder': <Future<void> Function(ImClient)>[
      (ImClient im) => im.conv.deleteFolder(const ImFolderIdRequest(folderId: 'work')),
    ],
    'msg.translate': <Future<void> Function(ImClient)>[
      (ImClient im) => im.msg.translate(const ImTranslateRequest(
            conversationId: 's_alice_bob',
            messageIds: <String>[snowflake, '360381357961969669'],
            targetLanguage: 'zh-CN',
            sourceLanguage: 'en',
          )),
      (ImClient im) => im.msg.translate(const ImTranslateRequest(
            conversationId: 's_alice_bob',
            messageIds: <String>[snowflake],
            targetLanguage: 'zh-CN',
          )),
    ],
  };
}

// ---------------------------------------------------------------------------- the inventory

final class Inventory {
  Inventory._(this.requestTypes, this.types, this.enums);

  /// Target → request DTO name (null for a parameterless endpoint), for every target this
  /// package implements.
  final Map<String, String?> requestTypes;

  /// DTO name → property name → C# type as the inventory writes it (`long?`, `List<string>`…).
  final Map<String, Map<String, String>> types;

  /// Enum name → its declared integer values.
  final Map<String, Set<int>> enums;

  static Inventory load() {
    Directory directory = Directory.current.absolute;

    for (int hop = 0; hop < 8; hop++) {
      final File file = File('${directory.path}/endpoint-inventory.json');
      if (file.existsSync()) {
        final Map<String, dynamic> parsed =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

        final Map<String, String?> requestTypes = <String, String?>{};
        for (final Object? raw in parsed['endpoints'] as List<dynamic>) {
          final Map<String, dynamic> endpoint = raw as Map<String, dynamic>;
          final Map<String, dynamic> implemented =
              endpoint['implementedIn'] as Map<String, dynamic>;
          // Every tier, not only T0–T3: a T4 family this package types (desk.*) goes out through the
          // same binder, and is judged by the same rules, as anything in T1.
          if (implemented['flutter'] != true) continue;
          requestTypes[endpoint['target'] as String] = endpoint['requestType'] as String?;
        }

        final Map<String, Map<String, String>> types = <String, Map<String, String>>{
          for (final MapEntry<String, dynamic> type
              in (parsed['payloadTypes'] as Map<String, dynamic>).entries)
            type.key: <String, String>{
              for (final Object? property
                  in (type.value as Map<String, dynamic>)['properties'] as List<dynamic>)
                (property as Map<String, dynamic>)['name'] as String: property['type'] as String,
            },
        };

        final Map<String, Set<int>> enums = <String, Set<int>>{
          for (final MapEntry<String, dynamic> entry
              in (parsed['payloadEnums'] as Map<String, dynamic>).entries)
            entry.key: <int>{
              for (final Object? value in (entry.value as Map<String, dynamic>).values)
                value as int,
            },
        };

        return Inventory._(requestTypes, types, enums);
      }

      if (directory.parent.path == directory.path) break;
      directory = directory.parent;
    }

    throw StateError('could not locate sdk/endpoint-inventory.json from ${Directory.current.path}');
  }
}

// ---------------------------------------------------------------------------- the judge

/// The JSON kind of a decoded value, as [decodeWire] leaves it.
String kindOf(Object? value) => switch (value) {
      null => 'null',
      String() => 'string',
      int() => 'integer',
      WireFloat() => 'float',
      bool() => 'bool',
      List<dynamic>() => 'array',
      Map<String, dynamic>() => 'object',
      _ => '${value.runtimeType}',
    };

/// `Dictionary<string, object?>` → `('Dictionary', ['string', 'object?'])`; null for a plain name.
(String, List<String>)? genericOf(String type) {
  final int open = type.indexOf('<');
  if (open < 0 || !type.endsWith('>')) return null;

  final String inner = type.substring(open + 1, type.length - 1);
  final List<String> arguments = <String>[];
  int depth = 0;
  int start = 0;
  for (int i = 0; i < inner.length; i++) {
    final String c = inner[i];
    if (c == '<') {
      depth++;
    } else if (c == '>') {
      depth--;
    } else if (c == ',' && depth == 0) {
      arguments.add(inner.substring(start, i).trim());
      start = i + 1;
    }
  }
  arguments.add(inner.substring(start).trim());
  return (type.substring(0, open), arguments);
}

const Set<String> integerTypes = <String>{'long', 'int', 'short', 'byte', 'ulong', 'uint'};
const Set<String> floatingTypes = <String>{'double', 'float', 'decimal'};
const Set<String> listTypes = <String>{
  'List',
  'IList',
  'IReadOnlyList',
  'ICollection',
  'IReadOnlyCollection',
  'IEnumerable',
  'HashSet',
  'ISet',
};
const Set<String> mapTypes = <String>{'Dictionary', 'IDictionary', 'IReadOnlyDictionary'};

/// Judges one value against the C# type the server binds it to, appending a finding per mismatch
/// and recording in [sent] every property path that carried a non-null value.
void judge(
  Inventory inventory,
  String path,
  Object? value,
  String csType,
  List<String> findings,
  Set<String> sent,
) {
  final bool nullable = csType.endsWith('?');
  final String type = nullable ? csType.substring(0, csType.length - 1) : csType;

  String refused(String expected) =>
      '$path: sent ${kindOf(value)} ${jsonEncode(value is WireFloat ? value.value : value)}; the '
      'server declares $csType and binds only $expected';

  if (value == null) {
    if (!nullable) findings.add(refused('a non-null value'));
    return;
  }
  sent.add(path);

  if (type == 'string') {
    if (value is! String) findings.add(refused('a JSON string'));
    return;
  }
  if (integerTypes.contains(type)) {
    if (value is! int) findings.add(refused('a JSON integer — no quotes, no fraction'));
    return;
  }
  if (floatingTypes.contains(type)) {
    if (value is! int && value is! WireFloat) findings.add(refused('a JSON number'));
    return;
  }
  if (type == 'bool') {
    if (value is! bool) findings.add(refused('true or false'));
    return;
  }
  if (type == 'object' || type == 'JsonElement' || type == 'JsonNode') return;

  final Set<int>? members = inventory.enums[type];
  if (members != null) {
    if (value is! int) {
      findings.add(refused('the enum as a JSON integer — never its name'));
    } else if (!members.contains(value)) {
      findings.add('$path: sent $value, which $type does not declare ($members) — the SDK '
          'constant has drifted from the server enum');
    }
    return;
  }

  if (type.endsWith('[]')) {
    final String element = type.substring(0, type.length - 2);
    if (value is! List<dynamic>) {
      findings.add(refused('a JSON array'));
      return;
    }
    for (int i = 0; i < value.length; i++) {
      judge(inventory, '$path[$i]', value[i], element, findings, <String>{});
    }
    return;
  }

  final (String, List<String>)? generic = genericOf(type);
  if (generic != null) {
    final (String name, List<String> arguments) = generic;
    if (listTypes.contains(name) && arguments.length == 1) {
      if (value is! List<dynamic>) {
        findings.add(refused('a JSON array'));
        return;
      }
      if (value.isEmpty) {
        findings.add('$path: sent an empty array, which proves nothing about $csType — populate '
            'it in the recipe');
      }
      for (int i = 0; i < value.length; i++) {
        judge(inventory, '$path[$i]', value[i], arguments.single, findings, <String>{});
      }
      return;
    }
    if (mapTypes.contains(name) && arguments.length == 2) {
      if (value is! Map<String, dynamic>) {
        findings.add(refused('a JSON object'));
        return;
      }
      if (value.isEmpty) {
        findings.add('$path: sent an empty object, which proves nothing about $csType — populate '
            'it in the recipe');
      }
      for (final MapEntry<String, dynamic> entry in value.entries) {
        judge(inventory, '$path.${entry.key}', entry.value, arguments[1], findings, <String>{});
      }
      return;
    }
  }

  final Map<String, String>? properties = inventory.types[type];
  if (properties != null) {
    if (value is! Map<String, dynamic>) {
      findings.add(refused('a JSON object'));
      return;
    }
    judgeObject(inventory, path, value, type, findings, sent);
    return;
  }

  findings.add('$path: the inventory declares $csType, which this test cannot judge yet — teach '
      'judge() the type rather than skipping the field');
}

/// Judges every key of an object against the DTO [type], recursing into nested DTOs.
void judgeObject(
  Inventory inventory,
  String path,
  Map<String, dynamic> body,
  String type,
  List<String> findings,
  Set<String> sent,
) {
  final Map<String, String> properties = inventory.types[type]!;
  for (final MapEntry<String, dynamic> entry in body.entries) {
    final String at = path.isEmpty ? entry.key : '$path.${entry.key}';
    final String? csType = properties[entry.key];
    if (csType == null) {
      findings.add('$at: $type has no property "${entry.key}" — the server never reads it '
          '(declared: ${properties.keys.join(', ')})');
      continue;
    }
    judge(inventory, at, entry.value, csType, findings, sent);
  }
}

/// Every declared property path of [type] that no call sent and no [omitted] entry explains.
/// Nested DTOs are walked only where they were sent at all.
void requireSent(
  Inventory inventory,
  String target,
  String path,
  String type,
  Set<String> sent,
  List<String> findings,
) {
  for (final MapEntry<String, String> property in inventory.types[type]!.entries) {
    final String at = path.isEmpty ? property.key : '$path.${property.key}';
    if (!sent.contains(at)) {
      if (omitted[target]?.containsKey(at) != true &&
          nestedOmitted[target]?.containsKey(at) != true) {
        findings.add('$target $at (${property.value}): no call path sends it — populate it in the '
            'recipe, or declare it in `omitted` with the reason the SDK never sends it');
      }
      continue;
    }

    final String nested = property.value.endsWith('?')
        ? property.value.substring(0, property.value.length - 1)
        : property.value;
    if (inventory.types.containsKey(nested)) {
      requireSent(inventory, target, at, nested, sent, findings);
    }
  }
}

// ---------------------------------------------------------------------------- the recording

const String recordCommand = 'IM_RECORD_WIRE_SAMPLES=1 dart test test/wire_kind_test.dart (in SDK/flutter)';

const String recordingComment = 'RECORDED by SDK/flutter/test/wire_kind_test.dart from the frames this '
    "package's typed methods put on a fake socket. Do not edit by hand; re-record with $recordCommand. "
    "Judged against the server's real socket binder by "
    'IM.Server/tests/IM.Tests.Unit/SdkWireSampleBindingTests.cs in the platform repository.';

/// Top-level fields the package fills in from the clock or a random source when a caller leaves
/// them out. Their values change every run, so the recording keeps their JSON kind — all the binder
/// decides on — and pins the value.
const Set<String> generatedFields = <String>{'clientMsgId', 'sendTime'};

/// Members holding a nested request whose own [generatedFields] are filled in the same way:
/// `room.send` carries the message `msg.send` sends, one level down.
/// room.send 把 msg.send 的那条消息嵌在 message 里，其中的生成字段同样按类型钉住。
const Set<String> nestedMessageFields = <String>{'message'};

Object? pinned(Object? value) => switch (value) {
      int() => 1758412790000,
      WireFloat() => const WireFloat(0.5),
      String() => 'generated',
      _ => value,
    };

/// [body] with every generated field pinned, at the top level and inside [nestedMessageFields].
Map<String, dynamic> pinGenerated(Map<String, dynamic> body, {bool nested = true}) =>
    <String, dynamic>{
      for (final MapEntry<String, dynamic> field in body.entries)
        field.key: generatedFields.contains(field.key)
            ? pinned(field.value)
            : nested && nestedMessageFields.contains(field.key) && field.value is Map<String, dynamic>
                ? pinGenerated(field.value as Map<String, dynamic>, nested: false)
                : field.value,
    };

/// Compact JSON, with a [WireFloat] written back as the fraction it was on the wire.
String encodeWire(Object? value) =>
    jsonEncode(value, toEncodable: (Object? item) => item is WireFloat ? item.value : item);

/// `SDK/wire-samples/flutter.json`, beside the inventory.
File wireSampleFile() {
  Directory directory = Directory.current.absolute;
  for (int hop = 0; hop < 8; hop++) {
    if (File('${directory.path}/endpoint-inventory.json').existsSync()) {
      return File('${directory.path}/wire-samples/flutter.json');
    }
    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }
  throw StateError('could not locate sdk/endpoint-inventory.json from ${Directory.current.path}');
}

// ---------------------------------------------------------------------------- the tests

void main() {
  final Inventory inventory = Inventory.load();

  test('every target this package implements has a recipe, and no recipe names another', () {
    final Set<String> implemented = inventory.requestTypes.keys.toSet();
    final Set<String> recipeTargets = recipes().keys.toSet();

    expect(implemented.difference(recipeTargets), isEmpty,
        reason: 'a typed endpoint with no recipe is an endpoint whose request kinds nobody judges');
    expect(recipeTargets.difference(implemented), isEmpty,
        reason: 'a recipe for a target the inventory does not list as implemented here');
  });

  test('every request field goes out as the JSON kind of the server\'s C# type', () async {
    final FakeGateway gateway = FakeGateway();
    final ImClient im = await connectedClient(gateway);

    final List<String> findings = <String>[];
    final Map<String, Set<String>> sentByTarget = <String, Set<String>>{};

    for (final MapEntry<String, List<Future<void> Function(ImClient)>> recipe
        in recipes().entries) {
      final String target = recipe.key;
      final String? requestType = inventory.requestTypes[target];
      final Set<String> sent = sentByTarget[target] = <String>{};

      for (int via = 0; via < recipe.value.length; via++) {
        final int before = gateway.requests.length;
        try {
          await recipe.value[via](im);
        } on Object {
          // The fake answers every call with an empty payload, which several decoders reject.
          // Only the frame the client wrote is under test here.
        }

        final List<FakeRequest> frames = gateway.requests
            .skip(before)
            .where((FakeRequest r) => r.target == target)
            .toList(growable: false);
        if (frames.isEmpty) {
          findings.add('$target (call path #$via): put no $target frame on the socket');
          continue;
        }

        final Map<String, dynamic> body = frames.first.body;
        if (requestType == null) {
          if (body.isNotEmpty) {
            findings.add('$target (call path #$via): takes no request, but the body was $body');
          }
          continue;
        }

        final List<String> local = <String>[];
        judgeObject(inventory, '', body, requestType, local, sent);
        for (final String finding in local) {
          // A field whose inventory type is known to lag the server is excused only while the
          // inventory still says exactly that type, and only for the kind the server now binds.
          final String field = finding.substring(0, finding.indexOf(':'));
          final String? lagging = serverCatchingUp[target]?[field];
          if (lagging != null &&
              inventory.types[requestType]![field] == lagging &&
              body[field] is String) {
            continue;
          }
          findings.add('$target (call path #$via) $finding');
        }
      }
    }

    await im.dispose();

    expect(findings, isEmpty,
        reason: 'the socket binder refuses these, and each refusal is status 1 / code 1000 with '
            'nothing to say which field:\n  ${findings.join('\n  ')}');

    // An excuse the inventory no longer needs is deleted, not left to excuse whatever comes next.
    final List<String> stale = <String>[
      for (final MapEntry<String, Map<String, String>> entry in serverCatchingUp.entries)
        for (final MapEntry<String, String> field in entry.value.entries)
          if (inventory.types[inventory.requestTypes[entry.key]]?[field.key] != field.value)
            '${entry.key} ${field.key}: the inventory now records '
                '${inventory.types[inventory.requestTypes[entry.key]]?[field.key]}, not ${field.value}',
    ];
    expect(stale, isEmpty,
        reason: 'delete these serverCatchingUp entries:\n  ${stale.join('\n  ')}');

    // Completeness: a field no call path sends is a field whose kind nobody judged.
    final List<String> unsent = <String>[];
    for (final MapEntry<String, String?> endpoint in inventory.requestTypes.entries) {
      final String? requestType = endpoint.value;
      if (requestType == null) continue;
      requireSent(inventory, endpoint.key, '', requestType,
          sentByTarget[endpoint.key] ?? <String>{}, unsent);
    }
    expect(unsent, isEmpty, reason: unsent.join('\n'));

    // An omission must name a real field and must really be omitted.
    for (final MapEntry<String, Map<String, String>> entry in omitted.entries) {
      final String? requestType = inventory.requestTypes[entry.key];
      expect(requestType, isNotNull,
          reason: '`omitted` names ${entry.key}, which takes no request');
      for (final String field in entry.value.keys) {
        expect(inventory.types[requestType]!.containsKey(field), isTrue,
            reason: '`omitted` names ${entry.key} $field, which $requestType does not declare');
        expect(sentByTarget[entry.key]!.contains(field), isFalse,
            reason: '`omitted` says ${entry.key} never sends $field, and a call path sent it');
      }
    }

    // Likewise a nested omission: its path must walk through the server's types to a real member,
    // and no call path may have sent it.
    for (final MapEntry<String, Map<String, String>> entry in nestedOmitted.entries) {
      final String? requestType = inventory.requestTypes[entry.key];
      expect(requestType, isNotNull,
          reason: '`nestedOmitted` names ${entry.key}, which takes no request');
      for (final String path in entry.value.keys) {
        final List<String> segments = path.split('.');
        expect(segments.length, greaterThan(1),
            reason: '`nestedOmitted` names ${entry.key} $path, which is top-level: use `omitted`');
        String? type = requestType;
        for (final String segment in segments) {
          final String? member = inventory.types[type]?[segment];
          expect(member, isNotNull,
              reason: '`nestedOmitted` names ${entry.key} $path, and $type declares no $segment');
          type = member!.endsWith('?') ? member.substring(0, member.length - 1) : member;
        }
        expect(sentByTarget[entry.key]!.contains(path), isFalse,
            reason: '`nestedOmitted` says ${entry.key} never sends $path, and a call path sent it');
      }
    }
  });

  // The judge above reads endpoint-inventory.json, which records the server's C# type names but not
  // its binder's rules — it could not see, for one, that a nested object is matched
  // case-sensitively. So every body the recipes put on the socket is also written to
  // SDK/wire-samples/flutter.json, and the platform repository binds each one with the server's real
  // socket binder (SdkWireSampleBindingTests). This test keeps that file honest: it fails when what
  // this package sends drifts from what is committed. IM_RECORD_WIRE_SAMPLES=1 rewrites it.
  // 上面的判定对照的是清单（只记类型名、不记绑定器规则）。所有请求体同时落盘到
  // wire-samples/flutter.json，由平台仓用服务端真实的绑定器逐个绑定；这里保证那份文件与实际发送一致。
  test('the recorded wire samples are exactly what this package sends', () async {
    final FakeGateway gateway = FakeGateway();
    final ImClient im = await connectedClient(gateway);
    final List<String> samples = <String>[];

    for (final MapEntry<String, List<Future<void> Function(ImClient)>> recipe
        in recipes().entries) {
      for (int via = 0; via < recipe.value.length; via++) {
        final int before = gateway.requests.length;
        try {
          await recipe.value[via](im);
        } on Object {
          // As above: only the frame the client wrote is under test.
        }

        final FakeRequest? frame = gateway.requests
            .skip(before)
            .where((FakeRequest r) => r.target == recipe.key)
            .firstOrNull;
        if (frame == null) continue; // the kind test above reports a recipe that sent nothing

        final Map<String, dynamic> body = pinGenerated(frame.body);
        samples.add('    {"target":${jsonEncode(recipe.key)},'
            '"type":${jsonEncode(inventory.requestTypes[recipe.key])},'
            '"via":${jsonEncode('${recipe.key} #$via')},"body":${encodeWire(body)}}');
      }
    }

    await im.dispose();

    final String text = <String>[
      '{',
      '  "\$comment": ${jsonEncode(recordingComment)},',
      '  "sdk": "flutter",',
      '  "omitted": {',
      <String>[
        for (final MapEntry<String, Map<String, String>> entry in omitted.entries)
          for (final MapEntry<String, String> field in entry.value.entries)
            '    ${jsonEncode('${inventory.requestTypes[entry.key]}.${field.key}')}: '
                '${jsonEncode(field.value)}',
      ].join(',\n'),
      '  },',
      '  "samples": [',
      samples.join(',\n'),
      '  ]',
      '}',
      '',
    ].join('\n');

    final File file = wireSampleFile();
    if (Platform.environment['IM_RECORD_WIRE_SAMPLES'] == '1') {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
      return;
    }

    expect(file.existsSync(), isTrue,
        reason: '${file.path} is missing; record it with $recordCommand and commit it');
    final List<String> committed =
        file.readAsStringSync().replaceAll('\r\n', '\n').split('\n');
    final List<String> live = text.split('\n');
    final List<String> changed = <String>[
      for (int i = 0; i < (committed.length > live.length ? committed.length : live.length); i++)
        if ((i < committed.length ? committed[i] : null) != (i < live.length ? live[i] : null))
          '  line ${i + 1}\n    committed: ${i < committed.length ? committed[i] : '(none)'}\n'
              '    sent now:  ${i < live.length ? live[i] : '(none)'}',
    ].take(12).toList();
    expect(changed, isEmpty,
        reason: 'what this package sends no longer matches SDK/wire-samples/flutter.json:\n'
            '${changed.join('\n')}\nIf the change is intended, re-record with $recordCommand and '
            'commit the file; the platform repository\'s SdkWireSampleBindingTests will judge it '
            'against the server\'s real binder.');
  });

  test('the judge sees every kind the socket binder refuses', () {
    // Controls, independent of the SDK: each body is one the binder answers with 1000. If the
    // judge accepts any of them it can no longer see the defect it exists for.
    final Map<String, (String, Map<String, dynamic>)> refused =
        <String, (String, Map<String, dynamic>)>{
      'a message id as a JSON number': (
        'RecallMessageRequest',
        <String, dynamic>{'conversationId': 'c', 'messageId': 360381357961969667},
      ),
      'message ids as JSON numbers': (
        'ReceiptRequest',
        <String, dynamic>{
          'conversationId': 'c',
          'messageIds': <dynamic>[360381357961969667],
        },
      ),
      'a long, quoted': (
        'UploadTicketRequest',
        <String, dynamic>{'fileName': 'a', 'contentType': 'b', 'size': '1024'},
      ),
      'an int with a fraction': (
        'ReadRequest',
        <String, dynamic>{'conversationId': 'c', 'readSeq': const WireFloat(41)},
      ),
      'an enum by name': (
        'SetRoleRequest',
        <String, dynamic>{'groupId': 'g', 'userId': 'u', 'role': 'Admin'},
      ),
      'a bool, quoted': (
        'TypingRequest',
        <String, dynamic>{'conversationId': 'c', 'typing': 'true'},
      ),
      'a nested enum by name': (
        'UpdateConversationSettingRequest',
        <String, dynamic>{
          'conversationId': 'c',
          'setting': <String, dynamic>{'muted': 'Silent'},
        },
      ),
      'a misspelled nested key': (
        'UpdateConversationSettingRequest',
        <String, dynamic>{
          'conversationId': 'c',
          'setting': <String, dynamic>{'pinnned': true},
        },
      ),
      'a quoted number inside a dictionary of longs': (
        'ResumeRequest',
        <String, dynamic>{
          'convSeqs': <String, dynamic>{'c': '5'},
        },
      ),
    };

    for (final MapEntry<String, (String, Map<String, dynamic>)> control in refused.entries) {
      final (String type, Map<String, dynamic> body) = control.value;
      expect(inventory.types.containsKey(type), isTrue, reason: '$type left the inventory');

      final List<String> findings = <String>[];
      judgeObject(inventory, '', body, type, findings, <String>{});
      expect(findings, isNotEmpty,
          reason: 'the judge accepted ${control.key} ($type $body); it can no longer see the '
              'defect it exists for');
    }
  });
}
