using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using Cyaim.Im.Json;
using UnityEngine;

namespace Cyaim.Im
{
    /// <summary>
    /// Where the SDK keeps the two numbers that decide what a cold start downloads.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This interface exists because of a specific data-loss bug, described in full in
    /// <c>sdk/CONTRACT.md</c> §5.1. A client that starts with no cursors reports nothing in
    /// <c>conn.sync</c>'s <c>convSeqs</c>; the server can only compute a gap for a conversation the
    /// client reported, so it reports none; the client then takes the server's <c>maxSeq</c> as its
    /// position, and every message that arrived while the app was closed is now behind the cursor.
    /// It is never requested, never arrives, and nothing anywhere says so.
    /// </para>
    /// <para>
    /// Which is why the store is a <b>required</b> option (<see cref="ImClientOptions.CursorStore"/>)
    /// rather than something with a default. There is no safe default: a wrong guess about where a
    /// game may write is worse than a loud error at construction, and defaulting to "no persistence"
    /// is exactly what produced the bug. An integrator who genuinely does not want persistence
    /// passes <see cref="ImCursorStore.InMemory"/>, which says so once in the log.
    /// </para>
    /// <para>
    /// <b>Lifetime.</b> This store and the game's own message store have exactly one lifetime.
    /// Whatever destroys one destroys the other, cursors first. Clearing messages but keeping
    /// cursors leaves a conversation the app will never refill; clearing cursors but keeping
    /// messages costs a full re-download and duplicate delivery.
    /// </para>
    /// <para>
    /// 冷启动丢消息的根因见 CONTRACT §5.1：客户端不报 convSeqs，服务端就算不出缺口，
    /// 客户端再把服务端的 maxSeq 当作自己的位置——关机期间到达的消息就此永久落在游标后面。
    /// </para>
    /// </remarks>
    public interface IImCursorStore
    {
        /// <summary>
        /// Reads the stored snapshot. Called once, before the first connect.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Throwing is a legitimate answer and is <i>not</i> treated as "fresh install" — see
        /// <see cref="ImClient.CursorStoreFailed"/>. A failed load and a fresh install look
        /// identical to the adoption branch, and adopting on a failed load destroys history that is
        /// sitting intact in the game's own database.
        /// </para>
        /// <para>
        /// There is no <c>scope</c> parameter. The interface is exactly <c>Load</c> / <c>Save</c> —
        /// the shape <c>sdk/CONTRACT.md</c> §5.3 specifies, and the same two members the other
        /// four SDKs expose. The account identity travels inside
        /// <see cref="ImCursorSnapshot.Scope"/> instead, which the SDK stamps on every write and
        /// checks on every read: a store handed the scope as an argument can still ignore it, and a
        /// store that never sees it cannot defeat the check at all.
        /// </para>
        /// </remarks>
        ImCursorSnapshot Load();

        /// <summary>
        /// Persists the snapshot. The SDK may call this often; see
        /// <see cref="ImClientOptions.CursorFlushInterval"/> for what is coalesced and what is not.
        /// </summary>
        void Save(ImCursorSnapshot snapshot);
    }

    /// <summary>
    /// Which account's cursors are being read or written: endpoint host, app id, user id.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The device id is deliberately <i>not</i> part of the key — the store is already local to the
    /// device. The user id is, and that is the point: without it, two accounts sharing a handset
    /// read each other's cursors, and the second one to sign in silently skips whatever the first
    /// one had already consumed.
    /// </para>
    /// <para>
    /// The SDK stamps <see cref="Key"/> into every snapshot it writes and refuses one carrying
    /// somebody else's, so the guarantee holds even for a store that knows nothing about scoping.
    /// <see cref="StorageKey"/> is for the built-in stores that pick their own file name and want
    /// one file per account — which is what makes signing back *in* to an earlier account find
    /// its cursors instead of re-downloading.
    /// </para>
    /// </remarks>
    public readonly struct ImCursorScope
    {
        /// <summary>Gateway host, without scheme or port.</summary>
        public string Host { get; }

        /// <summary>Tenant id.</summary>
        public string AppId { get; }

        /// <summary>The signed-in user. Empty when the host app never set
        /// <see cref="ImConnectionOptions.UserId"/>, which the SDK warns about once.</summary>
        public string UserId { get; }

        /// <inheritdoc cref="ImCursorScope"/>
        public ImCursorScope(string host, string appId, string userId)
        {
            Host = host ?? string.Empty;
            AppId = appId ?? string.Empty;
            UserId = userId ?? string.Empty;
        }

        /// <summary>
        /// Builds a scope from an endpoint URL, taking only its host. The scheme and port are left
        /// out on purpose: moving a deployment from <c>ws://</c> to <c>wss://</c>, or off a
        /// development port, must not orphan the cursors already on the device.
        /// </summary>
        public static ImCursorScope Of(string endpoint, string appId, string userId)
        {
            return new ImCursorScope(HostOf(endpoint), appId, userId);
        }

        /// <summary>Former name of <see cref="Of"/>. The other four SDKs spell it <c>of</c>.</summary>
        [Obsolete("Renamed to ImCursorScope.Of, matching the other four SDKs. Removed in 2.0.")]
        public static ImCursorScope For(string endpoint, string appId, string userId)
        {
            return Of(endpoint, appId, userId);
        }

        /// <summary>
        /// The identity stamped into <see cref="ImCursorSnapshot.Scope"/> and compared on load:
        /// <c>host|appId|userId</c>. Spelled the same way in all five SDKs, so a snapshot written by
        /// one is legible to the others.
        /// </summary>
        public string Key
        {
            get
            {
                return Host + "|" + AppId + "|" + (string.IsNullOrEmpty(UserId) ? "*" : UserId);
            }
        }

        /// <summary>
        /// A stable, filesystem- and PlayerPrefs-safe rendering of the same identity. Same three
        /// inputs always produce the same string, on every platform.
        /// </summary>
        public string StorageKey
        {
            get
            {
                var key = new StringBuilder(96);
                Append(key, Host);
                key.Append('_');
                Append(key, AppId);
                key.Append('_');
                Append(key, string.IsNullOrEmpty(UserId) ? "anonymous" : UserId);
                return key.ToString();
            }
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            return Host + "/" + AppId + "/" + (string.IsNullOrEmpty(UserId) ? "(no userId)" : UserId);
        }

        private static string HostOf(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint))
            {
                return string.Empty;
            }

            Uri parsed;
            if (Uri.TryCreate(endpoint, UriKind.Absolute, out parsed))
            {
                return parsed.Host;
            }

            return endpoint;
        }

        /// <summary>
        /// Copies a segment, replacing anything that is not plainly safe. Ids are tenant-chosen and
        /// have been seen to contain slashes and colons; one of those in a file name is a write that
        /// lands somewhere else or not at all.
        /// </summary>
        private static void Append(StringBuilder target, string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                target.Append('-');
                return;
            }

            for (int i = 0; i < value.Length; i++)
            {
                var c = value[i];
                var safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                           c == '-' || c == '.';
                target.Append(safe ? c : '_');
            }
        }
    }

    /// <summary>
    /// What the SDK persists: how far each conversation is durably stored, and how far the
    /// conversation list itself has been consumed.
    /// </summary>
    public sealed class ImCursorSnapshot
    {
        /// <summary>
        /// conversationId to <c>committedSeq</c> — the highest seq the <i>application</i> has said
        /// it has durably stored, never the highest the SDK has delivered. This is the map reported
        /// as <c>convSeqs</c>, and reporting the delivered one instead is the bug in §5.1.
        /// </summary>
        public Dictionary<string, long> ConvSeqs { get; private set; }

        /// <summary>
        /// Highest <c>ConversationView.updatedAt</c> from a <i>completed</i> <c>conn.sync</c> run.
        /// </summary>
        /// <remarks>
        /// The list is sorted by <c>updatedAt</c> descending, so page one holds the newest value.
        /// Advancing this before the run finishes pushes the cursor past every conversation on the
        /// pages that were never read, and the server will never return them again.
        /// </remarks>
        public long ConversationCursor { get; set; }

        /// <summary>
        /// Which <see cref="ImCursorScope"/> these cursors belong to, as
        /// <see cref="ImCursorScope.Key"/>. Stamped by the SDK on every write.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>This field is the account-switch guarantee, and it lives in the payload rather than in
        /// the store's signature on purpose.</b> A store is a few lines an integrator writes; a
        /// store that keys itself per account is a few lines an integrator <i>remembers</i> to
        /// write. Carrying the identity here means the SDK can refuse cursors belonging to somebody
        /// else even when the store did nothing to keep two accounts apart — so a game that does
        /// nothing special cannot get it wrong.
        /// </para>
        /// <para>
        /// Null or empty on a snapshot the SDK has never written. That is accepted, and the next
        /// save stamps it.
        /// </para>
        /// </remarks>
        public string Scope { get; set; }

        /// <inheritdoc cref="ImCursorSnapshot"/>
        public ImCursorSnapshot()
        {
            ConvSeqs = new Dictionary<string, long>(StringComparer.Ordinal);
        }

        /// <summary>An independent copy, so a store can serialise off the SDK's live map.</summary>
        public ImCursorSnapshot Clone()
        {
            var copy = new ImCursorSnapshot { ConversationCursor = ConversationCursor, Scope = Scope };
            foreach (var entry in ConvSeqs)
            {
                copy.ConvSeqs[entry.Key] = entry.Value;
            }

            return copy;
        }

        /// <summary>Serialises to the on-disk shape used by the built-in stores.</summary>
        public string ToJson()
        {
            var seqs = JsonValue.NewObject();
            foreach (var entry in ConvSeqs)
            {
                seqs.Set(entry.Key, entry.Value);
            }

            var root = JsonValue.NewObject()
                .Set("version", 1L)
                .Set("conversationCursor", ConversationCursor)
                .Set("convSeqs", seqs);

            if (!string.IsNullOrEmpty(Scope))
            {
                root.Set("scope", Scope);
            }

            return root.ToJson();
        }

        /// <summary>
        /// Reads the on-disk shape. Throws <see cref="ImJsonException"/> on text that is not JSON —
        /// deliberately, because a truncated file must reach
        /// <see cref="ImClient.CursorStoreFailed"/> rather than be mistaken for a fresh install.
        /// </summary>
        public static ImCursorSnapshot FromJson(string text)
        {
            var root = JsonValue.Parse(text);
            if (!root.IsObject)
            {
                throw new ImJsonException("a cursor snapshot must be a JSON object", 0);
            }

            var snapshot = new ImCursorSnapshot
            {
                ConversationCursor = root["conversationCursor"].AsLong(),
                Scope = root["scope"].AsString(null),
            };

            foreach (var member in root["convSeqs"].Members)
            {
                // Zero entries are kept, not dropped. A conversation that existed with no messages
                // yet is a conversation this device has already been told about, and forgetting it
                // would make the next start treat it as first sight and adopt whatever maxSeq it
                // has grown to — skipping every message it gained in between. Zero is filtered only
                // where it goes onto the wire, because there the server reads absent and 0 alike.
                snapshot.ConvSeqs[member.Key] = member.Value.AsLong();
            }

            return snapshot;
        }
    }

    /// <summary>
    /// The stores that ship with the SDK. Each one is an explicit choice; there is no default.
    /// </summary>
    public static class ImCursorStore
    {
        /// <summary>Folder under <c>Application.persistentDataPath</c> used when none is named.</summary>
        public const string DefaultSubdirectory = "cyaim-im";

        /// <summary>
        /// Keeps cursors under <c>Application.persistentDataPath</c>, one file per account. The
        /// right answer for almost every game.
        /// </summary>
        /// <remarks>
        /// On WebGL this delegates to <see cref="PlayerPrefs"/>: a browser build's
        /// <c>persistentDataPath</c> is an IndexedDB image that Unity flushes on its own schedule,
        /// and a cursor written into a flush that never happened is the §5.5 failure exactly.
        /// <c>PlayerPrefs</c> is synchronous there and is what the device id already uses.
        /// </remarks>
        /// <param name="scope">
        /// Whose cursors these are. Required, because this factory picks the file name and keys it
        /// per account: signing back in as an earlier account then finds its cursors intact rather
        /// than re-baselining to the server's position. Build it with
        /// <see cref="ImCursorScope.Of"/> from the same endpoint, app id and user id you pass to
        /// <see cref="ImClientOptions"/>.
        /// </param>
        /// <param name="subdirectory">Folder name under the persistent data path.</param>
        public static IImCursorStore PersistentDataPath(
            ImCursorScope scope,
            string subdirectory = DefaultSubdirectory)
        {
            if (Application.platform == RuntimePlatform.WebGLPlayer)
            {
                return PlayerPrefs(scope);
            }

            var root = Path.Combine(Application.persistentDataPath, string.IsNullOrEmpty(subdirectory)
                ? DefaultSubdirectory
                : subdirectory);

            return new ImFileCursorStore(Path.Combine(root, scope.StorageKey + ".cursors.json"));
        }

        /// <summary>
        /// Keeps cursors in one file at a path you choose. For a headless build, a dedicated server,
        /// or an editor tool that has nowhere else to put them.
        /// </summary>
        /// <remarks>
        /// The path is used verbatim, so a host that runs two accounts through one process must give
        /// each its own path — unlike <see cref="PersistentDataPath"/>, which derives the file name
        /// from the scope and cannot collide. Point two accounts at one path and the SDK notices,
        /// because the snapshot carries its scope, and starts clean rather than handing the second
        /// user the first one's cursors; the first account's cursors are gone once the second one
        /// writes. <c>ImCursorScope.Of(…).StorageKey</c> in the file name is the whole fix.
        /// </remarks>
        public static IImCursorStore File(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                throw new ArgumentException("path is required", "path");
            }

            return new ImFileCursorStore(path);
        }

        /// <summary>Keeps cursors in <c>UnityEngine.PlayerPrefs</c>, one entry per account.</summary>
        /// <remarks>
        /// Small and synchronous, and the only thing that reliably survives on WebGL.
        /// <c>PlayerPrefs</c> is not a database: a snapshot for a user with thousands of
        /// conversations belongs in a file.
        /// </remarks>
        public static IImCursorStore PlayerPrefs(
            ImCursorScope scope,
            string keyPrefix = "cyaim.im.cursors.")
        {
            return new ImPlayerPrefsCursorStore((keyPrefix ?? string.Empty) + scope.StorageKey);
        }

        /// <summary>
        /// Keeps cursors for the life of the process and no longer. An explicit opt-out of
        /// persistence, and it logs one warning naming <c>sdk/CONTRACT.md</c> §5.3 to say so.
        /// </summary>
        /// <remarks>
        /// Legitimate for a bot, a load test, or a kiosk build that has no local message store to
        /// keep in step. In a player-facing app it means every cold start re-adopts the server's
        /// position, which is the data loss this whole mechanism exists to prevent.
        /// </remarks>
        public static IImCursorStore InMemory()
        {
            return new ImMemoryCursorStore();
        }
    }

    /// <summary>Snapshots held in a field. See <see cref="ImCursorStore.InMemory"/>.</summary>
    internal sealed class ImMemoryCursorStore : IImCursorStore
    {
        private ImCursorSnapshot _held;

        public ImCursorSnapshot Load()
        {
            // No warning here. <see cref="ImClient"/> raises the one §5.3 asks for, because whether
            // the game is told it is running without persistence is not a store's decision to make:
            // a store that could answer that question could also answer it wrongly, and three of
            // the five SDKs let any custom store do exactly that.
            return _held != null ? _held.Clone() : new ImCursorSnapshot();
        }

        public void Save(ImCursorSnapshot snapshot)
        {
            _held = snapshot.Clone();
        }
    }

    /// <summary>One JSON file per account. See <see cref="ImCursorStore.PersistentDataPath"/>.</summary>
    internal sealed class ImFileCursorStore : IImCursorStore
    {
        private readonly string _path;

        internal ImFileCursorStore(string path)
        {
            _path = path;
        }

        public ImCursorSnapshot Load()
        {
            var path = _path;
            if (!System.IO.File.Exists(path))
            {
                // Genuinely absent, which is a fresh install and the one case where adoption is
                // correct. Unreadable is a different answer and is allowed to throw.
                return new ImCursorSnapshot();
            }

            return ImCursorSnapshot.FromJson(System.IO.File.ReadAllText(path, Encoding.UTF8));
        }

        public void Save(ImCursorSnapshot snapshot)
        {
            var path = _path;
            var folder = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(folder) && !Directory.Exists(folder))
            {
                Directory.CreateDirectory(folder);
            }

            // Write beside the target and swap. A half-written cursor file is worse than an old
            // one: the old one costs duplicate delivery, the truncated one costs the whole
            // snapshot, and a game is killed mid-write by the OS more often than anyone expects.
            var temporary = path + ".tmp";
            System.IO.File.WriteAllText(temporary, snapshot.ToJson(), Encoding.UTF8);

            try
            {
                if (System.IO.File.Exists(path))
                {
                    System.IO.File.Replace(temporary, path, null);
                }
                else
                {
                    System.IO.File.Move(temporary, path);
                }
            }
            catch (Exception error)
            {
                // Some platforms and some filesystems do not implement Replace. Falling back is
                // strictly worse — there is a window where neither file is the snapshot — but it is
                // better than never writing at all.
                ImLog.Warn("atomic cursor write is unavailable here; falling back to delete-and-move", error);
                System.IO.File.Delete(path);
                System.IO.File.Move(temporary, path);
            }
        }
    }

    /// <summary>One PlayerPrefs entry per account. See <see cref="ImCursorStore.PlayerPrefs"/>.</summary>
    internal sealed class ImPlayerPrefsCursorStore : IImCursorStore
    {
        private readonly string _prefix;

        internal ImPlayerPrefsCursorStore(string prefix)
        {
            _prefix = prefix;
        }

        public ImCursorSnapshot Load()
        {
            var text = UnityEngine.PlayerPrefs.GetString(_prefix, null);
            return string.IsNullOrEmpty(text) ? new ImCursorSnapshot() : ImCursorSnapshot.FromJson(text);
        }

        public void Save(ImCursorSnapshot snapshot)
        {
            UnityEngine.PlayerPrefs.SetString(_prefix, snapshot.ToJson());

            // Save() rather than leaving it to the player loop: the writes that matter most are the
            // ones taken as the app is being suspended, and an unflushed PlayerPrefs is discarded
            // when the OS kills the process.
            UnityEngine.PlayerPrefs.Save();
        }
    }

    /// <summary>
    /// Raised when the cursor store could not be read. Carries what the store threw.
    /// </summary>
    /// <remarks>
    /// The SDK's response to this is deliberately conservative and is described in
    /// <c>sdk/CONTRACT.md</c> §5.8: it refuses to adopt any conversation and refuses to advance any
    /// cursor for the rest of the session. Delivery keeps working; nothing is persisted. The app
    /// decides whether to re-derive cursors from its own store — the correct fix, and the reason
    /// <see cref="ImClient.Commit"/> is monotonic — or to accept a re-download next launch.
    /// </remarks>
    public sealed class ImCursorStoreException : Exception
    {
        /// <summary>The account whose snapshot could not be read.</summary>
        public ImCursorScope Scope { get; private set; }

        /// <inheritdoc cref="ImCursorStoreException"/>
        public ImCursorStoreException(ImCursorScope scope, Exception inner)
            : base("the cursor store could not be read for " + scope +
                   "; no conversation will be adopted and no cursor will be persisted this session " +
                   "(sdk/CONTRACT.md §5.8)", inner)
        {
            Scope = scope;
        }
    }

    /// <summary>Numbers the SDK reports about itself. Quote <see cref="ContractVersion"/> in a ticket.</summary>
    public static class ImSdk
    {
        /// <summary>
        /// Version of <c>sdk/CONTRACT.md</c> this build implements. Sourced from
        /// <c>sdk/endpoint-inventory.json</c> and identical across all five client SDKs, so it
        /// answers "which endpoints do you have" without anyone having to ask which platform.
        /// </summary>
        public const string ContractVersion = "1.0";

        /// <summary>
        /// This package's version, sent as the <c>cv</c> handshake parameter by default. Kept equal
        /// to <c>package.json</c> by <c>VersionGuardTests</c>, which also checks that all five SDKs
        /// carry the same number (<c>sdk/CONTRACT.md</c> §9.1).
        /// </summary>
        public const string PackageVersion = "0.9.0";
    }
}
