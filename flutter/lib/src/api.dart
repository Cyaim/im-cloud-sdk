/// The typed surface, grouped into namespaces named exactly for the endpoint prefix.
///
/// 107 flat methods on one object is not an API, it is a scroll bar. `im.msg.recall(…)` is
/// `msg.recall`; `im.group.memberList(…)` is `group.memberList`. A reader who knows the endpoint
/// name knows the call without a lookup table, and — the part that matters at support time — a
/// bug report naming an endpoint can be grepped straight to the method.
///
/// **The method name is the endpoint's method part. No synonyms.** `msg.cancelScheduled` becomes
/// `cancelScheduled`, never `unschedule`, however much better that reads. See `sdk/CONTRACT.md`
/// §4.2. The nine flat convenience methods on [ImClient] are the only permitted exception, and
/// they are frozen legacy.
///
/// Every method here is a thin wrapper that builds a body and calls the same internal `request`
/// that [ImClient.invoke] does (§8.1). If they were not one code path they would drift on
/// timeouts, cancellation, error mapping and metrics — and the drift would be found by a customer.
///
/// 命名空间与端点前缀一一对应，方法名就是端点的方法部分，不取同义词；
/// 所有方法与 invoke() 走同一条内部请求路径。
library;

import 'dart:async';

import 'cancel.dart';
import 'device_logs.dart';
import 'json.dart';
import 'logging.dart';
import 'models.dart';
import 'protocol.dart';
import 'requests.dart';

/// What a namespace needs from the connection, and nothing more.
///
/// An interface rather than a direct dependency on `ImConnection` so the namespaces stay testable
/// on their own, and so the escape hatch and the typed surface provably share one implementation.
abstract interface class ImRequester {
  /// Sends [target] with [body] and returns the unwrapped `ApiResult.data`.
  ///
  /// Throws [ImException] for any non-zero business code and for a transport failure;
  /// [ImCancelledException] when [cancel] fires.
  Future<T> request<T>(String target, [Object? body, ImCancelToken? cancel]);
}

/// Shared plumbing: every namespace decodes `data` itself rather than casting, because the JSON
/// policy lets a `long` arrive as a string and a null field arrive as no field at all.
abstract base class _Namespace {
  const _Namespace(this.requester);

  final ImRequester requester;

  Future<Object?> rawData(String target, [Object? body, ImCancelToken? cancel]) =>
      requester.request<Object?>(target, body, cancel);

  /// An endpoint whose `ApiResult` carries no payload.
  Future<void> sendUnit(String target, [Object? body, ImCancelToken? cancel]) async {
    await requester.request<Object?>(target, body, cancel);
  }

  Future<T> decodeOne<T>(
    String target,
    Object? body,
    ImCancelToken? cancel,
    T Function(Map<String, dynamic>) decode,
  ) async =>
      decode(imMap(await rawData(target, body, cancel)));

  Future<List<T>> decodeList<T>(
    String target,
    Object? body,
    ImCancelToken? cancel,
    T Function(Map<String, dynamic>) decode,
  ) async =>
      imList<T>(await rawData(target, body, cancel), decode);

  Future<ImPage<T>> decodePage<T>(
    String target,
    Object? body,
    ImCancelToken? cancel,
    T Function(Map<String, dynamic>) decode,
  ) async =>
      ImPage<T>.fromJson(imMap(await rawData(target, body, cancel)), decode);
}

// ---------------------------------------------------------------------------- conn (T0)

/// `conn.*` — transport lifecycle. An SDK missing one of these is broken, not incomplete.
final class ImConnApi extends _Namespace {
  const ImConnApi(super.requester);

  /// `conn.heartbeat`. Keeps the session alive and, on the server side, heals it: a beat that
  /// finds no routing entry re-registers this connection and republishes presence.
  ///
  /// [ImClient] beats on its own at the cadence the server reports. Call this directly only for a
  /// diagnostics screen — [ImHeartbeatResult.connectionId] and [ImHeartbeatResult.nodeId] are what
  /// turn a support ticket into one query.
  Future<ImHeartbeatResult> heartbeat([ImCancelToken? cancel]) =>
      decodeOne('conn.heartbeat', null, cancel, ImHeartbeatResult.fromJson);

  /// `conn.reauth`. Swaps in a fresh token **without dropping the socket**.
  ///
  /// This is the whole point of T0: on a flaky network, a reconnect is precisely what you were
  /// trying to avoid, and a token expiry should not cost one. [ImClient] calls this itself when a
  /// request comes back [ImErrorCode.tokenExpired] and `ImOptions.onTokenExpired` can supply a new
  /// token; only if reauth fails does the session drop.
  Future<void> reauth(ImReauthRequest request, [ImCancelToken? cancel]) =>
      sendUnit('conn.reauth', request.toJson(), cancel);

  /// `conn.sync`. What changed while we were away, one page at a time.
  ///
  /// [ImClient] runs this itself on every connect and reconnect, with the cursor rules in
  /// `sdk/CONTRACT.md` §5.6 — including paging until `hasMore` is false, which is the step whose
  /// absence loses every conversation past the first page. Calling it by hand does not move any
  /// cursor.
  Future<ImResumeResult> sync(ImResumeRequest request, [ImCancelToken? cancel]) =>
      decodeOne('conn.sync', request.toJson(), cancel, ImResumeResult.fromJson);
}

// ---------------------------------------------------------------------------- msg

/// `msg.*` — sending, reading and operating on messages.
final class ImMsgApi extends _Namespace {
  const ImMsgApi(super.requester);

  /// `msg.send`. Idempotent on [ImSendMessageRequest.clientMsgId].
  Future<ImSendResult> send(ImSendMessageRequest request, [ImCancelToken? cancel]) =>
      decodeOne('msg.send', request.toJson(), cancel, ImSendResult.fromJson);

  /// `msg.sync`. One page of a contiguous seq range.
  ///
  /// Note this does **not** deliver through [ImClient.messages] and does not move a cursor: the
  /// typed surface never mutates sequence state, only the SDK's own repair path does. Loop on
  /// [ImSyncMessagesResult.hasMore], never on `messages.length`.
  Future<ImSyncMessagesResult> sync(ImSyncMessagesRequest request, [ImCancelToken? cancel]) =>
      decodeOne('msg.sync', request.toJson(), cancel, ImSyncMessagesResult.fromJson);

  /// `msg.history`. Pages backwards from a seq cursor.
  Future<ImPage<ImMessage>> history(ImHistoryRequest request, [ImCancelToken? cancel]) =>
      decodePage('msg.history', request.toJson(), cancel, ImMessage.fromJson);

  /// `msg.recall`. Withdraws a message for everyone, inside the tenant's recall window.
  Future<void> recall(ImRecallMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.recall', request.toJson(), cancel);

  /// `msg.delete`. Hides messages for the caller, or destroys them for everyone.
  Future<void> delete(ImDeleteMessagesRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.delete', request.toJson(), cancel);

  /// `msg.typing`.
  Future<void> typing(ImTypingRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.typing', request.toJson(), cancel);

  /// `msg.edit`.
  Future<void> edit(ImEditMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.edit', request.toJson(), cancel);

  /// `msg.forward`. Returns one result per message actually posted.
  Future<List<ImSendResult>> forward(
    ImForwardMessagesRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodeList('msg.forward', request.toJson(), cancel, ImSendResult.fromJson);

  /// `msg.react`.
  Future<void> react(ImReactRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.react', request.toJson(), cancel);

  /// `msg.receipt`. Per-message read acknowledgement.
  Future<void> receipt(ImReceiptRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.receipt', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- conv

/// `conv.*` — the list a user opens the app to, and the per-user state attached to it.
final class ImConvApi extends _Namespace {
  const ImConvApi(super.requester);

  /// `conv.list`. Incremental: pass the largest `updatedAt` you hold.
  Future<ImPage<ImConversationView>> list(
    ImListConversationsRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodePage('conv.list', request.toJson(), cancel, ImConversationView.fromJson);

  /// `conv.get`.
  Future<ImConversationView> get(ImConversationIdRequest request, [ImCancelToken? cancel]) =>
      decodeOne('conv.get', request.toJson(), cancel, ImConversationView.fromJson);

  /// `conv.read`. Moves the read cursor, clearing the badge on every device of this user.
  ///
  /// Distinct from the *delivery* cursor [ImClient.commit] moves: this one is server-side and
  /// about what the human has seen; that one is client-side and about what the app has stored.
  Future<void> read(ImReadRequest request, [ImCancelToken? cancel]) =>
      sendUnit('conv.read', request.toJson(), cancel);

  /// `conv.unreadTotal`. The app badge.
  Future<int> unreadTotal([ImCancelToken? cancel]) async =>
      imIntOr(await rawData('conv.unreadTotal', null, cancel));

  /// `conv.setting`. Pin, mute, draft, tags — a patch, not a replacement.
  Future<void> setting(
    ImUpdateConversationSettingRequest request, [
    ImCancelToken? cancel,
  ]) =>
      sendUnit('conv.setting', request.toJson(), cancel);

  /// `conv.delete`. Removes the conversation from the caller's list. The messages survive for
  /// everyone else, and for the caller if it is re-created.
  Future<void> delete(ImConversationIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('conv.delete', request.toJson(), cancel);

  /// `conv.clear`. Clears the caller's own history. Clearing for everyone destroys other people's
  /// data and is a server-API operation, not a client one.
  Future<void> clear(ImConversationIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('conv.clear', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- user

/// `user.*` — profiles and presence.
final class ImUserApi extends _Namespace {
  const ImUserApi(super.requester);

  /// `user.me`.
  Future<ImUserProfile> me([ImCancelToken? cancel]) =>
      decodeOne('user.me', null, cancel, ImUserProfile.fromJson);

  /// `user.profile`.
  Future<ImUserProfile> profile(ImUserIdRequest request, [ImCancelToken? cancel]) =>
      decodeOne('user.profile', request.toJson(), cancel, ImUserProfile.fromJson);

  /// `user.batchProfile`. Up to 200 ids. This is what stops a 50-row conversation list issuing 50
  /// profile calls.
  Future<List<ImUserProfile>> batchProfile(
    ImUserIdsRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodeList('user.batchProfile', request.toJson(), cancel, ImUserProfile.fromJson);

  /// `user.updateProfile`. Patches the caller's own profile.
  Future<void> updateProfile(ImUpdateProfileRequest request, [ImCancelToken? cancel]) =>
      sendUnit('user.updateProfile', request.toJson(), cancel);

  /// `user.presence`. Tenant-gated on `EnablePresence`; a disabled app answers
  /// [ImErrorCode.featureNotEnabled], which must not be latched locally.
  Future<List<ImPresenceState>> presence(ImUserIdsRequest request, [ImCancelToken? cancel]) =>
      decodeList('user.presence', request.toJson(), cancel, ImPresenceState.fromJson);

  /// `user.subscribePresence`. Updates then arrive on `evt.presence`.
  Future<void> subscribePresence(
    ImSubscribePresenceRequest request, [
    ImCancelToken? cancel,
  ]) =>
      sendUnit('user.subscribePresence', request.toJson(), cancel);

  /// `user.unsubscribePresence`.
  Future<void> unsubscribePresence(ImUserIdsRequest request, [ImCancelToken? cancel]) =>
      sendUnit('user.unsubscribePresence', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- friend

/// `friend.*` — the contact list, applications and the blocklist.
final class ImFriendApi extends _Namespace {
  const ImFriendApi(super.requester);

  /// `friend.list`.
  Future<ImPage<ImFriend>> list(ImCursorRequest request, [ImCancelToken? cancel]) =>
      decodePage('friend.list', request.toJson(), cancel, ImFriend.fromJson);

  /// `friend.add`. Files an application; acceptance arrives on `evt.friend`.
  Future<void> add(ImAddFriendRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.add', request.toJson(), cancel);

  /// `friend.handleRequest`.
  Future<void> handleRequest(ImHandleFriendRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.handleRequest', request.toJson(), cancel);

  /// `friend.requestList`.
  Future<ImPage<ImFriendRequest>> requestList(
    ImFriendRequestListRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodePage('friend.requestList', request.toJson(), cancel, ImFriendRequest.fromJson);

  /// `friend.delete`.
  Future<void> delete(ImUserIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.delete', request.toJson(), cancel);

  /// `friend.blockList`.
  Future<ImPage<ImBlockEntry>> blockList(ImCursorRequest request, [ImCancelToken? cancel]) =>
      decodePage('friend.blockList', request.toJson(), cancel, ImBlockEntry.fromJson);

  /// `friend.block`.
  ///
  /// Not optional product surface: app-store review treats user blocking as mandatory for any app
  /// carrying user-generated content. Ship the button.
  Future<void> block(ImBlockRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.block', request.toJson(), cancel);

  /// `friend.unblock`.
  Future<void> unblock(ImUserIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.unblock', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- group

/// `group.*` — the ten calls that turn a 1:1 chat into a messenger.
final class ImGroupApi extends _Namespace {
  const ImGroupApi(super.requester);

  /// `group.create`.
  Future<ImGroup> create(ImCreateGroupRequest request, [ImCancelToken? cancel]) =>
      decodeOne('group.create', request.toJson(), cancel, ImGroup.fromJson);

  /// `group.info`.
  Future<ImGroup> info(ImGroupIdRequest request, [ImCancelToken? cancel]) =>
      decodeOne('group.info', request.toJson(), cancel, ImGroup.fromJson);

  /// `group.update`.
  Future<void> update(ImUpdateGroupCommand request, [ImCancelToken? cancel]) =>
      sendUnit('group.update', request.toJson(), cancel);

  /// `group.dismiss`. Owner only. The history stays readable.
  Future<void> dismiss(ImGroupIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.dismiss', request.toJson(), cancel);

  /// `group.memberList`. Always paged.
  Future<ImPage<ImGroupMember>> memberList(
    ImGroupCursorRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodePage('group.memberList', request.toJson(), cancel, ImGroupMember.fromJson);

  /// `group.joined`. The caller's own groups.
  Future<ImPage<ImGroup>> joined(ImCursorRequest request, [ImCancelToken? cancel]) =>
      decodePage('group.joined', request.toJson(), cancel, ImGroup.fromJson);

  /// `group.invite`.
  Future<void> invite(ImGroupMembersRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.invite', request.toJson(), cancel);

  /// `group.kick`.
  Future<void> kick(ImGroupMembersRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.kick', request.toJson(), cancel);

  /// `group.quit`. The owner cannot quit; transfer ownership first.
  Future<void> quit(ImGroupIdRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.quit', request.toJson(), cancel);

  /// `group.join`. A `needApproval` group answers [ImErrorCode.joinNeedsApproval] — the
  /// application was filed, which is not a failure.
  Future<void> join(ImJoinGroupRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.join', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- media

/// `media.*` — attachments. Bytes go straight to object storage, never through the gateway.
final class ImMediaApi extends _Namespace {
  const ImMediaApi(super.requester);

  /// `media.uploadTicket`. A chat app that cannot send a photo is not a chat app, and a photo
  /// cannot be sent without one of these.
  Future<ImMediaUploadTicket> uploadTicket(
    ImUploadTicketRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodeOne('media.uploadTicket', request.toJson(), cancel, ImMediaUploadTicket.fromJson);

  /// `media.downloadUrl`. Every reader signs their own short-lived link; that is what makes
  /// expiry and revocation possible at all.
  Future<String> downloadUrl(ImDownloadUrlRequest request, [ImCancelToken? cancel]) async =>
      imStringOr(await rawData('media.downloadUrl', request.toJson(), cancel));
}

// ---------------------------------------------------------------------------- push

/// `push.*` — offline notification registration.
///
/// **The host app owns token acquisition; the SDK owns token delivery.** Firebase, APNs and every
/// OEM channel hand the token to the application, not to a library, so this package takes no push
/// plugin dependency. Call [setToken] from whatever plugin the app already uses — once at startup
/// and again from the plugin's refresh callback — and the SDK does the rest:
///
/// 1. registers on **every** successful connect while a token is known (not once at install: the
///    vendor may replace a token while the process is frozen, and the server has no other way to
///    learn it — re-registering an unchanged token costs no write, the server debounces it);
/// 2. registers immediately on a refresh if connected, otherwise on the next connect;
/// 3. unregisters **before** the socket closes on logout — see [ImClient.logout]. After the socket
///    closes there is no authenticated channel and the token cannot be removed at all.
///
/// Disconnecting never unregisters. A dead socket is precisely the state offline push exists to
/// serve.
///
/// ```dart
/// FirebaseMessaging.instance.onTokenRefresh.listen(
///   (String t) => im.push.setToken(ImPushProvider.fcm, t),
/// );
/// im.push.setToken(ImPushProvider.fcm, await FirebaseMessaging.instance.getToken() ?? '');
/// ```
///
/// 宿主应用负责取 token，SDK 负责送 token：每次连接都注册，登出时先注销再断开。
final class ImPushApi extends _Namespace {
  ImPushApi(
    super.requester, {
    required bool Function() isConnected,
    required ImLogger logger,
  })  : _isConnected = isConnected,
        _logger = logger;

  final bool Function() _isConnected;
  final ImLogger _logger;

  String? _provider;
  String? _token;
  String? _language;
  bool _registered = false;
  bool _warned = false;

  /// The vendor token the SDK is holding, if any. Null until [setToken].
  String? get token => _token;

  /// The channel that token came from.
  String? get provider => _provider;

  /// True once a registration for the current token has succeeded on this connection.
  bool get isRegistered => _registered;

  /// `push.register`. Records or refreshes this device's vendor token.
  ///
  /// Identity comes from the socket; there is no `userId` or `deviceId` to pass. Prefer [setToken],
  /// which also handles rules 1 and 2 above; call this directly only when you are driving
  /// registration yourself.
  Future<void> register(ImRegisterPushTokenRequest request, [ImCancelToken? cancel]) async {
    await sendUnit('push.register', request.toJson(), cancel);
    _provider = request.provider;
    _token = request.token;
    _language = request.language;
    _registered = true;
  }

  /// `push.unregister`. Drops this device's registration; other devices of the same user are
  /// untouched.
  ///
  /// **Call this before disconnecting, not after** — [ImClient.logout] does. Once the socket is
  /// closed there is no authenticated channel to remove the token on, and the user keeps getting
  /// notifications on a handset they logged out of.
  Future<void> unregister([ImCancelToken? cancel]) async {
    await sendUnit('push.unregister', null, cancel);
    _registered = false;
  }

  /// `push.clicked`. Reports that the user tapped one of this device's notifications.
  ///
  /// **The call site is the tap handler, not the message render.** What it feeds is the delivery
  /// funnel on the tenant's push screen — sent → delivered → clicked. APNs and FCM do not report
  /// delivery at all, so on most deployments a click is the only evidence a notification ever
  /// arrived, and the server credits delivery from it.
  ///
  /// **This is the one call in the package that swallows its own failure**, and the only one that
  /// should: it is best-effort statistics, nothing in the app depends on the answer, and the
  /// natural way to call it is to fire and not await — which in Dart turns any rejection into an
  /// unhandled asynchronous error, i.e. a red screen in debug for a notification that was tapped
  /// successfully. Failures are logged through the client's logger instead. Do not retry it either;
  /// a click reported twice is worse than one reported never.
  ///
  /// The usual failure is `2401 PushDeliveryNotFound` — the delivery row expired after seven days,
  /// or the notification did not come from this platform. Neither is the caller's fault and neither
  /// is worth a word to the user.
  ///
  /// **Cancellation is the exception.** An [ImCancelledException] is rethrown rather than
  /// logged: it means the caller decided to stop, and the one thing a fire-and-forget call
  /// must not do is report success to somebody who asked it to quit.
  ///
  /// 调用点是点击处理器，不是消息渲染处：APNs 与 FCM 根本不回报送达，
  /// 多数部署上"点击"是这条通知确实到过的唯一证据。失败只记日志——
  /// 这个调用天然不会被 await，而 Dart 里未被 await 的失败 Future 是一次未捕获异步异常。
  Future<void> clicked([ImPushClickedRequest? request, ImCancelToken? cancel]) async {
    try {
      await sendUnit('push.clicked', (request ?? const ImPushClickedRequest()).toJson(), cancel);
    } on ImCancelledException {
      // Cancellation is not a server outcome (CONTRACT §7.5 rule 3) and it is not this call's to
      // absorb. "The caller cancelled it, so there is nobody left to tell" reads true and is not:
      // the caller is precisely who is still listening — a cancelled token means somebody upstream
      // decided to stop, and a future that completes normally tells them it finished instead.
      // 取消不是服务端结果，也不该由这个调用吞掉：「调用方取消了，已经没人听了」听着成立，实则相反——
      // 还在听的正是调用方。取消意味着上游决定停下，而一个正常完成的 Future 会告诉他「做完了」。
      rethrow;
    } catch (error) {
      _logger('push.clicked was not recorded: $error. The delivery funnel undercounts by one.');
    }
  }

  /// Caches the vendor token and applies §6.2.
  ///
  /// Registers immediately if the socket is open, otherwise on the next successful connect. Safe
  /// to call from a plugin callback on any turn of the event loop, and safe to call with the same
  /// token repeatedly — the server debounces an unchanged token to no write at all.
  ///
  /// Returns the registration future when one was started, so a caller that wants to await it can;
  /// callers that do not care may ignore it.
  Future<void> setToken(String provider, String token, {String? language}) {
    if (token.isEmpty) return Future<void>.value();

    final bool changed = token != _token || provider != _provider || language != _language;
    _provider = provider;
    _token = token;
    _language = language;
    if (changed) _registered = false;

    if (!_isConnected()) return Future<void>.value();
    return registerOnConnect();
  }

  /// Forgets the cached token without calling the server. Used by [ImClient.logout] after a
  /// successful [unregister], so a later reconnect does not re-register a token for an account
  /// that has logged out.
  void clearToken() {
    _provider = null;
    _token = null;
    _language = null;
    _registered = false;
    _warned = false;
  }

  /// Rule 1: register whatever token we hold, on every successful connect.
  ///
  /// Failures are logged rather than thrown — this runs on the connect path, where nobody is
  /// awaiting it, and a push registration that failed must not take the session down. The one
  /// warning §6.2 requires is emitted here: a device holding a token it has never registered is
  /// indistinguishable from a broken push provider, and that misdiagnosis costs a support cycle
  /// every time.
  /// The connect-time hook, not part of the public token-cache pair. `setToken` / `clearToken` is
  /// the pair, spelled that way in all five SDKs; this is what the client calls behind it.
  Future<void> registerOnConnect() async {
    final String? token = _token;
    if (token == null || token.isEmpty) return;

    try {
      await register(ImRegisterPushTokenRequest(
        provider: _provider ?? '',
        token: token,
        language: _language,
      ));
    } catch (error) {
      if (!_warned) {
        _warned = true;
        _logger(
          'push.register failed and this device is holding a token it has never registered: '
          '$error. Offline push will not reach it, which looks exactly like a broken push '
          'provider. See sdk/CONTRACT.md §6.2.',
        );
      }
    }
  }

  /// @nodoc
  @Deprecated('Renamed to registerOnConnect, matching the other four SDKs. Removed in 2.0.')
  Future<void> registerCachedToken() => registerOnConnect();
}

// ---------------------------------------------------------------------------- moderation

/// `moderation.*` — what an end user can do about content, as opposed to what a moderator does
/// about it.
///
/// The other half of what [ImFriendApi.block] is here for: app-store review requires both a way to
/// block an abusive user and a way to report objectionable content, and an app that ships only the
/// first still does not pass. Put the two behind the same long-press menu.
///
/// 与拉黑成对：应用商店审核要求「屏蔽」和「举报」两者都有，只做前者一样过不了。
final class ImModerationApi extends _Namespace {
  const ImModerationApi(super.requester);

  /// `moderation.report`. Reports another user, optionally naming a message.
  ///
  /// **The reporter is the connection**, so there is nothing to pass but who and what is being
  /// reported — see [ImSubmitReportRequest]. Reporting yourself is refused with
  /// [ImErrorCode.invalidArgument], and so is a category the server does not file.
  ///
  /// The receipt is not the stored report: [ImReportReceipt] is an id and a timestamp, because the
  /// reporter has no business reading back what a moderator decided.
  Future<ImReportReceipt> report(ImSubmitReportRequest request, [ImCancelToken? cancel]) =>
      decodeOne('moderation.report', request.toJson(), cancel, ImReportReceipt.fromJson);
}

/// `diag.*` — this device's half of troubleshooting.
///
/// **Ordinary applications never call these.** [ImClient] drives both: it asks once after every
/// connect and answers whatever is waiting. They are typed because this SDK's rule is that every
/// endpoint has a typed method — a capability reachable only through a raw invoke is one a support
/// engineer cannot find.
///
/// See `ADR-003` for why the log store belongs to the integrating application, and [ImLogStore] for
/// what an integrator who supplies none still gets.
final class ImDiagApi extends _Namespace {
  const ImDiagApi(super.requester);

  /// `diag.logRequests`. Open log requests for this device, each with a freshly signed upload
  /// target.
  ///
  /// **Once per connect, never on a timer.** Requests are raised by a person looking at a support
  /// ticket, so the rate is at most one every few days; polling would turn a human-paced feature
  /// into background traffic on every handset a tenant has.
  /// 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
  Future<List<ImPendingDeviceLog>> logRequests([ImCancelToken? cancel]) =>
      decodeList('diag.logRequests', null, cancel, ImPendingDeviceLog.fromJson);

  /// `diag.logUploaded`. Reports what happened to one request — a bundle, or why there is none.
  ///
  /// **A refusal is an answer and must be sent.** Silence is indistinguishable from a device that
  /// never received the request, and the two send a support engineer in opposite directions: wait
  /// for the customer to open the app, or look at why this build cannot comply.
  /// 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别，而两者要查的方向相反。
  Future<void> logUploaded(ImDeviceLogAnswer answer, [ImCancelToken? cancel]) =>
      sendUnit('diag.logUploaded', answer.toJson(), cancel);
}
