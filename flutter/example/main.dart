// A runnable end-to-end sample for package:cyaim_im.
//
//   dart run example/main.dart \
//     --endpoint wss://im.example.com --app-id demo --user alice --token "$IM_TOKEN"
//
// Deliberately plain Dart rather than a Flutter app. The package has no Flutter dependency, the
// interesting parts of an IM integration are not widgets, and a sample you can run in a terminal
// against your own deployment is worth more than one you have to build for a simulator first.
// The four Flutter-specific lines — where the cursor file lives, and when to flush it — are marked
// below and spelled out in README.md.
//
// 用纯 Dart 而不是 Flutter 应用：这个包不依赖 Flutter，接入里真正难的部分也不在 UI；
// 能在终端里直接连自己部署的样例，比必须先跑模拟器的样例有用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';

Future<void> main(List<String> arguments) async {
  final Map<String, String> args = _parseArgs(arguments);

  final String endpoint = args['endpoint'] ?? 'wss://im.example.com';
  final String appId = args['app-id'] ?? 'demo';
  final String userId = args['user'] ?? 'alice';
  final String token = args['token'] ?? Platform.environment['IM_TOKEN'] ?? '';
  final String deviceId = args['device'] ?? 'example-cli';

  if (token.isEmpty) {
    stderr.writeln(
      'No token. Mint a short-lived user token with your own backend and pass --token, or set '
      'IM_TOKEN. A client never holds an AppSecret.',
    );
    exitCode = 2;
    return;
  }

  // ---------------------------------------------------------------- 1. the cursor store
  //
  // Required, with no default, and this is the single most important line in the sample. Without
  // a persisted cursor the client cold-starts knowing nothing, `conn.sync` reports no gap for a
  // conversation it was told nothing about, the client adopts the server's newest seq, and every
  // message that arrived while the app was closed is skipped — silently.
  //
  // Scope by (host, appId, userId): not the device, which the file already is, but the account,
  // so switching users on a shared handset does not hand one user another's cursors.
  //
  // In Flutter this directory comes from path_provider:
  //   final Directory dir = await getApplicationSupportDirectory();
  final Directory directory = Directory('${Directory.systemTemp.path}/cyaim-im-example');
  final ImCursorScope scope = ImCursorScope.of(
    endpoint: endpoint,
    appId: appId,
    userId: userId,
  );
  final ImCursorStore cursors =
      ImCursorStore.file('${directory.path}/cursors-${scope.storageKey}.json');

  final ImClient im = ImClient(ImOptions(
    endpoint: endpoint,
    appId: appId,
    token: token,
    deviceId: deviceId,
    userId: userId,
    cursorStore: cursors,
    platform: ImPlatform.linux,
    language: 'en-US',
    // Called when the token has expired: on a live socket this costs one `conn.reauth` frame
    // instead of a full reconnect. Return a fresh token from your own backend, or null to stop.
    onTokenExpired: () async => Platform.environment['IM_TOKEN'],
    logger: (String message) => stdout.writeln('[sdk] $message'),
  ));

  // ---------------------------------------------------------------- 2. what to listen to

  im.states.listen((ImConnectionState state) => stdout.writeln('[conn] $state'));

  im.kicks.listen((ImKickEvent kick) {
    stdout.writeln('[kick] $kick');
    // Terminal means the SDK has stopped reconnecting on purpose: another device took over, the
    // token was revoked, the account was banned. Send the user back to a login screen; retrying
    // is a loop.
    if (kick.isTerminal) unawaited(_shutdown(im));
  });

  // Session-level failures nothing else is awaiting: a cursor store that would not load, an
  // interrupted resume, a repair that failed. Surfaced rather than logged because only the
  // application can decide what to do about them.
  im.errors.listen((ImException error) => stderr.writeln('[error] $error'));

  // A stretch of conversation the SDK deliberately did not backfill because it was wider than
  // maxAutoRepairSeq. The cursor has moved past it, so nothing else will ever mention it —
  // reload that conversation from history or the UI keeps a hole in it forever.
  im.conversationNeedsReload.listen((String conversationId) async {
    stdout.writeln('[reload] $conversationId is stale; refetching the tail from history');
    final ImPage<ImMessage> page =
        await im.msg.history(ImHistoryRequest(conversationId: conversationId, limit: 50));
    for (final ImMessage message in page.items.reversed) {
      _render(message);
    }
  });

  // Delivery is at-least-once, so deduplicate on messageId, and commit only once the message is
  // durably in *your* store. Committing from inside the callback because it returned would be
  // claiming durability for something that is still only in memory.
  im.messages.listen((ImMessage message) async {
    _render(message);
    await _saveToYourOwnDatabase(message);
    await im.commit(message.conversationId, message.seq);
  });

  await im.connect();

  // ---------------------------------------------------------------- 3. offline push
  //
  // The host app owns token acquisition; the SDK owns token delivery. In a Flutter app this is
  // whatever plugin you already use:
  //
  //   FirebaseMessaging.instance.onTokenRefresh.listen(
  //     (String t) => im.push.setToken(ImPushProvider.fcm, t));
  //   await im.push.setToken(
  //     ImPushProvider.fcm, await FirebaseMessaging.instance.getToken() ?? '');
  //
  // setToken registers immediately when connected and again on every later connect — not once at
  // install, because the vendor may replace the token while the process is frozen.
  final String? pushToken = Platform.environment['IM_PUSH_TOKEN'];
  if (pushToken != null && pushToken.isNotEmpty) {
    await im.push.setToken(ImPushProvider.fcm, pushToken, language: 'en-US');
    stdout.writeln('[push] registered ${im.push.provider} token');
  }

  // ---------------------------------------------------------------- 4. the typed surface

  final ImUserProfile me = await im.user.me();
  stdout.writeln('[me] ${me.userId} ${me.nickname ?? ''}');

  final ImPage<ImConversationView> conversations =
      await im.conv.list(const ImListConversationsRequest(limit: 20));
  stdout.writeln('[conv] ${conversations.items.length} conversations, '
      '${await im.conv.unreadTotal()} unread in total');
  for (final ImConversationView view in conversations.items) {
    stdout.writeln('  ${view.conversationId}  seq ${view.maxSeq}  '
        'unread ${view.unreadCount}  ${view.lastMessage?.digest ?? ''}');
  }

  _usage();
  await _repl(im);
  await _shutdown(im);
}

// ---------------------------------------------------------------------------- the REPL

Future<void> _repl(ImClient im) async {
  final Stream<String> lines = stdin.transform(utf8.decoder).transform(const LineSplitter());

  await for (final String line in lines) {
    final List<String> parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) continue;

    try {
      switch (parts.first) {
        case '/send' when parts.length >= 3:
          final ImSendResult result = await im.msg.send(ImSendMessageRequest.text(
            parts.sublist(2).join(' '),
            receiverId: parts[1],
          ));
          stdout.writeln('[sent] seq ${result.seq}'
              '${result.deduplicated ? ' (deduplicated — idempotency working)' : ''}');

        case '/history' when parts.length >= 2:
          final ImPage<ImMessage> page =
              await im.msg.history(ImHistoryRequest(conversationId: parts[1], limit: 20));
          for (final ImMessage message in page.items.reversed) {
            _render(message);
          }
          stdout.writeln('[history] hasMore ${page.hasMore}');

        case '/read' when parts.length >= 3:
          await im.conv.read(ImReadRequest(
            conversationId: parts[1],
            readSeq: int.parse(parts[2]),
          ));

        case '/typing' when parts.length >= 2:
          await im.msg.typing(ImTypingRequest(conversationId: parts[1]));

        case '/unread':
          stdout.writeln('[unread] ${await im.conv.unreadTotal()}');

        case '/cursors':
          stdout.writeln('[cursors] ${im.cursors}');

        case '/raw' when parts.length >= 2:
          // The escape hatch: any endpoint the typed surface does not cover yet. Same code path,
          // same timeouts, same error mapping — and it never touches a cursor.
          final Object? data = await im.invoke<Object?>(
            parts[1],
            parts.length > 2 ? jsonDecode(parts.sublist(2).join(' ')) : null,
          );
          stdout.writeln('[raw] ${jsonEncode(data)}');

        case '/quit':
          return;

        default:
          _usage();
      }
    } on ImException catch (error) {
      // Branch on the code, never on the message text. traceId and target are what turn a bug
      // report into a one-query investigation.
      stderr.writeln('[failed] $error  retryable=${error.isRetryable}');
      if (error.code == ImErrorCode.featureNotEnabled) {
        stderr.writeln('  the tenant has this feature switched off; it can be turned on at '
            'runtime, so keep calling');
      }
    }
  }
}

void _usage() => stdout.writeln(
      'commands: /send <userId> <text> · /history <conversationId> · /read <conversationId> <seq> '
      '· /typing <conversationId> · /unread · /cursors · /raw <target> [json] · /quit',
    );

void _render(ImMessage message) => stdout.writeln(
      '[${message.conversationId} #${message.seq}] ${message.senderId}: '
      '${message.content['text'] ?? message.contentType.name}',
    );

/// Stands in for the application's own durable write. [ImClient.commit] must follow *this*, not
/// the delivery callback returning — a callback returning only means the message reached memory,
/// which is exactly the state a crash loses.
Future<void> _saveToYourOwnDatabase(ImMessage message) async {}

Future<void> _shutdown(ImClient im) async {
  // logout, not disconnect: `push.unregister` has to go out **before** the socket closes, because
  // afterwards there is no authenticated channel on which to remove the token and the user keeps
  // getting notifications on a handset they logged out of.
  //
  // In Flutter, also call `im.flushCursors()` from AppLifecycleState.paused — a mobile OS can stop
  // the process without warning, and a debounced commit that never reached disk is a duplicate
  // delivery on the next launch.
  await im.logout();
  await im.dispose();
}

Map<String, String> _parseArgs(List<String> arguments) {
  final Map<String, String> parsed = <String, String>{};
  for (int i = 0; i < arguments.length - 1; i++) {
    if (arguments[i].startsWith('--')) {
      parsed[arguments[i].substring(2)] = arguments[i + 1];
    }
  }
  return parsed;
}
