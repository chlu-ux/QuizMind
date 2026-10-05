import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/database.dart';
import '../../data/models.dart';
import '../../data/progress.dart';
import '../../data/repository.dart';
import 'active_timer.dart';

enum QuizOrder { random, sequential }

/// Orders a question list for a session. Pure so it can be tested.
List<Question> orderQuestions(List<Question> qs, QuizOrder order, {Random? rng}) {
  final out = [...qs];
  if (order == QuizOrder.random) out.shuffle(rng);
  return out;
}

/// Order in which a question's options are shown: entry `d` is the original
/// index of the option displayed at position `d`. Single-choice options are
/// shuffled; judge options keep their fixed 正确 / 错误 order. Deterministic in
/// [seed] and the question id, so a resumed session shows the same layout.
List<int> optionOrder(Question q, int seed) {
  final order = List.generate(q.options.length, (i) => i);
  if (q.type != 'single') return order;
  return order..shuffle(Random(seed ^ _stableHash(q.id)));
}

/// FNV-1a. `String.hashCode` is not promised to be stable between runs.
int _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// An answer given in an earlier run of the same session, put back on resume.
class RestoredAnswer {
  const RestoredAnswer({required this.selected, required this.outcome});

  final List<int> selected;
  final AnswerOutcome outcome;
}

/// One run through a fixed list of questions. Keeps what was chosen and the
/// outcome per position so the learner can step back and review.
///
/// Options are shuffled once per question for the whole session, so stepping
/// back shows the same layout. Everything the session stores or grades
/// (`selected`, attempts) uses the question's original option indexes; only
/// [displayOptions], [selectAt] and [labelOf] know about the shuffled positions.
class QuizSession extends ChangeNotifier {
  QuizSession({
    required this.title,
    required this.questions,
    required this.repo,
    int startAt = 0,
    int? seed,
    this.shuffleOptions = true,
    Map<String, RestoredAnswer> restored = const {},
    DateTime Function()? clock,
  })  : assert(questions.isNotEmpty),
        seed = seed ?? Random().nextInt(1 << 30),
        _index = startAt.clamp(0, questions.length - 1),
        _selected = List.generate(questions.length, (_) => const <int>[]),
        _outcomes = List.filled(questions.length, null),
        _waited = List.filled(questions.length, 0),
        _timer = ActiveTimer(clock: clock) {
    for (var i = 0; i < questions.length; i++) {
      final r = restored[questions[i].id];
      if (r == null) continue;
      _selected[i] = r.selected;
      _outcomes[i] = r.outcome;
    }
  }

  final String title;
  final List<Question> questions;
  final Repository repo;
  final int seed;
  final bool shuffleOptions;

  int _index;
  bool _finished = false;
  bool _busy = false;
  final List<List<int>> _selected;
  final List<AnswerOutcome?> _outcomes;

  /// Counts the time on the current question; a backgrounded app does not count.
  final ActiveTimer _timer;

  /// Time spent on each question before it was answered, over earlier visits.
  final List<int> _waited;

  int get index => _index;
  int get length => questions.length;
  Question get current => questions[_index];
  bool get finished => _finished;
  bool get busy => _busy;
  bool get isLast => _index == questions.length - 1;
  bool get canGoBack => _index > 0;

  List<int> get selected => _selected[_index];
  AnswerOutcome? get outcome => _outcomes[_index];
  bool get submitted => outcome != null;
  int get answeredCount => _outcomes.where((o) => o != null).length;
  int get correctCount => _outcomes.where((o) => o?.correct ?? false).length;

  /// Questions answered wrongly in this session, in order.
  List<Question> get missed => [
        for (var i = 0; i < questions.length; i++)
          if (_outcomes[i] != null && !_outcomes[i]!.correct) questions[i],
      ];

  /// The current question's options in the order they are shown; `original` is
  /// the index to select, grade and store.
  List<({String text, int original})> get displayOptions {
    final opts = current.options;
    return [for (final o in _orderOf(_index)) (text: opts[o], original: o)];
  }

  final Map<int, List<int>> _orders = {};

  List<int> _orderOf(int position) => _orders.putIfAbsent(
        position,
        () => shuffleOptions
            ? optionOrder(questions[position], seed)
            : List.generate(questions[position].options.length, (i) => i),
      );

  /// Selects by shown position (keyboard shortcuts).
  void selectAt(int position) {
    final order = _orderOf(_index);
    if (position >= 0 && position < order.length) select(order[position]);
  }

  /// Letter or number shown next to an option, given its original index.
  String labelOf(int original) {
    final position = _orderOf(_index).indexOf(original);
    return current.type == 'judge' ? '${position + 1}' : String.fromCharCode(65 + position);
  }

  /// What the learner chose and whether it was right, by question id, for saving.
  Map<String, ({List<int> selected, bool correct})> get answerSnapshot => {
        for (var i = 0; i < questions.length; i++)
          if (_outcomes[i] != null) questions[i].id: (selected: _selected[i], correct: _outcomes[i]!.correct),
      };

  void select(int option) {
    if (submitted || option < 0 || option >= current.options.length) return;
    _selected[_index] = [option];
    notifyListeners();
  }

  /// Grades the current selection and stores it. No-op without a selection.
  Future<void> submit() async {
    if (submitted || selected.isEmpty || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      final at = _index;
      final elapsed = _waited[at] + _timer.lap();
      _waited[at] = 0;
      _outcomes[at] = await repo.recordAnswer(question: questions[at], selected: _selected[at], durationMs: elapsed);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Books the time since the last call to the question on screen: an answered one
  /// gains reading time (explanation, AI), an unanswered one carries it into its
  /// answer time. Called whenever the learner leaves a question or the app, so
  /// little is lost if the app is closed.
  Future<void> flush() {
    final ms = _timer.lap();
    final at = _index;
    final attemptId = _outcomes[at]?.attemptId;
    if (_outcomes[at] == null) _waited[at] += ms;
    return attemptId == null ? Future.value() : repo.addReviewTime(attemptId, ms);
  }

  /// The app went to the background or came back; background time is not counted.
  void setVisible(bool visible) => _timer.setVisible(visible);

  /// Booking reading time is best effort: a failed write must not disturb moving on.
  void _bookInBackground() => unawaited(flush().catchError((Object _) {}));

  void next() {
    _bookInBackground();
    if (isLast) {
      if (answeredCount > 0) _finished = true;
    } else {
      _index++;
    }
    notifyListeners();
  }

  void previous() {
    if (!canGoBack) return;
    _bookInBackground();
    _index--;
    notifyListeners();
  }

  /// Moves to the question at [position] (0-based, clamped), e.g. to pick up where an earlier round stopped.
  void jumpTo(int position) {
    final target = position.clamp(0, questions.length - 1);
    if (target == _index) return;
    _bookInBackground();
    _index = target;
    notifyListeners();
  }

  /// Hides the current question after a report and moves on.
  Future<void> flagCurrent({FlagReason reason = FlagReason.other}) async {
    await repo.flagQuestion(current.id, reason: reason);
  }
}
