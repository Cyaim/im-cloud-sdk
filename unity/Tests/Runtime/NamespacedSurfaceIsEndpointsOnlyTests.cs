using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// Every method on the namespaced surface is an endpoint. Nothing else may live there.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>sdk/CONTRACT.md</c> §4.1–4.2: the typed surface is the endpoint list transliterated, so a
    /// reader who knows an endpoint name knows the call, in every language, without a lookup table
    /// — and a support engineer can grep a bug report for the target that failed. A convenience
    /// method with no endpoint behind it breaks both halves of that.
    /// </para>
    /// <para>
    /// This exists because it happened. This SDK grew <c>ImMsgApi.SendTextAsync</c>, for which
    /// <c>msg.sendText</c> is not and never was an endpoint; the other four expose <c>sendText</c>
    /// only as a flat legacy alias, and this SDK's own deprecation messages pointed <i>at</i> the
    /// invented method, so it was actively teaching the wrong shape. A reviewer will not catch the
    /// next one either, which is why this is a test rather than a rule.
    /// </para>
    /// <para>
    /// The nine frozen legacy aliases of §4.2 are deliberately not covered: they live on
    /// <see cref="ImClient"/>, not on a namespace, and that separation is the point.
    /// </para>
    /// <para>
    /// 命名空间层只能有端点。这条规则被破坏过一次：ImMsgApi.SendTextAsync 背后根本没有
    /// msg.sendText 这个端点，而废弃提示还在指向它。
    /// </para>
    /// </remarks>
    [TestFixture]
    public sealed class NamespacedSurfaceIsEndpointsOnlyTests
    {
        /// <summary>Namespace type to the target prefix it mirrors.</summary>
        private static readonly Dictionary<Type, string> Namespaces = new Dictionary<Type, string>
        {
            { typeof(ImConnApi), "conn" },
            { typeof(ImMsgApi), "msg" },
            { typeof(ImConvApi), "conv" },
            { typeof(ImUserApi), "user" },
            { typeof(ImFriendApi), "friend" },
            { typeof(ImGroupApi), "group" },
            { typeof(ImMediaApi), "media" },
            { typeof(ImPushApi), "push" },
        };

        /// <summary>
        /// Members that are policy rather than endpoints, and are the same on all five platforms.
        /// </summary>
        /// <remarks>
        /// The push token cache is the whole of it: §6.2 requires the SDK to re-register on every
        /// connect, and that needs somewhere to keep the token. <c>SetToken</c> / <c>ClearToken</c>
        /// is the pair, spelled that way in all five SDKs.
        /// </remarks>
        private static readonly HashSet<string> AllowedNonEndpoints = new HashSet<string>(StringComparer.Ordinal)
        {
            "SetToken",
            "ClearToken",
            "HasToken",
            "IsRegistered",
        };

        [Test]
        public void No_namespaced_method_exists_without_an_endpoint_behind_it()
        {
            var endpoints = EndpointTargets();
            var strays = new List<string>();

            foreach (var entry in Namespaces)
            {
                var methods = entry.Key.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly);

                foreach (var method in methods)
                {
                    if (method.IsSpecialName)
                    {
                        continue; // property accessors
                    }

                    if (AllowedNonEndpoints.Contains(method.Name))
                    {
                        continue;
                    }

                    var target = entry.Value + "." + MethodPart(method.Name);
                    if (!endpoints.Contains(target))
                    {
                        strays.Add(entry.Key.Name + "." + method.Name + " implies " + target);
                    }
                }
            }

            Assert.That(
                strays,
                Is.Empty,
                "these namespaced methods name endpoints the server does not have. Either the " +
                "endpoint exists and endpoint-inventory.json needs regenerating, or the method is " +
                "an invention and belongs on ImClient as a flat alias (sdk/CONTRACT.md §4.2): " +
                string.Join("; ", strays.ToArray()));
        }

        [Test]
        public void Msg_sendText_is_not_on_the_namespaced_surface()
        {
            // The specific regression, named, so the failure message says what went wrong rather
            // than making a reader re-derive it from a list of strays.
            Assert.That(
                typeof(ImMsgApi).GetMethod("SendTextAsync", BindingFlags.Public | BindingFlags.Instance),
                Is.Null,
                "msg.sendText is not an endpoint. The flat im.SendTextAsync alias stays; the " +
                "namespaced one must not come back (sdk/CONTRACT.md §4.2).");

            // …and the alias it replaced is still there, because §4.2 freezes those nine until 2.0.
            Assert.That(
                typeof(ImClient).GetMethod("SendTextAsync", BindingFlags.Public | BindingFlags.Instance),
                Is.Not.Null,
                "the flat alias is frozen surface: it appears in every published sample");
        }

        /// <summary><c>CancelScheduledAsync</c> -> <c>cancelScheduled</c>.</summary>
        private static string MethodPart(string name)
        {
            var trimmed = name.EndsWith("Async", StringComparison.Ordinal)
                ? name.Substring(0, name.Length - "Async".Length)
                : name;

            if (trimmed.Length == 0)
            {
                return trimmed;
            }

            return char.ToLowerInvariant(trimmed[0]) + trimmed.Substring(1);
        }

        /// <summary>
        /// Every target the generator found on the server, read out of the inventory rather than
        /// listed here — a list here would be the very thing that goes stale.
        /// </summary>
        private static HashSet<string> EndpointTargets([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);

            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                var candidate = Path.Combine(directory, "endpoint-inventory.json");
                if (File.Exists(candidate))
                {
                    var targets = new HashSet<string>(StringComparer.Ordinal);
                    foreach (Match match in Regex.Matches(
                                 File.ReadAllText(candidate), "\"target\"\\s*:\\s*\"([^\"]+)\""))
                    {
                        targets.Add(match.Groups[1].Value);
                    }

                    Assert.That(targets, Is.Not.Empty, "the inventory parsed to no targets at all");
                    return targets;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }
    }
}
