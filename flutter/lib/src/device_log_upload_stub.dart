import 'device_logs.dart';

/// Web build of the default device-log uploader.
///
/// There is no `dart:io` in a browser and this package has no dependencies, so rather than pull in
/// `package:http` for one call, the web build fails loudly at the moment of use and names the fix.
/// Failing loudly matters here: a silent no-op would answer the console with "the device refused",
/// which sends a support engineer to look at the customer's build for a problem that is ours.
///
/// 浏览器里没有 dart:io，而本包零依赖：与其为一次调用引入 package:http，
/// web 构建在使用的那一刻大声失败并说出怎么修。静默不做的代价是控制台上写着「设备拒绝了」——
/// 那会让支持工程师去客户的构建里找一个其实在我们这边的问题。
ImDeviceLogUploader createDeviceLogUploader() => (ImPendingDeviceLog request, String body) async {
      throw UnsupportedError(
        'The default device-log uploader needs dart:io, which a browser does not have. Pass '
        'ImOptions(deviceLogUploader: ...) built over package:http or window.fetch. See ADR-003.',
      );
    };
