using System.Collections.Generic;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The JSON <i>kind</i> of what a request puts on the wire, checked against the server's C# type.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The gateway's socket binder converts each request member to the C# type the server declares
    /// and refuses a mismatch outright: a JSON number for a <c>string</c>, a quoted number for a
    /// <c>long</c>, <c>1</c> for a <c>bool</c>, a name for an enum. The call answers
    /// <c>1000 InternalError</c> before the endpoint runs, on every attempt, with nothing naming the
    /// field. So the rule for a request is: send each member as the JSON kind of the server's type.
    /// 请求字段一律按服务端 C# 类型的 JSON 形态发送：string→字符串、long/int/枚举→整数、bool→true/false。
    /// </para>
    /// <para>
    /// Every assertion here reads through <see cref="WireJson"/>, because <see cref="JsonValue"/>'s
    /// own readers cannot see the kind — which is how <see cref="ImSendRequest.QuoteMessageId"/> went
    /// out as a JSON number while the server's <c>SendMessageRequest.QuoteMessageId</c> is a
    /// <c>string?</c>: every send that quoted a message came back 1000.
    /// </para>
    /// </remarks>
    public sealed class WireKindTests
    {
        /// <summary>Odd and past 2^53, so a trip through a double changes its last digits.</summary>
        private const long QuotedValue = 360381357961969667L;

        private const string Quoted = "360381357961969667";

        private ImTestHarness _harness;

        [SetUp]
        public void SetUp()
        {
            _harness = new ImTestHarness();
            _harness.Connect();
        }

        [TearDown]
        public void TearDown()
        {
            _harness.Dispose();
        }

        /// <summary>The readers the whole suite now asserts through can tell 7 from "7".</summary>
        /// <remarks>
        /// A strict reader that quietly went lenient would turn every kind assertion in this suite
        /// back into a value assertion, and nothing would go red. This is the control for that.
        /// </remarks>
        [Test]
        public void The_strict_readers_see_the_kind_the_lenient_ones_hide()
        {
            var body = JsonValue.Parse(
                "{\"number\":7,\"quoted\":\"7\",\"one\":1,\"half\":1.5,\"yes\":true,"
                + "\"ids\":[\"7\",8],\"huge\":4294967296}");

            // What the lenient readers say: the same thing for both kinds.
            Assert.That(body["number"].AsString(), Is.EqualTo("7"));
            Assert.That(body["quoted"].AsLong(), Is.EqualTo(7));
            Assert.That(body["one"].AsBool(), Is.True);

            // What the strict ones say.
            Assert.That(body["quoted"].WireString(), Is.EqualTo("7"));
            Assert.That(body["number"].WireLong(), Is.EqualTo(7));
            Assert.That(body["number"].WireInt(), Is.EqualTo(7));
            Assert.That(body["yes"].WireBool(), Is.True);

            Assert.Throws<AssertionException>(delegate { body["number"].WireString(); }, "a number sent to a C# string");
            Assert.Throws<AssertionException>(delegate { body["quoted"].WireLong(); }, "a quoted number sent to a C# long");
            Assert.Throws<AssertionException>(delegate { body["quoted"].WireInt(); }, "a quoted number sent to a C# int");
            Assert.Throws<AssertionException>(delegate { body["half"].WireLong(); }, "a fraction sent to a C# long");
            Assert.Throws<AssertionException>(delegate { body["huge"].WireInt(); }, "past the range of a C# int");
            Assert.Throws<AssertionException>(delegate { body["one"].WireBool(); }, "1 sent to a C# bool");
            Assert.Throws<AssertionException>(delegate { body["ids"].WireStrings(); }, "a number inside a List<string>");
            Assert.Throws<AssertionException>(delegate { body["missing"].WireString(); }, "an absent member");
            Assert.Throws<AssertionException>(delegate { body["quoted"].WireStrings(); }, "a scalar where a list belongs");
        }

        /// <summary>
        /// <see cref="ImSendRequest.QuoteMessageId"/> is a <c>long</c> in the API and a JSON string on
        /// the wire, with every digit.
        /// </summary>
        /// <remarks>
        /// The public member stays a <c>long</c> so it takes an <see cref="ImMessage.MessageId"/>
        /// unconverted; the server's member is a <c>string?</c>, so the conversion happens in the body.
        /// 公开字段仍是 long（可以直接接 ImMessage.MessageId），线路上是字符串。
        /// </remarks>
        [Test]
        public void A_quoted_message_travels_as_a_string_with_every_digit()
        {
            var request = ImTestHarness.TextMessage(ImRecipient.Conversation("g_team"), "agreed");
            request.QuoteMessageId = QuotedValue;

            var body = Sent(_harness.Client.Msg.SendAsync(request));

            Assert.That(body["quoteMessageId"].WireString(), Is.EqualTo(Quoted),
                "the server's SendMessageRequest.QuoteMessageId is a string?; a JSON number there is 1000");

            var plain = Sent(_harness.Client.Msg.SendAsync(
                ImTestHarness.TextMessage(ImRecipient.Conversation("g_team"), "no quote")));
            Assert.That(plain.Has("quoteMessageId"), Is.False, "a member left null is not a member set to null");
        }

        /// <summary>Every member a fully populated send can carry, each in the server's kind.</summary>
        /// <remarks>
        /// The key set is exact, so it also records what this SDK does not send:
        /// <c>threadRootId</c> and <c>conversationType</c> have no member on
        /// <see cref="ImSendRequest"/>.
        /// </remarks>
        [Test]
        public void Every_member_of_a_fully_populated_send_has_the_servers_kind()
        {
            var body = Sent(_harness.Client.Msg.SendAsync(new ImSendRequest
            {
                Recipient = ImRecipient.User("bob"),
                ContentType = ImMessageContentType.Image,
                Content = JsonValue.NewObject().Set("url", "objects/abc"),
                ClientMsgId = "cm-wire-1",
                MentionedUserIds = new[] { "carol", "dave" },
                MentionAll = true,
                QuoteMessageId = QuotedValue,
                Options = JsonValue.NewObject().Set("needReceipt", true),
                Extensions = JsonValue.NewObject().Set("quest", "q7"),
            }));

            AssertKeys(body,
                "receiverId", "contentType", "content", "clientMsgId", "sendTime",
                "mentionAll", "mentionedUserIds", "quoteMessageId", "options", "extensions");

            Assert.That(body["receiverId"].WireString(), Is.EqualTo("bob"));
            Assert.That(body["contentType"].WireInt(), Is.EqualTo(2), "an enum member takes its integer; the binder refuses the name");
            Assert.That(body["content"].Kind, Is.EqualTo(JsonKind.Object));
            Assert.That(body["clientMsgId"].WireString(), Is.EqualTo("cm-wire-1"));
            Assert.That(body["sendTime"].WireLong(), Is.GreaterThan(0));
            Assert.That(body["mentionAll"].WireBool(), Is.True);
            Assert.That(body["mentionedUserIds"].WireStrings(), Is.EqualTo(new[] { "carol", "dave" }));
            Assert.That(body["quoteMessageId"].WireString(), Is.EqualTo(Quoted));
            Assert.That(body["options"].Kind, Is.EqualTo(JsonKind.Object));
            Assert.That(body["extensions"].Kind, Is.EqualTo(JsonKind.Object));
        }

        /// <summary>Each of the three addressing modes names its target by a string, and only one.</summary>
        [Test]
        public void Every_addressing_mode_sends_one_string_id()
        {
            var modes = new Dictionary<string, ImRecipient>
            {
                { "receiverId", ImRecipient.User("bob") },
                { "groupId", ImRecipient.Group("guild-7") },
                { "conversationId", ImRecipient.Conversation("c1") },
            };

            foreach (var mode in modes)
            {
                var body = Sent(_harness.Client.Msg.SendAsync(ImTestHarness.TextMessage(mode.Value, "hi")));

                Assert.That(body[mode.Key].WireString(), Is.Not.Empty, mode.Key);
                foreach (var other in modes.Keys)
                {
                    if (other != mode.Key)
                    {
                        Assert.That(body.Has(other), Is.False, mode.Key + " also sent " + other);
                    }
                }
            }
        }

        private static void AssertKeys(JsonValue body, params string[] expected)
        {
            var actual = new List<string>();
            foreach (var member in body.Members)
            {
                actual.Add(member.Key);
            }

            Assert.That(actual, Is.EquivalentTo(expected), "body was " + body.ToJson());
        }

        private JsonValue Sent(Task pending)
        {
            ImTestHarness.Forget(pending);
            _harness.Pump();

            var requests = _harness.Socket.Requests;
            Assert.That(requests, Is.Not.Empty);

            var last = requests[requests.Count - 1];
            Assert.That(last.Target, Is.EqualTo("msg.send"));
            return last.Body;
        }
    }
}
