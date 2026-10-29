using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// <see cref="ImConversationIds.SingleConversationId"/> against the shared vectors in
    /// <c>single-chat-id-vectors.json</c> at the root of the SDK repository — the same file the
    /// server's <c>SingleChatIdVectorTests</c>, the widget and every other SDK read.
    /// </summary>
    /// <remarks>
    /// A single-chat id one side builds differently is not an error anywhere: it is a second
    /// conversation, or one nobody can read. So the expected ids come from the file, written out from
    /// the grammar, never from this implementation — implementations that only check each other agree
    /// forever, including on the day they are all wrong.
    /// 单聊 id 对着共享向量断言：一端拼得不一样不会报错，得到的是第二个会话或谁也读不了的会话。
    /// 期望值来自那份文件，不来自被测实现。
    /// </remarks>
    public sealed class SingleChatIdTests
    {
        [Test]
        public void Builds_every_build_vector_whichever_end_comes_first()
        {
            var build = Vectors()["build"];
            Assert.That(build.Count, Is.GreaterThan(0), "single-chat-id-vectors.json has no build vectors");

            foreach (var v in build.Items)
            {
                var a = v["a"].AsString();
                var b = v["b"].AsString();
                var id = v["id"].AsString();

                Assert.That(ImConversationIds.SingleConversationId(a, b), Is.EqualTo(id),
                    "'" + a + "' + '" + b + "' (" + v["note"].AsString(string.Empty) + ")");
                Assert.That(ImConversationIds.SingleConversationId(b, a), Is.EqualTo(id),
                    "'" + b + "' + '" + a + "', ends swapped");
            }
        }

        [Test]
        public void Rebuilds_every_id_the_file_says_parses_from_the_pair_it_parses_to()
        {
            var parsed = 0;
            foreach (var v in Vectors()["parse"].Items)
            {
                if (!v["ok"].AsBool())
                {
                    continue;
                }

                var id = v["id"].AsString();
                var a = v["a"].AsString();
                var b = v["b"].AsString();
                Assert.That(a != null && b != null, Is.True, "parse vector '" + id + "' is ok but names no pair");
                Assert.That(ImConversationIds.SingleConversationId(a, b), Is.EqualTo(id), id);
                parsed++;
            }

            Assert.That(parsed, Is.GreaterThan(0), "single-chat-id-vectors.json has no parse vectors that parse");
        }

        [Test]
        public void Never_builds_an_id_the_file_refuses()
        {
            var vectors = Vectors();
            var refused = new HashSet<string>(StringComparer.Ordinal);
            foreach (var v in vectors["parse"].Items)
            {
                if (!v["ok"].AsBool())
                {
                    refused.Add(v["id"].AsString());
                }
            }

            Assert.That(refused.Count, Is.GreaterThan(0), "single-chat-id-vectors.json has no refused parse vectors");

            foreach (var v in vectors["build"].Items)
            {
                var a = v["a"].AsString();
                var b = v["b"].AsString();
                var id = ImConversationIds.SingleConversationId(a, b);
                Assert.That(refused.Contains(id), Is.False,
                    "'" + a + "' + '" + b + "' built '" + id + "', which the file lists as malformed");
            }
        }

        [Test]
        public void Still_has_the_vectors_this_implementation_is_easiest_to_get_wrong_on()
        {
            // Named rather than counted: a file trimmed to make a failure go away keeps a count plausible.
            // 点名而不是数数：为了让失败消失而删掉几条之后，数量照样说得过去。
            var built = new HashSet<string>(StringComparer.Ordinal);
            foreach (var v in Vectors()["build"].Items)
            {
                built.Add(v["id"].AsString());
            }

            foreach (var id in new[] { "s_alice_bob", "s_u~1alice_u~1bob", "s_a~01_c", "s_user~11_user~110", "s_\U0001F600_Ａ" })
            {
                Assert.That(built.Contains(id), Is.True, "build vector '" + id + "' is missing from single-chat-id-vectors.json");
            }
        }

        private static JsonValue Vectors()
        {
            return JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "single-chat-id-vectors.json"), Encoding.UTF8));
        }

        private static string SdkRoot([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);
            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                if (File.Exists(Path.Combine(directory, "single-chat-id-vectors.json")))
                {
                    return directory;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/single-chat-id-vectors.json from " + here);
        }
    }
}
