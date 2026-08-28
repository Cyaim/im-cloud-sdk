using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// A payload the SDK can decode by itself, which is what lets
    /// <see cref="ImClient.InvokeAsync{T}(string,JsonValue,System.Threading.CancellationToken)"/>
    /// be generic without reflection.
    /// </summary>
    /// <remarks>
    /// Reflection is the obvious way to do this and is the wrong one here: an IL2CPP build with
    /// managed stripping removes the members a reflective mapper would look for, and the failure
    /// shows up only in a player build. Every payload maps itself, explicitly, so stripping at any
    /// level is safe — the same reason <c>Runtime/Json</c> exists at all.
    /// </remarks>
    public interface IImJsonPayload
    {
        /// <summary>Fills this instance from a payload. Absent members leave defaults in place.</summary>
        void ReadFrom(JsonValue json);
    }

    // ---------------------------------------------------------------------- enums
    //
    // Plain C# enums are already "open" in the sense CONTRACT §4.5 requires: casting an int the
    // build has never heard of produces a value that keeps its raw number and round-trips, rather
    // than throwing or collapsing to a default member. That is why every mapper below casts rather
    // than switching, and why a server that ships a new content type does not need an SDK release.

    /// <summary>Group kind.</summary>
    public enum ImGroupType
    {
        /// <summary>Ordinary group with a member roster.</summary>
        Normal = 1,

        /// <summary>Super group: tens of thousands of members, roster paged, no presence fan-out.</summary>
        Super = 2,

        /// <summary>Chat room: no roster, best-effort delivery, seq 0.</summary>
        ChatRoom = 3,
    }

    /// <summary>A member's authority inside a group.</summary>
    public enum ImGroupRole
    {
        /// <summary>Ordinary member.</summary>
        Member = 1,

        /// <summary>Can moderate, cannot dismiss or transfer.</summary>
        Admin = 2,

        /// <summary>Exactly one per group.</summary>
        Owner = 3,
    }

    /// <summary>How a stranger gets into a group.</summary>
    public enum ImGroupJoinMode
    {
        /// <summary>Anyone with the id may join.</summary>
        FreeAccess = 0,

        /// <summary>Joining raises an application an admin handles.</summary>
        NeedApproval = 1,

        /// <summary>Nobody may join themselves; invitation only.</summary>
        Forbidden = 2,
    }

    /// <summary>Who may bring someone into a group.</summary>
    public enum ImGroupInviteMode
    {
        /// <summary>Any member.</summary>
        AllMembers = 0,

        /// <summary>Admins and the owner.</summary>
        AdminsOnly = 1,

        /// <summary>Nobody; membership is managed from the tenant backend.</summary>
        Forbidden = 2,
    }

    /// <summary>Per-conversation do-not-disturb level.</summary>
    public enum ImMuteMode
    {
        /// <summary>Notify normally.</summary>
        Normal = 0,

        /// <summary>Count unread, send no push.</summary>
        NoPush = 1,

        /// <summary>No push and no unread badge.</summary>
        Silent = 2,
    }

    /// <summary>State of a friend or group application.</summary>
    public enum ImApplicationStatus
    {
        /// <summary>Waiting for a decision.</summary>
        Pending = 0,

        /// <summary>Accepted.</summary>
        Accepted = 1,

        /// <summary>Refused.</summary>
        Rejected = 2,

        /// <summary>Nobody answered within the window.</summary>
        Expired = 3,
    }

    /// <summary>Server-side delivery state of a message.</summary>
    public enum ImMessageStatus
    {
        /// <summary>Accepted, not yet persisted.</summary>
        Sending = 0,

        /// <summary>Persisted and given a seq.</summary>
        Sent = 1,

        /// <summary>Handed to at least one live device.</summary>
        Delivered = 2,

        /// <summary>Receipted by the recipient.</summary>
        Read = 3,

        /// <summary>Rejected or undeliverable.</summary>
        Failed = 4,
    }

    /// <summary>Delivery priority, used when a connection is behind and something has to go.</summary>
    public enum ImMessagePriority
    {
        /// <summary>Dropped first under pressure.</summary>
        Low = 0,

        /// <summary>The default.</summary>
        Normal = 1,

        /// <summary>Kept longest.</summary>
        High = 2,
    }

    // ---------------------------------------------------------------------- payloads

    /// <summary>A user, as the platform stores them.</summary>
    public sealed class ImUserProfile : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Stable user id, chosen by the tenant.</summary>
        public string UserId { get; internal set; }

        /// <summary>Display name, or null when never set.</summary>
        public string Nickname { get; internal set; }

        /// <summary>Avatar object key or URL, or null.</summary>
        public string Avatar { get; internal set; }

        /// <summary>Tenant-defined; 0 when unspecified.</summary>
        public int Gender { get; internal set; }

        /// <summary>ISO date, or null.</summary>
        public string Birthday { get; internal set; }

        /// <summary>Free-text status line, or null.</summary>
        public string Signature { get; internal set; }

        /// <summary>Hashed phone number when the tenant stores one. Never the number itself.</summary>
        public string PhoneHash { get; internal set; }

        /// <summary>Hashed email when the tenant stores one.</summary>
        public string EmailHash { get; internal set; }

        /// <summary>Unix ms until which this user may not send, or null.</summary>
        public long? SilencedUntil { get; internal set; }

        /// <summary>True when the account is banned.</summary>
        public bool Banned { get; internal set; }

        /// <summary>Creation time, unix ms.</summary>
        public long CreatedAt { get; internal set; }

        /// <summary>Last change, unix ms.</summary>
        public long UpdatedAt { get; internal set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            UserId = json["userId"].AsString(string.Empty);
            Nickname = json["nickname"].AsString();
            Avatar = json["avatar"].AsString();
            Gender = json["gender"].AsInt();
            Birthday = json["birthday"].AsString();
            Signature = json["signature"].AsString();
            PhoneHash = json["phoneHash"].AsString();
            EmailHash = json["emailHash"].AsString();
            SilencedUntil = json.Has("silencedUntil") && !json["silencedUntil"].IsNull
                ? json["silencedUntil"].AsLong()
                : (long?)null;
            Banned = json["banned"].AsBool();
            CreatedAt = json["createdAt"].AsLong();
            UpdatedAt = json["updatedAt"].AsLong();
            Extensions = json["extensions"];
        }

        /// <summary>Maps a profile out of a payload.</summary>
        public static ImUserProfile FromJson(JsonValue json)
        {
            return ImPayload.Read<ImUserProfile>(json);
        }
    }

    /// <summary>Whether a user is online, and from where.</summary>
    public sealed class ImPresenceState : IImJsonPayload
    {
        /// <summary>Who this is about.</summary>
        public string UserId { get; internal set; }

        /// <summary>True when at least one device is connected.</summary>
        public bool Online { get; internal set; }

        /// <summary>Platforms currently holding a socket. Never null.</summary>
        public List<ImPlatform> Platforms { get; internal set; }

        /// <summary>Unix ms of the last disconnect, 0 when never seen.</summary>
        public long LastSeen { get; internal set; }

        /// <summary>Free-text status the user set, or null.</summary>
        public string CustomStatus { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            UserId = json["userId"].AsString(string.Empty);
            Online = json["online"].AsBool();
            LastSeen = json["lastSeen"].AsLong();
            CustomStatus = json["customStatus"].AsString();

            Platforms = new List<ImPlatform>(json["platforms"].Count);
            foreach (var item in json["platforms"].Items)
            {
                Platforms.Add((ImPlatform)item.AsInt());
            }
        }

        /// <summary>Maps a presence state out of a payload.</summary>
        public static ImPresenceState FromJson(JsonValue json)
        {
            return ImPayload.Read<ImPresenceState>(json);
        }
    }

    /// <summary>
    /// A short-lived permit to upload one file straight to object storage.
    /// </summary>
    /// <remarks>
    /// Bytes never pass through the gateway. PUT the file to <see cref="UploadUrl"/> yourself with
    /// <c>UnityWebRequest.Put</c>, then send a message whose <c>content.url</c> is
    /// <see cref="ObjectKey"/> — not <see cref="DownloadUrl"/>. Messages carry keys, and every
    /// reader signs their own link, which is the only thing that makes expiry and revocation
    /// possible; a URL baked into a message is public forever the moment it leaks.
    /// </remarks>
    public sealed class ImMediaUploadTicket : IImJsonPayload
    {
        /// <summary>Storage key the server allocated. This is what goes in the message.</summary>
        public string ObjectKey { get; internal set; }

        /// <summary>Presigned URL to PUT the bytes to.</summary>
        public string UploadUrl { get; internal set; }

        /// <summary>A download URL for the object, already signed for the uploader.</summary>
        public string DownloadUrl { get; internal set; }

        /// <summary>Extra form fields some providers require on the upload. Null when there are none.</summary>
        public Dictionary<string, string> FormFields { get; internal set; }

        /// <summary>Unix ms after which <see cref="UploadUrl"/> stops working.</summary>
        public long ExpiresAt { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            ObjectKey = json["objectKey"].AsString(string.Empty);
            UploadUrl = json["uploadUrl"].AsString(string.Empty);
            DownloadUrl = json["downloadUrl"].AsString(string.Empty);
            ExpiresAt = json["expiresAt"].AsLong();

            var fields = json["formFields"];
            if (fields.IsObject && fields.Count > 0)
            {
                FormFields = new Dictionary<string, string>(fields.Count);
                foreach (var member in fields.Members)
                {
                    FormFields[member.Key] = member.Value.AsString(string.Empty);
                }
            }
        }

        /// <summary>Maps a ticket out of a payload.</summary>
        public static ImMediaUploadTicket FromJson(JsonValue json)
        {
            return ImPayload.Read<ImMediaUploadTicket>(json);
        }
    }

    /// <summary>What a heartbeat comes back with.</summary>
    public sealed class ImHeartbeatResult : IImJsonPayload
    {
        /// <summary>Authoritative server clock in unix ms.</summary>
        public long ServerTime { get; internal set; }

        /// <summary>How often to beat, in seconds. The server owns this; the SDK obeys it.</summary>
        public int IntervalSeconds { get; internal set; }

        /// <summary>True when this beat rebuilt a routing entry that had gone missing.</summary>
        public bool Healed { get; internal set; }

        /// <summary>This socket's cluster-unique id. Worth quoting in a support ticket.</summary>
        public string ConnectionId { get; internal set; }

        /// <summary>The gateway node holding this socket.</summary>
        public string NodeId { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            ServerTime = json["serverTime"].AsLong();
            IntervalSeconds = json["intervalSeconds"].AsInt();
            Healed = json["healed"].AsBool();
            ConnectionId = json["connectionId"].AsString(string.Empty);
            NodeId = json["nodeId"].AsString(string.Empty);
        }

        /// <summary>Maps a heartbeat result out of a payload.</summary>
        public static ImHeartbeatResult FromJson(JsonValue json)
        {
            return ImPayload.Read<ImHeartbeatResult>(json);
        }
    }

    /// <summary>One window of a conversation's history, as <c>msg.sync</c> returns it.</summary>
    /// <remarks>
    /// <see cref="HasMore"/> is computed on the raw window <i>before</i> messages hidden from this
    /// user are filtered out, so <see cref="Messages"/> can be shorter than the requested limit —
    /// even empty — while <see cref="HasMore"/> is true. Loop on <see cref="HasMore"/>, never on
    /// the message count; the SDK's own repair loop does the same, for the same reason.
    /// </remarks>
    public sealed class ImSyncResult : IImJsonPayload
    {
        /// <summary>Conversation this window belongs to.</summary>
        public string ConversationId { get; internal set; }

        /// <summary>The messages, in the order the server returned them. Never null.</summary>
        public List<ImMessage> Messages { get; internal set; }

        /// <summary>Highest seq the server holds for this conversation.</summary>
        public long MaxSeq { get; internal set; }

        /// <summary>Lowest seq this user is allowed to read back to.</summary>
        public long MinSeq { get; internal set; }

        /// <summary>True when the requested range was not exhausted.</summary>
        public bool HasMore { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            ConversationId = json["conversationId"].AsString(string.Empty);
            MaxSeq = json["maxSeq"].AsLong();
            MinSeq = json["minSeq"].AsLong();
            HasMore = json["hasMore"].AsBool();

            Messages = new List<ImMessage>(json["messages"].Count);
            foreach (var item in json["messages"].Items)
            {
                Messages.Add(ImMessage.FromJson(item));
            }
        }

        /// <summary>Maps a sync result out of a payload.</summary>
        public static ImSyncResult FromJson(JsonValue json)
        {
            return ImPayload.Read<ImSyncResult>(json);
        }
    }

    /// <summary>One page of what changed while this device was away, as <c>conn.sync</c> returns it.</summary>
    public sealed class ImResumeResult : IImJsonPayload
    {
        /// <summary>Conversations whose state moved, newest first. Never null.</summary>
        public List<ImConversationView> Conversations { get; internal set; }

        /// <summary>Cursor for the next page; null when exhausted.</summary>
        public string NextCursor { get; internal set; }

        /// <summary>True when another page exists. This — not the item count — ends the loop.</summary>
        public bool HasMore { get; internal set; }

        /// <summary>conversationId to the first seq this device is missing. Never null.</summary>
        public Dictionary<string, long> GapsFrom { get; internal set; }

        /// <summary>Server clock in unix ms.</summary>
        public long ServerTime { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            NextCursor = json["nextCursor"].AsString();
            HasMore = json["hasMore"].AsBool();
            ServerTime = json["serverTime"].AsLong();

            Conversations = new List<ImConversationView>(json["conversations"].Count);
            foreach (var item in json["conversations"].Items)
            {
                Conversations.Add(ImConversationView.FromJson(item));
            }

            GapsFrom = new Dictionary<string, long>(System.StringComparer.Ordinal);
            foreach (var member in json["gapsFrom"].Members)
            {
                GapsFrom[member.Key] = member.Value.AsLong();
            }
        }

        /// <summary>Maps a resume result out of a payload.</summary>
        public static ImResumeResult FromJson(JsonValue json)
        {
            return ImPayload.Read<ImResumeResult>(json);
        }
    }

    /// <summary>A group, as the platform stores it.</summary>
    public sealed class ImGroup : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Group id.</summary>
        public string GroupId { get; internal set; }

        /// <summary>Normal, super, or chat room.</summary>
        public ImGroupType Type { get; internal set; }

        /// <summary>Display name.</summary>
        public string Name { get; internal set; }

        /// <summary>Avatar object key or URL, or null.</summary>
        public string Avatar { get; internal set; }

        /// <summary>Description shown before joining, or null.</summary>
        public string Introduction { get; internal set; }

        /// <summary>Current announcement, or null.</summary>
        public string Announcement { get; internal set; }

        /// <summary>When the announcement last changed, unix ms, or null.</summary>
        public long? AnnouncementUpdatedAt { get; internal set; }

        /// <summary>Exactly one owner.</summary>
        public string OwnerId { get; internal set; }

        /// <summary>Members right now.</summary>
        public int MemberCount { get; internal set; }

        /// <summary>Ceiling for this group.</summary>
        public int MaxMemberCount { get; internal set; }

        /// <summary>How a stranger gets in.</summary>
        public ImGroupJoinMode JoinMode { get; internal set; }

        /// <summary>Who may invite.</summary>
        public ImGroupInviteMode InviteMode { get; internal set; }

        /// <summary>True when the whole group is muted.</summary>
        public bool MuteAll { get; internal set; }

        /// <summary>Unix ms the group-wide mute lifts, or null.</summary>
        public long? MuteEndTime { get; internal set; }

        /// <summary>True once dismissed; it will not come back.</summary>
        public bool Dismissed { get; internal set; }

        /// <summary>Creation time, unix ms.</summary>
        public long CreatedAt { get; internal set; }

        /// <summary>Last change, unix ms.</summary>
        public long UpdatedAt { get; internal set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            GroupId = json["groupId"].AsString(string.Empty);
            Type = (ImGroupType)json["type"].AsInt();
            Name = json["name"].AsString(string.Empty);
            Avatar = json["avatar"].AsString();
            Introduction = json["introduction"].AsString();
            Announcement = json["announcement"].AsString();
            AnnouncementUpdatedAt = ImPayload.OptionalLong(json, "announcementUpdatedAt");
            OwnerId = json["ownerId"].AsString(string.Empty);
            MemberCount = json["memberCount"].AsInt();
            MaxMemberCount = json["maxMemberCount"].AsInt();
            JoinMode = (ImGroupJoinMode)json["joinMode"].AsInt();
            InviteMode = (ImGroupInviteMode)json["inviteMode"].AsInt();
            MuteAll = json["muteAll"].AsBool();
            MuteEndTime = ImPayload.OptionalLong(json, "muteEndTime");
            Dismissed = json["dismissed"].AsBool();
            CreatedAt = json["createdAt"].AsLong();
            UpdatedAt = json["updatedAt"].AsLong();
            Extensions = json["extensions"];
        }

        /// <summary>Maps a group out of a payload.</summary>
        public static ImGroup FromJson(JsonValue json)
        {
            return ImPayload.Read<ImGroup>(json);
        }
    }

    /// <summary>One row of a group's member list.</summary>
    public sealed class ImGroupMember : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Group this membership is in.</summary>
        public string GroupId { get; internal set; }

        /// <summary>The member.</summary>
        public string UserId { get; internal set; }

        /// <summary>Member, admin, or owner.</summary>
        public ImGroupRole Role { get; internal set; }

        /// <summary>Per-group display name, or null to fall back to the profile.</summary>
        public string Nickname { get; internal set; }

        /// <summary>Unix ms this member's mute lifts, or null.</summary>
        public long? MuteEndTime { get; internal set; }

        /// <summary>When they joined, unix ms.</summary>
        public long JoinTime { get; internal set; }

        /// <summary>How they got in — invite, search, link — or null.</summary>
        public string JoinSource { get; internal set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            GroupId = json["groupId"].AsString(string.Empty);
            UserId = json["userId"].AsString(string.Empty);
            Role = (ImGroupRole)json["role"].AsInt();
            Nickname = json["nickname"].AsString();
            MuteEndTime = ImPayload.OptionalLong(json, "muteEndTime");
            JoinTime = json["joinTime"].AsLong();
            JoinSource = json["joinSource"].AsString();
            Extensions = json["extensions"];
        }

        /// <summary>Maps a group member out of a payload.</summary>
        public static ImGroupMember FromJson(JsonValue json)
        {
            return ImPayload.Read<ImGroupMember>(json);
        }
    }

    /// <summary>One row of the caller's friend list.</summary>
    public sealed class ImFriend : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Whose list this row is on.</summary>
        public string UserId { get; internal set; }

        /// <summary>The friend.</summary>
        public string FriendUserId { get; internal set; }

        /// <summary>Private name the owner gave them, or null.</summary>
        public string Remark { get; internal set; }

        /// <summary>Owner-defined grouping tags. Never null.</summary>
        public List<string> Tags { get; internal set; }

        /// <summary>How the relationship started, or null.</summary>
        public string Source { get; internal set; }

        /// <summary>When it started, unix ms.</summary>
        public long AddTime { get; internal set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            UserId = json["userId"].AsString(string.Empty);
            FriendUserId = json["friendUserId"].AsString(string.Empty);
            Remark = json["remark"].AsString();
            Tags = json["tags"].AsStringList();
            Source = json["source"].AsString();
            AddTime = json["addTime"].AsLong();
            Extensions = json["extensions"];
        }

        /// <summary>Maps a friend out of a payload.</summary>
        public static ImFriend FromJson(JsonValue json)
        {
            return ImPayload.Read<ImFriend>(json);
        }
    }

    /// <summary>A pending or handled friend application.</summary>
    public sealed class ImFriendRequest : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Who asked.</summary>
        public string FromUserId { get; internal set; }

        /// <summary>Who was asked.</summary>
        public string ToUserId { get; internal set; }

        /// <summary>Message attached to the request, or null.</summary>
        public string Greeting { get; internal set; }

        /// <summary>Where the request came from — search, card, QR — or null.</summary>
        public string Source { get; internal set; }

        /// <summary>Pending, accepted, rejected, expired.</summary>
        public ImApplicationStatus Status { get; internal set; }

        /// <summary>Reason given when it was handled, or null.</summary>
        public string HandleReason { get; internal set; }

        /// <summary>When it was raised, unix ms.</summary>
        public long CreatedAt { get; internal set; }

        /// <summary>When it was handled, unix ms, or null while pending.</summary>
        public long? HandledAt { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            FromUserId = json["fromUserId"].AsString(string.Empty);
            ToUserId = json["toUserId"].AsString(string.Empty);
            Greeting = json["greeting"].AsString();
            Source = json["source"].AsString();
            Status = (ImApplicationStatus)json["status"].AsInt();
            HandleReason = json["handleReason"].AsString();
            CreatedAt = json["createdAt"].AsLong();
            HandledAt = ImPayload.OptionalLong(json, "handledAt");
        }

        /// <summary>Maps a friend request out of a payload.</summary>
        public static ImFriendRequest FromJson(JsonValue json)
        {
            return ImPayload.Read<ImFriendRequest>(json);
        }
    }

    /// <summary>One row of the caller's blocklist.</summary>
    public sealed class ImBlockEntry : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; internal set; }

        /// <summary>Whose blocklist this row is on.</summary>
        public string UserId { get; internal set; }

        /// <summary>Who is blocked.</summary>
        public string BlockedUserId { get; internal set; }

        /// <summary>When, unix ms.</summary>
        public long CreatedAt { get; internal set; }

        /// <summary>Reason recorded at block time, or null.</summary>
        public string Reason { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            UserId = json["userId"].AsString(string.Empty);
            BlockedUserId = json["blockedUserId"].AsString(string.Empty);
            CreatedAt = json["createdAt"].AsLong();
            Reason = json["reason"].AsString();
        }

        /// <summary>Maps a block entry out of a payload.</summary>
        public static ImBlockEntry FromJson(JsonValue json)
        {
            return ImPayload.Read<ImBlockEntry>(json);
        }
    }

    /// <summary>Decoding helpers shared by the payload types and by <c>InvokeAsync&lt;T&gt;</c>.</summary>
    public static class ImPayload
    {
        /// <summary>Builds one payload of type <typeparamref name="T"/> from a JSON node.</summary>
        public static T Read<T>(JsonValue json) where T : IImJsonPayload, new()
        {
            var value = new T();
            value.ReadFrom(json ?? JsonValue.Null);
            return value;
        }

        /// <summary>Builds a list of payloads from a JSON array. A non-array yields an empty list.</summary>
        public static List<T> ReadList<T>(JsonValue json) where T : IImJsonPayload, new()
        {
            var items = new List<T>(json != null ? json.Count : 0);
            if (json == null)
            {
                return items;
            }

            foreach (var item in json.Items)
            {
                items.Add(Read<T>(item));
            }

            return items;
        }

        /// <summary>
        /// Reads a nullable integer, keeping "absent" and "zero" distinct. The distinction is not
        /// pedantry: a <c>muteEndTime</c> of 0 means "the mute ended at the epoch", and treating an
        /// absent one as 0 would silently unmute.
        /// </summary>
        public static long? OptionalLong(JsonValue json, string name)
        {
            var member = json[name];
            return member.IsNull ? (long?)null : member.AsLong();
        }
    }
}
