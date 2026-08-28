using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cyaim.Im.ServerSdk;

/// <summary>
/// Server-side client for the IM Cloud REST API, for use from a tenant's own backend.
/// </summary>
/// <remarks>
/// This class holds the app secret and therefore must never be constructed in client code. Its
/// most important method is <see cref="IssueUserTokenAsync"/>: your backend decides who a user is,
/// mints a short-lived token for them, and the token — not the secret — is what reaches the device.
/// 本类持有 AppSecret，绝不可用于客户端。最重要的方法是签发 UserToken：由你的后端认定身份，
/// 下发到设备的是短期 token 而不是密钥。
/// </remarks>
public sealed class ImServerClient : IDisposable
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _http;
    private readonly ImServerOptions _options;
    private readonly bool _ownsHttpClient;

    public ImServerClient(ImServerOptions options, HttpClient? httpClient = null)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.BaseUrl);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.AppKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.AppSecret);

        _options = options;
        _ownsHttpClient = httpClient is null;
        _http = httpClient ?? new HttpClient();
        _http.BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + "/");
        _http.Timeout = TimeSpan.FromSeconds(options.TimeoutSeconds);
    }

    // ------------------------------------------------------------------ users

    /// <summary>
    /// Mints a token a client uses to open its WebSocket. Call this after your own login succeeds.
    /// </summary>
    public Task<TokenResult> IssueUserTokenAsync(
        string userId,
        int platform,
        int? expireSeconds = null,
        CancellationToken ct = default) =>
        PostAsync<TokenResult>($"v1/users/{Uri.EscapeDataString(userId)}/token",
            new { platform, expireSeconds }, ct);

    /// <summary>Creates or updates a user profile. Safe to call repeatedly.</summary>
    public Task<UserProfileDto> UpsertUserAsync(UserProfileDto profile, CancellationToken ct = default) =>
        PostAsync<UserProfileDto>("v1/users", profile, ct);

    /// <summary>
    /// Bulk import, for onboarding an existing user base. Sent in batches of 500.
    /// </summary>
    /// <remarks>
    /// Returns per-row outcomes rather than a count, because a batch never fails as a page: a
    /// tenant importing five hundred users typically has a handful their own database accepted and
    /// ours rejects, and knowing which three rows failed is the difference between fixing them and
    /// retrying the same page forever.
    /// 逐行返回结果而不是一个计数：批量接口不会整页失败，知道是哪几行坏了才能修，否则只会原样重试。
    /// </remarks>
    public async Task<BatchResult<UserProfileDto>> ImportUsersAsync(
        IEnumerable<UserProfileDto> profiles,
        CancellationToken ct = default)
    {
        var combined = new BatchResult<UserProfileDto>();
        var offset = 0;

        foreach (var chunk in profiles.Chunk(500))
        {
            var page = await PostAsync<BatchResult<UserProfileDto>>("v1/users:batch", new { users = chunk }, ct)
                .ConfigureAwait(false);

            // Indexes are per request; re-base them so a caller that passed one sequence can map
            // every result back to the row it submitted.
            foreach (var item in page.Items)
            {
                item.Index += offset;
                combined.Items.Add(item);
            }

            combined.SucceededCount += page.SucceededCount;
            combined.FailedCount += page.FailedCount;
            offset += chunk.Length;
        }

        return combined;
    }

    /// <summary>Invalidates every token issued for the user, forcing all their devices offline.</summary>
    public Task RevokeUserTokensAsync(string userId, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, $"v1/users/{Uri.EscapeDataString(userId)}/tokens", null, ct);

    public Task BanUserAsync(string userId, bool banned, string? reason = null, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Post, $"v1/users/{Uri.EscapeDataString(userId)}/ban",
            new { banned, reason }, ct);

    // --------------------------------------------------------------- messages

    /// <summary>
    /// Sends a message as any user, or as the system. Idempotent on <c>clientMsgId</c> — pass a
    /// deterministic one (an order id, say) and a retry after a timeout cannot double-send.
    /// </summary>
    public Task<SendResult> SendMessageAsync(SendMessageDto message, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(message);
        ArgumentException.ThrowIfNullOrWhiteSpace(message.ClientMsgId);

        return PostAsync<SendResult>("v1/messages", message, ct);
    }

    /// <summary>
    /// Sends up to 100 messages in one call, reporting each one separately. The server allocates
    /// sequence numbers in submission order, so the results come back in that order too.
    /// </summary>
    public Task<BatchResult<SendResult>> SendBatchAsync(
        IReadOnlyCollection<SendMessageDto> messages,
        CancellationToken ct = default) =>
        PostAsync<BatchResult<SendResult>>("v1/messages:batch", new { messages }, ct);

    public Task RecallMessageAsync(string conversationId, long messageId, string? reason = null, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Post, $"v1/messages/{messageId}/recall",
            new { conversationId, reason }, ct);

    // ----------------------------------------------------------------- groups

    public Task<GroupDto> CreateGroupAsync(CreateGroupDto group, CancellationToken ct = default) =>
        PostAsync<GroupDto>("v1/groups", group, ct);

    public Task AddGroupMembersAsync(string groupId, IReadOnlyCollection<string> userIds, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Post, $"v1/groups/{Uri.EscapeDataString(groupId)}/members",
            new { userIds }, ct);

    public Task RemoveGroupMembersAsync(string groupId, IReadOnlyCollection<string> userIds, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, $"v1/groups/{Uri.EscapeDataString(groupId)}/members",
            new { userIds }, ct);

    // --------------------------------------------------------------- webhooks

    /// <summary>
    /// Verifies the signature on an inbound callback. Call this before trusting a callback body:
    /// the endpoint is public, so anything that does not verify is someone else's request.
    /// 回调端点是公网可达的，验签之前收到的一切都不能当作我们发的。
    /// </summary>
    public bool VerifyCallback(string timestamp, string nonce, string signature, ReadOnlySpan<byte> body)
    {
        if (!long.TryParse(timestamp, out var sent))
        {
            return false;
        }

        var age = Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - sent);
        if (age > _options.CallbackToleranceSeconds)
        {
            return false;
        }

        var expected = ComputeSignature(timestamp, nonce, body);

        // Constant time: a byte-by-byte early exit leaks the correct prefix to anyone who can
        // measure the response.
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(expected),
            Encoding.UTF8.GetBytes(signature ?? string.Empty));
    }

    // --------------------------------------------------------------- internals

    private async Task<T> PostAsync<T>(string path, object? body, CancellationToken ct)
    {
        using var response = await SendCoreAsync(HttpMethod.Post, path, body, ct).ConfigureAwait(false);
        return await ReadAsync<T>(response, ct).ConfigureAwait(false);
    }

    private async Task SendAsync(HttpMethod method, string path, object? body, CancellationToken ct)
    {
        using var response = await SendCoreAsync(method, path, body, ct).ConfigureAwait(false);
        await ReadAsync<object?>(response, ct).ConfigureAwait(false);
    }

    private async Task<HttpResponseMessage> SendCoreAsync(HttpMethod method, string path, object? body, CancellationToken ct)
    {
        var payload = body is null ? [] : JsonSerializer.SerializeToUtf8Bytes(body, Json);
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
        var nonce = Guid.NewGuid().ToString("N");

        using var request = new HttpRequestMessage(method, path);
        if (body is not null)
        {
            request.Content = new ByteArrayContent(payload);
            request.Content.Headers.ContentType = new("application/json") { CharSet = "utf-8" };
        }

        request.Headers.TryAddWithoutValidation("X-IM-AppKey", _options.AppKey);
        request.Headers.TryAddWithoutValidation("X-IM-Timestamp", timestamp);
        request.Headers.TryAddWithoutValidation("X-IM-Nonce", nonce);
        request.Headers.TryAddWithoutValidation("X-IM-Signature", ComputeSignature(timestamp, nonce, payload));

        return await _http.SendAsync(request, ct).ConfigureAwait(false);
    }

    private string ComputeSignature(string timestamp, string nonce, ReadOnlySpan<byte> body)
    {
        var prefix = Encoding.UTF8.GetBytes(timestamp + nonce);
        var buffer = new byte[prefix.Length + body.Length];
        prefix.CopyTo(buffer);
        body.CopyTo(buffer.AsSpan(prefix.Length));

        var mac = HMACSHA256.HashData(Encoding.UTF8.GetBytes(_options.AppSecret), buffer);
        return Convert.ToBase64String(mac);
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken ct)
    {
        var envelope = await response.Content
            .ReadFromJsonAsync<ApiEnvelope<T>>(Json, ct)
            .ConfigureAwait(false);

        if (envelope is null)
        {
            throw new ImApiException((int)response.StatusCode, "empty response", null);
        }

        // The HTTP status describes the transport; `code` describes the operation. A 200 with a
        // non-zero code is a business failure and must not be mistaken for success.
        if (envelope.Code != 0)
        {
            throw new ImApiException(envelope.Code, envelope.Message ?? "request failed", envelope.TraceId);
        }

        return envelope.Data!;
    }

    public void Dispose()
    {
        if (_ownsHttpClient)
        {
            _http.Dispose();
        }
    }

    private sealed class ApiEnvelope<T>
    {
        public int Code { get; set; }

        public string? Message { get; set; }

        public string? TraceId { get; set; }

        public long ServerTime { get; set; }

        public T? Data { get; set; }
    }
}

public sealed class ImServerOptions
{
    public required string BaseUrl { get; set; }

    public required string AppKey { get; set; }

    /// <summary>Never ship this to a client. It signs requests and mints user tokens.</summary>
    public required string AppSecret { get; set; }

    public int TimeoutSeconds { get; set; } = 10;

    /// <summary>How much clock skew to tolerate when verifying an inbound callback.</summary>
    public int CallbackToleranceSeconds { get; set; } = 300;
}

/// <summary>Thrown for any non-zero business code, carrying the trace id for support tickets.</summary>
public sealed class ImApiException(int code, string message, string? traceId)
    : Exception($"IM API error {code}: {message}" + (traceId is null ? "" : $" (traceId {traceId})"))
{
    public int Code { get; } = code;

    public string? TraceId { get; } = traceId;
}

public sealed class TokenResult
{
    public string Token { get; set; } = string.Empty;

    public long ExpiresAt { get; set; }
}

/// <summary>One row's outcome inside a batch response.</summary>
public sealed class BatchItemResult<T>
{
    /// <summary>Position in the submitted array, so results map back without echoing the input.</summary>
    public int Index { get; set; }

    /// <summary>The row's natural id when it has one — a user id, a client message id.</summary>
    public string? Id { get; set; }

    public int Code { get; set; }

    public string? Message { get; set; }

    public T? Data { get; set; }

    public bool IsSuccess => Code == 0;
}

/// <summary>Per-row outcomes plus the two totals. A batch never fails as a page.</summary>
public sealed class BatchResult<T>
{
    public List<BatchItemResult<T>> Items { get; set; } = [];

    public int SucceededCount { get; set; }

    public int FailedCount { get; set; }

    /// <summary>The rows that failed, for the common "log what I could not import" case.</summary>
    public IEnumerable<BatchItemResult<T>> Failures => Items.Where(i => !i.IsSuccess);
}

public sealed class UserProfileDto
{
    public required string UserId { get; set; }

    public string? Nickname { get; set; }

    public string? Avatar { get; set; }

    public int Gender { get; set; }

    public Dictionary<string, object?>? Extensions { get; set; }
}

public sealed class SendMessageDto
{
    /// <summary>Use "@system" for a platform notification.</summary>
    public required string SenderId { get; set; }

    public string? ReceiverId { get; set; }

    public string? GroupId { get; set; }

    public string? ConversationId { get; set; }

    public int ContentType { get; set; } = 1;

    public Dictionary<string, object?> Content { get; set; } = [];

    /// <summary>Idempotency key. Make it deterministic and a retry can never double-send.</summary>
    public required string ClientMsgId { get; set; }

    public Dictionary<string, object?>? Options { get; set; }
}

public sealed class SendResult
{
    public long MessageId { get; set; }

    public long Seq { get; set; }

    public string ConversationId { get; set; } = string.Empty;

    public long CreateTime { get; set; }

    public bool Deduplicated { get; set; }
}

public sealed class CreateGroupDto
{
    public string? GroupId { get; set; }

    public required string Name { get; set; }

    public string? Avatar { get; set; }

    public required string OwnerId { get; set; }

    public List<string> MemberIds { get; set; } = [];
}

public sealed class GroupDto
{
    public string GroupId { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string OwnerId { get; set; } = string.Empty;

    public int MemberCount { get; set; }
}
