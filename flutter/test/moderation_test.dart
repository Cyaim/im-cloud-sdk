import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `moderation.report` — the other half of `friend.block`.
///
/// App-store review requires both a way to block an abusive user and a way to report objectionable
/// content, which is the same argument that put blocking in T2. An SDK that types one and not the
/// other still fails the submission, and the customer finds that out from a reviewer rather than
/// from us.
///
/// Two properties carry the weight here and neither is visible from the method signature: the
/// reporter is never a parameter, and the message id leaves as a string.
///
/// 举报与拉黑是同一次提审的两个必要条件。这里守住两件签名上看不出来的事：
/// 举报人永远不是参数，消息 id 以字符串出线。
void main() {
  /// A real snowflake: 2^58-ish, thirty-eight times past what a JavaScript number holds exactly —
  /// which is what Dart's `int` compiles to on the web.
  const String snowflake = '350598345233801216';

  group('moderation.report', () {
    test('puts no reporter in the body — the socket already carries one', () async {
      // A field for the reporter would let one account file in another's name, which is both a way
      // to get somebody banned and a way to poison the count a moderator decides on. There is no
      // such field on the server, and an SDK that invented one would be teaching a model the
      // platform does not have.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.moderation.report(const ImSubmitReportRequest(
        targetUserId: 'bob',
        category: ImReportCategory.harassment,
        note: 'threats in the group',
      ));

      final FakeRequest request = gateway.requestsTo('moderation.report').single;
      expect(request.body.keys.toList()..sort(), <String>['category', 'note', 'targetUserId']);
      expect(request.body['targetUserId'], 'bob');
      expect(request.body['category'], 'harassment');

      await client.dispose();
    });

    test('sends the message id as a string, digits intact', () async {
      // The failure this prevents is a report filed against a message id the server never issued.
      // On the web a Dart `int` is a JavaScript number, and near 2^58 that holds a *different*
      // integer — the moderator then opens a row pointing at nothing. Checked against the encoded
      // frame rather than the decoded body, because the quotes are the whole point.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.moderation.report(const ImSubmitReportRequest(
        targetUserId: 'bob',
        conversationId: 'c1',
        messageId: snowflake,
      ));

      final String frame = gateway.socket.sent.firstWhere(
        (String payload) => payload.contains('moderation.report'),
      );
      expect(frame, contains('"messageId":"$snowflake"'));

      await client.dispose();
    });

    test('a report about the account names no message', () async {
      // An absent field is how the server hears "this is about the account, not one message".
      // Blank and "0" read the same on the current server, but an older one took a number and
      // failed to bind `""`, which is what a report screen with nothing selected would otherwise
      // send — so the SDK omits it.
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      await client.moderation.report(const ImSubmitReportRequest(targetUserId: 'bob'));
      await client.moderation.report(const ImSubmitReportRequest(
        targetUserId: 'bob',
        messageId: '',
      ));

      for (final FakeRequest request in gateway.requestsTo('moderation.report')) {
        expect(request.body.containsKey('messageId'), isFalse);
        // Unset means the server's own default, and it is not the SDK's job to guess a different
        // one.
        expect(request.body['category'], 'other');
      }

      await client.dispose();
    });

    test('returns the receipt, not the report', () async {
      // A reporter has no business reading back the moderation state of their own report, and the
      // stored row carries fields — handledBy, resolution — that belong to the tenant's moderators.
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'moderation.report',
        (FakeRequest _) => const FakeData(<String, dynamic>{
          'reportId': 'rp_9f2c',
          'createdAt': 1756339200000,
        }),
      );

      final ImClient client = await connectedClient(gateway);
      final ImReportReceipt receipt =
          await client.moderation.report(const ImSubmitReportRequest(targetUserId: 'bob'));

      expect(receipt.reportId, 'rp_9f2c');
      expect(receipt.createdAt, 1756339200000);

      await client.dispose();
    });

    test('reporting yourself surfaces the server refusal', () async {
      // The server refuses it; the SDK does not pre-empt that check, because the reporter's own id
      // is not something the request object knows.
      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'moderation.report',
        (FakeRequest _) => const FakeFail(
          ImErrorCode.invalidArgument,
          message: 'a user cannot report themselves',
        ),
      );

      final ImClient client = await connectedClient(gateway);

      await expectLater(
        client.moderation.report(const ImSubmitReportRequest(targetUserId: 'alice')),
        throwsA(isA<ImException>()
            .having((ImException e) => e.code, 'code', ImErrorCode.invalidArgument)
            .having((ImException e) => e.target, 'target', 'moderation.report')),
      );

      await client.dispose();
    });

    test('every category the server files has a named constant', () {
      // Unlike a push provider, an unknown category is refused outright rather than folded — so a
      // picker built from anything but this list files reports the server will not take.
      expect(ImReportCategory.values, <String>[
        'spam',
        'harassment',
        'fraud',
        'pornography',
        'violence',
        'other',
      ]);
    });
  });
}
