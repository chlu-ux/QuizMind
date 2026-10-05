import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/features/quiz/active_timer.dart';

void main() {
  var t = DateTime(2026, 10, 3);
  void advance(int ms) => t = t.add(Duration(milliseconds: ms));
  setUp(() => t = DateTime(2026, 10, 3));

  test('hands out the time since the last lap', () {
    final w = ActiveTimer(clock: () => t);
    advance(5000);
    expect(w.lap(), 5000);
    advance(2000);
    expect(w.lap(), 2000);
    expect(w.lap(), 0);
  });

  test('does not count the time the app was in the background', () {
    final w = ActiveTimer(clock: () => t);
    advance(3000);
    w.setVisible(false);
    advance(60000);
    expect(w.lap(), 3000);
    advance(60000);
    expect(w.lap(), 0, reason: 'still in the background');
    w.setVisible(true);
    advance(1500);
    expect(w.lap(), 1500);
  });

  test('starts paused for an app opened in the background', () {
    final w = ActiveTimer(clock: () => t, visible: false);
    advance(10000);
    expect(w.lap(), 0);
    w.setVisible(true);
    advance(400);
    expect(w.lap(), 400);
  });
}
