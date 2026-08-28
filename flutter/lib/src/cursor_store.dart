// Conditional import: `dart:io` does not exist in a browser, and a single `import 'dart:io'`
// anywhere in the package's reachable graph would stop `flutter build web` dead. The stub throws
// from `ImCursorStore.file` on the web and nothing else changes.
// 条件导入：包里任何一处 `dart:io` 都会让 web 构建直接失败。
import 'cursor_store_stub.dart' if (dart.library.io) 'cursor_store_io.dart' as platform;

/// Who a set of cursors belongs to: `(endpoint host, appId, userId)`.
///
/// Not the device id — the store is already local to the device. [userId] is the part that matters:
/// without it, two accounts on one handset share one set of cursors, and the second one to sign in
/// silently inherits the first one's position and skips whatever the first had already consumed.
/// That is one person's cursors replaying into another person's client. `sdk/CONTRACT.md` §5.3.
///
/// 作用域键必须含 userId：同一台设备换账号时，否则第二个账号会继承第一个账号的游标。
class ImCursorScope {
  const ImCursorScope._(this.host, this.appId, this.userId);

  /// The usual construction: the endpoint the client connects to, reduced to its host.
  ///
  /// The host and not the whole URL, because a deployment that moves between `wss://h/im` and
  /// `wss://h/gateway` is the same server holding the same seqs; re-downloading everything because
  /// a path changed is a cost with nothing behind it.
  factory ImCursorScope.of({
    required String endpoint,
    required String appId,
    required String userId,
  }) {
    final String host = Uri.tryParse(endpoint)?.host ?? '';
    return ImCursorScope._(host.isEmpty ? endpoint : host, appId, userId);
  }

  final String host;
  final String appId;
  final String userId;

  /// The identity stamped into a snapshot and compared on load. Spelled the same way in all five
  /// SDKs, so a snapshot written by one is legible to the others.
  String get key => '$host|$appId|${userId.isEmpty ? '*' : userId}';

  /// The same identity, safe as a file name on every platform.
  String get storageKey => key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  @override
  String toString() => key;
}

/// What the SDK persists between launches, and the whole of it.
///
/// Two numbers per conversation are *not* stored here: only [convSeqs], which is `committedSeq` —
/// the highest seq the application said it had durably written. `deliveredSeq` lives in memory and
/// dies with the process, on purpose. See [ImCursorStore] and `sdk/CONTRACT.md` §5.2.
class ImCursorSnapshot {
  const ImCursorSnapshot({
    this.convSeqs = const <String, int>{},
    this.conversationCursor = 0,
    this.scope,
  });

  /// Decodes a snapshot written by [toJson], tolerating a truncated or partially-written file.
  ///
  /// Anything unreadable is *not* silently treated as empty — the caller distinguishes the two,
  /// because "nothing stored yet" and "the store is broken" need opposite responses (§5.8). This
  /// constructor throws on a shape it cannot read, and [ImCursorStore] implementations let that
  /// throw travel.
  factory ImCursorSnapshot.fromJson(Map<String, dynamic> json) {
    final Object? seqs = json['convSeqs'];
    if (seqs != null && seqs is! Map<String, dynamic>) {
      throw const FormatException('convSeqs must be an object');
    }

    return ImCursorSnapshot(
      convSeqs: <String, int>{
        if (seqs is Map<String, dynamic>)
          for (final MapEntry<String, dynamic> entry in seqs.entries)
            if (_seq(entry.value) case final int seq) entry.key: seq,
      },
      conversationCursor: _seq(json['conversationCursor']) ?? 0,
      scope: switch (json['scope']) {
        final String scope => scope,
        null => null,
        _ => throw const FormatException('scope must be a string'),
      },
    );
  }

  /// An empty snapshot: a genuinely fresh install.
  static const ImCursorSnapshot empty = ImCursorSnapshot();

  /// `committedSeq` per conversation. This, and never `deliveredSeq`, is what `conn.sync` reports.
  final Map<String, int> convSeqs;

  /// Highest `ConversationView.updatedAt` from a `conn.sync` run that ran to completion.
  ///
  /// Only advanced after a full run: the list is sorted newest-first, so taking the maximum from
  /// page one and stopping pushes this past every conversation on pages 2…N, which the server then
  /// never returns again. See §5.6 step 8.
  final int conversationCursor;

  /// Which [ImCursorScope] these cursors belong to — stamped by the SDK on every write.
  ///
  /// **This field is the account-switch guarantee, and it lives in the payload rather than in the
  /// store's signature on purpose.** A store is a few lines an integrator writes; a store that keys
  /// itself per account is a few lines an integrator *remembers* to write. Carrying the identity in
  /// the snapshot means the SDK can refuse cursors that belong to somebody else even when the store
  /// did nothing to keep two accounts apart — so an app that does nothing special cannot get it
  /// wrong. Null on a snapshot the SDK has never written; the SDK accepts that and stamps the next
  /// save.
  final String? scope;

  Map<String, Object?> toJson() => <String, Object?>{
        'convSeqs': convSeqs,
        'conversationCursor': conversationCursor,
        if (scope != null) 'scope': scope,
      };

  ImCursorSnapshot copyWith({
    Map<String, int>? convSeqs,
    int? conversationCursor,
    String? scope,
  }) =>
      ImCursorSnapshot(
        convSeqs: convSeqs ?? this.convSeqs,
        conversationCursor: conversationCursor ?? this.conversationCursor,
        scope: scope ?? this.scope,
      );

  @override
  String toString() =>
      'ImCursorSnapshot(${convSeqs.length} conversations, cursor $conversationCursor)';

  static int? _seq(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Where cursors survive a process restart.
///
/// **This is the fix for a silent data-loss bug, and it is a required argument on [ImOptions] for
/// that reason.** Without it the SDK cold-starts with no cursors, `conn.sync` reports no gap for a
/// conversation it was told nothing about, the client adopts the server's newest `maxSeq`, and
/// every message that arrived while the app was closed falls behind the cursor: never requested,
/// never delivered, no error, no log line, nothing later that corrects it.
///
/// There is no implicit default. An integrator who genuinely does not want persistence passes
/// [ImCursorStore.inMemory], which says so out loud once. Defaulting to no persistence is what
/// produced the bug; defaulting to *some* persistence would mean guessing where a Flutter app is
/// allowed to write, and a wrong guess about that is worse than a compile error.
///
/// **Scope the store by `(endpoint host, appId, userId)`** — see [ImCursorScope]. Not the device
/// id: the file is already local to the device, and it is account switching on a shared handset
/// that hands one user another user's cursors.
///
/// You do not have to remember that. The SDK stamps [ImCursorSnapshot.scope] onto every write and
/// refuses a snapshot belonging to another account on read, so the worst a shared store can do is
/// cost the earlier account a re-download. Keying the file per account with
/// [ImCursorScope.storageKey] is what avoids even that.
///
/// **The cursor store and the application's message store have exactly one lifetime.** Whatever
/// destroys one destroys the other, cursors first. Clearing messages but keeping cursors leaves an
/// empty conversation that will never refill; clearing cursors but keeping messages costs a full
/// re-download and duplicate delivery.
///
/// 游标存储是强制构造参数，因为"不持久化"正是那个静默丢消息的 bug 的成因。
/// 按 (host, appId, userId) 划分作用域；游标与应用自己的消息库生死与共，先删游标。
abstract interface class ImCursorStore {
  /// Read once, before the first connect. Throwing is meaningful — see §5.8: the SDK treats a
  /// failed load as "history exists and I cannot see it", refuses to adopt, and refuses to move
  /// any cursor for the rest of the session.
  Future<ImCursorSnapshot> load();

  /// Persist [snapshot]. May be called often; the SDK debounces ordinary commits itself and
  /// awaits this call where the contract requires a flush (before `conn.sync`, and after an
  /// adoption).
  Future<void> save(ImCursorSnapshot snapshot);

  /// A JSON file at [path]. The application supplies the directory.
  ///
  /// The SDK takes no `path_provider` dependency: it is a Flutter plugin, and this package's test
  /// suite deliberately runs under the plain Dart SDK. Two lines in the host app —
  /// `getApplicationSupportDirectory()` and [ImCursorScope] — cost less than a plugin dependency in
  /// every consumer, including the ones that are pure Dart.
  ///
  /// Writes go to `$path.tmp` and are renamed over [path], so a crash mid-write leaves the previous
  /// snapshot intact rather than a truncated file that [load] would reject.
  ///
  /// Throws [UnsupportedError] on the web, where there is no filesystem. Web deployments should
  /// supply their own store over `window.localStorage`, or use [inMemory] and accept a
  /// re-download per tab.
  static ImCursorStore file(String path) => platform.createFileCursorStore(path);

  /// Keeps nothing.
  ///
  /// [ImClient] logs one warning naming `sdk/CONTRACT.md` §5.3 when it sees this store, because a
  /// silently non-persisting client is indistinguishable from a working one until a customer
  /// reports missing messages. The warning is raised by the client and not here: whether the
  /// application is told it is running without persistence is not a store's decision to make.
  ///
  /// Legitimate uses: a test, a kiosk that shows only live traffic, a first spike. It is not a
  /// default and is not treated as one.
  static ImCursorStore inMemory() => ImInMemoryCursorStore();

  /// The scope a store should be keyed by, as a filename-safe string.
  ///
  /// ```dart
  /// final ImCursorScope scope = ImCursorScope.of(
  ///   endpoint: 'wss://im.example.com', appId: appId, userId: userId,
  /// );
  /// final ImCursorStore store = ImCursorStore.file('${dir.path}/cyaim-${scope.storageKey}.json');
  /// ```
  ///
  /// Keying the file per account is the *retention* half of §5.3: signing back in as the first
  /// account then finds its cursors intact instead of re-downloading. The *safety* half — never
  /// handing one user another user's position — is enforced by the SDK from
  /// [ImCursorSnapshot.scope] and needs nothing from you.
  @Deprecated('Use ImCursorScope.of(endpoint: …, appId: …, userId: …).storageKey. Removed in 2.0.')
  static String scopeKey({
    required String endpoint,
    required String appId,
    required String userId,
  }) =>
      ImCursorScope.of(endpoint: endpoint, appId: appId, userId: userId).storageKey;
}

/// [ImCursorStore.inMemory]. Public only so [ImClient] can recognise it by type.
///
/// "Is this store persistent" is answered by the SDK from the store's identity, never by the store
/// itself. A declared flag would let *any* store — including one an integrator wrote over
/// sqflite — announce itself volatile, and the only thing that answer drives is the warning
/// about losing messages. A store that can lie about that is a store that can silence the one line
/// standing between a misconfigured client and a support ticket about missing history.
///
/// 「是否持久化」由 SDK 按存储的身份判断，不由存储自己声明。
class ImInMemoryCursorStore implements ImCursorStore {
  ImCursorSnapshot _snapshot = ImCursorSnapshot.empty;

  @override
  Future<ImCursorSnapshot> load() async => _snapshot;

  @override
  Future<void> save(ImCursorSnapshot snapshot) async => _snapshot = snapshot;
}
