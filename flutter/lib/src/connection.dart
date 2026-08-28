import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'backoff.dart';
import 'cancel.dart';
import 'models.dart';
import 'options.dart';
import 'protocol.dart';
import 'socket.dart';
import 'version.dart';

/// One multiplexed socket to the gateway, with the reconnect behaviour a shipped app needs.
///
/// Reconnecting is not a nicety here. A gateway is stateful, so a rolling update drops every
/// socket on the node being replaced, and all of those clients come back at the same instant.
/// Delays are drawn with **full jitter** — uniformly from `0..ceiling`, ceiling doubling to 30s —
/// because that is what actually de-synchronises a fleet. A fixed backoff, or one jittered by
/// ±10%, reconnects a whole node's worth of clients inside the same second, against the service
/// that has just come back up.
///
/// 网关一次滚动更新会让该节点上所有客户端同时重连。退避必须是全抖动（0..上限 均匀取值），
/// 固定退避或 ±10% 抖动会让它们挤在同一秒里打向刚恢复的服务。
class ImConnection implements ImRequester {
  ImConnection(this._options) : _token = _options.token;

  ImOptions _options;
  String _token;

  final FullJitterBackoff _backoff = FullJitterBackoff();

  final Map<String, Completer<ImFrame>> _pending = <String, Completer<ImFrame>>{};
  final Map<String, List<void Function(ImFrame)>> _listeners =
      <String, List<void Function(ImFrame)>>{};

  final StreamController<ImConnectionState> _states =
      StreamController<ImConnectionState>.broadcast();
  final StreamController<ImKickEvent> _kicks = StreamController<ImKickEvent>.broadcast();

  ImSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Future<bool>? _reauthing;

  ImConnectionState _state = ImConnectionState.idle;
  Duration _heartbeatInterval = const Duration(seconds: 30);
  int _attempt = 0;
  int _sequence = 0;
  bool _stopped = false;

  ImConnectionState get state => _state;

  /// Connection state transitions, for a status banner.
  Stream<ImConnectionState> get states => _states.stream;

  /// Emitted when the server ends the session rather than the network doing it.
  Stream<ImKickEvent> get kicks => _kicks.stream;

  /// The token currently in use, which is not `options.token` after a `conn.reauth`.
  String get token => _token;

  /// How many replies are outstanding. Exposed because "cancellation leaks a pending entry" is a
  /// bug you can only see from here, and it is one of the conformance tests.
  int get pendingRequestCount => _pending.length;

  /// Subscribes to a server push target. Returns a function that removes the subscription.
  void Function() on(String target, void Function(ImFrame frame) listener) {
    _listeners.putIfAbsent(target, () => <void Function(ImFrame)>[]).add(listener);
    return () => _listeners[target]?.remove(listener);
  }

  Future<void> connect() async {
    _stopped = false;
    await _open();
  }

  Future<void> close() async {
    _stopped = true;
    _clearTimers();
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close(1000, 'client-close');
    _socket = null;
    _setState(ImConnectionState.closed);
    _failAllPending();
  }

  /// Sends a request and returns its business payload, throwing [ImException] on a non-zero code.
  ///
  /// Requests issued while offline fail immediately rather than queueing: a chat client that
  /// silently buffers sends produces messages that arrive minutes later with no explanation, and
  /// the user has already retyped them by then. The application knows whether a message is still
  /// worth sending; the SDK does not.
  ///
  /// A reply carrying [ImErrorCode.tokenExpired] is retried **once**, after a `conn.reauth` on the
  /// socket that is already open — see [ImOptions.onTokenExpired]. Only if that reauth fails does
  /// the error reach the caller.
  @override
  Future<T> request<T>(String target, [Object? body, ImCancelToken? cancel]) async {
    final Object? data = await _requestData(target, body, cancel, allowReauth: true);
    return data as T;
  }

  /// Sends a request and returns the raw frame, for callers that need the envelope.
  Future<ImFrame> send(String target, [Object? body, ImCancelToken? cancel]) {
    if (cancel != null && cancel.isCancelled) {
      return Future<ImFrame>.error(
        ImCancelledException(target: target, reason: cancel.reason),
      );
    }

    final ImSocket? socket = _socket;
    if (socket == null || _state != ImConnectionState.open) {
      // 1005 ServiceUnavailable, not 1004: nothing was delivered, and the caller can say so.
      return Future<ImFrame>.error(
        const ImException(ImErrorCode.serviceUnavailable, 'not connected'),
      );
    }

    final String id = 'c${++_sequence}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final Completer<ImFrame> completer = Completer<ImFrame>();
    _pending[id] = completer;

    final Timer timer = Timer(_options.requestTimeout, () {
      if (_pending.remove(id) != null && !completer.isCompleted) {
        completer.completeError(
          ImException(ImErrorCode.timeout, 'request timed out: $target', target: target),
        );
      }
    });

    // Cancelling must remove the pending entry, not merely stop the caller waiting: an entry left
    // behind is a leak that grows for the life of the connection.
    final void Function()? unlisten = cancel?.addListener(() {
      if (_pending.remove(id) != null && !completer.isCompleted) {
        completer.completeError(
          ImCancelledException(target: target, reason: cancel.reason),
        );
      }
    });

    void cleanup() {
      timer.cancel();
      unlisten?.call();
    }

    try {
      socket.send(jsonEncode(
        ImRequest(id: id, target: target, body: body ?? const <String, dynamic>{}).toJson(),
      ));
    } catch (error) {
      cleanup();
      _pending.remove(id);
      return Future<ImFrame>.error(
        ImException(ImErrorCode.serviceUnavailable, 'send failed: $error', target: target),
      );
    }

    return completer.future.whenComplete(cleanup);
  }

  // -------------------------------------------------------------------------- internals

  Future<Object?> _requestData(
    String target,
    Object? body,
    ImCancelToken? cancel, {
    required bool allowReauth,
  }) async {
    final ImFrame frame = await send(target, body, cancel);
    final ImException? error = ImException.fromFrame(frame, target);
    if (error == null) return frame.body?.data;

    // §7.4: an expired token costs one frame, not a reconnect. Retried exactly once — a second
    // expiry on a token minted seconds ago is a server or clock problem, and looping on it turns
    // one failure into a storm.
    if (allowReauth &&
        error.code == ImErrorCode.tokenExpired &&
        _options.onTokenExpired != null &&
        await _reauth()) {
      return _requestData(target, body, cancel, allowReauth: false);
    }

    throw error;
  }

  /// Renews the token on the live socket. Concurrent callers share one attempt — a burst of
  /// requests all failing 1101 at once must produce one `conn.reauth`, not one each.
  Future<bool> _reauth() {
    return _reauthing ??= _performReauth().whenComplete(() => _reauthing = null);
  }

  Future<bool> _performReauth() async {
    final String? next = await _options.onTokenExpired?.call();
    if (next == null || next.isEmpty) return false;

    try {
      await _requestData(
        'conn.reauth',
        <String, Object?>{'token': next},
        null,
        allowReauth: false,
      );
    } catch (_) {
      // The session is genuinely finished; let the original error surface to the caller and let
      // the close path handle the drop.
      return false;
    }

    _token = next;
    _options = _options.copyWith(token: next);
    return true;
  }

  Future<void> _open() async {
    _setState(_attempt == 0 ? ImConnectionState.connecting : ImConnectionState.reconnecting);

    final ImSocket socket = (_options.socketFactory ?? defaultImSocketFactory)(_buildUri());
    _socket = socket;

    _subscription = socket.messages.listen(
      _dispatch,
      onError: (Object _) {
        // onDone always follows, and the reconnect decision lives there so it runs exactly once.
      },
      onDone: () => _handleClosed(socket),
      cancelOnError: false,
    );

    try {
      await socket.ready;
    } catch (_) {
      // A refused handshake never produces a close frame, so nothing else would notice it.
      _handleClosed(socket);
      return;
    }

    _attempt = 0;
    _setState(ImConnectionState.open);
    _startHeartbeat();
  }

  Uri _buildUri() {
    final String base = _options.endpoint.replaceAll(RegExp(r'/+$'), '');
    final Map<String, String> query = <String, String>{
      'appId': _options.appId,
      'token': _token,
      'deviceId': _options.deviceId,
      'platform': _options.platform.wireValue.toString(),
      'v': '1',
      // The SDK's own version when the host app did not name one, so a support ticket carries it
      // without anyone having to ask which build the customer is on.
      'cv': _options.clientVersion ?? ImSdk.packageVersion,
      if (_options.language != null) 'lang': _options.language!,
    };

    return Uri.parse('$base${_options.channel}').replace(queryParameters: query);
  }

  void _dispatch(dynamic raw) {
    if (raw is! String) return;

    final ImFrame frame;
    try {
      frame = ImFrame.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return;
    }

    final Completer<ImFrame>? waiting = frame.id.isEmpty ? null : _pending.remove(frame.id);
    if (waiting != null) {
      if (!waiting.isCompleted) waiting.complete(frame);
      return;
    }

    if (frame.target == ImPushTarget.kick) {
      _handleKickPush(frame);
      return;
    }

    for (final void Function(ImFrame) listener in List<void Function(ImFrame)>.of(
        _listeners[frame.target] ?? const <void Function(ImFrame)>[])) {
      try {
        listener(frame);
      } catch (_) {
        // A throwing listener must not stop the others or the receive loop.
      }
    }
  }

  /// A kick that arrives as a push rather than as a close reason.
  ///
  /// Both forms carry the same meaning and must get the same response: **stop reconnecting.**
  /// Reconnecting into a kick is a loop, and the loop is invisible from the app — the socket keeps
  /// coming back and keeps being taken away. This path used to emit the event and then reconnect
  /// anyway.
  /// 被踢有两种到达方式，处理必须一致：终止重连。重连进一次踢下线就是死循环。
  void _handleKickPush(ImFrame frame) {
    final Map<String, dynamic>? detail =
        frame.body?.data is Map<String, dynamic> ? frame.body!.data as Map<String, dynamic> : null;
    final String kickReason = detail?['reason']?.toString() ?? '';
    final ImKickReason reason = ImKickReason.parse('im-kick:$kickReason') ?? ImKickReason.unknown;

    // The gateway also sends 1107 as a business code on the kick body; either is enough.
    final bool terminal = reason.terminal || frame.body?.code == ImErrorCode.kickedByOtherDevice;

    if (!_kicks.isClosed) {
      _kicks.add(ImKickEvent(reason, rawReason: kickReason, detail: detail));
    }

    if (!terminal) return;

    _stopped = true;
    _clearTimers();
    unawaited(_socket?.close(1000, 'im-kick:$kickReason') ?? Future<void>.value());
  }

  void _handleClosed(ImSocket socket) {
    if (!identical(socket, _socket)) return;

    _clearTimers();
    _failAllPending();

    if (_stopped) {
      _setState(ImConnectionState.closed);
      return;
    }

    // The close reason is the only thing separating "you were kicked" from "the network died",
    // and the two need opposite responses.
    final ImKickReason? kick = ImKickReason.parse(socket.closeReason);

    if (kick != null) {
      if (!_kicks.isClosed) {
        _kicks.add(ImKickEvent(kick, rawReason: socket.closeReason ?? ''));
      }

      if (kick.terminal) {
        _stopped = true;
        _setState(ImConnectionState.closed);
        return;
      }

      if (kick == ImKickReason.tokenExpired) {
        unawaited(_refreshTokenAndReconnect());
        return;
      }
    }

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _setState(ImConnectionState.reconnecting);
    final Duration delay = _backoff.delayFor(++_attempt);
    _reconnectTimer = Timer(delay, () => unawaited(_open()));
  }

  Future<void> _refreshTokenAndReconnect() async {
    final String? next = await _options.onTokenExpired?.call();
    if (next == null || next.isEmpty) {
      _stopped = true;
      _setState(ImConnectionState.closed);
      return;
    }

    _token = next;
    _options = _options.copyWith(token: next);
    _scheduleReconnect();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      try {
        final ImHeartbeatResult beat = ImHeartbeatResult.fromJson(
          await request<Map<String, dynamic>>('conn.heartbeat'),
        );

        if (beat.intervalSeconds > 0 && beat.intervalSeconds != _heartbeatInterval.inSeconds) {
          // The server owns the cadence; adopt whatever it reports.
          _heartbeatInterval = Duration(seconds: beat.intervalSeconds);
          _startHeartbeat();
        }
      } catch (_) {
        // A missed beat on a socket the OS still believes is open is exactly the half-open case.
        // Forcing a close is what hands control to the reconnect path.
        unawaited(_socket?.close(4000, 'heartbeat-failed') ?? Future<void>.value());
      }
    });
  }

  void _clearTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Fails everything still waiting with [ImErrorCode.timeout], **not** with
  /// [ImErrorCode.serviceUnavailable].
  ///
  /// 1005 would claim the call was never delivered, and the SDK does not know that — the request
  /// may well have executed on the server before the socket died. 1004 is the honest answer, and
  /// it is the one that makes a caller reach for `clientMsgId` idempotency instead of blindly
  /// resending.
  /// 套接字带着在途请求断开时报 1004 而不是 1005：请求可能已经在服务端执行了，1005 是在说谎。
  void _failAllPending() {
    if (_pending.isEmpty) return;

    final List<Completer<ImFrame>> waiting = List<Completer<ImFrame>>.of(_pending.values);
    _pending.clear();

    for (final Completer<ImFrame> completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(
          const ImException(
            ImErrorCode.timeout,
            'the connection dropped with this request in flight; it may or may not have run',
          ),
        );
      }
    }
  }

  void _setState(ImConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
