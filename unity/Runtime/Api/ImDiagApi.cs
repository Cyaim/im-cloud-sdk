using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>diag.*</c> — this device's half of troubleshooting.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Ordinary games never call these.</b> <see cref="ImClient"/> drives both: it asks once after
    /// every connect and answers whatever is waiting. They are typed because this SDK's rule is that
    /// every endpoint has a typed method — a capability reachable only through a raw invoke is one a
    /// support engineer cannot find.
    /// 一般游戏不会调用它们：客户端自己驱动。类型化是因为「每个端点都有类型化方法」是本 SDK 的规矩。
    /// </para>
    /// <para>
    /// See <c>ADR-003</c> for why the log store belongs to the integrating game, and
    /// <see cref="IImLogStore"/> for what a studio who supplies none still gets.
    /// </para>
    /// </remarks>
    public sealed class ImDiagApi : ImApiNamespace
    {
        internal ImDiagApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Open log requests for this device, each with a freshly signed upload target.
        /// </summary>
        /// <remarks>
        /// <b>Once per connect, never on a timer.</b> Requests are raised by a person looking at a
        /// support ticket, so the rate is at most one every few days; polling would turn a
        /// human-paced feature into background traffic on every device a tenant has.
        /// 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
        /// </remarks>
        public Task<List<ImPendingDeviceLog>> LogRequestsAsync(CancellationToken cancellationToken = default)
        {
            return RequestListAsync<ImPendingDeviceLog>("diag.logRequests", null, cancellationToken);
        }

        /// <summary>
        /// Reports what happened to one request — a bundle, or why there is none.
        /// </summary>
        /// <remarks>
        /// <b>A refusal is an answer and must be sent.</b> Silence is indistinguishable from a device
        /// that never received the request, and the two send a support engineer in opposite
        /// directions: wait for the player to open the game, or look at why this build cannot comply.
        /// 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别，而两者要查的方向相反。
        /// </remarks>
        public Task LogUploadedAsync(ImDeviceLogAnswer answer, CancellationToken cancellationToken = default)
        {
            if (answer == null)
            {
                throw new ArgumentNullException(nameof(answer));
            }

            return ExecuteAsync("diag.logUploaded", answer, cancellationToken);
        }
    }

    /// <summary>One open log request, exactly as <c>diag.logRequests</c> returns it.</summary>
    public sealed class ImPendingDeviceLog : IImJsonPayload
    {
        /// <summary>Our own id for the request, and the idempotency key on the answer.</summary>
        public string RequestId { get; internal set; }

        /// <summary>Where to write the bundle. Signed and short-lived.</summary>
        public string UploadUrl { get; internal set; }

        /// <summary>Fields a presigned POST needs. Empty for a presigned PUT.</summary>
        public Dictionary<string, string> FormFields { get; internal set; }

        public string ObjectKey { get; internal set; }

        /// <summary>After this the ticket is dead and the request has expired.</summary>
        public long ExpiresAt { get; internal set; }

        /// <summary>
        /// Most bytes the ticket accepts. Send the newest slice rather than failing — an upload that
        /// failed outright would be recorded as "the device refused", which is the wrong sentence to
        /// put in front of whoever is waiting.
        /// 上限而不是目标：超出就发最近的一段，别整个失败——那会被记成「设备拒绝了」。
        /// </summary>
        public long MaxBytes { get; internal set; }

        /// <summary>What the operator wrote when they asked. Never shown to the player.</summary>
        public string Reason { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            RequestId = json["requestId"].AsString(string.Empty);
            UploadUrl = json["uploadUrl"].AsString(string.Empty);
            ObjectKey = json["objectKey"].AsString(string.Empty);
            ExpiresAt = json["expiresAt"].AsLong();
            MaxBytes = json["maxBytes"].AsLong();
            Reason = json["reason"].AsString(string.Empty);

            var fields = json["formFields"];
            if (fields.IsObject)
            {
                FormFields = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var pair in fields.Members)
                {
                    FormFields[pair.Key] = pair.Value.AsString(string.Empty);
                }
            }
        }
    }

    /// <summary>What this device says about one request.</summary>
    public sealed class ImDeviceLogAnswer : IImRequest
    {
        public string RequestId { get; set; }

        public bool Uploaded { get; set; }

        public long SizeBytes { get; set; }

        /// <summary>
        /// The earliest moment the bundle covers, or null when there is no bundle.
        /// </summary>
        /// <remarks>
        /// Not decoration: a three-minute log and a seven-day log look identical on the console, and
        /// reading the first as the second is how somebody concludes nothing went wrong.
        /// 不是装饰：三分钟与七天的日志长得一模一样，把前者读成后者正是有人得出「什么都没发生」的过程。
        /// </remarks>
        public long? CoveredFromMs { get; set; }

        /// <summary>Whether the log covers this process only. Decided by the SDK, never by the store.</summary>
        public bool Volatile { get; set; }

        /// <summary>Why it could not be done, when it could not.</summary>
        public string Detail { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var json = JsonValue.NewObject()
                .Set("requestId", RequestId)
                .Set("uploaded", Uploaded)
                .Set("sizeBytes", SizeBytes)
                .Set("volatile", Volatile);

            if (CoveredFromMs.HasValue)
            {
                json = json.Set("coveredFromMs", CoveredFromMs.Value);
            }

            if (!string.IsNullOrEmpty(Detail))
            {
                json = json.Set("detail", Detail);
            }

            return json;
        }
    }
}
