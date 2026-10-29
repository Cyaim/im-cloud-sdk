package com.cyaim.im.client

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * [singleConversationId] against the shared vectors in `single-chat-id-vectors.json` at the root of
 * the SDK repository — the same file the server's `SingleChatIdVectorTests`, the widget and every
 * other SDK read.
 *
 * A single-chat id one side builds differently is not an error anywhere: it is a second
 * conversation, or one nobody can read. So the expected ids come from the file, written out from the
 * grammar, never from this implementation — implementations that only check each other agree
 * forever, including on the day they are all wrong.
 *
 * 单聊 id 对着共享向量断言：一端拼得不一样不会报错，得到的是第二个会话或谁也读不了的会话。
 * 期望值来自那份文件，不来自被测实现。
 */
class SingleChatIdTest {

    private class BuildVector(val a: String, val b: String, val id: String, val note: String?)

    private class ParseVector(val id: String, val ok: Boolean, val a: String?, val b: String?)

    private val vectors: JsonObject = loadVectors()

    private val build: List<BuildVector> = vectors.getValue("build").jsonArray.map {
        val v = it.jsonObject
        BuildVector(
            a = v.getValue("a").jsonPrimitive.content,
            b = v.getValue("b").jsonPrimitive.content,
            id = v.getValue("id").jsonPrimitive.content,
            note = v["note"]?.jsonPrimitive?.contentOrNull,
        )
    }

    private val parse: List<ParseVector> = vectors.getValue("parse").jsonArray.map {
        val v = it.jsonObject
        ParseVector(
            id = v.getValue("id").jsonPrimitive.content,
            ok = v.getValue("ok").jsonPrimitive.boolean,
            a = v["a"]?.jsonPrimitive?.contentOrNull,
            b = v["b"]?.jsonPrimitive?.contentOrNull,
        )
    }

    @Test
    fun `builds every build vector, whichever end comes first`() {
        assertTrue(build.isNotEmpty(), "single-chat-id-vectors.json has no build vectors")
        for (v in build) {
            assertEquals(v.id, singleConversationId(v.a, v.b), "'${v.a}' + '${v.b}' (${v.note ?: ""})")
            assertEquals(v.id, singleConversationId(v.b, v.a), "'${v.b}' + '${v.a}', ends swapped")
        }
    }

    @Test
    fun `rebuilds every id the file says parses from the pair it parses to`() {
        val parsed = parse.filter { it.ok }
        assertTrue(parsed.isNotEmpty(), "single-chat-id-vectors.json has no parse vectors that parse")
        for (v in parsed) {
            val a = assertNotNull(v.a, "parse vector '${v.id}' is ok but names no pair")
            val b = assertNotNull(v.b, "parse vector '${v.id}' is ok but names no pair")
            assertEquals(v.id, singleConversationId(a, b), v.id)
        }
    }

    @Test
    fun `never builds an id the file refuses`() {
        val refused = parse.filterNot { it.ok }.map { it.id }.toSet()
        assertTrue(refused.isNotEmpty(), "single-chat-id-vectors.json has no refused parse vectors")
        for (v in build) {
            val id = singleConversationId(v.a, v.b)
            assertFalse(id in refused, "'${v.a}' + '${v.b}' built '$id', which the file lists as malformed")
        }
    }

    @Test
    fun `still has the vectors this implementation is easiest to get wrong on`() {
        // Named rather than counted: a file trimmed to make a failure go away keeps a count plausible.
        // 点名而不是数数：为了让失败消失而删掉几条之后，数量照样说得过去。
        val built = build.map { it.id }.toSet()
        for (id in listOf("s_alice_bob", "s_u~1alice_u~1bob", "s_a~01_c", "s_user~11_user~110", "s_😀_Ａ")) {
            assertTrue(id in built, "build vector '$id' is missing from single-chat-id-vectors.json")
        }
    }

    /**
     * Gradle runs the tests from this project's directory and the vectors live one level up: walk up
     * until they turn up, as the endpoint-inventory readers do, rather than hard-coding a depth.
     */
    private fun loadVectors(): JsonObject {
        var directory: File? = File(".").absoluteFile

        repeat(8) {
            val candidate = directory ?: return@repeat
            val file = File(candidate, "single-chat-id-vectors.json")
            if (file.isFile) {
                return ImJson.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
            }
            directory = candidate.parentFile
        }

        error("could not locate sdk/single-chat-id-vectors.json from ${File(".").absolutePath}")
    }
}
