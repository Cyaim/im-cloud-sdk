import 'dart:async';
import 'dart:convert';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// A socket the test drives: it records what was sent, replies on command, and dies on command.
///
/// A real socket cannot be made to fail on demand, and every behaviour worth testing here is
/// defined by what happens when one does.
class FakeSocket implements ImSocket {
  FakeSocket(this.url, {this.onSend});

  final Uri url;

  /// Called for every frame the client writes, before it is recorded. [FakeGateway] uses it to
  /// answer automatically; a test driving the socket by hand leaves it null.
  final void Function(FakeSocket socket, String payload)? onSend;

  final List<String> sent = <String>[];
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final Completer<void> _ready = Completer<void>();

  @override
  int? closeCode;

  @override
  String? closeReason;

  /// Order matters in one of the conformance tests: `push.unregister` must be on the wire before
  /// the close, and after the close nothing may be written at all.
  bool get isClosed => _incoming.isClosed;

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  void send(String payload) {
    sent.add(payload);
    onSend?.call(this, payload);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    closeReason ??= reason;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void open() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void refuse(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
  }

  void deliver(Object payload) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(payload));
  }

  /// Simulates the peer closing, optionally with a kick reason.
  Future<void> die({int code = 1006, String? reason}) async {
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// The most recent request the client sent, decoded.
  Map<String, dynamic>? get lastRequest =>
      sent.isEmpty ? null : jsonDecode(sent.last) as Map<String, dynamic>;

  /// Every request sent on this socket, decoded, in order.
  List<Map<String, dynamic>> get allRequests => <Map<String, dynamic>>[
        for (final String payload in sent) jsonDecode(payload) as Map<String, dynamic>,
      ];
}

/// Hands out sockets in order and records how many were asked for.
class FakeTransport {
  final List<FakeSocket> created = <FakeSocket>[];

  ImSocket call(Uri url) {
    final FakeSocket socket = FakeSocket(url);
    created.add(socket);
    return socket;
  }

  FakeSocket get latest => created.last;
}

/// What a [FakeGateway] handler answers with.
sealed class FakeReply {
  const FakeReply();
}

/// A successful `ApiResult` carrying [data].
class FakeData extends FakeReply {
  const FakeData([this.data]);

  final Object? data;
}

/// A non-zero business code inside a routed frame.
class FakeFail extends FakeReply {
  const FakeFail(this.code, {this.message = 'refused', this.traceId});

  final int code;
  final String message;
  final String? traceId;
}

/// A transport-level outcome: `status` 1 (the endpoint threw) or 2 (no such target).
class FakeStatus extends FakeReply {
  const FakeStatus(this.status, {this.msg});

  final int status;
  final String? msg;
}

/// Never answer. The client's own timeout is what ends the call.
class FakeSilence extends FakeReply {
  const FakeSilence();
}

/// One request the client sent.
class FakeRequest {
  FakeRequest(this.id, this.target, this.body);

  final String id;
  final String target;
  final Map<String, dynamic> body;

  @override
  String toString() => '$target $body';
}

/// A scriptable gateway: it hands out sockets, records every request, and answers from per-target
/// handlers.
///
/// Written because the conformance suite in `sdk/CONTRACT.md` §10 is twenty-six behaviours, most
/// of which need three or four canned replies in a particular order. Driving each one by hand
/// would bury the behaviour under transport bookkeeping.
class FakeGateway {
  final List<FakeSocket> sockets = <FakeSocket>[];
  final List<FakeRequest> requests = <FakeRequest>[];

  final Map<String, FakeReply Function(FakeRequest request)> _handlers =
      <String, FakeReply Function(FakeRequest)>{};
  final Map<String, int> _calls = <String, int>{};

  FakeSocket get socket => sockets.last;

  /// How many times [target] has been called across every socket.
  int callsTo(String target) => _calls[target] ?? 0;

  List<FakeRequest> requestsTo(String target) =>
      requests.where((FakeRequest r) => r.target == target).toList(growable: false);

  List<String> get targets => requests.map((FakeRequest r) => r.target).toList(growable: false);

  /// Registers a handler. Later registrations replace earlier ones.
  void on(String target, FakeReply Function(FakeRequest request) handler) =>
      _handlers[target] = handler;

  /// Answers [target] from [replies] in order, repeating the last one once exhausted.
  void script(String target, List<FakeReply> replies) {
    int index = 0;
    on(target, (FakeRequest _) {
      final FakeReply reply = replies[index < replies.length ? index : replies.length - 1];
      index++;
      return reply;
    });
  }

  /// The transport factory to hand to [ImOptions.socketFactory].
  ImSocket connect(Uri url) {
    final FakeSocket created = FakeSocket(url, onSend: _onSend);
    sockets.add(created);
    return created;
  }

  /// Opens the newest socket's handshake.
  void openLatest() => sockets.last.open();

  void _onSend(FakeSocket source, String payload) {
    final Map<String, dynamic> frame = jsonDecode(payload) as Map<String, dynamic>;
    final FakeRequest request = FakeRequest(
      frame['id'] as String,
      frame['target'] as String,
      (frame['body'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );

    requests.add(request);
    _calls[request.target] = (_calls[request.target] ?? 0) + 1;

    final FakeReply reply = (_handlers[request.target] ?? _defaultFor(request.target))(request);
    if (reply is FakeSilence) return;

    // Answered on a later microtask, the way a real socket would: replying inside `send` would
    // hide any ordering bug that depends on the caller having finished registering first.
    scheduleMicrotask(() => source.deliver(_encode(request, reply)));
  }

  FakeReply Function(FakeRequest) _defaultFor(String target) => switch (target) {
        'conn.sync' => (FakeRequest _) => const FakeData(<String, dynamic>{
              'conversations': <dynamic>[],
              'gapsFrom': <String, dynamic>{},
              'hasMore': false,
            }),
        'conn.heartbeat' => (FakeRequest _) =>
            const FakeData(<String, dynamic>{'serverTime': 1, 'intervalSeconds': 30}),
        _ => (FakeRequest _) => const FakeData(),
      };

  static Map<String, dynamic> _encode(FakeRequest request, FakeReply reply) => switch (reply) {
        FakeData(:final Object? data) => <String, dynamic>{
            'id': request.id,
            'target': request.target,
            'status': 0,
            'body': <String, dynamic>{'code': 0, 'serverTime': 1, 'data': data},
          },
        FakeFail(:final int code, :final String message, :final String? traceId) =>
          <String, dynamic>{
            'id': request.id,
            'target': request.target,
            'status': 0,
            'body': <String, dynamic>{
              'code': code,
              'message': message,
              'traceId': traceId,
              'serverTime': 1,
            },
          },
        FakeStatus(:final int status, :final String? msg) => <String, dynamic>{
            'id': request.id,
            'target': request.target,
            'status': status,
            'msg': msg,
          },
        FakeSilence() => throw StateError('unreachable'),
      };
}

/// An [ImCursorStore] a test can inspect, corrupt, and count writes on.
class RecordingCursorStore implements ImCursorStore {
  RecordingCursorStore({
    ImCursorSnapshot? initial,
    this.failLoad = false,
  }) : _snapshot = initial ?? ImCursorSnapshot.empty;

  /// Makes [load] throw, which must freeze every cursor rather than look like a fresh install.
  final bool failLoad;

  ImCursorSnapshot _snapshot;

  /// Every snapshot handed to [save], in order.
  final List<ImCursorSnapshot> writes = <ImCursorSnapshot>[];

  int loads = 0;

  ImCursorSnapshot get persisted => _snapshot;

  @override
  Future<ImCursorSnapshot> load() async {
    loads++;
    if (failLoad) throw const FormatException('cursor store is corrupt');
    return _snapshot;
  }

  @override
  Future<void> save(ImCursorSnapshot snapshot) async {
    writes.add(snapshot);
    _snapshot = snapshot;
  }
}

ImOptions optionsFor(
  ImSocketFactory socketFactory, {
  ImCursorStore? cursorStore,
  Future<String?> Function()? onTokenExpired,
  int maxAutoRepairSeq = 500,
  Duration cursorSaveDebounce = Duration.zero,
  ImLogger? logger,
  String userId = 'alice',
}) =>
    ImOptions(
      endpoint: 'wss://im.test',
      appId: 'demo',
      token: 'token-1',
      deviceId: 'device-1',
      userId: userId,
      cursorStore: cursorStore ?? RecordingCursorStore(),
      platform: ImPlatform.web,
      requestTimeout: const Duration(milliseconds: 200),
      maxAutoRepairSeq: maxAutoRepairSeq,
      cursorSaveDebounce: cursorSaveDebounce,
      logger: logger ?? (String _) {},
      onTokenExpired: onTokenExpired,
      socketFactory: socketFactory,
    );

Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  String? because,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout${because == null ? '' : ': $because'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets every pending microtask and timer-zero callback run.
Future<void> settle([int turns = 8]) async {
  for (int i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Connects a client against [gateway] and waits until the first `conn.sync` has been answered.
Future<ImClient> connectedClient(
  FakeGateway gateway, {
  ImCursorStore? cursorStore,
  int maxAutoRepairSeq = 500,
  Duration cursorSaveDebounce = Duration.zero,
  Future<String?> Function()? onTokenExpired,
  ImLogger? logger,
  String userId = 'alice',
}) async {
  final ImClient client = ImClient(optionsFor(
    gateway.connect,
    cursorStore: cursorStore,
    maxAutoRepairSeq: maxAutoRepairSeq,
    cursorSaveDebounce: cursorSaveDebounce,
    onTokenExpired: onTokenExpired,
    logger: logger,
    userId: userId,
  ));

  unawaited(client.connect());
  await pumpUntil(() => gateway.sockets.isNotEmpty, because: 'no socket was created');
  gateway.openLatest();
  await pumpUntil(
    () => client.state == ImConnectionState.open,
    because: 'the handshake never completed',
  );
  await pumpUntil(
    () => gateway.callsTo('conn.sync') > 0,
    because: 'the resume never issued conn.sync',
  );
  await settle();
  return client;
}

// ---------------------------------------------------------------------------- frame builders

Map<String, dynamic> reply(String id, String target, Map<String, dynamic> data) =>
    <String, dynamic>{
      'id': id,
      'target': target,
      'status': 0,
      'body': <String, dynamic>{'code': 0, 'serverTime': 1, 'data': data},
    };

Map<String, dynamic> push(String target, Map<String, dynamic> data) => <String, dynamic>{
      'id': 'srv-1',
      'target': target,
      'status': 0,
      'body': <String, dynamic>{'code': 0, 'serverTime': 1, 'data': data},
    };

Map<String, dynamic> message(String conversationId, int seq) => <String, dynamic>{
      'appId': 'demo',
      'conversationId': conversationId,
      'conversationType': 1,
      'seq': seq,
      'messageId': 1000 + seq,
      'clientMsgId': 'c$seq',
      'senderId': 'alice',
      'senderPlatform': 5,
      'contentType': 1,
      'content': <String, dynamic>{'text': 'm$seq'},
      'sendTime': 1,
      'createTime': 1,
    };

Map<String, dynamic> conversationView(
  String conversationId, {
  required int maxSeq,
  int updatedAt = 1,
}) =>
    <String, dynamic>{
      'conversationId': conversationId,
      'type': 1,
      'maxSeq': maxSeq,
      'readSeq': 0,
      'unreadCount': 0,
      'updatedAt': updatedAt,
    };

Map<String, dynamic> resumePage({
  List<Map<String, dynamic>> conversations = const <Map<String, dynamic>>[],
  Map<String, dynamic> gapsFrom = const <String, dynamic>{},
  bool hasMore = false,
  String? nextCursor,
}) =>
    <String, dynamic>{
      'conversations': conversations,
      'gapsFrom': gapsFrom,
      'hasMore': hasMore,
      if (nextCursor != null) 'nextCursor': nextCursor,
      'serverTime': 1,
    };

Map<String, dynamic> syncPage({
  required String conversationId,
  required List<int> seqs,
  required bool hasMore,
  int? maxSeq,
}) =>
    <String, dynamic>{
      'conversationId': conversationId,
      'messages': <Map<String, dynamic>>[
        for (final int seq in seqs) message(conversationId, seq),
      ],
      'maxSeq': maxSeq ?? (seqs.isEmpty ? 0 : seqs.last),
      'minSeq': 1,
      'hasMore': hasMore,
    };
