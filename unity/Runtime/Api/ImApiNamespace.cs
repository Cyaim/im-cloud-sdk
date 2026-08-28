using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// Base of the typed endpoint groups hanging off <see cref="ImClient"/> — <c>im.Msg</c>,
    /// <c>im.Conv</c>, <c>im.Group</c> and the rest.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The grouping is not decoration. The gateway publishes 107 endpoints; 107 flat methods on one
    /// object is not an API, it is a scroll bar. Each group is named exactly for the target prefix,
    /// and each method exactly for the method half of the target, so a reader who knows
    /// <c>group.memberList</c> knows to write <c>im.Group.MemberListAsync(…)</c> without a lookup
    /// table — in this SDK and in the other four.
    /// </para>
    /// <para>
    /// Everything here is a thin wrapper over the same internal request path <c>InvokeAsync</c>
    /// uses. That is deliberate: two paths would drift on timeouts, cancellation, error mapping and
    /// logging, and the drift would be found by a customer rather than by us.
    /// </para>
    /// </remarks>
    public abstract class ImApiNamespace
    {
        /// <summary>The client this group belongs to.</summary>
        protected readonly ImClient Client;

        internal ImApiNamespace(ImClient client)
        {
            Client = client;
        }

        /// <summary>Sends a request and returns its <c>data</c> payload, unwrapped.</summary>
        protected Task<JsonValue> RequestAsync(string target, IImRequest request, CancellationToken cancellationToken)
        {
            return Client.SendRequestAsync(target, request != null ? request.ToJson() : null, cancellationToken);
        }

        /// <summary>Sends a request whose payload carries nothing worth returning.</summary>
        protected async Task ExecuteAsync(string target, IImRequest request, CancellationToken cancellationToken)
        {
            await Client.SendRequestAsync(target, request != null ? request.ToJson() : null, cancellationToken)
                .ConfigureAwait(false);
        }

        /// <summary>Sends a request and maps its payload to one object.</summary>
        protected async Task<T> RequestAsync<T>(string target, IImRequest request, CancellationToken cancellationToken)
            where T : IImJsonPayload, new()
        {
            var data = await RequestAsync(target, request, cancellationToken).ConfigureAwait(false);
            return ImPayload.Read<T>(data);
        }

        /// <summary>Sends a request and maps its payload to a list.</summary>
        protected async Task<List<T>> RequestListAsync<T>(
            string target,
            IImRequest request,
            CancellationToken cancellationToken)
            where T : IImJsonPayload, new()
        {
            var data = await RequestAsync(target, request, cancellationToken).ConfigureAwait(false);
            return ImPayload.ReadList<T>(data);
        }

        /// <summary>Sends a request and maps its payload to one page of a cursor-paginated list.</summary>
        /// <remarks>
        /// The page is returned whole rather than flattened to a bare list. <c>nextCursor</c> is the
        /// only correct way to page — a caller that guesses from the item count is wrong, because a
        /// page can come back short of its limit while <c>hasMore</c> is true (deleted rows are
        /// filtered after the cursor is computed) — and an SDK that hides it forces the application
        /// into that wrong loop.
        /// </remarks>
        protected async Task<ImPage<T>> RequestPageAsync<T>(
            string target,
            IImRequest request,
            CancellationToken cancellationToken)
            where T : IImJsonPayload, new()
        {
            var data = await RequestAsync(target, request, cancellationToken).ConfigureAwait(false);
            return ImPage<T>.FromJson(data, ImPayload.Read<T>);
        }

        /// <summary>Throws when a required field was left null or empty, naming it.</summary>
        protected static void Require(string value, string name)
        {
            if (string.IsNullOrEmpty(value))
            {
                throw new ArgumentException(name + " is required", name);
            }
        }

        /// <summary>Throws when the caller passed no request object at all.</summary>
        protected static T RequireRequest<T>(T request) where T : class
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }

            return request;
        }
    }
}
