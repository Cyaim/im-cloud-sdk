using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// <c>keys.*</c> — the end-to-end encryption key directory: <c>publish</c>, <c>upload</c>,
    /// <c>remaining</c>, <c>claim</c>, <c>devices</c>, <c>revoke</c>, <c>safetyNumber</c>.
    /// </summary>
    /// <remarks>
    /// Every call is asserted on the frame it puts on the wire — target and the whole body, by JSON kind,
    /// with the nested <c>signedPreKey</c> / <c>oneTimePreKeys[]</c> / <c>keys[]</c> names exact (the
    /// binder matches them case-sensitively and requires them) — and every reply is decoded from a fixture
    /// with every member set; both are held to the inventory's <c>payloadTypes</c>. Then the rules an
    /// integrator cannot read off a signature: key material goes out unchanged and reaches no log; a claim
    /// consumes, so it is sent once and never again; an empty pool is a bundle without a one-time prekey;
    /// the directory's refusals are ordinary errors with the server's words.
    /// 每个调用断言整帧（按 JSON 形态，嵌套成员的名字逐字），每个答复用全字段夹具解码，两者都对着清单的 payloadTypes 钉住；
    /// 再加签名上看不出的规则：密钥材料原样发出、不进任何日志；领取会消耗，所以只发一次、绝不重发；池空时密钥包里没有一次性预密钥；
    /// 目录的拒绝是带服务端原文的普通错误。
    /// </remarks>
    public sealed class KeysTests
    {
        // Standard base64 with '+', '/' and '=' in it: a re-encoding (base64url, stripped padding,
        // escaped slashes) would show up as a different string.
        private const string IdentityKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";

        private const string SpkPublic = "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=";

        private const string SpkSignature = "c2lnbmF0dXJlLW92ZXItc3BrLXB1YmxpYw/+8w==";

        private const string Otk1 = "b3RrLTEvKys=";

        private const string Otk2 = "b3RrLTIvKys=";

        private const string Algorithm = "x3dh-ed25519-aes256gcm-v1";

        private static readonly string[] Material = { IdentityKey, SpkPublic, SpkSignature, Otk1, Otk2 };

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

        // ------------------------------------------------------------------ fixtures

        private static ImPublishKeysRequest FullPublish()
        {
            return new ImPublishKeysRequest(
                IdentityKey,
                new ImSignedPreKey("spk_1", SpkPublic, SpkSignature, 1758412800000L),
                new ImOneTimePreKey("otk_1", Otk1),
                new ImOneTimePreKey("otk_2", Otk2))
            {
                Algorithm = Algorithm,
            };
        }

        private static JsonValue SignedPreKeyJson()
        {
            return JsonValue.NewObject()
                .Set("keyId", "spk_1")
                .Set("publicKey", SpkPublic)
                .Set("signature", SpkSignature)
                .Set("createdAt", 1758412800000L);
        }

        /// <summary>A bundle with every member set, as the server writes one with a key left in the pool.</summary>
        private static JsonValue Bundle()
        {
            return JsonValue.NewObject()
                .Set("userId", "u_bob")
                .Set("deviceId", "device-9")
                .Set("identityKey", IdentityKey)
                .Set("signedPreKey", SignedPreKeyJson())
                .Set("oneTimePreKey", JsonValue.NewObject().Set("keyId", "otk_1").Set("publicKey", Otk1))
                .Set("algorithm", Algorithm);
        }

        /// <summary>The same with the pool empty: the server omits <c>oneTimePreKey</c> rather than writing null.</summary>
        private static JsonValue BundleFromAnEmptyPool()
        {
            return JsonValue.NewObject()
                .Set("userId", "u_bob")
                .Set("deviceId", "device-9")
                .Set("identityKey", IdentityKey)
                .Set("signedPreKey", SignedPreKeyJson())
                .Set("algorithm", Algorithm);
        }

        private static JsonValue Device(string deviceId, long platform, int remaining)
        {
            return JsonValue.NewObject()
                .Set("deviceId", deviceId)
                .Set("platform", platform)
                .Set("identityKey", IdentityKey)
                .Set("publishedAt", 1758412800123L)
                .Set("remainingOneTimeKeys", (long)remaining);
        }

        // ------------------------------------------------------------------ helpers

        private T Answered<T>(Task<T> pending, string target, JsonValue data)
        {
            _harness.Pump();
            _harness.Socket.Reply(target, data);
            _harness.Pump();

            Assert.That(pending.IsCompleted, Is.True, target + " did not complete");
            return pending.Result;
        }

        private JsonValue Acknowledged(Task pending, string target)
        {
            _harness.Pump();
            var body = _harness.Socket.LastBody(target);
            Assert.That(body, Is.Not.Null, target + " never reached the socket");

            _harness.Socket.Reply(target, JsonValue.Null);
            _harness.Pump();
            Assert.That(pending.IsCompleted && !pending.IsFaulted, Is.True, target + " did not succeed");
            return body;
        }

        /// <summary>
        /// Answers the newest request for a target with the envelope the server writes for a failure:
        /// a code, its own message, and no <c>data</c> member at all.
        /// </summary>
        private ImException RefusedInWords(Task pending, string target, int code, string message)
        {
            AnswerNewest(target, JsonValue.NewObject()
                .Set("code", (long)code)
                .Set("message", message)
                .Set("serverTime", 1767225600000L)
                .Set("traceId", "tr-keys"));

            Assert.That(pending.IsFaulted, Is.True, target + " should have failed with " + code);
            var error = pending.Exception.GetBaseException() as ImException;
            Assert.That(error, Is.Not.Null, "an ordinary ImException, not a decoding failure");
            Assert.That(error.Code, Is.EqualTo(code));
            Assert.That(error.Message, Is.EqualTo(message), "the server's own words reach the caller");
            Assert.That(error.Target, Is.EqualTo(target));
            Assert.That(error.TraceId, Is.EqualTo("tr-keys"));
            return error;
        }

        /// <summary>Delivers a reply envelope, exactly as given, to the newest request for a target.</summary>
        private void AnswerNewest(string target, JsonValue envelope)
        {
            _harness.Pump();

            string id = null;
            foreach (var request in _harness.Socket.Requests)
            {
                if (request.Target == target)
                {
                    id = request.Id;
                }
            }

            Assert.That(id, Is.Not.Null, target + " never reached the socket");

            _harness.Socket.Deliver(JsonValue.NewObject()
                .Set("id", id)
                .Set("target", target)
                .Set("status", 0L)
                .Set("body", envelope)
                .ToJson());
            _harness.Pump();
        }

        private static List<string> Keys(JsonValue body)
        {
            var keys = new List<string>();
            foreach (var member in body.Members)
            {
                keys.Add(member.Key);
            }

            keys.Sort(StringComparer.Ordinal);
            return keys;
        }

        /// <summary>Claims put on the wire, on every socket the client has had.</summary>
        private int ClaimsSent()
        {
            var count = 0;
            foreach (var transport in _harness.Transports)
            {
                count += transport.CountOf("keys.claim");
            }

            return count;
        }

        private void AssertNothingSentSince(int before)
        {
            _harness.Pump();
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before), "nothing reached the socket");
        }

        // ------------------------------------------------------------------ keys.publish

        [Test]
        public void Publish_with_every_member_sends_each_in_the_servers_kind_with_the_nested_names_exact()
        {
            var before = _harness.Socket.Requests.Count;
            var body = Acknowledged(_harness.Client.Keys.PublishAsync(FullPublish()), "keys.publish");

            // One frame and nothing before it: no setting is read first, because no setting gates keys.*.
            Assert.That(_harness.Socket.Requests.Count, Is.EqualTo(before + 1));

            // No deviceId and no platform: the server takes both from the connection.
            Assert.That(Keys(body), Is.EqualTo(new[] { "algorithm", "identityKey", "oneTimePreKeys", "signedPreKey" }));
            Assert.That(body["identityKey"].WireString(), Is.EqualTo(IdentityKey));
            Assert.That(body["algorithm"].WireString(), Is.EqualTo(Algorithm));

            var spk = body["signedPreKey"];
            Assert.That(spk.Kind, Is.EqualTo(JsonKind.Object));
            Assert.That(Keys(spk), Is.EqualTo(new[] { "createdAt", "keyId", "publicKey", "signature" }),
                "exact camelCase: the binder matches a nested name case-sensitively and requires the first three");
            Assert.That(spk["keyId"].WireString(), Is.EqualTo("spk_1"));
            Assert.That(spk["publicKey"].WireString(), Is.EqualTo(SpkPublic));
            Assert.That(spk["signature"].WireString(), Is.EqualTo(SpkSignature));
            Assert.That(spk["createdAt"].WireLong(), Is.EqualTo(1758412800000L));

            var pool = body["oneTimePreKeys"];
            Assert.That(pool.Kind, Is.EqualTo(JsonKind.Array));
            Assert.That(pool.Count, Is.EqualTo(2));
            Assert.That(Keys(pool[0]), Is.EqualTo(new[] { "keyId", "publicKey" }));
            Assert.That(pool[0]["keyId"].WireString(), Is.EqualTo("otk_1"));
            Assert.That(pool[0]["publicKey"].WireString(), Is.EqualTo(Otk1));
            Assert.That(pool[1]["keyId"].WireString(), Is.EqualTo("otk_2"));
            Assert.That(pool[1]["publicKey"].WireString(), Is.EqualTo(Otk2));

            // Unchanged on the wire, character for character: no base64url, no stripped padding, no "\/".
            var text = body.ToJson();
            foreach (var material in Material)
            {
                Assert.That(text, Does.Contain("\"" + material + "\""), material + " was re-encoded on the wire");
            }
        }

        [Test]
        public void A_minimal_publish_sends_an_empty_pool_a_zero_created_at_and_no_algorithm()
        {
            var body = Acknowledged(
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, new ImSignedPreKey("spk_1", SpkPublic, SpkSignature))),
                "keys.publish");

            Assert.That(Keys(body), Is.EqualTo(new[] { "identityKey", "oneTimePreKeys", "signedPreKey" }),
                "a null algorithm is not sent: the server keeps its default");
            Assert.That(body["oneTimePreKeys"].Kind, Is.EqualTo(JsonKind.Array));
            Assert.That(body["oneTimePreKeys"].Count, Is.Zero);
            Assert.That(body["signedPreKey"]["createdAt"].WireLong(), Is.Zero, "0 means now; the server stamps it");
        }

        [Test]
        public void Publish_refusals_are_ordinary_errors_with_the_servers_words()
        {
            var badSignature = RefusedInWords(
                _harness.Client.Keys.PublishAsync(FullPublish()),
                "keys.publish",
                ImErrorCode.InvalidArgument,
                "signedPreKey signature does not verify against identityKey");
            Assert.That(badSignature.IsRetryable, Is.False, "the same keys will not verify on a second try");

            var unknownAlgorithm = RefusedInWords(
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, new ImSignedPreKey("spk_1", SpkPublic, SpkSignature))
                {
                    Algorithm = "x3dh-rsa-v1",
                }),
                "keys.publish",
                ImErrorCode.UnsupportedOperation,
                "unsupported algorithm");
            Assert.That(unknownAlgorithm.Code, Is.EqualTo(1008));

            var eleventhDevice = RefusedInWords(
                _harness.Client.Keys.PublishAsync(FullPublish()),
                "keys.publish",
                ImErrorCode.QuotaExceeded,
                "a user may publish at most 10 devices");
            Assert.That(eleventhDevice.Code, Is.EqualTo(1202));

            RefusedInWords(
                _harness.Client.Keys.PublishAsync(FullPublish()),
                "keys.publish",
                ImErrorCode.InvalidArgument,
                "identityKey is not valid for this algorithm");

            // The connection is untouched: the next call goes out and succeeds.
            var next = _harness.Client.Keys.PublishAsync(FullPublish());
            AnswerNewest("keys.publish", JsonValue.NewObject().Set("code", 0L));
            Assert.That(next.IsCompleted && !next.IsFaulted, Is.True);
            Assert.That(_harness.Client.State, Is.EqualTo(ImConnectionState.Open));
        }

        /// <summary>
        /// A blank identity key or signed-prekey public key is the server's <c>1001</c>; a null member
        /// inside <c>signedPreKey</c> or a one-time prekey would leave a required nested name out, which
        /// fails to bind and answers <c>1000</c> for the whole call. All are refused here first.
        /// </summary>
        [Test]
        public void Publish_without_a_required_member_is_refused_before_anything_is_sent()
        {
            var before = _harness.Socket.Requests.Count;

            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Keys.PublishAsync(null); });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(string.Empty, new ImSignedPreKey("spk_1", SpkPublic, SpkSignature)));
            });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, null)); });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, new ImSignedPreKey("spk_1", null, SpkSignature)));
            });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, new ImSignedPreKey(null, SpkPublic, SpkSignature)));
            });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(IdentityKey, new ImSignedPreKey("spk_1", SpkPublic, null)));
            });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(
                    IdentityKey, new ImSignedPreKey("spk_1", SpkPublic, SpkSignature), new ImOneTimePreKey("otk_1", null)));
            });
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.PublishAsync(new ImPublishKeysRequest(
                    IdentityKey, new ImSignedPreKey("spk_1", SpkPublic, SpkSignature), new ImOneTimePreKey("otk_1", Otk1), null));
            });

            AssertNothingSentSince(before);
        }

        // ------------------------------------------------------------------ keys.upload

        [Test]
        public void Upload_sends_the_keys_and_nothing_else_and_before_a_publish_is_not_found()
        {
            var body = Acknowledged(
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_3", Otk1), new ImOneTimePreKey("otk_4", Otk2))),
                "keys.upload");

            Assert.That(Keys(body), Is.EqualTo(new[] { "keys" }), "no device: the server uses the connection's");
            Assert.That(body["keys"].Kind, Is.EqualTo(JsonKind.Array));
            Assert.That(Keys(body["keys"][0]), Is.EqualTo(new[] { "keyId", "publicKey" }));
            Assert.That(body["keys"][0]["keyId"].WireString(), Is.EqualTo("otk_3"));
            Assert.That(body["keys"][1]["publicKey"].WireString(), Is.EqualTo(Otk2));

            var fromList = Acknowledged(
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new List<ImOneTimePreKey> { new ImOneTimePreKey("otk_5", Otk1) })),
                "keys.upload");
            Assert.That(fromList["keys"].Count, Is.EqualTo(1));

            RefusedInWords(
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_6", Otk1))),
                "keys.upload",
                ImErrorCode.NotFound,
                "device has not published its identity key");
            RefusedInWords(
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_7", "not base64!"))),
                "keys.upload",
                ImErrorCode.InvalidArgument,
                "no valid one-time prekeys supplied");

            var before = _harness.Socket.Requests.Count;
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Keys.UploadAsync(null); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest()); },
                "the server's 1001 \"keys is required\"");
            Assert.Throws<ArgumentException>(delegate
            {
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey(null, Otk1)));
            });
            AssertNothingSentSince(before);
        }

        // ------------------------------------------------------------------ keys.remaining

        [Test]
        public void Remaining_reads_a_bare_number_and_sends_an_empty_body_for_the_connected_device()
        {
            var own = Answered(_harness.Client.Keys.RemainingAsync(), "keys.remaining", JsonValue.Of(37L));
            Assert.That(Keys(_harness.Socket.LastBody("keys.remaining")), Is.Empty, "{} means the connected device");
            Assert.That(own, Is.EqualTo(37));

            var named = Answered(
                _harness.Client.Keys.RemainingAsync(new ImRemainingKeysRequest("device-2")),
                "keys.remaining",
                JsonValue.Of(0L));
            var body = _harness.Socket.LastBody("keys.remaining");
            Assert.That(Keys(body), Is.EqualTo(new[] { "deviceId" }));
            Assert.That(body["deviceId"].WireString(), Is.EqualTo("device-2"));
            Assert.That(named, Is.Zero, "an unknown device is 0, not an error");

            Answered(_harness.Client.Keys.RemainingAsync(new ImRemainingKeysRequest()), "keys.remaining", JsonValue.Of(1L));
            Assert.That(Keys(_harness.Socket.LastBody("keys.remaining")), Is.Empty);
        }

        // ------------------------------------------------------------------ keys.claim

        [Test]
        public void Claim_sends_both_ids_and_decodes_every_member_of_the_bundle()
        {
            var bundle = Answered(
                _harness.Client.Keys.ClaimAsync(new ImClaimBundleRequest("u_bob", "device-9")),
                "keys.claim",
                Bundle());

            var body = _harness.Socket.LastBody("keys.claim");
            Assert.That(Keys(body), Is.EqualTo(new[] { "deviceId", "userId" }));
            Assert.That(body["userId"].WireString(), Is.EqualTo("u_bob"));
            Assert.That(body["deviceId"].WireString(), Is.EqualTo("device-9"));

            Assert.That(bundle.UserId, Is.EqualTo("u_bob"));
            Assert.That(bundle.DeviceId, Is.EqualTo("device-9"));
            Assert.That(bundle.IdentityKey, Is.EqualTo(IdentityKey), "byte for byte as published");
            Assert.That(bundle.SignedPreKey.KeyId, Is.EqualTo("spk_1"));
            Assert.That(bundle.SignedPreKey.PublicKey, Is.EqualTo(SpkPublic));
            Assert.That(bundle.SignedPreKey.Signature, Is.EqualTo(SpkSignature));
            Assert.That(bundle.SignedPreKey.CreatedAt, Is.EqualTo(1758412800000L));
            Assert.That(bundle.OneTimePreKey, Is.Not.Null);
            Assert.That(bundle.OneTimePreKey.KeyId, Is.EqualTo("otk_1"));
            Assert.That(bundle.OneTimePreKey.PublicKey, Is.EqualTo(Otk1));
            Assert.That(bundle.Algorithm, Is.EqualTo(Algorithm));

            Answered(_harness.Client.Keys.ClaimAsync("u_carol", "device-3"), "keys.claim", Bundle());
            var shorthand = _harness.Socket.LastBody("keys.claim");
            Assert.That(shorthand["userId"].WireString(), Is.EqualTo("u_carol"));
            Assert.That(shorthand["deviceId"].WireString(), Is.EqualTo("device-3"));
        }

        [Test]
        public void A_claim_on_an_empty_pool_succeeds_with_no_one_time_prekey()
        {
            var absent = Answered(_harness.Client.Keys.ClaimAsync("u_bob", "device-9"), "keys.claim", BundleFromAnEmptyPool());
            Assert.That(absent.OneTimePreKey, Is.Null, "the server omits the member; that is an empty pool, not a failure");
            Assert.That(absent.SignedPreKey.PublicKey, Is.EqualTo(SpkPublic), "the rest of the bundle is still usable");

            var explicitNull = Answered(
                _harness.Client.Keys.ClaimAsync("u_bob", "device-9"),
                "keys.claim",
                BundleFromAnEmptyPool().Set("oneTimePreKey", JsonValue.Null));
            Assert.That(explicitNull.OneTimePreKey, Is.Null);
        }

        /// <summary>
        /// A claim consumes a one-time prekey, so a lost reply may already have spent one: the SDK must
        /// not send it a second time on any failure, retryable or not.
        /// </summary>
        [Test]
        public void A_claim_is_sent_exactly_once_whether_refused_or_unanswered()
        {
            var unavailable = RefusedInWords(
                _harness.Client.Keys.ClaimAsync("u_bob", "device-9"),
                "keys.claim",
                ImErrorCode.ServiceUnavailable,
                "key directory is unavailable");
            Assert.That(unavailable.IsRetryable, Is.True, "retryable in general — which is exactly why the SDK must not do it here");
            _harness.Advance(TimeSpan.FromSeconds(5));
            Assert.That(ClaimsSent(), Is.EqualTo(1));

            // Inside the 30 s heartbeat, so the socket under the test stays the one it started on.
            var unanswered = _harness.Client.Keys.ClaimAsync("u_bob", "device-9");
            _harness.Pump();
            _harness.Advance(_harness.Options.RequestTimeout + TimeSpan.FromSeconds(1));
            Assert.That(unanswered.IsFaulted, Is.True);
            Assert.That(((ImException)unanswered.Exception.GetBaseException()).Code, Is.EqualTo(ImErrorCode.Timeout));
            _harness.Advance(TimeSpan.FromSeconds(5));
            Assert.That(ClaimsSent(), Is.EqualTo(2), "one per call, never a resend");
            Assert.That(_harness.Transports, Has.Count.EqualTo(1));

            RefusedInWords(
                _harness.Client.Keys.ClaimAsync("u_bob", "device-gone"),
                "keys.claim",
                ImErrorCode.NotFound,
                "device has published no keys");
            Assert.That(ClaimsSent(), Is.EqualTo(3));

            var before = _harness.Socket.Requests.Count;
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Keys.ClaimAsync(null); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.ClaimAsync("u_bob", string.Empty); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.ClaimAsync(null, "device-9"); });
            AssertNothingSentSince(before);
        }

        // ------------------------------------------------------------------ keys.devices

        [Test]
        public void Devices_decode_a_bare_array_and_an_empty_body_means_the_callers_own()
        {
            var listed = Answered(
                _harness.Client.Keys.DevicesAsync(new ImDeviceKeysRequest("u_bob")),
                "keys.devices",
                JsonValue.NewArray()
                    .Add(Device("device-9", 2L, 37))
                    .Add(Device("sdk-sweep-u_bob", 5L, 0))
                    .Add(Device("server-1", 100L, 100)));

            var body = _harness.Socket.LastBody("keys.devices");
            Assert.That(Keys(body), Is.EqualTo(new[] { "userId" }));
            Assert.That(body["userId"].WireString(), Is.EqualTo("u_bob"));

            // No order is promised, so sort before reading.
            listed.Sort((a, b) => string.CompareOrdinal(a.DeviceId, b.DeviceId));
            Assert.That(listed, Has.Count.EqualTo(3));
            Assert.That(listed[0].DeviceId, Is.EqualTo("device-9"));
            Assert.That(listed[0].Platform, Is.EqualTo(ImPlatform.Android));
            Assert.That(listed[0].IdentityKey, Is.EqualTo(IdentityKey));
            Assert.That(listed[0].PublishedAt, Is.EqualTo(1758412800123L));
            Assert.That(listed[0].RemainingOneTimeKeys, Is.EqualTo(37));
            Assert.That(listed[1].Platform, Is.EqualTo(ImPlatform.Web));
            Assert.That(listed[2].Platform, Is.EqualTo((ImPlatform)100), "a platform this build does not name keeps its number");
            Assert.That(listed[2].RemainingOneTimeKeys, Is.EqualTo(100));

            var none = Answered(_harness.Client.Keys.DevicesAsync(), "keys.devices", JsonValue.NewArray());
            Assert.That(Keys(_harness.Socket.LastBody("keys.devices")), Is.Empty, "{} means the caller's own");
            Assert.That(none, Is.Empty, "an unknown user is an empty list, not an error");
        }

        // ------------------------------------------------------------------ keys.revoke

        [Test]
        public void Revoke_names_the_device_and_never_defaults_it()
        {
            var body = Acknowledged(_harness.Client.Keys.RevokeAsync(new ImRevokeDeviceRequest("device-2")), "keys.revoke");
            Assert.That(Keys(body), Is.EqualTo(new[] { "deviceId" }));
            Assert.That(body["deviceId"].WireString(), Is.EqualTo("device-2"));

            // An unknown device: the server answers success, and so does the SDK.
            var shorthand = Acknowledged(_harness.Client.Keys.RevokeAsync("device-never-seen"), "keys.revoke");
            Assert.That(shorthand["deviceId"].WireString(), Is.EqualTo("device-never-seen"));

            var before = _harness.Socket.Requests.Count;
            Assert.Throws<ArgumentNullException>(delegate { _harness.Client.Keys.RevokeAsync((ImRevokeDeviceRequest)null); });
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.RevokeAsync(new ImRevokeDeviceRequest()); },
                "blank is the server's 1001, never the connected device");
            Assert.Throws<ArgumentException>(delegate { _harness.Client.Keys.RevokeAsync(string.Empty); });
            AssertNothingSentSince(before);
        }

        // ------------------------------------------------------------------ keys.safetyNumber

        [Test]
        public void Safety_number_reads_a_bare_string_and_a_party_without_keys_is_not_found()
        {
            const string number = "12345 67890 12345 67890 12345 67890 12345 67890 12345 67890 12345 67890";

            var read = Answered(
                _harness.Client.Keys.SafetyNumberAsync(new ImSafetyNumberRequest("u_bob")),
                "keys.safetyNumber",
                JsonValue.Of(number));
            var body = _harness.Socket.LastBody("keys.safetyNumber");
            Assert.That(Keys(body), Is.EqualTo(new[] { "peerUserId" }));
            Assert.That(body["peerUserId"].WireString(), Is.EqualTo("u_bob"));
            Assert.That(read, Is.EqualTo(number));
            Assert.That(read.Split(' '), Has.Length.EqualTo(12));

            Answered(_harness.Client.Keys.SafetyNumberAsync("alice"), "keys.safetyNumber", JsonValue.Of(number));
            Assert.That(_harness.Socket.LastBody("keys.safetyNumber")["peerUserId"].WireString(), Is.EqualTo("alice"),
                "the caller's own id is allowed");

            RefusedInWords(
                _harness.Client.Keys.SafetyNumberAsync("u_carol"),
                "keys.safetyNumber",
                ImErrorCode.NotFound,
                "one of the parties has published no keys");

            var before = _harness.Socket.Requests.Count;
            var blank = _harness.Client.Keys.SafetyNumberAsync(string.Empty);
            _harness.Pump();
            Assert.That(blank.IsFaulted, Is.True);
            Assert.That(blank.Exception.GetBaseException(), Is.InstanceOf<ArgumentException>());
            AssertNothingSentSince(before);
        }

        // ------------------------------------------------------------------ logs

        /// <summary>
        /// The harness runs the SDK's console log at <see cref="ImLogLevel.Verbose"/>, where every frame
        /// in and out is traced: the most a game could ever turn on. Key material must reach neither that
        /// nor the SDK's own uploadable log — while the trace still shows that the calls happened.
        /// </summary>
        [Test]
        public void No_key_material_reaches_any_log_even_at_verbose()
        {
            Assert.That(ImLog.Level, Is.EqualTo(ImLogLevel.Verbose), "the trace this test reads is on");

            Acknowledged(_harness.Client.Keys.PublishAsync(FullPublish()), "keys.publish");
            Acknowledged(_harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_2", Otk2))), "keys.upload");
            Answered(_harness.Client.Keys.ClaimAsync("u_bob", "device-9"), "keys.claim", Bundle());
            Answered(_harness.Client.Keys.DevicesAsync(new ImDeviceKeysRequest("u_bob")), "keys.devices", JsonValue.NewArray().Add(Device("device-9", 2L, 1)));
            RefusedInWords(
                _harness.Client.Keys.PublishAsync(FullPublish()),
                "keys.publish",
                ImErrorCode.InvalidArgument,
                "signedPreKey signature does not verify against identityKey");
            _harness.Client.Log.Flush();

            var lines = new List<string>(_harness.Log);
            foreach (var line in _harness.Client.Log.Read())
            {
                lines.Add(line.Msg);
            }

            var leaked = lines.FindAll(line => Array.Exists(Material, material => line.Contains(material)));
            Assert.That(leaked, Is.Empty, "the SDK logged key material:\n" + string.Join("\n", leaked.ToArray()));

            Assert.That(_harness.Log.Exists(line => line.Contains("keys.publish") && line.Contains("not traced")), Is.True,
                "the trace still records that the call went out; log was:\n" + string.Join("\n", _harness.Log));
            Assert.That(_harness.Log.Exists(line => line.StartsWith("Verbose ← ", StringComparison.Ordinal) && line.Contains("keys.claim")), Is.True,
                "and that its reply came back");
        }

        [Test]
        public void The_frame_trace_elides_only_the_key_directory()
        {
            Answered(_harness.Client.Room.OnlineCountAsync("lobby-trace"), "room.onlineCount", JsonValue.Of(3L));
            Answered(_harness.Client.Keys.DevicesAsync(new ImDeviceKeysRequest("u_trace")), "keys.devices", JsonValue.NewArray());

            var outgoing = _harness.Log.FindAll(line => line.StartsWith("Verbose → ", StringComparison.Ordinal));
            Assert.That(outgoing.Exists(line => line.Contains("room.onlineCount") && line.Contains("\"roomId\":\"lobby-trace\"")), Is.True,
                "every other frame is still traced verbatim; log was:\n" + string.Join("\n", _harness.Log));

            var keys = outgoing.FindAll(line => line.Contains("keys.devices"));
            Assert.That(keys, Has.Count.EqualTo(1));
            Assert.That(keys[0], Does.Not.Contain("u_trace"), "a keys.* body is left out whole, not filtered field by field");
            Assert.That(keys[0], Does.Contain("not traced"));
        }

        // ------------------------------------------------------------------ inventory

        private static readonly string[] Seven =
        {
            "keys.publish", "keys.upload", "keys.remaining", "keys.claim", "keys.devices", "keys.revoke", "keys.safetyNumber",
        };

        /// <summary>
        /// "The seven are typed" is something this suite can fail on: every method is driven, and the targets
        /// that reach the wire are compared with the inventory's own <c>keys.*</c> list. There is no
        /// <c>keys.*</c> event to decode, and none is invented.
        /// </summary>
        [Test]
        public void Every_key_endpoint_in_the_inventory_is_typed_here_and_none_is_an_event()
        {
            var calls = new List<Task>
            {
                _harness.Client.Keys.PublishAsync(FullPublish()),
                _harness.Client.Keys.UploadAsync(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_1", Otk1))),
                _harness.Client.Keys.RemainingAsync(),
                _harness.Client.Keys.ClaimAsync("u_bob", "device-9"),
                _harness.Client.Keys.DevicesAsync(),
                _harness.Client.Keys.RevokeAsync("device-2"),
                _harness.Client.Keys.SafetyNumberAsync("u_bob"),
            };

            foreach (var call in calls)
            {
                ImTestHarness.Forget(call);
            }

            _harness.Pump();

            var sent = new HashSet<string>(StringComparer.Ordinal);
            foreach (var request in _harness.Socket.Requests)
            {
                sent.Add(request.Target);
            }

            var listed = new List<string>();
            foreach (var endpoint in Inventory()["endpoints"].Items)
            {
                var target = endpoint["target"].AsString();
                if (target.StartsWith("keys.", StringComparison.Ordinal))
                {
                    listed.Add(target);
                }
            }

            listed.Sort(StringComparer.Ordinal);
            var seven = new List<string>(Seven);
            seven.Sort(StringComparer.Ordinal);
            Assert.That(listed, Is.EqualTo(seven), "the inventory's keys list");

            var missing = listed.FindAll(target => !sent.Contains(target));
            Assert.That(missing, Is.Empty, "keys endpoints no typed method sends: " + string.Join(", ", missing.ToArray()));

            foreach (var field in typeof(ImPushTarget).GetFields(BindingFlags.Public | BindingFlags.Static))
            {
                var value = field.GetValue(null) as string;
                Assert.That(value == null || value.IndexOf("key", StringComparison.OrdinalIgnoreCase) < 0, Is.True,
                    "the server sends no key-directory event; " + field.Name + " = " + value);
            }
        }

        /// <summary>
        /// The frame tests are only as wide as the bodies they build and the decoding tests only as wide as
        /// their fixtures, so both are held to the inventory's <c>payloadTypes</c>. <c>PublishKeysRequest</c>
        /// declares <c>deviceId</c> and <c>platform</c>, which the server overwrites from the connection; the
        /// wire-sample file declares those two omitted, and so does this test.
        /// </summary>
        [Test]
        public void The_full_fixtures_and_bodies_carry_every_member_the_server_declares()
        {
            var publish = Members("PublishKeysRequest");
            Assert.That(publish.Remove("deviceId") && publish.Remove("platform"), Is.True,
                "the two members the server takes from the connection are still declared");
            Assert.That(Keys(FullPublish().ToJson()), Is.EqualTo(publish));
            Assert.That(Keys(FullPublish().ToJson()["signedPreKey"]), Is.EqualTo(Members("SignedPreKey")));
            Assert.That(Keys(FullPublish().ToJson()["oneTimePreKeys"][0]), Is.EqualTo(Members("OneTimePreKey")));

            Assert.That(Keys(new ImUploadOneTimeKeysRequest(new ImOneTimePreKey("otk_1", Otk1)).ToJson()), Is.EqualTo(Members("UploadOneTimeKeysRequest")));
            Assert.That(Keys(new ImRemainingKeysRequest("device-2").ToJson()), Is.EqualTo(Members("RemainingKeysRequest")));
            Assert.That(Keys(new ImClaimBundleRequest("u_bob", "device-9").ToJson()), Is.EqualTo(Members("ClaimBundleRequest")));
            Assert.That(Keys(new ImDeviceKeysRequest("u_bob").ToJson()), Is.EqualTo(Members("DeviceKeysRequest")));
            Assert.That(Keys(new ImRevokeDeviceRequest("device-2").ToJson()), Is.EqualTo(Members("RevokeDeviceRequest")));
            Assert.That(Keys(new ImSafetyNumberRequest("u_bob").ToJson()), Is.EqualTo(Members("SafetyNumberRequest")));

            Assert.That(Keys(Bundle()), Is.EqualTo(Members("PreKeyBundle")));
            Assert.That(Keys(Bundle()["signedPreKey"]), Is.EqualTo(Members("SignedPreKey")));
            Assert.That(Keys(Bundle()["oneTimePreKey"]), Is.EqualTo(Members("OneTimePreKey")));
            Assert.That(Keys(Device("device-9", 2L, 1)), Is.EqualTo(Members("DeviceKeyInfo")));
        }

        /// <summary>The decoders read every member the fixtures carry — a member read under the wrong name is empty or 0.</summary>
        [Test]
        public void Every_declared_member_of_the_replies_is_read()
        {
            var device = ImPayload.Read<ImDeviceKeyInfo>(Device("device-9", 7L, 42));
            Assert.That(new object[] { device.DeviceId, device.Platform, device.IdentityKey, device.PublishedAt, device.RemainingOneTimeKeys },
                Is.EqualTo(new object[] { "device-9", ImPlatform.Linux, IdentityKey, 1758412800123L, 42 }));

            var bundle = ImPayload.Read<ImPreKeyBundle>(Bundle());
            Assert.That(new object[] { bundle.UserId, bundle.DeviceId, bundle.IdentityKey, bundle.Algorithm, bundle.OneTimePreKey.KeyId, bundle.SignedPreKey.Signature },
                Is.EqualTo(new object[] { "u_bob", "device-9", IdentityKey, Algorithm, "otk_1", SpkSignature }));
        }

        private static List<string> Members(string type)
        {
            var declared = Inventory()["payloadTypes"][type];
            Assert.That(declared.IsObject, Is.True, type + " is not in the inventory's payloadTypes");

            var names = new List<string>();
            foreach (var property in declared["properties"].Items)
            {
                names.Add(property["name"].AsString());
            }

            names.Sort(StringComparer.Ordinal);
            return names;
        }

        private static JsonValue Inventory()
        {
            return JsonValue.Parse(File.ReadAllText(Path.Combine(SdkRoot(), "endpoint-inventory.json")));
        }

        private static string SdkRoot([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);
            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                if (File.Exists(Path.Combine(directory, "endpoint-inventory.json")))
                {
                    return directory;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }
    }
}
