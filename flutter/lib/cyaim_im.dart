/// Client SDK for Cyaim IM Cloud.
///
/// Multiplexed WebSocket, full-jitter reconnect, kick-aware close handling, and a two-cursor
/// delivery model that survives a process restart — from one codebase on iOS, Android, Windows,
/// macOS, Linux and web.
library;

export 'src/api.dart'
    show
        ImConnApi,
        ImConvApi,
        ImFriendApi,
        ImGroupApi,
        ImMediaApi,
        ImModerationApi,
        ImMsgApi,
        ImPushApi,
        ImRequester,
        ImUserApi;
export 'src/backoff.dart' show FullJitterBackoff;
export 'src/cancel.dart' show ImCancelToken, ImCancelledException;
export 'src/client.dart' show ImClient;
export 'src/connection.dart' show ImConnection;
export 'src/cursor_store.dart'
    show ImCursorScope, ImCursorSnapshot, ImCursorStore, ImInMemoryCursorStore;
export 'src/logging.dart' show ImLogger, defaultImLogger;
export 'src/models.dart';
export 'src/options.dart' show ImConnectionState, ImOptions;
export 'src/protocol.dart';
export 'src/requests.dart';
export 'src/socket.dart'
    show ImSocket, ImSocketFactory, WebSocketChannelSocket, defaultImSocketFactory;
export 'src/version.dart' show ImSdk;
