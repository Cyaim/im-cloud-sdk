import 'dart:async';
import 'dart:math';

import 'api.dart';
import 'cancel.dart';
import 'connection.dart';
import 'cursor_store.dart';
import 'cursors.dart';
import 'models.dart';
import 'options.dart';
import 'protocol.dart';
import 'requests.dart';

/// The client applications use.
///
/// Beyond wrapping commands, this owns the one thing every correct IM client must do and most
/// hand-rolled ones do not: it keeps two cursors per conversation, notices when an arriving message
/// skips a number, pulls the missing range before delivering it, and — the part four of the five
/// Cyaim SDKs used to get wrong — **remembers those cursors across a process restart.**
///
/// A client that cold-starts with no cursors reports nothing in `conn.sync`, gets no gap back
/// (the server can only diff against what you tell it), adopts the server's newest `maxSeq`, and
/// silently skips every message that arrived while the app was closed. No error, no log line,
/// nothing later that corrects it. [ImOptions.cursorStore] is a required argument because that is
/// the only fix that cannot be forgotten.
///
/// 客户端必须做、而多数自研客户端没做的事：按会话记录游标并跨进程持久化。
/// 冷启动时不上报游标，服务端就报不出空洞，客户端会直接采纳最新 seq——离线期间的消息全部静默丢失。
///
/// Delivery is **at-least-once**. The application must be idempotent on
/// [ImMessage.messageId], and must call [commit] once a message is durably in its own store.
class ImClient {
  ImClient(this.options)
      : _connection = ImConnection(options),
        _cursors = ImCursors(
          options.cursorStore,
          scope: ImCursorScope.of(
            endpoint: options.endpoint,
            appId: options.appId,
            userId: options.userId,
          ),
          debounce: options.cursorSaveDebounce,
          onWarning: options.logger,
        ) {
    conn = ImConnApi(_connection);
    msg = ImMsgApi(_connection);
    conv = ImConvApi(_connection);
    user = ImUserApi(_connection);
    friend = ImFriendApi(_connection);
    group = ImGroupApi(_connection);
    media = ImMediaApi(_connection);
    push = ImPushApi(
      _connection,
      isConnected: () => _connection.state == ImConnectionState.open,
      logger: options.logger,
    );

    _cursors.onSaveError = (Object error) => _raise(ImException(
          ImErrorCode.serviceUnavailable,
          'the cursor store failed to save ($error). Cursors are correct in memory but will not '
          'survive a restart, which is the state that loses messages.',
        ));

    _connection.on(ImPushTarget.message, _handleMessage);
    _states = _connection.states.listen((ImConnectionState state) {
      if (state == ImConnectionState.open) unawaited(_onConnected());
    });
  }

  /// `conn.sync` returns at most 200 conversations per page and clamps anything outside 1…500 to
  /// 200, so asking for 200 is asking for what you will get.
  static const int _resumePageLimit = 200;

  /// `MessageService.SyncAsync` clamps `limit` to 500. Asking for more silently returns 500 and an
  /// SDK that ignored `hasMore` would leave the rest as a permanent hole.
  static const int _msgSyncPageLimit = 500;

  /// A `conn.sync` run that pages this many times has met a server bug, not a large account:
  /// 200 conversations a page is 40,000 conversations. Stopping is right, and stopping *without*
  /// advancing `conversationCursor` is what makes the next run re-read rather than skip.
  static const int _maxResumePages = 200;

  final ImOptions options;
  final ImConnection _connection;
  final ImCursors _cursors;

  /// `conn.*` — heartbeat, reauth, sync.
  late final ImConnApi conn;

  /// `msg.*` — send, sync, history, recall, delete, typing, edit, forward, react, receipt.
  late final ImMsgApi msg;

  /// `conv.*` — list, get, read, unreadTotal, setting, delete, clear.
  late final ImConvApi conv;

  /// `user.*` — me, profile, batchProfile, updateProfile, presence, subscribe/unsubscribe.
  late final ImUserApi user;

  /// `friend.*` — contacts, applications, blocklist.
  late final ImFriendApi friend;

  /// `group.*` — create, info, update, dismiss, memberList, joined, invite, kick, quit, join.
  late final ImGroupApi group;

  /// `media.*` — upload tickets and download URLs.
  late final ImMediaApi media;

  /// `push.*` — offline notification registration. See [ImPushApi] for the token lifecycle.
  late final ImPushApi push;

  /// One in-flight worker per conversation. This is what guarantees the ordering rule: for a given
  /// conversation, messages reach the application in seq order and never concurrently, a live
  /// message arriving during a repair is held and delivered after it, and two repairs for one
  /// conversation never run at once.
  final Map<String, Future<void>> _lanes = <String, Future<void>>{};

  final StreamController<ImMessage> _messages = StreamController<ImMessage>.broadcast();
  final StreamController<ImException> _errors = StreamController<ImException>.broadcast();
  final StreamController<String> _reloads = StreamController<String>.broadcast();

  StreamSubscription<ImConnectionState>? _states;
  Future<void>? _loading;
  bool _closed = false;

  ImConnectionState get state => _connection.state;

  Stream<ImConnectionState> get states => _connection.states;

  Stream<ImKickEvent> get kicks => _connection.kicks;

  /// Every message, in seq order per conversation, gaps already repaired.
  ///
  /// Delivery is at-least-once: a reconnect redelivers anything the application received but never
  /// [commit]ted. Deduplicate on [ImMessage.messageId].
  Stream<ImMessage> get messages => _messages.stream;

  /// Session-level failures that no single call is waiting on: a cursor store that would not load,
  /// a `conn.sync` run that was interrupted, a repair that failed.
  ///
  /// These are surfaced rather than logged because §5.8 requires it — a store that failed to load
  /// looks exactly like a fresh install to the adoption branch, and only the application can decide
  /// whether to re-derive its cursors from its own database or accept a re-download.
  Stream<ImException> get errors => _errors.stream;

  /// A conversation the SDK deliberately did **not** backfill: the gap was wider than
  /// [ImOptions.maxAutoRepairSeq], or a repair loop hit its iteration cap.
  ///
  /// The cursor has been advanced past the hole and committed, so no later message will look like
  /// a gap — which means **nothing else will ever mention this**. Reload the conversation from
  /// `msg.history`. Both halves are mandatory and this event is the half an application cannot
  /// reconstruct for itself.
  /// 这段消息 SDK 主动不补，游标已经推过去了；不重新拉取就是 UI 上一个永远没人提起的洞。
  Stream<String> get conversationNeedsReload => _reloads.stream;

  /// Any other server event, decoded from the frame's payload.
  ///
  /// The underlying subscription is created when the stream is first listened to and torn down
  /// when the last listener leaves, so a caller that stops listening stops costing anything —
  /// a controller wired up eagerly would keep the connection callback alive forever.
  Stream<Map<String, dynamic>> events(String target) {
    late final StreamController<Map<String, dynamic>> controller;
    void Function()? unsubscribe;

    controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        unsubscribe = _connection.on(target, (ImFrame frame) {
          final Object? data = frame.body?.data;
          if (data is Map<String, dynamic> && !controller.isClosed) controller.add(data);
        });
      },
      onCancel: () async {
        unsubscribe?.call();
        unsubscribe = null;
        await controller.close();
      },
    );

    return controller.stream;
  }

  /// Loads the cursor store, then opens the socket. Idempotent.
  Future<void> connect() async {
    await _loadCursors();
    await _connection.connect();
  }

  /// Closes the socket and flushes cursors. The client stays usable — call [connect] again.
  ///
  /// **Disconnecting never unregisters the push token**, and that is the entire point of a push
  /// token: a dead socket is precisely the state offline push exists to serve. Use [logout] when
  /// the user is actually leaving.
  Future<void> disconnect() async {
    await _cursors.flush();
    await _connection.close();
  }

  /// Ends the session properly: `push.unregister` **first**, then close.
  ///
  /// The order is not stylistic. After the socket closes there is no authenticated channel and the
  /// SDK cannot remove the token at all — the user keeps getting notifications on a handset they
  /// logged out of, and only the tenant backend can clean that up afterwards with
  /// `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
  ///
  /// [clearCursors] defaults to false, matching the lifetime rule in §5.3: **the cursor store and
  /// the application's message store have exactly one lifetime.** Pass true only if this logout
  /// also clears the local messages. An app that keeps messages for a fast re-login keeps the
  /// cursors too — clearing one and not the other leaves either an empty conversation that never
  /// refills, or a full re-download.
  ///
  /// 登出必须先 push.unregister 再断开：断开之后没有已鉴权的通道，token 就再也删不掉了。
  Future<void> logout({bool clearCursors = false}) async {
    if (_connection.state == ImConnectionState.open && push.token != null) {
      try {
        await push.unregister();
      } catch (error) {
        options.logger(
          'push.unregister failed on logout: $error. The token stays registered until the tenant '
          'backend removes it with DELETE /v1/users/{userId}/push-tokens/{deviceId}.',
        );
      }
    }

    push.clearToken();

    if (clearCursors) {
      await _cursors.clear();
    } else {
      await _cursors.flush();
    }

    await _connection.close();
  }

  /// Final teardown. Closes the event streams; the client cannot be reused afterwards.
  ///
  /// Separate from [disconnect] because closing the message stream on an ordinary disconnect would
  /// mean a reconnect delivers nothing — connect and disconnect are meant to be a pair you can run
  /// as often as the network requires.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;

    await _states?.cancel();
    _states = null;
    await _connection.close();
    _cursors.dispose();
    await _messages.close();
    await _errors.close();
    await _reloads.close();
  }

  // ---------------------------------------------------------------- cursors

  /// Tells the SDK that everything up to [seq] in [conversationId] is **durably stored by the
  /// application**. Monotonic: a lower seq is ignored, not an error.
  ///
  /// Call it after your own write completes, not when the listener returns. A callback returning
  /// means the message reached your process's memory, which is exactly the state a crash loses,
  /// and the SDK will not infer durability from it — a cursor that is confidently wrong is worse
  /// than one that is behind.
  ///
  /// 请在自己写库成功之后调用，而不是在回调返回时。回调返回只说明消息进了内存，崩溃就没了。
  Future<void> commit(String conversationId, int seq) => _cursors.commit(conversationId, seq);

  /// Highest seq handed to the application in this process. In memory only.
  int deliveredSeq(String conversationId) => _cursors.deliveredOf(conversationId);

  /// Highest seq the application has [commit]ted. This, and only this, is reported to the server.
  int committedSeq(String conversationId) => _cursors.committedOf(conversationId);

  /// The cursors as they stand, for a diagnostics screen or an export.
  ImCursorSnapshot get cursors => _cursors.snapshot;

  /// True when [ImOptions.cursorStore] failed to load and every cursor is frozen for this session.
  ///
  /// The SDK will not adopt and will not advance anything while this is true, because a failed
  /// load and a fresh install are indistinguishable to the adoption branch and adopting on a failed
  /// load destroys history sitting intact in the application's own database. Re-derive your
  /// cursors with [commit] — it is monotonic precisely so you can — or accept a re-download.
  bool get cursorsFrozen => _cursors.loadFailed;

  /// True when the store held cursors for a different `(host, appId, userId)` and the SDK discarded
  /// them rather than replaying another account's position into this one (§5.3).
  ///
  /// Worth surfacing: it means this account re-downloads, and it means the store is shared across
  /// logins where it should be keyed per account with [ImCursorScope.storageKey].
  bool get cursorScopeRejected => _cursors.foreignScopeRejected;

  /// Writes any debounced commit through now. **Call this from the platform's background/suspend
  /// signal** (`AppLifecycleState.paused`), where a mobile OS may stop the process without warning.
  Future<void> flushCursors() => _cursors.flush();

  /// Drops every cursor and empties the store. Use it only alongside clearing the application's
  /// own messages — see [logout].
  Future<void> clearCursors() => _cursors.clear();

  // ---------------------------------------------------------------- legacy flat surface
  //
  // These nine predate the namespaced surface and appear in every README and sample, so they stay
  // and delegate. They are the only permitted deviation from "the method name is the endpoint's
  // method part" (sdk/CONTRACT.md §4.2) — and note that four of them (setTyping, conversations,
  // markRead, totalUnread) already drifted from their endpoint names, which is the drift that rule
  // exists to stop. New code should use im.msg / im.conv.
  // 这九个是历史遗留的扁平方法，保留并转发；新代码请用命名空间。

  @Deprecated('Use im.msg.send(ImSendMessageRequest(…)). Removed in 2.0.')
  Future<ImSendResult> send({
    String? conversationId,
    String? receiverId,
    String? groupId,
    ImMessageContentType contentType = ImMessageContentType.text,
    required Map<String, dynamic> content,
    String? clientMsgId,
    List<String>? mentionedUserIds,
    bool mentionAll = false,
    String? quoteMessageId,
    Map<String, dynamic>? messageOptions,
  }) =>
      sendRequest(ImSendMessageRequest(
        conversationId: conversationId,
        receiverId: receiverId,
        groupId: groupId,
        contentType: contentType,
        content: content,
        clientMsgId: clientMsgId,
        mentionedUserIds: mentionedUserIds,
        mentionAll: mentionAll,
        quoteMessageId: quoteMessageId,
        options: messageOptions == null ? null : ImMessageOptions.fromJson(messageOptions),
      ));

  @Deprecated('Use im.msg.send(ImSendMessageRequest.text(…)). Removed in 2.0.')
  Future<ImSendResult> sendText({
    String? conversationId,
    String? receiverId,
    String? groupId,
    required String text,
  }) =>
      sendRequest(ImSendMessageRequest.text(
        text,
        conversationId: conversationId,
        receiverId: receiverId,
        groupId: groupId,
      ));

  @Deprecated('Use im.msg.history(ImHistoryRequest(…)). Removed in 2.0.')
  Future<ImPage<ImMessage>> history(
    String conversationId, {
    int? beforeSeq,
    int limit = 20,
  }) =>
      msg.history(ImHistoryRequest(
        conversationId: conversationId,
        beforeSeq: beforeSeq,
        limit: limit,
      ));

  @Deprecated('Use im.msg.recall(ImRecallMessageRequest(…)). Removed in 2.0.')
  Future<void> recall(String conversationId, String messageId, {String? reason}) =>
      msg.recall(ImRecallMessageRequest(
        conversationId: conversationId,
        messageId: messageId,
        reason: reason,
      ));

  @Deprecated('Use im.msg.react(ImReactRequest(…)). Removed in 2.0.')
  Future<void> react(String conversationId, String messageId, String emoji, {bool add = true}) =>
      msg.react(ImReactRequest(
        conversationId: conversationId,
        messageId: messageId,
        emoji: emoji,
        add: add,
      ));

  @Deprecated('Use im.msg.typing(ImTypingRequest(…)). Removed in 2.0.')
  Future<void> setTyping(String conversationId, {bool typing = true}) =>
      msg.typing(ImTypingRequest(conversationId: conversationId, typing: typing));

  @Deprecated('Use im.conv.list(ImListConversationsRequest(…)). Removed in 2.0.')
  Future<ImPage<ImConversationView>> conversations({
    int updatedAfter = 0,
    String? cursor,
    int limit = 50,
  }) =>
      conv.list(ImListConversationsRequest(
        updatedAfter: updatedAfter,
        cursor: cursor,
        limit: limit,
      ));

  @Deprecated('Use im.conv.read(ImReadRequest(…)). Removed in 2.0.')
  Future<void> markRead(String conversationId, int readSeq) =>
      conv.read(ImReadRequest(conversationId: conversationId, readSeq: readSeq));

  @Deprecated('Use im.conv.unreadTotal(). Removed in 2.0.')
  Future<int> totalUnread() => conv.unreadTotal();

  /// `msg.send`, remembering the seq we just wrote so our own message is not treated as a gap.
  ///
  /// Public because the deprecated `send` and `sendText` both need it and neither may call a
  /// deprecated member. Prefer `im.msg.send`, which is the same call without the bookkeeping —
  /// the echo of your own message arrives on [messages] either way.
  Future<ImSendResult> sendRequest(
    ImSendMessageRequest request, [
    ImCancelToken? cancel,
  ]) async {
    final ImSendResult result = await msg.send(request, cancel);

    // Our own message is already in hand, so marking it delivered saves a pointless repair round
    // trip when the next inbound message is seq + 1. It is *not* committed: only the application
    // can say it has stored the thing, and a reconnect will redeliver it if it never did.
    _cursors.markDelivered(result.conversationId, result.seq);
    return result;
  }

  /// Escape hatch for any endpoint the typed surface does not cover yet — the difference between
  /// "wait for the next SDK release" and "ship on Friday".
  ///
  /// It shares one code path with every typed method, so timeouts, cancellation and error mapping
  /// behave identically. It **never** participates in cursor logic: `invoke('msg.sync', …)`
  /// returns messages and moves nothing.
  ///
  /// ```dart
  /// // group.transfer is T3 and not typed yet:
  /// await im.invoke<void>('group.transfer', <String, Object?>{
  ///   'groupId': groupId,
  ///   'newOwnerId': userId,
  /// });
  /// ```
  Future<T> invoke<T>(String target, [Object? body, ImCancelToken? cancel]) =>
      _connection.request<T>(target, body, cancel);

  // ------------------------------------------------------------------ internals

  /// Reads the cursor store exactly once, before the first connect.
  ///
  /// A failure here is surfaced on [errors] and freezes every cursor for the session (§5.8). It
  /// does **not** stop the connect: live delivery still works, and refusing to connect would turn
  /// a recoverable storage problem into a dead app.
  Future<void> _loadCursors() {
    return _loading ??= _cursors.load().catchError((Object error) {
      _raise(ImException(
        ImErrorCode.serviceUnavailable,
        'the cursor store failed to load ($error). No cursor will be adopted or advanced this '
        'session, because a failed load is indistinguishable from a fresh install and adopting '
        'here would discard history you still hold. Re-derive cursors with commit(), or accept a '
        're-download.',
      ));
    });
  }

  Future<void> _onConnected() async {
    // §6.2 rule 1: register on every successful connect, not once at install — the vendor may
    // replace a token while the process is frozen and the server has no other way to learn it.
    // Deliberately not awaited before the resume: a slow push registration must never delay the
    // one path that repairs missing messages.
    unawaited(push.registerOnConnect());

    await _resume();
  }

  /// The `conn.sync` run, exactly as `sdk/CONTRACT.md` §5.6 specifies it.
  ///
  /// The two steps everyone leaves out, and what each costs:
  ///
  /// - **Paging (step 7).** `conn.sync` returns at most 200 conversations a page. A user with more
  ///   gets gaps reported only for the first page; the rest are never repaired.
  /// - **Advancing `conversationCursor` only after a completed run (step 8).** The list is sorted
  ///   by `updatedAt` *descending*, so page 1 holds the newest timestamp. Taking the maximum from
  ///   page 1 and stopping pushes the cursor past every conversation on pages 2…N, and
  ///   `ListUserConversationsAsync` filters `UpdatedAt > updatedAfter` — the server will never
  ///   return them again. Re-reading a page is free; skipping one is permanent.
  ///
  /// 分页必须做完，`conversationCursor` 只能在整轮跑完后推进：列表按 updatedAt 倒序，
  /// 拿第一页的最大值就收工，等于把后面所有页永久跳过。
  Future<void> _resume() async {
    // Runs even when the store failed to load. Nothing is adopted in that state — [ImCursors.adopt]
    // is a no-op — so the run cannot silently baseline anything; and if the application has
    // re-derived cursors with [commit], this is what repairs the gaps they describe.

    // §5.2(2): redelivery only actually reaches the application if the in-memory cursor is pulled
    // back to what was durably stored first. Without this, the repaired messages are dropped as
    // duplicates by the very cursor that was too far ahead.
    _cursors.resetDeliveredToCommitted();
    await _cursors.flush();

    String? cursor;
    int maxUpdatedAt = _cursors.conversationCursor;
    bool completed = false;
    int pages = 0;

    try {
      while (true) {
        final ImResumeResult result = await conn.sync(ImResumeRequest(
          convSeqs: _cursors.convSeqs,
          conversationCursor: _cursors.conversationCursor,
          cursor: cursor,
          limit: _resumePageLimit,
        ));

        final Map<String, int> maxSeqByConversation = <String, int>{};
        bool adopted = false;

        for (final ImConversationView view in result.conversations) {
          maxSeqByConversation[view.conversationId] = view.maxSeq;
          if (view.updatedAt > maxUpdatedAt) maxUpdatedAt = view.updatedAt;

          if (!_cursors.knows(view.conversationId)) {
            // First sight: take the server's maxSeq rather than replaying a whole history into a
            // UI that has never shown it.
            _cursors.adopt(view.conversationId, view.maxSeq);
            adopted = true;
          }
        }

        // Adoption is a commit, and **its write is not debounced**. If an adoption write is lost,
        // the next cold start sees no entry, adopts a *newer* maxSeq, and silently drops
        // everything in between — the original bug, re-created by the optimisation.
        if (adopted) await _cursors.flush();

        for (final MapEntry<String, int> gap in result.gapsFrom.entries) {
          await _repairConversation(
            gap.key,
            gap.value,
            maxSeqByConversation[gap.key] ?? 0,
          );
        }

        if (!result.hasMore) {
          completed = true;
          break;
        }

        final String? next = result.nextCursor;
        if (next == null || next == cursor) {
          // hasMore with no usable cursor is a server fault. Stopping is right; pretending the run
          // finished is not, so conversationCursor stays where it was and the next run re-reads.
          _raise(const ImException(
            ImErrorCode.internalError,
            'conn.sync reported hasMore with no usable nextCursor; the resume run is incomplete',
            target: 'conn.sync',
          ));
          break;
        }

        cursor = next;

        if (++pages >= _maxResumePages) {
          _raise(const ImException(
            ImErrorCode.internalError,
            'conn.sync paged past the safety limit; the resume run is incomplete',
            target: 'conn.sync',
          ));
          break;
        }
      }
    } catch (error) {
      // An interrupted run — disconnect, error, cancellation — must leave conversationCursor
      // untouched. Anything already repaired and committed stays committed; that is safe, because
      // commits are per conversation and monotonic.
      _raise(_asImException(error, 'conn.sync'));
      return;
    }

    if (completed) await _cursors.setConversationCursor(maxUpdatedAt);
  }

  /// Runs a repair on the conversation's own lane, so a live message that arrives mid-repair is
  /// held and delivered after it rather than jumping ahead of it.
  Future<void> _repairConversation(String conversationId, int fromSeq, int toSeq) =>
      _enqueue(conversationId, () => _repair(conversationId, fromSeq, toSeq));

  /// Backfills `[fromSeq, toSeq]`, paging `msg.sync` until it says it is done.
  ///
  /// Must be called from inside the conversation's lane — [_repairConversation] and [_processLive]
  /// are the two entry points, and the live path and the resume path deliberately share this one
  /// implementation. A live gap and a resume gap are the same defect and must get the same
  /// treatment, including the oversized case.
  Future<void> _repair(String conversationId, int fromSeq, int toSeq) async {
    final int span = toSeq - fromSeq + 1;
    if (span <= 0) return;

    if (span > options.maxAutoRepairSeq) {
      await _declineRepair(conversationId, toSeq);
      return;
    }

    // `hasMore` is computed on the raw window before per-user hidden messages are filtered out, so
    // a page can be short — even empty — and still have more behind it. Loop on hasMore, never on
    // messages.length. The cap is what stops a server bug spinning the client forever.
    final int cap = (span / _msgSyncPageLimit).ceil() + 2;
    int cursor = fromSeq;
    int iterations = 0;

    while (cursor <= toSeq) {
      if (++iterations > cap) {
        await _declineRepair(conversationId, toSeq);
        return;
      }

      final int limit = min(toSeq - cursor + 1, _msgSyncPageLimit);
      final ImSyncMessagesResult page = await msg.sync(ImSyncMessagesRequest(
        conversationId: conversationId,
        fromSeq: cursor,
        toSeq: toSeq,
        limit: limit,
        ascending: true,
      ));

      for (final ImMessage message in page.messages) {
        _deliver(message);
      }

      if (!page.hasMore) return;

      final int highest = page.messages.isEmpty
          ? page.maxSeq
          : page.messages.map((ImMessage m) => m.seq).reduce(max);

      // Never move backwards, and never stand still: an empty page whose maxSeq is behind the
      // cursor would otherwise loop until the cap.
      cursor = highest + 1 > cursor ? highest + 1 : cursor + limit;
    }
  }

  /// The gap is wider than we are willing to backfill. **Both halves of this are mandatory.**
  ///
  /// Advancing and committing the cursor stops every later message looking like a gap and
  /// re-requesting a range we have already declined; raising the event is the only way the
  /// application ever learns there is a hole to refill.
  Future<void> _declineRepair(String conversationId, int toSeq) async {
    await _cursors.commit(conversationId, toSeq);
    if (!_reloads.isClosed) _reloads.add(conversationId);
  }

  void _handleMessage(ImFrame frame) {
    final Object? data = frame.body?.data;
    if (data is! Map<String, dynamic>) return;

    final ImMessage message = ImMessage.fromJson(data);

    // seq 0 means the message was never persisted (typing, presence, chat-room traffic). It
    // bypasses the cursor machinery *and* the ordering lane: it carries no position, so it cannot
    // be ordered against anything, and holding it behind a repair would only deliver it late.
    if (message.seq == 0) {
      _emit(message);
      return;
    }

    unawaited(_enqueue(message.conversationId, () => _processLive(message)));
  }

  Future<void> _processLive(ImMessage message) async {
    final String conversationId = message.conversationId;
    final int delivered = _cursors.deliveredOf(conversationId);

    // Already seen. Duplicates are routine after a reconnect replay and must be silent.
    if (message.seq <= delivered && delivered > 0) return;

    if (delivered > 0 && message.seq > delivered + 1) {
      await _repair(conversationId, delivered + 1, message.seq - 1);

      // The repair may have carried us past this message already — a decline sets the cursor to
      // the conversation's maxSeq.
      if (message.seq <= _cursors.deliveredOf(conversationId)) return;
    }

    _deliver(message);
  }

  void _deliver(ImMessage message) {
    if (message.seq > 0) {
      final int delivered = _cursors.deliveredOf(message.conversationId);
      if (delivered > 0 && message.seq <= delivered) return;
      _cursors.markDelivered(message.conversationId, message.seq);
    }

    _emit(message);
  }

  /// Serialises work per conversation.
  ///
  /// A failed repair deliberately does **not** advance any cursor and does not deliver the message
  /// that triggered it. Delivering it would move the cursor past the hole and the gap would never
  /// be detected again — a silent permanent loss for a failure that was probably transient. Left
  /// alone, the next message in that conversation sees the same (wider) gap and retries, and a
  /// reconnect's `conn.sync` reports it too.
  /// 补洞失败时不推进游标、也不投递触发它的那条消息：投递就等于把洞永久跳过。
  Future<void> _enqueue(String conversationId, Future<void> Function() work) {
    final Future<void> previous = _lanes[conversationId] ?? Future<void>.value();

    final Future<void> next = previous.then((_) => work()).catchError((Object error) {
      _raise(_asImException(error, null));
    });

    _lanes[conversationId] = next;
    unawaited(next.whenComplete(() {
      if (identical(_lanes[conversationId], next)) _lanes.remove(conversationId);
    }));

    return next;
  }

  void _emit(ImMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  void _raise(ImException error) {
    if (_errors.isClosed) return;
    if (_errors.hasListener) {
      _errors.add(error);
      return;
    }

    // An error nobody is listening for still has to be visible; the alternative is the silence
    // this whole section exists to remove.
    options.logger('$error');
  }

  static ImException _asImException(Object error, String? target) {
    if (error is ImException) return error;
    return ImException(ImErrorCode.internalError, '$error', target: target);
  }
}
