import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Conformance tests 1–13 from `sdk/CONTRACT.md` §10, "Cursor and cold start".
///
/// Five of these (1, 4, 5, 11, 13) fail against the SDK as it shipped, and that is why they were
/// written first. The one that matters most is the first: this SDK kept `_maxSeq` in a private
/// `Map` with no public accessor and nothing that outlived the process, so every cold start
/// reported an empty `convSeqs`, got no `gapsFrom` back — the server can only diff against what it
/// is told — and then adopted the server's newest `maxSeq` in the first-sight branch. Every
/// message that arrived while the app was closed ended up behind the cursor: never requested,
/// never delivered, no error, no log line, and nothing later that corrects it.
///
/// 这一组前 13 个用例对应契约 §10；其中 1/4/5/11/13 在修复前必然失败。
void main() {
  group('cold start', () {
    test('1. coldStartRestoresCursors', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(
          convSeqs: <String, int>{'c1': 100},
          conversationCursor: 4242,
        ),
      );

      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      final FakeRequest sync = gateway.requestsTo('conn.sync').first;

      // The whole bug in one assertion: what the client tells the server it already holds.
      expect(sync.body['convSeqs'], <String, dynamic>{'c1': 100});
      expect(sync.body['conversationCursor'], 4242);

      expect(client.committedSeq('c1'), 100);
      expect(client.deliveredSeq('c1'), 100);

      await client.dispose();
    });

    test('the SDK stamps (host, appId, userId) onto every snapshot it writes', () async {
      final RecordingCursorStore store = RecordingCursorStore();

      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store, userId: 'bob');

      await client.commit('c1', 5);
      await client.flushCursors();

      expect(store.persisted.scope, 'im.test|demo|bob');

      await client.dispose();
    });

    test('cursors belonging to another account are refused, not replayed', () async {
      // CONTRACT §5.3, the account-switch guarantee. Alice signed out, Bob signed in, and the app
      // pointed both at one store. Handing Bob Alice's position marks messages Bob has never seen
      // as already consumed — one person's cursors replaying into another person's client,
      // silently and permanently.
      //
      // The guarantee is structural: it comes from the identity the SDK stamped into the snapshot,
      // so a store that does nothing to keep two accounts apart still cannot defeat it.
      final List<String> warnings = <String>[];
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(
          convSeqs: <String, int>{'c1': 100},
          conversationCursor: 4242,
          scope: 'im.test|demo|alice',
        ),
      );

      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(
        gateway,
        cursorStore: store,
        userId: 'bob',
        logger: warnings.add,
      );

      final FakeRequest sync = gateway.requestsTo('conn.sync').first;
      expect(sync.body['convSeqs'], isEmpty, reason: "Bob must not report Alice's position");
      expect(sync.body['conversationCursor'], 0);
      expect(client.committedSeq('c1'), 0);
      expect(client.cursorScopeRejected, isTrue);
      expect(client.cursorsFrozen, isFalse);
      expect(warnings.where((String w) => w.contains('im.test|demo|alice')), isNotEmpty);

      await client.dispose();
    });

    test('cursors stamped with this account are used as they always were', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(
          convSeqs: <String, int>{'c1': 100},
          conversationCursor: 4242,
          scope: 'im.test|demo|bob',
        ),
      );

      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store, userId: 'bob');

      final FakeRequest sync = gateway.requestsTo('conn.sync').first;
      expect(sync.body['convSeqs'], <String, dynamic>{'c1': 100});
      expect(client.cursorScopeRejected, isFalse);

      await client.dispose();
    });

    test('2. coldStartWithoutStoreDoesNotSilentlyAdopt', () async {
      final List<String> warnings = <String>[];
      final ImCursorStore store = ImCursorStore.inMemory();

      final FakeGateway gateway = FakeGateway();
      final ImClient client =
          await connectedClient(gateway, cursorStore: store, logger: warnings.add);

      // One warning, from the client rather than the store, naming the section — so an integrator
      // who chose this can see that they chose it. The client raises it because whether the
      // application is told it is running without persistence is not a store's decision: a store
      // that could declare itself persistent could silence this line.
      expect(warnings.where((String w) => w.contains('§5.3')), hasLength(1));
      expect(warnings.singleWhere((String w) => w.contains('§5.3')), contains('NOT persisted'));

      // And the application can observe that nothing was restored, rather than having to infer it.
      expect(client.cursors.convSeqs, isEmpty);
      expect(gateway.requestsTo('conn.sync').first.body['convSeqs'], isEmpty);

      await client.dispose();
    });

    test('3. firstSightAdoptsAndPersistsSynchronously', () async {
      final RecordingCursorStore store = RecordingCursorStore();
      final FakeGateway gateway = FakeGateway();

      final List<bool> adoptionWasOnDiskAtNextPage = <bool>[];

      gateway.on('conn.sync', (FakeRequest request) {
        if (request.body['cursor'] == null) {
          return FakeData(resumePage(
            conversations: <Map<String, dynamic>>[
              conversationView('c1', maxSeq: 50, updatedAt: 10),
            ],
            hasMore: true,
            nextCursor: 'page-2',
          ));
        }

        adoptionWasOnDiskAtNextPage.add(
          store.writes.any((ImCursorSnapshot s) => s.convSeqs['c1'] == 50),
        );
        return FakeData(resumePage(hasMore: false));
      });

      // A ten-second debounce: only an explicitly flushed adoption write could reach the store
      // before the second page is requested.
      final ImClient client = await connectedClient(
        gateway,
        cursorStore: store,
        cursorSaveDebounce: const Duration(seconds: 10),
      );
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 2,
          because: 'the resume never asked for the second page');

      expect(adoptionWasOnDiskAtNextPage, <bool>[true]);
      expect(client.committedSeq('c1'), 50);

      await client.dispose();
    });
  });

  group('resume paging', () {
    test('4. resumePagesUntilHasMoreFalse', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(
          convSeqs: <String, int>{'c1': 10, 'c2': 10, 'c3': 10},
        ),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.script('conn.sync', <FakeReply>[
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 11, updatedAt: 300),
          ],
          gapsFrom: <String, dynamic>{'c1': 11},
          hasMore: true,
          nextCursor: 'p2',
        )),
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c2', maxSeq: 11, updatedAt: 200),
          ],
          gapsFrom: <String, dynamic>{'c2': 11},
          hasMore: true,
          nextCursor: 'p3',
        )),
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c3', maxSeq: 11, updatedAt: 100),
          ],
          gapsFrom: <String, dynamic>{'c3': 11},
          hasMore: false,
        )),
      ]);

      gateway.on('msg.sync', (FakeRequest request) {
        final String conversationId = request.body['conversationId'] as String;
        return FakeData(syncPage(
          conversationId: conversationId,
          seqs: <int>[11],
          hasMore: false,
        ));
      });

      final ImClient client = await connectedClient(gateway, cursorStore: store);
      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      await pumpUntil(() => gateway.callsTo('msg.sync') >= 3,
          because: 'the resume stopped before it had paged through every conversation with a gap');
      await settle();

      expect(gateway.callsTo('conn.sync'), 3);
      expect(
        gateway.requestsTo('msg.sync').map((FakeRequest r) => r.body['conversationId']),
        <String>['c1', 'c2', 'c3'],
      );

      await client.dispose();
    });

    test('5. conversationCursorAdvancesOnlyAfterFullRun', () async {
      final RecordingCursorStore store = RecordingCursorStore();
      final FakeGateway gateway = FakeGateway();

      gateway.script('conn.sync', <FakeReply>[
        // Page 1 is the newest, so it carries the largest updatedAt. Taking it and stopping is the
        // bug: the server filters UpdatedAt > updatedAfter and would never return pages 2…N again.
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 5, updatedAt: 900),
          ],
          hasMore: true,
          nextCursor: 'p2',
        )),
        const FakeStatus(1, msg: 'the node went away mid-run'),
      ]);

      final ImClient client = await connectedClient(gateway, cursorStore: store);
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 2,
          because: 'the resume never attempted the second page');
      await settle();

      expect(client.cursors.conversationCursor, 0,
          reason: 'an interrupted run must not move conversationCursor at all');
      expect(
        store.writes.every((ImCursorSnapshot s) => s.conversationCursor == 0),
        isTrue,
        reason: 'and must not have written a moved cursor on the way past either',
      );

      // The adoption from page 1 does stand: commits are per conversation and monotonic, so
      // keeping them is safe even though the run as a whole did not finish.
      expect(client.committedSeq('c1'), 5);

      await client.dispose();
    });

    test('6. pageWithFewerItemsThanLimitStillPages', () async {
      final FakeGateway gateway = FakeGateway();

      // ConversationService.ListAsync computes the paging cursor from the raw page *before*
      // deleted conversations are filtered out, so a page can be far shorter than the limit and
      // still have more behind it. Stopping on `items.length < limit` loses the rest.
      gateway.script('conn.sync', <FakeReply>[
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 1, updatedAt: 5),
          ],
          hasMore: true,
          nextCursor: 'p2',
        )),
        FakeData(resumePage(hasMore: false)),
      ]);

      final ImClient client = await connectedClient(gateway);
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 2,
          because: 'a short page ended the paging loop, which items.length must never do');
      await settle();

      expect(gateway.callsTo('conn.sync'), 2);
      expect(gateway.requestsTo('conn.sync')[1].body['cursor'], 'p2');

      await client.dispose();
    });

    test('7. deliveredResetsToCommittedOnReconnect', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 3}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.script('conn.sync', <FakeReply>[
        FakeData(resumePage(hasMore: false)),
        FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 5, updatedAt: 20),
          ],
          gapsFrom: <String, dynamic>{'c1': 4},
          hasMore: false,
        )),
      ]);
      gateway.on(
        'msg.sync',
        (FakeRequest _) => FakeData(syncPage(
          conversationId: 'c1',
          seqs: <int>[4, 5],
          hasMore: false,
        )),
      );

      final ImClient client = await connectedClient(gateway, cursorStore: store);
      final List<int> delivered = <int>[];
      client.messages.listen((ImMessage m) => delivered.add(m.seq));

      gateway.socket.deliver(push('evt.message', message('c1', 4)));
      gateway.socket.deliver(push('evt.message', message('c1', 5)));
      await pumpUntil(() => delivered.length == 2, because: 'the first two messages never arrived');

      // Received, but the application never said it had stored them.
      expect(client.deliveredSeq('c1'), 5);
      expect(client.committedSeq('c1'), 3);

      await gateway.socket.die();
      await pumpUntil(() => gateway.sockets.length >= 2, timeout: const Duration(seconds: 6));
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 2, timeout: const Duration(seconds: 6));
      await pumpUntil(() => delivered.length == 4,
          because: 'the uncommitted message was not redelivered after the reconnect');

      expect(gateway.requestsTo('conn.sync')[1].body['convSeqs'], <String, dynamic>{'c1': 3});
      expect(delivered, <int>[4, 5, 4, 5],
          reason: 'uncommitted messages must be delivered again, not suppressed as duplicates');

      await client.dispose();
    });
  });

  group('gaps', () {
    test('8. oversizedGapAdvancesCursorAndRaisesReload', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 1}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'conn.sync',
        (FakeRequest _) => FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 900, updatedAt: 30),
          ],
          gapsFrom: <String, dynamic>{'c1': 2},
          hasMore: false,
        )),
      );

      final ImClient client = ImClient(optionsFor(
        gateway.connect,
        cursorStore: store,
        maxAutoRepairSeq: 5,
        cursorSaveDebounce: Duration.zero,
      ));

      final List<String> reloads = <String>[];
      client.conversationNeedsReload.listen(reloads.add);

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => reloads.isNotEmpty,
          because: 'no conversationNeedsReload was raised for the oversized gap');
      await settle();

      expect(reloads, <String>['c1']);
      expect(gateway.callsTo('msg.sync'), 0, reason: '898 messages is not a backfill');

      // Both halves. Without the cursor advance, every later message looks like a gap and
      // re-requests a range we have already declined.
      expect(client.committedSeq('c1'), 900);
      expect(store.persisted.convSeqs['c1'], 900);

      await client.dispose();
    });

    test('9. seqZeroNeverMovesCursor', () async {
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway);

      final List<ImMessage> delivered = <ImMessage>[];
      client.messages.listen(delivered.add);

      gateway.socket.deliver(push('evt.message', message('room-1', 0)));
      await pumpUntil(() => delivered.length == 1,
          because: 'the seq-0 message was never delivered');
      await client.commit('room-1', 0);

      expect(client.deliveredSeq('room-1'), 0);
      expect(client.committedSeq('room-1'), 0);
      expect(client.cursors.convSeqs, isEmpty);

      await client.dispose();
    });

    test('10. storeLoadFailureDoesNotAdopt', () async {
      final RecordingCursorStore store = RecordingCursorStore(failLoad: true);
      final FakeGateway gateway = FakeGateway();

      gateway.on(
        'conn.sync',
        (FakeRequest _) => FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 500, updatedAt: 77),
          ],
          hasMore: false,
        )),
      );

      final ImClient client = ImClient(optionsFor(gateway.connect, cursorStore: store));
      final List<ImException> errors = <ImException>[];
      client.errors.listen(errors.add);

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 1,
          because: 'the resume never issued conn.sync');
      await settle();

      // Surfaced, not logged away.
      expect(errors, isNotEmpty);
      expect(errors.first.message, contains('cursor store failed to load'));
      expect(client.cursorsFrozen, isTrue);

      // And nothing adopted: adopting here would discard history the application still holds.
      expect(client.committedSeq('c1'), 0);
      expect(client.cursors.conversationCursor, 0);
      expect(store.writes.any((ImCursorSnapshot s) => s.convSeqs.containsKey('c1')), isFalse);

      // The sanctioned recovery still works: the application re-derives from its own database.
      await client.commit('c1', 480);
      expect(client.committedSeq('c1'), 480);

      await client.dispose();
    });
  });

  group('repair paging', () {
    test('11. repairPagesUntilSyncHasMoreFalse', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 1}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'conn.sync',
        (FakeRequest _) => FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 7, updatedAt: 9),
          ],
          gapsFrom: <String, dynamic>{'c1': 2},
          hasMore: false,
        )),
      );

      // MessageService.SyncAsync clamps limit to 500 and returns hasMore. An SDK that treats
      // msg.sync as one-shot leaves everything past the first page as a permanent hole.
      gateway.script('msg.sync', <FakeReply>[
        FakeData(syncPage(conversationId: 'c1', seqs: <int>[2, 3], hasMore: true, maxSeq: 7)),
        FakeData(syncPage(conversationId: 'c1', seqs: <int>[4, 5], hasMore: true, maxSeq: 7)),
        FakeData(syncPage(conversationId: 'c1', seqs: <int>[6, 7], hasMore: false, maxSeq: 7)),
      ]);

      final ImClient client = ImClient(optionsFor(gateway.connect, cursorStore: store));
      final List<int> delivered = <int>[];
      client.messages.listen((ImMessage m) => delivered.add(m.seq));

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => delivered.length == 6,
          because: 'the repair stopped before msg.sync said hasMore was false');
      await settle();

      expect(delivered, <int>[2, 3, 4, 5, 6, 7]);
      expect(gateway.callsTo('msg.sync'), 3);
      expect(
          gateway.requestsTo('msg.sync').map((FakeRequest r) => r.body['fromSeq']), <int>[2, 4, 6]);

      await client.dispose();
    });

    test('12. repairPagesWhenPageIsShorterThanLimit', () async {
      final RecordingCursorStore store = RecordingCursorStore(
        initial: const ImCursorSnapshot(convSeqs: <String, int>{'c1': 1}),
      );

      final FakeGateway gateway = FakeGateway();
      gateway.on(
        'conn.sync',
        (FakeRequest _) => FakeData(resumePage(
          conversations: <Map<String, dynamic>>[
            conversationView('c1', maxSeq: 5, updatedAt: 9),
          ],
          gapsFrom: <String, dynamic>{'c1': 2},
          hasMore: false,
        )),
      );

      // hasMore is computed on the raw window before per-user hidden messages are filtered out, so
      // a page can be one message long — or empty — and still not be the end.
      gateway.script('msg.sync', <FakeReply>[
        FakeData(syncPage(conversationId: 'c1', seqs: <int>[2], hasMore: true, maxSeq: 5)),
        FakeData(syncPage(conversationId: 'c1', seqs: <int>[3, 4, 5], hasMore: false, maxSeq: 5)),
      ]);

      final ImClient client = ImClient(optionsFor(gateway.connect, cursorStore: store));
      final List<int> delivered = <int>[];
      client.messages.listen((ImMessage m) => delivered.add(m.seq));

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => delivered.length == 4,
          because: 'a short msg.sync page ended the repair, which messages.length must never do');
      await settle();

      expect(delivered, <int>[2, 3, 4, 5]);
      expect(gateway.callsTo('msg.sync'), 2);

      await client.dispose();
    });

    test('13. oversizedLiveGapRaisesReload', () async {
      final FakeGateway gateway = FakeGateway();

      final ImClient client = ImClient(optionsFor(
        gateway.connect,
        maxAutoRepairSeq: 5,
      ));

      final List<String> reloads = <String>[];
      final List<int> delivered = <int>[];
      client.conversationNeedsReload.listen(reloads.add);
      client.messages.listen((ImMessage m) => delivered.add(m.seq));

      unawaited(client.connect());
      await pumpUntil(() => gateway.sockets.isNotEmpty);
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 1,
          because: 'the resume never issued conn.sync');
      await settle();

      gateway.socket.deliver(push('evt.message', message('c1', 1)));
      await pumpUntil(() => delivered.length == 1, because: 'the first live message never arrived');

      // A 98-wide jump on the live socket. The cursor stays honest either way; without the event
      // the application is simply never told a stretch of the conversation was skipped, and a hole
      // nobody is told about is the same defect as a hole nobody repairs.
      gateway.socket.deliver(push('evt.message', message('c1', 100)));
      await pumpUntil(() => reloads.isNotEmpty,
          because: 'the live path never raised conversationNeedsReload for the oversized gap');
      await pumpUntil(() => delivered.length == 2,
          because: 'the triggering message was not delivered after the decline');

      expect(reloads, <String>['c1']);
      expect(gateway.callsTo('msg.sync'), 0);
      expect(delivered, <int>[1, 100]);
      expect(client.committedSeq('c1'), 99);

      await client.dispose();
    });
  });

  group('cursor store', () {
    test('a file store round-trips and rejects a corrupt file rather than looking empty', () async {
      final Directory directory = await Directory.systemTemp.createTemp('cyaim-cursor-test');
      final String path = '${directory.path}/cursors.json';

      addTearDown(() => directory.delete(recursive: true));

      final ImCursorStore store = ImCursorStore.file(path);

      // A missing file is a fresh install, and that is the only case where "empty" is the answer.
      expect((await store.load()).convSeqs, isEmpty);

      await store.save(const ImCursorSnapshot(
        convSeqs: <String, int>{'c1': 12, 'c2': 9007199254740993},
        conversationCursor: 55,
      ));

      final ImCursorSnapshot reloaded = await ImCursorStore.file(path).load();
      expect(reloaded.convSeqs['c1'], 12);
      // 64-bit seqs survive: Dart ints are 64-bit off the web, which is why the SDK never uses
      // doubles for a seq.
      expect(reloaded.convSeqs['c2'], 9007199254740993);
      expect(reloaded.conversationCursor, 55);

      // The write is atomic, so no `.tmp` is left behind for the next load to trip over.
      expect(await File('$path.tmp').exists(), isFalse);

      await File(path).writeAsString('{not json');
      await expectLater(ImCursorStore.file(path).load(), throwsA(isA<FormatException>()));
    });

    test('a seq stored as a JSON string decodes, because the gateway may send one', () {
      final ImCursorSnapshot snapshot = ImCursorSnapshot.fromJson(
        jsonDecode('{"convSeqs":{"c1":"1234"},"conversationCursor":"99"}') as Map<String, dynamic>,
      );

      expect(snapshot.convSeqs['c1'], 1234);
      expect(snapshot.conversationCursor, 99);
    });

    test('the scope key separates users on one device', () {
      final ImCursorScope alice = ImCursorScope.of(
        endpoint: 'wss://im.example.com/im',
        appId: 'app-1',
        userId: 'alice',
      );
      final ImCursorScope bob = ImCursorScope.of(
        endpoint: 'wss://im.example.com/im',
        appId: 'app-1',
        userId: 'bob',
      );

      expect(alice.key, isNot(bob.key));
      expect(alice.key, 'im.example.com|app-1|alice');
      // Safe as a filename on every platform the SDK targets.
      expect(alice.storageKey, 'im.example.com_app-1_alice');
      expect(alice.storageKey, matches(RegExp(r'^[A-Za-z0-9._-]+$')));
    });

    test('commit is monotonic and a lower seq is ignored, not an error', () async {
      final RecordingCursorStore store = RecordingCursorStore();
      final FakeGateway gateway = FakeGateway();
      final ImClient client = await connectedClient(gateway, cursorStore: store);

      await client.commit('c1', 10);
      await client.commit('c1', 4);
      expect(client.committedSeq('c1'), 10);

      await client.commit('c1', 11);
      expect(client.committedSeq('c1'), 11);
      expect(store.persisted.convSeqs['c1'], 11);

      await client.dispose();
    });

    test('ordinary commits are debounced but flushed before the next conn.sync', () async {
      final RecordingCursorStore store = RecordingCursorStore();
      final FakeGateway gateway = FakeGateway();

      final ImClient client = await connectedClient(
        gateway,
        cursorStore: store,
        cursorSaveDebounce: const Duration(seconds: 10),
      );

      await client.commit('c1', 7);
      expect(store.writes, isEmpty, reason: 'a ten-second debounce has not elapsed');

      // A lost debounced commit costs one duplicate delivery, so coalescing is fine — but the
      // value has to be on disk before it is reported to the server.
      await gateway.socket.die();
      await pumpUntil(() => gateway.sockets.length >= 2, timeout: const Duration(seconds: 6));
      gateway.openLatest();
      await pumpUntil(() => gateway.callsTo('conn.sync') >= 2, timeout: const Duration(seconds: 6));

      expect(store.persisted.convSeqs['c1'], 7);
      expect(gateway.requestsTo('conn.sync')[1].body['convSeqs'], <String, dynamic>{'c1': 7});

      await client.dispose();
    });
  });
}
