using System;
using System.Globalization;
using System.Text;

namespace Cyaim.Im.Json
{
    /// <summary>
    /// The recursive-descent JSON reader behind <see cref="JsonValue.Parse"/>.
    /// </summary>
    /// <remarks>
    /// It is deliberately strict about structure and forgiving about nothing: a frame that does not
    /// parse is a frame the SDK must drop rather than half-interpret. The one hard limit is nesting
    /// depth — a socket is an untrusted input even when the server is friendly, and an unbounded
    /// recursive parser turns a malformed 10 KB payload into a stack overflow that no
    /// <c>try</c>/<c>catch</c> in the game can survive.
    /// </remarks>
    public static class ImJson
    {
        /// <summary>
        /// Deepest nesting the parser will follow. Real frames nest four or five levels; anything
        /// approaching this is either a bug or an attack.
        /// </summary>
        public const int MaxDepth = 64;

        /// <summary>Parses JSON text into a <see cref="JsonValue"/> tree.</summary>
        /// <exception cref="ImJsonException">The text is not valid JSON.</exception>
        public static JsonValue Parse(string text)
        {
            if (text == null)
            {
                throw new ImJsonException("payload was null", 0);
            }

            int index = 0;
            SkipWhitespace(text, ref index);
            var value = ParseValue(text, ref index, 0);
            SkipWhitespace(text, ref index);

            if (index != text.Length)
            {
                throw new ImJsonException("trailing characters after the JSON document", index);
            }

            return value;
        }

        /// <summary>Parses JSON text, returning false instead of throwing on malformed input.</summary>
        public static bool TryParse(string text, out JsonValue value)
        {
            try
            {
                value = Parse(text);
                return true;
            }
            catch (ImJsonException)
            {
                value = JsonValue.Null;
                return false;
            }
        }

        private static JsonValue ParseValue(string text, ref int index, int depth)
        {
            if (depth > MaxDepth)
            {
                throw new ImJsonException("nesting deeper than " + MaxDepth + " levels", index);
            }

            if (index >= text.Length)
            {
                throw new ImJsonException("unexpected end of input", index);
            }

            char c = text[index];
            switch (c)
            {
                case '{':
                    return ParseObject(text, ref index, depth);
                case '[':
                    return ParseArray(text, ref index, depth);
                case '"':
                    return JsonValue.Of(ParseString(text, ref index));
                case 't':
                    Expect(text, ref index, "true");
                    return JsonValue.Of(true);
                case 'f':
                    Expect(text, ref index, "false");
                    return JsonValue.Of(false);
                case 'n':
                    Expect(text, ref index, "null");
                    return JsonValue.Null;
                default:
                    return ParseNumber(text, ref index);
            }
        }

        private static JsonValue ParseObject(string text, ref int index, int depth)
        {
            var result = JsonValue.NewObject();
            index++; // consume '{'
            SkipWhitespace(text, ref index);

            if (index < text.Length && text[index] == '}')
            {
                index++;
                return result;
            }

            while (true)
            {
                SkipWhitespace(text, ref index);
                if (index >= text.Length || text[index] != '"')
                {
                    throw new ImJsonException("expected a member name", index);
                }

                var name = ParseString(text, ref index);
                SkipWhitespace(text, ref index);

                if (index >= text.Length || text[index] != ':')
                {
                    throw new ImJsonException("expected ':' after member name", index);
                }

                index++;
                SkipWhitespace(text, ref index);
                result.Set(name, ParseValue(text, ref index, depth + 1));
                SkipWhitespace(text, ref index);

                if (index >= text.Length)
                {
                    throw new ImJsonException("unterminated object", index);
                }

                if (text[index] == ',')
                {
                    index++;
                    continue;
                }

                if (text[index] == '}')
                {
                    index++;
                    return result;
                }

                throw new ImJsonException("expected ',' or '}' in object", index);
            }
        }

        private static JsonValue ParseArray(string text, ref int index, int depth)
        {
            var result = JsonValue.NewArray();
            index++; // consume '['
            SkipWhitespace(text, ref index);

            if (index < text.Length && text[index] == ']')
            {
                index++;
                return result;
            }

            while (true)
            {
                SkipWhitespace(text, ref index);
                result.Add(ParseValue(text, ref index, depth + 1));
                SkipWhitespace(text, ref index);

                if (index >= text.Length)
                {
                    throw new ImJsonException("unterminated array", index);
                }

                if (text[index] == ',')
                {
                    index++;
                    continue;
                }

                if (text[index] == ']')
                {
                    index++;
                    return result;
                }

                throw new ImJsonException("expected ',' or ']' in array", index);
            }
        }

        private static string ParseString(string text, ref int index)
        {
            index++; // consume opening quote
            var builder = new StringBuilder();

            while (true)
            {
                if (index >= text.Length)
                {
                    throw new ImJsonException("unterminated string", index);
                }

                char c = text[index++];

                if (c == '"')
                {
                    return builder.ToString();
                }

                if (c != '\\')
                {
                    builder.Append(c);
                    continue;
                }

                if (index >= text.Length)
                {
                    throw new ImJsonException("unterminated escape sequence", index);
                }

                char escape = text[index++];
                switch (escape)
                {
                    case '"':
                        builder.Append('"');
                        break;
                    case '\\':
                        builder.Append('\\');
                        break;
                    case '/':
                        builder.Append('/');
                        break;
                    case 'b':
                        builder.Append('\b');
                        break;
                    case 'f':
                        builder.Append('\f');
                        break;
                    case 'n':
                        builder.Append('\n');
                        break;
                    case 'r':
                        builder.Append('\r');
                        break;
                    case 't':
                        builder.Append('\t');
                        break;
                    case 'u':
                        if (index + 4 > text.Length)
                        {
                            throw new ImJsonException("truncated \\u escape", index);
                        }

                        int code;
                        if (!int.TryParse(
                                text.Substring(index, 4),
                                NumberStyles.HexNumber,
                                CultureInfo.InvariantCulture,
                                out code))
                        {
                            throw new ImJsonException("malformed \\u escape", index);
                        }

                        // Surrogate pairs arrive as two consecutive escapes; appending both halves
                        // reconstructs the code point, which is why emoji survive the round trip.
                        builder.Append((char)code);
                        index += 4;
                        break;
                    default:
                        throw new ImJsonException("unknown escape character", index - 1);
                }
            }
        }

        private static JsonValue ParseNumber(string text, ref int index)
        {
            int start = index;

            if (index < text.Length && (text[index] == '-' || text[index] == '+'))
            {
                index++;
            }

            bool integral = true;
            while (index < text.Length)
            {
                char c = text[index];
                if (c >= '0' && c <= '9')
                {
                    index++;
                    continue;
                }

                if (c == '.' || c == 'e' || c == 'E')
                {
                    integral = false;
                    index++;
                    continue;
                }

                if ((c == '+' || c == '-') && (text[index - 1] == 'e' || text[index - 1] == 'E'))
                {
                    index++;
                    continue;
                }

                break;
            }

            if (index == start)
            {
                throw new ImJsonException("expected a value", index);
            }

            var token = text.Substring(start, index - start);

            if (integral)
            {
                long integerValue;
                if (long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out integerValue))
                {
                    return JsonValue.Of(integerValue);
                }
            }

            double realValue;
            if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out realValue))
            {
                return JsonValue.Of(realValue);
            }

            throw new ImJsonException("malformed number '" + token + "'", start);
        }

        private static void Expect(string text, ref int index, string literal)
        {
            if (index + literal.Length > text.Length ||
                string.CompareOrdinal(text, index, literal, 0, literal.Length) != 0)
            {
                throw new ImJsonException("expected '" + literal + "'", index);
            }

            index += literal.Length;
        }

        private static void SkipWhitespace(string text, ref int index)
        {
            while (index < text.Length)
            {
                char c = text[index];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                {
                    index++;
                    continue;
                }

                break;
            }
        }

        internal static void WriteString(StringBuilder builder, string value)
        {
            if (value == null)
            {
                builder.Append("null");
                return;
            }

            builder.Append('"');
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                switch (c)
                {
                    case '"':
                        builder.Append("\\\"");
                        break;
                    case '\\':
                        builder.Append("\\\\");
                        break;
                    case '\b':
                        builder.Append("\\b");
                        break;
                    case '\f':
                        builder.Append("\\f");
                        break;
                    case '\n':
                        builder.Append("\\n");
                        break;
                    case '\r':
                        builder.Append("\\r");
                        break;
                    case '\t':
                        builder.Append("\\t");
                        break;
                    default:
                        if (c < ' ')
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            // Everything above U+001F goes out as UTF-8 in the text frame. Escaping
                            // non-ASCII would triple the size of a Chinese message for no benefit.
                            builder.Append(c);
                        }

                        break;
                }
            }

            builder.Append('"');
        }
    }
}
