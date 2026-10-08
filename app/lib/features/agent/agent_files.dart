import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/agent_models.dart';

/// A file the learner chose. Its bytes are read only if the file passes the size check.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.size,
    required this.read,
  });

  final String name;
  final int size;
  final Future<Uint8List> Function() read;
}

typedef AgentFilePicker = Future<List<PickedFile>> Function();

/// Opens the system file chooser. Overridden in tests.
final agentFilePickerProvider = Provider<AgentFilePicker>(
  (ref) => pickAgentFiles,
);

Future<List<PickedFile>> pickAgentFiles() async {
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: [for (final e in agentFileExtensions) e.substring(1)],
  );
  return [
    for (final f in picked)
      PickedFile(
        name: f.name,
        size: await f.length() ?? 0,
        read: f.readAsBytes,
      ),
  ];
}
