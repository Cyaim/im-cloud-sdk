using System;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Threading;
using Cyaim.Im.Transport;

namespace Cyaim.Im
{
    /// <summary>Everything needed to open and keep a connection to the gateway.</summary>
    public class ImConnectionOptions
    {
        /// <summary>Gateway base URL, for example <c>wss://im.example.com</c>. No trailing path.</summary>
        public string Endpoint { get; set; }

        /// <summary>Channel path appended to <see cref="Endpoint"/>. The default matches the gateway.</summary>
        public string Channel { get; set; }

        /// <summary>Tenant id from the console. Safe to ship in the client.</summary>
        public string AppId { get; set; }

        /// <summary>
        /// Short-lived user token minted by your backend after your own login succeeded.
        /// </summary>
        /// <remarks>
        /// Never an AppSecret. The secret signs tokens and belongs on your server; anything shipped
        /// inside a game client should be assumed extracted within a day of release, and an
        /// extracted AppSecret lets a stranger impersonate every one of your users.
        /// </remarks>
        public string Token { get; set; }

        /// <summary>
        /// Stable per-installation id. Use <see cref="ImDevice.GetOrCreateDeviceId"/> unless you
        /// already have one — see the warning there about what a per-launch value does.
        /// </summary>
        public string DeviceId { get; set; }

        /// <summary>
        /// Who the token was minted for. Not sent in the handshake — the gateway reads the identity
        /// out of the token — but the SDK needs it to keep one account's cursors apart from
        /// another's on a shared device.
        /// </summary>
        /// <remarks>
        /// <see cref="ImClientOptions"/> takes it as a constructor argument and refuses an empty
        /// one, because without it every account on the handset scopes to the same
        /// <c>host|appId|*</c> and the account-switch guarantee quietly applies to nobody. Your
        /// backend already knows the value: it is the user it just signed a token for.
        /// </remarks>
        public string UserId { get; set; }

        /// <summary>
        /// Reported platform. Left as <see cref="ImPlatform.Unknown"/>, it is detected from the
        /// running Unity platform at connect time.
        /// </summary>
        public ImPlatform Platform { get; set; }

        /// <summary>Your build version, echoed in server logs and useful for narrowing a bug to a release.</summary>
        public string ClientVersion { get; set; }

        /// <summary>Preferred language tag, used for server-rendered notification text.</summary>
        public string Language { get; set; }

        /// <summary>
        /// How long a request waits for its reply before failing with
        /// <see cref="ImErrorCode.Timeout"/>.
        /// </summary>
        public TimeSpan RequestTimeout { get; set; }

        /// <summary>
        /// How long <see cref="ImConnection.ConnectAsync"/> waits for a socket to open before giving
        /// up. Retries inside that window use the normal backoff; when it expires the awaiting task
        /// fails and the connection stops, so a caller always gets an answer rather than a task that
        /// never completes. Set it to <see cref="TimeSpan.Zero"/> to wait indefinitely.
        /// </summary>
        public TimeSpan ConnectTimeout { get; set; }

        /// <summary>
        /// Called when the server closes the socket with <c>im-kick:TokenExpired</c>. Return a fresh
        /// token to reconnect with, or null to stop reconnecting and surface a kick.
        /// </summary>
        /// <remarks>
        /// This runs on the dispatcher thread — the Unity main thread in a game — so it is safe to
        /// start a <c>UnityWebRequest</c> here, which is the usual way to fetch one. Expect it to be
        /// called on a device that has just come back from a tunnel, so give it a timeout of its own.
        /// </remarks>
        public Func<CancellationToken, Task<string>> TokenProvider { get; set; }

        /// <summary>
        /// Where SDK callbacks run. Defaults to <see cref="ImMainThreadDispatcher"/>, which is the
        /// Unity main thread. Override it with a <see cref="ManualDispatcher"/> in tests, or in a
        /// headless build that drives its own loop.
        /// </summary>
        public IImDispatcher Dispatcher { get; set; }

        /// <summary>
        /// Creates the socket. Defaults to <see cref="ImTransports.CreateDefault"/>, which picks the
        /// right one for the build target. Called once per connection attempt, because a WebSocket
        /// cannot be reopened.
        /// </summary>
        public Func<IImTransport> TransportFactory { get; set; }

        /// <summary>
        /// Reconnect delay policy. Defaults to <see cref="FullJitterBackoff"/>.
        /// </summary>
        /// <remarks>
        /// Replaceable so it can be driven deterministically from a test — not because it is a
        /// tuning knob. Substituting a fixed delay here is how a gateway rolling update turns into
        /// an outage; read <see cref="FullJitterBackoff"/> before you do it.
        /// </remarks>
        public IReconnectBackoff Backoff { get; set; }

        /// <inheritdoc cref="ImConnectionOptions"/>
        public ImConnectionOptions()
        {
            Channel = "/im";
            Platform = ImPlatform.Unknown;
            RequestTimeout = TimeSpan.FromSeconds(15);
            ConnectTimeout = TimeSpan.FromSeconds(30);
        }

        /// <summary>Throws if a required field is missing, with a message that says which one.</summary>
        public virtual void Validate()
        {
            Require(Endpoint, "Endpoint");
            Require(AppId, "AppId");
            Require(Token, "Token");
            Require(DeviceId, "DeviceId");

            if (RequestTimeout <= TimeSpan.Zero)
            {
                throw new ArgumentException("RequestTimeout must be positive.", "RequestTimeout");
            }
        }

        private static void Require(string value, string name)
        {
            if (string.IsNullOrEmpty(value))
            {
                throw new ArgumentException("ImConnectionOptions." + name + " is required.", name);
            }
        }
    }
}
