using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>moderation.*</c> — what a player can do about content they should not have seen.
    /// </summary>
    /// <remarks>
    /// The other half of what <see cref="ImFriendApi"/>'s blocklist is here for: app-store review
    /// treats a way to block an abusive user and a way to report objectionable content as two
    /// separate mandatory items for anything carrying user-generated content, and a game that ships
    /// one without the other fails the same submission twice.
    /// </remarks>
    public sealed class ImModerationApi : ImApiNamespace
    {
        internal ImModerationApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Reports a user, optionally naming one of their messages. Returns the receipt to show in
        /// the confirmation.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>The reporter is the socket, so there is no member for it.</b> If you find yourself
        /// looking for where to put the reporting player's id, there is nowhere: the server takes
        /// it from this connection, which is what makes a report unforgeable.
        /// </para>
        /// <para>
        /// Report the message even when it is no longer in the local store — recalled, deleted,
        /// scrolled past the retention window. The server does not check the message at all, on
        /// purpose: a report about a message that is already gone is the one a moderator most wants,
        /// and refusing it would turn the platform's own retention into a way to escape moderation.
        /// 消息已经不在本地也照报：服务端除了「不能举报自己」什么都不校验，
        /// 因为关于「已经没了的消息」的举报恰恰是审核员最想要的那条。
        /// </para>
        /// </remarks>
        public Task<ImReportReceipt> ReportAsync(
            ImSubmitReportRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.TargetUserId, "targetUserId");
            return RequestAsync<ImReportReceipt>("moderation.report", request, cancellationToken);
        }
    }
}
