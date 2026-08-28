using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cyaim.Im.Json
{
    /// <summary>The six shapes a JSON value can take.</summary>
    public enum JsonKind
    {
        Null = 0,
        Bool = 1,
        Number = 2,
        String = 3,
        Array = 4,
        Object = 5,
    }

    /// <summary>Raised when a payload is not valid JSON. Carries the offset so a bad frame is diagnosable.</summary>
    public sealed class ImJsonException : Exception
    {
        /// <summary>Character offset in the source text where parsing gave up.</summary>
        public int Position { get; private set; }

        /// <inheritdoc cref="ImJsonException"/>
        public ImJsonException(string message, int position)
            : base(message + " (at offset " + position.ToString(CultureInfo.InvariantCulture) + ")")
        {
            Position = position;
        }
    }

    /// <summary>
    /// A mutable JSON document node: the data layer for the whole SDK.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Unity ships no <c>System.Text.Json</c>, and <c>JsonUtility</c> cannot express what this wire
    /// protocol actually sends — free-form <c>content</c> objects, maps keyed by conversation id,
    /// members that are absent rather than defaulted. Pulling in Newtonsoft would add a package
    /// dependency and a slab of IL2CPP reflection to a game that only wanted chat. So the SDK
    /// carries its own tree, and every model maps itself from one explicitly.
    /// </para>
    /// <para>Two details here are correctness, not taste:</para>
    /// <list type="bullet">
    /// <item><description>
    /// Integers stay <see cref="long"/> and are never widened to <see cref="double"/>. A
    /// <c>messageId</c> is a snowflake — past 2^53 a double silently rounds and two different
    /// messages begin to compare equal. Parsers that keep every number as a double get this wrong.
    /// </description></item>
    /// <item><description>
    /// Numbers are read and written with <see cref="CultureInfo.InvariantCulture"/>. On a device
    /// whose locale uses a decimal comma, culture-sensitive formatting would emit <c>1,5</c> and
    /// produce a frame the gateway rejects — a bug that never reproduces on the developer machine.
    /// </description></item>
    /// </list>
    /// <para>
    /// Member lookup is case-insensitive. The transport envelope is written PascalCase in
    /// docs/SPEC-02-protocol.md and camelCase by the gateway as it serialises today; one decoder
    /// that reads both means a serialiser policy change on the server cannot break shipped clients.
    /// </para>
    /// </remarks>
    public sealed class JsonValue
    {
        private static readonly JsonValue NullValue = new JsonValue(JsonKind.Null);
        private static readonly JsonValue TrueValue = new JsonValue(true);
        private static readonly JsonValue FalseValue = new JsonValue(false);

        private readonly JsonKind _kind;
        private readonly bool _bool;
        private readonly long _integer;
        private readonly double _real;
        private readonly bool _isIntegral;
        private readonly string _text;
        private readonly List<JsonValue> _items;
        private readonly List<KeyValuePair<string, JsonValue>> _members;

        private JsonValue(JsonKind kind)
        {
            _kind = kind;
            if (kind == JsonKind.Array)
            {
                _items = new List<JsonValue>();
            }
            else if (kind == JsonKind.Object)
            {
                _members = new List<KeyValuePair<string, JsonValue>>();
            }
        }

        private JsonValue(bool value)
        {
            _kind = JsonKind.Bool;
            _bool = value;
        }

        private JsonValue(long value)
        {
            _kind = JsonKind.Number;
            _integer = value;
            _real = value;
            _isIntegral = true;
        }

        private JsonValue(double value)
        {
            _kind = JsonKind.Number;
            _real = value;
            _integer = (long)value;
            _isIntegral = false;
        }

        private JsonValue(string value)
        {
            _kind = JsonKind.String;
            _text = value;
        }

        // ------------------------------------------------------------------ factories

        /// <summary>The shared JSON <c>null</c>. Reading a missing member yields this, never a C# null.</summary>
        public static JsonValue Null
        {
            get { return NullValue; }
        }

        /// <summary>Wraps a boolean.</summary>
        public static JsonValue Of(bool value)
        {
            return value ? TrueValue : FalseValue;
        }

        /// <summary>Wraps a 64-bit integer, which stays exact on the wire.</summary>
        public static JsonValue Of(long value)
        {
            return new JsonValue(value);
        }

        /// <summary>Wraps a 32-bit integer.</summary>
        public static JsonValue Of(int value)
        {
            return new JsonValue((long)value);
        }

        /// <summary>Wraps a floating point number.</summary>
        public static JsonValue Of(double value)
        {
            return new JsonValue(value);
        }

        /// <summary>Wraps a string; a null string becomes JSON <c>null</c>.</summary>
        public static JsonValue Of(string value)
        {
            return value == null ? NullValue : new JsonValue(value);
        }

        /// <summary>Creates an empty object, ready for <see cref="Set(string,JsonValue)"/>.</summary>
        public static JsonValue NewObject()
        {
            return new JsonValue(JsonKind.Object);
        }

        /// <summary>Creates an empty array, ready for <see cref="Add(JsonValue)"/>.</summary>
        public static JsonValue NewArray()
        {
            return new JsonValue(JsonKind.Array);
        }

        /// <summary>Parses JSON text. Throws <see cref="ImJsonException"/> when it is not valid.</summary>
        public static JsonValue Parse(string text)
        {
            return ImJson.Parse(text);
        }

        // ------------------------------------------------------------------ inspection

        /// <summary>Which of the six JSON shapes this node is.</summary>
        public JsonKind Kind
        {
            get { return _kind; }
        }

        /// <summary>True for JSON <c>null</c> — and therefore also for any member that was absent.</summary>
        public bool IsNull
        {
            get { return _kind == JsonKind.Null; }
        }

        /// <summary>True when this node is an object.</summary>
        public bool IsObject
        {
            get { return _kind == JsonKind.Object; }
        }

        /// <summary>True when this node is an array.</summary>
        public bool IsArray
        {
            get { return _kind == JsonKind.Array; }
        }

        /// <summary>Element count for arrays, member count for objects, otherwise 0.</summary>
        public int Count
        {
            get
            {
                if (_kind == JsonKind.Array)
                {
                    return _items.Count;
                }

                return _kind == JsonKind.Object ? _members.Count : 0;
            }
        }

        /// <summary>
        /// Reads a member by name. A missing member returns <see cref="Null"/> instead of throwing,
        /// so <c>frame["body"]["data"]["seq"].AsLong()</c> survives a partial payload — which
        /// matters because a client does not get to choose what a server sends it.
        /// </summary>
        public JsonValue this[string name]
        {
            get
            {
                if (_kind != JsonKind.Object || name == null)
                {
                    return NullValue;
                }

                for (int i = 0; i < _members.Count; i++)
                {
                    if (string.Equals(_members[i].Key, name, StringComparison.OrdinalIgnoreCase))
                    {
                        return _members[i].Value;
                    }
                }

                return NullValue;
            }
        }

        /// <summary>Reads an array element. An out-of-range index returns <see cref="Null"/>.</summary>
        public JsonValue this[int index]
        {
            get
            {
                if (_kind != JsonKind.Array || index < 0 || index >= _items.Count)
                {
                    return NullValue;
                }

                return _items[index];
            }
        }

        /// <summary>True when this object has the named member (case-insensitive).</summary>
        public bool Has(string name)
        {
            if (_kind != JsonKind.Object || name == null)
            {
                return false;
            }

            for (int i = 0; i < _members.Count; i++)
            {
                if (string.Equals(_members[i].Key, name, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        /// <summary>Object members, in the order they were parsed or added.</summary>
        public IEnumerable<KeyValuePair<string, JsonValue>> Members
        {
            get
            {
                if (_kind != JsonKind.Object)
                {
                    yield break;
                }

                for (int i = 0; i < _members.Count; i++)
                {
                    yield return _members[i];
                }
            }
        }

        /// <summary>Array elements, in order.</summary>
        public IEnumerable<JsonValue> Items
        {
            get
            {
                if (_kind != JsonKind.Array)
                {
                    yield break;
                }

                for (int i = 0; i < _items.Count; i++)
                {
                    yield return _items[i];
                }
            }
        }

        // ------------------------------------------------------------------ conversion

        /// <summary>Reads this node as a string, or <paramref name="fallback"/> when it is not one.</summary>
        public string AsString(string fallback = null)
        {
            if (_kind == JsonKind.String)
            {
                return _text;
            }

            if (_kind == JsonKind.Number)
            {
                return _isIntegral
                    ? _integer.ToString(CultureInfo.InvariantCulture)
                    : _real.ToString("R", CultureInfo.InvariantCulture);
            }

            if (_kind == JsonKind.Bool)
            {
                return _bool ? "true" : "false";
            }

            return fallback;
        }

        /// <summary>
        /// Reads this node as a 64-bit integer. Numeric strings are accepted as well: an id this
        /// large is often quoted by gateways written in languages where JSON numbers are doubles,
        /// and refusing to read it would be pedantry that loses messages.
        /// </summary>
        public long AsLong(long fallback = 0)
        {
            if (_kind == JsonKind.Number)
            {
                return _isIntegral ? _integer : (long)_real;
            }

            if (_kind == JsonKind.String)
            {
                long parsed;
                if (long.TryParse(_text, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                {
                    return parsed;
                }
            }

            return fallback;
        }

        /// <summary>Reads this node as an <see cref="int"/>. Larger values are truncated, not clamped.</summary>
        public int AsInt(int fallback = 0)
        {
            return (int)AsLong(fallback);
        }

        /// <summary>Reads this node as a double.</summary>
        public double AsDouble(double fallback = 0)
        {
            if (_kind == JsonKind.Number)
            {
                return _isIntegral ? _integer : _real;
            }

            if (_kind == JsonKind.String)
            {
                double parsed;
                if (double.TryParse(_text, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                {
                    return parsed;
                }
            }

            return fallback;
        }

        /// <summary>Reads this node as a boolean. A number counts as true when it is non-zero.</summary>
        public bool AsBool(bool fallback = false)
        {
            if (_kind == JsonKind.Bool)
            {
                return _bool;
            }

            if (_kind == JsonKind.Number)
            {
                return AsDouble() != 0;
            }

            return fallback;
        }

        /// <summary>Reads an array of strings, skipping anything that is not one. Never returns null.</summary>
        public List<string> AsStringList()
        {
            var result = new List<string>(Count);
            if (_kind != JsonKind.Array)
            {
                return result;
            }

            for (int i = 0; i < _items.Count; i++)
            {
                var text = _items[i].AsString();
                if (text != null)
                {
                    result.Add(text);
                }
            }

            return result;
        }

        // ------------------------------------------------------------------ building

        /// <summary>Sets an object member and returns this node, so builders chain.</summary>
        public JsonValue Set(string name, JsonValue value)
        {
            if (_kind != JsonKind.Object)
            {
                throw new InvalidOperationException("Set is only valid on a JSON object, not " + _kind + ".");
            }

            if (name == null)
            {
                throw new ArgumentNullException("name");
            }

            var entry = new KeyValuePair<string, JsonValue>(name, value ?? NullValue);
            for (int i = 0; i < _members.Count; i++)
            {
                if (string.Equals(_members[i].Key, name, StringComparison.OrdinalIgnoreCase))
                {
                    _members[i] = entry;
                    return this;
                }
            }

            _members.Add(entry);
            return this;
        }

        /// <summary>Sets a string member. A null value is skipped, so absent stays absent.</summary>
        public JsonValue Set(string name, string value)
        {
            return value == null ? this : Set(name, Of(value));
        }

        /// <summary>Sets an integer member.</summary>
        public JsonValue Set(string name, long value)
        {
            return Set(name, Of(value));
        }

        /// <summary>Sets an integer member, skipping it when the value is absent.</summary>
        public JsonValue Set(string name, long? value)
        {
            return value.HasValue ? Set(name, Of(value.Value)) : this;
        }

        /// <summary>Sets a boolean member.</summary>
        public JsonValue Set(string name, bool value)
        {
            return Set(name, Of(value));
        }

        /// <summary>Sets a floating point member.</summary>
        public JsonValue Set(string name, double value)
        {
            return Set(name, Of(value));
        }

        /// <summary>Appends to an array and returns this node, so builders chain.</summary>
        public JsonValue Add(JsonValue value)
        {
            if (_kind != JsonKind.Array)
            {
                throw new InvalidOperationException("Add is only valid on a JSON array, not " + _kind + ".");
            }

            _items.Add(value ?? NullValue);
            return this;
        }

        /// <summary>Builds a JSON array from strings.</summary>
        public static JsonValue ArrayOf(IEnumerable<string> values)
        {
            var array = NewArray();
            if (values != null)
            {
                foreach (var value in values)
                {
                    array.Add(Of(value));
                }
            }

            return array;
        }

        /// <summary>Builds a JSON object from a string-keyed integer map — conversation id to seq, and the like.</summary>
        public static JsonValue ObjectOf(IEnumerable<KeyValuePair<string, long>> entries)
        {
            var obj = NewObject();
            if (entries != null)
            {
                foreach (var entry in entries)
                {
                    obj.Set(entry.Key, Of(entry.Value));
                }
            }

            return obj;
        }

        // ------------------------------------------------------------------ output

        /// <summary>Serialises this node to compact JSON text.</summary>
        public string ToJson()
        {
            var builder = new StringBuilder(256);
            Write(builder);
            return builder.ToString();
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            return ToJson();
        }

        internal void Write(StringBuilder builder)
        {
            switch (_kind)
            {
                case JsonKind.Null:
                    builder.Append("null");
                    break;

                case JsonKind.Bool:
                    builder.Append(_bool ? "true" : "false");
                    break;

                case JsonKind.Number:
                    if (_isIntegral)
                    {
                        builder.Append(_integer.ToString(CultureInfo.InvariantCulture));
                    }
                    else if (double.IsNaN(_real) || double.IsInfinity(_real))
                    {
                        // JSON cannot spell these. Null is what every mainstream serialiser emits,
                        // and an unparseable frame would cost more than a lost fractional value.
                        builder.Append("null");
                    }
                    else
                    {
                        builder.Append(_real.ToString("R", CultureInfo.InvariantCulture));
                    }

                    break;

                case JsonKind.String:
                    ImJson.WriteString(builder, _text);
                    break;

                case JsonKind.Array:
                    builder.Append('[');
                    for (int i = 0; i < _items.Count; i++)
                    {
                        if (i > 0)
                        {
                            builder.Append(',');
                        }

                        _items[i].Write(builder);
                    }

                    builder.Append(']');
                    break;

                case JsonKind.Object:
                    builder.Append('{');
                    for (int i = 0; i < _members.Count; i++)
                    {
                        if (i > 0)
                        {
                            builder.Append(',');
                        }

                        ImJson.WriteString(builder, _members[i].Key);
                        builder.Append(':');
                        _members[i].Value.Write(builder);
                    }

                    builder.Append('}');
                    break;
            }
        }
    }
}
