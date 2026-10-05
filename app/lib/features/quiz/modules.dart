import '../../data/database.dart';
import 'topics.dart';

/// Short names for the modules (documents) of one bank. Document titles in a bank usually share a
/// long lead ("软件设计师（中级）考点精讲（操作系统）"); the learner only needs what differs, so the
/// shared lead is dropped and the brackets around the rest with it. A title with nothing left after
/// that (the bank's overview document, or a bank with a single document) keeps its full title.
String moduleLabel(String title, Iterable<String> allTitles) {
  final titles = allTitles.toSet();
  if (titles.length < 2) return title;
  var lead = titles.first;
  for (final t in titles) {
    var i = 0;
    while (i < lead.length && i < t.length && lead.codeUnitAt(i) == t.codeUnitAt(i)) {
      i++;
    }
    lead = lead.substring(0, i);
  }
  var rest = title.substring(lead.length);
  if (rest.isEmpty) return title;
  if (lead.endsWith('（') && rest.endsWith('）')) {
    rest = rest.substring(0, rest.length - 1);
  } else if (rest.startsWith('（') && rest.endsWith('）')) {
    rest = rest.substring(1, rest.length - 1);
  }
  rest = rest.trim();
  return rest.isEmpty ? title : rest;
}

/// One module of a bank: a topic row (counts, accuracy) plus which document it is.
class ModuleSummary extends TopicSummary {
  ModuleSummary(this.id, this.title, this.order, super.label);

  final String id;
  final String title;

  /// When the document was uploaded; modules are listed in this order.
  final int order;
}

/// The modules of [qs] in the order their documents were added, with how each has gone.
/// Questions that carry no document (synced from an older server) belong to no module.
List<ModuleSummary> moduleSummary(List<Question> qs, List<Attempt> attempts) {
  final byQuestion = <String, ({int attempts, int correct})>{};
  for (final a in attempts) {
    final t = byQuestion[a.questionId] ?? (attempts: 0, correct: 0);
    byQuestion[a.questionId] = (attempts: t.attempts + 1, correct: t.correct + (a.isCorrect ? 1 : 0));
  }
  final titleOf = <String, String>{};
  final orderOf = <String, int>{};
  for (final q in qs) {
    if (q.documentId.isEmpty) continue;
    titleOf.putIfAbsent(q.documentId, () => q.documentTitle);
    orderOf.putIfAbsent(q.documentId, () => q.documentOrder);
  }
  final titles = titleOf.values;
  final rows = <String, ModuleSummary>{};
  for (final q in qs) {
    if (q.documentId.isEmpty) continue;
    final r = rows.putIfAbsent(
      q.documentId,
      () => ModuleSummary(q.documentId, titleOf[q.documentId]!, orderOf[q.documentId]!, moduleLabel(titleOf[q.documentId]!, titles)),
    );
    r.count++;
    final t = byQuestion[q.id];
    if (t == null) continue;
    r.answered++;
    if (t.correct < t.attempts) r.missed++;
    r.attempts += t.attempts;
    r.correct += t.correct;
  }
  return rows.values.toList()..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.title.compareTo(b.title));
}

/// The questions of one module, in the order of [qs].
List<Question> moduleQuestions(List<Question> qs, String documentId) => [for (final q in qs) if (q.documentId == documentId) q];
