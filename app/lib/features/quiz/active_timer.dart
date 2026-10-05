/// Counts time only while the app is in the foreground: a phone with the screen off
/// or an app in the background is not studying. [lap] hands out what has been counted
/// since the previous lap, so one timer can time a series of consecutive stretches.
class ActiveTimer {
  ActiveTimer({DateTime Function()? clock, bool visible = true})
      : _clock = clock ?? DateTime.now,
        _shown = visible {
    _since = visible ? _clock() : null;
  }

  final DateTime Function() _clock;
  bool _shown;
  int _counted = 0;
  DateTime? _since;

  /// Tells the timer the app went to the background or came back.
  void setVisible(bool visible) {
    if (visible == _shown) return;
    _shown = visible;
    if (visible) {
      _since = _clock();
    } else if (_since != null) {
      _counted += _elapsed(_since!, _clock());
      _since = null;
    }
  }

  /// Milliseconds counted since the last lap, which a new lap then starts from.
  int lap() {
    var ms = _counted;
    final since = _since;
    if (since != null) {
      final t = _clock();
      ms += _elapsed(since, t);
      _since = t;
    }
    _counted = 0;
    return ms;
  }

  static int _elapsed(DateTime from, DateTime to) {
    final ms = to.difference(from).inMilliseconds;
    return ms < 0 ? 0 : ms;
  }
}
