import 'dart:developer' as developer;

/// Where the SDK's own diagnostics go.
///
/// A sink rather than `print`: the package's lint set bans `print`, a Flutter app usually already
/// owns a logger, and — the reason that actually matters — two of the contract's rules are
/// *warnings the integrator has to be able to see*. `ImCursorStore.inMemory()` warns that nothing
/// is persisted (`sdk/CONTRACT.md` §5.3) and the push path warns that a held token was never
/// registered (§6.2). A warning written to a stream nobody reads is the same as no warning, so
/// both are routed here and both are observable from a test.
///
/// 日志走可注入的 sink：契约里有两条"必须让接入方看见"的警告，写进无人订阅的流等于没写。
typedef ImLogger = void Function(String message);

/// Default sink: `dart:developer`'s `log`, which works on the VM and on the web and does not trip
/// the `avoid_print` lint. Replace it with [ImOptions.logger] to route into the host app's logger.
void defaultImLogger(String message) => developer.log(message, name: 'cyaim_im');
