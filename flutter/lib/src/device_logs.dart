// Answering the server when somebody asks this device for its log. See `ADR-003`.
//
// Two entrances and one exit. The entrances are a pull — [ImDeviceLogs.check], once after every
// connect — and a push, an `evt.system` frame naming this device. The exit is always the same: read
// the store, upload the bundle to the signed target the server issued, then say what happened.
//
// 两个入口、一个出口：拉取与推送进来，出去永远是「读存储、上传、答复」。

import 'dart:convert';

import 'api.dart';
import 'json.dart';
import 'log_store.dart';

// Conditional import: `dart:io` does not exist in a browser, and a single `import 'dart:io'`
// anywhere in the package's reachable graph would stop `flutter build web` dead. The stub throws
// from the default uploader on the web and nothing else changes.
// 条件导入：包里任何一处 dart:io 都会让 web 构建直接失败。
import 'device_log_upload_stub.dart'
    if (dart.library.io) 'device_log_upload_io.dart' as platform;

/// One open log request, exactly as `diag.logRequests` returns it.
class ImPendingDeviceLog {
  const ImPendingDeviceLog({
    required this.requestId,
    required this.uploadUrl,
    this.formFields,
    this.objectKey = '',
    this.expiresAt = 0,
    this.maxBytes = 0,
    this.reason = '',
  });

  factory ImPendingDeviceLog.fromJson(Map<String, dynamic> json) => ImPendingDeviceLog(
        requestId: imStringOr(json['requestId']),
        uploadUrl: imStringOr(json['uploadUrl']),
        formFields: json['formFields'] is Map
            ? (json['formFields'] as Map).map<String, String>(
                (Object? key, Object? value) => MapEntry<String, String>('$key', '$value'),
              )
            : null,
        objectKey: imStringOr(json['objectKey']),
        expiresAt: imIntOr(json['expiresAt']),
        maxBytes: imIntOr(json['maxBytes']),
        reason: imStringOr(json['reason']),
      );

  final String requestId;
  final String uploadUrl;

  /// Fields a presigned POST needs. Null for a presigned PUT.
  final Map<String, String>? formFields;
  final String objectKey;
  final int expiresAt;

  /// Most bytes the ticket accepts. Send the newest slice rather than failing — an upload that
  /// failed outright would be recorded as "the device refused", which is the wrong sentence to put
  /// in front of whoever is waiting.
  /// 上限而不是目标：超出就发最近的一段，别整个失败——那会被记成「设备拒绝了」。
  final int maxBytes;
  final String reason;
}

/// What this device says about one request.
class ImDeviceLogAnswer {
  const ImDeviceLogAnswer({
    required this.requestId,
    required this.uploaded,
    this.sizeBytes = 0,
    this.coveredFromMs,
    this.isVolatile = false,
    this.detail,
  });

  final String requestId;
  final bool uploaded;
  final int sizeBytes;
  final int? coveredFromMs;

  /// Whether the log covers this run only. Decided by the SDK, never by the store.
  final bool isVolatile;
  final String? detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'requestId': requestId,
        'uploaded': uploaded,
        'sizeBytes': sizeBytes,
        if (coveredFromMs != null) 'coveredFromMs': coveredFromMs,
        // `volatile` on the wire, `isVolatile` in Dart: the server's field name is not ours to
        // rename, and `volatile` reads as a keyword to every reviewer.
        // 线上是 volatile：服务端的字段名不归我们改。
        'volatile': isVolatile,
        if (detail != null) 'detail': detail,
      };
}

/// How a bundle reaches object storage. A function so a test never touches the network.
typedef ImDeviceLogUploader = Future<void> Function(ImPendingDeviceLog request, String body);

/// The uploader an integrator gets when they pass none: `dart:io` everywhere but the web, where it
/// throws and names the fix.
ImDeviceLogUploader defaultDeviceLogUploader() => platform.createDeviceLogUploader();

/// Answering the server when somebody asks this device for its log.
class ImDeviceLogs {
  ImDeviceLogs({
    required ImDiagApi diag,
    required ImLog log,
    required String deviceId,
    ImDeviceLogUploader? upload,
    int Function()? now,
  })  : _diag = diag,
        _log = log,
        _deviceId = deviceId,
        _upload = upload ?? defaultDeviceLogUploader(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ImDiagApi _diag;
  final ImLog _log;
  final String _deviceId;
  final ImDeviceLogUploader _upload;
  final int Function() _now;

  /// Requests already answered in this run, so a pull after a push does not upload twice.
  final Set<String> _answered = <String>{};

  /// Asks whether anything is waiting, and fulfils whatever is.
  ///
  /// **Once per connect, never on a timer.** Requests are raised by a person looking at a support
  /// ticket, so the rate is at most one every few days; polling would turn a human-paced feature
  /// into background traffic on every handset a tenant has.
  /// 每次连接一次，不要轮询：这是一件由人按工单节奏发起的事。
  Future<void> check() async {
    List<ImPendingDeviceLog> pending;

    try {
      pending = await _diag.logRequests();
    } catch (error) {
      // A server that will not answer this must not stop a client from chatting. Logged into our
      // own store, which is the right place for it: the next successful pull carries this line up.
      // 服务端不答复不能挡住聊天：记进我们自己的存储，下一次成功的拉取会把它带上去。
      _log.warn('diag.logRequests failed: $error');
      return;
    }

    for (final ImPendingDeviceLog request in pending) {
      await _fulfil(request);
    }
  }

  /// Handles an `evt.system` frame. Ignores anything that is not a log request for this device.
  ///
  /// Delivery is per user rather than per device, so every device of theirs sees the frame and
  /// exactly one should answer.
  /// 投递是按用户而不是按设备的：他的每一台设备都会看到，而应当只有一台回答。
  Future<void> onSystemEvent(Object? data) async {
    if (data is! Map) return;

    final Map<String, dynamic> root = imMap(data);
    if (imStringOr(root['event']) != 'device.logRequest') return;
    if (root['body'] is! Map) return;

    final Map<String, dynamic> payload = imMap(root['body']);
    final String target = imStringOr(payload['deviceId']);
    if (target.isNotEmpty && target != _deviceId) return;

    await _fulfil(ImPendingDeviceLog.fromJson(payload));
  }

  Future<void> _fulfil(ImPendingDeviceLog request) async {
    // Claimed before the work rather than after it. Two entrances can deliver the same request
    // within milliseconds — a push arriving while a pull is in flight — and claiming late would
    // upload the same bundle twice and answer twice.
    // 先认领再干活：两个入口可能在几毫秒内送来同一条，晚认领会上传两次、答复两次。
    if (request.requestId.isEmpty || !_answered.add(request.requestId)) return;

    if (request.expiresAt > 0 && _now() >= request.expiresAt) {
      // Not answered at all. The ticket is dead, so an upload would fail and a refusal would put
      // "the device could not do it" on a row whose real state is "nobody asked in time".
      // 完全不答复：报「设备做不到」会写在一条真实状态是「没人及时问」的行上。
      _log.warn('device-log request ${request.requestId} arrived after its window closed');
      return;
    }

    final List<ImLogLine> lines = await _log.read();

    // Trimmed from the front, keeping the newest: the failure being investigated is at the end of
    // the log, and dropping the tail to fit would remove the only part anybody asked for.
    // 从前面裁、保留最新：故障在末尾，为了塞下丢掉尾巴，丢的正是唯一有人要的那段。
    List<ImLogLine> kept = lines;
    String body = renderLogBundle(kept);
    if (request.maxBytes > 0) {
      while (kept.isNotEmpty && utf8.encode(body).length > request.maxBytes) {
        final int keep = kept.length ~/ 2 == 0 ? 1 : kept.length ~/ 2;
        kept = kept.sublist(kept.length - keep);
        body = renderLogBundle(kept);
      }
    }

    try {
      await _upload(request, body);
    } catch (error) {
      await _tell(ImDeviceLogAnswer(
        requestId: request.requestId,
        uploaded: false,
        isVolatile: _log.isVolatile,
        detail: 'upload failed: $error',
      ));
      return;
    }

    await _tell(ImDeviceLogAnswer(
      requestId: request.requestId,
      uploaded: true,
      sizeBytes: utf8.encode(body).length,
      coveredFromMs: kept.isEmpty ? null : kept.first.t,
      isVolatile: _log.isVolatile,
    ));

    // Cleared only after the server has been told. Clearing first and then failing to report would
    // destroy the evidence and leave the row saying nothing arrived.
    // 只有在告诉服务端之后才清空：先清再失败，会毁掉证据而记录上写着什么都没到。
    await _log.clear();
  }

  Future<void> _tell(ImDeviceLogAnswer answer) async {
    try {
      await _diag.logUploaded(answer);
    } catch (error) {
      // The upload may well have succeeded; the row will expire saying nothing arrived. Logged so
      // the next bundle carries the explanation, which is the best this side can do.
      // 上传很可能成功了，而那一行会以「什么都没到」过期。记下来，让下一份日志带上解释。
      _log.warn('diag.logUploaded failed for ${answer.requestId}: $error');
    }
  }
}
