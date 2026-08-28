using System;

namespace Cyaim.Im
{
    /// <summary>
    /// Everything <see cref="ImConnectionOptions"/> holds, plus the policies that belong to the
    /// message layer rather than the socket.
    /// </summary>
    public sealed class ImClientOptions : ImConnectionOptions
    {
        /// <summary>
        /// Default for <see cref="MaxAutoRepairSeq"/>: the same 500 every other Cyaim client SDK
        /// uses, so a user switching devices sees the same behaviour on each.
        /// </summary>
        public const long DefaultMaxAutoRepairSeq = 500;

        /// <summary>Default for <see cref="CursorFlushInterval"/>.</summary>
        public static readonly TimeSpan DefaultCursorFlushInterval = TimeSpan.FromMilliseconds(1000);

        /// <summary>
        /// Where committed cursors are kept between launches. <b>Required</b> — there is no default.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Almost every game wants <c>ImCursorStore.PersistentDataPath()</c>. A build with no local
        /// message store of its own — a bot, a load test, a kiosk — passes
        /// <c>ImCursorStore.InMemory()</c>, which is an explicit opt-out and logs one line saying so.
        /// </para>
        /// <para>
        /// This has no default on purpose. Defaulting to no persistence produced a silent data-loss
        /// bug in four of the five client SDKs (<c>sdk/CONTRACT.md</c> §5.1), and defaulting to
        /// <i>some</i> persistence would mean guessing where a game may write — a guess that is
        /// worse wrong than a constructor that refuses to run.
        /// </para>
        /// </remarks>
        public IImCursorStore CursorStore { get; private set; }

        /// <summary>
        /// Where the SDK's own runtime log lives between runs. <b>Optional; null means in memory.</b>
        /// </summary>
        /// <remarks>
        /// <para>
        /// Unlike <see cref="CursorStore"/> this has a default, and the asymmetry is deliberate:
        /// losing cursors loses a player's messages, while losing logs loses a diagnostic. Supplying
        /// one is what makes "pull a log from that device" answer questions about anything before the
        /// current process — a crash, a session that ended badly, the reconnect storm during a raid.
        /// Null keeps a bounded ring in memory, and the console shows a support engineer which of the
        /// two they are reading.
        /// </para>
        /// <para>
        /// The SDK does not pick a location for you — see <c>ADR-003</c>. Most games want
        /// <c>ImLogStore.File(Application.persistentDataPath + "/im.log")</c>, but that is the game's
        /// decision to make rather than the SDK's: it is about where its players' runtime detail may
        /// be written.
        /// SDK 不替你选写入位置：不提供也是一个完整的选择，而控制台会把这个区别显示出来。
        /// </para>
        /// </remarks>
        public IImLogStore LogStore { get; set; }

        /// <summary>
        /// Largest gap the client will backfill message by message before giving up and skipping
        /// the conversation forward.
        /// </summary>
        /// <remarks>
        /// <para>
        /// A player who was away for five minutes is a few messages behind and should have them
        /// pulled in silently. A player who was away for a week is behind by more messages than any
        /// chat UI can usefully receive at once, and fetching them all would spend the first ten
        /// seconds after launch downloading history nobody scrolled to.
        /// </para>
        /// <para>
        /// Past this many messages the cursor is moved to the server's position, committed, and the
        /// conversation id is raised on <see cref="ImClient.ConversationNeedsReload"/>. Both halves
        /// are mandatory: skipping the cursor advance makes every later message look like a gap and
        /// re-request a range you have already declined, and skipping the event leaves a hole in the
        /// UI that nothing will ever mention.
        /// </para>
        /// <para>
        /// Raising it above 500 does not buy a bigger single call — the server clamps
        /// <c>msg.sync</c> to 500 whatever you ask for — it buys more iterations of the repair loop.
        /// That is fine and intended.
        /// </para>
        /// </remarks>
        public long MaxAutoRepairSeq { get; set; }

        /// <summary>
        /// How long ordinary commits may sit unwritten before the store is asked to save.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Coalescing matters: a player scrolling a busy group can commit a hundred times a second,
        /// and a hundred file writes a second on a phone is a battery complaint. The debounce is
        /// flushed regardless before every <c>conn.sync</c>, when the app is backgrounded, and on
        /// <see cref="ImClient.Disconnect"/> / <see cref="ImClient.Dispose"/>.
        /// </para>
        /// <para>
        /// <b>Adoption is never debounced</b>, whatever this is set to. The asymmetry is deliberate:
        /// a lost debounced commit costs one duplicate delivery, while a lost adoption costs silent
        /// permanent data loss — the next cold start sees no entry, adopts a newer <c>maxSeq</c>,
        /// and drops everything in between.
        /// </para>
        /// <para><see cref="TimeSpan.Zero"/> writes through on every commit. There is no ceiling.</para>
        /// </remarks>
        public TimeSpan CursorFlushInterval { get; set; }

        /// <summary>
        /// Guard on the <c>msg.sync</c> repair loop: how many pages one gap may take before the SDK
        /// gives up and treats it as an oversized gap.
        /// </summary>
        /// <remarks>
        /// A server that reports <c>hasMore</c> forever would otherwise spin a client until the
        /// battery ran out. Hitting the cap raises
        /// <see cref="ImClient.ConversationNeedsReload"/> exactly as an oversized gap does, so the
        /// failure is visible rather than silent.
        /// </remarks>
        public int MaxRepairPages { get; set; }

        /// <summary>
        /// The two settings that have no safe default, taken where the compiler can insist on them.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Both used to be settable properties checked at construction, which made this the only
        /// one of the five SDKs enforcing the required cursor store at <i>runtime</i> — the other
        /// four take it as a constructor argument and refuse to compile without one. A missing
        /// store is a data-loss bug (§5.1) and a missing user id silently disables the
        /// account-switch guarantee (§5.3); neither is a thing to discover when a player launches
        /// the build.
        /// </para>
        /// <para>
        /// Everything else stays an object-initialiser property, because everything else has a
        /// defensible default:
        /// <code>
        /// var options = new ImClientOptions(ImCursorStore.PersistentDataPath(scope), "alice")
        /// {
        ///     Endpoint = "wss://im.example.com",
        ///     AppId = "app-1",
        ///     Token = token,
        ///     DeviceId = ImDevice.GetOrCreateDeviceId(),
        /// };
        /// </code>
        /// </para>
        /// </remarks>
        /// <param name="cursorStore">
        /// Where committed cursors are kept between launches. <c>ImCursorStore.PersistentDataPath</c>
        /// for almost every game; <c>ImCursorStore.InMemory()</c> to opt out explicitly and accept
        /// that every cold start re-adopts the server's position.
        /// </param>
        /// <param name="userId">
        /// The signed-in user. Not sent in the handshake — the gateway reads the identity out of
        /// the token — but the third component of the cursor scope, and the one that keeps two
        /// accounts on one device apart.
        /// </param>
        public ImClientOptions(IImCursorStore cursorStore, string userId)
        {
            if (cursorStore == null)
            {
                throw new ArgumentNullException(
                    "cursorStore",
                    "the cursor store has no default. Pass ImCursorStore.PersistentDataPath(scope) " +
                    "to keep cursors between launches, or ImCursorStore.InMemory() to opt out " +
                    "explicitly — in which case every cold start adopts the server's position and " +
                    "messages that arrived while the app was closed are never delivered. " +
                    "See sdk/CONTRACT.md §5.3.");
            }

            if (string.IsNullOrEmpty(userId))
            {
                throw new ArgumentException(
                    "userId is required: it is the third component of the cursor store's scope key " +
                    "and the only thing that stops account switching on a shared device from " +
                    "handing one user another's cursors (sdk/CONTRACT.md §5.3).",
                    "userId");
            }

            CursorStore = cursorStore;
            UserId = userId;
            MaxAutoRepairSeq = DefaultMaxAutoRepairSeq;
            CursorFlushInterval = DefaultCursorFlushInterval;
            MaxRepairPages = 64;
        }
    }
}
