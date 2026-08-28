import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// `evt.call` and `evt.desk` were absent from every client SDK while the server was already
/// pushing them (AUDIT-2026-08-21 §6.1): the frame arrived, no constant matched it, and the app
/// dropped it without a word.
///
/// The exhaustive cross-SDK check is `PushTargetParityTests` in `tests/IM.Tests.Unit` — it is the
/// only one that can read the server's own declaration. Dart cannot enumerate static consts
/// without mirrors, so an exhaustive list here would just be a second hand-written copy; this pins
/// the two that actually drifted.
void main() {
  test('call and desk are named constants, not bare strings', () {
    expect(ImPushTarget.call, 'evt.call');
    expect(ImPushTarget.desk, 'evt.desk');
  });
}
