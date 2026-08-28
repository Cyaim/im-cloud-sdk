import 'cursor_store.dart';
import 'logging.dart';
import 'protocol.dart';
import 'socket.dart';

/// Everything the SDK needs to open a connection, and the hooks a host app must supply.
class ImOptions {
  const ImOptions({
    required this.endpoint,
    required this.appId,
    required this.token,
    required this.deviceId,
    required this.userId,
    required this.cursorStore,
    this.platform = ImPlatform.unknown,
    this.channel = '/im',
    this.clientVersion,
    this.language,
    this.requestTimeout = const Duration(seconds: 15),
    this.maxAutoRepairSeq = 500,
    this.cursorSaveDebounce = const Duration(milliseconds: 1000),
    this.logger = defaultImLogger,
    this.onTokenExpired,
    this.socketFactory,
  });

  /// Base URL, e.g. `wss://im.example.com`. The channel path is appended.
  final String endpoint;

  final String appId;

  /// Short-lived user token minted by the tenant's own backend. Never an app secret.
  final String token;

  /// Stable per installation. The multi-device policy uses it to tell a reconnect from a second
  /// device, so a value that changes on every launch makes users kick themselves offline.
  final String deviceId;

  /// The signed-in user.
  ///
  /// Not sent in the handshake — the gateway reads the identity out of the token — but required,
  /// because the cursor store is scoped `(endpoint host, appId, userId)` and without the user id
  /// account switching on a shared handset hands one user the other's cursors (§5.3). Your backend
  /// already knows the value: it is the user it just minted a token for.
  ///
  /// 必填：游标作用域是 (host, appId, userId)，缺了 userId 就无法阻止同设备换账号时游标串号。
  final String userId;

  /// Where per-conversation cursors survive a process restart. **Required, with no default.**
  ///
  /// Without persistence the SDK cold-starts knowing nothing, `conn.sync` reports no gap for a
  /// conversation it was told nothing about, the client adopts the server's newest `maxSeq`, and
  /// every message that arrived while the app was closed is skipped — silently. That is a real bug
  /// this SDK shipped with, and a required argument is the only fix that cannot be forgotten.
  ///
  /// Use `ImCursorStore.file(path)` with a directory from `path_provider`, keyed by
  /// [ImCursorScope.storageKey]; or `ImCursorStore.inMemory()` if you genuinely do not want
  /// persistence and have read why that costs messages.
  ///
  /// 必填且无默认值：不持久化游标就会在冷启动时静默丢掉离线期间的全部消息。
  final ImCursorStore cursorStore;

  final ImPlatform platform;

  final String channel;

  /// Sent as the handshake's `cv`. Defaults to this package's own version, so a support ticket
  /// carries it without anyone having to ask. Set it to the *host app's* version if that is more
  /// useful to you.
  final String? clientVersion;

  /// BCP-47. The gateway remembers it, and offline push falls back to it when
  /// `push.register` carries no language of its own.
  final String? language;

  final Duration requestTimeout;

  /// Largest gap repaired message-by-message.
  ///
  /// Beyond it the SDK advances the cursor to the conversation's current `maxSeq`, commits, and
  /// raises [ImClient.conversationNeedsReload] so the application reloads that conversation from
  /// history. **Both halves matter**: skipping the cursor advance makes every later message look
  /// like a gap and re-request a range you have already declined; skipping the event leaves a hole
  /// in the UI that nothing will ever mention.
  ///
  /// Raising this above 500 does not buy a bigger single `msg.sync` — the server clamps that at
  /// 500 — it buys more iterations of the repair loop. That is fine and intended.
  final int maxAutoRepairSeq;

  /// How long ordinary [ImClient.commit] calls may be coalesced before they must reach the cursor
  /// store. Floor `Duration.zero` (write through); no ceiling.
  ///
  /// Adoption writes are never debounced regardless of this. The asymmetry is deliberate: **a lost
  /// debounced commit costs one duplicate delivery; a lost adoption costs silent permanent data
  /// loss.**
  final Duration cursorSaveDebounce;

  /// Where the SDK's own warnings go. Two of them are contractual — the in-memory cursor store and
  /// an unregistered push token — and both are things an integrator must be able to see.
  final ImLogger logger;

  /// Called when a token has expired: on a `conn.reauth` opportunity mid-session, and when the
  /// server closes with `im-kick:TokenExpired`. Return a fresh token, or null to stop.
  ///
  /// With this set, an expired token costs one `conn.reauth` frame on the socket that is already
  /// open rather than a full reconnect — which on the flaky network where tokens tend to expire is
  /// exactly what you were trying to avoid.
  final Future<String?> Function()? onTokenExpired;

  /// Supplies the transport. Defaults to `package:web_socket_channel`; tests and hosts with their
  /// own socket stack override it.
  final ImSocketFactory? socketFactory;

  ImOptions copyWith({String? token}) => ImOptions(
        endpoint: endpoint,
        appId: appId,
        token: token ?? this.token,
        deviceId: deviceId,
        userId: userId,
        cursorStore: cursorStore,
        platform: platform,
        channel: channel,
        clientVersion: clientVersion,
        language: language,
        requestTimeout: requestTimeout,
        maxAutoRepairSeq: maxAutoRepairSeq,
        cursorSaveDebounce: cursorSaveDebounce,
        logger: logger,
        onTokenExpired: onTokenExpired,
        socketFactory: socketFactory,
      );
}

/// Where the connection currently is. Drives a "reconnecting…" banner and nothing else.
enum ImConnectionState { idle, connecting, open, reconnecting, closed }
