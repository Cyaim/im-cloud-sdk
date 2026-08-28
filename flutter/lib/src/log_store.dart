// The SDK's own runtime log, and where it lives between runs. See `ADR-003`.
//
// The decision this file implements: **the store belongs to the integrating application**, exactly
// as [ImCursorStore] does. The SDK does not pick a write location, because on Android that is
// app-private storage whose backup behaviour you configure, on iOS it is `Documents` or
// `Library/Caches` — whose backup behaviour differs — and on the web it is a browser store the
// integrator may be obliged to clear on logout and cannot clear if they do not know it exists.
//
// 依据 ADR-003：存储属于接入方，与游标存储同理。SDK 不替你选写入位置——那个选择的后果由你承担。

import 'logging.dart';

/// One line of the SDK's own runtime log. [t] is Unix ms.
///
/// Spelled the same way in all five SDKs, so a bundle written by one is legible to whoever opens
/// it, whatever produced it.
class ImLogLine {
  const ImLogLine(this.t, this.level, this.msg);

  final int t;
  final String level;
  final String msg;
}

/// Where the SDK's runtime log lives between runs.
///
/// **Optional, and the default is honest** — unlike [ImCursorStore], which has no default. The
/// asymmetry is deliberate: losing cursors loses a user's messages, while losing logs loses a
/// diagnostic. Requiring a store here would make every integration answer a question about a
/// feature most of them will never use.
///
/// Supplying one is what makes "pull a log from that handset" answer questions about anything
/// before the current run — a crash, a night the app was closed, the reconnect storm at 3am.
/// Supplying none keeps a bounded ring in memory, which answers "what is happening now" completely
/// and "what happened when it crashed" not at all; the console shows which of the two a support
/// engineer is looking at, because a three-minute log and a seven-day log are otherwise identical.
///
/// 不提供也是一个完整的选择：内存环形缓冲只覆盖本次运行——
/// 它完整地回答「现在正在发生什么」，而对「崩的时候发生了什么」一个字也答不出。
///
/// **Every method may throw**, and every throw is handled. A broken store must never take down a
/// client that is otherwise chatting happily.
/// 每个方法都可以抛，而每一次抛出都被处理。
abstract interface class ImLogStore {
  /// Appends lines. May coalesce, and may drop the oldest to stay within its own bound.
  Future<void> append(List<ImLogLine> lines);

  /// Everything currently held, oldest first.
  Future<List<ImLogLine>> read();

  /// Called after a successful upload. A store that ignores this is allowed but will grow.
  Future<void> clear();

  /// Loses everything on restart. The default, and an honest one.
  ///
  /// [capacity] is lines rather than bytes because a line is what a reader counts, and a byte cap
  /// would truncate the middle of the sentence somebody is trying to read.
  static ImLogStore inMemory({int capacity = 2000}) => ImInMemoryLogStore(capacity: capacity);
}

/// The store [ImLogStore.inMemory] builds. Public only so [ImLog] can recognise it by type.
///
/// "Is this store persistent" is answered by the SDK from the store's identity, never by the store
/// itself — the same rule the cursor store follows. A declared flag would let any store announce
/// itself persistent, and the only thing that answer drives is whether a support engineer is told
/// the log they are reading covers three minutes or three weeks. A store that can lie about that is
/// a store that can make somebody conclude nothing went wrong.
/// 由 SDK 按身份判断而不是由存储自称：能自称持久的存储，也能让人得出「什么都没发生」的结论。
final class ImInMemoryLogStore implements ImLogStore {
  ImInMemoryLogStore({this.capacity = 2000});

  final int capacity;
  final List<ImLogLine> _lines = <ImLogLine>[];

  @override
  Future<void> append(List<ImLogLine> lines) async {
    _lines.addAll(lines);
    // The newest are what a support engineer needs: the failure is at the end of the log.
    // 保留最新的：故障在日志末尾。
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
  }

  @override
  Future<List<ImLogLine>> read() async => List<ImLogLine>.unmodifiable(_lines);

  @override
  Future<void> clear() async => _lines.clear();
}

/// True only for the store [ImLogStore.inMemory] builds.
bool isVolatileLogStore(ImLogStore store) => store is ImInMemoryLogStore;

/// Buffers the SDK's own lines and hands them to the store.
///
/// **Buffered rather than written through**, because the events worth logging arrive in bursts — a
/// reconnect storm writes a dozen lines in as many milliseconds — and a store backed by a file
/// would be asked for a dozen round trips to record one incident.
/// 带缓冲而不是直写：值得记的事件是成串来的，而落在文件上的存储会为一次事故被要求往返十几次。
class ImLog {
  ImLog(this._store, this._sink);

  final ImLogStore _store;
  final ImLogger _sink;
  final List<ImLogLine> _pending = <ImLogLine>[];

  bool _storeFailed = false;
  bool _warned = false;

  /// True when the store is the in-memory one, so the log covers this run only.
  bool get isVolatile => isVolatileLogStore(_store);

  /// True once an append or a read has thrown. Surfaced so a misconfigured store is findable.
  bool get storeFailed => _storeFailed;

  /// Adds a line, and tees it to the integrator's own sink.
  ///
  /// Both, because they answer different questions. The sink is for the developer watching the
  /// console right now; the store is for the support engineer reading a bundle from a customer's
  /// handset a week later.
  /// 两边都写：sink 给此刻盯着控制台的开发者，store 给一周后读那份包的支持工程师。
  void write(String level, String message) {
    _sink('[$level] $message');
    _pending.add(ImLogLine(DateTime.now().millisecondsSinceEpoch, level, message));

    if (_pending.length >= 32) {
      unawaitedFlush();
    }
  }

  void info(String message) => write('info', message);

  void warn(String message) => write('warn', message);

  void error(String message) => write('error', message);

  /// Fire-and-forget flush, for the call sites that are not async.
  void unawaitedFlush() {
    // ignore: discarded_futures
    flush();
  }

  Future<void> flush() async {
    if (_pending.isEmpty) return;

    final List<ImLogLine> batch = List<ImLogLine>.of(_pending);
    _pending.clear();

    try {
      await _store.append(batch);
    } catch (error) {
      // Deliberately swallowed. A store that cannot be written to is a diagnostic problem, and
      // raising it here would put a logging failure in the path of whatever was being logged —
      // very often an error the application actually needs to see.
      // 刻意吞掉：在这里抛出，会把一次日志失败插进正在被记录的那件事的路径上。
      _noteFailure(error);
    }
  }

  /// Everything the store holds, oldest first. Flushes first so the tail is not missing.
  Future<List<ImLogLine>> read() async {
    await flush();

    try {
      return await _store.read();
    } catch (error) {
      _noteFailure(error);
      return const <ImLogLine>[];
    }
  }

  Future<void> clear() async {
    _pending.clear();

    try {
      await _store.clear();
    } catch (error) {
      _noteFailure(error);
    }
  }

  /// Says it once, out loud, the first time the store refuses.
  ///
  /// Once because a store that fails once fails every time, and a warning per line would bury the
  /// application's own output. Out loud at all because the alternative is an integrator finding out
  /// when a support engineer asks for a log and gets an empty one — which reads as "nothing
  /// happened on that device" rather than as "the store was never writable".
  /// 只说一次；而完全不说的代价是：接入方要等到有人拿到一份空日志，才知道存储从来就写不进去。
  void _noteFailure(Object error) {
    _storeFailed = true;
    if (_warned) return;
    _warned = true;

    _sink(
      'the log store refused a write ($error). Device-log requests from the console will come '
      "back empty, which reads as 'nothing happened on that device'. See ADR-003.",
    );
  }
}

/// Renders lines as the text file a support engineer opens.
///
/// Plain text, one line each, ISO timestamps — not JSON. Whoever reads this is reading it in a
/// viewer, often on a phone, and the first thing they do is search it for a word.
/// 纯文本而不是 JSON：读它的人在查看器里读、常常在手机上，而他做的第一件事是搜一个词。
String renderLogBundle(List<ImLogLine> lines) => lines
    .map((ImLogLine line) =>
        '${DateTime.fromMillisecondsSinceEpoch(line.t, isUtc: true).toIso8601String()} '
        '${line.level.toUpperCase().padRight(5)} ${line.msg}')
    .join('\n');
