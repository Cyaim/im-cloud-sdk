import Foundation

// Answering the server when somebody asks this device for its log. See `ADR-003`.
//
// Two entrances and one exit. The entrances are a pull — `check()`, once after every connect — and
// a push, an `evt.system` frame naming this device. The exit is always the same: read the store,
// upload the bundle to the signed target the server issued, then say what happened.
//
// 两个入口、一个出口：拉取与推送进来，出去永远是「读存储、上传、答复」。

// MARK: - Wire types

/// One open log request, exactly as `diag.logRequests` returns it.
public struct PendingDeviceLog: Decodable, Sendable, Hashable {
    public var requestId: String
    public var uploadUrl: String
    /// Fields a presigned POST needs. `nil` for a presigned PUT.
    public var formFields: [String: String]?
    public var objectKey: String
    public var expiresAt: Int64
    /// Most bytes the ticket accepts. Send the newest slice rather than failing — an upload that
    /// failed outright would be recorded as "the device refused", which is the wrong sentence to
    /// put in front of whoever is waiting.
    /// 上限而不是目标：超出就发最近的一段，别整个失败——那会被记成「设备拒绝了」。
    public var maxBytes: Int64
    public var reason: String

    public init(
        requestId: String,
        uploadUrl: String,
        formFields: [String: String]? = nil,
        objectKey: String = "",
        expiresAt: Int64 = 0,
        maxBytes: Int64 = 0,
        reason: String = ""
    ) {
        self.requestId = requestId
        self.uploadUrl = uploadUrl
        self.formFields = formFields
        self.objectKey = objectKey
        self.expiresAt = expiresAt
        self.maxBytes = maxBytes
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId) ?? ""
        uploadUrl = try container.decodeIfPresent(String.self, forKey: .uploadUrl) ?? ""
        formFields = try container.decodeIfPresent([String: String].self, forKey: .formFields)
        objectKey = try container.decodeIfPresent(String.self, forKey: .objectKey) ?? ""
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        maxBytes = try container.decodeIfPresent(Int64.self, forKey: .maxBytes) ?? 0
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, uploadUrl, formFields, objectKey, expiresAt, maxBytes, reason
    }
}

/// What this device says about one request.
public struct DeviceLogAnswer: Encodable, Sendable, Hashable {
    public var requestId: String
    public var uploaded: Bool
    public var sizeBytes: Int64
    public var coveredFromMs: Int64?
    /// Whether the log covers this launch only. Decided by the SDK, never by the store.
    public var isVolatile: Bool
    public var detail: String?

    public init(
        requestId: String,
        uploaded: Bool,
        sizeBytes: Int64 = 0,
        coveredFromMs: Int64? = nil,
        isVolatile: Bool = false,
        detail: String? = nil
    ) {
        self.requestId = requestId
        self.uploaded = uploaded
        self.sizeBytes = sizeBytes
        self.coveredFromMs = coveredFromMs
        self.isVolatile = isVolatile
        self.detail = detail
    }

    // `volatile` on the wire, `isVolatile` in Swift: the former is a C keyword this language does
    // not reserve but every reviewer reads as one, and the server's field name is not ours to
    // rename. 线上是 volatile，Swift 里叫 isVolatile：服务端的字段名不归我们改。
    private enum CodingKeys: String, CodingKey {
        case requestId, uploaded, sizeBytes, coveredFromMs
        case isVolatile = "volatile"
        case detail
    }
}

// MARK: - Uploader

/// How a bundle reaches object storage. A closure so a test never touches the network.
public typealias ImDeviceLogUploader = @Sendable (PendingDeviceLog, String) async throws -> Void

/// The default uploader: a presigned POST when the ticket carries form fields, a presigned PUT
/// otherwise.
///
/// Both shapes exist because both storage backends do, and guessing wrong produces a 403 from a
/// service that will not say which of the two it wanted.
/// 两种形状都要支持：猜错得到的是一个不肯说它想要哪种的 403。
public func defaultDeviceLogUploader() -> ImDeviceLogUploader {
    { request, body in
        guard let url = URL(string: request.uploadUrl) else {
            throw ImError(code: .internalError, message: "the upload target is not a URL", target: "diag.logUploaded")
        }

        var http = URLRequest(url: url)

        if let fields = request.formFields, !fields.isEmpty {
            let boundary = "----imlog\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var payload = ""
            for (key, value) in fields {
                payload += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
            }
            payload += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; "
            payload += "filename=\"device.log\"\r\nContent-Type: text/plain\r\n\r\n\(body)\r\n--\(boundary)--\r\n"

            http.httpMethod = "POST"
            http.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            http.httpBody = payload.data(using: .utf8)
        } else {
            http.httpMethod = "PUT"
            http.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            http.httpBody = body.data(using: .utf8)
        }

        let (_, response) = try await URLSession.shared.data(for: http)

        if let status = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) {
            throw ImError(code: .internalError, message: "upload rejected with \(status)", target: "diag.logUploaded")
        }
    }
}

// MARK: - Runner

actor ImDeviceLogs {
    private let connection: ImConnection
    private let log: ImLogRecorder
    private let deviceId: String
    private let upload: ImDeviceLogUploader

    /// Requests already answered in this launch, so a pull after a push does not upload twice.
    private var answered: Set<String> = []

    init(
        connection: ImConnection,
        log: ImLogRecorder,
        deviceId: String,
        upload: @escaping ImDeviceLogUploader = defaultDeviceLogUploader()
    ) {
        self.connection = connection
        self.log = log
        self.deviceId = deviceId
        self.upload = upload
    }

    /// Asks whether anything is waiting, and fulfils whatever is.
    ///
    /// **Once per connect, never on a timer.** Requests are raised by a person looking at a support
    /// ticket, so the rate is at most one every few days; polling would turn a human-paced feature
    /// into background traffic on every handset a tenant has.
    /// 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
    func check() async {
        let pending: [PendingDeviceLog]

        do {
            pending = try await connection.request("diag.logRequests", as: [PendingDeviceLog].self)
        } catch {
            // A server that will not answer this must not stop a client from chatting. Logged into
            // our own store, which is the right place for it: the next successful pull carries this
            // line up with it.
            // 服务端不答复不能挡住聊天：记进我们自己的存储，下一次成功的拉取会把它带上去。
            await log.write("warn", "diag.logRequests failed: \(error)")
            return
        }

        for request in pending {
            await fulfil(request)
        }
    }

    /// Handles an `evt.system` frame. Ignores anything that is not a log request for this device.
    ///
    /// Delivery is per user rather than per device, so every device of theirs sees the frame and
    /// exactly one should answer.
    /// 投递是按用户而不是按设备的：他的每一台设备都会看到，而应当只有一台回答。
    func onSystemEvent(_ data: JSONValue?) async {
        guard case let .object(root)? = data,
              case let .string(event)? = root["event"], event == "device.logRequest",
              case let .object(payload)? = root["body"]
        else {
            return
        }

        if case let .string(target)? = payload["deviceId"], target != deviceId {
            return
        }

        var fields: [String: String]?
        if case let .object(raw)? = payload["formFields"] {
            fields = raw.compactMapValues { value in
                if case let .string(text) = value { return text }
                return nil
            }
        }

        await fulfil(
            PendingDeviceLog(
                requestId: payload["requestId"]?.stringValue ?? "",
                uploadUrl: payload["uploadUrl"]?.stringValue ?? "",
                formFields: fields,
                objectKey: payload["objectKey"]?.stringValue ?? "",
                expiresAt: payload["expiresAt"]?.intValue ?? 0,
                maxBytes: payload["maxBytes"]?.intValue ?? 0,
                reason: payload["reason"]?.stringValue ?? ""
            )
        )
    }

    private func fulfil(_ request: PendingDeviceLog) async {
        // Claimed before the work rather than after it. Two entrances can deliver the same request
        // within milliseconds — a push arriving while a pull is in flight — and claiming late would
        // upload the same bundle twice and answer twice.
        // 先认领再干活：两个入口可能在几毫秒内送来同一条，晚认领会上传两次、答复两次。
        guard !request.requestId.isEmpty, answered.insert(request.requestId).inserted else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if request.expiresAt > 0, now >= request.expiresAt {
            // Not answered at all. The ticket is dead, so an upload would fail and a refusal would
            // put "the device could not do it" on a row whose real state is "nobody asked in time".
            // 完全不答复：报「设备做不到」会写在一条真实状态是「没人及时问」的行上。
            await log.write("warn", "device-log request \(request.requestId) arrived after its window closed")
            return
        }

        let lines = await log.read()

        // Trimmed from the front, keeping the newest: the failure being investigated is at the end
        // of the log, and dropping the tail to fit would remove the only part anybody asked for.
        // 从前面裁、保留最新：故障在末尾，为了塞下丢掉尾巴，丢的正是唯一有人要的那段。
        var kept = lines
        var body = renderLogBundle(kept)
        if request.maxBytes > 0 {
            while !kept.isEmpty, Int64(body.utf8.count) > request.maxBytes {
                kept = Array(kept.suffix(max(1, kept.count / 2)))
                body = renderLogBundle(kept)
            }
        }

        do {
            try await upload(request, body)
        } catch {
            await tell(
                DeviceLogAnswer(
                    requestId: request.requestId,
                    uploaded: false,
                    isVolatile: log.isVolatile,
                    detail: "upload failed: \(error)"
                )
            )
            return
        }

        await tell(
            DeviceLogAnswer(
                requestId: request.requestId,
                uploaded: true,
                sizeBytes: Int64(body.utf8.count),
                coveredFromMs: kept.first?.t,
                isVolatile: log.isVolatile
            )
        )

        // Cleared only after the server has been told. Clearing first and then failing to report
        // would destroy the evidence and leave the row saying nothing arrived.
        // 只有在告诉服务端之后才清空：先清再失败，会毁掉证据而记录上写着什么都没到。
        await log.clear()
    }

    private func tell(_ answer: DeviceLogAnswer) async {
        do {
            try await connection.execute("diag.logUploaded", body: answer)
        } catch {
            // The upload may well have succeeded; the row will expire saying nothing arrived.
            // Logged so the next bundle carries the explanation, which is the best this side can do.
            // 上传很可能成功了，而那一行会以「什么都没到」过期。记下来，让下一份日志带上解释。
            await log.write("warn", "diag.logUploaded failed for \(answer.requestId): \(error)")
        }
    }
}
