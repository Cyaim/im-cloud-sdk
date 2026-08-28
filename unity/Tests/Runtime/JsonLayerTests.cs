using System;
using System.Globalization;
using System.Threading;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The hand-written JSON layer. Every one of these tests is a bug that shipped in some client
    /// somewhere.
    /// </summary>
    public sealed class JsonLayerTests
    {
        [Test]
        public void Snowflake_ids_survive_the_round_trip()
        {
            // Past 2^53 a double silently rounds, and two different messages start comparing equal.
            // Parsers that keep every number as a double get this wrong, which is why this one keeps
            // integers as long.
            const long messageId = 7318349286351294977L;

            var parsed = JsonValue.Parse("{\"messageId\":" + messageId.ToString(CultureInfo.InvariantCulture) + "}");

            Assert.That(parsed["messageId"].AsLong(), Is.EqualTo(messageId));
            Assert.That(parsed.ToJson(), Does.Contain(messageId.ToString(CultureInfo.InvariantCulture)));
        }

        [Test]
        public void Numbers_are_written_the_same_way_in_every_locale()
        {
            var previous = Thread.CurrentThread.CurrentCulture;
            try
            {
                // On a device whose locale writes a decimal comma, culture-sensitive formatting
                // emits 1,5 and the gateway rejects the frame — a bug that never reproduces on the
                // developer's machine.
                Thread.CurrentThread.CurrentCulture = new CultureInfo("de-DE");

                var json = JsonValue.NewObject().Set("ratio", 1.5).ToJson();
                Assert.That(json, Is.EqualTo("{\"ratio\":1.5}"));

                Assert.That(JsonValue.Parse("{\"ratio\":1.5}")["ratio"].AsDouble(), Is.EqualTo(1.5));
            }
            finally
            {
                Thread.CurrentThread.CurrentCulture = previous;
            }
        }

        [Test]
        public void Text_that_is_not_english_survives()
        {
            var original = "你好，世界 🎮 \"quoted\" \\ tab\there";
            var json = JsonValue.NewObject().Set("text", original).ToJson();

            Assert.That(JsonValue.Parse(json)["text"].AsString(), Is.EqualTo(original));
        }

        [Test]
        public void Escaped_unicode_is_decoded_including_surrogate_pairs()
        {
            var parsed = JsonValue.Parse("{\"text\":\"\\u4f60\\u597d \\ud83c\\udfae\"}");

            Assert.That(parsed["text"].AsString(), Is.EqualTo("你好 🎮"));
        }

        [Test]
        public void A_missing_member_reads_as_null_rather_than_throwing()
        {
            var frame = JsonValue.Parse("{\"body\":{}}");

            // A client does not get to choose what a server sends it, and a chain of lookups on a
            // partial payload must not take the receive loop down.
            Assert.That(frame["body"]["data"]["message"]["seq"].AsLong(), Is.Zero);
            Assert.That(frame["nope"].IsNull, Is.True);
            Assert.That(frame["nope"].AsString("fallback"), Is.EqualTo("fallback"));
        }

        [Test]
        public void Member_lookup_ignores_case()
        {
            // SPEC-02 writes the envelope PascalCase; the gateway serialises it camelCase today.
            // One decoder that reads both means a serialiser policy change cannot break shipped
            // clients.
            var frame = JsonValue.Parse("{\"Id\":\"srv-1\",\"Target\":\"evt.message\",\"Status\":0}");

            Assert.That(frame["id"].AsString(), Is.EqualTo("srv-1"));
            Assert.That(frame["TARGET"].AsString(), Is.EqualTo("evt.message"));
            Assert.That(frame.Has("status"), Is.True);
        }

        [Test]
        public void A_quoted_id_is_read_as_a_number()
        {
            // Gateways written in languages where JSON numbers are doubles quote their large ids.
            // Refusing to read one would be pedantry that loses messages.
            Assert.That(JsonValue.Parse("{\"seq\":\"421\"}")["seq"].AsLong(), Is.EqualTo(421));
        }

        [Test]
        public void Malformed_payloads_are_rejected_with_a_position()
        {
            Assert.Throws<ImJsonException>(delegate { JsonValue.Parse("{\"a\":}"); });
            Assert.Throws<ImJsonException>(delegate { JsonValue.Parse("{\"a\":1"); });
            Assert.Throws<ImJsonException>(delegate { JsonValue.Parse("{} trailing"); });

            JsonValue value;
            Assert.That(ImJson.TryParse("not json", out value), Is.False);
            Assert.That(value.IsNull, Is.True);
        }

        [Test]
        public void Absurd_nesting_is_refused_instead_of_overflowing_the_stack()
        {
            // A socket is untrusted input even when the server is friendly, and a stack overflow is
            // not something a try/catch in the game can survive.
            var deep = new string('[', ImJson.MaxDepth + 8);

            Assert.Throws<ImJsonException>(delegate { JsonValue.Parse(deep); });
        }

        [Test]
        public void Objects_and_arrays_build_and_read_back()
        {
            var payload = JsonValue.NewObject()
                .Set("conversationId", "c1")
                .Set("mentionAll", true)
                .Set("mentionedUserIds", JsonValue.ArrayOf(new[] { "alice", "bob" }))
                .Set("convSeqs", JsonValue.ObjectOf(new[]
                {
                    new System.Collections.Generic.KeyValuePair<string, long>("c1", 12),
                }));

            var parsed = JsonValue.Parse(payload.ToJson());

            Assert.That(parsed["conversationId"].AsString(), Is.EqualTo("c1"));
            Assert.That(parsed["mentionAll"].AsBool(), Is.True);
            Assert.That(parsed["mentionedUserIds"].Count, Is.EqualTo(2));
            Assert.That(parsed["mentionedUserIds"][1].AsString(), Is.EqualTo("bob"));
            Assert.That(parsed["convSeqs"]["c1"].AsLong(), Is.EqualTo(12));
        }

        [Test]
        public void A_null_member_is_left_out_so_absent_stays_absent()
        {
            // "not set" and "set to null" mean different things to the server: one keeps the stored
            // value, the other clears it.
            var json = JsonValue.NewObject().Set("draft", (string)null).ToJson();

            Assert.That(json, Is.EqualTo("{}"));
        }

        [Test]
        public void A_message_maps_out_of_its_payload()
        {
            var message = ImMessage.FromJson(JsonValue.Parse(
                "{\"conversationId\":\"c1\",\"seq\":9,\"messageId\":7318349286351294977," +
                "\"contentType\":1,\"senderId\":\"bob\",\"content\":{\"text\":\"hi\"}," +
                "\"reactions\":{\"👍\":[\"alice\"]},\"recalled\":{\"operatorId\":\"admin\",\"byAdmin\":true}}"));

            Assert.That(message.ConversationId, Is.EqualTo("c1"));
            Assert.That(message.Seq, Is.EqualTo(9));
            Assert.That(message.MessageId, Is.EqualTo(7318349286351294977L));
            Assert.That(message.Text, Is.EqualTo("hi"));
            Assert.That(message.ContentType, Is.EqualTo(ImMessageContentType.Text));
            Assert.That(message.Reactions["👍"], Is.EqualTo(new[] { "alice" }));
            Assert.That(message.Recalled.ByAdmin, Is.True);
            Assert.That(message.MentionedUserIds, Is.Empty, "a list is never null");
        }
    }
}
