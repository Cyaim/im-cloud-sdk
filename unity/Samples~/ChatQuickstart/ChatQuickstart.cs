using System;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im;
using Cyaim.Im.Json;
using UnityEngine;
using UnityEngine.Networking;

namespace Cyaim.Im.Samples
{
    /// <summary>
    /// A complete integration in one behaviour: fetch a token from your backend, connect, persist
    /// where each conversation stands, register for offline push, render what arrives, send.
    /// </summary>
    /// <remarks>
    /// Drop this on a GameObject, fill in the endpoint and the URL of your own token endpoint, and
    /// press play. Everything here runs on the main thread, so the message handler can touch scene
    /// objects directly — that is the SDK's contract, not an accident of this sample.
    /// </remarks>
    public sealed class ChatQuickstart : MonoBehaviour
    {
        [Header("Gateway")]
        [Tooltip("Base URL of the IM gateway, without a path. wss:// in anything you ship.")]
        [SerializeField] private string endpoint = "wss://im.example.com";

        [Tooltip("Your application id from the console. Safe to ship in a client build.")]
        [SerializeField] private string appId = "your-app-id";

        [Tooltip("The user your backend is minting a token for. The SDK keys its cursor store on " +
                 "this, so two accounts on one handset cannot read each other's positions.")]
        [SerializeField] private string userId = "alice";

        [Header("Your backend")]
        [Tooltip("An endpoint of yours that returns a short-lived user token as plain text. " +
                 "The AppSecret that signs it must never leave your server.")]
        [SerializeField] private string tokenUrl = "https://your-backend.example.com/api/im-token";

        [Header("Chat")]
        [Tooltip("Who the Send button talks to.")]
        [SerializeField] private string peerUserId = "bob";

        private ImClient _client;

        private async void Start()
        {
            // A token is needed before the first connect; after that the SDK renews it in place
            // with conn.reauth, and only falls back to a reconnect if that fails.
            var token = await FetchTokenAsync(CancellationToken.None);
            if (string.IsNullOrEmpty(token))
            {
                Debug.LogError("[chat] no token, so no chat. Is " + tokenUrl + " reachable?");
                return;
            }

            // The cursor store and the user id are constructor arguments, not properties, because
            // neither has a safe default: without a store the SDK cannot tell "this device has
            // never seen this conversation" — where adopting the server's position is right — from
            // "this device was closed for a week" — where adopting it silently throws a week away;
            // and without the user id every account on the handset shares one set of cursors.
            //
            // The scope keys the file per account, so switching users and switching back finds each
            // account's cursors where it left them.
            var scope = ImCursorScope.Of(endpoint, appId, userId);

            _client = new ImClient(new ImClientOptions(ImCursorStore.PersistentDataPath(scope), userId)
            {
                Endpoint = endpoint,
                AppId = appId,
                Token = token,

                // Stable for this installation. A fresh id per launch makes a player kick
                // themselves offline under any single-device policy.
                DeviceId = ImDevice.GetOrCreateDeviceId(),

                ClientVersion = UnityEngine.Application.version,
                TokenProvider = FetchTokenAsync,
            });

            _client.MessageReceived += OnMessage;
            _client.StateChanged += OnStateChanged;
            _client.Kicked += OnKicked;
            _client.ConversationNeedsReload += OnConversationNeedsReload;
            _client.CursorStoreFailed += OnCursorStoreFailed;

            try
            {
                await _client.ConnectAsync();
            }
            catch (ImException failure)
            {
                // Connecting failed for a reason the server named — a rejected token, most likely.
                Debug.LogError("[chat] could not connect: " + failure);
                return;
            }

            // Offline push. Hand the SDK whatever token the vendor gave the app and it registers on
            // every connect from then on, because a vendor may replace the token while the process
            // is frozen and the server has no other way to learn that. On iOS this comes from
            // UnityEngine.iOS.NotificationServices.deviceToken; on Android from the Firebase Unity
            // SDK or the OEM plugin you already ship. Always name the provider on Android.
            var pushToken = ReadVendorPushToken();
            if (!string.IsNullOrEmpty(pushToken))
            {
                _client.Push.SetToken(PushProviderForThisPlatform(), pushToken);
            }

            var me = await _client.User.MeAsync();
            var conversations = await _client.Conv.ListAsync();
            Debug.Log("[chat] " + me.UserId + ": " + conversations.Items.Count + " conversations, " +
                      await _client.Conv.UnreadTotalAsync() + " unread");
        }

        /// <summary>Sends a message to <see cref="peerUserId"/>. Wire it to a button.</summary>
        public async void Send(string text)
        {
            if (_client == null || string.IsNullOrEmpty(text))
            {
                return;
            }

            try
            {
                var result = await _client.Msg.SendAsync(new ImSendRequest
                {
                    Recipient = ImRecipient.User(peerUserId),
                    ContentType = ImMessageContentType.Text,
                    Content = JsonValue.NewObject().Set("text", text),
                });

                // Holding a seq means the message is persisted. Render the bubble as sent here,
                // not when the button was pressed.
                Debug.Log("[chat] sent, seq " + result.Seq + (result.Deduplicated ? " (deduplicated)" : string.Empty));
            }
            catch (ImException failure)
            {
                // Every failure the server can name arrives here with a code worth branching on.
                if (failure.Code == ImErrorCode.ModerationRejected)
                {
                    Debug.LogWarning("[chat] that message was rejected by moderation");
                    return;
                }

                // IsRetryable is computed from the code alone and is the same in all five SDKs.
                // The SDK never retries a business call for you: it hides rate limiting from the UI
                // that has to explain it.
                Debug.LogWarning("[chat] send failed" + (failure.IsRetryable ? " (worth retrying)" : string.Empty) +
                                 ": " + failure);
            }
        }

        /// <summary>Sends an image, which takes an upload ticket first.</summary>
        /// <remarks>
        /// The bytes go straight to object storage and never through the gateway, and what goes in
        /// the message is the object <i>key</i> — not a URL. Every reader signs their own
        /// short-lived link with <c>Media.DownloadUrlAsync</c>, which is the only thing that makes
        /// expiry and revocation possible; a URL baked into a message is public forever the moment
        /// it leaks.
        /// </remarks>
        public async void SendImage(byte[] png, string fileName)
        {
            if (_client == null || png == null || png.Length == 0)
            {
                return;
            }

            try
            {
                var ticket = await _client.Media.UploadTicketAsync(new ImUploadTicketRequest
                {
                    FileName = fileName,
                    ContentType = "image/png",
                    Size = png.LongLength,
                });

                using (var upload = UnityWebRequest.Put(ticket.UploadUrl, png))
                {
                    upload.SetRequestHeader("Content-Type", "image/png");
                    await ToTask(upload.SendWebRequest());

                    if (upload.result != UnityWebRequest.Result.Success)
                    {
                        Debug.LogWarning("[chat] upload failed: " + upload.error);
                        return;
                    }
                }

                await _client.Msg.SendAsync(new ImSendRequest
                {
                    Recipient = ImRecipient.User(peerUserId),
                    ContentType = ImMessageContentType.Image,
                    Content = JsonValue.NewObject().Set("url", ticket.ObjectKey),
                });
            }
            catch (ImException failure)
            {
                // The tenant's own allow-list and size ceiling are checked before any bytes leave
                // the device, which is the point of asking for a ticket first.
                Debug.LogWarning("[chat] could not send that image: " + failure);
            }
        }

        /// <summary>Signs the user out. Not the same thing as disconnecting.</summary>
        /// <remarks>
        /// <see cref="ImClient.LogoutAsync"/> unregisters this device for offline push and only then
        /// closes the socket. The order is the whole feature: after the socket is gone there is no
        /// authenticated channel and the token cannot be removed at all, so the handset would keep
        /// receiving the next user's notifications until your backend cleaned it up with
        /// <c>DELETE /v1/users/{userId}/push-tokens/{deviceId}</c>.
        /// </remarks>
        public async void Logout()
        {
            if (_client == null)
            {
                return;
            }

            await _client.LogoutAsync();

            // Cursors and your local messages have exactly one lifetime, cursors first. If you are
            // wiping the local conversation history on logout, wipe the cursor file with it —
            // keeping cursors and losing messages leaves conversations that will never refill.
            Debug.Log("[chat] signed out");
        }

        private void OnMessage(ImMessage message)
        {
            // On the main thread, so instantiating a prefab here is safe.
            Debug.Log("[chat] " + message.ConversationId + " #" + message.Seq + " " +
                      message.SenderId + ": " + (message.Text ?? message.ContentType.ToString()));

            if (message.Seq == 0)
            {
                // Never persisted — chat-room traffic and other online-only signals. It carries no
                // position, so there is nothing to commit.
                return;
            }

            // Store it, then say so. Commit is what the SDK reports to the server on the next
            // connect, so committing before the write has landed is how a crash turns into a
            // permanently skipped message. Delivery is at-least-once: be idempotent on MessageId.
            //
            // A game with no store of its own can commit straight from here. "Durable" then means
            // "as durable as this game gets", which is honest — and it is still better than the SDK
            // assuming it, because the choice is visible in your code rather than hidden in ours.
            _client.Commit(message.ConversationId, message.Seq);

            // Move the read cursor as the player sees things. Unread counts everywhere else are
            // derived from it, so there is no counter to keep in step.
            var ignored = _client.Conv.ReadAsync(message.ConversationId, message.Seq);
        }

        private static void OnStateChanged(ImConnectionState state)
        {
            Debug.Log("[chat] connection " + state);
        }

        private static void OnKicked(ImKick kick)
        {
            if (!kick.IsTerminal)
            {
                return;
            }

            // Terminal means the SDK has stopped. Leaving a spinner up would be a lie: nothing is
            // coming back without the player logging in again.
            Debug.LogWarning("[chat] signed out: " + kick.RawReason);
        }

        private void OnConversationNeedsReload(string conversationId)
        {
            // Further behind than the SDK will backfill message by message. New messages still
            // arrive and the cursor is honest; the stretch in between has to come from history.
            Debug.Log("[chat] " + conversationId + " needs reloading from history");
        }

        private static void OnCursorStoreFailed(ImCursorStoreException failure)
        {
            // The stored cursors could not be read. The SDK will not adopt anything and will not
            // write anything for the rest of this session, because a failed load and a fresh
            // install look identical to the adoption branch and guessing wrong destroys history.
            //
            // The fix is to hand back what your own database knows: for each conversation you
            // store, call im.Commit(conversationId, highestSeqYouHold). Commit is monotonic, so
            // order does not matter.
            Debug.LogError("[chat] cursor store unreadable, re-derive from your own store: " + failure.Message);
        }

        /// <summary>
        /// Asks your backend for a user token.
        /// </summary>
        /// <remarks>
        /// <para>
        /// The SDK calls this on the main thread, which is why starting a <c>UnityWebRequest</c>
        /// here is legal. Returning null tells the SDK to stop reconnecting — the right answer when
        /// your own session is gone, and the reason this returns null instead of throwing.
        /// </para>
        /// <para>
        /// In a real game this request carries your own session cookie or bearer token: the IM
        /// service trusts your backend to decide who the player is.
        /// </para>
        /// </remarks>
        private Task<string> FetchTokenAsync(CancellationToken cancellationToken)
        {
            var completion = new TaskCompletionSource<string>();
            var request = UnityWebRequest.Get(tokenUrl);

            // Expect this to run on a device that has just come back from a tunnel, so it needs a
            // deadline of its own — the SDK is waiting on this before it can reconnect.
            request.timeout = 10;

            request.SendWebRequest().completed += delegate
            {
                try
                {
                    if (request.result != UnityWebRequest.Result.Success)
                    {
                        Debug.LogWarning("[chat] token request failed: " + request.error);
                        completion.TrySetResult(null);
                        return;
                    }

                    completion.TrySetResult(request.downloadHandler.text.Trim());
                }
                finally
                {
                    request.Dispose();
                }
            };

            return completion.Task;
        }

        /// <summary>
        /// Where the vendor's device token comes from on this platform.
        /// </summary>
        /// <remarks>
        /// Left as a stub because there is no single answer and the SDK deliberately takes no push
        /// dependency of its own. On iOS, ask for permission with
        /// <c>UnityEngine.iOS.NotificationServices.RegisterForNotifications</c> and hex-encode
        /// <c>NotificationServices.deviceToken</c> once it arrives. On Android, subscribe to the
        /// Firebase Unity SDK's <c>FirebaseMessaging.TokenReceived</c>, or to whichever OEM plugin
        /// the build ships, and call <c>im.Push.SetToken</c> from the callback — the SDK sends
        /// whatever it holds on every connect, so a token that arrives late is not a token that is
        /// lost.
        /// </remarks>
        private static string ReadVendorPushToken()
        {
            return null;
        }

        private static string PushProviderForThisPlatform()
        {
            switch (UnityEngine.Application.platform)
            {
                case RuntimePlatform.IPhonePlayer:
                    return ImPushProvider.Apns;

                case RuntimePlatform.Android:
                    // Firebase is the default; swap in ImPushProvider.Huawei / Xiaomi / Oppo / Vivo
                    // / Honor for an OEM build. Never send this empty on Android: the server cannot
                    // guess which of five channels a token came from, and an unroutable token looks
                    // exactly like a broken push provider.
                    return ImPushProvider.Fcm;

                default:
                    return ImPushProvider.Fcm;
            }
        }

        private static Task ToTask(UnityWebRequestAsyncOperation operation)
        {
            var completion = new TaskCompletionSource<bool>();
            operation.completed += delegate { completion.TrySetResult(true); };
            return completion.Task;
        }

        private void OnApplicationPause(bool paused)
        {
            if (_client == null)
            {
                return;
            }

            if (paused)
            {
                // The SDK also flushes its cursors on Unity's own suspend callbacks; this is here to
                // show the seam, and to give a game with its own save point somewhere to hook.
                _client.FlushCursors();
                return;
            }

            // Coming back from the background: the socket almost certainly died while the app was
            // suspended, and the OS will not say so. Retrying now beats waiting out a backoff that
            // was sized for a fleet-wide outage.
            _client.Connection.ReconnectNow();
        }

        private void OnDestroy()
        {
            if (_client != null)
            {
                _client.Dispose();
                _client = null;
            }
        }
    }
}
