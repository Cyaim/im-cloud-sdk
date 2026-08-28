/// Decoding helpers shared by every wire type in this package.
///
/// They exist because the gateway's JSON policy (`GatewayRegistration.CreateJsonOptions`, quoted in
/// `sdk/CONTRACT.md` §2) is looser than a naive `as` cast survives, and every one of the three
/// looseness rules has bitten a client somewhere:
///
/// - **Numbers may arrive as JSON strings** (`NumberHandling.AllowReadingFromString`). A 64-bit
///   `seq` sent as `"1234"` must not throw.
/// - **Nulls are omitted when writing.** A missing field means null/default; decoding must never
///   fail because a field is absent.
/// - **Unknown fields are ignored, unknown enum values are preserved.** The server ships new
///   content types without waiting for the app.
///
/// Not exported from `package:cyaim_im/cyaim_im.dart`: this is package plumbing, not API.
///
/// 网关的 JSON 策略比朴素强转宽松：数字可能是字符串、null 字段直接不写、未知字段忽略。
library;

/// Reads a message id, which travels as a string.
///
/// Ids are snowflakes around 2^58. On the Dart VM an `int` is 64-bit and would hold one, but this
/// package also targets the web, where `int` compiles to a JavaScript number and cannot: an id
/// with non-zero sequence bits is rounded on the way in, and one whose sequence bits are zero
/// parses exactly yet is printed back as a different integer. Keeping ids as `String` end to end
/// is what makes this package behave identically on mobile, desktop and web.
///
/// id 是约 2^58 的雪花。Dart VM 上 int 是 64 位、装得下，但本包同样支持 web——
/// 那里 int 会编译成 JavaScript number，装不下。全程保持 String 才能让三端行为一致。
String imId(Object? value) {
  if (value is String) return value;
  if (value == null) return '';
  return value.toString();
}

int? imInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Reads a numeric field that the server declares non-nullable, defaulting to [fallback] when the
/// field was omitted — which the JSON policy says is the same as null.
int imIntOr(Object? value, [int fallback = 0]) => imInt(value) ?? fallback;

double? imDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

String? imString(Object? value) {
  if (value is String) return value;
  // A number or bool in a string field is a server-side mistake, not a reason to lose the frame.
  if (value is num || value is bool) return value.toString();
  return null;
}

String imStringOr(Object? value, [String fallback = '']) => imString(value) ?? fallback;

/// Booleans are compared against `true` rather than cast, so `null`, `0` and `"false"` all read as
/// false instead of throwing.
bool imBool(Object? value) => value == true || value == 'true' || value == 1;

Map<String, dynamic> imMap(Object? value) =>
    value is Map<String, dynamic> ? value : const <String, dynamic>{};

Map<String, dynamic>? imMapOrNull(Object? value) => value is Map<String, dynamic> ? value : null;

List<String> imStringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? element in value)
      if (imString(element) case final String text) text,
  ];
}

List<int> imIntList(Object? value) {
  if (value is! List) return const <int>[];
  return <int>[
    for (final Object? element in value)
      if (imInt(element) case final int number) number,
  ];
}

/// `Dictionary<string, long>` — `convSeqs`, `gapsFrom`. Values may be strings; keys never are
/// anything else.
Map<String, int> imIntMap(Object? value) {
  if (value is! Map<String, dynamic>) return const <String, int>{};
  return <String, int>{
    for (final MapEntry<String, dynamic> entry in value.entries)
      if (imInt(entry.value) case final int number) entry.key: number,
  };
}

Map<String, String> imStringMap(Object? value) {
  if (value is! Map<String, dynamic>) return const <String, String>{};
  return <String, String>{
    for (final MapEntry<String, dynamic> entry in value.entries)
      if (imString(entry.value) case final String text) entry.key: text,
  };
}

/// Decodes a list of objects, skipping anything that is not one rather than failing the page.
List<T> imList<T>(Object? value, T Function(Map<String, dynamic>) decode) {
  if (value is! List) return const <Never>[];
  return <T>[
    for (final Object? element in value)
      if (element is Map<String, dynamic>) decode(element),
  ];
}

/// Drops null entries from a request body.
///
/// The server omits nulls when writing and treats a missing field as default, so sending
/// `"reason": null` and omitting `reason` mean the same thing — but only omitting it keeps the
/// frame small on a mobile radio, and only omitting it survives a future `[Required]` on a sibling
/// field. Every request type in this package builds its body through here.
Map<String, Object?> imBody(Map<String, Object?> fields) => <String, Object?>{
      for (final MapEntry<String, Object?> entry in fields.entries)
        if (entry.value != null) entry.key: entry.value,
    };
