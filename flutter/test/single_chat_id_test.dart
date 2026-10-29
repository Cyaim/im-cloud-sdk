// singleConversationId against the shared vectors in `single-chat-id-vectors.json` at the root of the
// SDK repository — the same file the server's SingleChatIdVectorTests, the widget and every other
// SDK read.
//
// A single-chat id one side builds differently is not an error anywhere: it is a second
// conversation, or one nobody can read. So the expected ids come from the file, written out from the
// grammar, never from this implementation — implementations that only check each other agree
// forever, including on the day they are all wrong.
//
// 单聊 id 对着共享向量断言：一端拼得不一样不会报错，得到的是第二个会话或谁也读不了的会话。
// 期望值来自那份文件，不来自被测实现。

import 'dart:convert';
import 'dart:io';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// Walks up from the working directory until the vectors turn up, as the inventory readers do.
Map<String, dynamic> vectors() {
  Directory directory = Directory.current.absolute;

  for (int hop = 0; hop < 8; hop++) {
    final File candidate = File('${directory.path}/single-chat-id-vectors.json');
    if (candidate.existsSync()) {
      return jsonDecode(candidate.readAsStringSync()) as Map<String, dynamic>;
    }
    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }

  throw StateError(
      'could not locate sdk/single-chat-id-vectors.json from ${Directory.current.path}');
}

List<Map<String, dynamic>> section(String name) {
  final List<Map<String, dynamic>> entries =
      (vectors()[name] as List<dynamic>).cast<Map<String, dynamic>>();
  expect(entries, isNotEmpty, reason: 'single-chat-id-vectors.json has no "$name" vectors');
  return entries;
}

void main() {
  group('singleConversationId: the shared single-chat id vectors', () {
    test('builds every build vector, whichever end comes first', () {
      for (final Map<String, dynamic> v in section('build')) {
        final String a = v['a'] as String;
        final String b = v['b'] as String;
        final String id = v['id'] as String;
        expect(singleConversationId(a, b), id, reason: "'$a' + '$b' (${v['note']})");
        expect(singleConversationId(b, a), id, reason: "'$b' + '$a', ends swapped");
      }
    });

    test('rebuilds every id the file says parses from the pair it parses to', () {
      for (final Map<String, dynamic> v
          in section('parse').where((Map<String, dynamic> p) => p['ok'] == true)) {
        final String id = v['id'] as String;
        expect(v['a'], isA<String>(), reason: "parse vector '$id' is ok but names no pair");
        expect(v['b'], isA<String>(), reason: "parse vector '$id' is ok but names no pair");
        expect(singleConversationId(v['a'] as String, v['b'] as String), id, reason: id);
      }
    });

    test('never builds an id the file refuses', () {
      final Set<String> refused = section('parse')
          .where((Map<String, dynamic> p) => p['ok'] == false)
          .map((Map<String, dynamic> p) => p['id'] as String)
          .toSet();
      for (final Map<String, dynamic> v in section('build')) {
        final String id = singleConversationId(v['a'] as String, v['b'] as String);
        expect(refused.contains(id), isFalse,
            reason: "'${v['a']}' + '${v['b']}' built '$id', which the file lists as malformed");
      }
    });

    test('still has the vectors this implementation is easiest to get wrong on', () {
      // Named rather than counted: a file trimmed to make a failure go away keeps a count plausible.
      // 点名而不是数数：为了让失败消失而删掉几条之后，数量照样说得过去。
      final Set<String> built =
          section('build').map((Map<String, dynamic> v) => v['id'] as String).toSet();
      for (final String id in <String>[
        's_alice_bob',
        's_u~1alice_u~1bob',
        's_a~01_c',
        's_user~11_user~110',
        's_😀_Ａ',
      ]) {
        expect(built, contains(id),
            reason: "build vector '$id' is missing from single-chat-id-vectors.json");
      }
    });
  });
}
