import Foundation

/// Who this build is, in the two numbers a support engineer asks for.
///
/// The package version and the contract version are separate on purpose. The package version says
/// which build of *this* SDK you are running; the contract version says which
/// [`CONTRACT.md`](https://github.com/Cyaim/im-cloud-sdk/blob/main/CONTRACT.md) it implements, and
/// therefore which endpoints exist on every platform at once. A ticket carrying both answers "which
/// endpoints do you have" without anyone having to ask which platform the customer is on.
///
/// 两个版本号刻意分开：包版本说明这份构建，契约版本说明它实现的是哪一版五端契约。
public enum ImSdk {
    /// This package's version. Sent as the `cv` handshake parameter and bumped in lockstep with the
    /// other four SDKs — one number identifies a contract, not a platform.
    ///
    /// Spelled `packageVersion` because that is what the other four call it. It was `version` here,
    /// `version` on the JVM, `packageVersion` in Dart and `PackageVersion` in C#: three names for
    /// one number, which turns "quote your SDK version" into a per-platform lookup at exactly the
    /// moment nobody has time for one.
    public static let packageVersion = "0.9.0"

    /// The client contract this build implements. Sourced from `sdk/endpoint-inventory.json`.
    public static let contractVersion = "1.0"

    /// What goes into `cv` when the host app has not named itself.
    public static let userAgent = "cyaim-swift/\(packageVersion)"

    @available(*, deprecated, renamed: "packageVersion", message: "Renamed to packageVersion, the name the other four SDKs use. Removed in 2.0.")
    public static var version: String { packageVersion }
}

/// Warnings the SDK has to say out loud.
///
/// There are only a handful of them and every one names the section of the contract it comes from,
/// because the failures they warn about — cursors that are not persisted, a push token that was
/// never registered — are all silent otherwise, and a silent failure costs a support cycle every
/// time somebody hits it.
enum ImLog {
    static func warn(_ message: String, using handler: (@Sendable (String) -> Void)?) {
        if let handler {
            handler(message)
            return
        }

        FileHandle.standardError.write(Data("[CyaimIM] warning: \(message)\n".utf8))
    }
}

/// Things the SDK needs to tell the application that are neither a message nor a connection state.
///
/// Every case here exists because the alternative is a hole nobody is told about. A conversation the
/// SDK declined to backfill, cursors it could not load, a push token it is holding but has never
/// registered — each of those leaves the app quietly wrong, and only the app can put it right.
///
/// ```swift
/// Task {
///     for await event in im.sessionEvents() {
///         switch event {
///         case .conversationNeedsReload(let conversationId, _, _):
///             await store.reloadFromHistory(conversationId)
///         case .cursorStoreUnavailable(let error):
///             await store.rederiveCursors(into: im, because: error)
///         default:
///             log(event)
///         }
///     }
/// }
/// ```
public enum ImSessionEvent: Sendable, Hashable {
    /// A stretch of a conversation was skipped rather than backfilled, because it was longer than
    /// ``ImClientOptions/maxAutoRepairSeq``.
    ///
    /// Both cursors have already moved to `toSeq`, so no later message will look like a gap. The
    /// range `fromSeq ... toSeq` is *not* in the message stream and never will be — reload the
    /// conversation from ``ImClient/history(of:before:limit:)`` if the user opens it.
    case conversationNeedsReload(conversationId: String, fromSeq: Int64, toSeq: Int64)

    /// ``ImCursorStore/load()`` failed, so the SDK does not know what this device already holds.
    ///
    /// It will not adopt, and it will not advance a cursor for the rest of the session — a failed
    /// load and a fresh install are indistinguishable to the adoption branch, and adopting on a
    /// failed load destroys history that is sitting intact in your own database. Re-derive the
    /// cursors from your own store and hand them back with ``ImClient/commit(_:seq:)`` (which is
    /// monotonic, and exists partly for this), or accept a re-download.
    case cursorStoreUnavailable(ImError)

    /// The client was built with ``ImCursorStore/inMemory()``, so nothing survives this launch.
    ///
    /// Emitted once, on the first connect, alongside a logged warning.
    case cursorsNotPersisted

    /// A push token was supplied but no `push.register` has ever succeeded on this client.
    ///
    /// A device in this state is indistinguishable from a broken push provider, and that
    /// misdiagnosis costs a support cycle every time.
    case pushTokenNotRegistered(provider: String, lastError: ImError?)
}
