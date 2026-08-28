using System;

namespace Cyaim.Im
{
    /// <summary>
    /// Raises an event so that one bad subscriber cannot take the rest of them — or the connection
    /// — down with it.
    /// </summary>
    /// <remarks>
    /// A plain <c>handler(argument)</c> invocation stops at the first subscriber that throws, and
    /// the ones registered after it never run. In this SDK the thing that throws is usually a
    /// <c>NullReferenceException</c> in a chat-bubble prefab, and the handler that would have been
    /// skipped is the one that advances a read cursor or repairs a gap. Worse, the exception would
    /// unwind into the dispatcher pump, i.e. into the middle of the receive path.
    /// </remarks>
    internal static class ImSafeEvent
    {
        /// <summary>Invokes every subscriber, logging and swallowing whatever any of them throws.</summary>
        internal static void Raise<T>(Action<T> handlers, T argument)
        {
            if (handlers == null)
            {
                return;
            }

            var subscribers = handlers.GetInvocationList();
            for (int i = 0; i < subscribers.Length; i++)
            {
                try
                {
                    ((Action<T>)subscribers[i])(argument);
                }
                catch (Exception error)
                {
                    ImLog.Error("an event handler threw and was ignored", error);
                }
            }
        }

        /// <summary>Invokes a single handler, logging and swallowing whatever it throws.</summary>
        internal static void Invoke<T>(Action<T> handler, T argument)
        {
            if (handler == null)
            {
                return;
            }

            try
            {
                handler(argument);
            }
            catch (Exception error)
            {
                ImLog.Error("a listener threw and was ignored", error);
            }
        }
    }
}
