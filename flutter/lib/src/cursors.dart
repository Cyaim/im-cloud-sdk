import 'dart:async';

import 'cursor_store.dart';
import 'logging.dart';

/// The two cursors, per conversation, and the rules that keep them honest.
///
/// This is the whole of `sdk/CONTRACT.md` §5 that is not I/O, kept in one object so the resume
/// path and the live path cannot drift into two different interpretations of it — five
/// interpretations is how the data-loss bug this replaces came to exist.
///
/// - **`deliveredSeq`** — highest seq handed to the application *in this process*. In memory only.
///   Drives gap detection and duplicate suppression.
/// - **`committedSeq`** — highest seq the application has said it durably stored. Written through
///   to the [ImCursorStore], and the only value ever reported in `convSeqs`.
///
/// Invariants, enforced here rather than at each call site:
///
/// 1. `committedSeq <= deliveredSeq`, always.
/// 2. Before every `conn.sync`, [resetDeliveredToCommitted] runs. Without it, redelivered messages
///    are dropped as duplicates by the very cursor that was too far ahead.
/// 3. [convSeqs] is built from `committedSeq`, never from `deliveredSeq`.
///
/// Delivery is therefore **at-least-once**, and the application must be idempotent on `messageId`.
///
/// 两个游标：deliveredSeq 只在内存里，committedSeq 由应用确认落库后写入存储；
/// 上报给 conn.sync 的永远是后者。因此投递是至少一次，应用需按 messageId 幂等。
class ImCursors {
  ImCursors(
    this.store, {
    required this.scope,
    Duration debounce = const Duration(milliseconds: 1000),
    void Function(String message)? onWarning,
  })  : _debounce = debounce,
        _warn = onWarning ?? defaultImLogger;

  final ImCursorStore store;

  /// Who this session is. Stamped onto every snapshot written, checked against every one read.
  final ImCursorScope scope;

  final void Function(String message) _warn;

  /// Where a failed [ImCursorStore.save] goes. A write that fails silently is the same defect as
  /// a write that never happened, and nothing is awaiting the debounced ones. Assigned by
  /// [ImClient] after construction, because a closure over the client cannot be built before the
  /// client exists.
  void Function(Object error)? onSaveError;

  /// How long ordinary commits may be coalesced before they must reach the store.
  ///
  /// The asymmetry with adoption is deliberate and worth stating where it is implemented: **a lost
  /// debounced commit costs one duplicate delivery; a lost adoption costs silent permanent data
  /// loss.** That is the entire reason one is allowed to be lossy and the other is not.
  /// 丢一次去抖后的 commit = 一条重复投递；丢一次 adopt = 永久静默丢消息。
  final Duration _debounce;

  final Map<String, int> _delivered = <String, int>{};
  final Map<String, int> _committed = <String, int>{};

  int _conversationCursor = 0;
  bool _loaded = false;
  bool _loadFailed = false;
  bool _foreignScopeRejected = false;
  bool _dirty = false;
  Timer? _debounceTimer;
  Future<void> _writing = Future<void>.value();

  /// True when [load] threw.
  ///
  /// The SDK then refuses to move a cursor **by itself** for the rest of the session: [adopt] and
  /// [setConversationCursor] become no-ops. §5.8 — a failed load and a fresh install are
  /// indistinguishable to the adoption branch, and adopting on a failed load discards history that
  /// is sitting intact in the application's own database.
  ///
  /// [commit] keeps working, and that is deliberate: re-deriving cursors from the application's own
  /// message store is the sanctioned recovery, and the reason [commit] is monotonic in the first
  /// place. Blocking it would leave the application no way out.
  ///
  /// 加载失败后 SDK 不再自行推进游标；应用仍可用 commit() 从自己的库里重建，这是既定的补救路径。
  bool get loadFailed => _loadFailed;

  /// True once [load] has completed, successfully or not.
  bool get isLoaded => _loaded;

  /// True when the store held cursors belonging to a different `(host, appId, userId)` and they
  /// were discarded rather than replayed into this account (§5.3).
  ///
  /// Distinct from both "fresh install" and "the store is broken": it means the store is shared
  /// across logins when it should be keyed per account, and that this account will re-download.
  bool get foreignScopeRejected => _foreignScopeRejected;

  /// `committedSeq` per conversation — what `conn.sync` reports, and nothing else.
  Map<String, int> get convSeqs => Map<String, int>.unmodifiable(_committed);

  /// The current in-memory view, for an application that wants to inspect or export it.
  ImCursorSnapshot get snapshot => ImCursorSnapshot(
        convSeqs: Map<String, int>.of(_committed),
        conversationCursor: _conversationCursor,
        scope: scope.key,
      );

  int get conversationCursor => _conversationCursor;

  int deliveredOf(String conversationId) => _delivered[conversationId] ?? 0;

  int committedOf(String conversationId) => _committed[conversationId] ?? 0;

  /// True when the loaded snapshot, or this session, already knows this conversation. False is
  /// what triggers adoption (§5.5), so it must never be true for a conversation the store failed
  /// to tell us about — which is why [loadFailed] blocks adoption outright instead of relying on
  /// this.
  bool knows(String conversationId) => _committed.containsKey(conversationId);

  /// Reads the store exactly once. Rethrows whatever the store threw, after marking the session
  /// frozen, so the caller can surface it to the application.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    if (store is ImInMemoryCursorStore) {
      _warn(
        'ImCursorStore.inMemory(): cursors are NOT persisted. On the next cold start this client '
        "will adopt the server's newest seq for every conversation and every message that arrived "
        'while the app was closed will be skipped, silently. See sdk/CONTRACT.md §5.3.',
      );
    }

    try {
      final ImCursorSnapshot loaded = await store.load();

      // The account-switch guarantee, §5.3. The snapshot carries the identity the SDK stamped on
      // it, so a store that does nothing to keep two accounts apart still cannot hand one user the
      // other's position. The worst a shared store can do is cost the earlier account a
      // re-download — loud, in the log, and recoverable; inherited cursors are silent, permanent
      // and look exactly like a working client.
      // 快照自带身份：即使存储没有按账号隔离，也不会把上一个账号的游标交给下一个账号。
      final String? stamped = loaded.scope;
      if (stamped != null && stamped != scope.key) {
        _foreignScopeRejected = true;
        _warn(
          'the cursor store holds cursors for "$stamped" but this session is "${scope.key}"; '
          "starting clean rather than replaying another account's position. Key the store per "
          'account with ImCursorScope.storageKey. See sdk/CONTRACT.md §5.3.',
        );
        return;
      }

      _committed
        ..clear()
        ..addAll(loaded.convSeqs);
      _delivered
        ..clear()
        ..addAll(loaded.convSeqs);
      _conversationCursor = loaded.conversationCursor;
    } catch (_) {
      _loadFailed = true;
      rethrow;
    }
  }

  /// §5.2(2). Runs before every `conn.sync`, including the first.
  ///
  /// A message delivered to the application but never committed — the app was mid-write, or
  /// crashed, or simply had not got to it — must be delivered again. Leaving `deliveredSeq` where
  /// it was makes the redelivery look like a duplicate and drops it, which turns at-least-once
  /// into at-most-once at exactly the moment at-least-once was the point.
  void resetDeliveredToCommitted() {
    _delivered
      ..clear()
      ..addAll(_committed);
  }

  /// Records that [seq] reached the application. Never written to the store.
  void markDelivered(String conversationId, int seq) {
    if (seq <= (_delivered[conversationId] ?? 0)) return;
    _delivered[conversationId] = seq;
  }

  /// The application has durably stored everything up to [seq]. Monotonic: a lower seq is ignored
  /// rather than an error, so an app re-deriving cursors from its own database can call this in
  /// any order.
  ///
  /// The SDK never calls this on its own from the fact that a listener returned. A callback
  /// returning means the message reached the app's *memory*, which is precisely the state a crash
  /// loses; inferring durability from it is how you get a cursor that is confidently wrong.
  /// The one exception is [adopt], where the application has nothing to store.
  Future<void> commit(String conversationId, int seq) {
    if (seq <= (_committed[conversationId] ?? 0)) return Future<void>.value();

    _committed[conversationId] = seq;
    markDelivered(conversationId, seq);
    return _scheduleSave();
  }

  /// First sight of a conversation: take the server's `maxSeq` as both cursors rather than
  /// replaying a whole history into a UI that has never shown it.
  ///
  /// Adoption is a commit the SDK makes on the application's behalf, and **its write must not be
  /// debounced** — the caller flushes before requesting the next `conn.sync` page. A lost adoption
  /// write means the next cold start sees no entry, adopts a *newer* `maxSeq`, and silently drops
  /// everything in between: the original bug, re-created by the optimisation.
  void adopt(String conversationId, int seq) {
    if (_loadFailed) return;

    _committed[conversationId] = seq;
    _delivered[conversationId] = seq;
    _dirty = true;
  }

  /// §5.6 step 8. Only ever called after a `conn.sync` run reached `hasMore == false`.
  ///
  /// Monotonic for the same reason [commit] is: an interrupted run must leave this untouched, and
  /// "untouched" has to survive a later run that saw fewer conversations.
  Future<void> setConversationCursor(int updatedAt) {
    // SDK-driven, so it stops with everything else the SDK drives when the store would not load.
    if (_loadFailed) return Future<void>.value();
    if (updatedAt <= _conversationCursor) return Future<void>.value();

    _conversationCursor = updatedAt;
    return _scheduleSave();
  }

  /// Writes any pending change through now and waits for it.
  ///
  /// Called before every `conn.sync`, after every adoption, and on the host app's
  /// background/suspend signal — see [ImClient.flushCursors].
  Future<void> flush() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_dirty) return _writing;

    _dirty = false;
    final ImCursorSnapshot pending = snapshot;
    _writing = _writing.then((_) => store.save(pending)).catchError(_reportSaveError);
    return _writing;
  }

  /// Drops every cursor. Used by a logout that also clears the application's messages — the two
  /// stores have one lifetime, and this half goes first.
  Future<void> clear() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _delivered.clear();
    _committed.clear();
    _conversationCursor = 0;
    _dirty = false;

    _writing =
        // Stamped, like every other write: a cleared store still belongs to this account, and an
        // unstamped empty snapshot would be adopted by the next account to sign in on this device.
        _writing
            .then((_) => store.save(ImCursorSnapshot(scope: scope.key)))
            .catchError(_reportSaveError);
    return _writing;
  }

  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// A save that failed must not become an unhandled async error — nothing is awaiting a debounced
  /// write — and must not stop the next one being attempted.
  void _reportSaveError(Object error) => onSaveError?.call(error);

  Future<void> _scheduleSave() {
    _dirty = true;

    // A floor of zero is legal and means "write through": Timer(Duration.zero) still defers to the
    // next event-loop turn, which is what coalesces a burst of commits from one delivered page.
    if (_debounce <= Duration.zero) return flush();

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, flush);
    return Future<void>.value();
  }
}
