using System;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>push.*</c> — offline notification registration.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Why this exists as more than two wrappers.</b> A device token is not a setting you write
    /// once at install. The vendor may replace it while the process is frozen, and the server has no
    /// other way to learn that; so the token is registered on <i>every</i> connect, which costs no
    /// write when it has not changed because the server debounces it. Hand the SDK the token with
    /// <see cref="SetToken"/> and it handles the rest.
    /// </para>
    /// <para>
    /// <b>Unregister before you disconnect, never after.</b> Once the socket is closed there is no
    /// authenticated channel left and the token cannot be removed at all — only the tenant backend
    /// can, with <c>DELETE /v1/users/{userId}/push-tokens/{deviceId}</c>. Use
    /// <see cref="ImClient.LogoutAsync"/>, which does it in the right order. Disconnecting on its
    /// own deliberately does <i>not</i> unregister: a dead socket is precisely the state offline
    /// push exists to serve.
    /// </para>
    /// <para>
    /// <b>Where the token comes from on each platform.</b> Unity has no single answer, so the SDK
    /// takes none: on iOS <c>UnityEngine.iOS.NotificationServices.deviceToken</c> hex-encoded with
    /// <see cref="ImPushProvider.Apns"/>; on Android the Firebase Unity SDK's
    /// <c>FirebaseMessaging.TokenReceived</c> with <see cref="ImPushProvider.Fcm"/>, or the OEM
    /// plugin the game already ships for Huawei, Xiaomi, OPPO, vivo or Honor. Always name the
    /// provider on Android: an empty one falls back to the platform default, which is only reliable
    /// on iOS, and Android fragments across five OEM channels the server cannot guess between.
    /// </para>
    /// <code>
    /// // iOS, once the OS has answered the permission prompt
    /// im.Push.SetToken(ImPushProvider.Apns, HexOf(NotificationServices.deviceToken));
    ///
    /// // Android with the Firebase Unity SDK
    /// FirebaseMessaging.TokenReceived += (_, e) => im.Push.SetToken(ImPushProvider.Fcm, e.Token);
    /// </code>
    /// </remarks>
    public sealed class ImPushApi : ImApiNamespace
    {
        private string _provider;
        private string _token;
        private string _language;

        /// <summary>True once the current token has been accepted by the server at least once.</summary>
        private bool _registered;

        /// <summary>Guards the one warning §6.2 asks for, so it is not repeated per reconnect.</summary>
        private bool _warnedNeverRegistered;

        internal ImPushApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>True when the host app has handed the SDK a vendor token.</summary>
        public bool HasToken
        {
            get { return !string.IsNullOrEmpty(_token); }
        }

        /// <summary>
        /// True when the current token has been registered successfully at least once. False here
        /// while <see cref="HasToken"/> is true means notifications will not arrive, and is worth
        /// surfacing in a settings screen — it is otherwise indistinguishable from a broken push
        /// provider, and that misdiagnosis costs a support cycle every time.
        /// </summary>
        public bool IsRegistered
        {
            get { return _registered; }
        }

        /// <summary>
        /// Hands the SDK the vendor's device token. Registers it immediately if the socket is open,
        /// and otherwise on the next connect.
        /// </summary>
        /// <remarks>
        /// Call it from the vendor's token callback <i>and</i> once at startup with whatever token
        /// the vendor already has. Calling it with a token the SDK already holds is free and is not
        /// re-sent until the next connect.
        /// </remarks>
        /// <param name="provider">One of <see cref="ImPushProvider"/>. Required on Android.</param>
        /// <param name="token">The vendor's device token.</param>
        /// <param name="language">BCP-47 tag for notification text; null uses the socket's.</param>
        public void SetToken(string provider, string token, string language = null)
        {
            if (string.IsNullOrEmpty(token))
            {
                throw new ArgumentException("token is required; use ClearToken() to forget one", "token");
            }

            Client.Dispatcher.Post(delegate
            {
                var changed = !string.Equals(_token, token, StringComparison.Ordinal) ||
                              !string.Equals(_provider, provider, StringComparison.Ordinal);

                _provider = provider;
                _token = token;
                _language = language;

                if (changed)
                {
                    _registered = false;
                }

                if (!_registered && Client.State == ImConnectionState.Open)
                {
                    var ignored = RegisterCachedAsync();
                }
            });
        }

        /// <summary>
        /// Forgets the cached token without telling the server. For the case where the vendor
        /// reports the token dead; a logout wants
        /// <see cref="UnregisterAsync"/> — or better,
        /// <see cref="ImClient.LogoutAsync"/> — instead.
        /// </summary>
        public void ClearToken()
        {
            Client.Dispatcher.Post(delegate
            {
                _provider = null;
                _token = null;
                _language = null;
                _registered = false;
            });
        }

        /// <summary>Registers a token explicitly, bypassing the cache.</summary>
        /// <remarks>
        /// Prefer <see cref="SetToken"/>, which also covers reconnects. This overload exists for a
        /// host app that owns the whole lifecycle itself.
        /// </remarks>
        public Task RegisterAsync(
            ImRegisterPushTokenRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.Token, "token");
            return ExecuteAsync("push.register", request, cancellationToken);
        }

        /// <summary>
        /// Removes this device's registration. Other devices of the same user are untouched.
        /// </summary>
        /// <remarks>
        /// This must reach the server <i>before</i> the socket closes. After that there is no
        /// authenticated channel and the token stays registered, so the signed-out handset keeps
        /// receiving the next user's notifications until the tenant backend cleans it up.
        /// </remarks>
        public async Task UnregisterAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            await ExecuteAsync("push.unregister", null, cancellationToken).ConfigureAwait(false);
            _registered = false;
        }

        /// <summary>
        /// Applies §6.2 rule 1: on every authenticated connect, re-register whatever token we hold.
        /// </summary>
        /// <remarks>
        /// Fire and forget by design. Push registration is not on the critical path of a chat
        /// session, and blocking the connect callback on a round trip would stall the frame it runs
        /// on. A failure here is logged, not thrown at a caller who did not ask for it.
        /// </remarks>
        internal void RegisterOnConnect()
        {
            if (!HasToken)
            {
                return;
            }

            var ignored = RegisterCachedAsync();
        }

        /// <summary>Unregisters if there is anything to unregister, swallowing a failed attempt.</summary>
        /// <remarks>
        /// Used by <see cref="ImClient.LogoutAsync"/>, where the disconnect must happen whether or
        /// not the unregister succeeded — a logout that a network error can refuse is worse than a
        /// stale token.
        /// </remarks>
        internal async Task UnregisterQuietlyAsync(CancellationToken cancellationToken)
        {
            if (!HasToken || Client.State != ImConnectionState.Open)
            {
                return;
            }

            try
            {
                await UnregisterAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                ImLog.Warn(
                    "push.unregister failed, so this device stays registered for offline push. " +
                    "The tenant backend can remove it with " +
                    "DELETE /v1/users/{userId}/push-tokens/{deviceId} (sdk/CONTRACT.md §6.4).",
                    error);
            }
        }

        private async Task RegisterCachedAsync()
        {
            var request = new ImRegisterPushTokenRequest(_provider, _token, _language);

            try
            {
                await RegisterAsync(request).ConfigureAwait(false);
                _registered = true;
            }
            catch (Exception error)
            {
                if (!_warnedNeverRegistered && !_registered)
                {
                    _warnedNeverRegistered = true;
                    ImLog.Warn(
                        "this device holds a push token that has never been registered, so offline " +
                        "notifications will not arrive. A silently unregistered device looks exactly " +
                        "like a broken push provider. See sdk/CONTRACT.md §6.",
                        error);
                }
                else
                {
                    ImLog.Info("push.register failed: " + error.Message);
                }
            }
        }
    }
}
