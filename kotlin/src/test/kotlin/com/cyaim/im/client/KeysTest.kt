@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/**
 * `keys.publish` / `keys.upload` / `keys.remaining` / `keys.claim` / `keys.devices` / `keys.revoke` /
 * `keys.safetyNumber` — the end-to-end encryption key directory, typed in round 78.
 *
 * Every call is asserted on the whole frame it puts on the wire, by JSON kind — the nested
 * `signedPreKey` / `oneTimePreKeys[]` / `keys[]` members by their exact camelCase names, since the
 * server matches those case-sensitively and throws (`1000`) on a missing required one — and on what
 * it makes of a reply with every field set; fixtures and requests are held to
 * `endpoint-inventory.json`'s `payloadTypes`. Rules with tests of their own: key material leaves
 * byte for byte as given and is never logged; a claim on an empty pool decodes with no one-time
 * prekey; a claim is sent once and never reissued; the refusals reach the caller as readable
 * [ImException]s.
 *
 * 每个调用断言发出的整帧（嵌套成员按服务端区分大小写的名字）与对满字段答复的解码，夹具与请求对着清单的 payloadTypes 钉住。
 * 另有几条规则单独测：密钥材料原样发出、从不写进日志；池子空了的领取解码为没有一次性预密钥；领取只发一次、不重发；拒绝以可读的 ImException 交给调用方。
 */
class KeysTest {

    // Standard base64 with '+', '/' and padding, so any re-encoding (base64url, unpadded) would show.
    private val identityKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    private val spkPublic = "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A="
    private val spkSignature = "+/+/c2lnbmF0dXJlLW92ZXItc3BrLXB1YmxpYy1rZXk/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pw=="
    private val otk1 = "b3RrLTEr/w=="
    private val otk2 = "b3RrLTIr/w=="

    // ------------------------------------------------------------------------------ fixtures

    private fun signedPreKey(): JsonObject = buildJsonObject {
        // Every member of the server's SignedPreKey.
        put("keyId", "spk_1")
        put("publicKey", spkPublic)
        put("signature", spkSignature)
        put("createdAt", 1_758_412_800_000L)
    }

    private fun bundle(withOneTimeKey: Boolean = true): JsonObject = buildJsonObject {
        // Every member of the server's PreKeyBundle; the server omits oneTimePreKey (never null) when the pool is empty.
        put("userId", "bob")
        put("deviceId", "device-9")
        put("identityKey", identityKey)
        put("signedPreKey", signedPreKey())
        if (withOneTimeKey) putJsonObject("oneTimePreKey") { put("keyId", "otk_1"); put("publicKey", otk1) }
        put("algorithm", "x3dh-ed25519-aes256gcm-v1")
    }

    private fun device(deviceId: String, platform: Int, remaining: Int): JsonObject = buildJsonObject {
        // Every member of the server's DeviceKeyInfo.
        put("deviceId", deviceId)
        put("platform", platform)
        put("identityKey", identityKey)
        put("publishedAt", 1_758_412_800_123L)
        put("remainingOneTimeKeys", remaining)
    }

    private val safety = "12345 67890 13579 24680 11223 34455 66778 89900 10293 84756 56473 82910"

    /** A refusal as the server writes one: status 0, a business code, its message, no data. */
    private fun refuse(request: JsonObject, code: Int, message: String): JsonObject = buildJsonObject {
        put("id", request.id)
        put("target", request.target)
        put("status", 0)
        putJsonObject("body") {
            put("code", code)
            put("message", message)
            put("traceId", "trace-refused")
            put("serverTime", 1_755_000_000_000L)
        }
    }

    private fun gateway(emptyPool: Boolean = false): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "keys.publish", "keys.upload", "keys.revoke" -> replyTo(request, JsonNull)
                // Bare values, as the server answers these three: a number, an array, a string.
                "keys.remaining" -> replyTo(request, JsonPrimitive(3))
                "keys.devices" -> replyTo(
                    request,
                    buildJsonArray {
                        add(device("device-9", platform = 5, remaining = 3))
                        add(device("device-2", platform = 1, remaining = 0))
                    },
                )
                "keys.claim" -> replyTo(request, bundle(withOneTimeKey = !emptyPool))
                "keys.safetyNumber" -> replyTo(request, JsonPrimitive(safety))
                else -> null
            }
        }
    }

    /** [gateway], except that [target] is refused with [code] and [message]. */
    private fun refusing(target: String, code: Int, message: String): FakeGateway = gateway().apply {
        val ordinary = onRequest!!
        onRequest = { request -> if (request.target == target) refuse(request, code, message) else ordinary(request) }
    }

    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    private suspend fun TestScope.failure(block: suspend () -> Unit): ImException {
        val call = backgroundScope.async { runCatching { block() } }
        runCurrent()
        return assertNotNull(call.await().exceptionOrNull() as? ImException, "expected an ImException")
    }

    private fun fullPublish(): PublishKeysRequest = PublishKeysRequest(
        identityKey = identityKey,
        signedPreKey = SignedPreKey("spk_1", spkPublic, spkSignature, createdAt = 1_758_412_800_000L),
        oneTimePreKeys = listOf(OneTimePreKey("otk_1", otk1), OneTimePreKey("otk_2", otk2)),
        algorithm = "x3dh-ed25519-aes256gcm-v1",
    )

    // ---------------------------------------------------------------------------- keys.publish

    @Test
    fun `keys publish sends every member but the two the server takes from the connection, nested names exact`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.keys.publish(fullPublish()) }

        val body = gateway.latest.requestsTo("keys.publish").single().body
        assertEquals(members("PublishKeysRequest") - setOf("deviceId", "platform"), body.keys)
        assertFalse("deviceId" in body, "the server overwrites it with the connection's; it is not an input: $body")
        assertFalse("platform" in body)
        assertEquals(identityKey, body.jsonString("identityKey"))
        assertEquals("x3dh-ed25519-aes256gcm-v1", body.jsonString("algorithm"))

        val signed = body.getValue("signedPreKey").jsonObject
        assertEquals(members("SignedPreKey"), signed.keys, "nested: matched case-sensitively, so exactly these names")
        assertEquals("spk_1", signed.jsonString("keyId"))
        assertEquals(spkPublic, signed.jsonString("publicKey"))
        assertEquals(spkSignature, signed.jsonString("signature"))
        assertEquals(1_758_412_800_000L, signed.jsonInteger("createdAt"))

        val pool = body.getValue("oneTimePreKeys").jsonArray.map { it.jsonObject }
        assertEquals(listOf(members("OneTimePreKey"), members("OneTimePreKey")), pool.map { it.keys })
        assertEquals(listOf("otk_1", "otk_2"), pool.map { it.jsonString("keyId") })
        assertEquals(listOf(otk1, otk2), pool.map { it.jsonString("publicKey") })
    }

    @Test
    fun `keys publish without one-time prekeys or an algorithm leaves the server's defaults`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.keys.publish(PublishKeysRequest(identityKey, SignedPreKey("spk_1", spkPublic, spkSignature))) }

        val body = gateway.latest.requestsTo("keys.publish").single().body
        assertEquals(setOf("identityKey", "signedPreKey", "oneTimePreKeys"), body.keys, "no algorithm: the server's default applies: $body")
        assertEquals(emptyList(), body.getValue("oneTimePreKeys").jsonArray.toList())
        val signed = body.getValue("signedPreKey").jsonObject
        assertEquals(members("SignedPreKey"), signed.keys, "createdAt goes as 0, which the server reads as now")
        assertEquals(0L, signed.jsonInteger("createdAt"))
    }

    // ----------------------------------------------------------------------------- keys.upload

    @Test
    fun `keys upload sends only the keys, on both overloads, nested names exact`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.keys.upload(UploadOneTimeKeysRequest(listOf(OneTimePreKey("otk_3", otk1))))
            client.keys.upload(listOf(OneTimePreKey("otk_4", otk2), OneTimePreKey("otk_5", otk1)))
        }

        val bodies = gateway.latest.requestsTo("keys.upload").map { it.body }
        assertEquals(listOf(members("UploadOneTimeKeysRequest"), members("UploadOneTimeKeysRequest")), bodies.map { it.keys })
        assertEquals(setOf("keys"), bodies.first().keys, "no device: it is the connection's")
        val (first, second) = bodies.map { body -> body.getValue("keys").jsonArray.map { it.jsonObject } }
        assertEquals(listOf(members("OneTimePreKey")), first.map { it.keys })
        assertEquals("otk_3", first.single().jsonString("keyId"))
        assertEquals(otk1, first.single().jsonString("publicKey"))
        assertEquals(listOf("otk_4", "otk_5"), second.map { it.jsonString("keyId") })
        assertEquals(listOf(otk2, otk1), second.map { it.jsonString("publicKey") })
    }

    // -------------------------------------------------------------------------- keys.remaining

    @Test
    fun `keys remaining sends an empty body for this device, a named one otherwise, and decodes the bare number`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val mine = settle { client.keys.remaining() }
        val other = settle { client.keys.remaining("device-2") }
        settle { client.keys.remaining(RemainingKeysRequest("device-3")) }

        val (empty, named, typed) = gateway.latest.requestsTo("keys.remaining").map { it.body }
        assertEquals(JsonObject(emptyMap()), empty, "absent means the connected device")
        assertEquals(members("RemainingKeysRequest"), named.keys)
        assertEquals("device-2", named.jsonString("deviceId"))
        assertEquals("device-3", typed.jsonString("deviceId"))
        assertEquals(3, mine)
        assertEquals(3, other)
    }

    // ------------------------------------------------------------------------------ keys.claim

    @Test
    fun `keys claim sends user and device on both overloads and decodes every member of the bundle`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val bundle = settle { client.keys.claim(ClaimBundleRequest("bob", "device-9")) }
        settle { client.keys.claim("bob", "device-2") }

        val (typed, positional) = gateway.latest.requestsTo("keys.claim").map { it.body }
        assertEquals(members("ClaimBundleRequest"), typed.keys)
        assertEquals("bob", typed.jsonString("userId"))
        assertEquals("device-9", typed.jsonString("deviceId"))
        assertEquals(members("ClaimBundleRequest"), positional.keys)
        assertEquals("device-2", positional.jsonString("deviceId"))

        assertEquals("bob", bundle.userId)
        assertEquals("device-9", bundle.deviceId)
        assertEquals(identityKey, bundle.identityKey, "byte for byte as the server sent it")
        assertEquals(SignedPreKey("spk_1", spkPublic, spkSignature, 1_758_412_800_000L), bundle.signedPreKey)
        assertEquals(OneTimePreKey("otk_1", otk1), bundle.oneTimePreKey)
        assertEquals("x3dh-ed25519-aes256gcm-v1", bundle.algorithm)
    }

    @Test
    fun `a claim on an empty pool still succeeds, with no one-time prekey`() = runTest {
        val gateway = gateway(emptyPool = true)
        val client = newClient(gateway)
        openClient(client, gateway)

        val bundle = settle { client.keys.claim("bob", "device-9") }

        assertNull(bundle.oneTimePreKey, "absent on the wire decodes as null, not as a throw or an empty key")
        assertEquals(identityKey, bundle.identityKey)
        assertEquals("spk_1", bundle.signedPreKey.keyId)
    }

    /**
     * A claim spends a one-time prekey, so the SDK must never send it twice on its own: not after a
     * refusal that `isRetryable` calls retryable, and not after a reply that never came.
     */
    @Test
    fun `a claim is sent exactly once, refused or unanswered`() = runTest {
        var answer = true
        val gateway = refusing("keys.claim", ImErrorCode.ServiceUnavailable, "key directory is unavailable").apply {
            val refusingClaim = onRequest!!
            onRequest = { request -> if (request.target == "keys.claim" && !answer) null else refusingClaim(request) }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val unavailable = failure { client.keys.claim("bob", "device-9") }
        assertEquals(ImErrorCode.ServiceUnavailable, unavailable.code)
        assertEquals("key directory is unavailable", unavailable.message)
        assertTrue(unavailable.isRetryable, "retryable in general — which is exactly why the SDK must not act on it here")
        assertEquals(1, gateway.allSent.count { it.target == "keys.claim" })

        answer = false
        val call = backgroundScope.async { runCatching { client.keys.claim("bob", "device-9") } }
        runCurrent()
        advanceTimeBy(16.seconds)
        runCurrent()
        val lost = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.Timeout, lost.code)
        assertEquals(2, gateway.allSent.count { it.target == "keys.claim" }, "one frame per call, across every socket; the timed-out one was not reissued")
    }

    // ---------------------------------------------------------------------------- keys.devices

    @Test
    fun `keys devices sends an empty body for the caller's own, a named user otherwise, and decodes the bare array`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val own = settle { client.keys.devices() }
        val bobs = settle { client.keys.devices("bob") }
        settle { client.keys.devices(DeviceKeysRequest("carol")) }

        val (empty, named, typed) = gateway.latest.requestsTo("keys.devices").map { it.body }
        assertEquals(JsonObject(emptyMap()), empty, "absent means the caller's own devices")
        assertEquals(members("DeviceKeysRequest"), named.keys)
        assertEquals("bob", named.jsonString("userId"))
        assertEquals("carol", typed.jsonString("userId"))
        assertEquals(own, bobs)

        // Unspecified order on the server: sort before asserting.
        val (two, nine) = bobs.sortedBy { it.deviceId }
        assertEquals("device-9", nine.deviceId)
        assertEquals(Platform.Web, nine.platform, "an integer on the wire")
        assertEquals(identityKey, nine.identityKey)
        assertEquals(1_758_412_800_123L, nine.publishedAt)
        assertEquals(3, nine.remainingOneTimeKeys)
        assertEquals("device-2", two.deviceId)
        assertEquals(Platform.IOS, two.platform)
        assertEquals(0, two.remainingOneTimeKeys)
    }

    @Test
    fun `an unknown user's devices are an empty list, not an error`() = runTest {
        val gateway = gateway().apply {
            val ordinary = onRequest!!
            onRequest = { request ->
                if (request.target == "keys.devices") replyTo(request, buildJsonArray { }) else ordinary(request)
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        assertEquals(emptyList(), settle { client.keys.devices("nobody") })
    }

    // ----------------------------------------------------------------------------- keys.revoke

    @Test
    fun `keys revoke sends only the device id on both overloads, and a blank one is the server's 1001`() = runTest {
        val gateway = gateway().apply {
            val ordinary = onRequest!!
            onRequest = { request ->
                if (request.target == "keys.revoke" && request.bodyString("deviceId").isEmpty()) {
                    refuse(request, ImErrorCode.InvalidArgument, "deviceId is required")
                } else {
                    ordinary(request)
                }
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.keys.revoke(RevokeDeviceRequest("device-2"))
            client.keys.revoke("device-gone")
        }
        val bodies = gateway.latest.requestsTo("keys.revoke").map { it.body }
        assertEquals(listOf(members("RevokeDeviceRequest"), members("RevokeDeviceRequest")), bodies.map { it.keys })
        assertEquals(listOf("device-2", "device-gone"), bodies.map { it.jsonString("deviceId") })

        // The SDK does not default a blank id to this device; it sends what it was given.
        val blank = failure { client.keys.revoke("") }
        assertEquals(ImErrorCode.InvalidArgument, blank.code)
        assertEquals("deviceId is required", blank.message)
        assertEquals("keys.revoke", blank.target)
        assertEquals("", gateway.latest.requestsTo("keys.revoke").last().bodyString("deviceId"))
    }

    // ------------------------------------------------------------------------ keys.safetyNumber

    @Test
    fun `keys safetyNumber sends the peer on both overloads and decodes the bare string`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val number = settle { client.keys.safetyNumber("bob") }
        settle { client.keys.safetyNumber(SafetyNumberRequest("carol")) }

        val (positional, typed) = gateway.latest.requestsTo("keys.safetyNumber").map { it.body }
        assertEquals(members("SafetyNumberRequest"), positional.keys)
        assertEquals("bob", positional.jsonString("peerUserId"))
        assertEquals("carol", typed.jsonString("peerUserId"))
        assertEquals(safety, number)
        assertTrue(Regex("""^\d{5}( \d{5}){11}$""").matches(number), "12 groups of 5 digits")
    }

    // ------------------------------------------------------------------------------ refusals

    @Test
    fun `the directory's refusals reach the caller as readable ImExceptions and leave the connection usable`() = runTest {
        val cases = listOf(
            Triple("keys.publish", ImErrorCode.InvalidArgument, "signedPreKey signature does not verify against identityKey"),
            Triple("keys.publish", ImErrorCode.UnsupportedOperation, "unsupported algorithm"),
            Triple("keys.publish", ImErrorCode.QuotaExceeded, "a user may publish at most 10 devices"),
            Triple("keys.upload", ImErrorCode.NotFound, "device has not published its identity key"),
            Triple("keys.claim", ImErrorCode.NotFound, "device has published no keys"),
            Triple("keys.safetyNumber", ImErrorCode.NotFound, "one of the parties has published no keys"),
        )
        for ((target, code, message) in cases) {
            val gateway = refusing(target, code, message)
            val client = newClient(gateway)
            openClient(client, gateway)

            val refused = failure {
                when (target) {
                    "keys.publish" -> client.keys.publish(fullPublish())
                    "keys.upload" -> client.keys.upload(listOf(OneTimePreKey("otk_9", otk1)))
                    "keys.claim" -> client.keys.claim("bob", "device-unknown")
                    else -> client.keys.safetyNumber("bob")
                }
            }
            assertEquals(code, refused.code, target)
            assertEquals(message, refused.message, "the server's own words, for $target")
            assertEquals(target, refused.target)
            assertEquals("trace-refused", refused.traceId)
            assertFalse(refused.isRetryable, "$target $code: retrying the same call cannot change the answer")
            assertEquals(ConnectionState.Open, client.state.value, "the refusal is the call's, not the connection's")
            assertEquals(3, settle { client.keys.remaining() })
        }
    }

    @Test
    fun `key material is passed through unchanged and never written to the log`() = runTest {
        val logger = RecordingLogger()
        val gateway = gateway()
        val client = newClient(gateway, options = testOptions(logger = logger))
        openClient(client, gateway)

        settle {
            client.keys.publish(fullPublish())
            client.keys.upload(listOf(OneTimePreKey("otk_3", otk2)))
            client.keys.claim("bob", "device-9")
            client.keys.devices("bob")
        }

        val sent = gateway.latest.requestsTo("keys.publish").single().body
        assertEquals(spkSignature, sent.getValue("signedPreKey").jsonObject.jsonString("signature"), "no re-encoding, padding kept")
        val material = listOf(identityKey, spkPublic, spkSignature, otk1, otk2)
        val leaked = logger.lines.map { it.second }.filter { line -> material.any { it in line } }
        assertEquals(emptyList(), leaked, "the SDK never logs key material")
    }

    // ------------------------------------------------------------------- held to the inventory

    /**
     * The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
     * decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
     * member the server's type declares, and the requests send every member a client may send, held
     * here to `endpoint-inventory.json`'s `payloadTypes`.
     */
    @Test
    fun `the full fixtures and requests carry every member the server declares`() {
        assertEquals(members("PreKeyBundle"), bundle().keys)
        assertEquals(members("SignedPreKey"), signedPreKey().keys)
        assertEquals(members("OneTimePreKey"), bundle().getValue("oneTimePreKey").jsonObject.keys)
        assertEquals(members("DeviceKeyInfo"), device("d", 5, 1).keys)

        assertEquals(
            members("PublishKeysRequest") - setOf("deviceId", "platform"),
            fullPublish().asBody().jsonObject.keys,
            "every member but the two the server takes from the connection",
        )
        assertEquals(members("SignedPreKey"), SignedPreKey("k", "p", "s").asBody().jsonObject.keys)
        assertEquals(members("OneTimePreKey"), OneTimePreKey("k", "p").asBody().jsonObject.keys)
        assertEquals(members("UploadOneTimeKeysRequest"), UploadOneTimeKeysRequest(emptyList()).asBody().jsonObject.keys)
        assertEquals(members("RemainingKeysRequest"), RemainingKeysRequest("d").asBody().jsonObject.keys)
        assertEquals(members("ClaimBundleRequest"), ClaimBundleRequest("u", "d").asBody().jsonObject.keys)
        assertEquals(members("DeviceKeysRequest"), DeviceKeysRequest("u").asBody().jsonObject.keys)
        assertEquals(members("RevokeDeviceRequest"), RevokeDeviceRequest("d").asBody().jsonObject.keys)
        assertEquals(members("SafetyNumberRequest"), SafetyNumberRequest("u").asBody().jsonObject.keys)
    }

    /** The decoded shapes, member for member, so a renamed Kotlin property cannot read a default. */
    @Test
    fun `a bundle and a device decode through the public types alone`() {
        val bundle = ImJson.decodeFromJsonElement(PreKeyBundle.serializer(), bundle())
        assertEquals(PreKeyBundle("bob", "device-9", identityKey, SignedPreKey("spk_1", spkPublic, spkSignature, 1_758_412_800_000L), OneTimePreKey("otk_1", otk1), "x3dh-ed25519-aes256gcm-v1"), bundle)
        val info = ImJson.decodeFromJsonElement(DeviceKeyInfo.serializer(), device("device-9", 100, 7))
        assertEquals(DeviceKeyInfo("device-9", Platform.Server, identityKey, 1_758_412_800_123L, 7), info)
        val unknownPlatform: JsonElement = device("device-x", 42, 0)
        assertEquals(42, ImJson.decodeFromJsonElement(DeviceKeyInfo.serializer(), unknownPlatform).platform.code, "an open enum keeps a code it does not know")
    }

    private fun members(type: String): Set<String> {
        val inventory = ImJson.parseToJsonElement(inventoryFile().readText()).jsonObject
        return inventory.getValue("payloadTypes").jsonObject.getValue(type).jsonObject.getValue("properties").jsonArray
            .map { it.jsonObject.getValue("name").jsonPrimitive.content }
            .toSet()
    }

    private fun inventoryFile(): File {
        var directory: File? = File(".").absoluteFile
        repeat(8) {
            val candidate = directory ?: return@repeat
            val inventory = File(candidate, "endpoint-inventory.json")
            if (inventory.isFile) return inventory
            directory = candidate.parentFile
        }
        error("could not locate SDK/endpoint-inventory.json from ${File(".").absolutePath}")
    }
}
