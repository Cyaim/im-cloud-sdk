using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Records what every typed method of this SDK puts on the socket into
    /// <c>sdk/wire-samples/unity.json</c>, and fails when that output drifts from the committed file.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The file is judged in the platform repository by <c>SdkWireSampleBindingTests</c>, which
    /// binds every recorded body with the socket plane's real conversion. That is the only check that
    /// sees what the binder does with a body — a JSON number sent to a C# string answers
    /// <c>1000</c>, and a nested key in the wrong case is dropped with status <c>0</c> — and it can
    /// only judge what a recorder hands it. The TypeScript, Kotlin and Dart suites record theirs the
    /// same way; this is the Unity one.
    /// 每个类型化方法都带着全部字段打到假 socket 上，把实际发出的请求体记进 sdk/wire-samples/unity.json；
    /// 平台仓库用服务端真实的绑定器把它们逐条绑一遍。输出与已提交的文件不一致即失败。
    /// </para>
    /// <para>
    /// <b>Recording.</b> Run the suite with <c>IM_RECORD_WIRE_SAMPLES=1</c> and commit the file.
    /// Without the variable the suite compares, so a changed body goes red here until it is
    /// re-recorded, and the new recording is then judged by the binder. Record mode asserts
    /// nothing about drift, so it is refused when <c>CI</c> is set: a variable a developer exported
    /// to re-record must not turn the only drift gate for this file into a green re-record.
    /// 录制：带 IM_RECORD_WIRE_SAMPLES=1 跑一遍并提交文件；不带时是比对模式。
    /// 录制模式不判漂移，所以设了 CI 时拒绝录制——开发者为重录而导出的变量不能把唯一的漂移门变成一次绿色的重录。
    /// </para>
    /// <para>
    /// <b>What is written by this file rather than by the SDK.</b> <see cref="ImSendRequest.Options"/>
    /// and <see cref="ImSendRequest.Extensions"/> are untyped <see cref="JsonValue"/>s the SDK passes
    /// through verbatim, so the keys inside <c>options</c> (and its <c>pushConfig</c>) are this
    /// file's spelling of the server's <c>MessageOptions</c> and <c>PushConfig</c>, not the SDK's.
    /// They are populated so the binder judges them, and a caller who spells them differently is not
    /// covered by this recording. The same holds for <c>content</c>, <c>patch</c> and every
    /// <c>extensions</c>. Two fields are pinned because the SDK generates them from the clock and a
    /// random source: <c>sendTime</c> always, <c>clientMsgId</c> when the caller left it empty. Each
    /// is checked for the server's JSON kind before it is replaced, so the pin cannot hide a kind
    /// defect.
    /// options / extensions / content 是 SDK 原样透传的无类型 JsonValue，里面的键是本文件写的；
    /// sendTime 与自动生成的 clientMsgId 取自时钟与随机源，先按服务端类型判过 JSON 形态再钉住。
    /// </para>
    /// </remarks>
    public sealed class WireSampleRecorderTests
    {
        private const string Big = "360381357961969667";

        private const long BigValue = 360381357961969667L;

        private const long PinnedTime = 1758412790000L;

        private const string PinnedId = "generated";

        private const string RecordVariable = "IM_RECORD_WIRE_SAMPLES";

        /// <summary>
        /// The namespaces whose public methods are the typed surface, in the spelling the rows'
        /// <c>via</c> uses (<c>ImMsgApi</c> is <c>Msg</c>).
        /// </summary>
        private static readonly Type[] Namespaces =
        {
            typeof(ImConnApi),
            typeof(ImMsgApi),
            typeof(ImConvApi),
            typeof(ImUserApi),
            typeof(ImFriendApi),
            typeof(ImGroupApi),
            typeof(ImMediaApi),
            typeof(ImPushApi),
            typeof(ImModerationApi),
            typeof(ImDiagApi),
        };

        /// <summary>
        /// Public methods with no row, each with the reason. Everything else on the namespaces, and
        /// every public <see cref="Task"/>-returning method of <see cref="ImClient"/>, needs a row.
        /// </summary>
        private static readonly KeyValuePair<string, string>[] NoRow =
        {
            new KeyValuePair<string, string>(
                "Push.ClearToken",
                "forgets the cached token on the device and sends nothing; the logout that tells the server is ImClient.LogoutAsync, which has a row"),
            new KeyValuePair<string, string>(
                "ImClient.ConnectAsync",
                "opens the socket; the resume it sends is an ImResumeRequest, the type the Conn.SyncAsync row records with every member set"),
            new KeyValuePair<string, string>(
                "ImClient.InvokeAsync",
                "the untyped escape hatch: the body is the caller's JsonValue, so there is no SDK spelling to record"),
            new KeyValuePair<string, string>(
                "ImClient.InvokeListAsync",
                "the untyped escape hatch: the body is the caller's JsonValue, so there is no SDK spelling to record"),
            new KeyValuePair<string, string>(
                "ImClient.InvokePageAsync",
                "the untyped escape hatch: the body is the caller's JsonValue, so there is no SDK spelling to record"),
        };

        private static readonly string[] ShippedTiers = { "T0", "T1", "T2", "T3" };

        /// <summary>
        /// Server request fields no Unity body carries, each with the reason. The platform repository
        /// turns red if a body sends one of these, or if one names no field.
        /// </summary>
        private static readonly KeyValuePair<string, string>[] Omitted =
        {
            new KeyValuePair<string, string>(
                "RecallMessageRequest.asAdmin",
                "MsgController.Recall forces it false for every socket call; recalling as an admin is a server-API capability, so ImRecallMessageRequest has no member for it"),
            new KeyValuePair<string, string>(
                "SendMessageRequest.conversationType",
                "ImSendRequest has no member for it (ImModels.cs): the recipient's mode (User / Group / Conversation) is the only addressing this SDK sends"),
            new KeyValuePair<string, string>(
                "SendMessageRequest.threadRootId",
                "ImSendRequest has no member for it (ImModels.cs): this SDK cannot reply in a thread"),
        };

        private sealed class Row
        {
            internal string Target;
            internal string Via;
            internal Func<ImClient, Task> Call;
            internal bool GeneratedClientMsgId;

            /// <summary>Runs, and is pumped, before the harness connects.</summary>
            internal Action<ImClient> Setup;
        }

        private static Row R(string target, string via, Func<ImClient, Task> call)
        {
            return new Row { Target = target, Via = via, Call = call };
        }

        private static Row Generated(string target, string via, Func<ImClient, Task> call)
        {
            return new Row { Target = target, Via = via, Call = call, GeneratedClientMsgId = true };
        }

        /// <summary>A row whose client already holds a push token when it connects.</summary>
        private static Row WithToken(string target, string via, Func<ImClient, Task> call)
        {
            return new Row
            {
                Target = target,
                Via = via,
                Call = call,
                Setup = c => c.Push.SetToken(ImPushProvider.Fcm, "fcm-token", "zh-CN"),
            };
        }

        private static JsonValue Obj(string key, string value)
        {
            return JsonValue.NewObject().Set(key, value);
        }

        private static List<string> Strings(params string[] values)
        {
            return new List<string>(values);
        }

        /// <summary>
        /// The server's <c>MessageOptions</c>, every member set away from its default, spelled as the
        /// server's System.Text.Json defaults read a nested object: camelCase, matched exactly.
        /// </summary>
        private static JsonValue FullOptions()
        {
            var push = JsonValue.NewObject()
                .Set("title", "Alice")
                .Set("body", "sent a photo")
                .Set("sound", "ding.caf")
                .Set("payload", Obj("deepLink", "app://c_wire"))
                .Set("badgeCount", false)
                .Set("channelId", "im_messages");

            return JsonValue.NewObject()
                .Set("persistent", false)
                .Set("updateConversation", false)
                .Set("countUnread", false)
                .Set("offlinePush", false)
                .Set("pushConfig", push)
                .Set("needReceipt", true)
                .Set("priority", 2L)
                .Set("onlineOnly", true)
                .Set("noSelfSync", true)
                .Set("expireIn", 5000L)
                .Set("moderationBypass", true);
        }

        private static ImSendRequest FullSend(ImRecipient recipient, string clientMsgId)
        {
            return new ImSendRequest
            {
                Recipient = recipient,
                ContentType = ImMessageContentType.Image,
                Content = JsonValue.NewObject().Set("objectKey", "demo/alice/a.png").Set("width", 640L),
                ClientMsgId = clientMsgId,
                MentionedUserIds = new[] { "bob", "carol" },
                MentionAll = true,
                QuoteMessageId = BigValue,
                Options = FullOptions(),
                Extensions = Obj("source", "wire"),
            };
        }

        /// <summary>
        /// One row per public typed method, overload, defaulted call and frozen alias, each with
        /// every member its request type has set to a value that is neither empty nor the default.
        /// </summary>
        private static List<Row> Rows()
        {
            var rows = new List<Row>
            {
                // ------------------------------------------------------------------ conn
                R("conn.heartbeat", "Conn.HeartbeatAsync()", c => c.Conn.HeartbeatAsync()),
                R("conn.reauth", "Conn.ReauthAsync(ImReauthRequest)", c => c.Conn.ReauthAsync(new ImReauthRequest { Token = "token-2" })),
                R("conn.reauth", "Conn.ReauthAsync(string)", c => c.Conn.ReauthAsync("token-3")),
                R("conn.sync", "Conn.SyncAsync(ImResumeRequest)", c => c.Conn.SyncAsync(new ImResumeRequest
                {
                    ConvSeqs = new Dictionary<string, long> { { "c_wire", 42L } },
                    ConversationCursor = PinnedTime,
                    Cursor = "sync:2",
                    Limit = 100,
                })),

                // ------------------------------------------------------------------- msg
                R("msg.send", "Msg.SendAsync(ImRecipient.User), every member", c => c.Msg.SendAsync(FullSend(ImRecipient.User("bob"), "cm-1"))),
                R("msg.send", "Msg.SendAsync(ImRecipient.Group), every member", c => c.Msg.SendAsync(FullSend(ImRecipient.Group("team"), "cm-2"))),
                R("msg.send", "Msg.SendAsync(ImRecipient.Conversation), every member", c => c.Msg.SendAsync(FullSend(ImRecipient.Conversation("c_wire"), "cm-3"))),
                Generated("msg.send", "Msg.SendAsync, defaults filled in", c => c.Msg.SendAsync(new ImSendRequest
                {
                    Recipient = ImRecipient.User("bob"),
                    Content = Obj("text", "hi"),
                })),
                R("msg.sync", "Msg.SyncAsync", c => c.Msg.SyncAsync(new ImSyncMessagesRequest
                {
                    ConversationId = "c_wire",
                    FromSeq = 2,
                    ToSeq = 9,
                    Limit = 100,
                    Ascending = true,
                })),
                R("msg.history", "Msg.HistoryAsync", c => c.Msg.HistoryAsync(new ImHistoryRequest
                {
                    ConversationId = "c_wire",
                    BeforeSeq = 9,
                    Limit = 30,
                })),
                R("msg.recall", "Msg.RecallAsync", c => c.Msg.RecallAsync(new ImRecallMessageRequest
                {
                    ConversationId = "c_wire",
                    MessageId = Big,
                    Reason = "typo",
                })),
                R("msg.delete", "Msg.DeleteAsync", c => c.Msg.DeleteAsync(new ImDeleteMessagesRequest
                {
                    ConversationId = "c_wire",
                    MessageIds = Strings(Big, "7"),
                    ForEveryone = true,
                })),
                R("msg.typing", "Msg.TypingAsync", c => c.Msg.TypingAsync(new ImTypingRequest { ConversationId = "c_wire", Typing = true })),
                R("msg.edit", "Msg.EditAsync", c => c.Msg.EditAsync(new ImEditMessageRequest
                {
                    ConversationId = "c_wire",
                    MessageId = Big,
                    Content = Obj("text", "fixed"),
                })),
                R("msg.forward", "Msg.ForwardAsync", c => c.Msg.ForwardAsync(new ImForwardMessagesRequest
                {
                    SourceConversationId = "c_wire",
                    MessageIds = Strings(Big, "7"),
                    TargetConversationIds = Strings("g_team"),
                    Merge = true,
                    MergeTitle = "Chat history",
                    ClientMsgId = "cm-fwd",
                })),
                R("msg.react", "Msg.ReactAsync", c => c.Msg.ReactAsync(new ImReactRequest
                {
                    ConversationId = "c_wire",
                    MessageId = Big,
                    Emoji = "+1",
                    Add = true,
                })),
                R("msg.receipt", "Msg.ReceiptAsync", c => c.Msg.ReceiptAsync(new ImReceiptRequest
                {
                    ConversationId = "c_wire",
                    MessageIds = Strings(Big, "7"),
                })),
                R("msg.pin", "Msg.PinAsync", c => c.Msg.PinAsync(new ImConversationMessageRequest("c_wire", Big))),
                R("msg.unpin", "Msg.UnpinAsync", c => c.Msg.UnpinAsync(new ImConversationMessageRequest("c_wire", Big))),
                R("msg.pins", "Msg.PinsAsync", c => c.Msg.PinsAsync(new ImConversationIdRequest("c_wire"))),
                R("msg.favourite", "Msg.FavouriteAsync", c => c.Msg.FavouriteAsync(new ImConversationMessageRequest("c_wire", Big))),
                R("msg.unfavourite", "Msg.UnfavouriteAsync", c => c.Msg.UnfavouriteAsync(new ImConversationMessageRequest("c_wire", Big))),
                R("msg.favourites", "Msg.FavouritesAsync(ImPageRequest)", c => c.Msg.FavouritesAsync(new ImPageRequest { Cursor = "fav:2", Limit = 10 })),
                R("msg.favourites", "Msg.FavouritesAsync()", c => c.Msg.FavouritesAsync()),
                R("msg.burn", "Msg.BurnAsync", c => c.Msg.BurnAsync(new ImConversationMessageRequest("c_wire", Big))),
                R("msg.search", "Msg.SearchAsync", c => c.Msg.SearchAsync(new ImSearchMessagesRequest
                {
                    Keyword = "invoice",
                    ConversationId = "c_wire",
                    ContentTypes = new List<ImMessageContentType> { ImMessageContentType.Text, ImMessageContentType.File },
                    SenderId = "bob",
                    StartTime = 1758412700000L,
                    EndTime = PinnedTime,
                    Cursor = "search:2",
                    Limit = 20,
                })),
                R("msg.receiptDetail", "Msg.ReceiptDetailAsync", c => c.Msg.ReceiptDetailAsync(new ImReceiptDetailRequest("c_wire", Big))),

                // ------------------------------------------------------------------ conv
                R("conv.list", "Conv.ListAsync(ImListConversationsRequest)", c => c.Conv.ListAsync(new ImListConversationsRequest
                {
                    UpdatedAfter = PinnedTime,
                    Cursor = "conv:2",
                    Limit = 50,
                })),
                R("conv.list", "Conv.ListAsync()", c => c.Conv.ListAsync()),
                R("conv.get", "Conv.GetAsync(ImConversationIdRequest)", c => c.Conv.GetAsync(new ImConversationIdRequest("c_wire"))),
                R("conv.get", "Conv.GetAsync(string)", c => c.Conv.GetAsync("c_wire")),
                R("conv.read", "Conv.ReadAsync(ImReadRequest)", c => c.Conv.ReadAsync(new ImReadRequest("c_wire", 42L))),
                R("conv.read", "Conv.ReadAsync(string, long)", c => c.Conv.ReadAsync("c_wire", 43L)),
                R("conv.unreadTotal", "Conv.UnreadTotalAsync()", c => c.Conv.UnreadTotalAsync()),
                R("conv.setting", "Conv.SettingAsync", c => c.Conv.SettingAsync(new ImUpdateConversationSettingRequest
                {
                    ConversationId = "c_wire",
                    Setting = new ImConversationSetting
                    {
                        Pinned = true,
                        Muted = ImMuteMode.Silent,
                        Draft = "half a thought",
                        Tags = Strings("work"),
                        Extensions = Obj("color", "red"),
                    },
                })),
                R("conv.delete", "Conv.DeleteAsync", c => c.Conv.DeleteAsync(new ImConversationIdRequest("c_wire"))),
                R("conv.clear", "Conv.ClearAsync", c => c.Conv.ClearAsync(new ImConversationIdRequest("c_wire"))),
                R("conv.markUnread", "Conv.MarkUnreadAsync", c => c.Conv.MarkUnreadAsync(new ImMarkUnreadRequest("c_wire", true))),

                // ------------------------------------------------------------------ diag
                R("diag.logRequests", "Diag.LogRequestsAsync()", c => c.Diag.LogRequestsAsync()),
                R("diag.logUploaded", "Diag.LogUploadedAsync", c => c.Diag.LogUploadedAsync(new ImDeviceLogAnswer
                {
                    RequestId = "dl_1",
                    Uploaded = true,
                    SizeBytes = 2048,
                    CoveredFromMs = 1758412700000L,
                    Volatile = true,
                    Detail = "trimmed to the newest 2 KiB",
                })),

                // ---------------------------------------------------------------- friend
                R("friend.list", "Friend.ListAsync(ImCursorRequest)", c => c.Friend.ListAsync(new ImCursorRequest { Cursor = "f:2", Limit = 25 })),
                R("friend.list", "Friend.ListAsync()", c => c.Friend.ListAsync()),
                R("friend.add", "Friend.AddAsync", c => c.Friend.AddAsync(new ImAddFriendRequest
                {
                    UserId = "bob",
                    Greeting = "hi, it is alice",
                    Source = "search",
                })),
                R("friend.handleRequest", "Friend.HandleRequestAsync", c => c.Friend.HandleRequestAsync(new ImHandleFriendRequest
                {
                    FromUserId = "bob",
                    Accept = true,
                    Reason = "welcome",
                })),
                R("friend.requestList", "Friend.RequestListAsync(ImFriendRequestListRequest)", c => c.Friend.RequestListAsync(new ImFriendRequestListRequest
                {
                    Incoming = true,
                    Cursor = "fr:2",
                    Limit = 25,
                })),
                R("friend.requestList", "Friend.RequestListAsync()", c => c.Friend.RequestListAsync()),
                R("friend.delete", "Friend.DeleteAsync", c => c.Friend.DeleteAsync(new ImUserIdRequest("bob"))),
                R("friend.blockList", "Friend.BlockListAsync(ImCursorRequest)", c => c.Friend.BlockListAsync(new ImCursorRequest { Cursor = "b:2", Limit = 25 })),
                R("friend.blockList", "Friend.BlockListAsync()", c => c.Friend.BlockListAsync()),
                R("friend.block", "Friend.BlockAsync(ImBlockRequest)", c => c.Friend.BlockAsync(new ImBlockRequest("mallory", "spam"))),
                R("friend.block", "Friend.BlockAsync(string, string)", c => c.Friend.BlockAsync("mallory", "abuse")),
                R("friend.unblock", "Friend.UnblockAsync(ImUserIdRequest)", c => c.Friend.UnblockAsync(new ImUserIdRequest("mallory"))),
                R("friend.unblock", "Friend.UnblockAsync(string)", c => c.Friend.UnblockAsync("mallory")),
                R("friend.setRemark", "Friend.SetRemarkAsync", c => c.Friend.SetRemarkAsync(new ImSetRemarkRequest
                {
                    UserId = "bob",
                    Remark = "Bob from work",
                    Tags = Strings("colleague"),
                })),

                // ----------------------------------------------------------------- group
                R("group.create", "Group.CreateAsync", c => c.Group.CreateAsync(new ImCreateGroupRequest
                {
                    GroupId = "team",
                    Name = "Team",
                    Avatar = "https://cdn.test/a.png",
                    Introduction = "the team",
                    Type = ImGroupType.Super,
                    MemberIds = Strings("bob", "carol"),
                    JoinMode = ImGroupJoinMode.NeedApproval,
                    InviteMode = ImGroupInviteMode.AdminsOnly,
                    MaxMemberCount = 500,
                    Extensions = Obj("dept", "eng"),
                })),
                R("group.info", "Group.InfoAsync(ImGroupIdRequest)", c => c.Group.InfoAsync(new ImGroupIdRequest("team"))),
                R("group.info", "Group.InfoAsync(string)", c => c.Group.InfoAsync("team")),
                R("group.update", "Group.UpdateAsync", c => c.Group.UpdateAsync(new ImUpdateGroupCommand("team", new ImUpdateGroupRequest
                {
                    Name = "Team 2",
                    Avatar = "https://cdn.test/b.png",
                    Introduction = "renamed",
                    JoinMode = ImGroupJoinMode.Forbidden,
                    InviteMode = ImGroupInviteMode.Forbidden,
                    MaxMemberCount = 200,
                    Extensions = Obj("dept", "ops"),
                }))),
                R("group.dismiss", "Group.DismissAsync", c => c.Group.DismissAsync(new ImGroupIdRequest("team"))),
                R("group.memberList", "Group.MemberListAsync", c => c.Group.MemberListAsync(new ImGroupCursorRequest { GroupId = "team", Cursor = "m:2", Limit = 40 })),
                R("group.joined", "Group.JoinedAsync(ImCursorRequest)", c => c.Group.JoinedAsync(new ImCursorRequest { Cursor = "j:2", Limit = 25 })),
                R("group.joined", "Group.JoinedAsync()", c => c.Group.JoinedAsync()),
                R("group.invite", "Group.InviteAsync", c => c.Group.InviteAsync(new ImGroupMembersRequest
                {
                    GroupId = "team",
                    UserIds = Strings("dave", "erin"),
                    Reason = "new hires",
                })),
                R("group.kick", "Group.KickAsync", c => c.Group.KickAsync(new ImGroupMembersRequest
                {
                    GroupId = "team",
                    UserIds = Strings("mallory"),
                    Reason = "spam",
                })),
                R("group.quit", "Group.QuitAsync", c => c.Group.QuitAsync(new ImGroupIdRequest("team"))),
                R("group.join", "Group.JoinAsync", c => c.Group.JoinAsync(new ImJoinGroupRequest("team", "let me in"))),
                R("group.transfer", "Group.TransferAsync", c => c.Group.TransferAsync(new ImTransferOwnerRequest("team", "bob"))),
                R("group.applicationList", "Group.ApplicationListAsync(ImGroupCursorRequest)", c => c.Group.ApplicationListAsync(new ImGroupCursorRequest { GroupId = "team", Cursor = "a:2", Limit = 40 })),
                R("group.applicationList", "Group.ApplicationListAsync()", c => c.Group.ApplicationListAsync()),
                R("group.handleApplication", "Group.HandleApplicationAsync", c => c.Group.HandleApplicationAsync(new ImHandleApplicationRequest("team", "dave", true, "welcome"))),
                R("group.setRole", "Group.SetRoleAsync", c => c.Group.SetRoleAsync(new ImSetRoleRequest("team", "bob", ImGroupRole.Admin))),
                R("group.mute", "Group.MuteAsync", c => c.Group.MuteAsync(new ImMuteGroupRequest("team", true, PinnedTime))),
                R("group.muteMember", "Group.MuteMemberAsync", c => c.Group.MuteMemberAsync(new ImMuteMemberRequest("team", "mallory", PinnedTime))),
                R("group.setNickname", "Group.SetNicknameAsync", c => c.Group.SetNicknameAsync(new ImSetGroupNicknameRequest("team", "Al", "alice"))),
                R("group.announcement", "Group.AnnouncementAsync", c => c.Group.AnnouncementAsync(new ImAnnouncementRequest("team", "standup at ten"))),

                // ----------------------------------------------------------------- media
                R("media.uploadTicket", "Media.UploadTicketAsync", c => c.Media.UploadTicketAsync(new ImUploadTicketRequest
                {
                    FileName = "a.png",
                    ContentType = "image/png",
                    Size = 1024,
                })),
                R("media.downloadUrl", "Media.DownloadUrlAsync(ImDownloadUrlRequest)", c => c.Media.DownloadUrlAsync(new ImDownloadUrlRequest { ObjectKey = "demo/alice/a.png", LifetimeSeconds = 600 })),
                R("media.downloadUrl", "Media.DownloadUrlAsync(string)", c => c.Media.DownloadUrlAsync("demo/alice/b.png")),

                // ------------------------------------------------------------ moderation
                R("moderation.report", "Moderation.ReportAsync", c => c.Moderation.ReportAsync(new ImSubmitReportRequest
                {
                    TargetUserId = "mallory",
                    ConversationId = "c_wire",
                    MessageId = Big,
                    Category = ImReportCategory.Spam,
                    Note = "n",
                })),

                // ------------------------------------------------------------------ push
                R("push.register", "Push.RegisterAsync", c => c.Push.RegisterAsync(new ImRegisterPushTokenRequest(ImPushProvider.Fcm, "fcm-token", "zh-CN"))),
                R("push.register", "Push.SetToken while connected", c =>
                {
                    c.Push.SetToken(ImPushProvider.Apns, "apns-token", "en-GB");
                    return Task.CompletedTask;
                }),
                R("push.unregister", "Push.UnregisterAsync()", c => c.Push.UnregisterAsync()),
                WithToken("push.unregister", "ImClient.LogoutAsync, token held", c => c.LogoutAsync()),
                R("push.clicked", "Push.ClickedAsync(ImPushClickedRequest)", c => c.Push.ClickedAsync(new ImPushClickedRequest { PushId = "pu_1", MessageId = Big })),
                R("push.clicked", "Push.ClickedAsync()", c => c.Push.ClickedAsync()),

                // ------------------------------------------------------------------ user
                R("user.me", "User.MeAsync()", c => c.User.MeAsync()),
                R("user.profile", "User.ProfileAsync(ImUserIdRequest)", c => c.User.ProfileAsync(new ImUserIdRequest("bob"))),
                R("user.profile", "User.ProfileAsync(string)", c => c.User.ProfileAsync("carol")),
                R("user.batchProfile", "User.BatchProfileAsync(ImUserIdsRequest)", c => c.User.BatchProfileAsync(new ImUserIdsRequest(new[] { "bob", "carol" }))),
                R("user.batchProfile", "User.BatchProfileAsync(IEnumerable<string>)", c => c.User.BatchProfileAsync(new[] { "dave" })),
                R("user.updateProfile", "User.UpdateProfileAsync", c => c.User.UpdateProfileAsync(new ImUpdateProfileRequest(
                    JsonValue.NewObject().Set("nickname", "Al").Set("gender", 1L)))),
                R("user.presence", "User.PresenceAsync(ImUserIdsRequest)", c => c.User.PresenceAsync(new ImUserIdsRequest(new[] { "bob", "carol" }))),
                R("user.presence", "User.PresenceAsync(IEnumerable<string>)", c => c.User.PresenceAsync(new[] { "dave" })),
                R("user.subscribePresence", "User.SubscribePresenceAsync", c => c.User.SubscribePresenceAsync(new ImSubscribePresenceRequest
                {
                    UserIds = Strings("bob", "carol"),
                    TtlSeconds = 300,
                })),
                R("user.unsubscribePresence", "User.UnsubscribePresenceAsync", c => c.User.UnsubscribePresenceAsync(new ImUserIdsRequest(new[] { "bob" }))),
                R("user.setStatus", "User.SetStatusAsync(ImSetStatusRequest)", c => c.User.SetStatusAsync(new ImSetStatusRequest("in a match"))),
                R("user.setStatus", "User.SetStatusAsync()", c => c.User.SetStatusAsync()),

                // ------------------------------------------- frozen [Obsolete] aliases
                R("msg.send", "ImClient.SendAsync [Obsolete]", c => c.SendAsync(FullSend(ImRecipient.Conversation("c_wire"), "cm-4"))),
                Generated("msg.send", "ImClient.SendTextAsync [Obsolete]", c => c.SendTextAsync(ImRecipient.User("bob"), "hi")),
                R("msg.history", "ImClient.HistoryAsync [Obsolete]", c => c.HistoryAsync("c_wire", 9, 30)),
                R("msg.recall", "ImClient.RecallAsync(string, long) [Obsolete]", c => c.RecallAsync("c_wire", BigValue, "typo")),
                R("msg.react", "ImClient.ReactAsync(string, long) [Obsolete]", c => c.ReactAsync("c_wire", BigValue, "+1", false)),
                R("msg.typing", "ImClient.SetTypingAsync [Obsolete]", c => c.SetTypingAsync("c_wire", true)),
                R("conv.list", "ImClient.ConversationsAsync [Obsolete]", c => c.ConversationsAsync(PinnedTime, "conv:2", 50)),
                R("conv.read", "ImClient.MarkReadAsync [Obsolete]", c => c.MarkReadAsync("c_wire", 44L)),
                R("conv.unreadTotal", "ImClient.TotalUnreadAsync [Obsolete]", c => c.TotalUnreadAsync()),
            };

            return rows;
        }

        /// <summary>The recorder's rows reach exactly the endpoints the inventory says Unity implements.</summary>
        /// <remarks>
        /// A typed method added without a row, or a row left behind for an endpoint Unity no longer
        /// implements, goes red here rather than quietly narrowing what the binder judges.
        /// 新增的类型化方法没有行、或者行指向 Unity 已不实现的端点，都在这里变红。
        /// </remarks>
        [Test]
        public void The_rows_cover_every_endpoint_unity_implements()
        {
            var expected = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                if (endpoint["implementedIn"]["unity"].AsBool()
                    && Array.IndexOf(ShippedTiers, endpoint["tier"].AsString()) >= 0)
                {
                    expected.Add(endpoint["target"].AsString());
                }
            }

            var covered = new SortedSet<string>(StringComparer.Ordinal);
            var vias = new HashSet<string>(StringComparer.Ordinal);
            foreach (var row in Rows())
            {
                covered.Add(row.Target);
                Assert.That(vias.Add(row.Via), Is.True, "two rows share the via " + row.Via);
            }

            Assert.That(covered, Is.EqualTo(expected),
                "every T0-T3 endpoint the inventory marks implementedIn.unity needs a row here, and no row may reach any other");
        }

        /// <summary>Every public method that sends has a row, and every row names a real method.</summary>
        /// <remarks>
        /// The endpoint check above compares targets, so a new overload or alias on a target that
        /// already has a row would add no red there. This one is per method: an overloaded name is
        /// keyed by its parameter list (without the <see cref="CancellationToken"/>), which the
        /// row's <c>via</c> has to spell, e.g. <c>Conv.ReadAsync(string, long)</c>.
        /// 上面那条只比端点；这条逐方法比——同一端点上新增的重载或别名没有行，也在这里变红。
        /// </remarks>
        [Test]
        public void Every_public_method_that_sends_has_a_row()
        {
            var exempt = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in NoRow)
            {
                exempt.Add(entry.Key);
            }

            var keys = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var type in Namespaces)
            {
                AddKeys(keys, exempt, type.Name.Substring(2, type.Name.Length - 5), type, false);
            }

            AddKeys(keys, exempt, "ImClient", typeof(ImClient), true);

            var vias = new List<string>();
            foreach (var row in Rows())
            {
                vias.Add(row.Via);
            }

            var unrowed = new List<string>();
            foreach (var key in keys)
            {
                if (!vias.Exists(via => Names(via, key)))
                {
                    unrowed.Add(key);
                }
            }

            var unknown = new List<string>();
            foreach (var via in vias)
            {
                var named = false;
                foreach (var key in keys)
                {
                    named |= Names(via, key);
                }

                if (!named)
                {
                    unknown.Add(via);
                }
            }

            Assert.That(unrowed, Is.Empty,
                "these public methods have no row, so what they send is never recorded or judged; add a row whose via starts with the name (or list it in NoRow with the reason)");
            Assert.That(unknown, Is.Empty,
                "these rows' via names no public method (an overloaded name needs its parameter list); keys are:\n  " + string.Join("\n  ", keys));
        }

        private static void AddKeys(SortedSet<string> keys, HashSet<string> exempt, string owner, Type type, bool tasksOnly)
        {
            var methods = new List<MethodInfo>();
            foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly))
            {
                if (method.IsSpecialName || exempt.Contains(owner + "." + method.Name))
                {
                    continue; // property and event accessors, and the declared exemptions
                }

                if (tasksOnly && !typeof(Task).IsAssignableFrom(method.ReturnType))
                {
                    continue;
                }

                methods.Add(method);
            }

            foreach (var method in methods)
            {
                var overloads = methods.FindAll(other => other.Name == method.Name).Count;
                var key = owner + "." + method.Name;

                if (overloads > 1)
                {
                    var parts = new List<string>();
                    foreach (var parameter in method.GetParameters())
                    {
                        if (parameter.ParameterType != typeof(CancellationToken))
                        {
                            parts.Add(Spell(parameter.ParameterType));
                        }
                    }

                    key += "(" + string.Join(", ", parts) + ")";
                }

                keys.Add(key);
            }
        }

        /// <summary>
        /// Whether a row's <c>via</c> names the method: the key, then nothing, a space, a comma or —
        /// for a name that is not overloaded — an opening parenthesis.
        /// </summary>
        private static bool Names(string via, string key)
        {
            if (!via.StartsWith(key, StringComparison.Ordinal))
            {
                return false;
            }

            if (via.Length == key.Length)
            {
                return true;
            }

            var next = via[key.Length];
            return next == ' ' || next == ',' || (next == '(' && !key.EndsWith(")", StringComparison.Ordinal));
        }

        /// <summary>A parameter type as C# source spells it.</summary>
        private static string Spell(Type type)
        {
            var underlying = Nullable.GetUnderlyingType(type);
            if (underlying != null)
            {
                return Spell(underlying) + "?";
            }

            if (type.IsArray)
            {
                return Spell(type.GetElementType()) + "[]";
            }

            if (type == typeof(string))
            {
                return "string";
            }

            if (type == typeof(long))
            {
                return "long";
            }

            if (type == typeof(int))
            {
                return "int";
            }

            if (type == typeof(bool))
            {
                return "bool";
            }

            if (type.IsGenericType)
            {
                var arguments = new List<string>();
                foreach (var argument in type.GetGenericArguments())
                {
                    arguments.Add(Spell(argument));
                }

                return type.Name.Substring(0, type.Name.IndexOf('`')) + "<" + string.Join(", ", arguments) + ">";
            }

            return type.Name;
        }

        /// <summary>
        /// Calls every row against a fake socket and records the bodies (<c>IM_RECORD_WIRE_SAMPLES=1</c>)
        /// or compares them with <c>sdk/wire-samples/unity.json</c>.
        /// </summary>
        [Test]
        public void The_recorded_wire_samples_match_what_the_sdk_sends()
        {
            var requestTypes = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                requestTypes[endpoint["target"].AsString()] = endpoint["requestType"].AsString();
            }

            var lines = new List<string>
            {
                "{",
                "  \"$comment\": " + Quote(
                    "RECORDED by SDK/unity/Tests/Runtime/WireSampleRecorderTests.cs from the frames this SDK's typed methods put on a fake socket. "
                    + "Do not edit by hand; re-record with IM_RECORD_WIRE_SAMPLES=1 dotnet IM.Tests.UnitySdk.dll "
                    + "(in IM.Server/tests/IM.Tests.UnitySdk/bin/Debug/net10.0 of the platform repository). "
                    + "The keys inside options, pushConfig, content, patch and extensions are the recorder's own spelling: "
                    + "the SDK passes those JsonValues through verbatim. "
                    + "Judged against the server's real socket binder by IM.Server/tests/IM.Tests.Unit/SdkWireSampleBindingTests.cs in the platform repository.") + ",",
                "  \"sdk\": \"unity\",",
                "  \"omitted\": {",
            };

            for (var i = 0; i < Omitted.Length; i++)
            {
                lines.Add("    " + Quote(Omitted[i].Key) + ": " + Quote(Omitted[i].Value) + (i + 1 < Omitted.Length ? "," : string.Empty));
            }

            lines.Add("  },");
            lines.Add("  \"samples\": [");

            var rows = Rows();
            for (var i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                var body = Capture(row);

                string type;
                requestTypes.TryGetValue(row.Target, out type);

                lines.Add("    {\"target\":" + Quote(row.Target)
                    + ",\"type\":" + (type == null ? "null" : Quote(type))
                    + ",\"via\":" + Quote(row.Via)
                    + ",\"body\":" + body.ToJson() + "}"
                    + (i + 1 < rows.Count ? "," : string.Empty));
            }

            lines.Add("  ]");
            lines.Add("}");

            var text = string.Join("\n", lines) + "\n";
            var path = SampleFile();

            if (Environment.GetEnvironmentVariable(RecordVariable) == "1")
            {
                var ci = Environment.GetEnvironmentVariable("CI");
                Assert.That(string.IsNullOrEmpty(ci) || ci == "false" || ci == "0", Is.True,
                    RecordVariable + "=1 with CI=" + ci + ": record mode asserts nothing about drift, and this "
                    + "comparison is the only drift gate " + path + " has, so CI must compare. Unset "
                    + RecordVariable + ", or record outside CI and commit the file.");

                File.WriteAllText(path, text, new UTF8Encoding(false));
                return;
            }

            Assert.That(File.Exists(path), Is.True,
                path + " is missing; run this suite with " + RecordVariable + "=1 and commit the file");

            var committed = File.ReadAllText(path).Replace("\r\n", "\n").Split('\n');
            var live = text.Split('\n');
            var differences = new List<string>();

            for (var i = 0; i < Math.Max(committed.Length, live.Length) && differences.Count < 12; i++)
            {
                var was = i < committed.Length ? committed[i] : "(no line)";
                var now = i < live.Length ? live[i] : "(no line)";
                if (!string.Equals(was, now, StringComparison.Ordinal))
                {
                    differences.Add("line " + (i + 1) + "\n  committed: " + was + "\n  sent now:  " + now);
                }
            }

            Assert.That(differences, Is.Empty,
                "what the typed methods send has drifted from " + path + ". If the change is intended, re-record with "
                + RecordVariable + "=1 and commit the file; the platform repository then judges the new bodies.\n"
                + string.Join("\n", differences));
        }

        /// <summary>
        /// Issues one row's call on a freshly connected client and returns the body of the first
        /// request it put on the socket for the row's target.
        /// </summary>
        private static JsonValue Capture(Row row)
        {
            using (var harness = new ImTestHarness())
            {
                if (row.Setup != null)
                {
                    row.Setup(harness.Client);
                    harness.Pump();
                }

                harness.Connect();
                var before = harness.Socket.Requests.Count;

                ImTestHarness.Forget(row.Call(harness.Client));
                harness.Pump();

                var requests = harness.Socket.Requests;
                for (var i = before; i < requests.Count; i++)
                {
                    if (string.Equals(requests[i].Target, row.Target, StringComparison.Ordinal))
                    {
                        return Pin(row, JsonValue.Parse(requests[i].Body.ToJson()));
                    }
                }

                Assert.Fail(row.Via + " put no " + row.Target + " request on the socket");
                return null;
            }
        }

        /// <summary>
        /// Replaces the clock and random values with fixed ones, after checking each is the JSON kind
        /// the server's member takes — a pinned value must not hide a kind defect.
        /// </summary>
        private static JsonValue Pin(Row row, JsonValue body)
        {
            if (row.Target != "msg.send")
            {
                return body;
            }

            Assert.That(body["sendTime"].Kind, Is.EqualTo(JsonKind.Number),
                row.Via + ": sendTime is a long on the server; body was " + body.ToJson());
            body.Set("sendTime", PinnedTime);

            if (row.GeneratedClientMsgId)
            {
                Assert.That(body["clientMsgId"].Kind, Is.EqualTo(JsonKind.String),
                    row.Via + ": clientMsgId is a string on the server; body was " + body.ToJson());
                Assert.That(body["clientMsgId"].AsString(), Is.Not.Empty, row.Via + ": clientMsgId");
                body.Set("clientMsgId", PinnedId);
            }

            return body;
        }

        private static string Quote(string value)
        {
            return JsonValue.Of(value).ToJson();
        }

        private static JsonValue Inventory()
        {
            return JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "endpoint-inventory.json")));
        }

        private static string SampleFile()
        {
            return Path.Combine(SdkRoot(), "wire-samples", "unity.json");
        }

        private static string SdkRoot([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);
            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                if (File.Exists(Path.Combine(directory, "endpoint-inventory.json")))
                {
                    return directory;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }
    }
}
