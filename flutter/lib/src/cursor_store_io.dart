import 'dart:convert';
import 'dart:io';

import 'cursor_store.dart';

/// Filesystem-backed [ImCursorStore]. Selected by the conditional import in `cursor_store.dart`
/// on every target except the web.
ImCursorStore createFileCursorStore(String path) => FileCursorStore(path);

/// A single JSON file holding one [ImCursorSnapshot].
///
/// Deliberately small and dependency-free. The interesting decisions are the two failure modes:
///
/// - **A missing file is an empty snapshot; an unreadable one is an error.** Returning "empty" for
///   a corrupt file is exactly the confusion §5.8 exists to forbid — a fresh install and a broken
///   store look the same to the adoption branch, and adopting on a broken store destroys history
///   that is sitting intact in the app's own database.
/// - **Writes are atomic.** The snapshot goes to a sibling `.tmp` and is renamed over the target,
///   because a process killed halfway through a rewrite would otherwise leave a truncated file —
///   which by the rule above is a hard error on the next launch, for a write that had nothing
///   wrong with it.
///
/// 文件缺失 = 空快照；文件读不了 = 报错，绝不当成空快照。写入先写 .tmp 再原子重命名。
class FileCursorStore implements ImCursorStore {
  FileCursorStore(this.path) : _file = File(path);

  final String path;
  final File _file;

  /// Serialises writes. Two saves racing on the same temp file is a corrupt snapshot, and the SDK
  /// does issue overlapping saves — an adoption flush can land while a debounced commit is in the
  /// air.
  Future<void> _writing = Future<void>.value();

  @override
  Future<ImCursorSnapshot> load() async {
    if (!await _file.exists()) return ImCursorSnapshot.empty;

    final String text = await _file.readAsString();
    if (text.trim().isEmpty) return ImCursorSnapshot.empty;

    final Object? decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('cursor store at $path is not a JSON object');
    }

    return ImCursorSnapshot.fromJson(decoded);
  }

  @override
  Future<void> save(ImCursorSnapshot snapshot) {
    final String payload = jsonEncode(snapshot.toJson());

    _writing = _writing.then((_) async {
      final Directory parent = _file.parent;
      if (!await parent.exists()) await parent.create(recursive: true);

      final File temporary = File('$path.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(path);
    });

    return _writing;
  }
}
