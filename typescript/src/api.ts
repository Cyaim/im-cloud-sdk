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
  BlockEntry,
  BlockRequest,
  ConversationIdRequest,
  ConversationView,
  CreateGroupRequest,
  CursorRequest,
  DeleteMessagesRequest,
  DownloadUrlRequest,
  EditMessageRequest,
  ForwardMessagesRequest,
  Friend,
  FriendRequest,
  FriendRequestListRequest,
  Group,
  GroupCursorRequest,
  GroupIdRequest,
  GroupMember,
  GroupMembersRequest,
  HandleFriendRequest,
  HeartbeatResult,
  HistoryRequest,
  ImMessage,
  JoinGroupRequest,
  ListConversationsRequest,
  MediaUploadTicket,
  PresenceState,
  PushClickedRequest,
  PushProvider,
  ReactRequest,
  ReadRequest,
  ReauthRequest,
  RecallMessageRequest,
  ReceiptRequest,
  RegisterPushTokenRequest,
  ReportReceipt,
  ResumeRequest,
  ResumeResult,
  SendMessageRequest,
  SendMessageResult,
  SubmitReportRequest,
  SubscribePresenceRequest,
  SyncMessagesRequest,
  SyncMessagesResult,
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
}

/** `group.*` — the core ten. Administration (roles, mute, announcements) is T3. */
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
  requests(options?: ImRequestOptions): Promise<PendingDeviceLog[]> {
    return this.io.request<PendingDeviceLog[]>('diag.logRequests', undefined, options);
  }

  /**
   * Reports what happened to one request — a bundle, or why there is none.
   *
   * **A refusal is an answer and must be sent.** Silence is indistinguishable from a device that
   * never received the request, and the two send a support engineer in opposite directions.
   * 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别。
   */
  async uploaded(answer: DeviceLogAnswer, options?: ImRequestOptions): Promise<void> {
    await this.io.request<void>('diag.logUploaded', answer, options);
  }
}
