import 'package:cyaim_im/cyaim_im.dart';
import 'package:test/test.dart';

/// `evt.call` and `evt.desk` were absent from every client SDK while the server was already
/// pushing them (AUDIT-2026-08-21 §6.1): the frame arrived, no constant matched it, and the app
/// dropped it without a word.
///
/// `evt.call` no longer exists on either side — calling was withdrawn from every product surface
/// on 2026-09-14 — so `evt.desk` is the only half left to pin.
///
/// The exhaustive cross-SDK check is `PushTargetParityTests` in `tests/IM.Tests.Unit` — it is the
/// only one that can read the server's own declaration. Dart cannot enumerate static consts
/// without mirrors, so an exhaustive list here would just be a second hand-written copy; this pins
/// the one that drifted and stayed.
void main() {
  test('desk is a named constant, not a bare string', () {
    expect(ImPushTarget.desk, 'evt.desk');
  });
}
