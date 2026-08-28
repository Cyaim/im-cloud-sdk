using System;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im.Transport
{
    /// <summary>Lifecycle of a single socket. A transport never reopens; the connection makes a new one.</summary>
    public enum ImTransportState
    {
        /// <summary>Created, not yet connected.</summary>
        Idle = 0,

        /// <summary>Handshake in flight.</summary>
        Connecting = 1,

        /// <summary>Open and usable.</summary>
        Open = 2,

        /// <summary>Closed, for any reason. Terminal.</summary>
        Closed = 3,
    }

    /// <summary>Why a socket closed.</summary>
    public readonly struct ImTransportClose
    {
        /// <summary>WebSocket close code. 1006 means the socket died without a close frame.</summary>
        public int Code { get; }

        /// <summary>
        /// Close reason as sent by the server. This is the field that carries
        /// <c>im-kick:{Reason}</c>, and therefore the field that decides whether reconnecting is
        /// the right thing to do.
        /// </summary>
        public string Reason { get; }

        /// <summary>The local exception that ended the socket, when one did. Diagnostics only.</summary>
        public Exception Error { get; }

        /// <inheritdoc cref="ImTransportClose"/>
        public ImTransportClose(int code, string reason, Exception error = null)
        {
            Code = code;
            Reason = reason ?? string.Empty;
            Error = error;
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            return "close " + Code + (string.IsNullOrEmpty(Reason) ? string.Empty : " \"" + Reason + "\"");
        }
    }

    /// <summary>
    /// One WebSocket, abstracted so the same connection logic runs on a desktop socket and on a
    /// browser one.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This interface exists because of WebGL. <c>System.Net.WebSockets.ClientWebSocket</c> is a
    /// real socket implementation and there are no sockets in a browser sandbox; in a WebGL build it
    /// throws or, worse, appears to construct and then never connects. Hiding both behind one
    /// interface — a .NET socket everywhere else, the browser WebSocket through a JS shim on
    /// WebGL — means <see cref="ImConnection"/> has no platform branches in it at all.
    /// </para>
    /// <para>
    /// <see cref="TextReceived"/> and <see cref="Closed"/> are raised on whatever thread the
    /// transport happens to be on. Nothing above this interface assumes otherwise: the connection
    /// posts everything to its dispatcher before touching any state.
    /// </para>
    /// </remarks>
    public interface IImTransport : IDisposable
    {
        /// <summary>Current lifecycle state.</summary>
        ImTransportState State { get; }

        /// <summary>
        /// Raised for each complete text frame. May fire on a worker thread — do not touch Unity
        /// objects from here.
        /// </summary>
        Action<string> TextReceived { get; set; }

        /// <summary>
        /// Raised exactly once, when the socket ends for any reason: server close, kick, network
        /// failure, or a local abort. May fire on a worker thread.
        /// </summary>
        Action<ImTransportClose> Closed { get; set; }

        /// <summary>Opens the socket. Completes when the handshake succeeds, throws when it does not.</summary>
        Task ConnectAsync(Uri url, CancellationToken cancellationToken);

        /// <summary>
        /// Queues a text frame. Fire and forget by design: the caller is a state machine on the main
        /// thread that must not block on network I/O, and a write that fails ends the socket, which
        /// the caller already handles as <see cref="Closed"/>. Frames are written in call order.
        /// </summary>
        void Send(string payload);

        /// <summary>Closes politely, with a code and reason, and waits for nothing.</summary>
        void Close(int code, string reason);

        /// <summary>
        /// Kills the socket without a close handshake. This is the right move for a half-open
        /// socket — one the OS still believes is fine but that carries no traffic — because a
        /// polite close on a socket like that waits for a reply that is never coming.
        /// </summary>
        void Abort();
    }
}
