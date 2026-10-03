import '../../data/database.dart';
import '../../data/repository.dart';
import '../../data/session_store.dart';
import 'quiz_session.dart';

/// A saved session rebuilt against the questions that still exist.
class ResumePlan {
  const ResumePlan({
    required this.title,
    required this.questions,
    required this.index,
    required this.seed,
    required this.restored,
  });

  final String title;
  final List<Question> questions;
  final int index;
  final int seed;
  final Map<String, RestoredAnswer> restored;
}

/// Reloads [saved] from the database. Questions withdrawn or reported since are
/// dropped, and the position moves back so it still points at the same question
/// (or the one that followed it). Null when nothing is left to practise.
Future<ResumePlan?> planResume(SavedSession saved, Repository repo) async {
  final questions = await repo.questionsByIds(saved.ids);
  if (questions.isEmpty) return null;
  final alive = {for (final q in questions) q.id};
  final index = saved.ids.take(saved.index).where(alive.contains).length.clamp(0, questions.length - 1);
  final restored = <String, RestoredAnswer>{};
  for (final e in saved.answers.entries) {
    if (!alive.contains(e.key)) continue;
    final state = await repo.getState(e.key);
    if (state == null) continue; // the local record is gone; let it be answered again
    restored[e.key] = RestoredAnswer(
      selected: e.value.selected,
      outcome: AnswerOutcome(correct: e.value.correct, enteredWrongBook: false, state: state),
    );
  }
  return ResumePlan(title: saved.title, questions: questions, index: index, seed: saved.seed, restored: restored);
}
