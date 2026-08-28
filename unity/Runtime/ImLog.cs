using System;

namespace Cyaim.Im
{
    /// <summary>How much the SDK writes to the Unity console.</summary>
    public enum ImLogLevel
    {
        /// <summary>Nothing at all.</summary>
        None = 0,

        /// <summary>Only failures that need a human.</summary>
        Error = 1,

        /// <summary>Failures plus recoverable trouble: a dropped frame, a failed repair.</summary>
        Warning = 2,

        /// <summary>Connection lifecycle: opened, kicked, reconnecting in N ms.</summary>
        Info = 3,

        /// <summary>Every frame in and out. Useful once, during integration; never ship it.</summary>
        Verbose = 4,
    }

    /// <summary>
    /// SDK logging, routed through <c>UnityEngine.Debug</c> by default.
    /// </summary>
    /// <remarks>
    /// The default level is <see cref="ImLogLevel.Warning"/>: silence during normal operation, but
    /// a visible line when something the SDK swallowed for correctness — a repair that failed, a
    /// frame that would not parse — actually happened. A networking library that logs nothing is a
    /// library you cannot debug from a player bug report; one that logs every frame is one that
    /// gets muted, which comes to the same thing.
    /// </remarks>
    public static class ImLog
    {
        /// <summary>Current verbosity. Set it before connecting.</summary>
        public static ImLogLevel Level = ImLogLevel.Warning;

        /// <summary>
        /// Where lines go. Replace it to route the SDK into your own logger — a crash reporter, a
        /// file, an in-game console — instead of the Unity console.
        /// </summary>
        public static Action<ImLogLevel, string, Exception> Sink = DefaultSink;

        /// <summary>Writes an error.</summary>
        public static void Error(string message, Exception error = null)
        {
            Write(ImLogLevel.Error, message, error);
        }

        /// <summary>Writes a warning.</summary>
        public static void Warn(string message, Exception error = null)
        {
            Write(ImLogLevel.Warning, message, error);
        }

        /// <summary>Writes a lifecycle line.</summary>
        public static void Info(string message)
        {
            Write(ImLogLevel.Info, message, null);
        }

        /// <summary>Writes a frame-level trace line.</summary>
        public static void Verbose(string message)
        {
            Write(ImLogLevel.Verbose, message, null);
        }

        private static void Write(ImLogLevel level, string message, Exception error)
        {
            if (level > Level)
            {
                return;
            }

            var sink = Sink;
            if (sink == null)
            {
                return;
            }

            try
            {
                sink(level, message, error);
            }
            catch
            {
                // A logger that throws must never take the connection down with it.
            }
        }

        private static void DefaultSink(ImLogLevel level, string message, Exception error)
        {
            var line = "[Cyaim.Im] " + message;
            if (error != null)
            {
                line += " :: " + error;
            }

            switch (level)
            {
                case ImLogLevel.Error:
                    UnityEngine.Debug.LogError(line);
                    break;
                case ImLogLevel.Warning:
                    UnityEngine.Debug.LogWarning(line);
                    break;
                default:
                    UnityEngine.Debug.Log(line);
                    break;
            }
        }
    }
}
