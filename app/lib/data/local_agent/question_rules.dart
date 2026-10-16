/// The rules a question the assistant wrote must meet, the same ones the server applies
/// (server/internal/pipeline/validate.go and dedupe.go). They run here too so the model can be told
/// at once what to fix; the server checks again when the question is uploaded and has the last word.
library;

/// The fixed options of every judge question.
const judgeOptions = ['正确', '错误'];

const _minStemRunes = 6;
const _maxStemRunes = 300;
const _maxCodeStemRunes = 2000;
const _maxOptionRunes = 200;
const _maxExplainRunes = 800;
const _minQuoteRunes = 8;
const _maxTags = 3;
const _maxTagRunes = 20;

final _optionLabel = RegExp(r'^\s*[A-Da-d]\s*[\.\)、:：．）]\s*');
final _catchAllOption = RegExp(
  r'^((以上|上述|所有|全部)(选项|说法|答案|内容)?[，,]?(都|均|皆|全)?(是)?(正确|对|错误|错|不正确|不对|不是)?的?|(都|均|皆|全)(正确|对|错误|错|不正确|不对|是|不是)|[a-d]([和与及、,，][a-d])+|alloftheabove|noneoftheabove)$',
);
final _contextualStem = RegExp(
  r'(根据(上文|本文|文中|原文|以上|上述|材料)|文中(提到|说|指出)|上文|本文|本段|如上所述|the (text|passage|excerpt|article) (above|says)|according to the (text|passage|excerpt))',
  caseSensitive: false,
);
const _codeSymbols = r'<>=:*&[]{}()+-/\@#%^|~;';
final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _memberAccess = RegExp(r'[A-Za-z0-9_]\.[A-Za-z_]');
final _letterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);

/// Thrown by [validateQuestion]; the message says what is wrong, in words the model can act on.
class RuleError implements Exception {
  RuleError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A question as the model wrote it, before any checking.
class ProposedQuestion {
  const ProposedQuestion({
    required this.type,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.explanation,
    this.difficulty = 3,
    this.tags = const [],
    required this.sourceQuote,
    this.replaces = '',
  });

  final String type;
  final String stem;
  final List<String> options;
  final int answerIndex;
  final String explanation;
  final int difficulty;
  final List<String> tags;
  final String sourceQuote;

  /// The id of an earlier question of the conversation this one takes the place of.
  final String replaces;

  factory ProposedQuestion.fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? v) => [for (final x in (v as List? ?? const [])) '$x'];
    return ProposedQuestion(
      type: (j['type'] as String?) ?? '',
      stem: (j['stem'] as String?) ?? '',
      options: strings(j['options']),
      answerIndex: (j['answer_index'] as num?)?.toInt() ?? 0,
      explanation: (j['explanation'] as String?) ?? '',
      difficulty: (j['difficulty'] as num?)?.toInt() ?? 3,
      tags: strings(j['tags']),
      sourceQuote: (j['source_quote'] as String?) ?? '',
      replaces: (j['replaces'] as String?) ?? '',
    );
  }
}

/// A question that passed every rule, cleaned and ready to store.
class ValidQuestion {
  const ValidQuestion({
    required this.type,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.explanation,
    required this.difficulty,
    required this.tags,
    required this.sourceQuote,
    required this.key,
  });

  final String type;
  final String stem;
  final List<String> options;
  final int answerIndex;
  final String explanation;
  final int difficulty;
  final List<String> tags;
  final String sourceQuote;

  /// Identifies the content for exact de-duplication (the server hashes the same text).
  final String key;
}

int runeCount(String s) => s.runes.length;

/// Folds the compatibility forms NFKC would: full-width ASCII and the ideographic space, circled digits.
/// (The server folds with the whole of NFKC; a character folded there and not here only makes this check
/// a little less strict.)
String _fold(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      out.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      out.write(' ');
    } else if (r >= 0x2460 && r <= 0x2473) {
      out.write(r - 0x2460 + 1);
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

/// Lower-case letters and digits only, so quote matching and de-duplication ignore spacing,
/// punctuation, full-width forms and Markdown.
String normalizeText(String s) {
  final sb = StringBuffer();
  for (final r in _fold(s).runes) {
    final c = String.fromCharCode(r);
    if (_letterOrDigit.hasMatch(c)) sb.write(c.toLowerCase());
  }
  return sb.toString();
}

/// The text compared when looking for duplicate questions; it includes the options so generic stems
/// are not mistaken for duplicates of each other.
String dedupeText(String stem, List<String> options) {
  final opts = [for (final o in options) normalizeText(o)]..sort();
  return '${normalizeText(stem)}|${opts.join('|')}';
}

String _optionKey(String o) {
  final f = _fold(o);
  final hasSymbol = f.split('').any(_codeSymbols.contains);
  if (hasSymbol || _identifier.hasMatch(f.trim()) || _memberAccess.hasMatch(f)) {
    return f.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join();
  }
  return normalizeText(o);
}

bool _isCatchAll(String o) {
  var compact = o.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join().toLowerCase();
  compact = compact.replaceFirst(RegExp(r'[。.!！]+$'), '');
  return _catchAllOption.hasMatch(compact);
}

List<String> _cleanSingleOptions(List<String> raw) {
  if (raw.length != 4) throw RuleError('single question needs exactly 4 options, got ${raw.length}');
  final out = <String>[];
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final o = raw[i].trim().replaceFirst(_optionLabel, '').trim();
    if (o.isEmpty) throw RuleError('option $i is empty');
    if (runeCount(o) > _maxOptionRunes) throw RuleError('option $i longer than $_maxOptionRunes characters');
    if (_isCatchAll(o)) throw RuleError('option $i is a catch-all ("$o")');
    final key = _optionKey(o);
    if (key.isEmpty || seen.contains(key)) throw RuleError('option $i duplicates another option');
    seen.add(key);
    out.add(o);
  }
  return out;
}

List<String> _cleanTags(List<String> raw) {
  final out = <String>[];
  for (var t in raw) {
    t = t.trim();
    if (t.isEmpty || runeCount(t) > _maxTagRunes) continue;
    out.add(t);
    if (out.length == _maxTags) break;
  }
  return out;
}

/// Applies the deterministic rules and checks that the source quote really occurs in [lessonText].
ValidQuestion validateQuestion(ProposedQuestion g, String lessonText) {
  final type = g.type.trim();
  final stem = g.stem.trim();
  final explanation = g.explanation.trim();
  final quote = g.sourceQuote.trim();

  final maxStem = stem.contains('```') ? _maxCodeStemRunes : _maxStemRunes;
  final n = runeCount(stem);
  if (n < _minStemRunes || n > maxStem) throw RuleError('stem length $n outside $_minStemRunes..$maxStem');
  if (_contextualStem.hasMatch(stem)) throw RuleError('stem refers to the source text instead of standing alone');

  late final List<String> options;
  switch (type) {
    case 'single':
      options = _cleanSingleOptions(g.options);
      if (g.answerIndex < 0 || g.answerIndex >= options.length) {
        throw RuleError('answer_index ${g.answerIndex} out of range for ${options.length} options');
      }
    case 'judge':
      if (g.answerIndex != 0 && g.answerIndex != 1) {
        throw RuleError('judge answer_index must be 0 or 1, got ${g.answerIndex}');
      }
      options = [...judgeOptions];
    default:
      throw RuleError('unsupported question type "${g.type}"');
  }
  if (runeCount(explanation) > _maxExplainRunes) throw RuleError('explanation longer than $_maxExplainRunes characters');
  final difficulty = g.difficulty < 1 || g.difficulty > 5 ? 3 : g.difficulty;

  final q = normalizeText(quote);
  if (runeCount(q) < _minQuoteRunes) throw RuleError('source_quote too short to verify');
  if (!normalizeText(lessonText).contains(q)) {
    throw RuleError('source_quote not found verbatim in the source excerpt (possible fabrication)');
  }
  return ValidQuestion(
    type: type,
    stem: stem,
    options: options,
    answerIndex: g.answerIndex,
    explanation: explanation,
    difficulty: difficulty,
    tags: _cleanTags(g.tags),
    sourceQuote: quote,
    key: dedupeText(stem, options),
  );
}

/// A question already in the bank, for [Deduper].
class ExistingQuestion {
  const ExistingQuestion(this.id, this.stem, this.options);
  final String id;
  final String stem;
  final List<String> options;
}

class _Entry {
  _Entry(this.id, String stem, List<String> options)
      : code = stem.contains('```'),
        textGrams = _trigrams(dedupeText(stem, options)),
        stemGrams = _trigrams(normalizeText(stem)),
        options = {for (final o in options) normalizeText(o)};

  final String id;
  final bool code;
  final Set<String> textGrams;
  final Set<String> stemGrams;
  final Set<String> options;
}

Set<String> _trigrams(String s) {
  final r = s.runes.toList();
  if (r.length < 3) return {s};
  return {for (var i = 0; i + 3 <= r.length; i++) String.fromCharCodes(r.sublist(i, i + 3))};
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final small = a.length <= b.length ? a : b;
  final large = identical(small, a) ? b : a;
  final inter = small.where(large.contains).length;
  return inter / (a.length + b.length - inter);
}

double _shared(Set<String> a, Set<String> b) {
  if (a.isEmpty) return 1;
  return a.where(b.contains).length / a.length;
}

/// Detects exact and near-duplicate questions within one bank: whole text similar, or stems similar
/// and half the options shared. Two code questions are only compared exactly.
class Deduper {
  Deduper(Iterable<ExistingQuestion> existing, this.threshold) {
    for (final e in existing) {
      _keys[dedupeText(e.stem, e.options)] = e.id;
      _entries.add(_Entry(e.id, e.stem, e.options));
    }
  }

  final double threshold;
  final _keys = <String, String>{};
  final _entries = <_Entry>[];

  /// The id of what [q] duplicates, or null; a question that is not a duplicate is remembered, so later
  /// ones of the same batch compare against it too.
  String? check(String id, ValidQuestion q) {
    final same = _keys[q.key];
    if (same != null) return same;
    final cand = _Entry(id, q.stem, q.options);
    for (final e in _entries) {
      if (cand.code && e.code) continue;
      if (_jaccard(cand.textGrams, e.textGrams) >= threshold) return e.id;
      if (_jaccard(cand.stemGrams, e.stemGrams) >= threshold && _shared(cand.options, e.options) >= 0.5) return e.id;
    }
    _keys[q.key] = id;
    _entries.add(cand);
    return null;
  }
}

/// Used by the tools to cut text to a number of characters.
String clip(String s, int n) {
  final r = s.runes.toList();
  return r.length <= n ? s : '${String.fromCharCodes(r.sublist(0, n))}…';
}
