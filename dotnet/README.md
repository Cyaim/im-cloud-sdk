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

## Errors

Any non-zero business code throws `ImApiException` carrying `Code` and `TraceId`. The trace id is
worth logging: it identifies the exact request end to end and is what a support ticket should quote.

Note that a `200 OK` with a non-zero `code` is a **business failure**, not a success — the SDK
raises it as an exception so it cannot be silently ignored.
