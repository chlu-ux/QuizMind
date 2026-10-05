import '../../data/database.dart';
import '../../data/media_text.dart';
import '../../data/progress.dart';

/// Where a question matched, best first: a hit in the stem outranks one in an option or tag, which outranks the explanation.
enum SearchWhere { stem, option, tag, explanation }

class SearchHit {
  const SearchHit({required this.question, required this.where, required this.snippet});

  final Question question;

  /// The best place any term was found.
  final SearchWhere where;

  /// Text to show under the stem when the match is not in the stem (empty for a stem hit).
  final String snippet;
}

/// A run of text that either matched a search term or did not.
class Piece {
  const Piece(this.text, {required this.hit});

  final String text;
  final bool hit;

  @override
  bool operator ==(Object other) => other is Piece && other.text == text && other.hit == hit;

  @override
  int get hashCode => Object.hash(text, hit);

  @override
  String toString() => 'Piece(${hit ? '*' : ''}$text)';
}

/// The text with every character width- and case-folded, remembering where each folded unit came from.
class _Folded {
  _Folded(this.text, this.from, this.to);

  final String text;

  /// For each UTF-16 unit of [text]: the start and end offsets in the original it came from.
  final List<int> from;
  final List<int> to;
}

/// Folds [text] one character at a time (full-width ASCII to half-width, then lower case), so a
/// full-width "ＵＭＬ" and a "uml" compare equal. Doing it per character, rather than on the whole
/// string, keeps every folded unit tied to a place in the original, which is what highlighting needs.
_Folded _fold(String text) {
  final out = StringBuffer();
  final from = <int>[];
  final to = <int>[];
  var at = 0;
  for (final r in text.runes) {
    final len = r > 0xFFFF ? 2 : 1;
    final end = at + len;
    final int c = r == 0x3000
        ? 0x20
        : (r >= 0xFF01 && r <= 0xFF5E)
            ? r - 0xFEE0
            : r;
    final f = String.fromCharCode(c).toLowerCase();
    for (var i = 0; i < f.length; i++) {
      from.add(at);
      to.add(end);
    }
    out.write(f);
    at = end;
  }
  return _Folded(out.toString(), from, to);
}

final _space = RegExp(r'\s+');

/// Search words: the query folded and split on whitespace, duplicates dropped. Empty for a blank query.
List<String> searchTerms(String query) {
  final terms = _fold(query).text.split(_space).where((t) => t.isNotEmpty);
  return {...terms}.toList();
}

const _rank = {SearchWhere.stem: 0, SearchWhere.option: 1, SearchWhere.tag: 1, SearchWhere.explanation: 2};

/// Characters of context kept either side of a hit in a long explanation.
const _before = 24;
const _after = 48;

Map<SearchWhere, List<String>> _fieldsOf(Question q) => {
      SearchWhere.stem: [plainText(q.stem)],
      SearchWhere.option: [for (final o in q.options) plainText(o)],
      SearchWhere.tag: q.tags,
      SearchWhere.explanation: q.explanation.isEmpty ? const [] : [plainText(q.explanation)],
    };

/// Where in [text] the first of [terms] occurs, as offsets in the original; null if none does.
({int start, int end})? _firstHit(String text, List<String> terms) {
  final f = _fold(text);
  ({int start, int end})? best;
  for (final t in terms) {
    final i = f.text.indexOf(t);
    if (i < 0) continue;
    if (best == null || f.from[i] < best.start) best = (start: f.from[i], end: f.to[i + t.length - 1]);
  }
  return best;
}

String _snippetOf(SearchWhere where, List<String> texts, List<String> terms) {
  if (where == SearchWhere.stem) return '';
  for (final t in texts) {
    final hit = _firstHit(t, terms);
    if (hit == null) continue;
    if (where != SearchWhere.explanation) return t;
    final from = hit.start - _before < 0 ? 0 : hit.start - _before;
    final to = hit.end + _after > t.length ? t.length : hit.end + _after;
    return '${from > 0 ? '…' : ''}${t.substring(from, to).replaceAll(_space, ' ')}${to < t.length ? '…' : ''}';
  }
  return '';
}

/// The questions that contain every word of [query] (case, width and spacing ignored) somewhere in
/// the stem, options, tags or explanation. Words are matched as plain text, never as patterns.
/// Stem hits come first, then option / tag hits, then explanation-only hits; ties keep the order
/// of [questions]. Withdrawn questions and blank queries give nothing.
List<SearchHit> searchQuestions(List<Question> questions, String query) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const [];
  final hits = <SearchHit>[];
  for (final q in questions) {
    if (q.hidden) continue;
    final fields = _fieldsOf(q);
    final folded = [
      for (final w in SearchWhere.values) for (final t in fields[w]!) (w: w, text: _fold(t).text),
    ];
    final all = folded.map((f) => f.text).join('\n');
    if (!terms.every(all.contains)) continue;
    final where = SearchWhere.values.firstWhere(
      (w) => folded.any((f) => f.w == w && terms.any(f.text.contains)),
    );
    hits.add(SearchHit(question: q, where: where, snippet: _snippetOf(where, fields[where]!, terms)));
  }
  // List.sort is not stable, so ties are broken on the original position.
  final order = {for (var i = 0; i < hits.length; i++) hits[i]: i};
  hits.sort((a, b) => _rank[a.where]! != _rank[b.where]! ? _rank[a.where]!.compareTo(_rank[b.where]!) : order[a]!.compareTo(order[b]!));
  return hits;
}

/// Cuts [text] into runs, marking those that match one of [terms]. Overlapping and touching
/// matches are merged, so the pieces are in order, never empty, and join back into [text].
List<Piece> highlight(String text, List<String> terms) {
  final f = _fold(text);
  final spans = <(int, int)>[];
  for (final raw in terms) {
    final t = _fold(raw).text;
    if (t.isEmpty) continue;
    for (var i = f.text.indexOf(t); i >= 0; i = f.text.indexOf(t, i + 1)) {
      spans.add((f.from[i], f.to[i + t.length - 1]));
    }
  }
  spans.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final merged = <List<int>>[];
  for (final s in spans) {
    if (merged.isNotEmpty && s.$1 <= merged.last[1]) {
      if (s.$2 > merged.last[1]) merged.last[1] = s.$2;
    } else {
      merged.add([s.$1, s.$2]);
    }
  }
  final out = <Piece>[];
  var at = 0;
  for (final m in merged) {
    if (m[0] > at) out.add(Piece(text.substring(at, m[0]), hit: false));
    out.add(Piece(text.substring(m[0], m[1]), hit: true));
    at = m[1];
  }
  if (at < text.length) out.add(Piece(text.substring(at), hit: false));
  return out;
}
