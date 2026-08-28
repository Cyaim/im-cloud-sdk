using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>media.*</c> — attachments. Bytes go straight to object storage and never through the
    /// gateway.
    /// </summary>
    /// <remarks>
    /// <para>The shape of an image send, end to end:</para>
    /// <code>
    /// var ticket = await im.Media.UploadTicketAsync(new ImUploadTicketRequest
    /// {
    ///     FileName = "screenshot.png", ContentType = "image/png", Size = bytes.LongLength,
    /// });
    ///
    /// using (var put = UnityWebRequest.Put(ticket.UploadUrl, bytes))
    /// {
    ///     put.SetRequestHeader("Content-Type", "image/png");
    ///     await put.SendWebRequest();
    /// }
    ///
    /// await im.Msg.SendAsync(new ImSendRequest
    /// {
    ///     Recipient   = ImRecipient.User("bob"),
    ///     ContentType = ImMessageContentType.Image,
    ///     Content     = JsonValue.NewObject().Set("url", ticket.ObjectKey),
    /// });
    /// </code>
    /// <para>
    /// Note what goes in the message: <c>ObjectKey</c>, not a URL. Every reader signs their own
    /// short-lived link with
    /// <see cref="DownloadUrlAsync(ImDownloadUrlRequest,CancellationToken)"/>, which is the only
    /// thing that makes expiry, revocation and per-reader access control possible at all. A URL
    /// baked into a message is public forever the moment it leaks.
    /// </para>
    /// </remarks>
    public sealed class ImMediaApi : ImApiNamespace
    {
        internal ImMediaApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Issues a short-lived presigned PUT. The server chooses the object key, so a client cannot
        /// write outside its own tenant and user prefix.
        /// </summary>
        /// <remarks>
        /// Fails with <see cref="ImErrorCode.FileTypeNotAllowed"/> or
        /// <see cref="ImErrorCode.FileTooLarge"/> against the tenant's own limits, before any bytes
        /// leave the device — which is the point of asking first.
        /// </remarks>
        public Task<ImMediaUploadTicket> UploadTicketAsync(
            ImUploadTicketRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.FileName, "fileName");
            Require(request.ContentType, "contentType");
            return RequestAsync<ImMediaUploadTicket>("media.uploadTicket", request, cancellationToken);
        }

        /// <summary>Exchanges a stored object key for a short-lived download URL.</summary>
        /// <remarks>
        /// Sign one when the image is about to be shown, not when the message arrives: the URL
        /// expires (an hour by default), and a link signed at receive time is dead by the time the
        /// player scrolls back to it.
        /// </remarks>
        public async Task<string> DownloadUrlAsync(
            ImDownloadUrlRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ObjectKey, "objectKey");

            var data = await RequestAsync("media.downloadUrl", request, cancellationToken).ConfigureAwait(false);
            return data.AsString(string.Empty);
        }

        /// <summary>Shorthand for <see cref="DownloadUrlAsync(ImDownloadUrlRequest,CancellationToken)"/>.</summary>
        public Task<string> DownloadUrlAsync(
            string objectKey,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return DownloadUrlAsync(new ImDownloadUrlRequest(objectKey), cancellationToken);
        }
    }
}
