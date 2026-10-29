/// The id of the single chat between users `a` and `b`, the same one the server gives it — so a
/// conversation can be addressed (`im.msg.history`, `im.conv.get`, `commit`, a cursor) before either
/// side has sent anything, or from nothing but the two user ids.
///
/// `"s_" + enc(A) + "_" + enc(B)`, where A and B are the two **raw** user ids ordered by UTF-16 code
/// unit (A first when they are equal) and `enc` writes every `~` as `~0` and every `_` as `~1`. After
/// escaping neither half contains `_`, so the one `_` after the prefix is the separator and every id
/// names exactly one pair: `u_alice` with `u_bob` is `s_u~1alice_u~1bob`, while ids with neither `_`
/// nor `~` come out as they always did (`s_alice_bob`).
///
/// Which end you pass first does not matter. The order is decided on the raw ids, not on the escaped
/// halves — escaping does not keep order (`_` sorts before the letters, its escape `~1` after them).
/// It is the order of their UTF-16 code units, because that is what the server and the other SDKs
/// compare; `String`'s own `<` compares Unicode scalars and puts a character outside the Basic
/// Multilingual Plane (`😀`, D83D DE00) after `Ａ` (FF21), where UTF-16 puts it before. An empty end is
/// not a user: the id it produces does not parse, and the server answers `1001` for it.
///
/// The rule is a contract shared with the server and the other SDKs; `single-chat-id-vectors.json` at
/// the root of the SDK repository is its executable form, and `SingleChatIdTests` holds this function
/// to every vector in it.
///
/// 单聊 id，与服务端给的同一个：两个原始 user id 按 UTF-16 码元排序，`~` 写成 `~0`、`_` 写成 `~1`，
/// 前缀后唯一的 `_` 是分隔符，所以每个 id 恰好对应一对人。谁先传都一样；顺序按原始 id 的 UTF-16 码元比，
/// 不按转义后的两半，也不用 `String` 的 `<`（它按 Unicode 标量比，遇到代理对给出相反的答案）。
public func singleConversationId(_ a: String, _ b: String) -> String {
    // a <= b in UTF-16 code units: b does not strictly precede a.
    let inOrder = !b.utf16.lexicographicallyPrecedes(a.utf16)
    let first = inOrder ? a : b
    let second = inOrder ? b : a
    return "s_" + escapeSingleEnd(first) + "_" + escapeSingleEnd(second)
}

/// `~` becomes `~0` and `_` becomes `~1`, scalar by scalar — `~` first is implicit, since each scalar
/// is looked at once. Not `replacing(_:with:)` or `replacingOccurrences(of:with:)`: they search by
/// `Character` or by canonical equivalence rather than by code unit, so a `~` or `_` that a combining
/// mark follows is part of a larger grapheme and can go out unescaped.
private func escapeSingleEnd(_ userId: String) -> String {
    var escaped = String.UnicodeScalarView()
    for scalar in userId.unicodeScalars {
        switch scalar {
        case "~":
            escaped.append(contentsOf: "~0".unicodeScalars)
        case "_":
            escaped.append(contentsOf: "~1".unicodeScalars)
        default:
            escaped.append(scalar)
        }
    }
    return String(escaped)
}
