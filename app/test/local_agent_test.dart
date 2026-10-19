import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/agent_api.dart';
import 'package:quizmind_app/data/agent_models.dart';
import 'package:quizmind_app/data/ai_config_store.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/data/local_agent/agent_spec.dart';
import 'package:quizmind_app/data/local_agent/agent_tools.dart';
import 'package:quizmind_app/data/local_agent/anthropic_chat.dart';
import 'package:quizmind_app/data/local_agent/library.dart';
import 'package:quizmind_app/data/local_agent/local_agent.dart';
import 'package:quizmind_app/data/local_agent/local_agent_api.dart';
import 'package:quizmind_app/data/local_agent/local_agent_store.dart';
import 'package:quizmind_app/data/local_agent/question_rules.dart';
import 'package:quizmind_app/data/local_agent/text_filters.dart';
import 'package:quizmind_app/data/models.dart';
import 'package:quizmind_app/data/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const quote = '读写锁允许多个读者同时持有锁，但写者必须独占整个资源。';
const lessonText = '读写锁是一种同步机制。$quote 因此读多写少的场景适合使用它。';

ProposedQuestion proposal({
  String stem = '关于读写锁的并发特性，下列哪项描述是正确的？',
  List<String> options = const ['多个读者可以同时持有读锁', '同一时刻只允许一个读者', '写者可以与读者并行执行', '读写锁不允许写者进入'],
  int answer = 0,
  String source = quote,
  String type = 'single',
}) =>
    ProposedQuestion(type: type, stem: stem, options: options, answerIndex: answer, explanation: '读写锁允许多个读者同时持有锁。', sourceQuote: source);

Map<String, dynamic> proposalJson(ProposedQuestion q) => {
      'type': q.type,
      'stem': q.stem,
      'options': q.options,
      'answer_index': q.answerIndex,
      'explanation': q.explanation,
      'difficulty': 2,
      'tags': ['锁'],
      'source_quote': q.sourceQuote,
    };

/// The moment the tools think it is.
final testNow = DateTime(2026, 10, 8, 12);
const hour = Duration(hours: 1);
const day = Duration(days: 1);
int msAgo(Duration d) => testNow.subtract(d).millisecondsSinceEpoch;

LocalAgentSpec testSpec({double dedupe = 0.8, int maxRounds = 8}) => LocalAgentSpec(
      version: 'v1',
      prompt: '你是助手',
      tools: [
        for (final n in ['list_outline', 'search_lessons', 'get_lesson', 'search_questions', 'pick_questions', 'get_weak_points', 'get_due_reviews', 'get_study_stats', 'get_question_detail', 'propose_questions', 'list_drafts'])
          AgentToolSpec(name: n, description: n, inputSchema: {'type': 'object', 'properties': {}}),
      ],
      model: const AgentModelConfig(baseUrl: 'https://llm.example/anthropic', apiKey: 'sk-x', model: 'm-1'),
      dedupeThreshold: dedupe,
      maxRounds: maxRounds,
    );

class MemLibrary implements AgentLibrary {
  MemLibrary({
    this.lessonList = const [],
    this.questionList = const [],
    this.attemptList = const [],
    this.stateList = const [],
    this.notes = const {},
  });

  final List<AgentLesson> lessonList;
  final List<AgentQuestion> questionList;
  final List<AgentAttempt> attemptList;
  final List<AgentState> stateList;
  final Map<String, String> notes;

  @override
  Future<List<AgentBank>> banks() async => const [AgentBank('b1', '题库')];
  @override
  Future<List<AgentLesson>> lessons() async => lessonList;
  @override
  Future<List<AgentQuestion>> questions() async => questionList;
  @override
  Future<List<AgentAttempt>> attempts() async => attemptList;
  @override
  Future<List<AgentState>> states() async => stateList;
  @override
  Future<String> note(String questionId) async => notes[questionId] ?? '';
}

AgentLesson lesson(String id, String title, String text, {String doc = 'd1'}) => AgentLesson(
    id: id, bankId: 'b1', documentId: doc, documentTitle: '讲义', headingPath: '讲义 > $title', text: text, documentOrder: 1);

AgentQuestion aq(String id, {String lessonId = 'L1', String stem = '题干'}) => AgentQuestion(
    id: id, bankId: 'b1', lessonId: lessonId, type: 'single', stem: '$stem $id', options: const ['甲', '乙', '丙', '丁'], answer: const [1], explanation: '解析', difficulty: 2);

/// A model that answers with scripted turns and records what it was asked.
/// A message's words without the `<context>` brief put in front of the learner's first one.
String unbrief(String text) => text.startsWith('<context>') ? text.substring(text.indexOf('</context>\n\n') + '</context>\n\n'.length) : text;

class ScriptedLlm implements AnthropicChat {
  ScriptedLlm(this.script);

  /// Called with the number of the turn and the messages so far.
  final ({List<String> text, List<LlmBlock> blocks, String stop}) Function(int n, List<LlmMessage> messages) script;
  final calls = <List<LlmMessage>>[];
  final systems = <List<String>>[];
  final toolCounts = <int>[];
  Object? error;

  @override
  Future<LlmTurn> converse({
    required AgentModelConfig config,
    required List<String> system,
    required List<LlmMessage> messages,
    required List<AgentToolSpec> tools,
    int maxTokens = 0,
    void Function(String text)? onText,
    CancelToken? cancel,
  }) async {
    final n = calls.length;
    calls.add([for (final m in messages) LlmMessage(m.role, [...m.blocks])]);
    systems.add(system);
    toolCounts.add(tools.length);
    if (error != null) throw error!;
    final t = script(n, messages);
    for (final s in t.text) {
      onText?.call(s);
    }
    return LlmTurn([
      if (t.text.isNotEmpty) LlmBlock.text(t.text.join()),
      ...t.blocks,
    ], t.stop, const LlmUsage(input: 10, output: 5));
  }
}

({List<String> text, List<LlmBlock> blocks, String stop}) say(String text) => (text: [text], blocks: const [], stop: 'end_turn');

({List<String> text, List<LlmBlock> blocks, String stop}) call(String id, String name, Map<String, dynamic> input, {String text = ''}) =>
    (text: text.isEmpty ? [] : [text], blocks: [LlmBlock.toolUse(toolUseId: id, toolName: name, toolInput: input)], stop: 'tool_use');

Future<List<AgentEvent>> drain(Stream<AgentEvent> s) => s.toList();

void main() {
  group('question rules', () {
    test('a good question passes, its options lose any A/B/C/D label', () {
      final v = validateQuestion(
          proposal(options: const ['A. 多个读者可以同时持有读锁', 'B、同一时刻只允许一个读者', '写者可以与读者并行执行', '读写锁不允许写者进入']), lessonText);
      expect(v.options.first, '多个读者可以同时持有读锁');
      expect(v.options[1], '同一时刻只允许一个读者');
      expect(v.difficulty, 3);
    });

    test('each rule says what to fix', () {
      String why(ProposedQuestion q) {
        try {
          validateQuestion(q, lessonText);
        } on RuleError catch (e) {
          return e.message;
        }
        return '';
      }

      expect(why(proposal(source: '这句话在讲义里根本不存在，是模型编出来的')), contains('source_quote'));
      expect(why(proposal(source: '读写锁')), contains('too short'));
      expect(why(proposal(stem: '根据上文，读写锁是什么？')), contains('stand'));
      expect(why(proposal(stem: '读写锁？')), contains('stem length'));
      expect(why(proposal(options: const ['甲甲', '乙乙', '丙丙'])), contains('4 options'));
      expect(why(proposal(options: const ['同一个选项', '同一个选项。', '丙丙丙', '丁丁丁'])), contains('duplicates'));
      expect(why(proposal(options: const ['以上都对', '乙乙乙', '丙丙丙', '丁丁丁'])), contains('catch-all'));
      expect(why(proposal(answer: 4)), contains('out of range'));
      expect(why(proposal(type: 'judge', answer: 2)), contains('0 or 1'));
      expect(why(proposal(type: 'essay')), contains('unsupported'));
    });

    test('a judge question gets the fixed options', () {
      final v = validateQuestion(proposal(type: 'judge', options: const [], answer: 1, stem: '读写锁允许多个读者同时持有锁。'), lessonText);
      expect(v.options, judgeOptions);
    });

    test('quotes and duplicates are compared without spacing, punctuation, case or full-width forms', () {
      expect(normalizeText('ＡＢＣ １２３，Foo bar。'), 'abc123foobar');
      final spaced = lessonText.replaceAll('，', ' ， ');
      expect(validateQuestion(proposal(), spaced).sourceQuote, quote);
    });

    test('the deduper finds exact and near duplicates, and leaves code questions to exact matching', () {
      final v = validateQuestion(proposal(), lessonText);
      final d = Deduper([ExistingQuestion('old', v.stem, v.options)], 0.8);
      expect(d.check('new', v), 'old');

      final other = validateQuestion(
          proposal(stem: '进程和线程之间最本质的区别在于什么？', options: const ['资源分配的单位不同', '只有名字不同', '线程更重量级', '进程不能并发']), lessonText);
      expect(Deduper([ExistingQuestion('old', v.stem, v.options)], 0.8).check('x', other), isNull);

      // A reworded stem with the same options is caught by the second rule.
      final reworded = validateQuestion(proposal(stem: '关于读写锁的并发特性，下面哪项描述是正确的？'), lessonText);
      expect(Deduper([ExistingQuestion('old', v.stem, v.options)], 0.8).check('r', reworded), 'old');

      // Within one batch the second copy is the duplicate.
      final batch = Deduper(const [], 0.8);
      expect(batch.check('a', v), isNull);
      expect(batch.check('b', v), 'a');

      final code = validateQuestion(proposal(stem: '补全下面的代码：\n```c\nint x = ?;\n```\n空白处应填什么？', options: const ['0', '1', '2', '3']), lessonText);
      final code2 = validateQuestion(proposal(stem: '补全下面的代码：\n```c\nint x = ?;\n```\n空白处应该填入什么？', options: const ['0', '1', '2', '4']), lessonText);
      expect(Deduper([ExistingQuestion('c1', code.stem, code.options)], 0.8).check('c2', code2), isNull);
    });
  });

  group('question rules, as the server has them', () {
    // The same cases the server runs (server/internal/pipeline/rules_golden_test.go): the two must agree.
    final golden = jsonDecode(File('../api/testdata/question_rules.json').readAsStringSync()) as Map<String, dynamic>;

    for (final c in (golden['validate'] as List).cast<Map<String, dynamic>>()) {
      test('validate: ${c['name']}', () {
        final q = ProposedQuestion.fromJson((c['question'] as Map).cast<String, dynamic>());
        final want = c['error'] as String;
        if (want.isNotEmpty) {
          expect(() => validateQuestion(q, golden['lesson'] as String), throwsA(isA<RuleError>().having((e) => e.message, 'message', contains(want))));
          return;
        }
        final v = validateQuestion(q, golden['lesson'] as String);
        if (c['options'] != null) expect(v.options, (c['options'] as List).cast<String>());
        if (c['tags'] != null) expect(v.tags, (c['tags'] as List).cast<String>());
        if (c['difficulty'] != null) expect(v.difficulty, c['difficulty']);
      });
    }

    for (final c in (golden['dedupe'] as List).cast<Map<String, dynamic>>()) {
      test('dedupe: ${c['name']}', () {
        ExistingQuestion existing(int i, Map<String, dynamic> e) => ExistingQuestion('e$i', e['stem'] as String, (e['options'] as List).cast<String>());
        final list = (c['existing'] as List).cast<Map<String, dynamic>>();
        final d = Deduper([for (var i = 0; i < list.length; i++) existing(i, list[i])], (c['threshold'] as num).toDouble());
        final cand = (c['candidate'] as Map).cast<String, dynamic>();
        final stem = cand['stem'] as String, options = (cand['options'] as List).cast<String>();
        final v = ValidQuestion(
            type: 'single', stem: stem, options: options, answerIndex: 0, explanation: '', difficulty: 3, tags: const [], sourceQuote: '', key: dedupeText(stem, options));
        expect(d.check('new', v) != null, c['duplicate']);
      });
    }
  });

  group('text filters', () {
    test('the link filter keeps links to things the assistant saw and drops the others, however the text is cut', () {
      for (final cut in [1, 3, 7, 100]) {
        final f = LinkFilter({'L1', 'q9'}.contains);
        final text = '见[读写锁](lesson:L1)，[假的](lesson:nope)、[题](question:q9)、[外链](https://x.y)和[括号]后面。';
        final out = StringBuffer();
        for (var i = 0; i < text.length; i += cut) {
          out.write(f.write(text.substring(i, math.min(text.length, i + cut))));
        }
        out.write(f.flush());
        expect(out.toString(), '见[读写锁](lesson:L1)，假的、[题](question:q9)、[外链](https://x.y)和[括号]后面。', reason: 'cut $cut');
      }
    });

    test('gateway noise is removed even when split across pieces', () {
      final f = NoiseFilter();
      final out = StringBuffer();
      for (final piece in ['你好<ds_', 'safety>内部</ds_safety>Sa', 'fe，世界<d', 'iv>']) {
        out.write(f.write(piece));
      }
      out.write(f.flush());
      expect(out.toString(), '你好，世界<div>');
      expect(stripNoise('A<ds_x>b</ds_x>SafeC'), 'AC');
    });
  });

  group('tools', () {
    test('search terms cut Chinese into pairs and keep Latin words whole', () {
      expect(searchTerms('进程调度'), ['进程调度', '进程', '程调', '调度']);
      expect(searchTerms('Mutex 锁'), ['mutex', '锁']);
      expect(searchTerms('  ，。 '), isEmpty);
    });

    ToolSet tools({
      List<AgentLesson>? lessons,
      List<AgentQuestion>? questions,
      List<AgentAttempt>? attempts,
      List<AgentState>? states,
      Map<String, String>? notes,
      String bank = '',
    }) =>
        ToolSet(
          ToolEnv(
            MemLibrary(
              lessonList: lessons ?? [],
              questionList: questions ?? [],
              attemptList: attempts ?? [],
              stateList: states ?? [],
              notes: notes ?? {},
            ),
            bank,
            clock: () => testNow,
          ),
          random: math.Random(1),
        );

    Future<Map<String, dynamic>> run(ToolSet t, String name, [Map<String, dynamic> args = const {}]) async {
      final (out, err) = await t.execute(name, args);
      expect(err, isFalse, reason: out);
      return jsonDecode(out) as Map<String, dynamic>;
    }

    test('search_lessons ranks heading hits above body hits and marks what it showed as known', () async {
      final t = tools(lessons: [
        lesson('L1', '概述', '讲义正文里提到死锁一次'),
        lesson('L2', '死锁', '这一节讲资源分配'),
        lesson('L3', '其他', '没有相关内容'),
      ]);
      final (out, err) = await t.execute('search_lessons', {'query': '死锁'});
      expect(err, isFalse);
      final j = jsonDecode(out) as Map;
      expect([for (final r in j['results']) r['lesson_id']], ['L2', 'L1']);
      expect(t.env.known('L2'), isTrue);
      expect(t.env.known('L3'), isFalse);
      expect(await t.label('search_lessons', {'query': '死锁'}), '在讲义里查找「死锁」');

      final (none, _) = await t.execute('search_lessons', {'query': '量子'});
      expect(jsonDecode(none)['note'], '讲义里没有找到相关内容。');
      final (bad, badErr) = await t.execute('search_lessons', {'query': '，'});
      expect((bad, badErr), ('query 不能为空', true));
    });

    test('get_lesson wraps the text as data, adds neighbours, and explains an unknown id', () async {
      final t = tools(lessons: [lesson('L1', 'A', '甲'), lesson('L2', 'B', '乙'), lesson('L3', 'C', '丙', doc: 'd2')]);
      final (out, _) = await t.execute('get_lesson', {'lesson_id': 'L2', 'with_neighbors': true});
      expect(out, startsWith('<lesson id="L2" path="讲义 > B">\n乙\n</lesson>'));
      expect(out, contains('上一节：讲义 > A（lesson_id=L1）'));
      expect(out, isNot(contains('下一节')), reason: 'the next section is of another document');
      expect(await t.label('get_lesson', {'lesson_id': 'L2'}), '读取讲义「B」');
      final (e, isErr) = await t.execute('get_lesson', {'lesson_id': 'nope'});
      expect(isErr, isTrue);
      expect(e, contains('没有 id 为 "nope" 的小节'));
    });

    test('pick_questions leaves out the answers and weak ones come from the answers given', () async {
      final qs = [aq('q1'), aq('q2'), aq('q3')];
      final attempts = [
        const AgentAttempt('q1', true),
        const AgentAttempt('q2', false),
        const AgentAttempt('q2', false),
        const AgentAttempt('q3', true),
      ];
      final t = tools(questions: qs, attempts: attempts);
      final (weak, _) = await t.execute('pick_questions', {'weak': true, 'count': 5});
      final w = jsonDecode(weak) as Map;
      expect([for (final q in w['questions']) q['question_id']], ['q2']);
      expect((w['questions'] as List).first.containsKey('answer_index'), isFalse);

      final (any, _) = await t.execute('pick_questions', {'count': 2});
      expect((jsonDecode(any)['questions'] as List).length, 2);
      final (emptyOut, _) = await tools().execute('pick_questions', {});
      expect(jsonDecode(emptyOut)['note'], '没有符合条件的题。');
    });

    test('get_weak_points lists questions and sections that went wrong', () async {
      final qs = [aq('q1', lessonId: 'L1'), aq('q2', lessonId: 'L1'), aq('q3', lessonId: 'L2')];
      final attempts = [
        const AgentAttempt('q1', false),
        const AgentAttempt('q2', true),
        const AgentAttempt('q1', false),
        const AgentAttempt('q3', true),
      ];
      final t = tools(lessons: [lesson('L1', '甲', 'x'), lesson('L2', '乙', 'y')], questions: qs, attempts: attempts);
      final j = jsonDecode((await t.execute('get_weak_points', {})).$1) as Map;
      expect([for (final q in j['weak_questions']) q['question_id']], ['q1']);
      expect(j['weak_lessons'], [
        {'lesson_id': 'L1', 'path': '讲义 > 甲', 'attempts': 3, 'accuracy_percent': 33},
      ]);
      final none = jsonDecode((await tools().execute('get_weak_points', {})).$1) as Map;
      expect(none['note'], '还没有足够的作答记录，看不出薄弱点。');
    });

    test('get_due_reviews lists the wrong book and the reviews that are due, the due ones first', () async {
      final qs = [aq('q1', lessonId: 'L2'), aq('q2', lessonId: 'L2'), aq('q3', lessonId: 'L3')];
      final t = tools(
        lessons: [lesson('L2', '乙', 'y'), lesson('L3', '丙', 'z')],
        questions: qs,
        attempts: [
          AgentAttempt('q1', false, at: msAgo(day * 3)),
          AgentAttempt('q1', false, at: msAgo(day * 2)),
          AgentAttempt('q1', true, at: msAgo(day)),
          for (var i = 3; i > 0; i--) AgentAttempt('q3', false, at: msAgo(day * i)),
        ],
        states: [
          const AgentState('q1', wrongCount: 2, streak: 0),
          AgentState('q2', wrongCount: 1, streak: 2, dueAt: msAgo(day * 3)), // out of the wrong book, but a review is due
          const AgentState('q3', wrongCount: 3, streak: 1),
          const AgentState('gone', wrongCount: 5), // a question that is no longer there
        ],
      );
      final j = await run(t, 'get_due_reviews');
      expect(j['due_count'], 3);
      expect(j['wrong_book_count'], 2, reason: 'q2 answered right twice in a row has left the wrong book');
      expect(j['scheduled_count'], 1);
      final items = j['questions'] as List;
      expect([for (final q in items) q['question_id']], ['q2', 'q3', 'q1']);
      expect(items[0]['reason'], 'scheduled');
      expect(items[0]['overdue_days'], 3);
      expect(items[1]['reason'], 'wrong_book');
      expect((j['lessons'] as List).first, {'lesson_id': 'L2', 'path': '讲义 > 乙', 'count': 2});
      expect(t.env.known('q3'), isTrue);
      expect(await t.label('get_due_reviews', {}), '查看待复习的题');
    });

    test('get_due_reviews says so when there is nothing to review, and only looks at the bank asked for', () async {
      final qs = [aq('q1')];
      final states = [const AgentState('q1', wrongCount: 1, streak: 2), const AgentState('q2', favorite: true)];
      final j = await run(tools(questions: qs, states: states), 'get_due_reviews');
      expect(j['due_count'], 0);
      expect(j['note'], contains('暂时没有需要复习的题'));

      final other = await run(tools(questions: qs, states: [const AgentState('q1', wrongCount: 1)]), 'get_due_reviews', {'bank_id': 'b2'});
      expect(other['due_count'], 0);
    });

    test('get_study_stats counts days, study time and the streak like the apps do', () async {
      final qs = [aq('q1'), aq('q2'), aq('q3')];
      final t = tools(questions: qs, states: const [AgentState('q3', wrongCount: 1)], attempts: [
        AgentAttempt('q1', false, at: msAgo(day * 10), durationMs: 5000),
        AgentAttempt('q1', true, at: msAgo(day), durationMs: 20000),
        AgentAttempt('q2', true, at: msAgo(hour * 2), durationMs: 30000, reviewMs: 60000),
        AgentAttempt('q3', false, at: msAgo(hour), durationMs: 600000, reviewMs: 600000), // capped at 2 + 3 minutes
        AgentAttempt('zz', true, at: msAgo(hour)), // not a published question
      ]);
      final j = await run(t, 'get_study_stats');
      expect(j['bank_questions'], 3);
      expect(j['answered_questions'], 3);
      expect(j['coverage_percent'], 100);
      expect(j['latest_correct'], 2, reason: 'q1 and q2 were right last; q3 was wrong');
      expect(j['wrong_book'], 1);
      expect(j['streak_days'], 2, reason: 'today and yesterday');
      expect(j['overall']['attempts'], 4);
      expect(j['period_days'], 7);
      expect(j['period'], {'attempts': 3, 'correct': 2, 'accuracy_percent': 67, 'active_days': 2, 'study_minutes': 7});
      expect(j['today'], {'attempts': 2, 'correct': 1, 'study_minutes': 7}, reason: '(30+60)s plus 2+3 minutes of the capped one');
      expect((j['daily'] as List).length, 2);

      final month = await run(t, 'get_study_stats', {'days': 30});
      expect(month['period']['attempts'], 4);
      expect(month['period']['active_days'], 3);
    });

    test('get_study_stats keeps a streak alive until today is over, and says when nothing was answered', () async {
      final qs = [aq('q1')];
      final j = await run(
        tools(questions: qs, attempts: [
          AgentAttempt('q1', true, at: msAgo(day)),
          AgentAttempt('q1', true, at: msAgo(day * 2)),
          AgentAttempt('q1', true, at: msAgo(day * 4)),
        ]),
        'get_study_stats',
      );
      expect(j['streak_days'], 2, reason: 'nothing yet today, but yesterday and the day before count');
      expect(j['today']['attempts'], 0);
      expect((await run(tools(questions: qs), 'get_study_stats'))['note'], '还没有作答记录。');
    });

    test('get_question_detail gives the answer and how the learner did on the question', () async {
      final t = tools(
        lessons: [lesson('L1', '甲', 'x')],
        questions: [aq('q1'), aq('q2')],
        attempts: [
          AgentAttempt('q1', false, at: msAgo(day * 3), selected: const [2], durationMs: 8000),
          AgentAttempt('q1', false, at: msAgo(day * 2), selected: const [2]),
          AgentAttempt('q1', false, at: msAgo(day), selected: const [0]),
          AgentAttempt('q1', true, at: msAgo(hour), selected: const [1]),
          AgentAttempt('q2', true, at: msAgo(hour), selected: const [1]),
        ],
        states: [AgentState('q1', favorite: true, wrongCount: 3, streak: 1, dueAt: msAgo(day * -2))],
        notes: {'q1': '这一题的要点'},
      );
      final j = await run(t, 'get_question_detail', {'question_id': 'q1'});
      expect(j['answer_index'], [1]);
      expect(j['explanation'], '解析');
      expect(j['lesson_id'], 'L1');
      expect(j['lesson_path'], '讲义 > 甲');
      expect(j['favorite'], isTrue);
      expect(j['in_wrong_book'], isTrue, reason: 'missed 3 times and only 1 right in a row');
      expect(j['review_due'], '2026-10-10');
      expect(j['ai_note'], '这一题的要点');
      final mine = j['mine'] as Map;
      expect(mine['attempts'], 4);
      expect(mine['correct'], 1);
      expect((mine['recent'] as List).first['correct'], isTrue, reason: 'newest first');
      expect((mine['recent'] as List).last['seconds'], 8);
      expect(mine['wrong_picks'], [
        {'option_index': 2, 'text': '丙', 'times': 2},
        {'option_index': 0, 'text': '甲', 'times': 1},
      ]);
      expect(t.env.known('q1'), isTrue);
      expect(await t.label('get_question_detail', {'question_id': 'q1'}), '查看题目详情');
    });

    test('get_question_detail for a question never answered, and for one that does not exist', () async {
      final t = tools(questions: [aq('q2')]);
      final j = await run(t, 'get_question_detail', {'question_id': 'q2'});
      expect(j['mine']['attempts'], 0);
      expect(j.containsKey('favorite'), isFalse, reason: 'a question the learner never touched has no state');
      expect(j.containsKey('ai_note'), isFalse);

      final (e, isErr) = await t.execute('get_question_detail', {'question_id': 'nope'});
      expect(isErr, isTrue);
      expect(e, contains('没有 id 为 "nope" 的题'));
      expect((await t.execute('get_question_detail', {})).$2, isTrue);
    });

    test('list_outline shows progress per section, and only chapters when there are too many', () async {
      final t = tools(
        lessons: [lesson('L1', '甲', 'x'), lesson('L2', '乙', 'y')],
        questions: [aq('q1', lessonId: 'L1'), aq('q2', lessonId: 'L1')],
        attempts: const [AgentAttempt('q1', true)],
      );
      final j = jsonDecode((await t.execute('list_outline', {})).$1) as Map;
      final doc = j['banks'][0]['documents'][0] as Map;
      expect(doc['lesson_count'], 2);
      expect(doc['lessons'][0], {
        'lesson_id': 'L1', 'title': '甲', 'path': '讲义 > 甲', 'questions': 2, 'answered': 1, 'latest_correct': 1,
      });

      final many = tools(lessons: [for (var i = 0; i < 201; i++) lesson('L$i', 'T$i', 'x')]);
      final big = jsonDecode((await many.execute('list_outline', {})).$1) as Map;
      expect(big['note'], contains('小节太多'));
      expect((big['banks'][0]['documents'][0] as Map).containsKey('lessons'), isFalse);
    });

    test('an unknown tool, a result that is too long, and a tool that breaks are all reported to the model', () async {
      final t = ToolSet(ToolEnv(MemLibrary(lessonList: [lesson('L1', 'A', '字' * 300)]), ''), maxResult: 100);
      final (e, isErr) = await t.execute('rm_rf', {});
      expect(isErr, isTrue);
      expect(e, contains('没有名为 "rm_rf" 的工具'));
      final (long, _) = await t.execute('get_lesson', {'lesson_id': 'L1'});
      expect(long, endsWith('…（已截断，请缩小范围）'));
      expect(t.has('propose_questions'), isFalse, reason: 'no drafter: the assistant cannot write questions');
    });
  });

  group('the Anthropic client', () {
    String ev(Map<String, dynamic> j) => 'data: ${jsonEncode(j)}\n\n';

    Stream<Uint8List> body(List<String> parts) => Stream.fromIterable([for (final p in parts) Uint8List.fromList(utf8.encode(p))]);

    test('reads text, thinking and a tool call from a stream, and says what it was asked', () async {
      final adapter = _Adapter((o) => ResponseBody(
            body([
              ev({'type': 'message_start', 'message': {'usage': {'input_tokens': 20, 'cache_read_input_tokens': 7, 'output_tokens': 1}}}),
              ': ping\n\n',
              ev({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}}),
              ev({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': '想一想'}}),
              ev({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'sig'}}),
              ev({'type': 'content_block_stop', 'index': 0}),
              ev({'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'text', 'text': ''}}),
              ev({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': '先查一下<ds_s'}}),
              ev({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'afety>x</ds_safety>Safe。'}}),
              ev({'type': 'content_block_stop', 'index': 1}),
              ev({'type': 'content_block_start', 'index': 2, 'content_block': {'type': 'tool_use', 'id': 'tu1', 'name': 'get_lesson', 'input': {}}}),
              ev({'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': '{"lesson_'}}),
              ev({'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': 'id":"L1"}'}}),
              ev({'type': 'content_block_stop', 'index': 2}),
              ev({'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}, 'usage': {'output_tokens': 33}}),
              ev({'type': 'message_stop'}),
            ]),
            200,
            headers: {'content-type': ['text/event-stream']},
          ));
      final chat = HttpAnthropicChat(dio: Dio()..httpClientAdapter = adapter);
      final shown = StringBuffer();
      final turn = await chat.converse(
        config: const AgentModelConfig(baseUrl: 'https://llm.example/anthropic/', apiKey: 'sk-1', model: 'm-1', effort: 'low'),
        system: ['稳定部分', '变化部分'],
        messages: [LlmMessage.text('user', '你好')],
        tools: const [AgentToolSpec(name: 'get_lesson', description: 'd', inputSchema: {'type': 'object', 'properties': {}})],
        onText: shown.write,
      );
      expect(shown.toString(), '先查一下。');
      expect(turn.stopReason, 'tool_use');
      expect(turn.blocks.map((b) => b.kind), [BlockKind.thinking, BlockKind.text, BlockKind.toolUse]);
      expect(turn.blocks[0].signature, 'sig');
      expect(turn.blocks[1].text, '先查一下。');
      expect(turn.toolCalls.single.toolInput, {'lesson_id': 'L1'});
      expect((turn.usage.input, turn.usage.output, turn.usage.cached), (20, 33, 7));

      final req = adapter.last!;
      expect(req.uri.toString(), 'https://llm.example/anthropic/v1/messages'.replaceFirst('anthropic//', 'anthropic/'));
      expect(req.headers['x-api-key'], 'sk-1');
      expect(req.headers['anthropic-version'], '2023-06-01');
      final b = req.data as Map;
      expect(b['model'], 'm-1');
      expect(b['stream'], true);
      expect(b['output_config'], {'effort': 'low'});
      expect(b['system'][0]['cache_control'], {'type': 'ephemeral'});
      expect(b['system'][1].containsKey('cache_control'), isFalse);
      expect(b.containsKey('tool_choice'), isFalse);
      expect(b['tools'][0]['name'], 'get_lesson');
    });

    test('a tool call cut off by max_tokens is dropped; an error event and an error status are explained', () async {
      Future<LlmTurn> run(ResponseBody Function(RequestOptions) respond) => HttpAnthropicChat(dio: Dio()..httpClientAdapter = _Adapter(respond)).converse(
            config: const AgentModelConfig(baseUrl: 'https://llm.example', apiKey: 'k', model: 'm'),
            system: const ['s'],
            messages: [LlmMessage.text('user', 'q')],
            tools: const [],
          );

      final cut = await run((_) => ResponseBody(
            body([
              ev({'type': 'message_start', 'message': {'usage': {}}}),
              ev({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 't', 'name': 'x', 'input': {}}}),
              ev({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"a'}}),
              ev({'type': 'message_delta', 'delta': {'stop_reason': 'max_tokens'}, 'usage': {'output_tokens': 4}}),
            ]),
            200,
          ));
      expect(cut.stopReason, 'max_tokens');
      expect(cut.toolCalls, isEmpty);

      await expectLater(
        run((_) => ResponseBody(body([ev({'type': 'error', 'error': {'message': 'overloaded'}})]), 200)),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', contains('overloaded'))),
      );
      await expectLater(
        run((_) => ResponseBody.fromString(jsonEncode({'error': {'message': 'bad key'}}), 401)),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', allOf(contains('密钥'), contains('bad key')))),
      );
      await expectLater(
        run((_) => ResponseBody(body(const []), 200)),
        throwsA(isA<AgentException>().having((e) => e.message, 'message', contains('没有返回内容'))),
      );
    });
  });

  group('the assistant on the device', () {
    late AppDatabase db;
    late LocalAgentStore store;

    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      store = LocalAgentStore(db);
      await db.into(db.banks).insert(BanksCompanion.insert(id: 'b1', title: '题库'));
      await addLesson(db, 'L1', title: '读写锁', body: lessonText);
    });

    LocalAgent agent(ScriptedLlm llm, {List<AiUsage>? usage, LocalAgentSpec? spec, math.Random? random}) {
      var n = 0;
      return LocalAgent(
        spec: spec ?? testSpec(),
        chat: llm,
        library: DbAgentLibrary(db),
        store: store,
        reportUsage: usage?.add,
        newId: () => 'U${n++}',
      );
    }

    AgentChatRequest request(String text, {String conv = 'c1', List<AgentHistoryMessage> history = const [], AgentContext context = const AgentContext()}) =>
        AgentChatRequest(conversationId: conv, deviceId: 'dev', message: text, history: history, context: context);

    test('the library on the device reads answers with their times, the wrong book with its streak, and AI notes', () async {
      await db.into(db.attempts).insert(AttemptsCompanion.insert(
          id: 'a1', questionId: 'q1', deviceId: 'dev', answerJson: '[2]', isCorrect: false, durationMs: const Value(8000), reviewMs: const Value(15000), answeredAt: 2000));
      await db.into(db.attempts).insert(
          AttemptsCompanion.insert(id: 'a0', questionId: 'q1', deviceId: 'dev', answerJson: 'broken', isCorrect: true, answeredAt: 1000));
      await db.into(db.questionStates).insert(QuestionStatesCompanion.insert(
          questionId: 'q1', fsrsJson: const Value('{"v":1,"streak":1,"last":2000}'), dueAt: const Value(5000), favorite: const Value(true), wrongCount: const Value(2), updatedAt: 1));
      await db.into(db.questionStates).insert(QuestionStatesCompanion.insert(questionId: 'q2', updatedAt: 1));
      await db.into(db.aiNotes).insert(AiNotesCompanion.insert(questionId: 'q1', content: '要点', updatedAt: 1));

      final lib = DbAgentLibrary(db);
      final attempts = await lib.attempts();
      expect([for (final a in attempts) a.at], [1000, 2000], reason: 'oldest first');
      expect(attempts[0].selected, isEmpty, reason: 'an unreadable answer is no answer');
      expect((attempts[0].durationMs, attempts[0].reviewMs), (0, 0));
      expect(attempts[1].selected, [2]);
      expect((attempts[1].durationMs, attempts[1].reviewMs, attempts[1].correct), (8000, 15000, false));

      final states = {for (final s in await lib.states()) s.questionId: s};
      expect((states['q1']!.streak, states['q1']!.dueAt, states['q1']!.favorite, states['q1']!.wrongCount), (1, 5000, true, 2));
      expect(states['q1']!.inWrongBook, isTrue);
      expect((states['q2']!.streak, states['q2']!.dueAt, states['q2']!.inWrongBook), (0, 0, false));

      expect(await lib.note('q1'), '要点');
      expect(await lib.note('q2'), '');
    });

    test('answers by looking things up, writes a question into the bank, and keeps the conversation', () async {
      final llm = ScriptedLlm((n, msgs) => switch (n) {
            0 => call('t1', 'search_lessons', {'query': '读写锁'}, text: '我先查一下。'),
            1 => call('t2', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal())]}),
            _ => say('出了一道题，依据[读写锁](lesson:L1)，另见[不存在](lesson:bogus)。'),
          });
      final usage = <AiUsage>[];
      final events = await drain(agent(llm, usage: usage).run(request('用读写锁那一节出一道题')));

      expect(events.first, isA<AgentLocalEvent>());
      expect(events[1], isA<AgentStarted>());
      final text = events.whereType<AgentDelta>().map((e) => e.text).join();
      expect(text, '我先查一下。出了一道题，依据[读写锁](lesson:L1)，另见不存在。');
      final tools = events.whereType<AgentToolEvent>().map((e) => '${e.name}:${e.status}:${e.label}').toList();
      expect(tools, [
        'search_lessons:running:在讲义里查找「读写锁」',
        'search_lessons:done:在讲义里查找「读写锁」',
        'propose_questions:running:生成题目草稿',
        'propose_questions:done:生成题目草稿',
      ]);
      final drafts = events.whereType<AgentDraftsEvent>().single.drafts;
      expect(drafts.single.adopted, isTrue);
      expect(drafts.single.lessonId, 'L1');
      expect(events.last, isA<AgentDone>().having((d) => d.stop, 'stop', 'end_turn').having((d) => d.outputTokens, 'out', 15));

      // The question is in the bank on this device at once, waiting to be uploaded.
      final q = (await store.question(drafts.single.id))!;
      expect((q.localState, q.hidden, q.bankId, q.chunkId, q.agentConv, q.syncSeq), (LocalState.pending, false, 'b1', 'L1', 'c1', 0));
      expect(q.documentTitle, '讲义');
      expect(jsonDecode(q.answerJson), [0]);
      expect([for (final x in await DbAgentLibrary(db).questions()) x.id], [q.id]);

      // The model was shown the tools' results; the instructions are one fixed text, and the day is in the learner's first words.
      final secondTurn = llm.calls[1].last.blocks.single;
      expect(secondTurn.kind, BlockKind.toolResult);
      expect(secondTurn.text, contains('"lesson_id":"L1"'));
      expect(llm.systems.first[0], '你是助手');
      expect(llm.systems.first, ['你是助手']);
      expect(llm.calls.first.first.blocks.single.text, matches(RegExp(r'^<context>\n对话开始于 \d{4}年\d{1,2}月\d{1,2}日。\n</context>\n\n')));
      expect(llm.toolCounts.first, 11);

      // The conversation is kept for the history page, with its card.
      final saved = (await store.conversation('c1'))!;
      expect(saved.item.title, '用读写锁那一节出一道题');
      expect(saved.messages.map((m) => m.role), ['user', 'assistant']);
      expect(saved.messages.last.text, text);
      expect(saved.messages.last.tools.map((t) => t.status), ['done', 'done']);
      expect(saved.messages.last.drafts.single.phase, StoredDraftPhase.accepted);

      // Every model call is reported, as the assistant's.
      expect(usage.map((u) => (u.role, u.questionId, u.model, u.ok)), List.filled(3, ('agent', 'c1', 'm-1', true)));
    });

    test('a question is refused with a reason the model can act on, then fixed', () async {
      final results = <String>[];
      final llm = ScriptedLlm((n, msgs) {
        if (n > 0) results.add(msgs.last.blocks.single.text);
        return switch (n) {
          0 => call('t1', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal(source: '这句话讲义里根本没有，是编的'))]}),
          1 => call('t2', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal())]}),
          2 => call('t3', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal())]}),
          _ => say('好了'),
        };
      });
      final events = await drain(agent(llm).run(request('出一道题')));
      expect(results[0], contains('source_quote 在这一节原文里找不到'));
      expect(jsonDecode(results[1])['results'][0]['ok'], isTrue);
      expect(jsonDecode(results[2])['results'][0]['error'], contains('与已有题目重复'));
      expect(events.whereType<AgentDraftsEvent>().length, 1, reason: 'only the call that made a question shows a card');
      expect((await store.conversationQuestions('c1')).length, 1);
    });

    test('a replaced question is taken back, a section that does not exist and the limit are explained', () async {
      final ids = <String>[];
      final texts = <String>[];
      final llm = ScriptedLlm((n, msgs) {
        if (n > 0) texts.add(msgs.last.blocks.single.text);
        if (n == 1) ids.add(jsonDecode(texts.last)['results'][0]['draft_id'] as String);
        return switch (n) {
          0 => call('t1', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal())]}),
          1 => call('t2', 'propose_questions', {
              'lesson_id': 'L1',
              'questions': [
                {...proposalJson(proposal(stem: '读写锁允许多个读者同时持有锁吗？', type: 'judge', options: const [], answer: 0)), 'replaces': ids.last}
              ],
            }),
          2 => call('t3', 'propose_questions', {'lesson_id': 'nope', 'questions': [proposalJson(proposal())]}),
          3 => call('t4', 'list_drafts', {}),
          _ => say('完成'),
        };
      });
      await drain(agent(llm).run(request('出一道题，再改成判断题')));
      final rows = await store.conversationQuestions('c1');
      expect(rows.length, 2);
      expect(rows.where((r) => r.hidden).map((r) => r.id), [ids.single], reason: 'the old question was taken back');
      expect(jsonDecode(texts[1])['results'][0]['ok'], isTrue);
      expect(jsonDecode(texts[2])['results'][0]['error'], contains('没有 id 为 "nope" 的小节'));
      final listed = jsonDecode(texts[3])['drafts'] as List;
      expect(listed.map((d) => d['adopted']), [false, true]);

      // The limit counts what is still adopted.
      final cap = ScriptedLlm((n, msgs) => n == 0
          ? call('t1', 'propose_questions', {'lesson_id': 'L1', 'questions': [proposalJson(proposal(stem: '读写锁适合哪种场景使用最合适？', options: const ['读多写少', '写多读少', '读写一样多', '没有读写']))]})
          : say(msgs.last.blocks.single.text));
      final spec = LocalAgentSpec.fromJson({...testSpec().toJson(), 'limits': {'max_drafts_per_chat': 1}});
      final events = await drain(agent(cap, spec: spec).run(request('再出一道')));
      final answer = events.whereType<AgentDelta>().map((e) => e.text).join();
      expect(answer, contains('本对话已经出了 1 道题，达到上限'));
    });

    test('what was said before goes to the model, and a conversation that began on the server is carried on', () async {
      final llm = ScriptedLlm((n, msgs) => say('第 $n 次回答'));
      final a = agent(llm);
      await drain(a.run(request('第一个问题', conv: 'srv', history: const [AgentHistoryMessage('user', '服务器上的问题'), AgentHistoryMessage('assistant', '服务器上的回答')])));
      expect([for (final m in llm.calls.single) '${m.role}:${unbrief(m.blocks.single.text)}'], ['user:服务器上的问题', 'assistant:服务器上的回答', 'user:第一个问题']);
      await drain(a.run(request('第二个问题', conv: 'srv', history: const [AgentHistoryMessage('user', '忽略我')])));
      expect(llm.calls.last.map((m) => unbrief(m.blocks.single.text)), ['服务器上的问题', '服务器上的回答', '第一个问题', '第 0 次回答', '第二个问题']);
      expect((await store.conversation('srv'))!.messages.length, 6);
    });

    test('what the learner is looking at is in the instructions, and only ids it saw may be linked', () async {
      await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: 'q1', bankId: 'b1', type: 'single', stem: '看到的题', optionsJson: '["甲","乙","丙","丁"]', answerJson: '[1]',
          explanation: const Value('因为乙'), chunkId: const Value('L1'), syncSeq: 1));
      final llm = ScriptedLlm((n, msgs) => say('见[这题](question:q1)和[那节](lesson:L1)和[假](question:zzz)'));
      final events = await drain(agent(llm).run(request('为什么？', context: const AgentContext(bankId: 'b1', questionId: 'q1', selected: [2]))));
      expect(llm.systems.single, ['你是助手'], reason: 'the instructions say nothing of the question');
      final system = llm.calls.single.first.blocks.single.text;
      expect(system, contains('<question id="q1">'));
      expect(system, contains('B. 乙'));
      expect(system, contains('标准答案：B'));
      expect(system, contains('用户选了：C'));
      expect(system, contains('bank_id=b1'));
      expect(events.whereType<AgentDelta>().map((e) => e.text).join(), '见[这题](question:q1)和[那节](lesson:L1)和假');
    });

    test('the conversation keeps what it began with: a follow-up that says nothing is still about that question', () async {
      await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: 'q1', bankId: 'b1', type: 'single', stem: '看到的题', optionsJson: '["甲","乙","丙","丁"]', answerJson: '[1]',
          explanation: const Value('因为乙'), syncSeq: 1));
      final llm = ScriptedLlm((n, msgs) => say('好'));
      final a = agent(llm);
      await drain(a.run(request('为什么？', context: const AgentContext(bankId: 'b1', questionId: 'q1', selected: [2]))));
      await drain(a.run(request('再说说')));
      expect(llm.calls, hasLength(2));
      for (final call in llm.calls) {
        final first = call.first.blocks.single.text;
        expect(first, contains('<question id="q1">'));
        expect(first, contains('用户选了：C'));
        expect(first, contains('bank_id=b1'));
        expect(first, endsWith('为什么？'), reason: 'their own words come after the brief');
      }
      expect(llm.calls.last, hasLength(3), reason: 'no second copy of the question');
      expect((await store.contextOf('c1'))!.questionId, 'q1');
    });

    test('out of rounds, the model is asked once more with the tools still declared; a refusal, a failure and a stop are told', () async {
      final llm = ScriptedLlm((n, msgs) => n < 2 ? call('t$n', 'list_outline', {}) : say('只能先答到这里'));
      final events = await drain(agent(llm, spec: LocalAgentSpec.fromJson({...testSpec().toJson(), 'limits': {'max_rounds': 2}})).run(request('讲讲')));
      expect(llm.toolCounts, [11, 11, 11], reason: 'the tools stay, so the cached start of the request does too');
      expect(llm.calls.last.last.blocks.last.text, contains('请不要再调用工具'));
      expect(events.last, isA<AgentDone>().having((d) => d.stop, 'stop', 'max_rounds'));
      expect((await store.conversation('c1'))!.messages.last.note, '查了很多资料，只能先答到这里');

      final refuse = ScriptedLlm((n, _) => (text: const [], blocks: const [], stop: 'refusal'));
      final r = await drain(agent(refuse).run(request('x', conv: 'c2')));
      expect(r.last, isA<AgentErrorEvent>().having((e) => e.code, 'code', 'refused'));

      final broken = ScriptedLlm((n, _) => say(''))..error = AgentException('连不上模型服务，请检查网络', code: 'unavailable', unreachable: true);
      final usage = <AiUsage>[];
      final b = await drain(agent(broken, usage: usage).run(request('x', conv: 'c3')));
      expect(b.last, isA<AgentErrorEvent>().having((e) => e.message, 'message', contains('连不上模型')));
      expect((await store.conversation('c3'))!.messages.last.error, contains('连不上模型'));
      expect(usage.single.ok, isFalse);

      final token = CancelToken()..cancel();
      final stopped = ScriptedLlm((n, _) => say(''))..error = AgentException('已停止');
      await expectLater(agent(stopped).run(request('x', conv: 'c4'), cancel: token), emitsInOrder([isA<AgentLocalEvent>(), isA<AgentStarted>(), emitsError(isA<AgentException>())]));
      expect((await store.conversation('c4'))!.messages.last.note, '已停止');
    });

    test('a model that keeps calling tools after the nudge gets a turn without them', () async {
      final llm = ScriptedLlm((n, msgs) => n < 3 ? call('t$n', 'list_outline', {}) : say('只能先答到这里'));
      await drain(agent(llm, spec: LocalAgentSpec.fromJson({...testSpec().toJson(), 'limits': {'max_rounds': 2}})).run(request('讲讲')));
      expect(llm.toolCounts, [11, 11, 11, 0]);
    });

    test('links of earlier answers may be written again', () async {
      await store.ensureConversation(id: 'c1', mode: '', bankId: '', lessonId: '', questionId: '', firstText: '讲讲');
      await store.appendMessage('c1', 'user', text: '讲讲');
      await store.appendMessage('c1', 'assistant', text: '见[那一节](lesson:L1)。');
      final llm = ScriptedLlm((n, msgs) => say('还是[那一节](lesson:L1)，不是[这个](lesson:NOPE)。'));
      final events = await drain(agent(llm).run(request('再讲讲')));
      expect(events.whereType<AgentDelta>().map((d) => d.text).join(), '还是[那一节](lesson:L1)，不是这个。');
    });

    test('a tool that takes too long is cut off and the model is told', () async {
      final slow = _SlowLibrary();
      final llm = ScriptedLlm((n, msgs) => n == 0 ? call('t', 'list_outline', {}) : say(msgs.last.blocks.single.text));
      final a = LocalAgent(spec: testSpec(), chat: llm, library: slow, store: store, toolTimeout: const Duration(milliseconds: 20));
      final events = await drain(a.run(request('x')));
      expect(events.whereType<AgentToolEvent>().last.status, 'error');
      expect(events.whereType<AgentDelta>().map((e) => e.text).join(), contains('工具执行超时'));
    });
  });

  group('the local store', () {
    late AppDatabase db;
    late LocalAgentStore store;
    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      store = LocalAgentStore(db);
    });

    Future<void> question(String id, {String state = '', bool hidden = false, String conv = ''}) =>
        db.into(db.questions).insert(QuestionsCompanion.insert(
            id: id, bankId: 'b1', type: 'single', stem: '题干 $id', optionsJson: '["甲","乙","丙","丁"]', answerJson: '[1]',
            syncSeq: 1, localState: Value(state), hidden: Value(hidden), agentConv: Value(conv)));

    test('taking back a question: one not sent yet is just hidden, one the server has waits to be told, a refused one stays refused', () async {
      await question('p', state: LocalState.pending);
      await question('s');
      await question('r', state: LocalState.refused);
      await store.decide('p', adopt: false);
      await store.decide('s', adopt: false);
      var p = (await store.question('p'))!, s = (await store.question('s'))!;
      expect((p.hidden, p.localState), (true, LocalState.pending));
      expect((s.hidden, s.localState), (true, LocalState.discard));
      await store.decide('s', adopt: true);
      s = (await store.question('s'))!;
      expect((s.hidden, s.localState), (false, LocalState.adopt));
      await expectLater(store.decide('r', adopt: true), throwsA(isA<AgentException>()));
      await expectLater(store.decide('zzz', adopt: true), throwsA(isA<AgentException>().having((e) => e.status, 'status', 404)));
    });

    test('the history is cut to the latest messages that fit, and starts with the learner', () async {
      await store.ensureConversation(id: 'c', mode: '', bankId: '', lessonId: '', questionId: '', firstText: '开头');
      for (var i = 0; i < 40; i++) {
        await store.appendMessage('c', i.isEven ? 'user' : 'assistant', text: '消息 $i');
      }
      await store.appendMessage('c', 'assistant', text: '', error: '失败了');
      final h = await store.history('c');
      expect(h.first.role, 'user');
      expect(h.length, lessThanOrEqualTo(30));
      expect(h.last.text, '消息 39');
      expect(h.first.text, '消息 10');

      await store.appendMessage('c', 'user', text: '字' * 30000);
      final lone = await store.history('c');
      expect(lone.single.text.length, 30000, reason: 'the newest message is kept however long, as on the server');
    });

    test('conversations are listed newest first and can be deleted without losing their questions', () async {
      for (final id in ['a', 'b']) {
        await store.ensureConversation(id: id, mode: '', bankId: 'b1', lessonId: '', questionId: '', firstText: '问题 $id');
        await store.appendMessage(id, 'user', text: '问题 $id');
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      await question('w', conv: 'a');
      final page = await store.conversations();
      expect(page.items.map((c) => c.id), ['b', 'a']);
      expect(page.items.first.messageCount, 1);
      await store.deleteConversation('a');
      expect((await store.conversations()).items.map((c) => c.id), ['b']);
      expect(await store.question('w'), isNotNull);
    });
  });

  group('server first, this device when the server cannot be reached', () {
    late AppDatabase db;
    late LocalAgentStore store;
    late _FakeServerApi server;
    late ScriptedLlm llm;
    late HybridAgentApi api;
    var now = DateTime(2026, 10, 16, 12);

    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      store = LocalAgentStore(db);
      await addLesson(db, 'L1', title: '读写锁', body: lessonText);
      server = _FakeServerApi();
      llm = ScriptedLlm((n, _) => say('本机的回答'));
      now = DateTime(2026, 10, 16, 12);
      api = _hybrid(server, db, store, llm, () => now);
    });

    test('with the server up nothing changes: its answer, its status, no local event', () async {
      server.events = [const AgentStarted('c1'), const AgentDelta('服务器的回答'), const AgentDone(stop: 'end_turn')];
      final events = await drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'q')));
      expect(events.whereType<AgentDelta>().single.text, '服务器的回答');
      expect(events.whereType<AgentLocalEvent>(), isEmpty);
      expect(llm.calls, isEmpty);
      expect((await api.status()).local, isFalse);
    });

    test('a server that cannot be reached hands the question to the assistant here, which is not retried at once', () async {
      server.chatError = AgentException('连不上服务器', unreachable: true);
      server.statusError = AgentException('连不上服务器', unreachable: true);
      final events = await drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'q')));
      expect(events.first, isA<AgentLocalEvent>());
      expect(events.whereType<AgentDelta>().single.text, '本机的回答');
      expect(server.chatCalls, 1);

      await drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'again')));
      expect(server.chatCalls, 1, reason: 'the server is not tried again for a minute');
      final status = await api.status();
      expect((status.local, status.available, status.model), (true, true, 'm-1'));
      expect(server.statusCalls, 0);

      now = now.add(const Duration(minutes: 2));
      server.chatError = null;
      server.statusError = null;
      server.events = [const AgentStarted('c1'), const AgentDone(stop: 'end_turn')];
      await drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'later')));
      expect(server.chatCalls, 2, reason: 'a minute later the server is asked again');
      expect((await api.status()).local, isFalse);
    });

    test('a server that answers with a refusal, or breaks off mid-answer, is not replaced', () async {
      server.chatError = AgentException('访问令牌不对', status: 401);
      await expectLater(drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'q'))), throwsA(isA<AgentException>().having((e) => e.status, 'status', 401)));
      server.chatError = null;
      server.events = [const AgentStarted('c1'), const AgentDelta('一半')];
      server.endWith = AgentException('网络中断了，请重试', unreachable: true);
      await expectLater(drain(api.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'q'))), throwsA(isA<AgentException>()));
      expect(llm.calls, isEmpty);
    });

    test('with no configuration on the device there is nothing to fall back on', () async {
      final bare = HybridAgentApi(server: server, local: LocalAgentApi(store: store, library: DbAgentLibrary(db), specOf: () => null, llm: llm));
      server.chatError = AgentException('连不上服务器', unreachable: true);
      await expectLater(drain(bare.chat(AgentChatRequest(conversationId: 'c1', deviceId: 'd', message: 'q'))), throwsA(isA<AgentException>().having((e) => e.unreachable, 'unreachable', isTrue)));
      server.statusError = AgentException('连不上服务器', unreachable: true);
      await expectLater(bare.status(), throwsA(isA<AgentException>()));
    });

    test('history is both: the server\'s list with this device\'s, and a conversation is read where it is kept', () async {
      server.keep('s1', 5);
      await drain(api.chat(AgentChatRequest(conversationId: 'srv', deviceId: 'd', message: 'q')));
      server.chatError = AgentException('x', unreachable: true);
      await drain(api.chat(AgentChatRequest(conversationId: 'loc', deviceId: 'd', message: '离线问题')));
      final both = await api.conversations();
      expect(both.items.map((c) => c.id).toSet(), {'s1', 'loc'});
      expect((await api.conversation('loc')).messages.last.text, '本机的回答');
      expect((await api.conversation('s1')).item.id, 's1');

      server.listError = AgentException('连不上服务器', unreachable: true);
      expect((await api.conversations()).items.map((c) => c.id), ['loc']);
      await store.deleteConversation('loc');
      await expectLater(api.conversations(), throwsA(isA<AgentException>()));

      await api.deleteConversation('s1');
      expect(server.deleted, ['s1']);
    });

    test('adopting and taking back: a question not sent yet is decided here, others go to the server, and wait when it is out of reach', () async {
      await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: 'pend', bankId: 'b1', type: 'single', stem: 'p', optionsJson: '[]', answerJson: '[0]', syncSeq: 0, localState: const Value(LocalState.pending)));
      await db.into(db.questions).insert(QuestionsCompanion.insert(
          id: 'known', bankId: 'b1', type: 'single', stem: 'k', optionsJson: '[]', answerJson: '[0]', syncSeq: 4));

      await api.discardDraft('pend');
      expect(server.decided, isEmpty);
      expect((await store.question('pend'))!.hidden, isTrue);

      await api.discardDraft('known');
      expect(server.decided, {'known': false});
      expect((await store.question('known'))!.hidden, isFalse, reason: 'the sync brings the change back');

      server.decideError = AgentException('连不上服务器', unreachable: true);
      await api.discardDraft('known');
      var k = (await store.question('known'))!;
      expect((k.hidden, k.localState), (true, LocalState.discard));
      server.decideError = null;
      await api.acceptDraft('known');
      k = (await store.question('known'))!;
      expect((k.hidden, k.localState), (false, ''), reason: 'told now, so nothing waits');
      expect(server.decided, {'known': true});

      server.decideError = AgentException('访问令牌不对', status: 401);
      await expectLater(api.discardDraft('known'), throwsA(isA<AgentException>()));
      expect((await store.question('known'))!.hidden, isFalse);
    });
  });

  group('sync of what the assistant wrote here', () {
    late AppDatabase db;
    late FakeApi api;
    late AiConfigStore ai;
    late AgentSpecStore specs;

    setUp(() async {
      db = memoryDb();
      addTearDown(db.close);
      api = FakeApi();
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ai = AiConfigStore(prefs);
      await ai.setToken('tok');
      specs = AgentSpecStore(prefs);
    });

    SyncService service() => SyncService(db, api, aiConfig: ai, agentSpec: specs, deviceId: 'dev');

    Future<void> written(String id, {String state = LocalState.pending, bool hidden = false}) =>
        db.into(db.questions).insert(QuestionsCompanion.insert(
            id: id, bankId: 'b1', type: 'single', stem: '题干 $id', optionsJson: '["甲","乙","丙","丁"]', answerJson: '[2]',
            explanation: const Value('解析'), tagsJson: const Value('["锁"]'), sourceQuote: const Value('原文引用'),
            chunkId: const Value('L1'), syncSeq: 0, localState: Value(state), hidden: Value(hidden), agentConv: const Value('conv-1')));

    test('the questions go up before the answers to them, and each comes back as the server judged it', () async {
      await written('ok');
      await written('review');
      await written('bad');
      await written('taken-back', hidden: true);
      api.agentRefusals['bad'] = '与已有题目重复';
      api.agentStatus['review'] = 'needs_review';
      await specs.save(testSpec());
      await db.into(db.attempts).insert(AttemptsCompanion.insert(
          id: 'a1', questionId: 'ok', deviceId: 'dev', answerJson: '[2]', isCorrect: true, answeredAt: 5));

      final report = await service().run();
      expect(api.uploadedAgentQuestions.map((q) => q.id), ['bad', 'ok', 'review'], reason: 'the one the learner took back is not sent');
      final up = api.uploadedAgentQuestions.firstWhere((q) => q.id == 'ok');
      expect((up.lessonId, up.conversationId, up.deviceId, up.model, up.answerIndex, up.sourceQuote), ('L1', 'conv-1', 'dev', 'm-1', 2, '原文引用'));
      expect(up.tags, ['锁']);
      expect(api.uploadedAttempts.map((a) => a.questionId), ['ok']);

      Future<Question> row(String id) => (db.select(db.questions)..where((q) => q.id.equals(id))).getSingle();
      var ok = await row('ok'), review = await row('review'), bad = await row('bad');
      expect((ok.localState, ok.hidden), ('', false));
      expect((review.localState, review.hidden), ('', true), reason: 'in the review queue: not in the bank until published');
      expect((bad.localState, bad.hidden, bad.localNote), (LocalState.refused, true, '与已有题目重复'));
      expect((await row('taken-back')).localState, LocalState.pending);
      expect((report.agentQuestionsUploaded, report.agentQuestionsRefused), (2, 1));
      expect(report.summary, allOf(contains('上传了离线出的 2 道题'), contains('1 道离线出的题没通过服务器检查')));

      // Once published, the question comes back under its own id and replaces the local row.
      api.published.add(QuestionDto(
          id: 'review', bankId: 'b1', type: 'single', stem: '服务器的题干', options: const ['甲', '乙', '丙', '丁'], answer: const [2],
          explanation: '', difficulty: 3, tags: const [], sourceQuote: '', chunkId: 'L1', syncSeq: 9));
      await service().run();
      review = await row('review');
      expect((review.stem, review.hidden, review.localState, review.syncSeq), ('服务器的题干', false, '', 9));
    });

    test('an older server, a wrong token or no token leave the questions waiting, and the sync goes on', () async {
      await written('w');
      api.agentUploadStatus = 404;
      var r = await service().run();
      expect(r.agentQuestionsUploaded, 0);
      expect((await (db.select(db.questions)..where((q) => q.id.equals('w'))).getSingle()).localState, LocalState.pending);

      api.agentUploadStatus = null;
      await ai.setToken('wrong');
      await service().run();
      expect(api.uploadedAgentQuestions, isEmpty);
      await ai.setToken('');
      await service().run();
      expect(api.uploadedAgentQuestions, isEmpty);

      await ai.setToken('tok');
      r = await service().run();
      expect(r.agentQuestionsUploaded, 1);
    });

    test('decisions made while the server was out of reach are told to it, and let go when it does not know the question', () async {
      await written('adopt', state: LocalState.adopt);
      await written('discard', state: LocalState.discard, hidden: true);
      await service().run();
      expect(api.agentDecisions, {'adopt': true, 'discard': false});
      final left = await (db.select(db.questions)..where((q) => q.localState.isIn([LocalState.adopt, LocalState.discard]))).get();
      expect(left, isEmpty);
    });

    test('the assistant\'s configuration is fetched at sync, kept, and dropped when the server has no assistant', () async {
      expect(specs.spec, isNull);
      api.agentSpec = testSpec();
      var r = await service().run();
      expect(r.agentSpecUpdated, isTrue);
      expect(specs.spec!.model.apiKey, 'sk-x');
      expect(specs.spec!.tools.length, 11);
      expect(specs.spec!.prompt, '你是助手');
      r = await service().run();
      expect(r.agentSpecUpdated, isFalse, reason: 'unchanged');
      api.agentSpec = null;
      await service().run();
      expect(specs.spec, isNull);
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    last = options;
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _SlowLibrary extends MemLibrary {
  @override
  Future<List<AgentLesson>> lessons() => Future<List<AgentLesson>>.delayed(const Duration(milliseconds: 500), () => []);
}

HybridAgentApi _hybrid(_FakeServerApi server, AppDatabase db, LocalAgentStore store, ScriptedLlm llm, DateTime Function() clock) {
  final local = LocalAgentApi(store: store, library: DbAgentLibrary(db), specOf: testSpec, llm: llm);
  return HybridAgentApi(server: server, local: local, clock: clock);
}

/// The server's assistant, scripted.
class _FakeServerApi implements AgentApi {
  List<AgentEvent> events = const [];
  Object? chatError;
  Object? endWith;
  Object? statusError;
  Object? listError;
  Object? decideError;
  var chatCalls = 0;
  var statusCalls = 0;
  final deleted = <String>[];
  final decided = <String, bool>{};
  final kept = <String, AgentConversationItem>{};

  void keep(String id, int updatedAt) => kept[id] = AgentConversationItem(id: id, mode: 'create', title: '服务器的 $id', updatedAt: updatedAt);

  @override
  Future<AgentStatus> status() async {
    statusCalls++;
    if (statusError != null) throw statusError!;
    return const AgentStatus(available: true, model: 'server-model', verified: true);
  }

  @override
  Stream<AgentEvent> chat(AgentChatRequest request, {CancelToken? cancel}) async* {
    chatCalls++;
    if (chatError != null) throw chatError!;
    for (final e in events) {
      yield e;
    }
    if (endWith != null) throw endWith!;
  }

  @override
  Future<AgentConversationPage> conversations({int? before, int limit = 30}) async {
    if (listError != null) throw listError!;
    return AgentConversationPage(kept.values.toList());
  }

  @override
  Future<AgentConversationDetail> conversation(String id) async {
    final c = kept[id];
    if (c == null) throw AgentException('没有', status: 404);
    return AgentConversationDetail(c, const []);
  }

  @override
  Future<void> deleteConversation(String id) async => deleted.add(id);

  @override
  Future<AgentAttachment> uploadAttachment(String conversationId, String name, Uint8List bytes) => throw UnimplementedError();

  @override
  Future<void> deleteAttachment(String id) async {}

  @override
  Future<Uint8List> attachmentBytes(String id) => throw UnimplementedError();

  @override
  Future<void> acceptDraft(String id) async {
    if (decideError != null) throw decideError!;
    decided[id] = true;
  }

  @override
  Future<void> discardDraft(String id) async {
    if (decideError != null) throw decideError!;
    decided[id] = false;
  }
}
