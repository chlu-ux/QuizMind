import '../../data/database.dart';
import 'modules.dart';

/// A chapter of the study text: one imported document, with its sections in reading order.
class Chapter {
  const Chapter(this.id, this.title, this.lessons);

  final String id;
  final String title;
  final List<Lesson> lessons;
}

/// The section's own title: the last part of its heading path ("考点精讲 > 2.1 操作系统概述" gives "2.1 操作系统概述").
String lessonTitle(Lesson l) {
  final parts = l.headingPath.split(' > ');
  final last = parts.last.trim();
  return last.isEmpty ? l.headingPath : last;
}

/// [lessons] in reading order: chapters as their documents were added, sections in document order.
List<Lesson> readingOrder(Iterable<Lesson> lessons) => lessons.toList()
  ..sort((a, b) {
    final byDate = a.documentOrder.compareTo(b.documentOrder);
    if (byDate != 0) return byDate;
    final byDoc = a.documentId.compareTo(b.documentId);
    return byDoc != 0 ? byDoc : a.seq.compareTo(b.seq);
  });

/// The sections grouped into chapters, chapters in the order the documents were added. Chapter names drop
/// what the bank's document titles have in common, like the module names.
List<Chapter> groupChapters(List<Lesson> lessons) {
  final ordered = readingOrder(lessons);
  final byDoc = <String, List<Lesson>>{};
  for (final l in ordered) {
    byDoc.putIfAbsent(l.documentId, () => []).add(l);
  }
  final titles = [for (final list in byDoc.values) list.first.documentTitle];
  return [
    for (final list in byDoc.values) Chapter(list.first.documentId, moduleLabel(list.first.documentTitle, titles), list),
  ];
}

/// How far along a section is. Each state includes the ones before it.
enum LessonState {
  unread('未学'),
  read('已读'),
  practiced('练习中'),
  mastered('已掌握');

  const LessonState(this.label);

  final String label;
}

class LessonProgress {
  const LessonProgress({
    required this.state,
    required this.read,
    required this.total,
    required this.answered,
    required this.correct,
  });

  final LessonState state;

  /// Marked as read by the learner, whatever else was done with the section.
  final bool read;

  /// Questions generated from the section.
  final int total;

  /// Of those, how many were answered at least once.
  final int answered;

  /// Of the answered ones, how many were right the last time.
  final int correct;

  /// Share of the answered questions that were right the last time, 0-100; null if none was answered.
  int? get accuracy => answered == 0 ? null : (correct * 100 / answered).round();
}

/// A section counts as mastered once this many of its questions (all of them, if it has fewer) were answered...
const masterMinAnswered = 5;

/// ...and at least this share (percent) of those were right the last time.
const masterMinAccuracy = 80;

/// Progress of every section of [lessons]. Practice is judged by the latest attempt at each question,
/// like the "最近一次答对" figure on the bank page, so a question learned since stops counting against you.
Map<String, LessonProgress> lessonProgress(
  Iterable<Lesson> lessons,
  Iterable<Question> questions,
  Iterable<Attempt> attempts,
  Set<String> readIds,
) {
  final last = <String, bool>{};
  for (final a in attempts.toList()..sort((x, y) => x.answeredAt.compareTo(y.answeredAt))) {
    last[a.questionId] = a.isCorrect;
  }
  final byLesson = <String, List<Question>>{};
  for (final q in questions) {
    if (q.chunkId.isEmpty) continue;
    byLesson.putIfAbsent(q.chunkId, () => []).add(q);
  }
  final out = <String, LessonProgress>{};
  for (final l in lessons) {
    final qs = byLesson[l.id] ?? const <Question>[];
    var answered = 0, correct = 0;
    for (final q in qs) {
      final r = last[q.id];
      if (r == null) continue;
      answered++;
      if (r) correct++;
    }
    final read = readIds.contains(l.id);
    var state = read ? LessonState.read : LessonState.unread;
    if (answered > 0) state = LessonState.practiced;
    final need = qs.length < masterMinAnswered ? qs.length : masterMinAnswered;
    if (qs.isNotEmpty && answered >= need && correct * 100 >= masterMinAccuracy * answered) {
      state = LessonState.mastered;
    }
    out[l.id] = LessonProgress(state: state, read: read, total: qs.length, answered: answered, correct: correct);
  }
  return out;
}

/// The questions generated from a section, in the order of [questions].
List<Question> lessonQuestions(String lessonId, Iterable<Question> questions) =>
    [for (final q in questions) if (q.chunkId == lessonId) q];

/// Where "继续学习" goes: the first section not read yet (practising it does not count as reading it),
/// else the first one with questions not mastered yet; null when everything is read and mastered.
/// [lessons] must be in reading order.
Lesson? nextToStudy(List<Lesson> lessons, Map<String, LessonProgress> progress) {
  for (final l in lessons) {
    if (!(progress[l.id]?.read ?? false)) return l;
  }
  for (final l in lessons) {
    final p = progress[l.id];
    // A section without questions has nothing left to master.
    if (p != null && p.total > 0 && p.state != LessonState.mastered) return l;
  }
  return null;
}

/// Sentences of a Chinese paragraph, each keeping its closing 。！？ and any closing quote or bracket.
List<String> splitSentences(String paragraph) {
  var text = '';
  for (final line in paragraph.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
    // Lines of a hard-wrapped paragraph join with a space only between two Latin words.
    text += text.isNotEmpty && _latinEnd.hasMatch(text) && _latinStart.hasMatch(line) ? ' $line' : line;
  }
  return [
    for (final m in _sentence.allMatches(text))
      if (m[0]!.trim().isNotEmpty) m[0]!.trim(),
  ];
}

final _latinEnd = RegExp(r'[A-Za-z0-9]$');
final _latinStart = RegExp(r'^[A-Za-z0-9]');
final _sentence = RegExp(r'[^。！？]+[。！？]+[」』”’）)]*|[^。！？]+$');

/// A piece of a section's text: a paragraph of plain prose cut into [sentences], or any other
/// Markdown ([sentences] null) to render as it is.
class LessonBlock {
  const LessonBlock.prose(List<String> this.sentences) : source = '';
  const LessonBlock.markdown(this.source) : sentences = null;

  final List<String>? sentences;
  final String source;
}

final _structured = RegExp(r'!\[|^\s*([-*+]|\d+[.)])\s|^\s*#|^\s*>|^\s*\||^\s*(```|~~~)', multiLine: true);
final _fenceOpen = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

/// Cuts a section into blocks. The study text is written as dense paragraphs; showing one sentence per
/// line makes them readable, and lets the reader cover sentences to test their memory. Lists, tables,
/// code and pictures are left alone.
List<LessonBlock> lessonBlocks(String text) {
  final blocks = <String>[];
  var cur = <String>[];
  var fence = '';
  void flush() {
    if (cur.isNotEmpty) blocks.add(cur.join('\n'));
    cur = [];
  }

  for (final line in text.replaceAll(RegExp(r'\r\n?'), '\n').split('\n')) {
    final m = _fenceOpen.firstMatch(line);
    if (m != null) {
      fence = fence.isEmpty ? m[1]![0] : (line.trim().startsWith(fence) ? '' : fence);
    }
    if (fence.isEmpty && m == null && line.trim().isEmpty) {
      flush();
    } else {
      cur.add(line);
    }
  }
  flush();
  return [
    for (final b in blocks)
      if (_structured.hasMatch(b))
        LessonBlock.markdown(b)
      else if (splitSentences(b) case final s when s.length > 1)
        LessonBlock.prose(s)
      else
        LessonBlock.markdown(b),
  ];
}
