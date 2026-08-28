package com.cyaim.im.client

/**
 * `moderation.*` — what an end user can do about content.
 *
 * The other half of what [FriendApi.block] is here for. App-store review asks for both a way to
 * block an abusive user and a way to report objectionable content in any app carrying
 * user-generated content, and an SDK that ships only the first turns a review rejection into a
 * release cycle.
 *
 * Reporting is on the socket rather than on the tenant's server API for the reason blocking is: it
 * is an end user's action, and the socket is the only surface where the user is a fact rather than
 * a parameter. A tenant backend proxying a report would have to be trusted with a reporter id it
 * cannot verify.
 *
 * 与 block 是同一件事的两半：应用商店对 UGC 应用同时要求「能拉黑」和「能举报」。
 * 举报走 socket 而不是租户服务端 API，理由和拉黑一样——举报人是终端用户，
 * 而 socket 是「举报人是谁」唯一不需要相信任何人的那个面。
 */
public class ModerationApi internal constructor(private val connection: ImConnection) {

    /**
     * Reports another user, optionally naming a message, and returns the receipt.
     *
     * The reporter is not an argument and cannot be: see [SubmitReportRequest]. Leave
     * [SubmitReportRequest.messageId] at 0 to report the account rather than one message.
     *
     * Refuses with `1001 InvalidArgument` for a blank `targetUserId`, for reporting yourself, and
     * for a category outside [ReportCategory]. All three are the caller's own bug rather than
     * something to show a user, so validate the category against [ReportCategory] before you send.
     *
     * There is nothing to poll afterwards and no state to read back — the receipt is the whole
     * answer, and a screen that promises to report on the outcome is promising something this
     * endpoint deliberately does not return.
     */
    public suspend fun report(request: SubmitReportRequest): ReportReceipt =
        connection.request("moderation.report", request.asBody())
}
