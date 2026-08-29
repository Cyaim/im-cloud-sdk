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

    /// 上面那张表是人工维护的，而**没有这一条，它就是一份会静默失去覆盖的清单**：
    /// 新增到 [ImClient] 上却忘了加进表里的命名空间根本不会被检查——套件照绿，
    /// 而一整个前缀无人过问，这与「没有这道护栏」在结果上完全一样。
    /// 2026-08-29 的 `diag` 正是如此：五端里四张人工表全都漏了它，只有 Swift 那条同类断言发现了。
    ///
    /// Without this, the table above is a list that quietly stops covering things: a namespace
    /// added to [ImClient] and not added there is simply not checked, and the suite stays green
    /// while a whole prefix goes unexamined — which is indistinguishable from not having the
    /// guardrail at all.
    ///
    /// 这一条本来记在 `CONTRACT §6A` 的缺口里，理由写的是「Dart 上没有 dart:mirrors」。
    /// **那个理由是错的**：mirrors 在 Flutter 的 AOT 编译器下不可用，而本包的测试套件跑在
    /// 普通 Dart VM 上（`dart test`），这个文件顶上那三个 test-only import 里就有一个是它，
    /// 上面两条断言一直在用。缺的从来不是能力，是这条断言本身。
    /// The gap note said "Dart has no dart:mirrors". It is wrong: mirrors are unavailable under
    /// Flutter's AOT compiler, not under the plain Dart VM this suite runs on — the two assertions
    /// above have been using them all along.
    test('the table covers every namespace the client exposes', () {
      final List<String> missing = <String>[];

      reflectClass(ImClient).declarations.forEach((Symbol _, DeclarationMirror declaration) {
        if (declaration is! VariableMirror) return;
        if (declaration.isPrivate || declaration.isStatic) return;

        final TypeMirror type = declaration.type;
        final String name = MirrorSystem.getName(type.simpleName);

        // 按名字筛而不是按「不在表里就算」：ImClient 上还有 ImOptions、ImConnection、ImLog
        // 这些不是命名空间的字段，把它们也要求进表里会逼着表去列一堆不是端点前缀的东西。
        if (!name.startsWith('Im') || !name.endsWith('Api')) return;
        if (namespaces.containsKey(type.reflectedType)) return;

        missing.add(name);
      });

      missing.sort();

      expect(
        missing,
        isEmpty,
        reason: 'these namespaces are exposed on ImClient and absent from this test\'s table, so '
            'nothing here checks them',
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
