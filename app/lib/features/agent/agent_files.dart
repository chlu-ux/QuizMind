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

  /// A picture, by its name; the server judges by content again.
  bool get isImage {
    final dot = name.lastIndexOf('.');
    return dot >= 0 &&
        agentImageExtensions.contains(name.substring(dot).toLowerCase());
  }
}

/// What the plus button adds.
enum AttachKind { file, image }

typedef AgentFilePicker = Future<List<PickedFile>> Function(AttachKind kind);

/// Opens the system file chooser. Overridden in tests.
final agentFilePickerProvider = Provider<AgentFilePicker>(
  (ref) => pickAgentFiles,
);

Future<List<PickedFile>> pickAgentFiles(AttachKind kind) async {
  final picked = await FilePicker.pickFiles(
    type: kind == AttachKind.image ? FileType.image : FileType.custom,
    allowedExtensions: kind == AttachKind.image
        ? null
        : [for (final e in agentFileExtensions) e.substring(1)],
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
