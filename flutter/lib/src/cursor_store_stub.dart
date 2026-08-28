import 'cursor_store.dart';

/// Web build of [ImCursorStore.file]. There is no filesystem in a browser, so this fails loudly at
/// the call rather than quietly persisting nothing — the exact failure the cursor store exists to
/// prevent.
///
/// A web deployment either supplies its own [ImCursorStore] over `localStorage` / IndexedDB, or
/// passes `ImCursorStore.inMemory()` and accepts that every tab re-downloads and may see a
/// duplicate delivery.
ImCursorStore createFileCursorStore(String path) => throw UnsupportedError(
      'ImCursorStore.file is not available on the web: there is no filesystem. Implement '
      'ImCursorStore over window.localStorage, or pass ImCursorStore.inMemory() and accept a '
      're-download per tab. See sdk/CONTRACT.md §5.3.',
    );
