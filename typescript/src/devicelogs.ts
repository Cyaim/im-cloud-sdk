/**
 * Answering the server when somebody asks this device for its log.
 *
 * The flow has two entrances and one exit. The entrances are a pull — {@link ImDeviceLogs.check},
 * called once after every connect — and a push, an `evt.system` frame naming this device. The exit
 * is always the same: read the store, upload the bundle to the signed target the server issued,
 * then say what happened with `diag.logUploaded`.
 *
 * 两个入口、一个出口：拉取（每次连接后一次）与推送（evt.system 指名本设备），
 * 而出口永远是同一个——读存储、上传到服务端签好的目标、再答复发生了什么。
 *
 * **A refusal is an answer and is always sent.** Silence is indistinguishable from a device that
 * never received the request, and the two send a support engineer in opposite directions: wait for
 * the customer to open the app, or look at why this build cannot comply.
 * 拒绝也要答复：沉默与「根本没收到」分不出区别，而这两者会让人朝相反的方向去查。
 */

import type { ImLog } from './logs.js';
import { renderLogBundle } from './logs.js';

/** One open request, exactly as `diag.logRequests` returns it. */
export interface PendingDeviceLog {
  requestId: string;
  uploadUrl: string;
  /** Fields a presigned POST needs. Absent for a presigned PUT. */
  formFields?: Record<string, string> | null;
  objectKey: string;
  expiresAt: number;
  /** Most bytes the ticket accepts. Send the newest slice rather than failing. */
  maxBytes: number;
  reason: string;
}

/** What this device says about one request. */
export interface DeviceLogAnswer {
  requestId: string;
  uploaded: boolean;
  sizeBytes: number;
  coveredFromMs?: number | null;
  /** Whether the log covers this process only. Decided by the SDK, never by the store. */
  volatile: boolean;
  detail?: string;
}

/** The two calls this needs, so the runner can be tested without a socket. */
export interface DeviceLogTransport {
  requests(): Promise<PendingDeviceLog[]>;
  answer(answer: DeviceLogAnswer): Promise<void>;
}

/** The upload, injected so a test never reaches the network. */
export type DeviceLogUploader = (request: PendingDeviceLog, body: string) => Promise<void>;

/**
 * Uploads with whatever the ticket describes: a presigned POST when it carries form fields, a
 * presigned PUT otherwise.
 *
 * Both shapes exist because both storage backends do, and guessing wrong produces a 403 from a
 * service that will not say which of the two it wanted.
 * 两种形状都要支持，因为两种对象存储后端都存在，而猜错得到的是一个不肯说它想要哪种的 403。
 */
export function defaultDeviceLogUploader(): DeviceLogUploader {
  return async (request, body) => {
    if (request.formFields) {
      const form = new FormData();
      for (const [key, value] of Object.entries(request.formFields)) {
        form.append(key, value);
      }
      form.append('file', new Blob([body], { type: 'text/plain' }));

      const posted = await fetch(request.uploadUrl, { method: 'POST', body: form });
      if (!posted.ok) {
        throw new Error(`upload rejected with ${posted.status}`);
      }
      return;
    }

    const put = await fetch(request.uploadUrl, {
      method: 'PUT',
      headers: { 'content-type': 'text/plain' },
      body,
    });

    if (!put.ok) {
      throw new Error(`upload rejected with ${put.status}`);
    }
  };
}

export class ImDeviceLogs {
  /** Requests already answered in this process, so a pull after a push does not upload twice. */
  private readonly answered = new Set<string>();

  constructor(
    private readonly transport: DeviceLogTransport,
    private readonly log: ImLog,
    private readonly upload: DeviceLogUploader = defaultDeviceLogUploader(),
    private readonly now: () => number = () => Date.now(),
  ) {}

  /**
   * Asks whether anything is waiting, and fulfils whatever is.
   *
   * **Call once per connect, never on a timer.** Requests are raised by a person looking at a
   * support ticket, so the rate is one every few days at most; polling would turn a human-paced
   * feature into per-device background traffic for every handset a tenant has.
   * 每次连接调一次，不要定时轮询：这是一件由人按工单节奏发起的事。
   */
  async check(): Promise<void> {
    let pending: PendingDeviceLog[];

    try {
      pending = await this.transport.requests();
    } catch (error) {
      // A server that will not answer this must not stop a client from chatting. Logged into our
      // own store, which is the right place for it: the next successful pull carries this line.
      // 服务端不答复不能挡住聊天。记进我们自己的存储——下一次成功的拉取会把这一行带上去。
      this.log.warn(`diag.logRequests failed: ${describe(error)}`);
      return;
    }

    for (const request of pending) {
      await this.fulfil(request);
    }
  }

  /**
   * Handles an `evt.system` frame. Ignores anything that is not a log request for this device.
   *
   * @param deviceId this client's own device id, which the frame names. Delivery is per user rather
   * than per device, so every device of theirs sees the frame and exactly one should answer.
   * 投递是按用户而不是按设备的：他的每一台设备都会看到这一帧，而应当只有一台回答。
   */
  async onSystemEvent(body: unknown, deviceId: string): Promise<void> {
    if (typeof body !== 'object' || body === null) {
      return;
    }

    const frame = body as { event?: unknown; body?: unknown };
    if (frame.event !== 'device.logRequest' || typeof frame.body !== 'object' || frame.body === null) {
      return;
    }

    const payload = frame.body as Record<string, unknown>;
    if (typeof payload['deviceId'] === 'string' && payload['deviceId'] !== deviceId) {
      return;
    }

    await this.fulfil({
      requestId: String(payload['requestId'] ?? ''),
      uploadUrl: String(payload['uploadUrl'] ?? ''),
      formFields: (payload['formFields'] as Record<string, string> | null | undefined) ?? null,
      objectKey: String(payload['objectKey'] ?? ''),
      expiresAt: Number(payload['expiresAt'] ?? 0),
      maxBytes: Number(payload['maxBytes'] ?? 0),
      reason: String(payload['reason'] ?? ''),
    });
  }

  private async fulfil(request: PendingDeviceLog): Promise<void> {
    if (!request.requestId || this.answered.has(request.requestId)) {
      return;
    }

    // Claimed before the work rather than after it. Two entrances can deliver the same request
    // within milliseconds — a push arriving while a pull is in flight — and claiming late would
    // upload the same bundle twice and answer twice.
    // 先认领再干活：两个入口可能在几毫秒内送来同一条请求，晚认领会上传两次、答复两次。
    this.answered.add(request.requestId);

    if (request.expiresAt > 0 && this.now() >= request.expiresAt) {
      // Not answered at all. The ticket is dead, so an upload would fail and a refusal would put
      // "the device could not do it" on a row whose real state is "nobody asked in time".
      // 完全不答复：票已经死了，上传会失败，而报「设备做不到」会写在一条真实状态是「没人及时问」的行上。
      this.log.warn(`device-log request ${request.requestId} arrived after its window closed`);
      return;
    }

    let lines;
    try {
      lines = await this.log.read();
    } catch (error) {
      await this.tell({
        requestId: request.requestId,
        uploaded: false,
        sizeBytes: 0,
        volatile: this.log.isVolatile,
        detail: `could not read the log store: ${describe(error)}`,
      });
      return;
    }

    // Trimmed from the front, keeping the newest. The failure being investigated is at the end of
    // the log; dropping the tail to fit would remove the only part anybody asked for.
    // 从前面裁，保留最新：被调查的故障在日志末尾，为了塞下而丢掉尾巴，
    // 恰恰丢掉了唯一有人要的那一段。
    let body = renderLogBundle(lines);
    let coveredFrom = lines.length > 0 ? lines[0]!.t : null;

    if (request.maxBytes > 0 && byteLength(body) > request.maxBytes) {
      let keep = lines.length;
      while (keep > 0 && byteLength(renderLogBundle(lines.slice(lines.length - keep))) > request.maxBytes) {
        keep = Math.floor(keep / 2);
      }

      const kept = lines.slice(lines.length - keep);
      body = renderLogBundle(kept);
      coveredFrom = kept.length > 0 ? kept[0]!.t : null;
    }

    try {
      await this.upload(request, body);
    } catch (error) {
      await this.tell({
        requestId: request.requestId,
        uploaded: false,
        sizeBytes: 0,
        volatile: this.log.isVolatile,
        detail: `upload failed: ${describe(error)}`,
      });
      return;
    }

    const told = await this.tell({
      requestId: request.requestId,
      uploaded: true,
      sizeBytes: byteLength(body),
      coveredFromMs: coveredFrom,
      volatile: this.log.isVolatile,
    });

    // Cleared only after the server has been told. Clearing first and then failing to report would
    // destroy the evidence and leave the row saying nothing arrived.
    // 只有在告诉服务端之后才清空：先清再失败，会毁掉证据而记录上写着什么都没到。
    if (told) {
      await this.log.clear();
    }
  }

  private async tell(answer: DeviceLogAnswer): Promise<boolean> {
    try {
      await this.transport.answer(answer);
      return true;
    } catch (error) {
      // Un-claimed, so the next connect tries again. The bundle may well have reached storage
      // already — but a row nobody was told about expires saying nothing arrived, and a log sitting
      // in a bucket that the record denies exists is the same as no log at all. Re-uploading the
      // same lines to the same object key is cheap; losing them is not.
      // 取消认领，下次连接再试一遍：包很可能已经进了对象存储，
      // 但一条没人被告知的记录会以「什么都没到」过期——而记录否认其存在的日志，等于没有日志。
      // 用同一个对象键重传同样几行很便宜，丢掉它们不便宜。
      this.answered.delete(answer.requestId);
      this.log.warn(`diag.logUploaded failed for ${answer.requestId}: ${describe(error)}`);
      return false;
    }
  }
}

function byteLength(text: string): number {
  return typeof TextEncoder === 'undefined' ? text.length : new TextEncoder().encode(text).length;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
