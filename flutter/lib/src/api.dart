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

  // ---- T3: competitive parity
  //
  // Every message id below leaves as a **string**, and for these endpoints that is the server's
  // requirement, not only this package's caution: the request DTOs declare `messageId` as C#
  // `string`, and the socket binder refuses a JSON number for one with `1000`. See
  // ImConversationMessageRequest.
  // 下面每个消息 id 都以字符串出线：服务端 DTO 就是 string，给数字会被绑定器拒成 1000。

  /// `msg.pin` (T3). Pins a message to the conversation's shared board — something everyone in the
  /// conversation sees, as opposed to [favourite], which only the caller does.
  ///
  /// **Who may:** either side of a single chat; in a group, only the owner or an admin while the
  /// deployment's `IM:Extras:GroupPinRequiresAdmin` is on, which is the default
  /// ([ImErrorCode.noGroupPermission] otherwise). Chat rooms are
  /// [ImErrorCode.unsupportedOperation]; a system or assistant conversation is
  /// [ImErrorCode.forbidden] unless the caller has received something there.
  ///
  /// **Refusals:** [ImErrorCode.messageNotFound] for a message that is not there — including a
  /// `messageId` the server cannot parse — and for a recalled one;
  /// [ImErrorCode.unsupportedOperation] for an ephemeral message (sent with
  /// [ImMessageOptions.expireIn]); [ImErrorCode.conflict] once the board holds
  /// `IM:Extras:MaxPinsPerConversation` pins (20 by default) — unpin one first. Pinning what is
  /// already pinned succeeds and announces nothing.
  ///
  /// On success everyone gets a notification message (`contentType` 9, `content.code` 1514,
  /// `pinned: true`), which does not count as unread and raises no push. **Do not take the message
  /// id from that notification**: its `content.messageId` is a bare JSON number, which on the web
  /// has lost precision before this package sees it. Re-read [pins] instead.
  /// 置顶成功会发一条 1514 通知，但它的 content.messageId 是裸数字、在 web 上已经丢了精度——请重新读 pins。
  Future<void> pin(ImConversationMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.pin', request.toJson(), cancel);

  /// `msg.unpin` (T3). Takes a message off the board. Same permission rules as [pin].
  ///
  /// **Succeeds silently when nothing was pinned** — including for a `messageId` the server cannot
  /// parse — so it is safe to retry, and a success is not proof the id was right. The 1514
  /// notification (`pinned: false`) goes out only when a pin was actually removed and the message
  /// still exists.
  Future<void> unpin(ImConversationMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.unpin', request.toJson(), cancel);

  /// `msg.pins` (T3). The conversation's pinned board, newest pin first.
  ///
  /// **A plain list, not a page**: the board is capped (20 by default), so there is nothing to page
  /// through, and it is empty when nothing is pinned. Any participant may read it; a group
  /// non-member is [ImErrorCode.notGroupMember]. Pins whose message has since vanished are dropped
  /// from the answer and cleaned up server-side.
  Future<List<ImPinnedMessage>> pins(ImConversationIdRequest request, [ImCancelToken? cancel]) =>
      decodeList('msg.pins', request.toJson(), cancel, ImPinnedMessage.fromJson);

  /// `msg.favourite` (T3). Bookmarks a message for the caller alone. Private and silent: nobody
  /// else is told.
  ///
  /// **Refusals:** [ImErrorCode.messageNotFound] for a message that is not there (including an
  /// unparseable id); [ImErrorCode.unsupportedOperation] for an ephemeral message;
  /// [ImErrorCode.conflict] once the caller holds `IM:Extras:MaxFavouritesPerUser` (5000 by
  /// default) — counted *before* the write, so re-favouriting at the cap also fails. A recalled
  /// message is **not** refused. Repeating it is safe, but it moves the favourite back to the top.
  Future<void> favourite(ImConversationMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.favourite', request.toJson(), cancel);

  /// `msg.unfavourite` (T3). Removes a bookmark.
  ///
  /// **Always succeeds** — nothing to remove, an unparseable id, a conversation the caller has since
  /// left: all `0`. So it is safe to repeat, and a success proves nothing about the id.
  Future<void> unfavourite(ImConversationMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.unfavourite', request.toJson(), cancel);

  /// `msg.favourites` (T3). The caller's bookmarks across every conversation, newest favourite
  /// first, as whole messages. The request is optional; without one the first page of 20 comes back.
  ///
  /// **Page until [ImPage.nextCursor] is null, not until a page comes back short**: favourites in
  /// chats the caller can no longer read are hidden rather than returned, so a page can be short —
  /// even empty — with more behind it. Recalled messages *are* listed, with
  /// [ImMessage.recalled] set. The payload carries no favourite timestamp, and [ImPage.total] is
  /// always null.
  /// 翻到 nextCursor 为空为止，不要按「这页不满」停：读不到的会话里的收藏被隐藏，一页可以短甚至为空。
  Future<ImPage<ImMessage>> favourites([
    ImPageRequest request = const ImPageRequest(),
    ImCancelToken? cancel,
  ]) =>
      decodePage('msg.favourites', request.toJson(), cancel, ImMessage.fromJson);

  /// `msg.burn` (T3). Starts the countdown on a burn-after-reading message. **Call it when the
  /// message is actually shown**; it is safe to call for every rendered message.
  ///
  /// Only messages sent with [ImMessageOptions.expireIn] above zero burn
  /// ([ImErrorCode.unsupportedOperation] otherwise). The sender calling it on their own message
  /// succeeds and starts nothing. The first *reader* moves the message's `expireAt` from
  /// `createTime + expireIn` to `now + expireIn` — **conversation-wide**, so in a group the first
  /// reader starts everyone's clock — and later calls succeed silently. A message nobody reads
  /// still expires at `createTime + expireIn`.
  ///
  /// The only T3 message call that checks its id: a missing or unparseable `messageId` is
  /// [ImErrorCode.invalidArgument]; a message that is not there is [ImErrorCode.messageNotFound].
  /// Participants are told through `evt.messageUpdate` with `kind: "burn"` and the absolute
  /// `expireAt` — read it with `im.events('evt.messageUpdate')`; that frame is not typed yet.
  ///
  /// **A courtesy between cooperating clients, not a defence.** The server stops serving the
  /// message and tells clients to erase it; a recipient who already has the bytes can keep them.
  /// 阅后即焚是协作客户端之间的礼貌，不是防御：已经拿到字节的接收方可以留存。
  Future<void> burn(ImConversationMessageRequest request, [ImCancelToken? cancel]) =>
      sendUnit('msg.burn', request.toJson(), cancel);

  /// `msg.search` (T3). Full-text search over what the caller can see, newest first. Recalled
  /// messages and ones the caller deleted for themselves are excluded.
  ///
  /// **Off unless the tenant turned it on**, and gated twice: [ImErrorCode.featureNotEnabled] while
  /// `EnableSearch` is off (the default, and forced off on end-to-end-encrypted apps), and
  /// [ImErrorCode.planExpired] when the plan lacks the search add-on. Latch neither — a tenant can
  /// change both at runtime (CONTRACT §7.4).
  ///
  /// **Rate limited per user, before either gate:** [ImErrorCode.rateLimited] past
  /// `MaxSearchPerMinutePerUser` (30 by default) in a sliding minute, with no retry hint. Because
  /// the limiter runs first, calls against a tenant with search off still spend the budget —
  /// **debounce search-as-you-type**.
  ///
  /// A blank keyword is [ImErrorCode.invalidArgument]. The filters apply after the index page, so
  /// short pages with [ImPage.hasMore] true are normal; page on [ImPage.nextCursor]. An index that
  /// takes longer than five seconds comes back [ImErrorCode.internalError], not
  /// [ImErrorCode.timeout] — it is retryable, and the SDK leaves the retry to you.
  /// 默认关闭；限速在开关检查之前执行，所以对关闭搜索的租户调用也会消耗额度——输入联想要做防抖。
  Future<ImPage<ImMessage>> search(ImSearchMessagesRequest request, [ImCancelToken? cancel]) =>
      decodePage('msg.search', request.toJson(), cancel, ImMessage.fromJson);

  /// `msg.receiptDetail` (T3). Who has read one message. Distinct from [receipt], which is how a
  /// reader *reports* a read.
  ///
  /// Returns the stored receipt when there is one. Otherwise [ImErrorCode.messageNotFound] for a
  /// message that is not there (including an unparseable id), [ImErrorCode.receiptDisabled] when it
  /// was not sent with [ImMessageOptions.needReceipt], and an **empty receipt** — no readers,
  /// `readCount` 0 — when nobody has read it yet. Access: [ImErrorCode.invalidArgument],
  /// [ImErrorCode.forbidden], [ImErrorCode.notGroupMember].
  ///
  /// **This read has no cap and truncates nothing.** The group-size limit belongs to the *write*:
  /// `msg.receipt` answers [ImErrorCode.receiptDisabled] in groups larger than the tenant's
  /// `ReceiptGroupMemberLimit` (100 by default), so in such a group nobody's read is ever recorded
  /// and this returns an empty — or frozen — receipt. Read [ImMessageReceipt.totalCount] with its
  /// note: it includes the sender.
  /// 这个读没有上限、不截断；群人数上限卡的是写入（msg.receipt），所以大群里这里读到的是空的或冻结的回执。
  Future<ImMessageReceipt> receiptDetail(
    ImReceiptDetailRequest request, [
    ImCancelToken? cancel,
  ]) =>
      decodeOne('msg.receiptDetail', request.toJson(), cancel, ImMessageReceipt.fromJson);
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

  /// `conv.markUnread` (T3). Marks a conversation unread by hand — the "remind me later" swipe — or
  /// clears that mark with [ImMarkUnreadRequest.unread] false.
  ///
  /// The mark surfaces as [ImConversationView.manuallyUnread], and an `unreadCount` that would
  /// otherwise be 0 displays as 1. It does **not** move `readSeq`, so the other side's read
  /// receipts are unaffected; [read], [delete] and [clear] all clear it. Setting the value it
  /// already has succeeds and sends no event; a change goes to the caller's other devices as
  /// `evt.conversationUpdate` with kind `"unread"`. Access: [ImErrorCode.invalidArgument],
  /// [ImErrorCode.forbidden], [ImErrorCode.notGroupMember].
  /// 不移动 readSeq，对方的已读回执不受影响；conv.read / delete / clear 都会清掉这个标记。
  Future<void> markUnread(ImMarkUnreadRequest request, [ImCancelToken? cancel]) =>
      sendUnit('conv.markUnread', request.toJson(), cancel);
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

  /// `user.setStatus` (T3). Sets the caller's own status line; `const ImSetStatusRequest()` clears
  /// it.
  ///
  /// **It expires after seven days, silently.** The server stores it with a TTL and nothing tells
  /// the user it went, so an application that wants it to persist sets it again on login.
  ///
  /// More than 64 characters is [ImErrorCode.invalidArgument]; [ImErrorCode.serviceUnavailable]
  /// when the presence store is down. Subscribers see it as [ImPresenceState.customStatus] on
  /// `evt.presence`. Like [subscribePresence], this call does **not** check `EnablePresence` while
  /// [presence] does, so a successful set does not mean anyone can read it.
  /// 七天后静默过期：服务端带 TTL 存储、不会通知任何人。要长期保留，就在每次登录时重新设置。
  Future<void> setStatus(ImSetStatusRequest request, [ImCancelToken? cancel]) =>
      sendUnit('user.setStatus', request.toJson(), cancel);
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

  /// `friend.setRemark` (T3). Renames a contact and re-files their tags. Visible only to the
  /// caller: the `evt.friend` frame (`action: "updated"`) goes to the caller's own devices and never
  /// to the contact.
  ///
  /// **A null remark clears it; null tags keep them** — so to change only the tags, send the
  /// current remark along. [ImErrorCode.invalidArgument] for a remark over 64 characters (refused,
  /// not truncated), more than 20 tags, or a tag blank or over 32; [ImErrorCode.notFriend] when
  /// they are not a contact.
  /// remark 为空会清空备注，tags 为空则不动——只改标签时要把现有备注一起带上。
  Future<void> setRemark(ImSetRemarkRequest request, [ImCancelToken? cancel]) =>
      sendUnit('friend.setRemark', request.toJson(), cancel);
}

// ---------------------------------------------------------------------------- group

/// `group.*` — the ten calls that turn a 1:1 chat into a messenger (T2), and administration:
/// ownership, roles, mutes, nicknames, announcements and join requests (T3).
///
/// Most of the administration calls are owner-or-admin ([ImErrorCode.noGroupPermission]
/// otherwise); the group-level refusals are [ImErrorCode.groupNotFound],
/// [ImErrorCode.groupDismissed] and [ImErrorCode.notGroupMember] (the caller or the target is not
/// a member). Each method names what is specific to it. Every successful change is announced to
/// the group as a notification message (`contentType` 9) carrying its own code in `content.code`.
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

  // ---- T3: administration

  /// `group.transfer` (T3). Hands the group to another member. **Owner only**
  /// ([ImErrorCode.noGroupPermission]), and not repeatable: a retry after it succeeded is
  /// [ImErrorCode.noGroupPermission] too, because the caller is no longer the owner.
  ///
  /// The outgoing owner becomes a plain **member**, not an admin — grant it back with [setRole] if
  /// that is what you want. Transferring to yourself is [ImErrorCode.invalidArgument]; to a
  /// non-member, [ImErrorCode.notGroupMember]. Announced as notification 1511.
  /// 原群主降为普通成员而不是管理员；成功后重试会得到 1504，因为调用者已不再是群主。
  Future<void> transfer(ImTransferOwnerRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.transfer', request.toJson(), cancel);

  /// `group.applicationList` (T3). Join requests awaiting — and already given — an answer, newest
  /// first.
  ///
  /// **The request is optional, and an empty `groupId` is meaningful**: without one it lists across
  /// every group the caller manages (only the first 200 groups they have joined are looked at).
  /// With a `groupId` the caller must be its owner or an admin
  /// ([ImErrorCode.noGroupPermission]).
  ///
  /// **It returns every status, not only pending**: filter on
  /// `status == ImApplicationStatus.pending` for a "waiting for you" list. A `limit` of 1–200 is
  /// kept; anything else becomes 50.
  /// 返回所有状态而不只是待处理的：「等你处理」要自己筛 pending。
  Future<ImPage<ImGroupApplication>> applicationList([
    ImGroupCursorRequest request = const ImGroupCursorRequest(groupId: ''),
    ImCancelToken? cancel,
  ]) =>
      decodePage(
        'group.applicationList',
        request.toJson(),
        cancel,
        ImGroupApplication.fromJson,
      );

  /// `group.handleApplication` (T3). Accepts or rejects one join request. Owner or admin
  /// ([ImErrorCode.noGroupPermission]).
  ///
  /// [ImErrorCode.applicationNotFound] when there is no such request, [ImErrorCode.conflict] when it
  /// was already handled. A rejection is stored with its reason and **tells nobody**. An acceptance
  /// adds the member and announces 1513 — unless the group is full ([ImErrorCode.groupFull]), in
  /// which case the request stays pending.
  Future<void> handleApplication(
    ImHandleApplicationRequest request, [
    ImCancelToken? cancel,
  ]) =>
      sendUnit('group.handleApplication', request.toJson(), cancel);

  /// `group.setRole` (T3). Promotes a member to admin or demotes an admin. **Owner only**
  /// ([ImErrorCode.noGroupPermission]).
  ///
  /// The role is asserted to be [ImGroupRole.member] or [ImGroupRole.admin] — see
  /// [ImSetRoleRequest.role] for why. Ownership moves only with [transfer]; [ImGroupRole.owner]
  /// here is [ImErrorCode.unsupportedOperation]. A non-member target is
  /// [ImErrorCode.notGroupMember]; the owner as target — including the owner naming themselves — is
  /// [ImErrorCode.cannotOperateOwner]. Setting the role somebody already has succeeds and announces
  /// nothing; otherwise 1507 announces a promotion to admin and 1508 anything else.
  Future<void> setRole(ImSetRoleRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.setRole', request.toJson(), cancel);

  /// `group.mute` (T3). Mutes or unmutes the whole group. Owner or admin
  /// ([ImErrorCode.noGroupPermission]); they can still send while it is on, and members get
  /// [ImErrorCode.groupMuted].
  ///
  /// **A past `untilMs` means indefinitely, not "unmute"** — see [ImMuteGroupRequest.untilMs];
  /// unmuting is `mute: false`. Every call writes and announces 1509, even when nothing changed.
  /// 过去的 untilMs 是「无限期」而不是「解除」；解除请发 mute: false。
  Future<void> mute(ImMuteGroupRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.mute', request.toJson(), cancel);

  /// `group.muteMember` (T3). Mutes one member until a time, or unmutes them. Owner or admin
  /// ([ImErrorCode.noGroupPermission]); an admin cannot mute another admin (the same code), nobody
  /// can mute the owner ([ImErrorCode.cannotOperateOwner]), and muting yourself is
  /// [ImErrorCode.unsupportedOperation].
  ///
  /// **No `untilMs`, or a past one, unmutes** — the opposite reading from [mute]. There is no
  /// indefinite member mute; send a far-future time. The muted member's sends fail
  /// [ImErrorCode.memberMuted]. Announced as 1510.
  Future<void> muteMember(ImMuteMemberRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.muteMember', request.toJson(), cancel);

  /// `group.setNickname` (T3). Sets somebody's nickname inside the group — the caller's own when
  /// `userId` is null, which any member may do. Anybody else's needs owner or admin and outranking
  /// them ([ImErrorCode.noGroupPermission] / [ImErrorCode.cannotOperateOwner]).
  ///
  /// Trimmed; blank clears it; **over 64 characters is truncated, not refused**. Announced as 1506
  /// with `fields: ["Nickname"]` — capitalised, as the server writes it.
  Future<void> setNickname(ImSetGroupNicknameRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.setNickname', request.toJson(), cancel);

  /// `group.announcement` (T3). Replaces the group's announcement. Owner or admin
  /// ([ImErrorCode.noGroupPermission]).
  ///
  /// Trimmed; null or blank clears it; **over 4096 characters is truncated, not refused**. Moves
  /// [ImGroup.announcementUpdatedAt]. Every call announces 1512 carrying the text, even when nothing
  /// changed.
  Future<void> announcement(ImAnnouncementRequest request, [ImCancelToken? cancel]) =>
      sendUnit('group.announcement', request.toJson(), cancel);
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
