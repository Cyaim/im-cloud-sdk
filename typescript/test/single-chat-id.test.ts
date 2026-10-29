/**
 * `singleConversationId` against the shared vectors in `single-chat-id-vectors.json` at the root of
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

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';

import { singleConversationId } from '../src/index.js';

interface BuildVector {
  a: string;
  b: string;
  id: string;
  note?: string;
}

interface ParseVector {
  id: string;
  ok: boolean;
  single: boolean;
  a?: string;
  b?: string;
  why?: string;
}

interface VectorFile {
  build: BuildVector[];
  parse: ParseVector[];
}

/**
 * The compiled tests run from `dist-test/test`, the sources from `test`: walk up until the vectors
 * turn up, as `inventory.ts` does for the endpoint inventory, rather than hard-coding a depth.
 */
function loadVectors(): VectorFile {
  let directory = dirname(fileURLToPath(import.meta.url));

  for (let hop = 0; hop < 8; hop++) {
    const candidate = join(directory, 'single-chat-id-vectors.json');
    if (existsSync(candidate)) {
      const file = JSON.parse(readFileSync(candidate, 'utf8')) as VectorFile;
      assert.ok(file.build.length > 0, 'single-chat-id-vectors.json has no build vectors');
      assert.ok(file.parse.length > 0, 'single-chat-id-vectors.json has no parse vectors');
      return file;
    }
    directory = dirname(directory);
  }

  throw new Error('could not locate sdk/single-chat-id-vectors.json from ' + import.meta.url);
}

const vectors = loadVectors();

describe('singleConversationId: the shared single-chat id vectors', () => {
  it('builds every build vector, whichever end comes first', () => {
    for (const v of vectors.build) {
      assert.equal(singleConversationId(v.a, v.b), v.id, `'${v.a}' + '${v.b}' (${v.note ?? ''})`);
      assert.equal(singleConversationId(v.b, v.a), v.id, `'${v.b}' + '${v.a}', ends swapped`);
    }
  });

  it('rebuilds every id the file says parses from the pair it parses to', () => {
    for (const v of vectors.parse.filter((p) => p.ok)) {
      assert.ok(v.a !== undefined && v.b !== undefined, `parse vector '${v.id}' is ok but names no pair`);
      assert.equal(singleConversationId(v.a, v.b), v.id, v.id);
    }
  });

  it('never builds an id the file refuses', () => {
    const refused = new Set(vectors.parse.filter((p) => !p.ok).map((p) => p.id));
    for (const v of vectors.build) {
      const id = singleConversationId(v.a, v.b);
      assert.ok(!refused.has(id), `'${v.a}' + '${v.b}' built '${id}', which the file lists as malformed`);
    }
  });

  it('still has the vectors this implementation is easiest to get wrong on', () => {
    // Named rather than counted: a file trimmed to make a failure go away keeps a count plausible.
    // 点名而不是数数：为了让失败消失而删掉几条之后，数量照样说得过去。
    const built = new Set(vectors.build.map((v) => v.id));
    for (const id of ['s_alice_bob', 's_u~1alice_u~1bob', 's_a~01_c', 's_user~11_user~110', 's_😀_Ａ']) {
      assert.ok(built.has(id), `build vector '${id}' is missing from single-chat-id-vectors.json`);
    }
  });
});
