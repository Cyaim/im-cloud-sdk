package com.cyaim.im.client

/**
 * `media.*` — attachments.
 *
 * The bytes never pass through the gateway. You ask for a ticket, `PUT` the file straight to
 * object storage with the SDK's HTTP client of your choice, then send a message whose content
 * carries the ticket's `objectKey`. Readers exchange that key for a short-lived signed link with
 * [downloadUrl].
 *
 * Messages carry a key and never a URL, which is what makes expiry, revocation and per-reader
 * access control possible at all: a URL baked into a message is public forever the moment it leaks.
 *
 * 消息里存 object key 而不是 URL：每个读者自己签发短期链接，过期与撤销才有意义。
 */
public class MediaApi internal constructor(private val connection: ImConnection) {

    /**
     * A short-lived presigned upload. The server chooses the object key, so a client cannot write
     * outside its own tenant and user prefix.
     *
     * `size` is sent up front so an oversized file is refused before the device spends the
     * bandwidth rather than after: `1702 FileTooLarge`, or `1701 FileTypeNotAllowed` for a content
     * type the tenant does not accept.
     */
    public suspend fun uploadTicket(request: UploadTicketRequest): MediaUploadTicket =
        connection.request("media.uploadTicket", request.asBody())

    /**
     * Signs a download link for a stored object.
     *
     * Sign it when the user is about to look at the file, not when the message arrives — a link
     * signed at receive time is usually expired by the time anyone taps it.
     */
    public suspend fun downloadUrl(request: DownloadUrlRequest): String =
        connection.request("media.downloadUrl", request.asBody())

    /** [downloadUrl] for the common call shape. */
    public suspend fun downloadUrl(objectKey: String, lifetimeSeconds: Int = 3600): String =
        downloadUrl(DownloadUrlRequest(objectKey, lifetimeSeconds))
}
