import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/database.dart';
import '../../data/progress.dart';
import '../../data/repository.dart';

enum QuizOrder { random, sequential }

/// Orders a question list for a session. Pure so it can be tested.
List<Question> orderQuestions(List<Question> qs, QuizOrder order, {Random? rng}) {
  final out = [...qs];
  if (order == QuizOrder.random) out.shuffle(rng);
  return out;
}

/// One run through a fixed list of questions. Keeps what was chosen and the
/// outcome per position so the learner can step back and review.
class QuizSession extends ChangeNotifier {
  QuizSession({required this.title, required this.questions, required this.repo, int startAt = 0})
      : assert(questions.isNotEmpty),
        _index = startAt.clamp(0, questions.length - 1),
        _selected = List.generate(questions.length, (_) => const <int>[]),
        _outcomes = List.filled(questions.length, null) {
    _startedAt = DateTime.now();
  }

  final String title;
  final List<Question> questions;
  final Repository repo;

  int _index;
  bool _finished = false;
  bool _busy = false;
  late DateTime _startedAt;
  final List<List<int>> _selected;
  final List<AnswerOutcome?> _outcomes;

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
      final elapsed = DateTime.now().difference(_startedAt).inMilliseconds;
      _outcomes[_index] = await repo.recordAnswer(question: current, selected: selected, durationMs: max(elapsed, 0));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void next() {
    if (isLast) {
      if (answeredCount > 0) _finished = true;
    } else {
      _index++;
      _startedAt = DateTime.now();
    }
    notifyListeners();
  }

  void previous() {
    if (!canGoBack) return;
    _index--;
    notifyListeners();
  }

  /// Hides the current question after a report and moves on.
  Future<void> flagCurrent() async {
    await repo.flagQuestion(current.id);
  }
}
