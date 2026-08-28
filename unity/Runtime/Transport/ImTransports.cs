namespace Cyaim.Im.Transport
{
    /// <summary>Chooses the socket implementation that actually works on the current build target.</summary>
    /// <remarks>
    /// The decision is made at compile time, not at run time, because the WebGL branch cannot even
    /// reference <c>ClientWebSocket</c> and the desktop branch cannot reference a <c>__Internal</c>
    /// import that will not link. A game never has to know which one it got.
    /// </remarks>
    public static class ImTransports
    {
        /// <summary>Creates the right transport for this platform.</summary>
        public static IImTransport CreateDefault()
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            return new WebGLWebSocketTransport();
#else
            return new ClientWebSocketTransport();
#endif
        }

        /// <summary>
        /// True in a WebGL player, where the browser owns the socket. Worth branching on in a game:
        /// there is no background execution in a tab, so a WebGL client goes away the moment the
        /// page is hidden and comes back through the normal reconnect path.
        /// </summary>
        public static bool IsBrowserTransport
        {
            get
            {
#if UNITY_WEBGL && !UNITY_EDITOR
                return true;
#else
                return false;
#endif
            }
        }
    }
}
