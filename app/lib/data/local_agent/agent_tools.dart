/// The tools the assistant may call, run on the library this device keeps. A port of
/// server/internal/agent/tool_*.go, search.go and stats.go: the model is told about the tools by the
/// spec the server sends (names, descriptions, schemas), so what each does must stay the same here.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../agent_models.dart';
import 'library.dart';
import 'question_rules.dart';

/// A tool call the model got wrong; the message is written for the model and says how to fix it.
class ToolArgError implements Exception {
  ToolArgError(this.message);
  final String message;
}

/// Turns a query into lower-case search terms. Latin words and digits are kept whole; a run of Chinese
/// is split into overlapping pairs of characters (plus the run itself when it is short).
List<String> searchTerms(String q) {
  final terms = <String>[];
  final seen = <String>{};
  void add(String t) {
    if (t.isNotEmpty && seen.add(t)) terms.add(t);
  }

  final word = StringBuffer();
  final han = <int>[];
  void flushWord() {
    add(word.toString());
    word.clear();
  }

  void flushHan() {
    if (han.length == 1) {
      add(String.fromCharCodes(han));
    } else if (han.length >= 2) {
      if (han.length <= 4) add(String.fromCharCodes(han));
      for (var i = 0; i + 1 < han.length; i++) {
        add(String.fromCharCodes(han.sublist(i, i + 2)));
      }
    }
    han.clear();
  }

  final isHan = RegExp(r'\p{Script=Han}', unicode: true);
  final isLetterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);
  for (final r in q.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    if (isHan.hasMatch(c)) {
      flushWord();
      han.add(r);
    } else if (isLetterOrDigit.hasMatch(c)) {
      flushHan();
      word.write(c);
    } else {
      flushWord();
      flushHan();
    }
  }
  flushWord();
  flushHan();
  return terms;
}

int _count(String text, String t) {
  var n = 0, from = 0;
  while (true) {
    final i = text.indexOf(t, from);
    if (i < 0) return n;
    n++;
    from = i + t.length;
  }
}

/// How well text matches the terms: each distinct term found counts once, plus a little for repeats.
int termScore(String textLower, List<String> terms) {
  var score = 0;
  for (final t in terms) {
    final n = _count(textLower, t);
    if (n == 0) continue;
    score += 2 + math.min(n - 1, 2);
  }
  return score;
}

/// About `2 * around` characters of [text] centred on the first place any term occurs.
String snippet(String text, List<String> terms, int around) {
  final lower = text.toLowerCase();
  var first = -1;
  for (final t in terms) {
    final i = lower.indexOf(t);
    if (i >= 0 && (first < 0 || i < first)) first = i;
  }
  final runes = text.runes.toList();
  if (first < 0) return clip(text, 2 * around);
  final at = lower.substring(0, first).runes.length;
  final from = math.max(0, at - around), to = math.min(runes.length, at + around);
  var s = String.fromCharCodes(runes.sublist(from, to));
  if (from > 0) s = '…$s';
  if (to < runes.length) s = '$s…';
  return s;
}

// The weak-question ranking matches the apps' statistics: a question is weak when it was answered wrong
// within its last [_weakWindow] answers; small samples are pulled toward a prior.
const _weakWindow = 5;
const _weakPriorRate = 0.25;
const _weakPriorWeight = 4;

class QStat {
  int attempts = 0;
  int correct = 0;
  bool latestCorrect = false;
  int recentWrong = 0;
  int recentCount = 0;
  double weakScore = 0;
}

Map<String, QStat> questionStats(List<AgentAttempt> attempts) {
  final byQ = <String, List<bool>>{};
  for (final a in attempts) {
    byQ.putIfAbsent(a.questionId, () => []).add(a.correct);
  }
  final out = <String, QStat>{};
  byQ.forEach((id, results) {
    final st = QStat()
      ..attempts = results.length
      ..latestCorrect = results.last
      ..correct = results.where((x) => x).length;
    final recent = results.sublist(math.max(0, results.length - _weakWindow));
    st.recentCount = recent.length;
    st.recentWrong = recent.where((x) => !x).length;
    if (st.recentWrong > 0) {
      st.weakScore = (st.recentWrong + _weakPriorRate * _weakPriorWeight) / (st.recentCount + _weakPriorWeight);
    }
    out[id] = st;
  });
  return out;
}

/// Weakest first, ties broken by id so the order is stable.
void sortWeak(List<AgentQuestion> qs, Map<String, QStat> stats) {
  (double, int) score(AgentQuestion q) {
    final st = stats[q.id];
    return st == null ? (0, 0) : (st.weakScore, st.recentWrong);
  }

  qs.sort((a, b) {
    final (si, wi) = score(a);
    final (sj, wj) = score(b);
    if (si != sj) return sj.compareTo(si);
    if (wi != wj) return wj.compareTo(wi);
    return a.id.compareTo(b.id);
  });
}

String lessonTitle(AgentLesson l) {
  final parts = l.headingPath.split(' > ');
  final last = parts.last.trim();
  return last.isNotEmpty ? last : l.headingPath;
}

/// The library as one conversation sees it: each part is read at most once.
class Snapshot {
  Snapshot(this._lib);

  final AgentLibrary _lib;
  Future<List<AgentBank>>? _banks;
  Future<List<AgentLesson>>? _lessons;
  Future<List<AgentQuestion>>? _questions;
  Future<List<AgentAttempt>>? _attempts;
  Map<String, AgentLesson>? _byId;

  Future<List<AgentBank>> banks() => _banks ??= _lib.banks();
  Future<List<AgentQuestion>> questions() => _questions ??= _lib.questions();
  Future<List<AgentAttempt>> attempts() => _attempts ??= _lib.attempts();
  Future<List<AgentLesson>> lessons() => _lessons ??= _lib.lessons();

  Future<AgentLesson?> lesson(String id) async {
    final all = await lessons();
    return (_byId ??= {for (final l in all) l.id: l})[id];
  }
}

/// What one conversation's tools share: the library, the bank the learner is in, and the ids the
/// assistant has seen (it may only link to those).
class ToolEnv {
  ToolEnv(AgentLibrary library, this.bank) : lib = Snapshot(library);

  final Snapshot lib;
  final String bank;
  final _seen = <String>{};
  final drafts = <AgentDraft>[];

  void see(Iterable<String> ids) {
    for (final id in ids) {
      if (id.isNotEmpty) _seen.add(id);
    }
  }

  bool known(String id) => _seen.contains(id);

  String bankOrDefault(String arg) => arg.isNotEmpty ? arg : bank;

  List<AgentDraft> takeDrafts() {
    final d = [...drafts];
    drafts.clear();
    return d;
  }
}

/// The outcome of one proposed question; [error] is written for the model.
class ProposeResult {
  const ProposeResult.ok(this.draft)
      : ok = true,
        error = '';
  const ProposeResult.fail(this.error)
      : ok = false,
        draft = null;

  final bool ok;
  final String error;
  final AgentDraft? draft;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        if (draft != null) 'draft_id': draft!.id,
        if (error.isNotEmpty) 'error': error,
      };
}

/// Checks and stores the questions the model proposes.
abstract class Drafter {
  Future<List<ProposeResult>> propose(String lessonId, List<ProposedQuestion> qs);

  /// The questions of the conversation, adopted or taken back.
  Future<List<AgentDraft>> drafts();
}

Map<String, dynamic> draftJson(AgentDraft d) => {
      'draft_id': d.id,
      'lesson_id': d.lessonId,
      'type': d.type,
      'stem': d.stem,
      'options': d.options,
      'answer_index': d.answerIndex,
      'explanation': d.explanation,
      'difficulty': d.difficulty,
      'tags': d.tags,
      'source_quote': d.sourceQuote,
      'verified': d.verified,
      'adopted': d.adopted,
    };

typedef ToolArgs = Map<String, dynamic>;

int _int(ToolArgs a, String k) => (a[k] as num?)?.toInt() ?? 0;
String _str(ToolArgs a, String k) => a[k] is String ? a[k] as String : '';

int clampLimit(int n, int def, int max) => n <= 0 ? def : (n > max ? max : n);

/// The tools of one conversation, by name.
class ToolSet {
  ToolSet(this.env, {this.drafter, this.maxResult = 6000, math.Random? random}) : _random = random ?? math.Random();

  final ToolEnv env;
  final Drafter? drafter;
  final int maxResult;
  final math.Random _random;

  static const _readOnly = [
    'list_outline',
    'search_lessons',
    'get_lesson',
    'search_questions',
    'pick_questions',
    'get_weak_points',
  ];

  bool has(String name) => _readOnly.contains(name) || (drafter != null && (name == 'propose_questions' || name == 'list_drafts'));

  List<String> get names => [..._readOnly, if (drafter != null) ...['propose_questions', 'list_drafts']];

  /// The status line shown while the tool runs.
  Future<String> label(String name, ToolArgs args) async {
    switch (name) {
      case 'list_outline':
        return '查看目录';
      case 'search_lessons':
        return '在讲义里查找「${clip(_str(args, 'query'), 20)}」';
      case 'get_lesson':
        final l = await env.lib.lesson(_str(args, 'lesson_id'));
        return l == null ? '读取讲义' : '读取讲义「${clip(lessonTitle(l), 20)}」';
      case 'search_questions':
        final q = _str(args, 'query');
        return q.isNotEmpty ? '查找题目「${clip(q, 20)}」' : '查找题目';
      case 'pick_questions':
        return '挑选题目';
      case 'get_weak_points':
        return '分析薄弱点';
      case 'propose_questions':
        return '生成题目草稿';
      case 'list_drafts':
        return '查看已有草稿';
    }
    return name;
  }

  /// Runs one call: the text for the tool_result and whether it failed.
  Future<(String, bool)> execute(String name, Object? rawArgs) async {
    if (!has(name)) return ('没有名为 "$name" 的工具。可用的工具：${names.join('、')}', true);
    try {
      final args = rawArgs is Map ? rawArgs.cast<String, dynamic>() : <String, dynamic>{};
      final res = await _run(name, args);
      return (_limit(res), false);
    } on ToolArgError catch (e) {
      return (e.message, true);
    } catch (_) {
      return ('工具执行失败，请换个办法或如实告诉用户。', true);
    }
  }

  String _limit(Object? res) {
    final s = res is String ? res : jsonEncode(res);
    final r = s.runes.toList();
    if (r.length <= maxResult) return s;
    return '${String.fromCharCodes(r.sublist(0, maxResult))}…（已截断，请缩小范围）';
  }

  Future<Object?> _run(String name, ToolArgs a) => switch (name) {
        'list_outline' => _listOutline(a),
        'search_lessons' => _searchLessons(a),
        'get_lesson' => _getLesson(a),
        'search_questions' => _searchQuestions(a),
        'pick_questions' => _pickQuestions(a),
        'get_weak_points' => _getWeakPoints(a),
        'propose_questions' => _propose(a),
        'list_drafts' => _listDrafts(),
        _ => throw ToolArgError('没有名为 "$name" 的工具'),
      };

  // ---- lessons ----

  static const _maxOutlineLessons = 200;

  Future<Object?> _listOutline(ToolArgs a) async {
    final banks = await env.lib.banks();
    final lessons = await env.lib.lessons();
    final questions = await env.lib.questions();
    final stats = questionStats(await env.lib.attempts());
    final byLesson = <String, List<int>>{}; // total, answered, latestCorrect
    for (final q in questions) {
      if (q.lessonId.isEmpty) continue;
      final p = byLesson.putIfAbsent(q.lessonId, () => [0, 0, 0]);
      p[0]++;
      final st = stats[q.id];
      if (st != null) {
        p[1]++;
        if (st.latestCorrect) p[2]++;
      }
    }
    final bank = env.bankOrDefault(_str(a, 'bank_id'));
    final documentId = _str(a, 'document_id');
    var wantLessons = documentId.isNotEmpty;
    if (!wantLessons) {
      final n = lessons.where((l) => bank.isEmpty || l.bankId == bank).length;
      wantLessons = n <= _maxOutlineLessons;
    }
    final out = <Map<String, dynamic>>[];
    for (final b in banks) {
      if (bank.isNotEmpty && b.id != bank) continue;
      final docs = <Map<String, dynamic>>[];
      final index = <String, int>{};
      for (final l in lessons) {
        if (l.bankId != b.id || (documentId.isNotEmpty && l.documentId != documentId)) continue;
        var di = index[l.documentId];
        if (di == null) {
          di = docs.length;
          index[l.documentId] = di;
          docs.add({'document_id': l.documentId, 'title': l.documentTitle, 'lesson_count': 0});
        }
        final d = docs[di];
        d['lesson_count'] = (d['lesson_count'] as int) + 1;
        if (wantLessons) {
          final p = byLesson[l.id] ?? const [0, 0, 0];
          final list = (d['lessons'] ??= <Map<String, dynamic>>[]) as List<Map<String, dynamic>>;
          list.add({
            'lesson_id': l.id,
            'title': lessonTitle(l),
            'path': l.headingPath,
            'questions': p[0],
            'answered': p[1],
            'latest_correct': p[2],
          });
          env.see([l.id]);
        }
      }
      if (docs.isNotEmpty) out.add({'bank_id': b.id, 'title': b.title, 'documents': docs});
    }
    final res = <String, dynamic>{'banks': out};
    if (!wantLessons) res['note'] = '小节太多，只列了章节。要看某一章的小节，请带上它的 document_id 再调用。';
    return res;
  }

  Future<Object?> _searchLessons(ToolArgs a) async {
    final terms = searchTerms(_str(a, 'query'));
    if (terms.isEmpty) throw ToolArgError('query 不能为空');
    final lessons = await env.lib.lessons();
    final bank = env.bankOrDefault(_str(a, 'bank_id'));
    final hits = <(AgentLesson, int)>[];
    for (final l in lessons) {
      if (bank.isNotEmpty && l.bankId != bank) continue;
      // A hit in the heading counts three times as much as one in the body.
      final s = 3 * termScore(l.headingPath.toLowerCase(), terms) + termScore(l.text.toLowerCase(), terms);
      if (s > 0) hits.add((l, s));
    }
    hits.sort((x, y) => x.$2 != y.$2 ? y.$2.compareTo(x.$2) : x.$1.id.compareTo(y.$1.id));
    final limit = clampLimit(_int(a, 'limit'), 5, 8);
    final res = <Map<String, dynamic>>[];
    for (final h in hits) {
      if (res.length == limit) break;
      env.see([h.$1.id]);
      res.add({'lesson_id': h.$1.id, 'path': h.$1.headingPath, 'snippet': snippet(h.$1.text, terms, 100)});
    }
    if (res.isEmpty) return {'results': res, 'note': '讲义里没有找到相关内容。'};
    return {'results': res};
  }

  Future<Object?> _getLesson(ToolArgs a) async {
    final id = _str(a, 'lesson_id');
    final l = await env.lib.lesson(id);
    if (l == null) throw ToolArgError('没有 id 为 "$id" 的小节，请用 search_lessons 或 list_outline 取得 lesson_id');
    env.see([l.id]);
    // The text is data from the library, not instructions: wrap it so the prompt can say so.
    final sb = StringBuffer('<lesson id="${l.id}" path="${l.headingPath}">\n${l.text}\n</lesson>');
    if (a['with_neighbors'] == true) {
      final all = await env.lib.lessons();
      final i = all.indexWhere((x) => x.id == l.id);
      if (i >= 0) {
        if (i > 0 && all[i - 1].documentId == l.documentId) {
          sb.write('\n上一节：${all[i - 1].headingPath}（lesson_id=${all[i - 1].id}）');
          env.see([all[i - 1].id]);
        }
        if (i + 1 < all.length && all[i + 1].documentId == l.documentId) {
          sb.write('\n下一节：${all[i + 1].headingPath}（lesson_id=${all[i + 1].id}）');
          env.see([all[i + 1].id]);
        }
      }
    }
    return sb.toString();
  }

  // ---- questions ----

  bool _matches(AgentQuestion q, String lessonId, String bank) =>
      (lessonId.isEmpty || q.lessonId == lessonId) && (bank.isEmpty || q.bankId == bank);

  Future<Object?> _searchQuestions(ToolArgs a) async {
    final questions = await env.lib.questions();
    final stats = questionStats(await env.lib.attempts());
    final lessonId = _str(a, 'lesson_id');
    final bank = env.bankOrDefault(_str(a, 'bank_id'));
    final terms = searchTerms(_str(a, 'query'));
    final hits = <(AgentQuestion, int)>[];
    for (final q in questions) {
      if (!_matches(q, lessonId, bank)) continue;
      var s = 1;
      if (terms.isNotEmpty) {
        final text = '${q.stem}\n${q.options.join('\n')}\n${q.explanation}'.toLowerCase();
        s = termScore(text, terms);
        if (s == 0) continue;
      }
      hits.add((q, s));
    }
    hits.sort((x, y) => x.$2 != y.$2 ? y.$2.compareTo(x.$2) : x.$1.id.compareTo(y.$1.id));
    final limit = clampLimit(_int(a, 'limit'), 5, 10);
    final res = <Map<String, dynamic>>[];
    for (final h in hits) {
      if (res.length == limit) break;
      final q = h.$1;
      env.see([q.id, q.lessonId]);
      final st = stats[q.id];
      res.add({
        'question_id': q.id,
        if (q.lessonId.isNotEmpty) 'lesson_id': q.lessonId,
        'type': q.type,
        'stem': q.stem,
        'options': q.options,
        'answer_index': q.answer,
        'explanation': clip(q.explanation, 300),
        'attempts': st?.attempts ?? 0,
        'correct': st?.correct ?? 0,
      });
    }
    return {'results': res};
  }

  Future<Object?> _pickQuestions(ToolArgs a) async {
    final questions = await env.lib.questions();
    final stats = questionStats(await env.lib.attempts());
    final lessonId = _str(a, 'lesson_id');
    final bank = env.bankOrDefault(_str(a, 'bank_id'));
    var pool = [for (final q in questions) if (_matches(q, lessonId, bank)) q];
    final count = clampLimit(_int(a, 'count'), 3, 10);
    if (a['weak'] == true) {
      sortWeak(pool, stats);
      // Only questions that have actually gone wrong are weak.
      var n = 0;
      while (n < pool.length && (stats[pool[n].id]?.weakScore ?? 0) > 0) {
        n++;
      }
      pool = pool.sublist(0, n);
    } else {
      pool.shuffle(_random);
      // Questions never answered first.
      pool = [...pool.where((q) => stats[q.id] == null), ...pool.where((q) => stats[q.id] != null)];
    }
    if (pool.length > count) pool = pool.sublist(0, count);
    final res = <Map<String, dynamic>>[];
    for (final q in pool) {
      env.see([q.id, q.lessonId]);
      res.add({
        'question_id': q.id,
        if (q.lessonId.isNotEmpty) 'lesson_id': q.lessonId,
        'type': q.type,
        'stem': q.stem,
        'options': q.options,
      });
    }
    if (res.isEmpty) return {'questions': res, 'note': '没有符合条件的题。'};
    return {'questions': res};
  }

  Future<Object?> _getWeakPoints(ToolArgs a) async {
    final questions = await env.lib.questions();
    final stats = questionStats(await env.lib.attempts());
    final bank = env.bankOrDefault(_str(a, 'bank_id'));
    final limit = clampLimit(_int(a, 'limit'), 5, 10);
    final pool = <AgentQuestion>[];
    final byLesson = <String, List<int>>{}; // attempts, correct
    for (final q in questions) {
      if (bank.isNotEmpty && q.bankId != bank) continue;
      final st = stats[q.id];
      if (st == null) continue;
      pool.add(q);
      if (q.lessonId.isNotEmpty) {
        final g = byLesson.putIfAbsent(q.lessonId, () => [0, 0]);
        g[0] += st.attempts;
        g[1] += st.correct;
      }
    }
    sortWeak(pool, stats);
    final weakQs = <Map<String, dynamic>>[];
    for (final q in pool) {
      final st = stats[q.id]!;
      if (st.weakScore == 0 || weakQs.length == limit) break;
      env.see([q.id, q.lessonId]);
      weakQs.add({
        'question_id': q.id,
        if (q.lessonId.isNotEmpty) 'lesson_id': q.lessonId,
        'stem': clip(q.stem, 80),
        'recent_attempts': st.recentCount,
        'recent_wrong': st.recentWrong,
      });
    }
    final weakLs = <({String id, String path, int attempts, int accuracy})>[];
    for (final e in byLesson.entries) {
      final g = e.value;
      if (g[0] < 3 || g[1] == g[0]) continue;
      final l = await env.lib.lesson(e.key);
      if (l == null) continue;
      weakLs.add((id: e.key, path: l.headingPath, attempts: g[0], accuracy: 100 * g[1] ~/ g[0]));
    }
    weakLs.sort((x, y) {
      if (x.accuracy != y.accuracy) return x.accuracy.compareTo(y.accuracy);
      if (x.attempts != y.attempts) return y.attempts.compareTo(x.attempts);
      return x.id.compareTo(y.id);
    });
    final top = weakLs.length > limit ? weakLs.sublist(0, limit) : weakLs;
    env.see([for (final l in top) l.id]);
    final res = <String, dynamic>{
      'weak_questions': weakQs,
      'weak_lessons': [
        for (final l in top) {'lesson_id': l.id, 'path': l.path, 'attempts': l.attempts, 'accuracy_percent': l.accuracy},
      ],
    };
    if (weakQs.isEmpty && top.isEmpty) res['note'] = '还没有足够的作答记录，看不出薄弱点。';
    return res;
  }

  // ---- writing questions ----

  Future<Object?> _propose(ToolArgs a) async {
    final d = drafter!;
    final lessonId = _str(a, 'lesson_id');
    if (lessonId.isEmpty) throw ToolArgError('lesson_id 不能为空');
    final raw = a['questions'];
    final list = raw is List ? raw : const [];
    const maxPerCall = 5;
    if (list.isEmpty || list.length > maxPerCall) {
      throw ToolArgError('questions 需要 1 到 $maxPerCall 道题，收到 ${list.length} 道');
    }
    final qs = [
      for (final x in list)
        ProposedQuestion.fromJson(x is Map ? x.cast<String, dynamic>() : const <String, dynamic>{}),
    ];
    env.see([lessonId]);
    final results = await d.propose(lessonId, qs);
    final made = [for (final r in results) if (r.ok && r.draft != null) r.draft!];
    env.drafts.addAll(made);
    final res = <String, dynamic>{'results': [for (final r in results) r.toJson()]};
    if (made.isNotEmpty) res['note'] = '通过的题已经加入用户的题库，并作为卡片展示给用户（用户可取消采纳）。不要在回答里重复整道题的内容，简要说明即可。';
    return res;
  }

  Future<Object?> _listDrafts() async => {'drafts': [for (final d in await drafter!.drafts()) draftJson(d)]};
}
