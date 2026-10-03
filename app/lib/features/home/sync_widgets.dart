import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';

String formatLastSync(DateTime? t) => t == null ? '从未同步' : DateFormat('M月d日 HH:mm').format(t);

/// App-bar button that runs a sync and reports the result in a snackbar.
class SyncButton extends ConsumerWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncProvider);
    final pending = ref.watch(pendingUploadsProvider).value ?? 0;
    ref.listen(syncProvider, (prev, next) {
      final done = (prev?.running ?? false) && !next.running;
      if (done && next.message != null && context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(next.message!),
            backgroundColor: next.isError ? Theme.of(context).colorScheme.error : null,
          ));
      }
    });
    if (status.running) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      tooltip: '同步（上次：${formatLastSync(status.lastSync)}）',
      onPressed: () => ref.read(syncProvider.notifier).run(),
      icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.sync)),
    );
  }
}
