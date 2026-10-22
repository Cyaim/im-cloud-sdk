package com.cyaim.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.LongAsStringSerializer

/*
 * `msg.translate` — machine translation of messages already in a conversation (T4). The call lives on
 * [MsgApi]; what it sends and gets back is here.
 *
 * **The platform calls no model of its own.** A deployment translates only when the operator has
 * configured a provider (`IM:Translation:Provider`) and the tenant's plan includes the translation
 * add-on, and the two refusals are ordinary [ImException]s, checked in this order before anything
 * else about the request:
 *
 * - `1204 PlanExpired` — the plan does not include translation (Enterprise and above, or a trial);
 * - `1203 FeatureNotEnabled` — the plan includes it but this app or deployment has no provider.
 *
 * Neither is something to retry, and neither should be latched for the life of the process: both are
 * runtime settings. Show the server's message and hide the action until the next start.
 *
 * 平台自己不调用任何模型：部署配置了翻译服务商、且租户套餐包含翻译增值项时才能翻译。两种拒绝都是普通的 ImException，
 * 在检查请求本身之前按此顺序判定：套餐不含翻译回 1204；含翻译但没有服务商回 1203。都不该重试。
 */

/**
 * `msg.translate`: up to 50 messages of one conversation into [targetLanguage].
 *
 * Each of [messageIds] is quoted on the wire (the server's field is a `List<string>`); an empty list
 * or more than 50 is `1001`. **A message that cannot be translated does not fail the call**: it comes
 * back with [TranslatedMessage.error] set, and the rest are translated.
 *
 * 每次至多 50 条，空列表回 1001。单条翻译失败不会让整次调用失败，而是在那一条的 error 里说明。
 */
@Serializable
public data class TranslateRequest(
    public val conversationId: String,
    public val messageIds: List<@Serializable(with = LongAsStringSerializer::class) Long>,
    /** BCP-47, e.g. `"zh-CN"`, `"en"`, `"ja"`. */
    public val targetLanguage: String,
    /** A hint; null lets the provider detect the source language. */
    public val sourceLanguage: String? = null,
)

/** What `msg.translate` answers: one item per message asked for. */
@Serializable
public data class TranslationResult(
    public val targetLanguage: String = "",
    public val items: List<TranslatedMessage> = emptyList(),
)

/** One message's translation, or why there is none. */
@Serializable
public data class TranslatedMessage(
    /** Arrives as a JSON string and decodes with every digit. */
    public val messageId: Long = 0,
    /** The translation; null when [error] is set. */
    public val text: String? = null,
    /** True when it came from the server's cache rather than a provider call. */
    public val cached: Boolean = false,
    /** Why this one message was not translated; the rest of the call still succeeded. */
    public val error: String? = null,
)
