import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/ulid.dart';
import '../../data/database.dart';
import '../../data/exam_store.dart';
import '../../data/progress.dart';
import '../../data/repository.dart';
import '../quiz/quiz_session.dart';

/// Score needed to pass a mock exam, in percent.
const passPercent = 60;

/// Question counts offered for a bank with [available] questions; the last choice is always "all of them".
List<int> examCountChoices(int available) => [
  ...[10, 20, 50, 100].where((n) => n < available),
  available,
];

/// [count] distinct questions picked at random.
List<Question> drawExam(List<Question> qs, int count, {Random? rng}) {
  final pool = [...qs]..shuffle(rng);
  return pool.take(count.clamp(0, pool.length)).toList();
}

class ExamItem {
  const ExamItem({required this.question, required this.selected, required this.correct});

  final Question question;

  /// Original option indexes picked; empty when left blank.
  final List<int> selected;
  final bool correct;
}

class ExamResult {
  const ExamResult({required this.record, required this.items});

  final ExamRecord record;
  final List<ExamItem> items;

  List<ExamItem> get missed => [
    for (final it in items)
      if (!it.correct) it,
  ];
}

/// A mock exam: a fixed list of questions answered with no feedback, answers
/// changeable until the whole paper is handed in (by the learner, or when the
/// time runs out). Only then is anything graded and written to the attempt log,
/// so a half-finished exam leaves no trace.
///
/// As in [QuizSession], everything stored or graded uses original option
/// indexes; only [displayOptions], [selectAt] and [labelOf] know about the
/// shuffled positions.
class ExamSession extends ChangeNotifier {
  ExamSession({
    required this.bankId,
    required this.title,
    required this.questions,
    required this.repo,
    required this.store,
    this.limitSec,
    DateTime Function()? clock,
    int? seed,
  }) : assert(questions.isNotEmpty),
       _clock = clock ?? DateTime.now,
       seed = seed ?? Random().nextInt(1 << 30),
       _chosen = List.generate(questions.length, (_) => const <int>[]),
       _spent = List.filled(questions.length, 0) {
    _startedAt = _enteredAt = _clock();
  }

  final String bankId;
  final String title;
  final List<Question> questions;
  final Repository repo;
  final ExamStore store;

  /// Time allowed in seconds, null for none.
  final int? limitSec;
  final int seed;
  final DateTime Function() _clock;

  late final DateTime _startedAt;
  late DateTime _enteredAt;
  final List<List<int>> _chosen;
  final List<int> _spent;
  final Map<int, List<int>> _orders = {};
  int _index = 0;
  bool _busy = false;
  Future<ExamResult>? _inFlight;
  ExamResult? _result;

  int get index => _index;
  int get length => questions.length;
  Question get current => questions[_index];
  List<int> get selected => _chosen[_index];
  bool get busy => _busy;
  ExamResult? get result => _result;
  bool get submitted => _result != null;
  int get answeredCount => _chosen.where((c) => c.isNotEmpty).length;
  bool isAnswered(int i) => _chosen[i].isNotEmpty;

  /// Seconds left at [at] (default: now), never below 0; null for an untimed exam.
  int? remainingSec([DateTime? at]) {
    final limit = limitSec;
    if (limit == null) return null;
    final elapsedMs = (at ?? _clock()).difference(_startedAt).inMilliseconds;
    return max(0, (limit - elapsedMs / 1000).ceil());
  }

  List<int> _orderOf(int position) => _orders.putIfAbsent(position, () => optionOrder(questions[position], seed));

  /// The current question's options in the order they are shown; `original` is
  /// the index to select, grade and store.
  List<({String text, int original})> get displayOptions {
    final opts = current.options;
    return [for (final o in _orderOf(_index)) (text: opts[o], original: o)];
  }

  String labelOf(int original) {
    final position = _orderOf(_index).indexOf(original);
    return current.type == 'judge' ? '${position + 1}' : String.fromCharCode(65 + position);
  }

  void select(int option) {
    if (submitted || option < 0 || option >= current.options.length) return;
    _chosen[_index] = [option];
    notifyListeners();
  }

  void selectAt(int position) {
    final order = _orderOf(_index);
    if (position >= 0 && position < order.length) select(order[position]);
  }

  /// Moves to question [i], crediting the time spent on the one being left.
  void go(int i) {
    if (submitted || i < 0 || i >= length || i == _index) return;
    _leave();
    _index = i;
    notifyListeners();
  }

  void next() => go(_index + 1);
  void previous() => go(_index - 1);

  void _leave() {
    final now = _clock();
    _spent[_index] += max(now.difference(_enteredAt).inMilliseconds, 0);
    _enteredAt = now;
  }

  /// Grades the paper and records every answered question. Calling it again,
  /// e.g. when the timeout races the button, returns the same result.
  Future<ExamResult> submit() {
    if (_result case final done?) return Future.value(done);
    return _inFlight ??= _grade().whenComplete(() => _inFlight = null);
  }

  Future<ExamResult> _grade() async {
    _busy = true;
    notifyListeners();
    try {
      _leave();
      final finishedAt = _clock();
      final items = <ExamItem>[];
      for (var i = 0; i < length; i++) {
        final question = questions[i];
        final selected = [..._chosen[i]];
        if (selected.isEmpty) {
          items.add(ExamItem(question: question, selected: selected, correct: false));
          continue;
        }
        final outcome = await repo.recordAnswer(question: question, selected: selected, durationMs: _spent[i]);
        items.add(ExamItem(question: question, selected: selected, correct: outcome.correct));
      }
      final correct = items.where((it) => it.correct).length;
      final percent = (correct * 100 / length).round();
      final record = ExamRecord(
        id: newUlid(now: finishedAt),
        bankId: bankId,
        title: title,
        finishedAt: finishedAt.millisecondsSinceEpoch,
        total: length,
        correct: correct,
        answered: answeredCount,
        percent: percent,
        passed: percent >= passPercent,
        limitSec: limitSec,
        usedMs: max(finishedAt.difference(_startedAt).inMilliseconds, 0),
      );
      await store.add(record);
      return _result = ExamResult(record: record, items: items);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
