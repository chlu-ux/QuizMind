import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/ulid.dart';
import '../../data/database.dart';
import '../../data/exam_store.dart';
import '../../data/models.dart';
import '../../data/progress.dart';
import '../../data/repository.dart';
import '../../data/tags.dart';
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

/// How the paper is put together:
///  - random: any questions
///  - weak: questions you got wrong last time first, then ones never tried, then the rest
///  - balanced: easy / medium / hard in a 4 : 4 : 2 mix
enum PaperStrategy {
  random('随机', '从题库随机抽题'),
  weak('查漏补缺', '优先抽上次做错的和没做过的题'),
  balanced('难度均衡', '简单、中等、困难按 4 : 4 : 2 搭配');

  const PaperStrategy(this.label, this.hint);

  final String label;
  final String hint;
}

/// Knowledge points a paper can be limited to, biggest first, with how many questions carry each.
List<({String label, int count})> paperTags(List<Question> qs) {
  final label = tagLabeler([for (final q in qs) ...q.tags], merge: true);
  final counts = <String, int>{};
  for (final q in qs) {
    for (final t in {...q.tags.map(label)}) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
  }
  final out = [for (final e in counts.entries) (label: e.key, count: e.value)];
  out.sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : a.label.compareTo(b.label));
  return out;
}

/// The questions a paper may draw from: those carrying one of [tags], or all when none are given.
List<Question> paperPool(List<Question> qs, [Iterable<String> tags = const []]) {
  final wanted = tags.toSet();
  if (wanted.isEmpty) return qs;
  final label = tagLabeler([for (final q in qs) ...q.tags], merge: true);
  return [
    for (final q in qs)
      if (q.tags.any((t) => wanted.contains(label(t)))) q,
  ];
}

int _bucketOf(Question q) => q.difficulty <= 2 ? 0 : (q.difficulty == 3 ? 1 : 2);
const _balance = [0.4, 0.4, 0.2];

/// Picks [count] questions for a paper. The result is in random order.
List<Question> drawPaper(
  List<Question> qs,
  int count, {
  PaperStrategy strategy = PaperStrategy.random,
  List<String> tags = const [],
  Map<String, QuestionHistory> history = const {},
  Set<String> wrongIds = const {},
  Random? rng,
}) {
  final pool = paperPool(qs, tags);
  final n = count.clamp(0, pool.length);
  List<Question> shuffled(Iterable<Question> items) => [...items]..shuffle(rng);
  List<Question> picked;

  switch (strategy) {
    case PaperStrategy.weak:
      int tier(Question q) {
        final h = history[q.id];
        if (wrongIds.contains(q.id) || (h != null && !h.lastCorrect)) return 0;
        return h == null ? 1 : 2;
      }

      picked = [for (var t = 0; t < 3; t++) ...shuffled(pool.where((q) => tier(q) == t))].take(n).toList();
    case PaperStrategy.balanced:
      final buckets = [for (var b = 0; b < 3; b++) shuffled(pool.where((q) => _bucketOf(q) == b))];
      picked = [];
      for (var b = 0; b < 3; b++) {
        final take = (n * _balance[b]).round().clamp(0, buckets[b].length);
        picked.addAll(buckets[b].take(take));
        buckets[b] = buckets[b].sublist(take);
      }
      // A bucket that ran dry (or rounding) is made up from whatever is left.
      if (picked.length > n) picked = picked.sublist(0, n);
      if (picked.length < n) picked.addAll(shuffled(buckets.expand((x) => x)).take(n - picked.length));
    case PaperStrategy.random:
      picked = shuffled(pool).take(n).toList();
  }
  return shuffled(picked);
}

/// One question of a graded paper.
class ExamEntry {
  const ExamEntry({required this.id, required this.question, required this.selected, required this.correct});

  final String id;

  /// Null when the question has since been withdrawn.
  final Question? question;

  /// Original option indexes picked; empty when left blank.
  final List<int> selected;
  final bool correct;
}

class ExamResult {
  const ExamResult({required this.record, required this.entries});

  final ExamRecord record;
  final List<ExamEntry> entries;

  /// Wrong or blank questions that still exist, to practise again.
  List<Question> get missed => [
    for (final e in entries)
      if (!e.correct && e.question != null) e.question!,
  ];
}

/// Pairs a stored exam with the questions that are still around.
List<ExamEntry> examEntries(ExamRecord record, Map<String, Question> questions) => [
  for (final it in record.items)
    ExamEntry(id: it.questionId, question: questions[it.questionId], selected: it.selected, correct: it.correct),
];

/// A mock exam: a fixed list of questions answered with no feedback, answers
/// changeable until the whole paper is handed in (by the learner, or when the
/// time runs out). Only then is anything graded and written to the attempt log,
/// so a half-finished exam leaves no trace in the statistics.
///
/// Progress is kept on the device after every change ([ExamDraft]), so a killed
/// app can [restore] it. The countdown runs from the start time, so being away
/// does not stop the clock.
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
    this.limitSec,
    DateTime Function()? clock,
    int? seed,
    DateTime? startedAt,
    int index = 0,
    List<List<int>>? chosen,
    List<int>? spent,
    List<bool>? marks,
  }) : assert(questions.isNotEmpty),
       _clock = clock ?? DateTime.now,
       seed = seed ?? Random().nextInt(1 << 30),
       _chosen = chosen ?? List.generate(questions.length, (_) => const <int>[]),
       _spent = spent ?? List.filled(questions.length, 0),
       _marks = marks ?? List.filled(questions.length, false),
       // ignore: prefer_initializing_formals
       _index = index {
    _enteredAt = _clock();
    _startedAt = startedAt ?? _enteredAt;
  }

  /// Picks an exam up from its saved [draft]. [available] holds the questions that
  /// still exist; withdrawn ones are dropped from the paper. Null when none are left.
  static ExamSession? restore(
    ExamDraft draft,
    List<Question> available,
    Repository repo, {
    DateTime Function()? clock,
  }) {
    final byId = {for (final q in available) q.id: q};
    final keep = [
      for (var i = 0; i < draft.ids.length; i++)
        if (byId.containsKey(draft.ids[i])) i,
    ];
    if (keep.isEmpty) return null;
    // Back to the question that was open, or the next one still around if it was withdrawn.
    final at = keep.indexWhere((i) => i >= draft.index);
    final marked = draft.marked.toSet();
    return ExamSession(
      bankId: draft.bankId,
      title: draft.title,
      questions: [for (final i in keep) byId[draft.ids[i]]!],
      repo: repo,
      limitSec: draft.limitSec,
      clock: clock,
      seed: draft.seed,
      startedAt: DateTime.fromMillisecondsSinceEpoch(draft.startedAt),
      index: at >= 0 ? at : keep.length - 1,
      chosen: [for (final i in keep) [...?draft.answers[draft.ids[i]]]],
      spent: [for (final i in keep) draft.spent[draft.ids[i]] ?? 0],
      marks: [for (final i in keep) marked.contains(draft.ids[i])],
    );
  }

  final String bankId;
  final String title;
  final List<Question> questions;
  final Repository repo;

  /// Time allowed in seconds, null for none.
  final int? limitSec;
  final int seed;
  final DateTime Function() _clock;

  late final DateTime _startedAt;
  late DateTime _enteredAt;
  final List<List<int>> _chosen;
  final List<int> _spent;
  final List<bool> _marks;
  final Map<int, List<int>> _orders = {};
  int _index;
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
  int get markedCount => _marks.where((m) => m).length;
  bool isMarked(int i) => _marks[i];

  /// Whether anything can still change: false once handing in has begun.
  bool get _open => !submitted && !_busy;

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
    if (!_open || option < 0 || option >= current.options.length) return;
    _chosen[_index] = [option];
    _changed();
  }

  void selectAt(int position) {
    final order = _orderOf(_index);
    if (position >= 0 && position < order.length) select(order[position]);
  }

  /// Flags the current question "check again", or clears the flag.
  void toggleMark() {
    if (!_open) return;
    _marks[_index] = !_marks[_index];
    _changed();
  }

  /// Moves to question [i], crediting the time spent on the one being left.
  void go(int i) {
    if (!_open || i < 0 || i >= length || i == _index) return;
    _leave();
    _index = i;
    _changed();
  }

  void next() => go(_index + 1);
  void previous() => go(_index - 1);

  void _leave() {
    final now = _clock();
    _spent[_index] += max(now.difference(_enteredAt).inMilliseconds, 0);
    _enteredAt = now;
  }

  void _changed() {
    save();
    notifyListeners();
  }

  /// What is needed to pick this exam up again later.
  ExamDraft snapshot() {
    final now = _clock();
    return ExamDraft(
      bankId: bankId,
      title: title,
      ids: [for (final q in questions) q.id],
      seed: seed,
      startedAt: _startedAt.millisecondsSinceEpoch,
      limitSec: limitSec,
      index: _index,
      answers: {
        for (var i = 0; i < length; i++)
          if (_chosen[i].isNotEmpty) questions[i].id: [..._chosen[i]],
      },
      spent: {
        for (var i = 0; i < length; i++)
          questions[i].id: _spent[i] + (i == _index ? max(now.difference(_enteredAt).inMilliseconds, 0) : 0),
      },
      marked: [
        for (var i = 0; i < length; i++)
          if (_marks[i]) questions[i].id,
      ],
      savedAt: now.millisecondsSinceEpoch,
    );
  }

  /// Stores progress on this device. Fire and forget: a failure only costs the ability to resume.
  void save() {
    if (!_open) return;
    unawaited(repo.saveExamDraft(snapshot()).catchError((Object _) {}));
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
      final entries = <ExamEntry>[
        for (var i = 0; i < length; i++)
          ExamEntry(
            id: questions[i].id,
            question: questions[i],
            selected: [..._chosen[i]],
            correct: _chosen[i].isNotEmpty && isCorrect(_chosen[i], questions[i].answer),
          ),
      ];
      final correct = entries.where((e) => e.correct).length;
      final percent = (correct * 100 / length).round();
      final wall = max(finishedAt.difference(_startedAt).inMilliseconds, 0);
      // A timed exam runs on the wall clock; an untimed one counts only time spent on questions.
      final used = limitSec == null ? _spent.fold<int>(0, (a, b) => a + b) : min(wall, limitSec! * 1000);
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
        usedMs: used,
        deviceId: repo.deviceId,
        items: [for (final e in entries) ExamItemRecord(questionId: e.id, selected: e.selected, correct: e.correct)],
      );
      await repo.submitExam(record, [
        for (var i = 0; i < length; i++)
          if (entries[i].selected.isNotEmpty)
            ExamAnswer(question: questions[i], selected: entries[i].selected, durationMs: _spent[i]),
      ]);
      return _result = ExamResult(record: record, entries: entries);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
