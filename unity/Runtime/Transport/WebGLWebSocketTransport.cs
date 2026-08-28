#if UNITY_WEBGL && !UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using AOT;

namespace Cyaim.Im.Transport
{
    /// <summary>
    /// The WebGL transport: the browser WebSocket, reached through the JS shim in
    /// <c>Runtime/Plugins/WebGL/ImWebSocket.jslib</c>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A browser tab has no TCP stack, so <c>System.Net.WebSockets.ClientWebSocket</c> cannot work
    /// in a WebGL build. It does not fail loudly either — which is the dangerous part, and the
    /// reason this file exists rather than a line in the release notes saying WebGL is unsupported.
    /// </para>
    /// <para>
    /// Everything JS hands back arrives on the browser main thread, which in a WebGL build is the
    /// Unity main thread. The callbacks are still routed through the dispatcher upstream, so the
    /// threading contract is identical on every platform and there is one code path to reason about.
    /// </para>
    /// <para>
    /// Two browser constraints leak through and cannot be hidden: the handshake carries no custom
    /// headers (which is why this protocol authenticates with query parameters), and a page served
    /// over HTTPS may only open <c>wss://</c>. A <c>ws://</c> endpoint in a hosted WebGL build is
    /// blocked by the browser before any of this code runs.
    /// </para>
    /// </remarks>
    public sealed class WebGLWebSocketTransport : IImTransport
    {
        private delegate void OpenCallback(int handle);

        private delegate void TextCallback(int handle, IntPtr payload);

        private delegate void CloseCallback(int handle, int code, IntPtr reason);

        [DllImport("__Internal")]
        private static extern int ImWsCreate(string url, OpenCallback onOpen, TextCallback onText, CloseCallback onClose);

        [DllImport("__Internal")]
        private static extern int ImWsSend(int handle, string payload);

        [DllImport("__Internal")]
        private static extern void ImWsClose(int handle, int code, string reason);

        [DllImport("__Internal")]
        private static extern void ImWsAbort(int handle);

        [DllImport("__Internal")]
        private static extern int ImWsReadyState(int handle);

        // Held in static fields for the lifetime of the domain. A delegate passed to native code and
        // then collected leaves the browser calling into freed memory the next time a frame arrives.
        private static readonly OpenCallback OpenThunk = OnOpenStatic;
        private static readonly TextCallback TextThunk = OnTextStatic;
        private static readonly CloseCallback CloseThunk = OnCloseStatic;

        private static readonly Dictionary<int, WebGLWebSocketTransport> Instances =
            new Dictionary<int, WebGLWebSocketTransport>();

        private TaskCompletionSource<bool> _handshake;
        private int _handle;
        private ImTransportState _state;
        private bool _closeRaised;
        private bool _disposed;

        /// <inheritdoc/>
        public ImTransportState State
        {
            get { return _state; }
        }

        /// <inheritdoc/>
        public Action<string> TextReceived { get; set; }

        /// <inheritdoc/>
        public Action<ImTransportClose> Closed { get; set; }

        /// <inheritdoc/>
        public Task ConnectAsync(Uri url, CancellationToken cancellationToken)
        {
            if (url == null)
            {
                throw new ArgumentNullException("url");
            }

            if (_state != ImTransportState.Idle)
            {
                throw new InvalidOperationException("This transport has already been used. Create a new one.");
            }

            _state = ImTransportState.Connecting;
            _handshake = new TaskCompletionSource<bool>();

            var handle = ImWsCreate(url.AbsoluteUri, OpenThunk, TextThunk, CloseThunk);
            if (handle == 0)
            {
                _state = ImTransportState.Closed;
                var failure = new ImTransportClose(1006, string.Empty);
                RaiseClosed(failure);
                _handshake.TrySetException(new ImException(
                    ImErrorCode.ServiceUnavailable,
                    "the browser refused to create a WebSocket for " + url.AbsoluteUri));
                return _handshake.Task;
            }

            _handle = handle;
            Instances[handle] = this;

            if (cancellationToken.CanBeCanceled)
            {
                cancellationToken.Register(Abort);
            }

            return _handshake.Task;
        }

        /// <inheritdoc/>
        public void Send(string payload)
        {
            if (payload == null || _state != ImTransportState.Open)
            {
                return;
            }

            if (ImWsSend(_handle, payload) == 0)
            {
                // The browser refused the write, which means this socket is finished even if the
                // close event has not arrived yet. Ending it now starts the reconnect a frame early
                // instead of leaving requests to time out one by one.
                Abort();
            }
        }

        /// <inheritdoc/>
        public void Close(int code, string reason)
        {
            if (_handle != 0)
            {
                ImWsClose(_handle, code, reason ?? string.Empty);
            }
            else
            {
                RaiseClosed(new ImTransportClose(code, reason));
            }
        }

        /// <inheritdoc/>
        public void Abort()
        {
            if (_handle != 0)
            {
                ImWsAbort(_handle);
            }

            _state = ImTransportState.Closed;
            RaiseClosed(new ImTransportClose(1006, string.Empty));
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            Abort();

            if (_handle != 0)
            {
                Instances.Remove(_handle);
                _handle = 0;
            }
        }

        /// <summary>True when the browser still reports this socket as open.</summary>
        public bool IsBrowserSocketOpen
        {
            get { return _handle != 0 && ImWsReadyState(_handle) == 1; }
        }

        private void RaiseClosed(ImTransportClose close)
        {
            if (_closeRaised)
            {
                return;
            }

            _closeRaised = true;
            _state = ImTransportState.Closed;

            var handshake = _handshake;
            if (handshake != null)
            {
                handshake.TrySetException(new ImException(
                    ImErrorCode.ServiceUnavailable,
                    "socket closed during handshake: " + close));
            }

            var handler = Closed;
            if (handler != null)
            {
                handler(close);
            }
        }

        [MonoPInvokeCallback(typeof(OpenCallback))]
        private static void OnOpenStatic(int handle)
        {
            var transport = Find(handle);
            if (transport == null)
            {
                return;
            }

            transport._state = ImTransportState.Open;
            transport._handshake.TrySetResult(true);
        }

        [MonoPInvokeCallback(typeof(TextCallback))]
        private static void OnTextStatic(int handle, IntPtr payload)
        {
            var transport = Find(handle);
            if (transport == null)
            {
                return;
            }

            var handler = transport.TextReceived;
            if (handler != null)
            {
                handler(ReadUtf8(payload));
            }
        }

        [MonoPInvokeCallback(typeof(CloseCallback))]
        private static void OnCloseStatic(int handle, int code, IntPtr reason)
        {
            var transport = Find(handle);
            if (transport == null)
            {
                return;
            }

            Instances.Remove(handle);
            transport.RaiseClosed(new ImTransportClose(code, ReadUtf8(reason)));
        }

        private static WebGLWebSocketTransport Find(int handle)
        {
            WebGLWebSocketTransport transport;
            return Instances.TryGetValue(handle, out transport) ? transport : null;
        }

        /// <summary>
        /// Reads a NUL-terminated UTF-8 string out of the emscripten heap.
        /// </summary>
        /// <remarks>
        /// Written by hand rather than with <c>Marshal.PtrToStringUTF8</c>, which is missing from
        /// some of the API compatibility profiles a Unity project can be configured with. A helper
        /// that fails to compile under a project setting the SDK does not control is a helper that
        /// does not work.
        /// </remarks>
        private static string ReadUtf8(IntPtr pointer)
        {
            if (pointer == IntPtr.Zero)
            {
                return string.Empty;
            }

            int length = 0;
            while (Marshal.ReadByte(pointer, length) != 0)
            {
                length++;
            }

            if (length == 0)
            {
                return string.Empty;
            }

            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }
    }
}
#endif
