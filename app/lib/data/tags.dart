/// Knowledge-point tags come from the model, so near-duplicates are common: "UML"
/// and "UML 辨析", "Cache" and "cache", "数据流图" and "数据流图案例". This folds
/// them for statistics and for picking exam topics.
library;

/// Width- and whitespace-normalised form, for comparing tags (full-width ASCII
/// becomes half-width; runs of spaces collapse).
String normalizeTag(String tag) {
  final sb = StringBuffer();
  for (final r in tag.runes) {
    if (r == 0x3000) {
      sb.write(' ');
    } else if (r >= 0xFF01 && r <= 0xFF5E) {
      sb.writeCharCode(r - 0xFEE0);
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _key(String tag) => normalizeTag(tag).toLowerCase();

final _separator = RegExp(r'\s*[/>›:|·]\s*');

/// The part before a path-like separator ("数据库/范式" → "数据库").
String _base(String tag) {
  final n = normalizeTag(tag);
  final m = _separator.firstMatch(n);
  return m != null && m.start > 0 ? n.substring(0, m.start).trim() : n;
}

bool _asciiWord(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

/// Returns a function mapping a raw tag to the label it is shown under.
///
/// Without [merge], tags that differ only in case, width or spacing share a label
/// (the most common spelling). With [merge], a tag also joins a shorter tag it
/// starts with ("UML 辨析" → "UML") and drops any "/"-style suffix. A one-letter
/// prefix never absorbs anything, and a Latin prefix only absorbs at a word
/// boundary, so "OSI" stays apart from "OS".
String Function(String) tagLabeler(Iterable<String> allTags, {required bool merge}) {
  final seen = <String, Map<String, int>>{}; // key → spelling → count
  for (final raw in allTags) {
    final spelling = merge ? _base(raw) : normalizeTag(raw);
    final k = spelling.toLowerCase();
    if (k.isEmpty) continue;
    final m = seen.putIfAbsent(k, () => {});
    m[spelling] = (m[spelling] ?? 0) + 1;
  }
  final keys = seen.keys.toList()
    ..sort((a, b) => a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b));

  final root = <String, String>{};
  for (final k in keys) {
    var r = k;
    if (merge) {
      for (final shorter in keys) {
        if (shorter.length >= k.length) break;
        if (shorter.length < 2 || !k.startsWith(shorter)) continue;
        if (_asciiWord(shorter[shorter.length - 1]) && _asciiWord(k[shorter.length])) continue;
        r = root[shorter] ?? shorter;
        break;
      }
    }
    root[k] = r;
  }

  String label(String k) {
    final spellings = seen[k]!.entries.toList()
      ..sort((a, b) => a.value != b.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
    return spellings.first.key;
  }

  return (tag) {
    final k = merge ? _base(tag).toLowerCase() : _key(tag);
    return seen.containsKey(k) ? label(root[k]!) : normalizeTag(tag);
  };
}
