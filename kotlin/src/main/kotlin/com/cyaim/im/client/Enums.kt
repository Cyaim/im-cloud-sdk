package com.cyaim.im.client

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable

/*
 * Every enumeration that crosses the wire.
 *
 * All of them are **open**: a value class over the server's integer with named members, not a
 * Kotlin `enum class`. The distinction is not stylistic. The gateway ships new content types,
 * new group roles and new mute modes on its own release train, months ahead of the app on a
 * user's phone. A closed enum has two options when it meets a number it does not know — throw,
 * which takes the whole conversation down, or fold it into `Unknown`, which throws away the one
 * piece of information the support ticket needed: *which* number. An open enum keeps the raw
 * value, compares equal to nothing it knows, and round-trips it back unchanged.
 *
 * 所有枚举都是"开放"的：值类包装服务端整数，而不是 Kotlin enum。网关会先于手机上的 App
 * 数月发布新的内容类型/角色/免打扰模式；封闭枚举遇到不认识的数字只能抛异常（拖垮整个会话）
 * 或折叠成 Unknown（丢掉工单唯一需要的那个数字）。开放枚举原样保留它，也能原样发回去。
 *
 * `when` over one of these therefore needs an `else` branch. That is the point: the branch you
 * are being forced to write is the one that handles a server newer than your build.
 */

/** Renders a known member by name and an unknown one as `Type(42)`, so a log line stays readable. */
internal fun openEnumName(type: String, code: Int, names: Map<Int, String>): String =
    names[code] ?: "$type($code)"

// --------------------------------------------------------------------------- connection

@JvmInline
@Serializable(with = PlatformSerializer::class)
public value class Platform(public val code: Int) {
    override fun toString(): String = openEnumName("Platform", code, NAMES)

    public companion object {
        public val Unknown: Platform = Platform(0)
        public val IOS: Platform = Platform(1)
        public val Android: Platform = Platform(2)
        public val Windows: Platform = Platform(3)
        public val MacOS: Platform = Platform(4)
        public val Web: Platform = Platform(5)
        public val MiniProgram: Platform = Platform(6)
        public val Linux: Platform = Platform(7)

        /** Reserved for the tenant's own backend; a client SDK never sends it. */
        public val Server: Platform = Platform(100)

        public fun fromCode(code: Int): Platform = Platform(code)

        private val NAMES = mapOf(
            0 to "Unknown", 1 to "iOS", 2 to "Android", 3 to "Windows",
            4 to "macOS", 5 to "Web", 6 to "MiniProgram", 7 to "Linux", 100 to "Server",
        )
    }
}

public object PlatformSerializer : KSerializer<Platform> by IntCodeSerializer<Platform>(
    "Platform",
    { it.code },
    { Platform(it) },
)

@JvmInline
@Serializable(with = MultiLoginPolicySerializer::class)
public value class MultiLoginPolicy(public val code: Int) {
    override fun toString(): String = openEnumName("MultiLoginPolicy", code, NAMES)

    public companion object {
        public val AllowAll: MultiLoginPolicy = MultiLoginPolicy(0)
        public val OnePerPlatform: MultiLoginPolicy = MultiLoginPolicy(1)
        public val OneMobileOneDesktopOneWeb: MultiLoginPolicy = MultiLoginPolicy(2)
        public val SingleDevice: MultiLoginPolicy = MultiLoginPolicy(3)

        private val NAMES = mapOf(
            0 to "AllowAll", 1 to "OnePerPlatform",
            2 to "OneMobileOneDesktopOneWeb", 3 to "SingleDevice",
        )
    }
}

public object MultiLoginPolicySerializer : KSerializer<MultiLoginPolicy> by IntCodeSerializer<MultiLoginPolicy>(
    "MultiLoginPolicy",
    { it.code },
    { MultiLoginPolicy(it) },
)

// ------------------------------------------------------------------------ conversations

@JvmInline
@Serializable(with = ConversationTypeSerializer::class)
public value class ConversationType(public val code: Int) {
    override fun toString(): String = openEnumName("ConversationType", code, NAMES)

    public companion object {
        /** Not a server value: what an absent or unrecognised `type` decodes to. */
        public val Unknown: ConversationType = ConversationType(0)
        public val Single: ConversationType = ConversationType(1)
        public val Group: ConversationType = ConversationType(2)
        public val ChatRoom: ConversationType = ConversationType(3)
        public val System: ConversationType = ConversationType(4)
        public val Assistant: ConversationType = ConversationType(5)

        public fun fromCode(code: Int): ConversationType = ConversationType(code)

        private val NAMES = mapOf(
            0 to "Unknown", 1 to "Single", 2 to "Group",
            3 to "ChatRoom", 4 to "System", 5 to "Assistant",
        )
    }
}

public object ConversationTypeSerializer : KSerializer<ConversationType> by IntCodeSerializer<ConversationType>(
    "ConversationType",
    { it.code },
    { ConversationType(it) },
)

/** Do-not-disturb level on one conversation. `Normal` is 0, so absent means "notify". */
@JvmInline
@Serializable(with = MuteModeSerializer::class)
public value class MuteMode(public val code: Int) {
    override fun toString(): String = openEnumName("MuteMode", code, NAMES)

    public companion object {
        public val Normal: MuteMode = MuteMode(0)

        /** Stays in the list and still counts unread; no notification is pushed. */
        public val NoPush: MuteMode = MuteMode(1)

        /** No notification and no unread badge. */
        public val Silent: MuteMode = MuteMode(2)

        private val NAMES = mapOf(0 to "Normal", 1 to "NoPush", 2 to "Silent")
    }
}

public object MuteModeSerializer : KSerializer<MuteMode> by IntCodeSerializer<MuteMode>(
    "MuteMode",
    { it.code },
    { MuteMode(it) },
)

// ----------------------------------------------------------------------------- messages

@JvmInline
@Serializable(with = MessageContentTypeSerializer::class)
public value class MessageContentType(public val code: Int) {
    override fun toString(): String = openEnumName("MessageContentType", code, NAMES)

    public companion object {
        /** Not a server value: what an absent `contentType` decodes to. */
        public val Unknown: MessageContentType = MessageContentType(0)
        public val Text: MessageContentType = MessageContentType(1)
        public val Image: MessageContentType = MessageContentType(2)
        public val Voice: MessageContentType = MessageContentType(3)
        public val Video: MessageContentType = MessageContentType(4)
        public val File: MessageContentType = MessageContentType(5)
        public val Location: MessageContentType = MessageContentType(6)
        public val Card: MessageContentType = MessageContentType(7)
        public val Merged: MessageContentType = MessageContentType(8)
        public val Notification: MessageContentType = MessageContentType(9)
        public val Tip: MessageContentType = MessageContentType(10)
        public val Recall: MessageContentType = MessageContentType(11)
        public val Stream: MessageContentType = MessageContentType(12)

        /** 100 and above is the tenant's own space; `content` is whatever the tenant put there. */
        public val Custom: MessageContentType = MessageContentType(100)

        public fun fromCode(code: Int): MessageContentType = MessageContentType(code)

        private val NAMES = mapOf(
            0 to "Unknown", 1 to "Text", 2 to "Image", 3 to "Voice", 4 to "Video",
            5 to "File", 6 to "Location", 7 to "Card", 8 to "Merged", 9 to "Notification",
            10 to "Tip", 11 to "Recall", 12 to "Stream", 100 to "Custom",
        )
    }
}

public object MessageContentTypeSerializer : KSerializer<MessageContentType> by IntCodeSerializer<MessageContentType>(
    "MessageContentType",
    { it.code },
    { MessageContentType(it) },
)

/**
 * Server-side lifecycle of a stored message.
 *
 * Not the *local* status of an outbound one: a message you are still sending has no server row
 * and therefore no value here. Track your own optimistic state next to `clientMsgId`.
 */
@JvmInline
@Serializable(with = MessageStatusSerializer::class)
public value class MessageStatus(public val code: Int) {
    override fun toString(): String = openEnumName("MessageStatus", code, NAMES)

    public companion object {
        public val Sending: MessageStatus = MessageStatus(0)
        public val Sent: MessageStatus = MessageStatus(1)
        public val Delivered: MessageStatus = MessageStatus(2)
        public val Read: MessageStatus = MessageStatus(3)
        public val Failed: MessageStatus = MessageStatus(4)

        private val NAMES = mapOf(
            0 to "Sending", 1 to "Sent", 2 to "Delivered", 3 to "Read", 4 to "Failed",
        )
    }
}

public object MessageStatusSerializer : KSerializer<MessageStatus> by IntCodeSerializer<MessageStatus>(
    "MessageStatus",
    { it.code },
    { MessageStatus(it) },
)

/** Delivery priority. `Low` is the first thing dropped when a connection is behind. */
@JvmInline
@Serializable(with = MessagePrioritySerializer::class)
public value class MessagePriority(public val code: Int) {
    override fun toString(): String = openEnumName("MessagePriority", code, NAMES)

    public companion object {
        public val Low: MessagePriority = MessagePriority(0)
        public val Normal: MessagePriority = MessagePriority(1)
        public val High: MessagePriority = MessagePriority(2)

        private val NAMES = mapOf(0 to "Low", 1 to "Normal", 2 to "High")
    }
}

public object MessagePrioritySerializer : KSerializer<MessagePriority> by IntCodeSerializer<MessagePriority>(
    "MessagePriority",
    { it.code },
    { MessagePriority(it) },
)

// ------------------------------------------------------------------------------- groups

@JvmInline
@Serializable(with = GroupTypeSerializer::class)
public value class GroupType(public val code: Int) {
    override fun toString(): String = openEnumName("GroupType", code, NAMES)

    public companion object {
        public val Normal: GroupType = GroupType(1)

        /** Tens of thousands of members; member lists are always paged and never broadcast. */
        public val Super: GroupType = GroupType(2)
        public val ChatRoom: GroupType = GroupType(3)

        private val NAMES = mapOf(1 to "Normal", 2 to "Super", 3 to "ChatRoom")
    }
}

public object GroupTypeSerializer : KSerializer<GroupType> by IntCodeSerializer<GroupType>(
    "GroupType",
    { it.code },
    { GroupType(it) },
)

@JvmInline
@Serializable(with = GroupRoleSerializer::class)
public value class GroupRole(public val code: Int) {
    override fun toString(): String = openEnumName("GroupRole", code, NAMES)

    public companion object {
        public val Member: GroupRole = GroupRole(1)
        public val Admin: GroupRole = GroupRole(2)
        public val Owner: GroupRole = GroupRole(3)

        private val NAMES = mapOf(1 to "Member", 2 to "Admin", 3 to "Owner")
    }
}

public object GroupRoleSerializer : KSerializer<GroupRole> by IntCodeSerializer<GroupRole>(
    "GroupRole",
    { it.code },
    { GroupRole(it) },
)

@JvmInline
@Serializable(with = GroupJoinModeSerializer::class)
public value class GroupJoinMode(public val code: Int) {
    override fun toString(): String = openEnumName("GroupJoinMode", code, NAMES)

    public companion object {
        public val FreeAccess: GroupJoinMode = GroupJoinMode(0)
        public val NeedApproval: GroupJoinMode = GroupJoinMode(1)
        public val Forbidden: GroupJoinMode = GroupJoinMode(2)

        private val NAMES = mapOf(0 to "FreeAccess", 1 to "NeedApproval", 2 to "Forbidden")
    }
}

public object GroupJoinModeSerializer : KSerializer<GroupJoinMode> by IntCodeSerializer<GroupJoinMode>(
    "GroupJoinMode",
    { it.code },
    { GroupJoinMode(it) },
)

@JvmInline
@Serializable(with = GroupInviteModeSerializer::class)
public value class GroupInviteMode(public val code: Int) {
    override fun toString(): String = openEnumName("GroupInviteMode", code, NAMES)

    public companion object {
        public val AllMembers: GroupInviteMode = GroupInviteMode(0)
        public val AdminsOnly: GroupInviteMode = GroupInviteMode(1)
        public val Forbidden: GroupInviteMode = GroupInviteMode(2)

        private val NAMES = mapOf(0 to "AllMembers", 1 to "AdminsOnly", 2 to "Forbidden")
    }
}

public object GroupInviteModeSerializer : KSerializer<GroupInviteMode> by IntCodeSerializer<GroupInviteMode>(
    "GroupInviteMode",
    { it.code },
    { GroupInviteMode(it) },
)

/** Where a friend request or a group join application got to. */
@JvmInline
@Serializable(with = ApplicationStatusSerializer::class)
public value class ApplicationStatus(public val code: Int) {
    override fun toString(): String = openEnumName("ApplicationStatus", code, NAMES)

    public companion object {
        public val Pending: ApplicationStatus = ApplicationStatus(0)
        public val Accepted: ApplicationStatus = ApplicationStatus(1)
        public val Rejected: ApplicationStatus = ApplicationStatus(2)
        public val Expired: ApplicationStatus = ApplicationStatus(3)

        private val NAMES = mapOf(0 to "Pending", 1 to "Accepted", 2 to "Rejected", 3 to "Expired")
    }
}

public object ApplicationStatusSerializer : KSerializer<ApplicationStatus> by IntCodeSerializer<ApplicationStatus>(
    "ApplicationStatus",
    { it.code },
    { ApplicationStatus(it) },
)
