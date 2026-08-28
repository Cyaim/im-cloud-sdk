package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import java.net.HttpURLConnection
import java.net.URI

/**
 * One open log request, exactly as `diag.logRequests` returns it.
 *
 * @property maxBytes most bytes the ticket accepts. A device holding more sends its newest slice
 * rather than failing: an upload that failed outright would be recorded as "the device refused",
 * which is the wrong sentence to put in front of whoever is waiting.
 * 上限而不是目标：超出就发最近的一段，别整个失败——那会被记成「设备拒绝了」。
 */
@Serializable
public data class PendingDeviceLog(
    public val requestId: String,
    public val uploadUrl: String,
    public val formFields: Map<String, String>? = null,
    public val objectKey: String = "",
    public val expiresAt: Long = 0,
    public val maxBytes: Long = 0,
    public val reason: String = "",
)

/** What this device says about one request. */
@Serializable
public data class DeviceLogAnswer(
    public val requestId: String,
    public val uploaded: Boolean,
    public val sizeBytes: Long = 0,
    public val coveredFromMs: Long? = null,
    /** Whether the log covers this process only. Decided by the SDK, never by the store. */
    public val volatile: Boolean = false,
    public val detail: String? = null,
)

/**
 * `diag.*` — this device's half of troubleshooting.
 *
 * **Ordinary applications never call these.** [ImClient] drives both: it asks once after every
 * connect and answers whatever is waiting. They are public because this SDK's rule is that every
 * endpoint has a typed method — a capability reachable only through a raw invoke is one a support
 * engineer cannot find.
 * 一般应用不会调用它们：客户端自己驱动。公开是因为「每个端点都有类型化方法」是本 SDK 的规矩。
 *
 * See `ADR-003` for why the log store belongs to the integrating application.
 */
public class DiagApi internal constructor(private val connection: ImConnection) {
    /**
     * Open log requests for this device, each with a freshly signed upload target.
     *
     * **Once per connect, never on a timer.** Requests are raised by a person looking at a support
     * ticket, so the rate is at most one every few days; polling would turn a human-paced feature
     * into background traffic on every handset a tenant has.
     * 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
     */
    public suspend fun requests(): List<PendingDeviceLog> =
        connection.request("diag.logRequests", null)

    /**
     * Reports what happened to one request — a bundle, or why there is none.
     *
     * **A refusal is an answer and must be sent.** Silence is indistinguishable from a device that
     * never received the request, and the two send a support engineer in opposite directions: wait
     * for the customer to open the app, or look at why this build cannot comply.
     * 拒绝也是一种答复，必须发出去：沉默与「根本没收到」分不出区别，而两者要查的方向相反。
     */
    public suspend fun uploaded(answer: DeviceLogAnswer) {
        connection.execute("diag.logUploaded", answer.asBody())
    }
}

/** How a bundle reaches object storage. Injected so a test never touches the network. */
public fun interface DeviceLogUploader {
    public fun upload(request: PendingDeviceLog, body: String)
}

/**
 * The default uploader: a presigned POST when the ticket carries form fields, a presigned PUT
 * otherwise.
 *
 * Both shapes exist because both storage backends do, and guessing wrong produces a 403 from a
 * service that will not say which of the two it wanted.
 * 两种形状都要支持：猜错得到的是一个不肯说它想要哪种的 403。
 */
internal class HttpDeviceLogUploader : DeviceLogUploader {
    override fun upload(request: PendingDeviceLog, body: String) {
        val fields = request.formFields

        if (fields.isNullOrEmpty()) {
            send(request.uploadUrl, "PUT", "text/plain; charset=utf-8", body.toByteArray())
            return
        }

        val boundary = "----imlog" + java.util.UUID.randomUUID().toString().replace("-", "")
        val payload = buildString {
            for ((key, value) in fields) {
                append("--").append(boundary).append("\r\n")
                append("Content-Disposition: form-data; name=\"").append(key).append("\"\r\n\r\n")
                append(value).append("\r\n")
            }
            append("--").append(boundary).append("\r\n")
            append("Content-Disposition: form-data; name=\"file\"; filename=\"device.log\"\r\n")
            append("Content-Type: text/plain\r\n\r\n")
            append(body).append("\r\n")
            append("--").append(boundary).append("--\r\n")
        }

        send(request.uploadUrl, "POST", "multipart/form-data; boundary=$boundary", payload.toByteArray())
    }

    private fun send(url: String, method: String, contentType: String, body: ByteArray) {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", contentType)
            connection.connectTimeout = 15_000
            connection.readTimeout = 60_000
            connection.outputStream.use { it.write(body) }

            val status = connection.responseCode
            if (status !in 200..299) {
                throw IllegalStateException("upload rejected with $status")
            }
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * Answering the server when somebody asks this device for its log.
 *
 * Two entrances and one exit. The entrances are a pull — [check], once after every connect — and a
 * push, an `evt.system` frame naming this device. The exit is always the same: read the store,
 * upload to the signed target, then say what happened.
 * 两个入口、一个出口：拉取与推送进来，出去永远是「读存储、上传、答复」。
 */
internal class ImDeviceLogs(
    private val diag: DiagApi,
    private val log: ImLog,
    private val deviceId: String,
    private val uploader: DeviceLogUploader = HttpDeviceLogUploader(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** Requests already answered in this process, so a pull after a push does not upload twice. */
    private val answered = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    suspend fun check() {
        val pending =
            try {
                diag.requests()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                // A server that will not answer this must not stop a client from chatting. Logged
                // into our own store, which is the right place for it: the next successful pull
                // carries this line up with it.
                // 服务端不答复不能挡住聊天：记进我们自己的存储，下一次成功的拉取会把这一行带上去。
                log.write(ImLogLevel.Warn, "diag.logRequests failed", failure)
                return
            }

        for (request in pending) {
            fulfil(request)
        }
    }

    /**
     * Handles an `evt.system` frame. Ignores anything that is not a log request for this device.
     *
     * Delivery is per user rather than per device, so every device of theirs sees the frame and
     * exactly one should answer.
     * 投递是按用户而不是按设备的：他的每一台设备都会看到，而应当只有一台回答。
     */
    suspend fun onSystemEvent(body: kotlinx.serialization.json.JsonElement?) {
        val root = body as? kotlinx.serialization.json.JsonObject ?: return
        val event = (root["event"] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
        if (event != "device.logRequest") return

        val payload = root["body"] as? kotlinx.serialization.json.JsonObject ?: return
        val target = (payload["deviceId"] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
        if (target != null && target != deviceId) return

        val request =
            try {
                ImJson.decodeFromJsonElement(PendingDeviceLog.serializer(), payload)
            } catch (failure: Throwable) {
                log.write(ImLogLevel.Warn, "could not decode a device-log request", failure)
                return
            }

        fulfil(request)
    }

    private suspend fun fulfil(request: PendingDeviceLog) {
        // Claimed before the work rather than after it. Two entrances can deliver the same request
        // within milliseconds — a push arriving while a pull is in flight — and claiming late would
        // upload the same bundle twice and answer twice.
        // 先认领再干活：两个入口可能在几毫秒内送来同一条，晚认领会上传两次、答复两次。
        if (request.requestId.isBlank() || !answered.add(request.requestId)) return

        if (request.expiresAt > 0 && now() >= request.expiresAt) {
            // Not answered at all. The ticket is dead, so an upload would fail and a refusal would
            // put "the device could not do it" on a row whose real state is "nobody asked in time".
            // 完全不答复：报「设备做不到」会写在一条真实状态是「没人及时问」的行上。
            log.write(ImLogLevel.Warn, "device-log request ${request.requestId} arrived after its window closed")
            return
        }

        val lines = log.read()

        // Trimmed from the front, keeping the newest: the failure being investigated is at the end
        // of the log, and dropping the tail to fit would remove the only part anybody asked for.
        // 从前面裁、保留最新：故障在末尾，为了塞下丢掉尾巴，丢的正是唯一有人要的那段。
        var kept = lines
        var body = renderLogBundle(kept)
        if (request.maxBytes > 0) {
            while (kept.isNotEmpty() && body.toByteArray().size > request.maxBytes) {
                kept = kept.subList(kept.size - maxOf(1, kept.size / 2), kept.size)
                body = renderLogBundle(kept)
            }
        }

        try {
            uploader.upload(request, body)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            tell(
                DeviceLogAnswer(
                    requestId = request.requestId,
                    uploaded = false,
                    volatile = log.isVolatile,
                    detail = "upload failed: ${failure.message ?: failure::class.simpleName}",
                ),
            )
            return
        }

        tell(
            DeviceLogAnswer(
                requestId = request.requestId,
                uploaded = true,
                sizeBytes = body.toByteArray().size.toLong(),
                coveredFromMs = kept.firstOrNull()?.t,
                volatile = log.isVolatile,
            ),
        )

        // Cleared only after the server has been told. Clearing first and then failing to report
        // would destroy the evidence and leave the row saying nothing arrived.
        // 只有在告诉服务端之后才清空：先清再失败，会毁掉证据而记录上写着什么都没到。
        log.clear()
    }

    private suspend fun tell(answer: DeviceLogAnswer) {
        try {
            diag.uploaded(answer)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            // The upload may well have succeeded; the row will expire saying nothing arrived.
            // Logged so the next bundle carries the explanation, which is the best this side can do.
            // 上传很可能成功了，而那一行会以「什么都没到」过期。记下来，让下一份日志带上解释。
            log.write(ImLogLevel.Warn, "diag.logUploaded failed for ${answer.requestId}", failure)
        }
    }
}

private val kotlinx.serialization.json.JsonPrimitive.contentOrNull: String?
    get() = if (isString) content else null
