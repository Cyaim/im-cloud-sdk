/**
 * The typed surface, grouped into namespaces named exactly for the target prefix.
 *
 * 107 flat methods on one object is not an API, it is a scroll bar. `im.msg.recall(…)` maps to
 * `msg.recall` with no lookup table, in every one of the five SDKs — and the method name is the
 * endpoint's method part with no synonyms, so a bug report saying "msg.forward fails" can be
 * grepped rather than translated (CONTRACT §4.1, §4.2).
 *
 * Every method here is a thin wrapper over the same internal `request(target, body)` that
 * `invoke()` uses. That is a rule, not an accident: two code paths drift on timeouts, cancellation
 * and error mapping, and the drift gets found by a customer (CONTRACT §8.1).
 *
 * 命名空间与端点前缀一一对应，方法名就是端点名的后半段，不取同义词——
 * 支持工程师能直接 grep 客户报上来的端点名。
 */

import type { ImRequestOptions } from './connection.js';
import type { DeviceLogAnswer, PendingDeviceLog } from './devicelogs.js';
import type {
  AddFriendRequest,
  AnnouncementRequest,
  BlockEntry,
  BlockRequest,
  ConversationIdRequest,
  ConversationMessageRequest,
  ConversationView,
  CreateGroupRequest,
  CursorRequest,
  DeleteMessagesRequest,
  DeskAcceptRequest,
  DeskCannedReply,
  DeskCannedRequest,
  DeskCloseRequest,
  DeskQueueView,
  DeskRateRequest,
  DeskRequest,
  DeskSession,
  DeskStatusRequest,
  DeskSuggestRequest,
  DeskTransferRequest,
  DownloadUrlRequest,
  EditMessageRequest,
  ForwardMessagesRequest,
  Friend,
  FriendRequest,
  FriendRequestListRequest,
  Group,
  GroupApplication,
  GroupCursorRequest,
  GroupIdRequest,
  GroupMember,
  GroupMembersRequest,
  HandleApplicationRequest,
  HandleFriendRequest,
  HeartbeatResult,
  HistoryRequest,
  ImMessage,
  JoinGroupRequest,
  ListConversationsRequest,
  MarkUnreadRequest,
  MediaUploadTicket,
  MessageReceipt,
  MuteGroupRequest,
  MuteMemberRequest,
  PageRequest,
  PinnedMessage,
  PresenceState,
  PushClickedRequest,
  PushProvider,
  ReactRequest,
  ReadRequest,
  ReauthRequest,
  RecallMessageRequest,
  ReceiptDetailRequest,
  ReceiptRequest,
  RegisterPushTokenRequest,
  ReportReceipt,
  ResumeRequest,
  ResumeResult,
  SearchMessagesRequest,
  SendMessageRequest,
  SendMessageResult,
  SetGroupNicknameRequest,
  SetRemarkRequest,
  SetRoleRequest,
  SetStatusRequest,
  SubmitReportRequest,
  SubscribePresenceRequest,
  SyncMessagesRequest,
  SyncMessagesResult,
  TransferOwnerRequest,
  TypingRequest,
  UpdateConversationSettingRequest,
  UpdateGroupCommand,
  UpdateProfileRequest,
  UploadTicketRequest,
  UserIdRequest,
  UserIdsRequest,
  UserProfile,
} from './models.js';
import { MessageContentType, type PagedResult, asId, asLong } from './protocol.js';

/** The one code path every typed method and `invoke()` share. */
export interface ImInvoker {
  request<T>(target: string, body?: unknown, options?: ImRequestOptions): Promise<T>;
}

/** `conn.*` — transport lifecycle (T0). The SDK drives all three; they are public for the odd case. */
export class ConnApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * Keeps the session alive and heals a routing entry the cluster lost. The SDK beats on the
   * cadence the server returns, so an application almost never calls this itself.
   */
  heartbeat(options?: ImRequestOptions): Promise<HeartbeatResult> {
    return this.io.request<HeartbeatResult>('conn.heartbeat', undefined, options);
  }

  /**
   * Exchanges a fresh token on the socket that is already open.
   *
   * Without it, a token expiring mid-session costs a full reconnect — and on the flaky network
   * where tokens tend to expire unnoticed, a reconnect is exactly what you were trying to avoid.
   * The connection calls this for you when a request comes back `1101` and `onTokenExpired` is set.
   */
  async reauth(request: ReauthRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conn.reauth', request, options);
  }

  /**
   * Raw resume. **The SDK runs this itself on every connect** with the right cursors and full
   * paging; calling it by hand does not move any cursor and does not repair anything.
   */
  sync(request: ResumeRequest, options?: ImRequestOptions): Promise<ResumeResult> {
    return this.io.request<ResumeResult>('conn.sync', request, options);
  }
}

/** `msg.*` — send, backfill, and everything done to a message after it exists. */
export class MsgApi {
  constructor(
    private readonly io: ImInvoker,
    /** Lets the client record its own send so the server's echo is recognised as a duplicate. */
    private readonly onSent: (result: SendMessageResult) => void = () => {},
    private readonly newClientMsgId: () => string = () => `${Date.now().toString(36)}`,
  ) {}

  /**
   * Sends a message. Idempotent on `clientMsgId`: retrying after a timeout returns the original
   * result rather than sending twice.
   *
   * `clientMsgId`, `contentType` and `sendTime` are filled in when absent, so a caller who never
   * thought about idempotency still gets it.
   */
  async send(request: SendMessageRequest, options?: ImRequestOptions): Promise<SendMessageResult> {
    const payload: SendMessageRequest = {
      ...request,
      contentType: request.contentType ?? MessageContentType.Text,
      clientMsgId: request.clientMsgId ?? this.newClientMsgId(),
      sendTime: request.sendTime ?? Date.now(),
    };

    const result = await this.io.request<SendMessageResult>('msg.send', payload, options);
    result.seq = asLong(result.seq);
    result.messageId = asId(result.messageId);
    this.onSent(result);
    return result;
  }

  /**
   * Fetches a contiguous seq range.
   *
   * `hasMore` is decided on the raw window before per-user hidden rows are removed, so `messages`
   * can be shorter than `limit` — even empty — while there is more of the range left. Page on
   * `hasMore`, never on `messages.length` (CONTRACT §5.9). The SDK's own gap repair does exactly
   * that; an application calling this directly must too.
   */
  sync(request: SyncMessagesRequest, options?: ImRequestOptions): Promise<SyncMessagesResult> {
    return this.io.request<SyncMessagesResult>('msg.sync', request, options);
  }

  /** Pages backwards from a seq cursor. `beforeSeq` is the oldest seq you already hold. */
  history(request: HistoryRequest, options?: ImRequestOptions): Promise<PagedResult<ImMessage>> {
    return this.io.request<PagedResult<ImMessage>>('msg.history', request, options);
  }

  async recall(request: RecallMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.recall', request, options);
  }

  /** Deletes for this user. `forEveryone` needs the permission the server checks. */
  async delete(request: DeleteMessagesRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.delete', request, options);
  }

  async edit(request: EditMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.edit', request, options);
  }

  /** One result per target conversation, in the order they were given. */
  forward(request: ForwardMessagesRequest, options?: ImRequestOptions): Promise<SendMessageResult[]> {
    return this.io.request<SendMessageResult[]>('msg.forward', request, options);
  }

  async react(request: ReactRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.react', request, options);
  }

  /** Per-message read receipt. Distinct from `conv.read`, which is the conversation-level cursor. */
  async receipt(request: ReceiptRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.receipt', request, options);
  }

  /**
   * Typing indicator. Never stored, never counted, dropped first when a connection is behind — and
   * answered `1203 FeatureNotEnabled` when the tenant has it off, which the SDK does not latch:
   * a tenant can flip that flag at runtime.
   */
  async typing(request: TypingRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.typing', request, options);
  }

  // ---- T3: competitive parity -----------------------------------------------------------------
  //
  // Every message id below leaves as a **string**, and for these endpoints that is the server's
  // requirement, not only this SDK's caution: the request DTOs declare `messageId` as C# `string`
  // and the socket binder refuses a JSON number for one with `1000`. See ConversationMessageRequest.
  // 下面每个消息 id 都以字符串出线：服务端 DTO 就是 string，给数字会被绑定器拒成 1000。

  /**
   * Pins a message to the conversation's shared board — an announcement everyone in the
   * conversation sees, as opposed to {@link favourite}, which only the caller does.
   *
   * **Who may:** either side of a single chat; in a group, only the owner or an admin while the
   * deployment's `IM:Extras:GroupPinRequiresAdmin` is on, which is the default (`1504` otherwise).
   * Chat rooms are `1008`.
   *
   * **Refusals:** `1400` for a message that is not there — including a `messageId` the server
   * cannot parse — and for a recalled one; `1008` for an ephemeral message (sent with
   * `options.expireIn`); `1006` once the board holds `IM:Extras:MaxPinsPerConversation` pins
   * (20 by default) — unpin one first. Pinning what is already pinned succeeds and announces nothing.
   *
   * On success everyone gets a notification message (`contentType` 9, `content.code` 1514,
   * `pinned: true`). **Do not take the message id from that notification**: its
   * `content.messageId` is a bare JSON number and has lost precision by the time `JSON.parse` hands
   * it over. Re-read {@link pins} instead.
   * 置顶成功会发一条 1514 通知，但它的 content.messageId 是裸数字、已经丢了精度——请重新读 pins。
   */
  async pin(request: ConversationMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.pin', request, options);
  }

  /**
   * Takes a message off the board. Same permission rules as {@link pin}.
   *
   * **Succeeds silently when nothing was pinned** — including for a `messageId` the server cannot
   * parse — so it is safe to retry, and a success is not proof the id was right. The 1514
   * notification (`pinned: false`) goes out only when a pin was actually removed.
   */
  async unpin(request: ConversationMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.unpin', request, options);
  }

  /**
   * The conversation's pinned board, newest pin first. **A plain array, not a page**: the board is
   * capped (20 by default), so there is nothing to page through. `[]` when nothing is pinned.
   *
   * Any participant may read it; a group non-member is `1503`. Pins whose message has since vanished
   * are dropped from the answer and cleaned up server-side.
   */
  pins(request: ConversationIdRequest, options?: ImRequestOptions): Promise<PinnedMessage[]> {
    return this.io.request<PinnedMessage[]>('msg.pins', request, options);
  }

  /**
   * Bookmarks a message for the caller alone. Private and silent: nobody else is told.
   *
   * **Refusals:** `1400` for a message that is not there (including an unparseable id); `1008` for
   * an ephemeral message; `1006` once the caller holds `IM:Extras:MaxFavouritesPerUser` (5000 by
   * default) — counted *before* the write, so re-favouriting at the cap also fails. A recalled
   * message is **not** refused. Repeating it is safe, but it moves the favourite back to the top.
   */
  async favourite(request: ConversationMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.favourite', request, options);
  }

  /**
   * Removes a bookmark. **Always succeeds** — nothing to remove, an unparseable id, a conversation
   * the caller has since left: all `0`. So it is safe to repeat, and a success proves nothing about
   * the id.
   */
  async unfavourite(request: ConversationMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.unfavourite', request, options);
  }

  /**
   * The caller's bookmarks across every conversation, newest favourite first, as whole messages.
   *
   * **Page until `nextCursor` is absent, not until a page comes back short**: favourites in chats the
   * caller can no longer read are hidden rather than returned, so a page can be short — even empty —
   * with more behind it. Recalled messages *are* listed, with `recalled` set. The payload carries no
   * favourite timestamp and no `total`.
   * 翻到 nextCursor 为空为止，不要按「这页不满」停：读不到的会话里的收藏被隐藏，一页可以短甚至为空。
   */
  favourites(request: PageRequest = {}, options?: ImRequestOptions): Promise<PagedResult<ImMessage>> {
    return this.io.request<PagedResult<ImMessage>>('msg.favourites', request, options);
  }

  /**
   * Starts the countdown on a burn-after-reading message. **Call it when the message is actually
   * shown**; it is safe to call for every rendered message.
   *
   * Only messages sent with `options.expireIn > 0` burn (`1008` otherwise). The sender calling it on
   * their own message succeeds and starts nothing. The first *reader* moves the message's `expireAt`
   * from `createTime + expireIn` to `now + expireIn` — **conversation-wide**, so in a group the first
   * reader starts everyone's clock — and later calls succeed silently. A message nobody reads still
   * expires at `createTime + expireIn`.
   *
   * The only T3 message call that checks its id: a missing or unparseable `messageId` is `1001`.
   * Participants are told through `evt.messageUpdate` with `kind: "burn"` and the absolute
   * `expireAt` — read it with `im.onEvent('evt.messageUpdate', …)`; it is not typed yet.
   *
   * **A courtesy between cooperating clients, not a defence.** The server stops serving the message
   * and tells clients to erase it; a recipient who already has the bytes can keep them.
   * 阅后即焚是协作客户端之间的礼貌，不是防御：已经拿到字节的接收方可以留存。
   */
  async burn(request: ConversationMessageRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('msg.burn', request, options);
  }

  /**
   * Full-text search over what the caller can see, newest first. Recalled messages and ones the
   * caller deleted for themselves are excluded.
   *
   * **Off unless the tenant turned it on**, and gated twice: `1203 FeatureNotEnabled` while
   * `EnableSearch` is off (the default, and forced off on end-to-end-encrypted apps), `1204
   * PlanExpired` when the plan lacks the search add-on. Neither is latched by the SDK — a tenant can
   * change both at runtime (CONTRACT §7.4).
   *
   * **Rate limited per user, before either gate:** `1003` past `MaxSearchPerMinutePerUser` (30 by
   * default) in a sliding minute, with no retry hint. Because the limiter runs first, calls against
   * a tenant with search off still spend the budget — **debounce search-as-you-type**.
   *
   * A blank `keyword` is `1001`; one made only of punctuation or emoji returns an empty page. The
   * filters apply after the index page, so short pages with `hasMore: true` are normal; page on
   * `nextCursor`. An index that takes longer than five seconds comes back `1000`, not `1004` — it is
   * retryable, and the SDK leaves the retry to you.
   * 默认关闭；限速在开关检查之前执行，所以对关闭搜索的租户调用也会消耗额度——输入联想要做防抖。
   */
  search(request: SearchMessagesRequest, options?: ImRequestOptions): Promise<PagedResult<ImMessage>> {
    return this.io.request<PagedResult<ImMessage>>('msg.search', request, options);
  }

  /**
   * Who has read one message. Distinct from {@link receipt}, which is how a reader *reports* a read.
   *
   * Returns the stored receipt when there is one. Otherwise `1400` for a message that is not there
   * (including an unparseable id), `1410 ReceiptDisabled` when it was not sent with
   * `options.needReceipt`, and an **empty receipt** — `readUserIds: []`, `readCount: 0` — when
   * nobody has read it yet. Access: `1001`, `1103`, `1503`.
   *
   * **This read has no cap and truncates nothing.** The group-size limit belongs to the *write*:
   * `msg.receipt` answers `1410` in groups larger than the tenant's `ReceiptGroupMemberLimit` (100 by
   * default), so in such a group nobody's read is ever recorded and this returns an empty — or
   * frozen — receipt. Read {@link MessageReceipt.totalCount} with its note: it includes the sender.
   * 这个读没有上限、不截断；群人数上限卡的是写入（msg.receipt），所以大群里这里读到的是空的或冻结的回执。
   */
  receiptDetail(request: ReceiptDetailRequest, options?: ImRequestOptions): Promise<MessageReceipt> {
    return this.io.request<MessageReceipt>('msg.receiptDetail', request, options);
  }
}

/** `conv.*` — the list a user opens the app to, and the per-user state attached to it. */
export class ConvApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * The conversation list, incrementally. Pass the largest `updatedAt` you hold as `updatedAfter`
   * and a returning user downloads what changed rather than their whole history — the difference
   * between a one-second cold start and a thirty-second one for a heavy user.
   */
  list(request: ListConversationsRequest = {}, options?: ImRequestOptions): Promise<PagedResult<ConversationView>> {
    return this.io.request<PagedResult<ConversationView>>('conv.list', request, options);
  }

  get(request: ConversationIdRequest, options?: ImRequestOptions): Promise<ConversationView> {
    return this.io.request<ConversationView>('conv.get', request, options);
  }

  /** Moves the read cursor, which clears the badge on every other device of the same user. */
  async read(request: ReadRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conv.read', request, options);
  }

  async setting(request: UpdateConversationSettingRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conv.setting', request, options);
  }

  /** Removes the conversation from this user's list. Other participants keep theirs. */
  async delete(request: ConversationIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conv.delete', request, options);
  }

  /** Clears this user's view of the history. Clearing for everyone is a server-API operation. */
  async clear(request: ConversationIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conv.clear', request, options);
  }

  /** The app badge. Arrives as a bare number, which the server may write as a JSON string. */
  async unreadTotal(options?: ImRequestOptions): Promise<number> {
    return asLong(await this.io.request<number | string>('conv.unreadTotal', undefined, options));
  }

  /**
   * Marks a conversation unread by hand — the "remind me later" swipe — or clears that mark (T3).
   *
   * **`unread` absent means `true`**; clearing is `unread: false`, explicitly. The mark surfaces as
   * `ConversationView.manuallyUnread`, and an `unreadCount` that would otherwise be 0 displays as 1.
   * It does **not** move `readSeq`, so the other side's read receipts are unaffected; `conv.read`,
   * `conv.delete` and `conv.clear` all clear it. Setting the value it already has succeeds and sends
   * no event; a change goes to the caller's other devices as `evt.conversationUpdate`, kind
   * `"unread"`. Access: `1001`, `1103`, `1503`.
   * 省略 unread 即 true；清除要显式发 false。不移动 readSeq，对方的已读回执不受影响。
   */
  async markUnread(request: MarkUnreadRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('conv.markUnread', request, options);
  }
}

/** `user.*` — profiles and presence. */
export class UserApi {
  constructor(private readonly io: ImInvoker) {}

  me(options?: ImRequestOptions): Promise<UserProfile> {
    return this.io.request<UserProfile>('user.me', undefined, options);
  }

  profile(request: UserIdRequest, options?: ImRequestOptions): Promise<UserProfile> {
    return this.io.request<UserProfile>('user.profile', request, options);
  }

  /**
   * Resolves many peers at once, up to 200. This is what stops a 50-row conversation list issuing
   * 50 profile calls, which is how a chat list takes two seconds to paint.
   */
  batchProfile(request: UserIdsRequest, options?: ImRequestOptions): Promise<UserProfile[]> {
    return this.io.request<UserProfile[]>('user.batchProfile', request, options);
  }

  /** Patches the caller's own profile. Platform-owned fields are stripped server-side. */
  async updateProfile(request: UpdateProfileRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('user.updateProfile', request, options);
  }

  /** Answers `1203` when the tenant has presence off. */
  presence(request: UserIdsRequest, options?: ImRequestOptions): Promise<PresenceState[]> {
    return this.io.request<PresenceState[]>('user.presence', request, options);
  }

  /**
   * Watches users for online/offline transitions, with a TTL — a client that crashes never sends
   * an unsubscribe, and an unbounded subscriber set is a leak that only shows up as presence
   * fan-out cost months later. Re-subscribe before it expires.
   *
   * One asymmetry worth knowing: this call does **not** check `EnablePresence`, while
   * `user.presence` does. A subscribe against a presence-disabled app succeeds and then never
   * fires, so do not infer the flag from a successful subscribe (CONTRACT §7.4).
   */
  async subscribePresence(request: SubscribePresenceRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('user.subscribePresence', request, options);
  }

  async unsubscribePresence(request: UserIdsRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('user.unsubscribePresence', request, options);
  }

  /**
   * Sets the caller's own status line (T3) — "in a meeting", "on leave". `setStatus({})` clears it.
   *
   * **It expires after seven days, silently.** The server stores it with a TTL and nothing tells
   * the user it went, so an application that wants it to persist sets it again on login.
   *
   * Trimmed; over 64 characters is `1001`. `1005` when the presence store is down. Subscribers see it
   * as `customStatus` on `evt.presence`. Like {@link subscribePresence}, this call does **not** check
   * `EnablePresence` while {@link presence} does, so a successful set does not mean anyone can read it.
   * 七天后静默过期：服务端带 TTL 存储、不会通知任何人。要长期保留，就在每次登录时重新设置。
   */
  async setStatus(request: SetStatusRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('user.setStatus', request, options);
  }
}

/** `friend.*` — contacts, requests and the blocklist. */
export class FriendApi {
  constructor(private readonly io: ImInvoker) {}

  list(request: CursorRequest = {}, options?: ImRequestOptions): Promise<PagedResult<Friend>> {
    return this.io.request<PagedResult<Friend>>('friend.list', request, options);
  }

  /** Sends a friend request; whether it needs approval is the tenant's setting, not the caller's. */
  async add(request: AddFriendRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.add', request, options);
  }

  async handleRequest(request: HandleFriendRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.handleRequest', request, options);
  }

  requestList(
    request: FriendRequestListRequest = {},
    options?: ImRequestOptions,
  ): Promise<PagedResult<FriendRequest>> {
    return this.io.request<PagedResult<FriendRequest>>('friend.requestList', request, options);
  }

  async delete(request: UserIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.delete', request, options);
  }

  blockList(request: CursorRequest = {}, options?: ImRequestOptions): Promise<PagedResult<BlockEntry>> {
    return this.io.request<PagedResult<BlockEntry>>('friend.blockList', request, options);
  }

  /**
   * Blocks a user. Not optional surface: app-store review treats user blocking as mandatory for
   * any app carrying user-generated content, so an SDK without it costs a submission.
   */
  async block(request: BlockRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.block', request, options);
  }

  async unblock(request: UserIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.unblock', request, options);
  }

  /**
   * Renames a contact and re-files their tags (T3). Visible only to the caller: the `evt.friend`
   * frame (`action: "updated"`) goes to the caller's own devices and never to the contact.
   *
   * **Omitting `remark` clears it; omitting `tags` keeps them** — so to change only the tags, send
   * the current remark along. `1001` for a remark over 64 characters (refused, not truncated), more
   * than 20 tags, or a tag blank or over 32; `1302 NotFriend` when they are not a contact.
   * 省略 remark 会清空备注，省略 tags 则不动——只改标签时要把现有备注一起带上。
   */
  async setRemark(request: SetRemarkRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('friend.setRemark', request, options);
  }
}

/**
 * `group.*` — the core ten (T2), and administration: ownership, roles, mutes, nicknames,
 * announcements and join requests (T3).
 *
 * Most of the administration verbs are owner-or-admin (`1504 NoGroupPermission` otherwise); the
 * group-level refusals are `1500` (no such group), `1501` (dismissed) and `1503` (the caller or the
 * target is not a member). Each method names what is specific to it. Every successful change is
 * announced to the group as a notification message (`contentType` 9) carrying its own code in
 * `content.code`.
 */
export class GroupApi {
  constructor(private readonly io: ImInvoker) {}

  /** The caller is added and made owner whatever `memberIds` says. */
  create(request: CreateGroupRequest, options?: ImRequestOptions): Promise<Group> {
    return this.io.request<Group>('group.create', request, options);
  }

  info(request: GroupIdRequest, options?: ImRequestOptions): Promise<Group> {
    return this.io.request<Group>('group.info', request, options);
  }

  async update(request: UpdateGroupCommand, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.update', request, options);
  }

  /** Owner only, and irreversible. Members get `evt.group`. */
  async dismiss(request: GroupIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.dismiss', request, options);
  }

  /** Always paged: a super group holds a hundred thousand members. */
  memberList(request: GroupCursorRequest, options?: ImRequestOptions): Promise<PagedResult<GroupMember>> {
    return this.io.request<PagedResult<GroupMember>>('group.memberList', request, options);
  }

  joined(request: CursorRequest = {}, options?: ImRequestOptions): Promise<PagedResult<Group>> {
    return this.io.request<PagedResult<Group>>('group.joined', request, options);
  }

  async invite(request: GroupMembersRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.invite', request, options);
  }

  async kick(request: GroupMembersRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.kick', request, options);
  }

  async quit(request: GroupIdRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.quit', request, options);
  }

  /** May answer `1508 JoinNeedsApproval`, which is a success of a different shape, not a failure. */
  async join(request: JoinGroupRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.join', request, options);
  }

  // ---- T3: administration ---------------------------------------------------------------------

  /**
   * Hands the group to another member. **Owner only** (`1504`), and not repeatable: a retry after
   * it succeeded is `1504`, because the caller is no longer the owner.
   *
   * The outgoing owner becomes a plain **Member**, not an admin — grant it back with
   * {@link setRole} if that is what you want. Transferring to yourself is `1001`; to a non-member,
   * `1503`. Announced as notification 1511.
   * 原群主降为普通成员而不是管理员；成功后重试会得到 1504，因为调用者已不再是群主。
   */
  async transfer(request: TransferOwnerRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.transfer', request, options);
  }

  /**
   * Join requests awaiting — and already given — an answer, newest first.
   *
   * **The body is optional, and so is `groupId`**: omitted, or `''`, lists across every group the
   * caller manages (only the first 200 groups they have joined are looked at). With a `groupId` the
   * caller must be its owner or an admin (`1504`).
   *
   * **It returns every status, not only pending**: filter on
   * `status === ApplicationStatus.Pending` for a "waiting for you" list. `limit` 1–200 is kept,
   * anything else becomes 50.
   * 返回所有状态而不只是待处理的：「等你处理」要自己筛 Pending。
   */
  applicationList(
    request: GroupCursorRequest = { groupId: '' },
    options?: ImRequestOptions,
  ): Promise<PagedResult<GroupApplication>> {
    return this.io.request<PagedResult<GroupApplication>>('group.applicationList', request, options);
  }

  /**
   * Accepts or rejects one join request. Owner or admin (`1504`).
   *
   * `1512 ApplicationNotFound` when there is no such request, `1006` when it was already handled.
   * A rejection is stored with its reason and **tells nobody**. An acceptance adds the member and
   * announces 1513 — unless the group is full (`1502`), in which case the request stays pending.
   */
  async handleApplication(request: HandleApplicationRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.handleApplication', request, options);
  }

  /**
   * Promotes a member to admin or demotes an admin. **Owner only** (`1504`).
   *
   * `role` is typed to `Member` or `Admin` because the server stores any other integer except
   * `Owner` — see {@link SetRoleRequest.role} for why that matters. Ownership moves only with
   * {@link transfer}; `Owner` here is `1008`. A non-member target is `1503`; the owner as target —
   * including the owner naming themselves — is `1511`. Setting the role somebody already has
   * succeeds and announces nothing; otherwise 1507 announces a promotion to admin and 1508
   * anything else.
   */
  async setRole(request: SetRoleRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.setRole', request, options);
  }

  /**
   * Mutes or unmutes the whole group. Owner or admin (`1504`); they can still send while it is on,
   * and members get `1505 GroupMuted`.
   *
   * **`mute` absent means `true`**, and **a past `untilMs` means indefinitely, not "unmute"** — see
   * {@link MuteGroupRequest}. Every call writes and announces 1509, even when nothing changed.
   * 省略 mute 即 true；过去的 untilMs 是「无限期」而不是「解除」。
   */
  async mute(request: MuteGroupRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.mute', request, options);
  }

  /**
   * Mutes one member until a time, or unmutes them. Owner or admin (`1504`); an admin cannot mute
   * another admin (`1504`), nobody can mute the owner (`1511`), and muting yourself is `1008`.
   *
   * **No `untilMs`, or a past one, unmutes** — the opposite reading from {@link mute}. There is no
   * indefinite member mute; send a far-future time. The muted member's sends fail `1506
   * MemberMuted`. Announced as 1510.
   */
  async muteMember(request: MuteMemberRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.muteMember', request, options);
  }

  /**
   * Sets somebody's nickname inside the group — the caller's own when `userId` is omitted, which
   * any member may do. Anybody else's needs owner or admin and outranking them (`1504` / `1511`).
   *
   * Trimmed; blank clears it; **over 64 characters is truncated, not refused**. Announced as 1506
   * with `fields: ["Nickname"]` — capitalised, as the server writes it.
   */
  async setNickname(request: SetGroupNicknameRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.setNickname', request, options);
  }

  /**
   * Replaces the group announcement. Owner or admin (`1504`).
   *
   * Trimmed; absent or blank clears it; **over 4096 characters is truncated, not refused**. Sets
   * `Group.announcementUpdatedAt`, and every call announces 1512 — even when the text did not change.
   */
  async announcement(request: AnnouncementRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('group.announcement', request, options);
  }
}

/** `media.*` — presigned upload and download. Bytes never travel through the gateway. */
export class MediaApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * A short-lived presigned PUT. The server chooses the object key, so a client cannot write
   * outside its own tenant and user prefix.
   *
   * Put `objectKey` in the message, never `downloadUrl` — every reader signs their own link, which
   * is what makes expiry and revocation possible at all.
   */
  uploadTicket(request: UploadTicketRequest, options?: ImRequestOptions): Promise<MediaUploadTicket> {
    return this.io.request<MediaUploadTicket>('media.uploadTicket', request, options);
  }

  /** Exchanges a stored object key for a short-lived download URL. */
  downloadUrl(request: DownloadUrlRequest, options?: ImRequestOptions): Promise<string> {
    return this.io.request<string>('media.downloadUrl', request, options);
  }
}

/**
 * `push.*` — offline push registration.
 *
 * Identity comes from the socket: app id, user id and device id are all already authenticated
 * there, and there is no field in the body in which to say "register a token against someone
 * else's device". Never put `userId` or `deviceId` in the request; the server ignores them.
 *
 * On the web this is only useful where the deployment supports Web Push. A browser tab that stays
 * open gets its messages over the live socket and needs none of this.
 */
export class PushApi {
  private provider: PushProvider = '';
  private token = '';
  private registered = false;

  constructor(
    private readonly io: ImInvoker,
    private readonly isConnected: () => boolean,
  ) {}

  /** True once a register call has succeeded on the current token. */
  get isRegistered(): boolean {
    return this.registered;
  }

  /** The token the SDK is holding, if any. Empty until `setToken` or a successful `register`. */
  get currentToken(): string {
    return this.token;
  }

  /**
   * Records or refreshes this device's vendor token.
   *
   * Idempotent, and re-registering an unchanged token costs no write — the server debounces it
   * (`IM:Push:TokenRefreshDebounceMinutes`). That is why the SDK calls it on *every* connect rather
   * than once at install: a vendor may replace the token while the process is frozen and the server
   * has no other way to learn it.
   */
  async register(request: RegisterPushTokenRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('push.register', request, options);
    this.provider = request.provider;
    this.token = request.token;
    this.registered = true;
  }

  /**
   * Drops this device's registration. Other devices of the same user are untouched.
   *
   * **Call this before `disconnect()`, never after.** Once the socket closes there is no
   * authenticated channel and the token cannot be removed at all — which is why disconnecting
   * never unregisters, and why `ImClient.logout()` exists to get the order right.
   */
  async unregister(options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('push.unregister', undefined, options);
    this.registered = false;
  }

  /**
   * Reports that the user tapped one of this device's notifications.
   *
   * **Best-effort statistics, and the call site is the tap handler — not the message render.** What
   * it feeds is the delivery funnel on the tenant's push screen: sent → delivered → clicked. APNs
   * and FCM do not report delivery at all, so on most deployments a click is the only evidence a
   * notification ever arrived, and the server credits delivery from it.
   *
   * **Both arguments are optional and neither carries identity.** Pass what the payload gave you:
   * `messageId` from the notification's `msgId` is the usual one. With nothing at all the server
   * attributes the newest delivery to this device, which is the right answer for a tap that opened
   * the app without naming a message.
   *
   * **The returned promise never rejects.** The server answers `2401 PushDeliveryNotFound` when
   * nothing matches — the row expired (seven days) or the notification did not come from this
   * platform — and neither is the caller's fault nor worth a line of error handling in a tap
   * handler, so the SDK logs it and resolves. Nothing is retried.
   *
   * 上报一次通知点击。**调用点是点击处理器，不是消息渲染处。**
   * APNs 与 FCM 根本不回报送达，所以在多数部署上，点击是「这条通知确实到过」的唯一证据。
   */
  async clicked(request?: PushClickedRequest, options?: ImRequestOptions): Promise<void> {
    try {
      await this.io.request<void>('push.clicked', request ?? {}, options);
    } catch (error) {
      // Cancellation is the caller's own doing and stays visible (CONTRACT §7.5). Everything else
      // does not.
      if (error instanceof Error && error.name === 'AbortError') throw error;

      // **This call never rejects, and that is the endpoint rather than a shortcut.** It is a
      // statistic reported from a tap handler: there is nothing the application can do about a
      // failure, nothing the user should be told, and an unhandled rejection escaping a tap
      // handler is a worse bug than the missing funnel row. It is not retried either — a click
      // that missed is one row on a dashboard, and the SDK never re-sends a business call anyway
      // (CONTRACT §7.3). A debug line, because the row expiring after seven days is routine and a
      // warning that fires routinely is a warning that gets filtered out.
      // 这一条永不 reject：它是从点击处理器上报的统计，失败时应用无事可做、用户无需知情，
      // 而从点击处理器里逃出去的未捕获 rejection 比少一行漏斗数据糟得多。也不重试。
      console.debug('[im] push.clicked was not recorded:', error);
    }
  }

  /**
   * Hands the SDK a vendor token without sending it yet.
   *
   * **The host app owns token acquisition; the SDK owns token delivery.** Firebase, APNs and the
   * OEM channels all hand the token to the application, not to a library, so this is the seam:
   * call it from your `onNewToken` equivalent and once at startup, and the SDK registers on the
   * next connect and on every connect after that.
   *
   * Registers immediately when already connected — and then the returned promise carries that
   * call's outcome, so it can reject. Otherwise the token is cached, the promise resolves at once,
   * and the connect path sends it. Registration is a normal request and is never queued across a
   * reconnect.
   */
  setToken(provider: PushProvider, token: string): Promise<void> {
    const changed = provider !== this.provider || token !== this.token;
    this.provider = provider;
    this.token = token;
    if (changed) this.registered = false;

    if (!token || !this.isConnected()) {
      return Promise.resolve();
    }

    return this.register({ provider, token });
  }

  /**
   * Clears the cached token. Used by logout, so the next login does not re-register a dead token.
   *
   * `setToken` / `clearToken` is the pair, spelled the same way in all five SDKs (Unity:
   * `SetToken` / `ClearToken`). It used to be `forgetToken` here and `clearToken` everywhere else,
   * which is exactly the kind of drift a support engineer pays for when a customer's snippet is
   * from the wrong platform's README.
   */
  clearToken(): void {
    this.provider = '';
    this.token = '';
    this.registered = false;
  }

  /**
   * @deprecated Use {@link clearToken}, which is the name the other four SDKs use. Removed in 2.0.
   */
  forgetToken(): void {
    this.clearToken();
  }

  /**
   * Rule 1 of CONTRACT §6.2, run by the client on every successful connect.
   *
   * Returns false when a token is held but registration failed, which is the one case worth a
   * warning: a silently unregistered device is indistinguishable from a broken push provider, and
   * that misdiagnosis costs a support cycle every time.
   *
   * @internal The connect-time hook, not part of the token-cache pair. It is public only because
   * TypeScript has no package-private; call {@link setToken} instead.
   */
  async registerOnConnect(): Promise<boolean> {
    if (!this.token) return true;

    try {
      await this.register({ provider: this.provider, token: this.token });
      return true;
    } catch {
      this.registered = false;
      return false;
    }
  }
}

/**
 * `moderation.*` — what an end user can do about content they should not have seen.
 *
 * The other half of what `friend.block` is here for: app-store review requires both a way to block
 * an abusive user and a way to report objectionable content, so an app that ships with one and not
 * the other fails the same submission.
 *
 * 与 friend.block 是同一件事的两半：应用商店审核要求既能拉黑也能举报，缺一条就过不了同一次提审。
 */
export class ModerationApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * Reports another user, optionally naming a message.
   *
   * **The reporter is the connection.** There is no argument for it, on purpose — see
   * {@link SubmitReportRequest}. Pass `messageId` to report one message and omit it to report the
   * account.
   *
   * The target and the category are checked; the message is not. A report about a message that
   * has already been deleted is exactly the report a moderator most wants, and refusing it would
   * turn the platform's own retention into a way to escape moderation. So a reporting UI can file
   * from a message that is no longer on screen.
   *
   * 除了「不能举报自己」和分类合法之外不做校验：关于已被删除的消息的举报恰恰是审核员最想要的那条。
   */
  report(request: SubmitReportRequest, options?: ImRequestOptions): Promise<ReportReceipt> {
    return this.io.request<ReportReceipt>('moderation.report', request, options);
  }
}

/**
 * `desk.*` — the customer-service desk, from both sides of it (T4).
 *
 * **Two audiences, one namespace, and which one you are is decided by the session rather than by
 * the method you call.** `request` and `rate` are the customer's; `accept`, `transfer`, `status`,
 * `queue`, `canned` and `suggest` are an agent's; `close` is either side's. The server checks the
 * caller against the session's holder on every one of them, so an agent-shaped call from a customer
 * is `1103`, not a privilege escalation.
 *
 * **The conversation is not here.** Everything a customer and an agent say to each other is an
 * ordinary single chat between the customer and the desk account, sent with `msg.send` and read
 * with `msg.history` like any other message. These nine verbs only move the *assignment* around it,
 * which is why a desk integration is a chat integration plus this namespace rather than a second
 * messaging stack.
 *
 * **Who calls these, in practice.** The visitor widget bundles this package and calls `request`,
 * `msg.send` and `rate` (SPEC-06 §14.3); an in-app support screen in a tenant's own client calls
 * the same three. An agent workbench built on the console uses `/console/v1` for its writes and
 * only `status` — the heartbeat — and the `evt.desk` subscription from here (SPEC-06 §14.5 adds no
 * write endpoints to the socket for it). `accept` / `transfer` / `close` over the socket are for a
 * tenant's own agent client.
 *
 * **A deployment older than this build answers `1008 UnsupportedOperation`** — "this server does
 * not have that endpoint" — rather than a desk-specific code, because `status: 2` maps there
 * (CONTRACT §7.2). Neither retrying nor re-authenticating changes it.
 *
 * 两种角色共用一个命名空间，而「你是谁」由会话判定、不由你调用哪个方法决定。
 * 聊天不在这里：客户与坐席之间就是一条普通单聊，这九个动词只负责「谁来接」。
 */
export class DeskApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * Asks for a person, and hands back the session — a new one, or the caller's own open one.
   *
   * **Idempotent, so the button does not need a guard.** A customer who already has a session
   * anywhere but closed — queued, assigned, or still with the bot — gets that session back
   * unchanged. Pressing twice cannot occupy two agents with one person.
   *
   * The session's `state` says what happened: {@link DeskSessionState.Queued} means they are
   * waiting and the 1801 notice is already in the transcript, {@link DeskSessionState.Assigned}
   * means an idle agent took it in the same call.
   */
  request(request: DeskRequest = {}, options?: ImRequestOptions): Promise<DeskSession> {
    return this.io.request<DeskSession>('desk.request', request, options);
  }

  /**
   * Takes a session: the named one, or the next one waiting when no id is given.
   *
   * **Agents pull; nothing is ever queued at an agent.** The empty call is the normal one — "I am
   * free, give me the next" — and a supplied id is a supervisor or an agent choosing a specific
   * customer out of the queue.
   *
   * An empty queue is `1002 NotFound`, not an empty success, so a workbench polling for work
   * should treat 1002 as "nothing waiting" rather than as an error worth showing. Being at the
   * capacity this agent declared is `1205 ConcurrencyLimitExceeded`, and that one is **not
   * retryable**: the fix is to finish a session, not to ask again.
   * 队列为空答 1002 而不是空成功；已满答 1205，而 1205 的解法是先结掉一个，不是重试。
   */
  accept(request: DeskAcceptRequest = {}, options?: ImRequestOptions): Promise<DeskSession> {
    return this.io.request<DeskSession>('desk.accept', request, options);
  }

  /**
   * Hands a session on — to a named agent, to a skill queue, or back to its own queue — carrying
   * its whole history with it.
   *
   * Exactly one target, and {@link DeskTransferRequest} is a union so the compiler says so before a
   * customer is left mid-handover. The server checks the same thing and answers `1001`.
   *
   * Only an assigned session can be transferred (`1006` otherwise), and only its holder or a
   * supervisor may (`1103`). The `note` is filed internally: the customer's transcript gets the
   * 1803 line and nothing else.
   */
  async transfer(request: DeskTransferRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('desk.transfer', request, options);
  }

  /**
   * Ends a session. Either side may: the agent when the matter is resolved, the customer when they
   * no longer need help.
   *
   * **Closing an already-closed session succeeds.** That is the server's answer, not this SDK's
   * leniency, and it is what makes a retry after a timeout safe — the alternative would be a
   * workbench showing "not found" for a session the agent just finished.
   *
   * Everything but `sessionId` is the end-of-session drawer and every field of it is optional;
   * absent means the agent did not fill it in. Note that omitting `inviteRating` **invites** —
   * see {@link DeskCloseRequest}.
   */
  async close(request: DeskCloseRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('desk.close', request, options);
  }

  /**
   * Sets this agent's availability — and renews their heartbeat by doing so.
   *
   * **Call it on a timer, not only when the agent changes status.** Availability and liveness are
   * one message on purpose: the roster drops an agent whose console has stopped saying anything and
   * requeues their sessions, which is the correct treatment for somebody who closed the lid and the
   * wrong treatment for somebody who is merely quiet. The one thing that distinguishes them is this
   * call arriving.
   * 要按心跳周期调用，而不是只在坐席切状态时调：名册会把不再说话的坐席回收并重排它的会话。
   */
  async status(request: DeskStatusRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('desk.status', request, options);
  }

  /**
   * The queue as a supervisor watches it. Takes no arguments — it is the whole desk, not one skill.
   *
   * `avgFirstResponseSeconds` is absent when nothing in the window is measurable. Render that as
   * "no data"; a 0 there reads as instant answers.
   */
  queue(options?: ImRequestOptions): Promise<DeskQueueView> {
    return this.io.request<DeskQueueView>('desk.queue', undefined, options);
  }

  /**
   * The customer rates a finished session, 1–5, in reply to the 1807 notice.
   *
   * Accepted once, only from the session's own customer, only inside the rating window — a second
   * attempt is `1006 Conflict`, and so is one that arrives after the window closed. A deployment
   * with ratings switched off answers `1203 FeatureNotEnabled` rather than accepting and discarding
   * it, so a rating sheet can tell "we are not asking" apart from "you already answered".
   */
  async rate(request: DeskRateRequest, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('desk.rate', request, options);
  }

  /**
   * The canned replies in this centre's phrasebook.
   *
   * Read-only over the socket the agent already holds; creating and editing them is a console
   * concern and stays on REST.
   *
   * **`ownerMemberId` is a filter, not a permission, and this endpoint does not narrow by
   * caller.** Omitting it lists *every* member's `personal` entries alongside the two shared
   * tiers, and naming somebody else's member id lists theirs — the server passes the value
   * straight through to the query, which only adds an owner condition when the value is present
   * and compares it against the value rather than against you. A workbench that wants the usual
   * "shared, plus mine" **must pass its own member id**; leaving it out puts a colleague's
   * private drafts on screen. The narrowing behaviour exists only on the console route
   * (`/console/v1/desks/{deskId}/canned-replies`), which rewrites the owner to the calling member
   * unless they hold `desk.supervise`.
   * ownerMemberId 是过滤参数而不是权限：服务端不按调用方收窄。省略它会返回本中心**所有成员**的
   * personal 条目，传别人的 memberId 就返回别人的。要「共享的 + 我自己的」，必须显式传自己的 memberId。
   */
  canned(request: DeskCannedRequest = {}, options?: ImRequestOptions): Promise<DeskCannedReply[]> {
    return this.io.request<DeskCannedReply[]>('desk.canned', request, options);
  }

  /**
   * Up to three model-written drafts for the session this agent holds.
   *
   * **Pull-based, and nothing here reaches the customer.** The agent edits a draft and sends it as
   * an ordinary message, or ignores all three; the difference between a copilot and an autoresponder
   * is that this call has no send in it.
   *
   * `1203 FeatureNotEnabled` when the tenant has configured no LLM — a state a workbench should
   * render as "not available on this plan" rather than as a failure — and `1005` when the model
   * did not answer, which is worth a retry the SDK deliberately does not do for you.
   */
  suggest(request: DeskSuggestRequest, options?: ImRequestOptions): Promise<string[]> {
    return this.io.request<string[]>('desk.suggest', request, options);
  }
}

/**
 * `diag.*` — this device's half of troubleshooting.
 *
 * **Ordinary applications never call these.** {@link ImClient} drives both: it asks once after
 * every connect and answers whatever is waiting. They are public because the SDK's rule is that
 * every endpoint has a typed method — a capability reachable only through `invoke()` is one a
 * support engineer cannot find — and because an application that manages its own lifecycle may want
 * to choose the moment.
 * 一般应用不会调用它们：客户端自己驱动。公开是因为本 SDK 的规矩是每个端点都有类型化方法，
 * 而只能靠 invoke() 够到的能力是支持工程师找不到的能力。
 *
 * See `ADR-003` for why the log store belongs to the integrating application.
 */
export class DiagApi {
  constructor(private readonly io: ImInvoker) {}

  /**
   * Open log requests for this device, each with a freshly signed upload target.
   *
   * **Once per connect, never on a timer.** Requests are raised by a person looking at a support
   * ticket, so the rate is at most one every few days; polling would turn a human-paced feature
   * into background traffic on every handset a tenant has.
   * 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
   */
  logRequests(options?: ImRequestOptions): Promise<PendingDeviceLog[]> {
    return this.io.request<PendingDeviceLog[]>('diag.logRequests', undefined, options);
  }

  /**
   * Reports what happened to one request — a bundle, or why there is none.
   *
   * **A refusal is an answer and must be sent.** Silence is indistinguishable from a device that
   * never received the request, and the two send a support engineer in opposite directions.
   * 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别。
   */
  async logUploaded(answer: DeviceLogAnswer, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('diag.logUploaded', answer, options);
  }
}
