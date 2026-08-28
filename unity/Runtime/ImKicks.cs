using System;

namespace Cyaim.Im
{
    /// <summary>
    /// Decodes the WebSocket close reason and answers the only question that matters when a socket
    /// dies: come back, or stay away?
    /// </summary>
    /// <remarks>
    /// <para>
    /// The server closes a kicked session with the reason <c>im-kick:{Reason}</c>. Nothing else in
    /// the protocol distinguishes "an administrator disconnected you" from "the player walked into
    /// a lift", because at the socket level there is nothing else to look at: both are a closed
    /// socket. Getting this wrong in either direction is a shipped bug — reconnect a banned account
    /// and the client re-authenticates in a loop until the battery is flat; refuse to reconnect a
    /// train tunnel and the player is silently offline until they restart the game.
    /// </para>
    /// <para>
    /// 服务端踢人时的关闭原因是 <c>im-kick:{Reason}</c>。终止性原因不能重连，否则就是拿一个必然
    /// 失败的 token 无限重试；网络断开必须重连。二者在 socket 层看起来完全一样，只有这个原因串能区分。
    /// </para>
    /// </remarks>
    public static class ImKicks
    {
        /// <summary>The close-reason prefix that marks a kick rather than a network failure.</summary>
        public const string ClosePrefix = "im-kick:";

        /// <summary>
        /// Reads a close reason. Returns false when the socket died for any reason other than a
        /// kick, which is the case that must reconnect.
        /// </summary>
        /// <param name="closeReason">Close reason as the server sent it. Null and empty are fine.</param>
        /// <param name="kick">The decoded kick, valid only when this method returns true.</param>
        public static bool TryParse(string closeReason, out ImKick kick)
        {
            if (string.IsNullOrEmpty(closeReason) ||
                !closeReason.StartsWith(ClosePrefix, StringComparison.OrdinalIgnoreCase))
            {
                kick = new ImKick(ImKickReason.None, string.Empty, false);
                return false;
            }

            var raw = closeReason.Substring(ClosePrefix.Length).Trim();
            var reason = ParseReason(raw);
            kick = new ImKick(reason, raw, IsTerminal(reason));
            return true;
        }

        /// <summary>
        /// Maps the text after <c>im-kick:</c> onto <see cref="ImKickReason"/>.
        /// </summary>
        /// <remarks>
        /// Written as an explicit switch rather than <c>Enum.TryParse</c> on purpose:
        /// <c>Enum.TryParse</c> also accepts the numeric form, so a server that one day closed with
        /// <c>im-kick:4</c> — or a truncated reason that happened to be digits — would silently
        /// decode as <see cref="ImKickReason.UserBanned"/> and strand a player who was never banned.
        /// </remarks>
        public static ImKickReason ParseReason(string rawReason)
        {
            if (string.IsNullOrEmpty(rawReason))
            {
                return ImKickReason.None;
            }

            if (Equals(rawReason, "MultiLoginPolicy"))
            {
                return ImKickReason.MultiLoginPolicy;
            }

            if (Equals(rawReason, "TokenExpired"))
            {
                return ImKickReason.TokenExpired;
            }

            if (Equals(rawReason, "TokenRevoked"))
            {
                return ImKickReason.TokenRevoked;
            }

            if (Equals(rawReason, "UserBanned"))
            {
                return ImKickReason.UserBanned;
            }

            if (Equals(rawReason, "AppDisabled"))
            {
                return ImKickReason.AppDisabled;
            }

            if (Equals(rawReason, "QuotaExceeded"))
            {
                return ImKickReason.QuotaExceeded;
            }

            if (Equals(rawReason, "ServerShutdown"))
            {
                return ImKickReason.ServerShutdown;
            }

            if (Equals(rawReason, "AdminKick"))
            {
                return ImKickReason.AdminKick;
            }

            // A reason a newer server knows and this build does not. Unknown is deliberately not
            // terminal: guessing "stay offline" would let one new server-side reason strand every
            // shipped client, and a client that comes back only to be kicked again learns the truth
            // one round trip later at negligible cost.
            return ImKickReason.Unknown;
        }

        /// <summary>
        /// True for the reasons where reconnecting would fail identically, forever.
        /// </summary>
        /// <remarks>
        /// Quota and shutdown are the two that look terminal and are not.
        /// <see cref="ImKickReason.QuotaExceeded"/> clears when the tenant's window rolls over, and
        /// <see cref="ImKickReason.ServerShutdown"/> is a gateway node being replaced — the rolling
        /// update case, which is precisely when full-jitter backoff has to work.
        /// </remarks>
        public static bool IsTerminal(ImKickReason reason)
        {
            switch (reason)
            {
                case ImKickReason.MultiLoginPolicy:
                case ImKickReason.TokenRevoked:
                case ImKickReason.UserBanned:
                case ImKickReason.AppDisabled:
                case ImKickReason.AdminKick:
                    return true;
                default:
                    return false;
            }
        }

        /// <summary>Reads a kick out of a <c>conn.kick</c> push payload.</summary>
        public static ImKick FromPayload(Json.JsonValue data)
        {
            var raw = data == null ? null : data["reason"].AsString(string.Empty);
            var reason = ParseReason(raw);
            return new ImKick(reason, raw == null ? string.Empty : raw, IsTerminal(reason));
        }

        private static bool Equals(string value, string literal)
        {
            return string.Equals(value, literal, StringComparison.OrdinalIgnoreCase);
        }
    }
}
