/**
 * The id of the single chat between two users, the same one the server gives it — so a conversation
 * can be addressed (`msg.history`, `conv.get`, `commit`, a cursor) before either side has sent
 * anything, or from nothing but the two user ids.
 *
 * `"s_" + enc(A) + "_" + enc(B)`, where A and B are the two **raw** user ids ordered by UTF-16 code
 * unit (A first when they are equal) and `enc` writes every `~` as `~0` and every `_` as `~1`. After
 * escaping neither half contains `_`, so the one `_` after the prefix is the separator and every id
 * names exactly one pair: `u_alice` with `u_bob` is `s_u~1alice_u~1bob`, while ids with neither `_`
 * nor `~` come out as they always did (`s_alice_bob`).
 *
 * Which end you pass first does not matter. The order is decided on the raw ids, not on the escaped
 * halves — escaping does not keep order (`_` sorts before the letters, its escape `~1` after them) —
 * and JavaScript's `<=` on strings is exactly that UTF-16 order (`localeCompare` is not). An empty
 * end is not a user: the id it produces does not parse, and the server answers `1001` for it.
 *
 * The rule is a contract shared with the server and the other SDKs; `single-chat-id-vectors.json` at
 * the root of the SDK repository is its executable form, and `test/single-chat-id.test.ts` holds
 * this function to every vector in it.
 *
 * 单聊 id，与服务端给的同一个：两个原始 user id 按 UTF-16 码元排序，`~` 写成 `~0`、`_` 写成 `~1`，
 * 前缀后唯一的 `_` 是分隔符，所以每个 id 恰好对应一对人。谁先传都一样；顺序按原始 id 比，不按转义后的两半。
 */
export function singleConversationId(a: string, b: string): string {
  const [first, second] = a <= b ? [a, b] : [b, a];
  return `s_${escapeEnd(first)}_${escapeEnd(second)}`;
}

/** `~` first, then `_` — the other way round would escape the `~` of every `~1` just written. */
function escapeEnd(userId: string): string {
  return userId.replaceAll('~', '~0').replaceAll('_', '~1');
}
