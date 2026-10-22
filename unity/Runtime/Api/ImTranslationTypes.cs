using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>msg.translate</c>: translates messages the caller can already read into one language. Pull, not
    /// push, and per reader.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Most deployments refuse it, and that is an ordinary answer.</b> The server checks, before it looks
    /// at the arguments: the plan's translation add-on (Enterprise and up, or a trial) —
    /// <see cref="ImErrorCode.PlanExpired"/> (<c>1204</c>) without it; then a configured provider —
    /// <see cref="ImErrorCode.FeatureNotEnabled"/> (<c>1203</c>) when the app has translation off or no
    /// provider is configured. Both reach the caller as an <see cref="ImException"/> with the code and the
    /// server's message. Do not remember either: a tenant can enable it at runtime.
    /// </para>
    /// <para>
    /// Then: <see cref="TargetLanguage"/> and a given <see cref="SourceLanguage"/> must be BCP-47 tags
    /// (<c>1001</c>); 1 to 50 message ids (<c>1001</c>); the usual access errors for the conversation; at
    /// most 60 calls a minute per user (<c>1003</c>). One message that cannot be translated does not fail
    /// the call: its <see cref="ImTranslatedMessage.Error"/> is set and the rest succeed.
    /// </para>
    /// <para>
    /// 大多数部署会拒绝它，这是正常答复：先查套餐的翻译增值项（企业版及以上或试用），没有回 1204；再查是否配置了翻译服务，
    /// 没有回 1203。两者都以带码与服务端原文的 ImException 交给调用方，别缓存这个结论。之后才校验参数：语言须是 BCP-47，
    /// 消息 1–50 条，每人每分钟至多 60 次。单条翻译失败不会让整个调用失败，那一条的 Error 有值。
    /// </para>
    /// </remarks>
    public sealed class ImTranslateRequest : IImRequest
    {
        /// <summary>The conversation the messages are in. Required.</summary>
        public string ConversationId { get; set; }

        /// <summary>
        /// The messages, as the decimal strings of their ids — strings on the wire, as every message id is.
        /// 1 to 50; an <see cref="ImMessage.MessageId"/> converts with <c>ToString(CultureInfo.InvariantCulture)</c>.
        /// </summary>
        public List<string> MessageIds { get; set; }

        /// <summary>BCP-47 target, e.g. <c>"zh-CN"</c>, <c>"en"</c>, <c>"ja"</c>. Required.</summary>
        public string TargetLanguage { get; set; }

        /// <summary>BCP-47 source hint. Null (not sent) lets the provider detect it.</summary>
        public string SourceLanguage { get; set; }

        /// <inheritdoc cref="ImTranslateRequest"/>
        public ImTranslateRequest()
        {
            MessageIds = new List<string>();
        }

        /// <inheritdoc cref="ImTranslateRequest"/>
        public ImTranslateRequest(string conversationId, string targetLanguage, params string[] messageIds)
        {
            ConversationId = conversationId;
            TargetLanguage = targetLanguage;
            MessageIds = new List<string>(messageIds ?? new string[0]);
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageIds", ImJsonArrays.OfStrings(MessageIds))
                .Set("targetLanguage", TargetLanguage)
                .Set("sourceLanguage", SourceLanguage);
        }
    }

    /// <summary>What <c>msg.translate</c> answers.</summary>
    public sealed class ImTranslationResult : IImJsonPayload
    {
        /// <summary>The target language, as the server normalised it.</summary>
        public string TargetLanguage { get; private set; }

        /// <summary>One entry per message the server considered. Never null.</summary>
        public List<ImTranslatedMessage> Items { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            TargetLanguage = json["targetLanguage"].AsString(string.Empty);
            Items = ImPayload.ReadList<ImTranslatedMessage>(json["items"]);
        }
    }

    /// <summary>One message's translation, or why there is none.</summary>
    public sealed class ImTranslatedMessage : IImJsonPayload
    {
        /// <summary>Which message. A string on the wire (it passes 2^53), read here without a double; a bare number is read too.</summary>
        public long MessageId { get; private set; }

        /// <summary>The translation. Null when <see cref="Error"/> is set.</summary>
        public string Text { get; private set; }

        /// <summary>True when it came from the server's cache rather than a provider call.</summary>
        public bool Cached { get; private set; }

        /// <summary>Why this one message could not be translated; null when it was.</summary>
        public string Error { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            MessageId = json["messageId"].AsLong();
            Text = json["text"].AsString();
            Cached = json["cached"].AsBool();
            Error = json["error"].AsString();
        }
    }
}
