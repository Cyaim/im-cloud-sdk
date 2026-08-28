using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>How a log bundle reaches object storage. Injected so a test never touches the network.</summary>
    public delegate Task ImDeviceLogUploader(
        ImPendingDeviceLog request,
        string body,
        CancellationToken cancellationToken);

    /// <summary>
    /// Answering the server when somebody asks this device for its log. See <c>ADR-003</c>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Two entrances and one exit. The entrances are a pull — <see cref="CheckAsync"/>, once after
    /// every connect — and a push, an <c>evt.system</c> frame naming this device. The exit is always
    /// the same: read the store, upload the bundle to the signed target, then say what happened.
    /// 两个入口、一个出口：拉取与推送进来，出去永远是「读存储、上传、答复」。
    /// </para>
    /// <para>
    /// <b>Nothing here is allowed to break a session.</b> Every failure is recorded into the log this
    /// very class uploads, and the next successful bundle carries the explanation.
    /// 这里的任何失败都不能弄坏一次会话：它们被记进这个类自己要上传的那份日志里。
    /// </para>
    /// </remarks>
    internal sealed class ImDeviceLogs
    {
        private readonly ImDiagApi _diag;
        private readonly ImLogRecorder _log;
        private readonly string _deviceId;
        private readonly ImDeviceLogUploader _upload;
        private readonly Func<long> _now;

        /// <summary>Requests already answered in this process, so a pull after a push does not upload twice.</summary>
        private readonly HashSet<string> _answered = new HashSet<string>(StringComparer.Ordinal);

        internal ImDeviceLogs(
            ImDiagApi diag,
            ImLogRecorder log,
            string deviceId,
            ImDeviceLogUploader upload = null,
            Func<long> now = null)
        {
            _diag = diag;
            _log = log;
            _deviceId = deviceId ?? string.Empty;
            _upload = upload ?? DefaultUploader;
            _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }

        /// <summary>Asks whether anything is waiting, and fulfils whatever is.</summary>
        internal async Task CheckAsync(CancellationToken cancellationToken = default)
        {
            List<ImPendingDeviceLog> pending;

            try
            {
                pending = await _diag.LogRequestsAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception failure)
            {
                // A server that will not answer this must not stop a client from chatting. Logged
                // into our own store, which is the right place for it: the next successful pull
                // carries this line up with it.
                // 服务端不答复不能挡住聊天：记进我们自己的存储，下一次成功的拉取会把它带上去。
                _log.Warn("diag.logRequests failed: " + failure.Message);
                return;
            }

            for (var i = 0; i < pending.Count; i++)
            {
                await FulfilAsync(pending[i], cancellationToken).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// Handles an <c>evt.system</c> frame. Ignores anything that is not a log request for this
        /// device.
        /// </summary>
        /// <remarks>
        /// Delivery is per user rather than per device, so every device of theirs sees the frame and
        /// exactly one should answer.
        /// 投递是按用户而不是按设备的：他的每一台设备都会看到，而应当只有一台回答。
        /// </remarks>
        internal async Task OnSystemEventAsync(JsonValue data, CancellationToken cancellationToken = default)
        {
            if (!data.IsObject || data["event"].AsString(string.Empty) != "device.logRequest")
            {
                return;
            }

            var payload = data["body"];
            if (!payload.IsObject)
            {
                return;
            }

            var target = payload["deviceId"].AsString(string.Empty);
            if (!string.IsNullOrEmpty(target) && !string.Equals(target, _deviceId, StringComparison.Ordinal))
            {
                return;
            }

            await FulfilAsync(ImPayload.Read<ImPendingDeviceLog>(payload), cancellationToken).ConfigureAwait(false);
        }

        private async Task FulfilAsync(ImPendingDeviceLog request, CancellationToken cancellationToken)
        {
            // Claimed before the work rather than after it. Two entrances can deliver the same
            // request within milliseconds — a push arriving while a pull is in flight — and claiming
            // late would upload the same bundle twice and answer twice.
            // 先认领再干活：两个入口可能在几毫秒内送来同一条，晚认领会上传两次、答复两次。
            if (request == null || string.IsNullOrEmpty(request.RequestId))
            {
                return;
            }

            lock (_answered)
            {
                if (!_answered.Add(request.RequestId))
                {
                    return;
                }
            }

            if (request.ExpiresAt > 0 && _now() >= request.ExpiresAt)
            {
                // Not answered at all. The ticket is dead, so an upload would fail and a refusal
                // would put "the device could not do it" on a row whose real state is "nobody asked
                // in time".
                // 完全不答复：报「设备做不到」会写在一条真实状态是「没人及时问」的行上。
                _log.Warn("device-log request " + request.RequestId + " arrived after its window closed");
                return;
            }

            var lines = _log.Read();

            // Trimmed from the front, keeping the newest: the failure being investigated is at the
            // end of the log, and dropping the tail to fit would remove the only part anybody asked
            // for.
            // 从前面裁、保留最新：故障在末尾，为了塞下丢掉尾巴，丢的正是唯一有人要的那段。
            var kept = lines;
            var body = ImLogRecorder.RenderBundle(kept);

            if (request.MaxBytes > 0)
            {
                while (kept.Count > 0 && Encoding.UTF8.GetByteCount(body) > request.MaxBytes)
                {
                    var keep = Math.Max(1, kept.Count / 2);
                    var trimmed = new ImLogLine[keep];
                    for (var i = 0; i < keep; i++)
                    {
                        trimmed[i] = kept[kept.Count - keep + i];
                    }

                    kept = trimmed;
                    body = ImLogRecorder.RenderBundle(kept);
                }
            }

            try
            {
                await _upload(request, body, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception failure)
            {
                await TellAsync(
                    new ImDeviceLogAnswer
                    {
                        RequestId = request.RequestId,
                        Uploaded = false,
                        Volatile = _log.IsVolatile,
                        Detail = "upload failed: " + failure.Message,
                    },
                    cancellationToken).ConfigureAwait(false);

                return;
            }

            await TellAsync(
                new ImDeviceLogAnswer
                {
                    RequestId = request.RequestId,
                    Uploaded = true,
                    SizeBytes = Encoding.UTF8.GetByteCount(body),
                    CoveredFromMs = kept.Count > 0 ? kept[0].T : (long?)null,
                    Volatile = _log.IsVolatile,
                },
                cancellationToken).ConfigureAwait(false);

            // Cleared only after the server has been told. Clearing first and then failing to report
            // would destroy the evidence and leave the row saying nothing arrived.
            // 只有在告诉服务端之后才清空：先清再失败，会毁掉证据而记录上写着什么都没到。
            _log.Clear();
        }

        private async Task TellAsync(ImDeviceLogAnswer answer, CancellationToken cancellationToken)
        {
            try
            {
                await _diag.LogUploadedAsync(answer, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception failure)
            {
                // The upload may well have succeeded; the row will expire saying nothing arrived.
                // Logged so the next bundle carries the explanation, which is the best this side can
                // do.
                // 上传很可能成功了，而那一行会以「什么都没到」过期。记下来，让下一份日志带上解释。
                _log.Warn("diag.logUploaded failed for " + answer.RequestId + ": " + failure.Message);
            }
        }

        /// <summary>
        /// A presigned POST when the ticket carries form fields, a presigned PUT otherwise.
        /// </summary>
        /// <remarks>
        /// Both shapes exist because both object-storage backends do, and guessing wrong produces a
        /// 403 from a service that will not say which of the two it wanted.
        /// 两种形状都要支持：猜错得到的是一个不肯说它想要哪种的 403。
        /// </remarks>
        private static async Task DefaultUploader(
            ImPendingDeviceLog request,
            string body,
            CancellationToken cancellationToken)
        {
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) })
            {
                HttpResponseMessage response;

                if (request.FormFields == null || request.FormFields.Count == 0)
                {
                    var content = new StringContent(body, Encoding.UTF8, "text/plain");
                    response = await http.PutAsync(request.UploadUrl, content, cancellationToken)
                        .ConfigureAwait(false);
                }
                else
                {
                    var form = new MultipartFormDataContent();
                    foreach (var pair in request.FormFields)
                    {
                        form.Add(new StringContent(pair.Value ?? string.Empty), pair.Key);
                    }

                    var file = new StringContent(body, Encoding.UTF8, "text/plain");
                    file.Headers.ContentType = new MediaTypeHeaderValue("text/plain");
                    form.Add(file, "file", "device.log");

                    response = await http.PostAsync(request.UploadUrl, form, cancellationToken)
                        .ConfigureAwait(false);
                }

                using (response)
                {
                    if (!response.IsSuccessStatusCode)
                    {
                        throw new InvalidOperationException(
                            "upload rejected with "
                            + ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture));
                    }
                }
            }
        }
    }
}
