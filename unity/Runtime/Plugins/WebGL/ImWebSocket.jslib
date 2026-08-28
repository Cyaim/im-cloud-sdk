// Browser WebSocket bridge for the Cyaim IM Unity SDK.
//
// A WebGL build has no TCP stack, so System.Net.WebSockets.ClientWebSocket cannot work there. The
// browser has its own WebSocket, and this file is the whole of the glue: create, send, close, and
// three callbacks back into managed code. Everything else — framing, reconnect, gap repair — is the
// same C# that runs on every other platform.
//
// Frames arrive here on the browser main thread, which is also the Unity main thread in a WebGL
// build, so these callbacks are already where the SDK wants them. They are still posted through the
// dispatcher on the C# side, so that one code path serves every platform.

var ImWebSocketLibrary = {

    $ImWs: {
        sockets: {},
        nextHandle: 1,

        // Copies a JS string into the heap for the duration of one call. The C# side reads it and
        // the caller frees it immediately after; nothing outlives the callback.
        allocString: function (text) {
            var size = lengthBytesUTF8(text) + 1;
            var ptr = _malloc(size);
            stringToUTF8(text, ptr, size);
            return ptr;
        }
    },

    ImWsCreate__deps: ['$ImWs', 'malloc', 'free'],
    ImWsCreate: function (urlPtr, onOpen, onText, onClose) {
        var url = UTF8ToString(urlPtr);
        var handle = ImWs.nextHandle++;
        var socket;

        try {
            socket = new WebSocket(url);
        } catch (error) {
            // A malformed URL or a mixed-content block throws synchronously — before the C# side
            // has a handle to map a callback onto. Returning 0 lets the caller fail the connect
            // attempt directly instead of racing a callback against its own registration.
            return 0;
        }

        ImWs.sockets[handle] = socket;

        socket.onopen = function () {
            {{{ makeDynCall('vi', 'onOpen') }}}(handle);
        };

        socket.onmessage = function (event) {
            // The gateway sends JSON text frames. Binary would mean proto=msgpack, which this SDK
            // never asks for, so ignoring it is correct rather than lossy.
            if (typeof event.data !== 'string') {
                return;
            }

            var ptr = ImWs.allocString(event.data);
            try {
                {{{ makeDynCall('vii', 'onText') }}}(handle, ptr);
            } finally {
                _free(ptr);
            }
        };

        socket.onerror = function () {
            // onclose always follows onerror in every browser, and the close carries the code and
            // reason. Handling both would double-report the same failure.
        };

        socket.onclose = function (event) {
            delete ImWs.sockets[handle];
            var ptr = ImWs.allocString(event.reason || '');
            try {
                {{{ makeDynCall('viii', 'onClose') }}}(handle, event.code, ptr);
            } finally {
                _free(ptr);
            }
        };

        return handle;
    },

    ImWsSend__deps: ['$ImWs'],
    ImWsSend: function (handle, payloadPtr) {
        var socket = ImWs.sockets[handle];
        if (!socket || socket.readyState !== 1) {
            return 0;
        }

        try {
            socket.send(UTF8ToString(payloadPtr));
            return 1;
        } catch (error) {
            return 0;
        }
    },

    ImWsClose__deps: ['$ImWs'],
    ImWsClose: function (handle, code, reasonPtr) {
        var socket = ImWs.sockets[handle];
        if (!socket) {
            return;
        }

        try {
            // Browsers reject any code outside 1000 and 3000-4999 with an exception, so anything
            // else becomes a plain normal closure rather than an uncaught error in the console.
            var safeCode = (code === 1000 || (code >= 3000 && code <= 4999)) ? code : 1000;
            socket.close(safeCode, UTF8ToString(reasonPtr));
        } catch (error) {
            // Already closing or already closed.
        }
    },

    ImWsAbort__deps: ['$ImWs'],
    ImWsAbort: function (handle) {
        var socket = ImWs.sockets[handle];
        if (!socket) {
            return;
        }

        // Drop the handlers first: an abort is the SDK deciding this socket is dead, and a late
        // onclose from it would be attributed to the connection that replaced it.
        socket.onopen = null;
        socket.onmessage = null;
        socket.onerror = null;
        socket.onclose = null;
        delete ImWs.sockets[handle];

        try {
            socket.close(1000, 'client-abort');
        } catch (error) {
            // Nothing left to do; the handlers are gone either way.
        }
    },

    ImWsReadyState__deps: ['$ImWs'],
    ImWsReadyState: function (handle) {
        var socket = ImWs.sockets[handle];
        return socket ? socket.readyState : 3;
    }
};

autoAddDeps(ImWebSocketLibrary, '$ImWs');
mergeInto(LibraryManager.library, ImWebSocketLibrary);
