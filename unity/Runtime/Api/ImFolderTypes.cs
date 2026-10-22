using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- the rule
    //
    // conv.folders / conv.upsertFolder / conv.deleteFolder (T4). A folder holds no conversations: it holds
    // tags, and the client filters conv.list with them. Filing a conversation is tagging it
    // (ImConversationSetting.Tags through conv.setting), so a folder can never disagree with the list.
    // Deleting a folder removes a name and nothing else — the conversations keep their tags. Folder changes
    // are not pushed (no evt.*): another device sees them by calling conv.folders again.
    //
    // 文件夹不装会话，它装标签，客户端用这些标签过滤 conv.list；归档就是给会话打标签（conv.setting 的 tags）。
    // 删文件夹只删一个名字，会话的标签不动。文件夹的变化没有推送，其他设备要重新调 conv.folders。

    /// <summary>
    /// <c>conv.upsertFolder</c>: creates a folder, or replaces the one with <see cref="FolderId"/>. Every
    /// member is written — the call replaces the whole folder, it does not patch it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Rules, from the server: <see cref="Name"/> is required and non-blank, at most 64 characters (longer
    /// is cut); <see cref="FolderId"/>, when given, is 1–64 letters, digits, <c>-</c>, <c>_</c> or <c>.</c>;
    /// at most 16 <see cref="Tags"/> of at most 64 characters, and <b>every tag must already be on one of
    /// the caller's conversations</b> — set it with <c>conv.setting</c> first. Each of those is <c>1001</c>.
    /// At most 20 folders per user (<c>1006</c>). <see cref="Order"/> below 0 is stored as 0; an empty
    /// <see cref="Types"/> is stored as "every kind" and read back as null.
    /// </para>
    /// <para>
    /// <b>Creating is not idempotent</b>: with <see cref="FolderId"/> null the server allocates an id, so a
    /// retry whose first reply was lost makes a second folder. Choose the id yourself to make a save safe to
    /// repeat.
    /// </para>
    /// <para>
    /// 整份替换而不是补丁。name 必填、≤64；folderId 若给出须是 1–64 位字母数字或 - _ .；tags ≤16 个、每个 ≤64，
    /// 且每个都必须已经出现在调用者的某个会话上（先用 conv.setting 打标签），否则 1001；每人至多 20 个文件夹（1006）。
    /// 不带 folderId 新建不幂等：重试会多出一个，要可重复保存就自己定 id。
    /// </para>
    /// </remarks>
    public sealed class ImUpsertFolderRequest : IImRequest
    {
        /// <summary>Null or empty creates a folder with a server-chosen id; an id creates or replaces that folder.</summary>
        public string FolderId { get; set; }

        /// <summary>The folder's name. Required, non-blank, at most 64 characters.</summary>
        public string Name { get; set; }

        /// <summary>Display order; clients sort by this, then by name. Below 0 is stored as 0.</summary>
        public int Order { get; set; }

        /// <summary>The conversation tags this folder gathers. Each must already be on one of the caller's conversations. Null sends none.</summary>
        public List<string> Tags { get; set; }

        /// <summary>Show only conversations with unread messages.</summary>
        public bool UnreadOnly { get; set; }

        /// <summary>Conversation kinds the folder shows, each sent as its integer. Null (not sent) or empty means every kind.</summary>
        public List<ImConversationType> Types { get; set; }

        /// <inheritdoc cref="ImUpsertFolderRequest"/>
        public ImUpsertFolderRequest()
        {
            Tags = new List<string>();
        }

        /// <inheritdoc cref="ImUpsertFolderRequest"/>
        public ImUpsertFolderRequest(string name, params string[] tags)
        {
            Name = name;
            Tags = new List<string>(tags ?? new string[0]);
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("folderId", string.IsNullOrEmpty(FolderId) ? null : FolderId)
                .Set("name", Name)
                .Set("order", (long)Order)
                .Set("tags", ImJsonArrays.OfStrings(Tags))
                .Set("unreadOnly", UnreadOnly);

            if (Types != null)
            {
                var types = JsonValue.NewArray();
                foreach (var type in Types)
                {
                    types.Add(JsonValue.Of((long)type));
                }

                body.Set("types", types);
            }

            return body;
        }
    }

    /// <summary>Body of <c>conv.deleteFolder</c>. An unknown id is <c>1002</c>.</summary>
    public sealed class ImFolderIdRequest : IImRequest
    {
        /// <summary><see cref="ImConversationFolder.FolderId"/>. Required.</summary>
        public string FolderId { get; set; }

        /// <inheritdoc cref="ImFolderIdRequest"/>
        public ImFolderIdRequest()
        {
        }

        /// <inheritdoc cref="ImFolderIdRequest"/>
        public ImFolderIdRequest(string folderId)
        {
            FolderId = folderId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("folderId", FolderId);
        }
    }

    /// <summary>
    /// One folder, as <c>conv.folders</c> lists it and <c>conv.upsertFolder</c> answers it (normalised: tags
    /// trimmed and de-duplicated, the name cut to 64, a negative order raised to 0).
    /// </summary>
    public sealed class ImConversationFolder : IImJsonPayload
    {
        /// <summary>The folder's id.</summary>
        public string FolderId { get; private set; }

        /// <summary>Its name.</summary>
        public string Name { get; private set; }

        /// <summary>Display order; sort by this, then by <see cref="Name"/>.</summary>
        public int Order { get; private set; }

        /// <summary>The conversation tags it gathers. Never null.</summary>
        public List<string> Tags { get; private set; }

        /// <summary>Show only conversations with unread messages.</summary>
        public bool UnreadOnly { get; private set; }

        /// <summary>
        /// Conversation kinds it shows; <b>null means every kind</b> (the server omits the member then, and
        /// never sends an empty list).
        /// </summary>
        public List<ImConversationType> Types { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            FolderId = json["folderId"].AsString(string.Empty);
            Name = json["name"].AsString(string.Empty);
            Order = json["order"].AsInt();
            Tags = json["tags"].AsStringList();
            UnreadOnly = json["unreadOnly"].AsBool();

            var types = json["types"];
            if (types.IsArray && types.Count > 0)
            {
                Types = new List<ImConversationType>(types.Count);
                foreach (var type in types.Items)
                {
                    Types.Add((ImConversationType)type.AsInt());
                }
            }
            else
            {
                Types = null;
            }
        }
    }
}
