using System;

namespace Cyaim.Im
{
    /// <summary>
    /// The one rule for turning two user ids into the id the server gives their single chat.
    /// 由两个 user id 得出服务端给他们单聊的那个 id 的唯一规则。
    /// </summary>
    public static class ImConversationIds
    {
        /// <summary>
        /// The id of the single chat between two users, the same one the server gives it — so a
        /// conversation can be addressed (<c>msg.history</c>, <c>conv.get</c>, <c>Commit</c>, a cursor)
        /// before either side has sent anything, or from nothing but the two user ids.
        /// 两个用户之间单聊的 id，与服务端给的同一个。
        /// </summary>
        /// <remarks>
        /// <para>
        /// <c>"s_" + enc(A) + "_" + enc(B)</c>, where A and B are the two <b>raw</b> user ids in UTF-16
        /// ordinal order (<see cref="string.CompareOrdinal(string, string)"/>, A first when they are
        /// equal) and <c>enc</c> writes every '~' as <c>~0</c> and every '_' as <c>~1</c>. After escaping
        /// neither half contains '_', so the one '_' after the prefix is the separator and every id names
        /// exactly one pair: <c>u_alice</c> with <c>u_bob</c> is <c>s_u~1alice_u~1bob</c>, while ids with
        /// neither '_' nor '~' come out as they always did (<c>s_alice_bob</c>).
        /// </para>
        /// <para>
        /// Which end comes first does not matter. The order is decided on the raw ids, not on the
        /// escaped halves — escaping does not keep order ('_' sorts before the letters, its escape
        /// <c>~1</c> after them) — and it is ordinal: <see cref="string.Compare(string, string)"/> is
        /// culture-sensitive and gives a different order. Do not join the ids yourself: a bare '_'
        /// between them is right only while neither contains '_' or '~'.
        /// </para>
        /// <para>
        /// An empty end is not a user: the id it produces does not parse, and the server answers 1001
        /// for it. The rule is a contract shared with the server and the other SDKs;
        /// <c>single-chat-id-vectors.json</c> at the root of the SDK repository is its executable form,
        /// and <c>SingleChatIdTests</c> holds this method to every vector in it.
        /// </para>
        /// <para>
        /// 两个原始 user id 按 UTF-16 码元序数排序，'~' 写成 ~0、'_' 写成 ~1，前缀后唯一的 '_' 是分隔符，
        /// 每个 id 恰好对应一对人。谁先传都一样；顺序按原始 id 比，不按转义后的两半。
        /// 不要自己拼：直接用 '_' 连接只在两个 id 都不含 '_' 与 '~' 时才对。
        /// </para>
        /// </remarks>
        /// <param name="a">One user id, as your backend gave it.</param>
        /// <param name="b">The other user id.</param>
        public static string SingleConversationId(string a, string b)
        {
            if (a == null)
            {
                throw new ArgumentNullException(nameof(a));
            }

            if (b == null)
            {
                throw new ArgumentNullException(nameof(b));
            }

            return string.CompareOrdinal(a, b) <= 0
                ? "s_" + EscapeEnd(a) + "_" + EscapeEnd(b)
                : "s_" + EscapeEnd(b) + "_" + EscapeEnd(a);
        }

        // '~' first, then '_': the other way round would escape the '~' of every "~1" just written.
        private static string EscapeEnd(string userId)
        {
            return userId.Replace("~", "~0").Replace("_", "~1");
        }
    }
}
