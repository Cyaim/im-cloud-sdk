using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Cyaim.Im
{
    /// <summary>One line of the SDK's own runtime log. <see cref="T"/> is Unix ms.</summary>
    /// <remarks>
    /// Spelled the same way in all five SDKs, so a bundle written by one is legible to whoever opens
    /// it, whatever produced it.
    /// 五端拼写一致：谁打开这份日志，都读得懂它是哪一端写的。
    /// </remarks>
    public readonly struct ImLogLine
    {
        public ImLogLine(long t, string level, string msg)
        {
            T = t;
            Level = level ?? string.Empty;
            Msg = msg ?? string.Empty;
        }

        public long T { get; }

        public string Level { get; }

        public string Msg { get; }
    }

    /// <summary>
    /// Where the SDK's runtime log lives between runs.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The decision behind this interface is <c>ADR-003</c>: <b>the store belongs to the integrating
    /// game</b>, exactly as <see cref="IImCursorStore"/> does. The SDK does not pick a write
    /// location, because on a console that is a title storage API with its own certification rules,
    /// on mobile it is app-private storage whose backup behaviour the game configures, and a wrong
    /// guess about that is a compliance problem the game's publisher answers for.
    /// </para>
    /// <para>
    /// <b>Optional, unlike the cursor store, and the asymmetry is deliberate.</b> Losing cursors
    /// loses a player's messages; losing logs loses a diagnostic. Requiring one here would make
    /// every integration answer a question about a feature most of them will never use.
    /// <see cref="ImLogStore.InMemory"/> is the default and it says what it costs: the log covers
    /// this process only, so it answers "what is happening now" completely and "what happened when
    /// it crashed" not at all.
    /// </para>
    /// <para>
    /// 不提供也是一个完整的选择：内存环形缓冲只覆盖本次进程——
    /// 它完整地回答「现在正在发生什么」，而对「崩的时候发生了什么」一个字也答不出。
    /// </para>
    /// <para>
    /// <b>Every member may throw</b>, and every throw is handled. A broken store must never take
    /// down a client that is otherwise chatting happily.
    /// </para>
    /// </remarks>
    public interface IImLogStore
    {
        /// <summary>Appends lines. May coalesce, and may drop the oldest to stay within its bound.</summary>
        void Append(IReadOnlyList<ImLogLine> lines);

        /// <summary>Everything currently held, oldest first.</summary>
        IReadOnlyList<ImLogLine> Read();

        /// <summary>Called after a successful upload. A store that ignores this is allowed but grows.</summary>
        void Clear();
    }

    /// <summary>The stores this SDK provides.</summary>
    public static class ImLogStore
    {
        /// <summary>
        /// Loses everything on restart. The default, and an honest one.
        /// </summary>
        /// <param name="capacity">
        /// Lines kept before the oldest are dropped. Bounded on lines rather than bytes because a
        /// line is what a reader counts, and a byte cap truncates the middle of the sentence
        /// somebody is trying to read.
        /// </param>
        public static IImLogStore InMemory(int capacity = 2000)
        {
            return new ImInMemoryLogStore(capacity);
        }

        /// <summary>
        /// A single file under <paramref name="path"/>, rotated once at <paramref name="maxBytes"/>.
        /// </summary>
        /// <remarks>
        /// <b>Provided but not the default</b>, and the difference matters: choosing this is the game
        /// saying where its players' runtime detail may be written. Two files rather than one,
        /// because a single file truncated at the limit loses the tail — and the tail is the failure
        /// being investigated.
        /// 提供但不是默认；两个文件而不是一个：单文件到限就截断会丢掉尾巴，而尾巴正是故障本身。
        /// </remarks>
        public static IImLogStore File(string path, long maxBytes = 2L * 1024 * 1024)
        {
            return new ImFileLogStore(path, maxBytes);
        }

        /// <summary>
        /// True only for the store <see cref="InMemory"/> builds.
        /// </summary>
        /// <remarks>
        /// "Is this store persistent" is answered by the SDK from the store's identity, never by the
        /// store itself — the same rule the cursor store follows. A declared flag would let any
        /// store announce itself persistent, and the only thing that answer drives is whether a
        /// support engineer is told the log they are reading covers three minutes or three weeks. A
        /// store that can lie about that is a store that can make somebody conclude nothing went
        /// wrong.
        /// 由 SDK 按身份判断而不是由存储自称：能自称持久的存储，也能让人得出「什么都没发生」的结论。
        /// </remarks>
        public static bool IsVolatile(IImLogStore store)
        {
            return store is ImInMemoryLogStore;
        }
    }

    internal sealed class ImInMemoryLogStore : IImLogStore
    {
        private readonly int _capacity;
        private readonly List<ImLogLine> _lines = new List<ImLogLine>();
        private readonly object _gate = new object();

        internal ImInMemoryLogStore(int capacity)
        {
            _capacity = Math.Max(1, capacity);
        }

        public void Append(IReadOnlyList<ImLogLine> lines)
        {
            if (lines == null)
            {
                return;
            }

            lock (_gate)
            {
                for (var i = 0; i < lines.Count; i++)
                {
                    _lines.Add(lines[i]);
                }

                // The newest are what a support engineer needs: the failure is at the end of the log.
                // 保留最新的：故障在日志末尾。
                if (_lines.Count > _capacity)
                {
                    _lines.RemoveRange(0, _lines.Count - _capacity);
                }
            }
        }

        public IReadOnlyList<ImLogLine> Read()
        {
            lock (_gate)
            {
                return _lines.ToArray();
            }
        }

        public void Clear()
        {
            lock (_gate)
            {
                _lines.Clear();
            }
        }
    }

    internal sealed class ImFileLogStore : IImLogStore
    {
        private readonly string _path;
        private readonly string _previous;
        private readonly long _maxBytes;
        private readonly object _gate = new object();

        internal ImFileLogStore(string path, long maxBytes)
        {
            _path = path ?? throw new ArgumentNullException(nameof(path));
            _previous = path + ".1";
            _maxBytes = Math.Max(1024, maxBytes);
        }

        public void Append(IReadOnlyList<ImLogLine> lines)
        {
            if (lines == null || lines.Count == 0)
            {
                return;
            }

            lock (_gate)
            {
                var directory = Path.GetDirectoryName(_path);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                if (System.IO.File.Exists(_path) && new FileInfo(_path).Length >= _maxBytes)
                {
                    if (System.IO.File.Exists(_previous))
                    {
                        System.IO.File.Delete(_previous);
                    }

                    System.IO.File.Move(_path, _previous);
                }

                var builder = new StringBuilder();
                for (var i = 0; i < lines.Count; i++)
                {
                    builder
                        .Append(lines[i].T.ToString(CultureInfo.InvariantCulture))
                        .Append('\t')
                        .Append(lines[i].Level)
                        .Append('\t')
                        .Append(Escape(lines[i].Msg))
                        .Append('\n');
                }

                System.IO.File.AppendAllText(_path, builder.ToString(), Encoding.UTF8);
            }
        }

        public IReadOnlyList<ImLogLine> Read()
        {
            lock (_gate)
            {
                var lines = new List<ImLogLine>();
                ReadOne(_previous, lines);
                ReadOne(_path, lines);
                return lines;
            }
        }

        public void Clear()
        {
            lock (_gate)
            {
                if (System.IO.File.Exists(_path))
                {
                    System.IO.File.Delete(_path);
                }

                if (System.IO.File.Exists(_previous))
                {
                    System.IO.File.Delete(_previous);
                }
            }
        }

        private static void ReadOne(string path, List<ImLogLine> into)
        {
            if (!System.IO.File.Exists(path))
            {
                return;
            }

            foreach (var row in System.IO.File.ReadAllLines(path, Encoding.UTF8))
            {
                var parts = row.Split(new[] { '\t' }, 3);
                if (parts.Length < 3)
                {
                    continue;
                }

                if (!long.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var at))
                {
                    continue;
                }

                into.Add(new ImLogLine(at, parts[1], Unescape(parts[2])));
            }
        }

        // Newlines and tabs are escaped rather than forbidden: a log line very often carries a stack
        // trace, and a format that silently split one across records would make traces unreadable
        // exactly when they matter.
        // 转义而不是禁止：日志行里常常是一段堆栈，而会把它拆开的格式，恰在最要紧时让堆栈读不懂。
        private static string Escape(string text)
        {
            return text.Replace("\\", "\\\\").Replace("\n", "\\n").Replace("\t", "\\t");
        }

        private static string Unescape(string text)
        {
            return text.Replace("\\t", "\t").Replace("\\n", "\n").Replace("\\\\", "\\");
        }
    }

    /// <summary>
    /// Buffers the SDK's own lines and hands them to the store.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Tees into both <see cref="ImLog"/> and the store, because they answer different questions:
    /// the static logger is for the developer watching the Unity console right now, the store is for
    /// the support engineer reading a bundle from a player's device a week later.
    /// 两边都写：静态日志给此刻盯着控制台的开发者，存储给一周后读那份包的支持工程师。
    /// </para>
    /// <para>
    /// Named <c>ImLogRecorder</c> rather than <c>ImLog</c>, which this SDK already uses for the
    /// static console logger. Both are worth having and neither replaces the other.
    /// 叫 ImLogRecorder 而不是 ImLog：后者已经是本 SDK 的静态控制台日志，两者都值得有。
    /// </para>
    /// </remarks>
    public sealed class ImLogRecorder
    {
        private readonly IImLogStore _store;
        private readonly Action<string> _sink;
        private readonly List<ImLogLine> _pending = new List<ImLogLine>();
        private readonly object _gate = new object();

        private bool _storeFailed;
        private bool _warned;

        internal ImLogRecorder(IImLogStore store, Action<string> sink)
        {
            _store = store ?? ImLogStore.InMemory();
            _sink = sink;
        }

        /// <summary>True when the store is the in-memory one, so the log covers this process only.</summary>
        public bool IsVolatile
        {
            get { return ImLogStore.IsVolatile(_store); }
        }

        /// <summary>True once an append or a read has thrown. Surfaced so a bad store is findable.</summary>
        public bool StoreFailed
        {
            get { return _storeFailed; }
        }

        /// <summary>
        /// Adds a line. Games may call this: the SDK cannot see what the <i>player</i> was doing when
        /// something went wrong, and that is usually the half that makes a log worth reading.
        /// 游戏可以调用它：SDK 看不见玩家当时在做什么，而那往往是让日志值得读的那一半。
        /// </summary>
        public void Write(string level, string message)
        {
            if (_sink != null)
            {
                _sink("[" + level + "] " + message);
            }

            var flushNow = false;

            lock (_gate)
            {
                _pending.Add(new ImLogLine(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), level, message));
                flushNow = _pending.Count >= 32;
            }

            if (flushNow)
            {
                Flush();
            }
        }

        public void Info(string message)
        {
            Write("info", message);
        }

        public void Warn(string message)
        {
            Write("warn", message);
        }

        public void Error(string message)
        {
            Write("error", message);
        }

        /// <summary>Writes whatever is buffered. Safe to call at any time; called before every read.</summary>
        public void Flush()
        {
            ImLogLine[] batch;

            lock (_gate)
            {
                if (_pending.Count == 0)
                {
                    return;
                }

                batch = _pending.ToArray();
                _pending.Clear();
            }

            try
            {
                _store.Append(batch);
            }
            catch (Exception failure)
            {
                // Deliberately swallowed. A store that cannot be written to is a diagnostic problem,
                // and raising it here would put a logging failure in the path of whatever was being
                // logged — very often an error the game actually needs to see.
                // 刻意吞掉：在这里抛出，会把一次日志失败插进正在被记录的那件事的路径上。
                NoteFailure(failure);
            }
        }

        /// <summary>Everything the store holds, oldest first. Flushes first so the tail is not missing.</summary>
        public IReadOnlyList<ImLogLine> Read()
        {
            Flush();

            try
            {
                return _store.Read() ?? Array.Empty<ImLogLine>();
            }
            catch (Exception failure)
            {
                NoteFailure(failure);
                return Array.Empty<ImLogLine>();
            }
        }

        public void Clear()
        {
            lock (_gate)
            {
                _pending.Clear();
            }

            try
            {
                _store.Clear();
            }
            catch (Exception failure)
            {
                NoteFailure(failure);
            }
        }

        /// <summary>
        /// Says it once, out loud, the first time the store refuses.
        /// </summary>
        /// <remarks>
        /// Once because a store that fails once fails every time, and a warning per line would bury
        /// the game's own output. Out loud at all because the alternative is a studio finding out
        /// when a support engineer asks for a log and gets an empty one — which reads as "nothing
        /// happened on that device" rather than as "the store was never writable".
        /// 只说一次；而完全不说的代价是：等到有人拿到一份空日志，才知道存储从来就写不进去。
        /// </remarks>
        private void NoteFailure(Exception failure)
        {
            _storeFailed = true;

            if (_warned || _sink == null)
            {
                return;
            }

            _warned = true;
            _sink(
                "the log store refused a write (" + failure.Message + "). Device-log requests from "
                + "the console will come back empty, which reads as 'nothing happened on that "
                + "device'. See ADR-003.");
        }

        /// <summary>
        /// Renders lines as the text file a support engineer opens.
        /// </summary>
        /// <remarks>
        /// Plain text, one line each, ISO timestamps — not JSON. Whoever reads this is reading it in
        /// a viewer, often on a phone, and the first thing they do is search it for a word.
        /// 纯文本而不是 JSON：读它的人在查看器里读、常常在手机上，而他做的第一件事是搜一个词。
        /// </remarks>
        public static string RenderBundle(IReadOnlyList<ImLogLine> lines)
        {
            var builder = new StringBuilder();

            for (var i = 0; i < lines.Count; i++)
            {
                if (i > 0)
                {
                    builder.Append('\n');
                }

                builder
                    .Append(DateTimeOffset.FromUnixTimeMilliseconds(lines[i].T).UtcDateTime
                        .ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture))
                    .Append(' ')
                    .Append((lines[i].Level ?? string.Empty).ToUpperInvariant().PadRight(5))
                    .Append(' ')
                    .Append(lines[i].Msg);
            }

            return builder.ToString();
        }
    }
}
