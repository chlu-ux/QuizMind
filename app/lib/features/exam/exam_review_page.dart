import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models.dart';
import 'exam_result_view.dart';
import 'exam_session.dart';

/// Looks at an earlier exam again: score and, where the exam kept it, every question
/// with the answer given. Questions withdrawn since show as such.
class ExamReviewPage extends ConsumerStatefulWidget {
  const ExamReviewPage({super.key, required this.examId});

  final String examId;

  @override
  ConsumerState<ExamReviewPage> createState() => _ExamReviewPageState();
}

class _ExamReviewPageState extends ConsumerState<ExamReviewPage> {
  late Future<({ExamRecord record, List<ExamEntry> entries})?> _loaded;

  @override
  void initState() {
    super.initState();
    _loaded = _load();
  }

  Future<({ExamRecord record, List<ExamEntry> entries})?> _load() async {
    final repo = ref.read(repositoryProvider);
    final record = await repo.exam(widget.examId);
    if (record == null) return null;
    final qs = await repo.questionsByIds([for (final it in record.items) it.questionId]);
    return (record: record, entries: examEntries(record, {for (final q in qs) q.id: q}));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _loaded,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(appBar: AppBar(title: const Text('考试回顾')), body: const Center(child: CircularProgressIndicator()));
        }
        final data = snap.data;
        if (data == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('考试回顾')),
            body: const Center(child: Text('没有找到这场考试，可能还没同步到这台设备')),
          );
        }
        return ExamResultView(record: data.record, entries: data.entries, title: '考试回顾');
      },
    );
  }
}
