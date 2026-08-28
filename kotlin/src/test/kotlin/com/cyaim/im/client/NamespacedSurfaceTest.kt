package com.cyaim.im.client

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Every method on a namespace is an endpoint. Nothing else may live there.
 *
 * CONTRACT.md §4.1–4.2: the typed surface is the endpoint list transliterated, so a reader who
 * knows an endpoint name knows the call, in every language, without a lookup table — and a support
 * engineer can grep a bug report for the target that failed. A convenience method with no endpoint
 * behind it breaks both halves of that.
 *
 * This is here because it happened. `sdk/unity` grew an `ImMsgApi.SendTextAsync` for which
 * `msg.sendText` is not and never was an endpoint, and its own deprecation messages pointed at the
 * invented method, so the SDK was actively teaching the wrong shape. A per-target coverage test
 * cannot see that — a phantom that delegates to a real endpoint puts a legitimate target on the
 * wire — so the check has to be on the *name*.
 *
 * 命名空间层只能有端点。按 target 统计的覆盖率测试看不见"转发到真端点的幽灵方法"，所以这里查方法名。
 */
class NamespacedSurfaceTest {

    /** Namespace class to the target prefix it mirrors. */
    private val namespaces: Map<Class<*>, String> = mapOf(
        ConnApi::class.java to "conn",
        MsgApi::class.java to "msg",
        ConvApi::class.java to "conv",
        UserApi::class.java to "user",
        FriendApi::class.java to "friend",
        GroupApi::class.java to "group",
        MediaApi::class.java to "media",
        PushApi::class.java to "push",
        ModerationApi::class.java to "moderation",
        DiagApi::class.java to "diag",
    )

    /**
     * The push token cache is the only non-endpoint the contract puts on a namespace: §6.2 requires
     * re-registering on every connect, which needs somewhere to keep the token. `setToken` /
     * `clearToken` is the pair, spelled that way in all five SDKs.
     */
    private val allowed = setOf("setToken", "clearToken", "getToken", "isRegistered")

    @Test
    fun `no namespaced method names an endpoint the server does not have`() {
        val endpoints = endpointTargets()
        val strays = mutableListOf<String>()

        for ((type, prefix) in namespaces) {
            for (method in type.declaredMethods) {
                if (method.isSynthetic || method.isBridge) continue

                // Kotlin mangles `internal` members with a `$module` suffix and generates
                // `name$default` bridges for default arguments; neither is public API.
                if (method.name.contains('$')) continue
                if (!java.lang.reflect.Modifier.isPublic(method.modifiers)) continue
                if (method.name in allowed) continue

                val target = "$prefix.${method.name}"
                if (target !in endpoints) {
                    strays += "${type.simpleName}.${method.name} implies $target"
                }
            }
        }

        assertEquals(
            emptyList(),
            strays.sorted(),
            "these namespaced methods name endpoints the server does not have. Either the endpoint " +
                "exists and endpoint-inventory.json needs regenerating, or the method is an " +
                "invention and belongs on ImClient as a flat alias (CONTRACT.md §4.2)",
        )
    }

    /**
     * The table above names every namespace the client exposes.
     *
     * **Without this, that table is a list that quietly stops covering things.** A namespace added
     * to [ImClient] and not added there is simply not checked: the suite stays green while a whole
     * prefix goes unexamined, which is the opposite of what a guardrail is for. `diag` was exactly
     * that on 2026-08-29 — it went in, and all four hand-maintained tables across the SDKs missed
     * it. Only Swift's equivalent assertion noticed, which is why this one now exists here too.
     *
     * 没有这一条，上面那张表就是一份会静默失去覆盖的清单：新增到 ImClient 上却没加进表里的
     * 命名空间根本不会被检查——套件照绿，而一整个前缀无人过问。2026-08-29 的 diag 正是如此：
     * 五端里四张人工维护的表全都漏了它，只有 Swift 那条同类断言发现了，所以这里也补上一条。
     */
    @Test
    fun `the table covers every namespace the client exposes`() {
        val missing = ImClient::class.java.methods
            .filter { it.name.startsWith("get") && it.parameterCount == 0 }
            .map { it.returnType }
            .filter { it.simpleName.endsWith("Api") && it.name.startsWith("com.cyaim.im.client.") }
            .distinct()
            .filterNot { it in namespaces.keys }
            .map { it.simpleName }
            .sorted()

        assertEquals(
            emptyList(),
            missing,
            "these namespaces are exposed on ImClient and absent from this test's table, so nothing " +
                "here checks them",
        )
    }

    @Test
    fun `sendText is not on the namespaced surface`() {
        // The specific regression, named, so the failure says what went wrong rather than making a
        // reader re-derive it from a list of strays. The flat `im.sendText` alias is where it
        // belongs and stays until 2.0.
        assertTrue(MsgApi::class.java.declaredMethods.none { it.name == "sendText" })
        assertTrue(ImClient::class.java.declaredMethods.any { it.name == "sendText" })
    }

    /**
     * Every target the generator found on the server, read out of the inventory rather than listed
     * here — a list here would be the very thing that goes stale.
     */
    private fun endpointTargets(): Set<String> {
        var directory: File? = File(".").absoluteFile

        repeat(8) {
            val candidate = directory ?: return@repeat
            val inventory = File(candidate, "endpoint-inventory.json")
            if (inventory.isFile) {
                val targets = Regex(""""target"\s*:\s*"([^"]+)"""")
                    .findAll(inventory.readText())
                    .map { it.groupValues[1] }
                    .toSet()

                assertTrue(targets.isNotEmpty(), "the inventory parsed to no targets at all")
                return targets
            }
            directory = candidate.parentFile
        }

        error("could not locate sdk/endpoint-inventory.json from ${File(".").absolutePath}")
    }
}
