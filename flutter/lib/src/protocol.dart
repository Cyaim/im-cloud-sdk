/// Wire protocol types. These mirror `docs/SPEC-02-protocol.md` and are the only place in the
/// package where the shape of a frame is described.
///
/// Everything here is immutable and hand-decoded. No code generation: a chat SDK that needs a
/// `build_runner` step before it compiles is a chat SDK that tenants will not adopt, and the
/// envelope is small enough that a hand-written `fromJson` stays readable.
library;

import 'json.dart';
import 'models.dart';

/// A request the client sends.
///
/// [id] is mandatory, not decorative: the socket is multiplexed, so the id is the only thing that
/// lets a reply find the caller waiting for it.
class ImRequest {
  const ImRequest({required this.id, required this.target, this.body});

  final String id;

  /// Endpoint name, `{controller}.{action}`. Matched case-insensitively by the gateway.
  final String target;

  final Object? body;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'target': target,
        'body': body ?? const <String, Object?>{},
      };
}

/// A frame the server sends.
///
/// Replies and server-initiated pushes are structurally identical, which is deliberate: one
/// decoder handles both, and a push can be correlated exactly like a reply.
class ImFrame {
  const ImFrame({
    required this.id,
    required this.target,
    required this.status,
    this.msg,
    this.requestTime,
    this.completeTime,
    this.body,
  });

  /// Decodes an envelope, tolerating either casing of the transport-level keys.
  ///
  /// The gateway is ASP.NET Core and serialises the MVC envelope in PascalCase (`Id`, `Status`,
  /// `Body`) while SPEC-02 §1.1 shows the client sending camelCase; the payload nested under
  /// `Body.data` is always camelCase. Reading PascalCase first with a camelCase fallback is the
  /// same tolerance `cyaim-websocket-client-dart` applies, and it costs one `??` per field.
  ///
  /// 网关按 PascalCase 序列化信封，而规范里客户端请求是小写；两种都认，代价只有一个 `??`。
  factory ImFrame.fromJson(Map<String, dynamic> json) {
    final Object? body = json['Body'] ?? json['body'];
    return ImFrame(
      id: imStringOr(json['Id'] ?? json['id']),
      target: imStringOr(json['Target'] ?? json['target']),
      status: imIntOr(json['Status'] ?? json['status']),
      msg: imString(json['Msg'] ?? json['msg']),
      requestTime: imInt(json['RequestTime'] ?? json['requestTime']),
      completeTime: imInt(json['CompleteTime'] ?? json['completeTime']),
      body: body is Map<String, dynamic> ? ImBody.fromJson(body) : null,
    );
  }

  final String id;
  final String target;

  /// Transport-level outcome: 0 routed, 1 endpoint threw, 2 endpoint not found.
  ///
  /// Distinct from [ImBody.code], which is the business-level outcome. The two are not merged
  /// because "the endpoint does not exist" and "the endpoint ran and refused you" are different
  /// problems with different fixes.
  final int status;

  final String? msg;
  final int? requestTime;
  final int? completeTime;
  final ImBody? body;
}

/// Transport-level outcomes of [ImFrame.status]. Named because two of the three map to error codes
/// that are easy to get wrong — see [ImException.fromFrame].
abstract final class ImFrameStatus {
  /// The gateway routed the request to an endpoint, which ran. Look at [ImBody.code] next.
  static const int routed = 0;

  /// The endpoint threw. [ImFrame.msg] carries whatever the gateway was willing to say.
  static const int endpointThrew = 1;

  /// No such target on this deployment.
  static const int noSuchTarget = 2;
}

/// Business-level result, nested inside the transport frame.
class ImBody {
  const ImBody({
    required this.code,
    this.message,
    this.traceId,
    this.serverTime = 0,
    this.data,
  });

  factory ImBody.fromJson(Map<String, dynamic> json) => ImBody(
        code: imIntOr(json['code'] ?? json['Code']),
        message: imString(json['message'] ?? json['Message']),
        traceId: imString(json['traceId'] ?? json['TraceId']),
        serverTime: imIntOr(json['serverTime'] ?? json['ServerTime']),
        data: json['data'] ?? json['Data'],
      );

  final int code;
  final String? message;

  /// Correlates this result with the server-side log line. Always quote it in a bug report.
  final String? traceId;

  /// Authoritative server clock, unix ms.
  final int serverTime;

  final Object? data;
}

/// Business error codes, from SPEC-02 §4 and `IM.Abstractions.Errors.ImErrorCode`.
///
/// Deliberately plain `int` constants rather than an enum: the server owns this list and will add
/// to it, and an enum would turn every future code into a decode failure on an already-shipped
/// client.
abstract final class ImErrorCode {
  static const int ok = 0;

  // 1000-1099 generic
  static const int internalError = 1000;
  static const int invalidArgument = 1001;
  static const int notFound = 1002;
  static const int rateLimited = 1003;
  static const int timeout = 1004;
  static const int serviceUnavailable = 1005;
  static const int conflict = 1006;
  static const int payloadTooLarge = 1007;

  /// This deployment does not have the endpoint you called — an SDK newer than the server it is
  /// pointed at. Deliberately *not* [notFound]: 1002 means "your group does not exist", 1008 means
  /// "this build of the server has never heard of `group.transfer`", and an integrator debugging a
  /// private deployment needs to be told which.
  static const int unsupportedOperation = 1008;

  /// The SDK raises this locally when a request is issued on a socket that is not open.
  ///
  /// Kept as a distinct name for the same value as [serviceUnavailable] because it is already in
  /// every README and sample. An in-flight request that dies *with* the socket is [timeout], not
  /// this — see [ImException.fromFrame].
  static const int connectionLost = serviceUnavailable;

  // 1100-1199 auth
  static const int unauthorized = 1100;
  static const int tokenExpired = 1101;
  static const int tokenInvalid = 1102;
  static const int forbidden = 1103;
  static const int userBanned = 1104;
  static const int signatureInvalid = 1105;
  static const int replayDetected = 1106;
  static const int kickedByOtherDevice = 1107;

  // 1200-1299 tenant and quota
  static const int appNotFound = 1200;
  static const int appDisabled = 1201;

  /// Tenant billing. Never retry and never bury it: the integrator debugging this needs the code.
  static const int quotaExceeded = 1202;

  /// The tenant has the feature switched off (`EnablePresence`, `EnableTypingIndicator`,
  /// `EnableSearch`, `EnableOfflinePush`) or the module is not deployed.
  ///
  /// **Do not latch this locally.** A tenant can flip a flag at runtime, and a client that
  /// remembers "typing is off" stays broken until the app restarts. Report it every time and keep
  /// calling. One asymmetry to know: `user.presence` checks `EnablePresence`,
  /// `user.subscribePresence` does not — a subscribe against a presence-disabled app succeeds and
  /// then never fires, so do not infer the flag from a successful subscribe.
  /// 不要在本地记住这个码：租户可以随时打开开关，记住它的客户端要等重启才恢复。
  static const int featureNotEnabled = 1203;

  static const int planExpired = 1204;
  static const int concurrencyLimitExceeded = 1205;

  // 1300-1399 user and relationship
  static const int userNotFound = 1300;
  static const int userAlreadyExists = 1301;
  static const int notFriend = 1302;
  static const int blockedByPeer = 1303;
  static const int blockedPeer = 1304;
  static const int friendRequestNotFound = 1305;
  static const int friendLimitExceeded = 1306;
  static const int cannotAddSelf = 1307;

  // 1400-1499 message
  static const int messageNotFound = 1400;
  static const int messageTooLong = 1401;
  static const int moderationRejected = 1402;
  static const int recallWindowExpired = 1403;
  static const int recallForbidden = 1404;
  static const int editWindowExpired = 1405;
  static const int duplicateClientMessageId = 1406;
  static const int conversationNotFound = 1407;
  static const int senderMuted = 1408;
  static const int unsupportedContentType = 1409;
  static const int receiptDisabled = 1410;

  // 1500-1599 group
  static const int groupNotFound = 1500;
  static const int groupDismissed = 1501;
  static const int groupFull = 1502;
  static const int notGroupMember = 1503;
  static const int noGroupPermission = 1504;
  static const int groupMuted = 1505;
  static const int memberMuted = 1506;
  static const int alreadyGroupMember = 1507;
  static const int joinNeedsApproval = 1508;
  static const int joinForbidden = 1509;
  static const int inviteForbidden = 1510;
  static const int cannotOperateOwner = 1511;
  static const int applicationNotFound = 1512;

  // 1600-1699 chat room
  static const int roomNotFound = 1600;
  static const int roomFull = 1601;
  static const int notInRoom = 1602;
  static const int roomMuted = 1603;

  // 1700-1799 media and storage
  static const int uploadFailed = 1700;
  static const int fileTypeNotAllowed = 1701;
  static const int fileTooLarge = 1702;
  static const int storageQuotaExceeded = 1703;

  /// No delivery record matches. The row is kept seven days, or the notification did not come from this platform at all. `clicked` swallows it: a click count one short is not an application's problem, and there is nothing a user could do about it.
  ///
  /// 没有匹配的投递记录：记录只保留七天，或者这条通知根本不是本平台发的。
  static const int pushDeliveryNotFound = 2401;

  /// Whether trying the same call again could plausibly produce a different answer.
  ///
  /// Exactly four codes, and the same four in all five SDKs (`sdk/CONTRACT.md` §7.3). Everything
  /// else is terminal — retrying it produces the same answer, so a retry loop around it is a way
  /// of turning one failure into many.
  ///
  /// **The SDK never acts on this by itself.** It retries the *connection*, and its own internal
  /// `conn.sync` / `msg.sync` repair; every business call surfaces with this flag set and the
  /// application decides. An SDK that silently re-sends on [rateLimited] hides rate limiting from
  /// the UI that has to explain it.
  static bool isRetryable(int code) =>
      code == internalError || code == rateLimited || code == timeout || code == serviceUnavailable;

  /// Whether the session's credentials, rather than the request, were the problem.
  static bool requiresReauth(int code) =>
      code == unauthorized || code == tokenExpired || code == tokenInvalid;
}

/// Server-initiated event names, from SPEC-02 §2.7.
///
/// Strings rather than an enum for the same reason as [ImErrorCode]: you can subscribe with
/// `ImClient.events<T>(target)` to any name the server grows, without waiting for an SDK release.
abstract final class ImPushTarget {
  static const String message = 'evt.message';
  static const String messageUpdate = 'evt.messageUpdate';
  static const String conversationUpdate = 'evt.conversationUpdate';
  static const String read = 'evt.read';
  static const String typing = 'evt.typing';
  static const String presence = 'evt.presence';
  static const String friend = 'evt.friend';
  static const String group = 'evt.group';
  static const String system = 'evt.system';
  static const String stream = 'evt.stream';
  static const String call = 'evt.call';
  static const String desk = 'evt.desk';
  static const String kick = 'conn.kick';
}

// ---------------------------------------------------------------------------- open enums
//
// Every server enum is modelled as an extension type over its wire value rather than as a Dart
// `enum`. The reason is one rule in the JSON policy: **unknown enum values are preserved as their
// raw value, never coerced to a default member.** The server ships new content types, new kick
// reasons and new group roles without waiting for the app, and a closed enum turns each of those
// into either a decode failure or — worse, because it is silent — a message rendered as the wrong
// kind. An extension type costs nothing at runtime (it *is* the int), keeps `==` and `switch`
// working exactly as an enum does, and lets `ImMessageContentType(13)` round-trip through a client
// that has never heard of 13.
//
// 服务端会随时新增枚举值。封闭枚举要么解码失败，要么静默退化成默认成员——后者更糟。
// extension type 在运行期就是那个 int，== 和 switch 照常可用，未知值原样保留。

/// Device platform, reported at handshake time and carried on every message.
///
/// Named `ImPlatform`, not `Platform`, on purpose: `dart:io` already exports a `Platform`, and a
/// Flutter file importing both would not compile. The same reasoning is why every public type in
/// this package carries the `Im` prefix — Dart has no namespaces, so a library's exports land
/// directly in the importing file's scope.
extension type const ImPlatform(int wireValue) {
  static const ImPlatform unknown = ImPlatform(0);
  static const ImPlatform ios = ImPlatform(1);
  static const ImPlatform android = ImPlatform(2);
  static const ImPlatform windows = ImPlatform(3);
  static const ImPlatform macos = ImPlatform(4);
  static const ImPlatform web = ImPlatform(5);
  static const ImPlatform miniProgram = ImPlatform(6);
  static const ImPlatform linux = ImPlatform(7);

  /// `Platform.Server = 100`. A client never sends it; a message relayed by the tenant's own
  /// backend arrives carrying it, and an app that renders a sender badge needs to know.
  static const ImPlatform server = ImPlatform(100);

  static const List<ImPlatform> values = <ImPlatform>[
    unknown,
    ios,
    android,
    windows,
    macos,
    web,
    miniProgram,
    linux,
    server
  ];

  /// Decodes a wire value, keeping an unrecognised one intact.
  static ImPlatform fromWire(Object? value) => ImPlatform(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'unknown',
        1 => 'ios',
        2 => 'android',
        3 => 'windows',
        4 => 'macos',
        5 => 'web',
        6 => 'miniProgram',
        7 => 'linux',
        100 => 'server',
        _ => 'platform($wireValue)',
      };
}

/// Kind of conversation a message belongs to.
extension type const ImConversationType(int wireValue) {
  static const ImConversationType single = ImConversationType(1);
  static const ImConversationType group = ImConversationType(2);
  static const ImConversationType chatRoom = ImConversationType(3);
  static const ImConversationType system = ImConversationType(4);
  static const ImConversationType assistant = ImConversationType(5);

  static const List<ImConversationType> values = <ImConversationType>[
    single,
    group,
    chatRoom,
    system,
    assistant
  ];

  static ImConversationType fromWire(Object? value) => ImConversationType(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        1 => 'single',
        2 => 'group',
        3 => 'chatRoom',
        4 => 'system',
        5 => 'assistant',
        _ => 'conversationType($wireValue)',
      };
}

/// Message payload kind. [custom] is the extension point; `content` is free-form for it.
extension type const ImMessageContentType(int wireValue) {
  static const ImMessageContentType text = ImMessageContentType(1);
  static const ImMessageContentType image = ImMessageContentType(2);
  static const ImMessageContentType voice = ImMessageContentType(3);
  static const ImMessageContentType video = ImMessageContentType(4);
  static const ImMessageContentType file = ImMessageContentType(5);
  static const ImMessageContentType location = ImMessageContentType(6);
  static const ImMessageContentType card = ImMessageContentType(7);
  static const ImMessageContentType merged = ImMessageContentType(8);
  static const ImMessageContentType notification = ImMessageContentType(9);
  static const ImMessageContentType tip = ImMessageContentType(10);
  static const ImMessageContentType recall = ImMessageContentType(11);
  static const ImMessageContentType stream = ImMessageContentType(12);
  static const ImMessageContentType custom = ImMessageContentType(100);

  static const List<ImMessageContentType> values = <ImMessageContentType>[
    text,
    image,
    voice,
    video,
    file,
    location,
    card,
    merged,
    notification,
    tip,
    recall,
    stream,
    custom
  ];

  /// A content type this SDK version does not know keeps its own number, so the app can render it
  /// from a tenant-side registry, forward it intact, or ignore it — instead of seeing it as
  /// [custom] and losing the one field that said what it was.
  static ImMessageContentType fromWire(Object? value) => ImMessageContentType(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        1 => 'text',
        2 => 'image',
        3 => 'voice',
        4 => 'video',
        5 => 'file',
        6 => 'location',
        7 => 'card',
        8 => 'merged',
        9 => 'notification',
        10 => 'tip',
        11 => 'recall',
        12 => 'stream',
        100 => 'custom',
        _ => 'contentType($wireValue)',
      };
}

/// Delivery state the server holds for a message.
extension type const ImMessageStatus(int wireValue) {
  static const ImMessageStatus sending = ImMessageStatus(0);
  static const ImMessageStatus sent = ImMessageStatus(1);
  static const ImMessageStatus delivered = ImMessageStatus(2);
  static const ImMessageStatus read = ImMessageStatus(3);
  static const ImMessageStatus failed = ImMessageStatus(4);

  static const List<ImMessageStatus> values = <ImMessageStatus>[
    sending,
    sent,
    delivered,
    read,
    failed
  ];

  static ImMessageStatus fromWire(Object? value) => ImMessageStatus(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'sending',
        1 => 'sent',
        2 => 'delivered',
        3 => 'read',
        4 => 'failed',
        _ => 'status($wireValue)',
      };
}

/// Queue priority. Low-priority traffic is what the gateway sheds first when a connection is
/// behind.
extension type const ImMessagePriority(int wireValue) {
  static const ImMessagePriority low = ImMessagePriority(0);
  static const ImMessagePriority normal = ImMessagePriority(1);
  static const ImMessagePriority high = ImMessagePriority(2);

  static const List<ImMessagePriority> values = <ImMessagePriority>[low, normal, high];

  static ImMessagePriority fromWire(Object? value) => ImMessagePriority(imIntOr(value, 1));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'low',
        1 => 'normal',
        2 => 'high',
        _ => 'priority($wireValue)',
      };
}

/// Per-conversation do-not-disturb level.
extension type const ImMuteMode(int wireValue) {
  /// Notify normally.
  static const ImMuteMode normal = ImMuteMode(0);

  /// Deliver, count unread, but do not raise an offline push.
  static const ImMuteMode noPush = ImMuteMode(1);

  /// Deliver silently and do not count unread either.
  static const ImMuteMode silent = ImMuteMode(2);

  static const List<ImMuteMode> values = <ImMuteMode>[normal, noPush, silent];

  static ImMuteMode fromWire(Object? value) => ImMuteMode(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'normal',
        1 => 'noPush',
        2 => 'silent',
        _ => 'muteMode($wireValue)',
      };
}

/// Recall metadata, present only on a message that has been withdrawn.
class ImRecallInfo {
  const ImRecallInfo({
    required this.operatorId,
    required this.recallTime,
    required this.byAdmin,
    this.reason,
  });

  factory ImRecallInfo.fromJson(Map<String, dynamic> json) => ImRecallInfo(
        operatorId: imStringOr(json['operatorId']),
        recallTime: imIntOr(json['recallTime']),
        byAdmin: imBool(json['byAdmin']),
        reason: imString(json['reason']),
      );

  final String operatorId;
  final int recallTime;
  final bool byAdmin;
  final String? reason;
}

/// Edit metadata. [version] increments per edit, so a late-arriving edit can be discarded.
class ImEditInfo {
  const ImEditInfo({
    required this.operatorId,
    required this.editTime,
    required this.version,
  });

  factory ImEditInfo.fromJson(Map<String, dynamic> json) => ImEditInfo(
        operatorId: imStringOr(json['operatorId']),
        editTime: imIntOr(json['editTime']),
        version: imIntOr(json['version']),
      );

  final String operatorId;
  final int editTime;
  final int version;
}

/// One message in a conversation. The server's `Message`.
class ImMessage {
  const ImMessage({
    required this.appId,
    required this.conversationId,
    required this.conversationType,
    required this.seq,
    required this.messageId,
    required this.clientMsgId,
    required this.senderId,
    required this.senderPlatform,
    required this.contentType,
    required this.content,
    required this.sendTime,
    required this.createTime,
    this.searchText,
    this.mentionAll = false,
    this.mentionedUserIds = const <String>[],
    this.quoteMessageId,
    this.threadRootId,
    this.options = const ImMessageOptions(),
    this.status = ImMessageStatus.sent,
    this.reactions = const <String, List<String>>{},
    this.recalled,
    this.edited,
    this.deletedForUsers = const <String>[],
    this.expireAt,
    this.extensions = const <String, dynamic>{},
  });

  factory ImMessage.fromJson(Map<String, dynamic> json) {
    final Object? recalled = json['recalled'];
    final Object? edited = json['edited'];
    final Object? reactions = json['reactions'];

    return ImMessage(
      appId: imStringOr(json['appId']),
      conversationId: imStringOr(json['conversationId']),
      conversationType: ImConversationType.fromWire(json['conversationType']),
      seq: imIntOr(json['seq']),
      messageId: imId(json['messageId']),
      clientMsgId: imStringOr(json['clientMsgId']),
      senderId: imStringOr(json['senderId']),
      senderPlatform: ImPlatform.fromWire(json['senderPlatform']),
      contentType: ImMessageContentType.fromWire(json['contentType']),
      content: imMap(json['content']),
      searchText: imString(json['searchText']),
      mentionAll: imBool(json['mentionAll']),
      mentionedUserIds: imStringList(json['mentionedUserIds']),
      quoteMessageId: imId(json['quoteMessageId']),
      threadRootId: imId(json['threadRootId']),
      options: ImMessageOptions.fromJson(imMap(json['options'])),
      status: ImMessageStatus.fromWire(json['status']),
      reactions: reactions is Map<String, dynamic>
          ? <String, List<String>>{
              for (final MapEntry<String, dynamic> entry in reactions.entries)
                entry.key: imStringList(entry.value),
            }
          : const <String, List<String>>{},
      recalled: recalled is Map<String, dynamic> ? ImRecallInfo.fromJson(recalled) : null,
      edited: edited is Map<String, dynamic> ? ImEditInfo.fromJson(edited) : null,
      deletedForUsers: imStringList(json['deletedForUsers']),
      sendTime: imIntOr(json['sendTime']),
      createTime: imIntOr(json['createTime']),
      expireAt: imInt(json['expireAt']),
      extensions: imMap(json['extensions']),
    );
  }

  final String appId;
  final String conversationId;
  final ImConversationType conversationType;

  /// Gap-free position inside the conversation. Ordering and gap repair both key off this.
  ///
  /// A [seq] of `0` means the message was never persisted — typing indicators, presence blips,
  /// chat-room traffic. Those are delivered straight through and never move a cursor.
  ///
  /// **Sort by this, never by a timestamp.** Client clocks are wrong and arrival order is not
  /// send order. 按 seq 排序，不要按时间戳。
  final int seq;

  final String messageId;

  /// Idempotency key. `(appId, conversationId, senderId, clientMsgId)` is unique server-side, so
  /// a resend after a timeout returns the first result instead of posting twice.
  final String clientMsgId;

  final String senderId;
  final ImPlatform senderPlatform;
  final ImMessageContentType contentType;

  /// Free-form payload, shaped by [contentType]. For media this holds an object key, not a URL —
  /// see `docs/GETTING-STARTED.md` §4.
  final Map<String, dynamic> content;

  /// Plain text the server indexed for `msg.search`. Usually absent on the delivery path.
  final String? searchText;

  final bool mentionAll;
  final List<String> mentionedUserIds;
  final String? quoteMessageId;

  /// Root of a thread, when the tenant uses threading. Null on an ordinary message.
  final String? threadRootId;

  /// Per-message switches the sender chose: persistence, unread counting, offline push, receipts.
  final ImMessageOptions options;

  final ImMessageStatus status;
  final Map<String, List<String>> reactions;
  final ImRecallInfo? recalled;
  final ImEditInfo? edited;

  /// Users who deleted this message for themselves only. Present on an admin-facing read; the
  /// delivery path filters the caller out of it server-side.
  final List<String> deletedForUsers;

  /// Sender's own clock, unix ms. Display only.
  final int sendTime;

  /// Authoritative server clock, unix ms.
  final int createTime;

  /// When a burn-after-reading message stops existing, unix ms.
  final int? expireAt;

  final Map<String, dynamic> extensions;

  @override
  String toString() => 'ImMessage($conversationId #$seq ${contentType.name} from $senderId)';
}

/// What the server returns for a successful `msg.send` — the server's `SendMessageResult`.
class ImSendResult {
  const ImSendResult({
    required this.messageId,
    required this.seq,
    required this.conversationId,
    required this.clientMsgId,
    required this.createTime,
    this.deduplicated = false,
    this.contentModified = false,
  });

  factory ImSendResult.fromJson(Map<String, dynamic> json) => ImSendResult(
        messageId: imId(json['messageId']),
        seq: imIntOr(json['seq']),
        conversationId: imStringOr(json['conversationId']),
        clientMsgId: imStringOr(json['clientMsgId']),
        createTime: imIntOr(json['createTime']),
        deduplicated: imBool(json['deduplicated']),
        contentModified: imBool(json['contentModified']),
      );

  final String messageId;
  final int seq;
  final String conversationId;
  final String clientMsgId;
  final int createTime;

  /// True when the server matched an earlier send by `clientMsgId` and replayed its result.
  /// Getting this back is success, not failure — it is idempotency working.
  final bool deduplicated;

  /// True when a moderation callback rewrote the content before it was stored.
  final bool contentModified;
}

/// The server DTO name for [ImSendResult], so a reader holding `endpoint-inventory.json` finds it
/// under the name the inventory uses.
typedef ImSendMessageResult = ImSendResult;

/// Summary of the newest message in a conversation, as carried on [ImConversationView]. The
/// server's `MessageBrief`.
class ImLastMessage {
  const ImLastMessage({
    required this.messageId,
    required this.seq,
    required this.senderId,
    required this.contentType,
    required this.digest,
    required this.createTime,
    required this.recalled,
  });

  factory ImLastMessage.fromJson(Map<String, dynamic> json) => ImLastMessage(
        messageId: imId(json['messageId']),
        seq: imIntOr(json['seq']),
        senderId: imStringOr(json['senderId']),
        contentType: ImMessageContentType.fromWire(json['contentType']),
        digest: imStringOr(json['digest']),
        createTime: imIntOr(json['createTime']),
        recalled: imBool(json['recalled']),
      );

  final String messageId;
  final int seq;
  final String senderId;
  final ImMessageContentType contentType;

  /// Short plain-text preview for the conversation list.
  final String digest;

  final int createTime;
  final bool recalled;
}

/// The server DTO name for [ImLastMessage].
typedef ImMessageBrief = ImLastMessage;

/// A row in the conversation list. The server's `ConversationView`.
class ImConversationView {
  const ImConversationView({
    required this.conversationId,
    required this.type,
    required this.maxSeq,
    required this.readSeq,
    required this.unreadCount,
    required this.updatedAt,
    this.lastMessage,
    this.pinned = false,
    this.muted = ImMuteMode.normal,
    this.draft,
    this.tags = const <String>[],
    this.manuallyUnread = false,
    this.peer,
    this.group,
    this.extensions = const <String, dynamic>{},
  });

  factory ImConversationView.fromJson(Map<String, dynamic> json) {
    final Object? last = json['lastMessage'];
    final Object? peer = json['peer'];
    final Object? group = json['group'];

    return ImConversationView(
      conversationId: imStringOr(json['conversationId']),
      type: ImConversationType.fromWire(json['type']),
      lastMessage: last is Map<String, dynamic> ? ImLastMessage.fromJson(last) : null,
      maxSeq: imIntOr(json['maxSeq']),
      readSeq: imIntOr(json['readSeq']),
      unreadCount: imIntOr(json['unreadCount']),
      pinned: imBool(json['pinned']),
      muted: ImMuteMode.fromWire(json['muted']),
      draft: imString(json['draft']),
      tags: imStringList(json['tags']),
      manuallyUnread: imBool(json['manuallyUnread']),
      updatedAt: imIntOr(json['updatedAt']),
      peer: peer is Map<String, dynamic> ? ImUserProfile.fromJson(peer) : null,
      group: group is Map<String, dynamic> ? ImGroup.fromJson(group) : null,
      extensions: imMap(json['extensions']),
    );
  }

  final String conversationId;
  final ImConversationType type;
  final ImLastMessage? lastMessage;

  /// Highest seq the server holds for this conversation.
  final int maxSeq;

  /// Highest seq this user has read.
  final int readSeq;

  /// Derived server-side from `maxSeq - readSeq`, not an incrementing counter — which is why it
  /// agrees across a user's devices instead of drifting.
  final int unreadCount;

  final bool pinned;

  /// Do-not-disturb level.
  final ImMuteMode muted;

  final String? draft;
  final List<String> tags;

  /// The user marked this unread by hand. Distinct from [unreadCount] being non-zero, and the
  /// reason a conversation can show a dot with nothing new in it.
  final bool manuallyUnread;

  /// Cursor for incremental `conv.list` polling, and for `conn.sync`'s `conversationCursor`.
  final int updatedAt;

  /// The other party, on a single conversation. Saved round trip: the server already had it.
  final ImUserProfile? peer;

  /// The group, on a group conversation.
  final ImGroup? group;

  final Map<String, dynamic> extensions;
}

/// Page of results from any cursor-paginated endpoint. The server's `PagedResult<T>`.
///
/// Kept as a page rather than flattened to a bare list on purpose: [nextCursor] is the only
/// correct way to page, and an SDK that hides it forces the application into a wrong loop —
/// usually "stop when a page comes back shorter than the limit", which this server breaks by
/// design. `ConversationService.ListAsync` computes the cursor from the raw page *before* deleted
/// rows are filtered out, so a page can return fewer [items] than the limit while [hasMore] is
/// still true.
///
/// **Page on [hasMore] / [nextCursor] only. Never stop because `items.length < limit`.**
/// 只按 hasMore/nextCursor 翻页；服务端会返回"不满页但还有更多"的页。
class ImPage<T> {
  const ImPage({required this.items, required this.hasMore, this.nextCursor, this.total});

  factory ImPage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) decode, {
    String itemsKey = 'items',
  }) =>
      ImPage<T>(
        items: imList<T>(json[itemsKey], decode),
        hasMore: imBool(json['hasMore']),
        nextCursor: imString(json['nextCursor']),
        total: imInt(json['total']),
      );

  final List<T> items;

  /// Opaque; pass it straight back to fetch the next page.
  final String? nextCursor;

  final bool hasMore;

  /// Present only when the store can count cheaply. Null is not zero.
  final int? total;
}

/// Why the gateway closed a connection from its side.
///
/// Parsed out of the WebSocket close reason, which the server formats as `im-kick:{Reason}`. That
/// string is the *only* thing separating "another device took over" from "the train went into a
/// tunnel", and the two need opposite responses.
enum ImKickReason {
  /// The multi-device policy handed the session to another device. Terminal.
  multiLoginPolicy('MultiLoginPolicy', terminal: true),

  /// The token was revoked — logout elsewhere, or a security action. Terminal.
  tokenRevoked('TokenRevoked', terminal: true),

  /// The user is banned. Terminal.
  userBanned('UserBanned', terminal: true),

  /// The tenant application is disabled: unpaid, suspended, deleted. Terminal.
  appDisabled('AppDisabled', terminal: true),

  /// An administrator forced this session offline. Terminal.
  adminKick('AdminKick', terminal: true),

  /// The token aged out. Not terminal: a fresh token fixes it, so the SDK asks the host app for
  /// one and reconnects.
  tokenExpired('TokenExpired', terminal: false),

  /// A reason this SDK version does not recognise. Treated as recoverable and retried, because
  /// refusing to reconnect on an unknown string would strand every shipped client the moment the
  /// server adds a reason.
  unknown('', terminal: false);

  const ImKickReason(this.wireValue, {required this.terminal});

  /// The text after `im-kick:` in the close reason.
  final String wireValue;

  /// When true, reconnecting would fail identically, forever, so the SDK stops.
  final bool terminal;

  static const String _prefix = 'im-kick:';

  /// Returns the reason encoded in a WebSocket close [reason], or null when the close was not a
  /// kick at all — that is, when it was an ordinary network failure.
  static ImKickReason? parse(String? reason) {
    if (reason == null || !reason.startsWith(_prefix)) return null;
    final String raw = reason.substring(_prefix.length);
    for (final ImKickReason candidate in values) {
      if (candidate != unknown && candidate.wireValue == raw) return candidate;
    }
    return unknown;
  }
}

/// Emitted when the session is ended by the server rather than by the network.
class ImKickEvent {
  const ImKickEvent(this.reason, {this.rawReason = '', this.detail});

  final ImKickReason reason;

  /// The exact text the server sent, so an unrecognised reason is still reportable.
  final String rawReason;

  /// Payload of a server-pushed `conn.kick` frame, when the kick arrived as an event rather than
  /// as a close reason.
  final Map<String, dynamic>? detail;

  /// True when the SDK will not reconnect on its own.
  bool get isTerminal => reason.terminal;

  @override
  String toString() => 'ImKickEvent(${reason.name}, raw: "$rawReason")';
}

/// Thrown for any non-zero business code, and for client-side transport failures.
///
/// Implements [Exception] rather than extending [Error] because a rejected send is an expected
/// runtime condition you are meant to catch, not a bug in the calling code.
class ImException implements Exception {
  const ImException(this.code, this.message, {this.traceId, this.target});

  /// Maps a completed frame onto an error, applying `sdk/CONTRACT.md` §7.2.
  ///
  /// Two of those rows are choices rather than deductions, and both are here:
  ///
  /// - **`status == 2` is [ImErrorCode.unsupportedOperation], not [ImErrorCode.notFound].** 1002
  ///   means "your group does not exist"; 1008 means "this deployment does not have this endpoint",
  ///   which is what an SDK newer than a private-deployment server produces and exactly what the
  ///   integrator needs to read verbatim.
  /// - **`status == 1` is [ImErrorCode.internalError]**, message from the transport `msg` — the
  ///   endpoint threw before it could produce a business result, so `body.code` is meaningless
  ///   and must not be reported as though it meant something.
  ///
  /// Returns null when the frame was a success.
  static ImException? fromFrame(ImFrame frame, String target) {
    if (frame.status == ImFrameStatus.noSuchTarget) {
      return ImException(
        ImErrorCode.unsupportedOperation,
        'this deployment has no endpoint named "$target"',
        traceId: frame.body?.traceId,
        target: target,
      );
    }

    if (frame.status != ImFrameStatus.routed) {
      return ImException(
        ImErrorCode.internalError,
        frame.msg ?? 'the endpoint threw',
        traceId: frame.body?.traceId,
        target: target,
      );
    }

    final ImBody? body = frame.body;
    if (body == null) {
      return ImException(
        ImErrorCode.internalError,
        'reply carried no body',
        target: target,
      );
    }

    if (body.code == ImErrorCode.ok) return null;

    return ImException(
      body.code,
      body.message ?? 'request failed',
      traceId: body.traceId,
      target: target,
    );
  }

  /// One of [ImErrorCode], or a newer code this SDK does not name yet.
  final int code;

  final String message;

  /// Server-side correlation id. Quote it in a support ticket and the log line can be found.
  ///
  /// Not decoration: a bug report carrying [traceId] and [target] is a one-query investigation,
  /// and without them it is a guess.
  final String? traceId;

  /// The endpoint that failed, e.g. `msg.send`.
  final String? target;

  /// True when retrying the same call could plausibly answer differently. See
  /// [ImErrorCode.isRetryable] — the classification is shared with the other four SDKs, and the
  /// SDK never acts on it by itself.
  bool get isRetryable => ImErrorCode.isRetryable(code);

  /// True when the session's credentials were the problem: renew the token and try again.
  bool get requiresReauth => ImErrorCode.requiresReauth(code);

  /// True when the failure was produced locally — no socket, or no reply in time — rather than
  /// returned by the server.
  bool get isTransport => code == ImErrorCode.timeout || code == ImErrorCode.serviceUnavailable;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('ImException($code): $message');
    if (target != null) buffer.write(' [$target]');
    if (traceId != null) buffer.write(' traceId=$traceId');
    return buffer.toString();
  }
}
