import Foundation
import Testing

@testable import CyaimIM

/// Records the body every request type of this SDK encodes to into `sdk/wire-samples/swift.json`,
/// and fails when that output drifts from the committed file.
///
/// The file is judged in the platform repository by `SdkWireSampleBindingTests`, which binds every
/// recorded body with the socket plane's real conversion: a JSON number sent to a C# string answers
/// `1000`, and a nested key in the wrong case is dropped with status `0`. The TypeScript, Kotlin, Dart
/// and Unity suites record theirs the same way; this one follows the Kotlin recorder's shape, one
/// fully populated request per type, keyed by the type's name, which is the server DTO's name.
///
/// Each body is encoded exactly as ``ImConnection`` encodes a frame's body (a plain `JSONEncoder`,
/// see ``RequestWireKindTests``), plus `.sortedKeys` so the recording is stable (a Swift dictionary
/// has no key order) and `.withoutEscapingSlashes` so a URL reads as the other recordings spell it.
/// Neither changes a JSON kind or a key, which is all the binder judges. The typed methods hand
/// these objects to the socket unchanged.
///
/// Record with `IM_RECORD_WIRE_SAMPLES=1 swift test` (in `SDK/swift`) and commit the file. Without
/// the variable the test compares. The SDK repository's Swift job records and then fails when the
/// file differs from the committed one, and uploads it as the `swift-wire-samples` artifact.
///
/// 每个请求类型带全部字段编码一次，按 ImConnection 编码帧体的方式（普通 JSONEncoder，加 sortedKeys
/// 让顺序稳定）记进 sdk/wire-samples/swift.json；平台仓库用服务端真实的绑定器逐条判。
@Suite("Wire samples for the platform's binder")
struct WireSampleRecorderTests {

    /// Past 2^53 and odd: a Double round trip changes its last digit.
    private static let big: Int64 = 360_381_357_961_969_667
    private static let bigText = "360381357961969667"
    private static let time: Int64 = 1_758_412_790_000

    private static func sdkRoot(from here: String = #filePath) -> URL {
        var directory = URL(fileURLWithPath: here).deletingLastPathComponent()

        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("endpoint-inventory.json").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }

        fatalError("could not locate sdk/endpoint-inventory.json from \(here)")
    }

    /// One sample line: the request's type name, and its body as the frame would carry it.
    private static func line<T: Encodable>(_ request: T, _ encoder: JSONEncoder, _ note: String = "") throws -> String {
        let name = String(describing: T.self)
        let data = try encoder.encode(request)
        let body = String(decoding: data, as: UTF8.self)
        return "    {\"type\":\"\(name)\",\"via\":\"JSONEncoder(\(name))\(note)\",\"body\":\(body)}"
    }

    @Test("every request type's body matches sdk/wire-samples/swift.json")
    func recordedWireSamplesMatch() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var samples: [String] = []

        // conn
        try samples.append(Self.line(ReauthRequest(token: "token-2"), encoder))
        try samples.append(Self.line(
            ResumeRequest(convSeqs: ["c_wire": 42], conversationCursor: Self.time, cursor: "sync:2", limit: 100),
            encoder
        ))

        // msg
        try samples.append(Self.line(
            SendMessageRequest(
                conversationId: "c_wire",
                conversationType: .group,
                clientMsgId: "cm-1",
                contentType: .image,
                content: ["objectKey": .string("demo/alice/a.png"), "width": .int(640)],
                mentionAll: true,
                mentionedUserIds: ["bob", "carol"],
                quoteMessageId: Self.big,
                threadRootId: 7,
                options: MessageOptions(
                    persistent: false,
                    updateConversation: false,
                    countUnread: false,
                    offlinePush: false,
                    pushConfig: PushConfig(
                        title: "Alice",
                        body: "sent a photo",
                        sound: "ding.caf",
                        payload: ["deepLink": "app://c_wire"],
                        badgeCount: false,
                        channelId: "im_messages"
                    ),
                    needReceipt: true,
                    priority: .high,
                    onlineOnly: true,
                    noSelfSync: true,
                    expireIn: 5_000,
                    moderationBypass: true
                ),
                sendTime: Self.time,
                extensions: ["source": .string("wire")]
            ),
            encoder,
            " by conversationId, every field"
        ))
        try samples.append(Self.line(
            SendMessageRequest(receiverId: "bob", clientMsgId: "cm-2", content: ["text": .string("hi")], sendTime: Self.time),
            encoder,
            " by receiverId"
        ))
        try samples.append(Self.line(
            SendMessageRequest(groupId: "team", clientMsgId: "cm-3", content: ["text": .string("hi all")], sendTime: Self.time),
            encoder,
            " by groupId"
        ))
        try samples.append(Self.line(
            SyncMessagesRequest(conversationId: "c_wire", fromSeq: 2, toSeq: 9, limit: 100, ascending: false),
            encoder
        ))
        try samples.append(Self.line(HistoryRequest(conversationId: "c_wire", beforeSeq: 9, limit: 30), encoder))
        try samples.append(Self.line(RecallMessageRequest(conversationId: "c_wire", messageId: Self.big, reason: "typo"), encoder))
        try samples.append(Self.line(
            DeleteMessagesRequest(conversationId: "c_wire", messageIds: [Self.big, 7], forEveryone: true),
            encoder
        ))
        try samples.append(Self.line(TypingRequest(conversationId: "c_wire", typing: false), encoder))
        try samples.append(Self.line(
            EditMessageRequest(conversationId: "c_wire", messageId: Self.big, content: ["text": .string("fixed")]),
            encoder
        ))
        try samples.append(Self.line(
            ForwardMessagesRequest(
                sourceConversationId: "c_wire",
                messageIds: [Self.big, 7],
                targetConversationIds: ["g_team"],
                merge: true,
                mergeTitle: "Chat history",
                clientMsgId: "cm-fwd"
            ),
            encoder
        ))
        try samples.append(Self.line(ReactRequest(conversationId: "c_wire", messageId: Self.big, emoji: "+1", add: false), encoder))
        try samples.append(Self.line(ReceiptRequest(conversationId: "c_wire", messageIds: [Self.big, 7]), encoder))
        try samples.append(Self.line(ConversationMessageRequest(conversationId: "c_wire", messageId: Self.big), encoder))
        try samples.append(Self.line(PageRequest(cursor: "fav:2", limit: 10), encoder))
        try samples.append(Self.line(
            SearchMessagesRequest(
                keyword: "invoice",
                conversationId: "c_wire",
                contentTypes: [.text, .file],
                senderId: "bob",
                startTime: 1_758_412_700_000,
                endTime: Self.time,
                cursor: "search:2",
                limit: 20
            ),
            encoder
        ))
        try samples.append(Self.line(ReceiptDetailRequest(conversationId: "c_wire", messageId: Self.big), encoder))

        // conv
        try samples.append(Self.line(ListConversationsRequest(updatedAfter: Self.time, cursor: "conv:2", limit: 10), encoder))
        try samples.append(Self.line(ConversationIdRequest("c_wire"), encoder))
        try samples.append(Self.line(ReadRequest(conversationId: "c_wire", readSeq: 42), encoder))
        try samples.append(Self.line(
            UpdateConversationSettingRequest(
                conversationId: "c_wire",
                setting: ConversationSetting(
                    pinned: true,
                    muted: .silent,
                    draft: "half a thought",
                    tags: ["work"],
                    extensions: ["color": .string("red")]
                )
            ),
            encoder
        ))
        try samples.append(Self.line(MarkUnreadRequest(conversationId: "c_wire", unread: true), encoder))

        // user
        try samples.append(Self.line(UserIdRequest("bob"), encoder))
        try samples.append(Self.line(UserIdsRequest(["bob", "carol"]), encoder))
        try samples.append(Self.line(UpdateProfileRequest(patch: ["nickname": .string("Al"), "gender": .int(1)]), encoder))
        try samples.append(Self.line(SubscribePresenceRequest(userIds: ["bob"], ttlSeconds: 900), encoder))
        try samples.append(Self.line(SetStatusRequest("in a match"), encoder))

        // media, push, diag, moderation
        try samples.append(Self.line(UploadTicketRequest(fileName: "a.png", contentType: "image/png", size: 1_024), encoder))
        try samples.append(Self.line(DownloadUrlRequest(objectKey: "demo/alice/a.png", lifetimeSeconds: 600), encoder))
        try samples.append(Self.line(
            RegisterPushTokenRequest(provider: ImPushProvider.fcm, token: "fcm-token", language: "zh-CN"),
            encoder
        ))
        try samples.append(Self.line(PushClickedRequest(pushId: "pu_1", messageId: Self.bigText), encoder))
        try samples.append(Self.line(
            DeviceLogAnswer(
                requestId: "dl_1",
                uploaded: true,
                sizeBytes: 2_048,
                coveredFromMs: 1_758_412_700_000,
                isVolatile: true,
                detail: "trimmed to the newest 2 KiB"
            ),
            encoder
        ))
        try samples.append(Self.line(
            SubmitReportRequest(
                targetUserId: "mallory",
                conversationId: "c_wire",
                messageId: Self.big,
                category: ImReportCategory.spam,
                note: "n"
            ),
            encoder
        ))

        // friend
        try samples.append(Self.line(CursorRequest(cursor: "f:2", limit: 25), encoder))
        try samples.append(Self.line(AddFriendRequest(userId: "bob", greeting: "hi, it is alice", source: "search"), encoder))
        try samples.append(Self.line(HandleFriendRequest(fromUserId: "bob", accept: true, reason: "welcome"), encoder))
        try samples.append(Self.line(FriendRequestListRequest(incoming: false, cursor: "fr:2", limit: 25), encoder))
        try samples.append(Self.line(BlockRequest(userId: "mallory", reason: "spam"), encoder))
        try samples.append(Self.line(SetRemarkRequest(userId: "bob", remark: "Bob from work", tags: ["colleague"]), encoder))

        // group
        try samples.append(Self.line(
            CreateGroupRequest(
                name: "Team",
                memberIds: ["bob", "carol"],
                groupId: "team",
                avatar: "https://cdn.test/a.png",
                introduction: "the team",
                type: .superGroup,
                joinMode: .needApproval,
                inviteMode: .adminsOnly,
                maxMemberCount: 500,
                extensions: ["dept": .string("eng")]
            ),
            encoder
        ))
        try samples.append(Self.line(GroupIdRequest("team"), encoder))
        try samples.append(Self.line(
            UpdateGroupCommand(
                groupId: "team",
                update: UpdateGroupRequest(
                    name: "Team 2",
                    avatar: "https://cdn.test/b.png",
                    introduction: "renamed",
                    joinMode: .forbidden,
                    inviteMode: .forbidden,
                    maxMemberCount: 200,
                    extensions: ["dept": .string("ops")]
                )
            ),
            encoder
        ))
        try samples.append(Self.line(GroupCursorRequest(groupId: "team", cursor: "m:2", limit: 40), encoder))
        try samples.append(Self.line(GroupMembersRequest(groupId: "team", userIds: ["dave", "erin"], reason: "new hires"), encoder))
        try samples.append(Self.line(JoinGroupRequest(groupId: "team", reason: "let me in"), encoder))
        try samples.append(Self.line(TransferOwnerRequest(groupId: "team", newOwnerId: "bob"), encoder))
        try samples.append(Self.line(
            HandleApplicationRequest(groupId: "team", applicantId: "dave", accept: true, reason: "welcome"),
            encoder
        ))
        try samples.append(Self.line(SetRoleRequest(groupId: "team", userId: "bob", role: .admin), encoder))
        try samples.append(Self.line(MuteGroupRequest(groupId: "team", mute: true, untilMs: Self.time), encoder))
        try samples.append(Self.line(MuteMemberRequest(groupId: "team", userId: "mallory", untilMs: Self.time), encoder))
        try samples.append(Self.line(SetGroupNicknameRequest(groupId: "team", userId: "alice", nickname: "Al"), encoder))
        try samples.append(Self.line(AnnouncementRequest(groupId: "team", announcement: "standup at ten"), encoder))

        var lines: [String] = [
            "{",
            "  \"$comment\": \"RECORDED by SDK/swift/Tests/CyaimIMTests/WireSampleRecorderTests.swift from JSONEncoder, the encoder every typed method hands its request to. Do not edit by hand; re-record with IM_RECORD_WIRE_SAMPLES=1 swift test (in SDK/swift). Judged against the server's real socket binder by IM.Server/tests/IM.Tests.Unit/SdkWireSampleBindingTests.cs in the platform repository.\",",
            "  \"sdk\": \"swift\",",
            "  \"omitted\": {",
            "    \"RecallMessageRequest.asAdmin\": \"MsgController.Recall forces it false for every socket call; recalling as an admin is a server-API capability, so no client type carries it\"",
            "  },",
            "  \"samples\": [",
        ]
        for (index, sample) in samples.enumerated() {
            lines.append(index + 1 < samples.count ? sample + "," : sample)
        }
        lines.append("  ]")
        lines.append("}")

        let text = lines.joined(separator: "\n") + "\n"
        let url = Self.sdkRoot().appendingPathComponent("wire-samples").appendingPathComponent("swift.json")

        if ProcessInfo.processInfo.environment["IM_RECORD_WIRE_SAMPLES"] == "1" {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("\(url.path) is missing; run swift test with IM_RECORD_WIRE_SAMPLES=1 and commit the file")
            return
        }

        let committed = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let committedLines = committed.components(separatedBy: "\n")
        let liveLines = text.components(separatedBy: "\n")

        var differences: [String] = []
        for index in 0 ..< max(committedLines.count, liveLines.count) where differences.count < 12 {
            let was = index < committedLines.count ? committedLines[index] : "(no line)"
            let now = index < liveLines.count ? liveLines[index] : "(no line)"
            if was != now {
                differences.append("line \(index + 1)\n  committed: \(was)\n  sent now:  \(now)")
            }
        }

        let report = differences.joined(separator: "\n")
        #expect(
            differences.isEmpty,
            "what the request types encode to has drifted from \(url.path); re-record with IM_RECORD_WIRE_SAMPLES=1 and commit the file.\n\(report)"
        )
    }
}
