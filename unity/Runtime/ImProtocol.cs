using System;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// Business result codes carried inside the response body, mirroring docs/SPEC-02-protocol.md §4.
    /// </summary>
    /// <remarks>
    /// <para>
    /// These are published API: a value that has shipped never changes meaning. The codes listed are
    /// the ones a client can reach; the console-only (<c>1800–1899</c>) and payment-operations
    /// (<c>1900–1999</c>) bands are deliberately absent, because SPEC-02 §4 says the tenant face and
    /// the gateway face never return them. <see cref="ImException.Code"/> carries whatever the
    /// server sent whether it is named here or not, so a new server-side code never becomes an
    /// unhandled crash in an old build.
    /// </para>
    /// <para>
    /// <b>This table must agree with the other four SDKs', and something now checks that.</b> Until
    /// 2026-09-09 it carried 42 of the 66 codes the TypeScript, Kotlin, Swift and Flutter tables all
    /// carry — 24 missing, 19 of them raised by calls this SDK already types. Nothing caught it
    /// because no test in either repository read an SDK error table at all: a game handling
    /// <c>1406 DuplicateClientMessageId</c> had to hardcode the number, and one handling
    /// <c>1509 JoinForbidden</c> by waiting for <c>evt.group</c> waited forever. The guard is
    /// <c>IM.Tests.Unit/SdkErrorCodeParityTests.cs</c> in the server repository, which reads all
    /// five tables off disk against the server's own <c>ImErrorCode</c>.
    /// 这张表必须与另外四个 SDK 一致，而现在有东西在查了：到 2026-09-09 为止它只有 66 个里的 42 个。
    /// 没人发现，是因为两个仓库里没有任何一条测试读过 SDK 的错误码表。
    /// </para>
    /// </remarks>
    public static class ImErrorCode
    {
        /// <summary>Success.</summary>
        public const int Ok = 0;

        /// <summary>Unhandled server-side failure.</summary>
        public const int InternalError = 1000;

        /// <summary>The request body failed validation.</summary>
        public const int InvalidArgument = 1001;

        /// <summary>The addressed entity does not exist.</summary>
        public const int NotFound = 1002;

        /// <summary>Rate limit hit. Back off; do not retry in a tight loop.</summary>
        public const int RateLimited = 1003;

        /// <summary>No reply arrived before the request deadline.</summary>
        public const int Timeout = 1004;

        /// <summary>Raised locally when a request is issued with no open socket.</summary>
        public const int ServiceUnavailable = 1005;

        /// <summary>The operation conflicts with the current state.</summary>
        public const int Conflict = 1006;

        /// <summary>The frame was larger than the gateway accepts.</summary>
        public const int PayloadTooLarge = 1007;

        /// <summary>
        /// This deployment has no such endpoint.
        /// </summary>
        /// <remarks>
        /// Distinct from <see cref="NotFound"/> on purpose: 1002 means "your group does not exist",
        /// 1008 means "this server does not have this call". It is what an SDK newer than a private
        /// deployment's server produces, and an integrator needs that verbatim rather than as a
        /// mystery missing entity.
        /// </remarks>
        public const int UnsupportedOperation = 1008;

        /// <summary>The connection is not authenticated.</summary>
        public const int Unauthorized = 1100;

        /// <summary>The user token has expired; mint a new one.</summary>
        public const int TokenExpired = 1101;

        /// <summary>The user token is malformed or was issued for another app.</summary>
        public const int TokenInvalid = 1102;

        /// <summary>Authenticated, but not allowed to do this.</summary>
        public const int Forbidden = 1103;

        /// <summary>The account is banned.</summary>
        public const int UserBanned = 1104;

        /// <summary>The request signature did not verify, or its headers were incomplete.</summary>
        /// <remarks>
        /// Seen from a game client only when a tenant backend minted the token; the SDK itself never
        /// signs. Distinct from <see cref="TokenInvalid"/> because the fix is on the tenant's server.
        /// </remarks>
        public const int SignatureInvalid = 1105;

        /// <summary>A signed request arrived a second time, or outside its timestamp window.</summary>
        public const int ReplayDetected = 1106;

        /// <summary>Another device took this session over under the multi-login policy.</summary>
        public const int KickedByOtherDevice = 1107;

        /// <summary>The page's origin is not on the app's web allowlist. A tenant sets that list in the console; it does not vary by user, so retrying or re-authenticating will not help and the SDK must not.</summary>
        /// <remarks>页面来源不在该应用的 Web 安全域名表里。这张表由租户在控制台设置、与用户无关——重试或重新登录都没有用，SDK 也不该那么做。</remarks>
        public const int OriginNotAllowed = 1109;

        /// <summary>No app with this <c>appId</c> exists in this deployment.</summary>
        /// <remarks>
        /// Almost always a build pointed at the wrong environment: the id is a staging app and the
        /// endpoint is production, or the reverse. Retrying cannot help.
        /// </remarks>
        public const int AppNotFound = 1200;

        /// <summary>The tenant app was disabled in the console.</summary>
        public const int AppDisabled = 1201;

        /// <summary>The tenant is over a plan limit. Never retry; surface the code.</summary>
        public const int QuotaExceeded = 1202;

        /// <summary>
        /// The tenant has this feature switched off, or the module is not deployed.
        /// </summary>
        /// <remarks>
        /// <b>Never latch this locally.</b> A tenant can flip <c>EnablePresence</c>,
        /// <c>EnableTypingIndicator</c>, <c>EnableSearch</c> or <c>EnableOfflinePush</c> at runtime,
        /// and a client that remembers "typing is off" stays broken until the app restarts. Report
        /// it every time and keep calling.
        /// </remarks>
        public const int FeatureNotEnabled = 1203;

        /// <summary>The tenant's plan has lapsed. Billing, not a bug; never retry.</summary>
        public const int PlanExpired = 1204;

        /// <summary>The tenant is at its concurrent-connection ceiling.</summary>
        public const int ConcurrencyLimitExceeded = 1205;

        /// <summary>No such user in this app.</summary>
        public const int UserNotFound = 1300;

        /// <summary>A user with this id already exists in this app.</summary>
        public const int UserAlreadyExists = 1301;

        /// <summary>The recipient is not a friend and the app requires friendship to message.</summary>
        public const int NotFriend = 1302;

        /// <summary>The recipient has blocked the sender.</summary>
        public const int BlockedByPeer = 1303;

        /// <summary>The sender has blocked the recipient.</summary>
        public const int BlockedPeer = 1304;

        /// <summary>No such friend request — it was already accepted, declined, or withdrawn.</summary>
        public const int FriendRequestNotFound = 1305;

        /// <summary>The account is at the tenant's friend-list ceiling.</summary>
        public const int FriendLimitExceeded = 1306;

        /// <summary>A user tried to add themselves as a friend.</summary>
        public const int CannotAddSelf = 1307;

        /// <summary>No such message, or it is not visible to this user.</summary>
        public const int MessageNotFound = 1400;

        /// <summary>The message body exceeded the tenant's length limit.</summary>
        public const int MessageTooLong = 1401;

        /// <summary>Moderation refused the content.</summary>
        public const int ModerationRejected = 1402;

        /// <summary>The recall window for this message has passed.</summary>
        public const int RecallWindowExpired = 1403;

        /// <summary>Recall is switched off for this app, or this caller lacks the authority for it.</summary>
        /// <remarks>
        /// Distinct from <see cref="RecallWindowExpired"/>: waiting does not help, and neither does
        /// retrying sooner next time — the operation itself is not available to this caller.
        /// </remarks>
        public const int RecallForbidden = 1404;

        /// <summary>Editing is switched off for this app, or the edit window has passed.</summary>
        public const int EditWindowExpired = 1405;

        /// <summary>
        /// This <c>clientMsgId</c> was already accepted, so the send was not performed twice.
        /// </summary>
        /// <remarks>
        /// The idempotency key doing its job, not a failure: the original message exists. A client
        /// that treats this as an error and retries with a fresh key is the thing that produces the
        /// duplicate the key was there to prevent.
        /// </remarks>
        public const int DuplicateClientMessageId = 1406;

        /// <summary>No such conversation, or it is not visible to this user.</summary>
        public const int ConversationNotFound = 1407;

        /// <summary>The sender is silenced, so the message was not accepted.</summary>
        public const int SenderMuted = 1408;

        /// <summary>This deployment does not accept that <see cref="ImMessageContentType"/>.</summary>
        public const int UnsupportedContentType = 1409;

        /// <summary>This message does not track read receipts, so there is nothing to report.</summary>
        public const int ReceiptDisabled = 1410;

        /// <summary>No such group, or it is not visible to this user.</summary>
        public const int GroupNotFound = 1500;

        /// <summary>The group has been dismissed.</summary>
        public const int GroupDismissed = 1501;

        /// <summary>The group is at its member ceiling.</summary>
        public const int GroupFull = 1502;

        /// <summary>The sender is not in the group.</summary>
        public const int NotGroupMember = 1503;

        /// <summary>Authenticated and a member, but not an admin or the owner.</summary>
        public const int NoGroupPermission = 1504;

        /// <summary>The whole group is muted.</summary>
        public const int GroupMuted = 1505;

        /// <summary>This member is muted in the group.</summary>
        public const int MemberMuted = 1506;

        /// <summary>The user is already in this group, so joining did nothing.</summary>
        public const int AlreadyGroupMember = 1507;

        /// <summary>Joining raised an application instead; wait for <c>evt.group</c>.</summary>
        public const int JoinNeedsApproval = 1508;

        /// <summary>This group does not accept new members at all.</summary>
        /// <remarks>
        /// Distinct from <see cref="JoinNeedsApproval"/>: nothing was raised and nothing is coming,
        /// so a client waiting for <c>evt.group</c> after this one waits forever.
        /// </remarks>
        public const int JoinForbidden = 1509;

        /// <summary>Invitations are disabled for this group, or restricted to administrators.</summary>
        public const int InviteForbidden = 1510;

        /// <summary>The group owner cannot be kicked, muted, demoted or otherwise operated on.</summary>
        public const int CannotOperateOwner = 1511;

        /// <summary>No such join application — it was already approved, rejected, or withdrawn.</summary>
        public const int ApplicationNotFound = 1512;

        /// <summary>No such chat room, or it is not visible to this user.</summary>
        public const int RoomNotFound = 1600;

        /// <summary>The chat room is at its occupant ceiling.</summary>
        public const int RoomFull = 1601;

        /// <summary>The caller has not joined this chat room.</summary>
        public const int NotInRoom = 1602;

        /// <summary>The whole chat room is muted.</summary>
        public const int RoomMuted = 1603;

        /// <summary>The upload did not complete; the object was not stored.</summary>
        public const int UploadFailed = 1700;

        /// <summary>The tenant's allow-list does not include this MIME type.</summary>
        public const int FileTypeNotAllowed = 1701;

        /// <summary>The file is over the tenant's per-object ceiling.</summary>
        public const int FileTooLarge = 1702;

        /// <summary>The tenant is out of object-storage quota.</summary>
        public const int StorageQuotaExceeded = 1703;

        /// <summary>
        /// No delivery row matches this device, so a reported tap could not be attributed.
        /// </summary>
        /// <remarks>
        /// The row aged out — seven days — or the notification did not come from this platform at
        /// all, which on a handset carrying two games is the ordinary case rather than the odd one.
        /// Neither is the caller's fault, which is why
        /// <see cref="ImPushApi.ClickedAsync(ImPushClickedRequest,System.Threading.CancellationToken)"/>
        /// logs it rather than raising it.
        /// </remarks>
        public const int PushDeliveryNotFound = 2401;

        /// <summary>
        /// True for the four codes where the same call, sent again later, can succeed.
        /// </summary>
        /// <remarks>
        /// <para>
        /// This list is closed and identical in all five SDKs. Everything not on it is terminal:
        /// retrying it produces the same answer, and a retry loop around it is a busy wait against
        /// a decision that has already been made.
        /// </para>
        /// <para>
        /// <b>The SDK never acts on this itself.</b> It retries the connection and its own
        /// <c>conn.sync</c> / <c>msg.sync</c> repair; every business call surfaces with this flag
        /// and the game decides. An SDK that silently re-sends on <see cref="RateLimited"/> hides
        /// rate limiting from the UI that has to explain it, and one that silently retries a send
        /// turns a visible failure into an invisible delay.
        /// </para>
        /// </remarks>
        public static bool IsRetryable(int code)
        {
            return code == InternalError || code == RateLimited || code == Timeout ||
                   code == ServiceUnavailable;
        }

        /// <summary>True for the three codes that mean "this token will not do".</summary>
        /// <remarks>
        /// <see cref="TokenExpired"/> is the recoverable one: the SDK renews in place with
        /// <c>conn.reauth</c> on the socket that is already open and retries the failed call once.
        /// The other two mean the credential is wrong rather than old, and the session ends.
        /// </remarks>
        public static bool RequiresReauth(int code)
        {
            return code == Unauthorized || code == TokenExpired || code == TokenInvalid;
        }
    }

    /// <summary>Server-initiated event names (SPEC-02 §2.7). Pass one to <see cref="ImClient.On"/>.</summary>
    public static class ImPushTarget
    {
        /// <summary>A new message. Handled internally by <see cref="ImClient"/>; subscribe to
        /// <see cref="ImClient.MessageReceived"/> instead so gap repair applies.</summary>
        public const string Message = "evt.message";

        /// <summary>A message was recalled, edited, or had a reaction changed.</summary>
        public const string MessageUpdate = "evt.messageUpdate";

        /// <summary>Conversation state changed — pin, mute, or a read cursor moved on another device.</summary>
        public const string ConversationUpdate = "evt.conversationUpdate";

        /// <summary>The peer read up to some seq.</summary>
        public const string Read = "evt.read";

        /// <summary>The peer is typing.</summary>
        public const string Typing = "evt.typing";

        /// <summary>A contact came online or went offline.</summary>
        public const string Presence = "evt.presence";

        /// <summary>Friend request, acceptance, or removal.</summary>
        public const string Friend = "evt.friend";

        /// <summary>Group membership or settings event.</summary>
        public const string Group = "evt.group";

        /// <summary>System notice, forced logout, quota warning.</summary>
        public const string System = "evt.system";

        /// <summary>AI streaming fragment.</summary>
        public const string Stream = "evt.stream";

        /// <summary>Support session lifecycle for the agent console: queued, assigned, transferred,
        /// closed, queue position.</summary>
        public const string Desk = "evt.desk";

        /// <summary>This connection was closed by the server. See <see cref="ImClient.Kicked"/>.</summary>
        public const string Kick = "conn.kick";
    }

    /// <summary>
    /// Why the server closed a connection, parsed from the WebSocket close reason
    /// <c>im-kick:{Reason}</c>.
    /// </summary>
    /// <remarks>
    /// This enum is the single most important distinction in the whole SDK. At the socket level a
    /// kick and a dead subway tunnel look identical — both are just a closed socket — and they need
    /// opposite responses. Reconnecting after a ban re-authenticates a banned user in a loop
    /// forever; not reconnecting after a tunnel leaves the player silently offline.
    /// </remarks>
    public enum ImKickReason
    {
        /// <summary>The socket closed without a kick reason: a network failure. Reconnect.</summary>
        None = 0,

        /// <summary>Another device took the session under the app multi-login policy. Terminal.</summary>
        MultiLoginPolicy = 1,

        /// <summary>The token expired. Not terminal — get a fresh token and reconnect.</summary>
        TokenExpired = 2,

        /// <summary>The token was revoked server-side. Terminal.</summary>
        TokenRevoked = 3,

        /// <summary>The account is banned. Terminal.</summary>
        UserBanned = 4,

        /// <summary>The tenant app was disabled. Terminal.</summary>
        AppDisabled = 5,

        /// <summary>The tenant is over quota. Not terminal: quota windows roll over.</summary>
        QuotaExceeded = 6,

        /// <summary>The gateway node is shutting down. Not terminal — this is the rolling-update
        /// case, and it is exactly when full-jitter backoff earns its keep.</summary>
        ServerShutdown = 7,

        /// <summary>An administrator disconnected this user. Terminal.</summary>
        AdminKick = 8,

        /// <summary>A reason this build does not know. Treated as non-terminal, so a newer server
        /// cannot strand an older client offline.</summary>
        Unknown = 1000,
    }

    /// <summary>Client platform reported at handshake time (SPEC-01).</summary>
    public enum ImPlatform
    {
        /// <summary>Unspecified.</summary>
        Unknown = 0,

        /// <summary>iOS or iPadOS.</summary>
        iOS = 1,

        /// <summary>Android.</summary>
        Android = 2,

        /// <summary>Windows desktop.</summary>
        Windows = 3,

        /// <summary>macOS desktop.</summary>
        macOS = 4,

        /// <summary>Browser, including Unity WebGL.</summary>
        Web = 5,

        /// <summary>Mini program host.</summary>
        MiniProgram = 6,

        /// <summary>Linux desktop or dedicated server.</summary>
        Linux = 7,
    }

    /// <summary>Conversation kind.</summary>
    public enum ImConversationType
    {
        /// <summary>One to one.</summary>
        Single = 1,

        /// <summary>Group with a membership roster.</summary>
        Group = 2,

        /// <summary>Chat room: high throughput, best-effort delivery, no roster.</summary>
        ChatRoom = 3,

        /// <summary>System channel.</summary>
        System = 4,

        /// <summary>AI assistant channel.</summary>
        Assistant = 5,
    }

    /// <summary>Message payload kind. The shape of <c>content</c> follows from this.</summary>
    public enum ImMessageContentType
    {
        /// <summary><c>{ "text": "..." }</c></summary>
        Text = 1,

        /// <summary><c>{ "url": objectKey, "width": w, "height": h, "size": bytes }</c></summary>
        Image = 2,

        /// <summary>Voice clip.</summary>
        Voice = 3,

        /// <summary>Video clip.</summary>
        Video = 4,

        /// <summary>Arbitrary file.</summary>
        File = 5,

        /// <summary>Map location.</summary>
        Location = 6,

        /// <summary>User or group card.</summary>
        Card = 7,

        /// <summary>Merged forward of several messages.</summary>
        Merged = 8,

        /// <summary>Structured system notification.</summary>
        Notification = 9,

        /// <summary>Inline grey tip.</summary>
        Tip = 10,

        /// <summary>Recall placeholder.</summary>
        Recall = 11,

        /// <summary>AI streaming message.</summary>
        Stream = 12,

        /// <summary>Anything the game defines itself.</summary>
        Custom = 100,
    }

    /// <summary>
    /// A frame from the server. Replies and server-initiated pushes are structurally identical,
    /// which is deliberate: one decoder handles both, and a push correlates exactly like a reply.
    /// </summary>
    public sealed class ImFrame
    {
        /// <summary>Correlation id. Echoes the request id for a reply; <c>srv-*</c> for a push.</summary>
        public string Id { get; private set; }

        /// <summary>Endpoint or event name.</summary>
        public string Target { get; private set; }

        /// <summary>Transport outcome: 0 routed, 1 the endpoint threw, 2 no such endpoint.</summary>
        public int Status { get; private set; }

        /// <summary>Transport-level error text, if any.</summary>
        public string Msg { get; private set; }

        /// <summary>The business envelope: <c>{ code, message, traceId, serverTime, data }</c>.</summary>
        public JsonValue Body { get; private set; }

        /// <summary>Business result code. See <see cref="ImErrorCode"/>.</summary>
        public int Code
        {
            get { return Body["code"].AsInt(); }
        }

        /// <summary>Business error message, if any.</summary>
        public string Message
        {
            get { return Body["message"].AsString(); }
        }

        /// <summary>End-to-end trace id. Worth logging: it is what a support ticket should quote.</summary>
        public string TraceId
        {
            get { return Body["traceId"].AsString(); }
        }

        /// <summary>Authoritative server clock in unix ms, usable to correct local drift.</summary>
        public long ServerTime
        {
            get { return Body["serverTime"].AsLong(); }
        }

        /// <summary>The payload. Never null — a missing member reads as <see cref="JsonValue.Null"/>.</summary>
        public JsonValue Data
        {
            get { return Body["data"]; }
        }

        /// <summary>Reads a frame out of a parsed document.</summary>
        public static ImFrame FromJson(JsonValue root)
        {
            if (root == null)
            {
                root = JsonValue.Null;
            }

            return new ImFrame
            {
                Id = root["id"].AsString(string.Empty),
                Target = root["target"].AsString(string.Empty),
                Status = root["status"].AsInt(),
                Msg = root["msg"].AsString(),
                Body = root["body"],
            };
        }

        /// <summary>Builds a frame locally, for events the SDK itself raises (a kick, for one).</summary>
        public static ImFrame Local(string target, JsonValue data)
        {
            var body = JsonValue.NewObject()
                .Set("code", 0L)
                .Set("serverTime", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
                .Set("data", data ?? JsonValue.Null);

            return new ImFrame
            {
                Id = string.Empty,
                Target = target,
                Status = 0,
                Body = body,
            };
        }
    }

    /// <summary>
    /// Raised for any non-zero business code, so a caller can <c>try</c>/<c>catch</c> once instead
    /// of checking a result code after every call.
    /// </summary>
    public sealed class ImException : Exception
    {
        /// <summary>The business code from <see cref="ImErrorCode"/>, or whatever the server sent.</summary>
        public int Code { get; private set; }

        /// <summary>
        /// End-to-end trace id for this request. Log it: it identifies the exact request across
        /// gateway, worker and store, and is the one thing a support ticket should carry.
        /// </summary>
        public string TraceId { get; private set; }

        /// <summary>The endpoint that failed, when the failure is attributable to one.</summary>
        public string Target { get; private set; }

        /// <summary>
        /// True when sending the same call again later could succeed. Computed from
        /// <see cref="Code"/> alone, and identical across all five client SDKs.
        /// </summary>
        /// <remarks>
        /// Branch on this, never on the message text: the text is human-facing, is localised
        /// server-side, and changes. There is no <c>retryAfter</c> on the WebSocket path — the REST
        /// layer sets a <c>Retry-After</c> header, the frame envelope has no equivalent — so apply
        /// your own full-jitter backoff, base 500 ms and cap 30 s, the same policy
        /// <see cref="FullJitterBackoff"/> uses for the connection.
        /// </remarks>
        public bool IsRetryable
        {
            get { return ImErrorCode.IsRetryable(Code); }
        }

        /// <summary>True when this failed because of the token rather than the request.</summary>
        public bool RequiresReauth
        {
            get { return ImErrorCode.RequiresReauth(Code); }
        }

        /// <inheritdoc cref="ImException"/>
        public ImException(int code, string message, string traceId = null, string target = null)
            : base(message)
        {
            Code = code;
            TraceId = traceId;
            Target = target;
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            return "ImException(" + Code + ") " + Message +
                   (Target != null ? " [target=" + Target + "]" : string.Empty) +
                   (TraceId != null ? " [traceId=" + TraceId + "]" : string.Empty);
        }
    }
}
