import 'dart:convert';
import 'dart:io';

import 'device_logs.dart';

/// The default device-log uploader on every target except the web. Selected by the conditional
/// import in `device_logs.dart`.
///
/// A presigned POST when the ticket carries form fields, a presigned PUT otherwise. Both shapes
/// exist because both object-storage backends do, and guessing wrong produces a 403 from a service
/// that will not say which of the two it wanted.
/// 两种形状都要支持：猜错得到的是一个不肯说它想要哪种的 403。
ImDeviceLogUploader createDeviceLogUploader() => (ImPendingDeviceLog request, String body) async {
      final HttpClient client = HttpClient();

      try {
        final Uri target = Uri.parse(request.uploadUrl);
        final Map<String, String>? fields = request.formFields;

        if (fields == null || fields.isEmpty) {
          final HttpClientRequest put = await client.putUrl(target);
          put.headers.set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');
          put.add(utf8.encode(body));
          await _expectSuccess(await put.close());
          return;
        }

        final String boundary =
            '----imlog${DateTime.now().microsecondsSinceEpoch}${identityHashCode(request)}';
        final StringBuffer payload = StringBuffer();

        fields.forEach((String key, String value) {
          payload
            ..write('--$boundary$_crlf')
            ..write('Content-Disposition: form-data; name="$key"$_crlf$_crlf')
            ..write('$value$_crlf');
        });

        payload
          ..write('--$boundary$_crlf')
          ..write('Content-Disposition: form-data; name="file"; filename="device.log"$_crlf')
          ..write('Content-Type: text/plain$_crlf$_crlf')
          ..write('$body$_crlf')
          ..write('--$boundary--$_crlf');

        final HttpClientRequest post = await client.postUrl(target);
        post.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
        post.add(utf8.encode(payload.toString()));
        await _expectSuccess(await post.close());
      } finally {
        client.close(force: true);
      }
    };

/// The line terminator multipart requires. Named rather than inlined so the escapes appear once:
/// a single `\n` where a `\r\n` belongs is accepted by some object-storage backends and rejected
/// by others, which produces a bug that reproduces on one deployment and not on the next.
/// 单独命名，让转义只出现一次：该用 CRLF 的地方写成 LF，有的对象存储收、有的不收——
/// 于是得到一个「换一套部署就复现不了」的缺陷。
const String _crlf = '\r\n';

Future<void> _expectSuccess(HttpClientResponse response) async {
  await response.drain<void>();

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('upload rejected with ${response.statusCode}');
  }
}
