import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { ImError } from '../src/protocol.js';
import { FakeSocket, until } from './fake-socket.js';
import { closeAll, openClient } from './doubles.js';

/**
 * `moderation.report` — the other half of `friend.block`.
 *
 * App-store review requires both a way to block an abusive user and a way to report objectionable
 * content, which is the same argument that put blocking in T2. An SDK that types one and not the
 * other still fails the submission, and the customer finds that out from a reviewer rather than
 * from us.
 *
 * Two properties carry the weight here and neither is visible from the method signature alone: the
 * reporter is never a parameter, and the message id leaves as a string.
 *
 * 举报与拉黑是同一次提审的两个必要条件。这里守住两件签名上看不出来的事：
 * 举报人永远不是参数，消息 id 以字符串出线。
 */

/** A real snowflake: 2^58-ish, thirty-eight times past what a JS number holds exactly. */
const SNOWFLAKE = '350598345233801216';

describe('moderation.report', () => {
  beforeEach(() => FakeSocket.reset());
  afterEach(closeAll);

  it('puts no reporter in the body — the socket already carries one', async () => {
    // A field for the reporter would let one account file in another's name, which is both a way
    // to get somebody banned and a way to poison the count a moderator decides on. There is no
    // such field, and an SDK that invented one would be teaching a model the server does not have.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    // Never answered: this test is about the frame, and the teardown fails it 1004.
    void client.moderation
      .report({ targetUserId: 'bob', category: 'harassment', note: 'threats' })
      .catch(() => {});
    await until(() => socket.requestsTo('moderation.report').length > 0);

    const body = socket.requestsTo('moderation.report')[0]!.body;
    assert.deepEqual(Object.keys(body).sort(), ['category', 'note', 'targetUserId']);
    assert.equal(body.targetUserId, 'bob');
    assert.equal(body.category, 'harassment');
  });

  it('sends the message id as a string, digits intact', async () => {
    // The failure this prevents is a report filed against a message id the server never issued:
    // a number round-trips through JSON.stringify as the shortest decimal for its double, which
    // near 2^58 is a different integer. The moderator then reads a row pointing at nothing.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.moderation.report({ targetUserId: 'bob', messageId: SNOWFLAKE }).catch(() => {});
    await until(() => socket.requestsTo('moderation.report').length > 0);

    const raw = socket.sent.find((frame) => frame.includes('moderation.report'))!;
    assert.match(raw, new RegExp(`"messageId":"${SNOWFLAKE}"`));
    assert.equal(socket.requestsTo('moderation.report')[0]!.body.messageId, SNOWFLAKE);
  });

  it('omits the message id when the report is about the account', async () => {
    // Zero reports the account rather than one message, and the server reads an absent field as
    // zero. Sending an id the reporter never named would attach the row to whatever message
    // happened to be on screen.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    void client.moderation.report({ targetUserId: 'bob' }).catch(() => {});
    await until(() => socket.requestsTo('moderation.report').length > 0);

    assert.deepEqual(Object.keys(socket.requestsTo('moderation.report')[0]!.body), ['targetUserId']);
  });

  it('returns the receipt, not the envelope', async () => {
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.moderation.report({ targetUserId: 'bob', category: 'spam' });
    await until(() => socket.requestsTo('moderation.report').length > 0);
    socket.replyLatest('moderation.report', { reportId: 'rp_9f2c', createdAt: 1755000000000 });

    assert.deepEqual(await pending, { reportId: 'rp_9f2c', createdAt: 1755000000000 });
  });

  it('rejects a refusal rather than swallowing it', async () => {
    // Reporting yourself, or naming a category the server does not have, comes back 1001. Unlike
    // `push.clicked` this is a user action with a user watching it: a reporting sheet that closes
    // on a refusal tells them the report was filed when it was not.
    const { client } = await openClient();
    const socket = FakeSocket.latest;

    const pending = client.moderation.report({ targetUserId: 'alice' });
    await until(() => socket.requestsTo('moderation.report').length > 0);

    const request = socket.requestsTo('moderation.report')[0]!;
    socket.reply(request.id, 'moderation.report', null, 1001, {
      message: 'a user cannot report themselves',
      traceId: 'trace-4',
    });

    await assert.rejects(
      () => pending,
      (error: unknown) =>
        error instanceof ImError &&
        error.code === 1001 &&
        error.traceId === 'trace-4' &&
        error.target === 'moderation.report' &&
        error.isRetryable === false,
    );
  });
});
