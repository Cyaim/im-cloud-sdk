// Every method on a namespace is an endpoint. Nothing else may live there.
//
// `sdk/CONTRACT.md` §4.1–4.2: the typed surface is the endpoint list transliterated, so a reader
// who knows an endpoint name knows the call, in every language, without a lookup table — and a
// support engineer can grep a bug report for the target that failed. A convenience method with no
// endpoint behind it breaks both halves of that.
//
// This is here because it happened. `sdk/unity` grew an `ImMsgApi.SendTextAsync` for which
// `msg.sendText` is not and never was an endpoint, and its own deprecation messages pointed at the
// invented method, so the SDK was actively teaching the wrong shape. A per-target coverage test
// cannot see that — a phantom that delegates to a real endpoint puts a legitimate target on the
// wire — so the check has to be on the *name*.
//
// `dart:mirrors` is a test-only import and stays that way: it is unavailable under Flutter's AOT
// compiler, which is exactly why nothing in `lib/` may touch it. This package's suite runs on the
// plain Dart VM (`dart test`, as CI does), where mirrors are present.
//
// 命名空间层只能有端点。按 target 统计的覆盖率测试看不见"转发到真端点的幽灵方法"，所以这里查方法名。

import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// Namespace class to the target prefix it mirrors.
final Map<Type, String> namespaces = <Type, String>{
  ImConnApi: 'conn',
  ImMsgApi: 'msg',
  ImConvApi: 'conv',
  ImUserApi: 'user',
  ImFriendApi: 'friend',
  ImGroupApi: 'group',
  ImMediaApi: 'media',
  ImPushApi: 'push',
  ImModerationApi: 'moderation',
  ImDiagApi: 'diag',
};

/// The push token cache is the only non-endpoint the contract puts on a namespace: §6.2 requires
/// re-registering on every connect, which needs somewhere to keep the token. `setToken` /
/// `clearToken` is the pair, spelled that way in all five SDKs.
const Set<String> allowed = <String>{
  'setToken',
  'clearToken',
  'registerOnConnect',
  'registerCachedToken', // deprecated alias for registerOnConnect, removed in 2.0
};

Set<String> endpointTargets() {
  Directory directory = Directory.current.absolute;

  for (int hop = 0; hop < 8; hop++) {
    final File inventory = File('${directory.path}/endpoint-inventory.json');
    if (inventory.existsSync()) {
      final Map<String, dynamic> parsed =
          jsonDecode(inventory.readAsStringSync()) as Map<String, dynamic>;
      final List<dynamic> endpoints = parsed['endpoints'] as List<dynamic>;

      return <String>{
        for (final dynamic endpoint in endpoints)
          (endpoint as Map<String, dynamic>)['target'] as String,
      };
    }

    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }

  throw StateError('could not locate sdk/endpoint-inventory.json from ${Directory.current.path}');
}

List<String> publicMethodsOf(Type type) {
  final ClassMirror mirror = reflectClass(type);
  final List<String> names = <String>[];

  mirror.declarations.forEach((Symbol key, DeclarationMirror declaration) {
    if (declaration is MethodMirror &&
        declaration.isRegularMethod &&
        !declaration.isPrivate &&
        !declaration.isStatic) {
      names.add(MirrorSystem.getName(key));
    }
  });

  return names;
}

void main() {
  group('the namespaced surface is endpoints only', () {
    test('names no endpoint the server does not have', () {
      final Set<String> endpoints = endpointTargets();
      expect(endpoints, isNotEmpty, reason: 'the inventory parsed to no targets at all');

      final List<String> strays = <String>[];

      for (final MapEntry<Type, String> entry in namespaces.entries) {
        for (final String method in publicMethodsOf(entry.key)) {
          if (allowed.contains(method)) continue;

          final String target = '${entry.value}.$method';
          if (!endpoints.contains(target)) {
            strays.add('${entry.key}.$method implies $target');
          }
        }
      }

      expect(
        strays,
        isEmpty,
        reason: 'these namespaced methods name endpoints the server does not have. Either the '
            'endpoint exists and endpoint-inventory.json needs regenerating, or the method is an '
            'invention and belongs on ImClient as a flat alias (CONTRACT §4.2)',
      );
    });

    test('keeps sendText off the namespaced surface', () {
      // The specific regression, named, so the failure says what went wrong rather than making a
      // reader re-derive it from a list of strays. The flat `im.sendText` alias is where it
      // belongs and stays until 2.0.
      expect(publicMethodsOf(ImMsgApi), isNot(contains('sendText')));
      expect(publicMethodsOf(ImClient), contains('sendText'));
    });
  });
}
