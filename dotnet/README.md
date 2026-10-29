# Cyaim.Im.ServerSdk

Server-side SDK for Cyaim IM Cloud, for use from a **tenant's own backend**. Targets net8.0 / net9.0 / net10.0.

> This package holds your `AppSecret`. It signs requests and mints user tokens. It must never be
> referenced from a mobile app, a desktop app, or browser code.
> 本包持有 AppSecret，用于签名与签发用户 token，**绝不可**被客户端引用。

## The one call that matters

```csharp
var im = new ImServerClient(new ImServerOptions
{
    BaseUrl   = "https://api.im.example.com",
    AppKey    = configuration["Im:AppKey"]!,
    AppSecret = configuration["Im:AppSecret"]!,
});

// After YOUR login succeeds, mint a short-lived token for the device.
var token = await im.IssueUserTokenAsync(userId: user.Id, platform: 1 /* iOS */);
return Ok(new { token.Token, token.ExpiresAt });
```

Your backend decides who a user is; the IM service decides how their messages move. The token — not
the secret — is what reaches the device. This is the same split as Tencent Cloud's UserSig and
Easemob's token, so migrating from either is a change of one method call.

## Sending as the system

```csharp
await im.SendMessageAsync(new SendMessageDto
{
    SenderId    = "@system",
    ReceiverId  = user.Id,
    ContentType = 9,                       // Notification
    Content     = new() { ["code"] = 2001, ["data"] = new { orderId } },
    // Deterministic, so a retry after a timeout cannot double-send.
    ClientMsgId = $"order-shipped-{orderId}",
    Options     = new()
    {
        ["pushConfig"] = new { title = "订单更新", body = "你的订单已发货" },
    },
});
```

`ClientMsgId` is the idempotency key. Derive it from your own domain (an order id, an event id) and
retries become free. Every send — client, server, system notification — goes down the same pipeline,
so they all get the same ordering, the same sequence numbers and the same delivery guarantees.

## Verifying callbacks

```csharp
app.MapPost("/im-callback", async (HttpContext ctx, ImServerClient im) =>
{
    ctx.Request.EnableBuffering();
    using var ms = new MemoryStream();
    await ctx.Request.Body.CopyToAsync(ms);

    var ok = im.VerifyCallback(
        ctx.Request.Headers["X-IM-Timestamp"]!,
        ctx.Request.Headers["X-IM-Nonce"]!,
        ctx.Request.Headers["X-IM-Signature"]!,
        ms.ToArray());

    if (!ok) return Results.Unauthorized();

    // before.message.send may veto or rewrite:
    return Results.Ok(new { allow = true });
});
```

The callback endpoint is reachable from the internet, so anything that fails verification is
someone else's request. `VerifyCallback` compares in constant time and rejects stale timestamps.

## Single-chat ids

A single chat's id is fixed by its two users, so a call that names a conversation — a recall, a send
by `ConversationId` — can build it from them alone:

```csharp
ImServerClient.SingleConversationId("bob", "alice");     // "s_alice_bob"
ImServerClient.SingleConversationId("u_alice", "u_bob"); // "s_u~1alice_u~1bob"
```

The rule is `"s_" + enc(A) + "_" + enc(B)`: the two **raw** user ids in UTF-16 ordinal order, each
with `~` written `~0` and `_` written `~1`, so the one `_` after the prefix is the separator and every
id names exactly one pair. Which end you pass first does not matter. **Do not join the ids
yourself**: `$"s_{a}_{b}"` is right only while neither id contains `_` or `~`; past that, the id it
gives is malformed (the server answers 1001) or names a different pair. The rule is shared with the
server and the client SDKs through `single-chat-id-vectors.json` at the root of the SDK repository.

## Errors

Any non-zero business code throws `ImApiException` carrying `Code` and `TraceId`. The trace id is
worth logging: it identifies the exact request end to end and is what a support ticket should quote.

Note that a `200 OK` with a non-zero `code` is a **business failure**, not a success — the SDK
raises it as an exception so it cannot be silently ignored.

A reply with **no envelope at all** — a proxy's error page, a bare 404 from a path that did not
match — throws with `Code` 0 and the HTTP status in `HttpStatus`. There is no business code to
report, and putting the status in its place would read as one of ours.

## Sharing an HttpClient

Pass one in (for example from `IHttpClientFactory`) and it is used as given: the client never
writes its `BaseAddress` or `Timeout`. Requests go to `BaseUrl`, and `TimeoutSeconds` applies per
request whoever owns the client.

## Importing users

`ImportUsersAsync` sends batches of 500 and returns one row per profile, in the order you passed
them: `Code` 0 with the imported user id in `Data`, or the code and message that refused that row.
Fix the rows in `Failures` and send only those again.
