#if !UNITY_WEBGL || UNITY_EDITOR
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im.Transport
{
    /// <summary>
    /// The transport used everywhere a real socket exists: standalone players, mobile, consoles,
    /// and the editor. Built on <see cref="ClientWebSocket"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This type is compiled out of WebGL builds on purpose. <see cref="ClientWebSocket"/> needs
    /// TCP, and a browser tab has none; leaving it referenced would produce a build that compiles,
    /// ships, and then fails to connect with no useful error. See
    /// <c>WebGLWebSocketTransport</c> for what runs there instead.
    /// </para>
    /// <para>
    /// Two implementation details matter for correctness. Fragmented frames are accumulated as
    /// bytes and decoded once at the end, because a multi-byte UTF-8 character can straddle a
    /// fragment boundary and decoding per fragment corrupts exactly the non-Latin text that most of
    /// this product ships to. And writes go through a single-consumer queue rather than a
    /// semaphore, because <see cref="ClientWebSocket"/> permits only one send at a time and message
    /// order on a chat socket is not negotiable.
    /// </para>
    /// </remarks>
    public sealed class ClientWebSocketTransport : IImTransport
    {
        private const int ReceiveBufferSize = 8 * 1024;

        private readonly ConcurrentQueue<string> _outbox = new ConcurrentQueue<string>();
        private readonly SemaphoreSlim _outboxSignal = new SemaphoreSlim(0);
        private readonly CancellationTokenSource _lifetime = new CancellationTokenSource();

        private ClientWebSocket _socket;
        private int _state;
        private int _closeRaised;
        private int _disposed;

        /// <inheritdoc/>
        public ImTransportState State
        {
            get { return (ImTransportState)Volatile.Read(ref _state); }
        }

        /// <inheritdoc/>
        public Action<string> TextReceived { get; set; }

        /// <inheritdoc/>
        public Action<ImTransportClose> Closed { get; set; }

        /// <inheritdoc/>
        public async Task ConnectAsync(Uri url, CancellationToken cancellationToken)
        {
            if (url == null)
            {
                throw new ArgumentNullException("url");
            }

            if (Interlocked.CompareExchange(ref _state, (int)ImTransportState.Connecting, (int)ImTransportState.Idle)
                != (int)ImTransportState.Idle)
            {
                throw new InvalidOperationException("This transport has already been used. Create a new one.");
            }

            var socket = new ClientWebSocket();

            // The SDK runs its own heartbeat on conn.heartbeat, which does more than a protocol
            // ping: it also re-registers a session whose cluster routing entry was evicted. Two
            // liveness mechanisms would just double the traffic.
            socket.Options.KeepAliveInterval = TimeSpan.Zero;
            _socket = socket;

            using (var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token))
            {
                try
                {
                    await socket.ConnectAsync(url, linked.Token).ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    Volatile.Write(ref _state, (int)ImTransportState.Closed);

                    // A refused handshake carries no close reason, which is precisely how the layer
                    // above tells it apart from a kick: no reason means the network, not the server.
                    RaiseClosed(new ImTransportClose(1006, string.Empty, error));
                    throw;
                }
            }

            Volatile.Write(ref _state, (int)ImTransportState.Open);

            // Detached on purpose: these two loops own the socket until it dies, and awaiting them
            // here would mean never returning from Connect.
            _ = Task.Run(ReceiveLoopAsync);
            _ = Task.Run(SendLoopAsync);
        }

        /// <inheritdoc/>
        public void Send(string payload)
        {
            if (payload == null || State != ImTransportState.Open)
            {
                return;
            }

            _outbox.Enqueue(payload);
            try
            {
                _outboxSignal.Release();
            }
            catch (ObjectDisposedException)
            {
                // Raced with Dispose; the socket is going away and the frame is moot.
            }
        }

        /// <inheritdoc/>
        public void Close(int code, string reason)
        {
            var socket = _socket;
            if (socket == null)
            {
                RaiseClosed(new ImTransportClose(code, reason));
                return;
            }

            // CloseOutputAsync, not CloseAsync: the latter waits for the peer to close back, and a
            // client that is shutting down must not depend on a server that may already be gone.
            var status = (WebSocketCloseStatus)code;
            var text = reason ?? string.Empty;

            _ = Task.Run(async () =>
            {
                try
                {
                    if (socket.State == WebSocketState.Open)
                    {
                        using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2)))
                        {
                            await socket.CloseOutputAsync(status, text, timeout.Token).ConfigureAwait(false);
                        }
                    }
                }
                catch (Exception error)
                {
                    ImLog.Verbose("close handshake failed, aborting instead: " + error.Message);
                }
                finally
                {
                    Abort();
                }
            });
        }

        /// <inheritdoc/>
        public void Abort()
        {
            var socket = _socket;
            if (socket != null)
            {
                try
                {
                    socket.Abort();
                }
                catch (Exception error)
                {
                    ImLog.Verbose("socket abort threw: " + error.Message);
                }
            }

            try
            {
                _lifetime.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }

            Volatile.Write(ref _state, (int)ImTransportState.Closed);
            RaiseClosed(new ImTransportClose(1006, string.Empty));
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            Abort();

            try
            {
                _lifetime.Dispose();
            }
            catch (Exception)
            {
                // Cancellation sources can be disposed concurrently with a cancel in flight.
            }

            _outboxSignal.Dispose();

            var socket = _socket;
            _socket = null;
            if (socket != null)
            {
                socket.Dispose();
            }
        }

        private async Task ReceiveLoopAsync()
        {
            var socket = _socket;
            var buffer = new ArraySegment<byte>(new byte[ReceiveBufferSize]);
            var assembled = new MemoryStream(ReceiveBufferSize);

            try
            {
                while (!_lifetime.IsCancellationRequested && socket.State == WebSocketState.Open)
                {
                    WebSocketReceiveResult result;
                    try
                    {
                        result = await socket.ReceiveAsync(buffer, _lifetime.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }

                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        var code = socket.CloseStatus.HasValue ? (int)socket.CloseStatus.Value : 1005;
                        RaiseClosed(new ImTransportClose(code, socket.CloseStatusDescription));
                        return;
                    }

                    if (result.MessageType == WebSocketMessageType.Binary)
                    {
                        // The gateway speaks JSON text frames unless proto=msgpack was requested,
                        // and this SDK never requests it. Anything binary is not ours to interpret.
                        continue;
                    }

                    assembled.Write(buffer.Array, buffer.Offset, result.Count);

                    if (!result.EndOfMessage)
                    {
                        continue;
                    }

                    string text;
                    try
                    {
                        text = Encoding.UTF8.GetString(assembled.GetBuffer(), 0, (int)assembled.Length);
                    }
                    finally
                    {
                        assembled.SetLength(0);
                    }

                    var handler = TextReceived;
                    if (handler != null)
                    {
                        handler(text);
                    }
                }
            }
            catch (Exception error)
            {
                ImLog.Verbose("receive loop ended: " + error.Message);
                RaiseClosed(new ImTransportClose(1006, string.Empty, error));
                return;
            }
            finally
            {
                assembled.Dispose();
                Volatile.Write(ref _state, (int)ImTransportState.Closed);
            }

            RaiseClosed(new ImTransportClose(1006, string.Empty));
        }

        private async Task SendLoopAsync()
        {
            var socket = _socket;

            try
            {
                while (!_lifetime.IsCancellationRequested)
                {
                    await _outboxSignal.WaitAsync(_lifetime.Token).ConfigureAwait(false);

                    string payload;
                    if (!_outbox.TryDequeue(out payload))
                    {
                        continue;
                    }

                    var bytes = Encoding.UTF8.GetBytes(payload);
                    await socket.SendAsync(
                            new ArraySegment<byte>(bytes),
                            WebSocketMessageType.Text,
                            true,
                            _lifetime.Token)
                        .ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
                // Normal shutdown.
            }
            catch (Exception error)
            {
                // A failed write means the socket is gone even if nothing has told us yet. Ending
                // it here turns a silent write failure into the reconnect path.
                ImLog.Verbose("send loop ended: " + error.Message);
                Abort();
            }
        }

        private void RaiseClosed(ImTransportClose close)
        {
            if (Interlocked.Exchange(ref _closeRaised, 1) != 0)
            {
                return;
            }

            Volatile.Write(ref _state, (int)ImTransportState.Closed);

            var handler = Closed;
            if (handler != null)
            {
                handler(close);
            }
        }
    }
}
#endif
