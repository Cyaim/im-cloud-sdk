import 'dart:async';

/// Cancels an in-flight request.
///
/// Dart `Future`s are not cancellable and this package takes no `package:async` dependency, so
/// cancellation is an explicit token the caller passes in — the mechanism `sdk/CONTRACT.md` §7.5
/// assigns to Dart. Pass the same token to several calls to cancel them together, e.g. everything
/// a screen has outstanding when it is disposed.
///
/// ```dart
/// final ImCancelToken token = ImCancelToken();
/// final Future<ImPage<ImMessage>> page = im.msg.history(request, token);
/// // …the user leaves the screen
/// token.cancel();
/// ```
///
/// **Cancelling abandons the reply. It does not cancel the server-side effect.** A cancelled
/// `msg.send` may well have sent the message; that is what `clientMsgId` idempotency is for —
/// reissue with the same id and the server replays the original result instead of posting twice.
/// Cancelling never touches a cursor.
///
/// 取消只是放弃等待回复，不会取消服务端已经发生的动作；用同一个 clientMsgId 重发即可幂等。
class ImCancelToken {
  ImCancelToken();

  final List<void Function()> _callbacks = <void Function()>[];

  bool _cancelled = false;
  Object? _reason;

  /// True once [cancel] has been called. A request started with an already-cancelled token fails
  /// immediately rather than reaching the socket.
  bool get isCancelled => _cancelled;

  /// Whatever was passed to [cancel], for a caller that wants to know *why*.
  Object? get reason => _reason;

  /// Cancels every request registered on this token, then every later one.
  ///
  /// Idempotent: a second call does nothing, so a dispose path may call it unconditionally.
  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;

    // Copied before iterating: a callback removes itself, which would otherwise mutate the list
    // being walked.
    for (final void Function() callback in List<void Function()>.of(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  /// Registers [callback], returning a function that unregisters it.
  ///
  /// Internal to the SDK. A token that is already cancelled runs [callback] on the next microtask
  /// rather than synchronously, so the caller has finished registering its pending entry before
  /// the cancellation tries to remove it.
  void Function() addListener(void Function() callback) {
    if (_cancelled) {
      scheduleMicrotask(callback);
      return () {};
    }

    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }
}

/// Raised when a request is abandoned through an [ImCancelToken].
///
/// Deliberately *not* an [ImException] with an invented code: cancellation is a local decision,
/// not a server outcome, and giving it a business code would put it in the same `catch` as a
/// rate limit or a moderation refusal — the two things a caller most needs to tell apart.
///
/// 取消不是服务端结果，因此不复用业务错误码，否则会和限流、审核拒绝落进同一个 catch。
class ImCancelledException implements Exception {
  const ImCancelledException({this.target, this.reason});

  /// The endpoint whose reply was abandoned, e.g. `msg.send`.
  final String? target;

  /// Whatever was passed to [ImCancelToken.cancel].
  final Object? reason;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('ImCancelledException');
    if (target != null) buffer.write('($target)');
    if (reason != null) buffer.write(': $reason');
    return buffer.toString();
  }
}
