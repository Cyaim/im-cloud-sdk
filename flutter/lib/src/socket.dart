import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// The transport surface [ImConnection] needs, and nothing more.
///
/// Two reasons this exists instead of using [WebSocketChannel] directly:
///
/// 1. **Tests.** Reconnect policy, kick classification and heartbeat failure are the behaviours
///    most likely to break, and all three are defined by what happens when a socket dies. A real
///    socket cannot be made to die on command, so the tests drive a fake one.
/// 2. **Hosts we do not control.** An app already multiplexing its own socket, a proxy, or a
///    platform whose WebSocket has to be created on a particular isolate can supply its own
///    transport without forking the SDK. This is the Dart equivalent of the TypeScript SDK's
///    `webSocketImpl` option.
abstract interface class ImSocket {
  /// Completes when the handshake has succeeded, or completes with an error when it has not.
  ///
  /// A failed handshake (HTTP 401 from the gateway, DNS failure, captive portal) never produces a
  /// close frame, so without this future the connection could not tell "refused" from "hung".
  Future<void> get ready;

  /// Frames from the peer. Text frames arrive as [String]; anything else is ignored upstream.
  ///
  /// Single-subscription: [ImConnection] listens exactly once per socket, and `onDone` is what
  /// drives the entire reconnect decision.
  Stream<dynamic> get messages;

  /// Queues a text frame. Must not throw for an ordinary "peer went away"; that is signalled by
  /// the stream ending.
  void send(String payload);

  /// Close code sent by the peer, available once [messages] is done.
  int? get closeCode;

  /// Close reason sent by the peer, available once [messages] is done.
  ///
  /// This is where `im-kick:{Reason}` arrives, and it is the reason this property is on the
  /// interface at all.
  String? get closeReason;

  /// Closes from our side. [code] and [reason] are sent to the peer.
  Future<void> close([int? code, String? reason]);
}

/// Default transport: `package:web_socket_channel`.
///
/// One implementation covers iOS, Android, Windows, macOS, Linux and the browser, because the
/// package picks `dart:io` or the DOM `WebSocket` behind the same API. That is the whole reason
/// this SDK can be one codebase rather than one per Flutter target.
class WebSocketChannelSocket implements ImSocket {
  WebSocketChannelSocket(this._channel);

  /// Connects to [url] with the platform's WebSocket implementation.
  factory WebSocketChannelSocket.connect(Uri url) =>
      WebSocketChannelSocket(WebSocketChannel.connect(url));

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get messages => _channel.stream;

  @override
  void send(String payload) => _channel.sink.add(payload);

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  Future<void> close([int? code, String? reason]) => _channel.sink.close(code, reason);
}

/// Creates a transport for [url]. This is the type of [ImOptions.socketFactory].
///
/// Synchronous on purpose. Construction has to return before the connection can subscribe to
/// [ImSocket.messages], and anything genuinely asynchronous about opening the socket already has a
/// home in [ImSocket.ready] — which is also the only place a refused handshake can be reported,
/// since it never produces a close frame.
typedef ImSocketFactory = ImSocket Function(Uri url);

/// The factory used when [ImOptions.socketFactory] is not supplied.
ImSocketFactory get defaultImSocketFactory => WebSocketChannelSocket.connect;
