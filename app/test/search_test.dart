import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/quiz/search.dart';

Question q(
  String id, {
  String? stem,
  List<String> options = const ['甲', '乙', '丙', '丁'],
  String explanation = '',
  List<String> tags = const [],
  bool hidden = false,
}) =>
    Question(
      id: id,
      bankId: 'b',
      type: 'single',
      stem: stem ?? '题干 $id',
      optionsJson: jsonEncode(options),
      answerJson: '[0]',
      explanation: explanation,
      difficulty: 2,
      tagsJson: jsonEncode(tags),
      sourceQuote: '',
      documentId: '',
      documentTitle: '',
      documentOrder: 0,
      syncSeq: 1,
      hidden: hidden,
    );

List<String> ids(List<Question> qs, String query) => [for (final h in searchQuestions(qs, query)) h.question.id];

void main() {
  group('searchTerms', () {
    test('folds case and width, splits on any whitespace and drops duplicates', () {
      expect(searchTerms('  ＵＭＬ　图\t uml '), ['uml', '图']);
      expect(searchTerms('   '), isEmpty);
      expect(searchTerms(''), isEmpty);
    });
  });

  group('searchQuestions', () {
    final qs = [
      q('a', stem: '读写锁允许多个读者同时持有锁'),
      q('b', stem: '互斥锁只允许一个线程持有', explanation: '与读写锁相比，互斥锁更简单'),
      q('c', stem: '下列哪项正确', options: ['使用读写锁', '使用信号量', '不加锁', '随便']),
    ];

    test('needs every word, in any field', () {
      expect(ids(qs, '读写锁'), ['a', 'c', 'b']);
      expect(ids(qs, '读写锁 互斥锁'), ['b']);
      expect(ids(qs, '读写锁 信号量'), ['c']);
      expect(ids(qs, '读写锁 不存在'), isEmpty);
    });

    test('ignores case, width and extra spaces', () {
      final list = [q('x', stem: 'UML 类图的画法'), q('y', stem: '数据流图')];
      expect(ids(list, 'uml'), ['x']);
      expect(ids(list, 'ＵＭＬ  类图'), ['x']);
      expect(ids([q('z', stem: '版本１０的特性')], '版本10'), ['z']);
    });

    test('blank queries find nothing and withdrawn questions never show', () {
      expect(ids(qs, ''), isEmpty);
      expect(ids(qs, '   '), isEmpty);
      expect(ids([q('h', stem: '读写锁', hidden: true)], '读写锁'), isEmpty);
    });

    test('ranks stem hits before option and tag hits before explanation hits, keeping bank order within a level', () {
      final list = [
        q('expl', stem: '无关', explanation: '这里讲到缓存一致性'),
        q('opt', stem: '无关', options: ['缓存', 'b', 'c', 'd']),
        q('stem1', stem: '缓存的作用'),
        q('tag', stem: '无关', tags: ['缓存']),
        q('stem2', stem: '什么是缓存'),
      ];
      final hits = searchQuestions(list, '缓存');
      expect([for (final h in hits) h.question.id], ['stem1', 'stem2', 'opt', 'tag', 'expl']);
      expect([for (final h in hits) h.where], [
        SearchWhere.stem,
        SearchWhere.stem,
        SearchWhere.option,
        SearchWhere.tag,
        SearchWhere.explanation,
      ]);
    });

    test('says what matched when it is not the stem', () {
      final list = [
        q('opt', stem: '无关', options: ['先进先出', '最近最少使用', 'c', 'd']),
        q('tag', stem: '无关', tags: ['LRU 算法']),
        q('stem', stem: '最近最少使用是什么'),
      ];
      expect(ids(list, '最近最少使用 lru'), isEmpty, reason: 'no single question has both words');
      expect([for (final h in searchQuestions(list, '最近最少')) (h.question.id, h.snippet)], [('stem', ''), ('opt', '最近最少使用')]);
      expect(searchQuestions(list, 'lru').single.snippet, 'LRU 算法');
    });

    test('shows a window around the hit for a long explanation', () {
      const long = '前面是很长很长的一段铺垫文字，用来把命中的词挤到中间去。关键词出现在这里。后面还有很长很长的一段说明文字，同样是为了超出窗口，继续往后写，再多写几句凑够字数，确保明显超过后面保留的那一段上下文。';
      final h = searchQuestions([q('e', stem: '无关', explanation: long)], '关键词').single;
      expect(h.where, SearchWhere.explanation);
      expect(h.snippet, startsWith('…'));
      expect(h.snippet, endsWith('…'));
      expect(h.snippet, contains('关键词出现在这里'));
      expect(h.snippet.length, lessThan(long.length));
    });

    test('treats regular-expression characters literally', () {
      final list = [q('a', stem: '计算 (a+b)*c 的值'), q('b', stem: 'abc')];
      expect(ids(list, '(a+b)*c'), ['a']);
      expect(ids(list, '.*'), isEmpty);
      expect(ids(list, '['), isEmpty);
    });
  });

  group('highlight', () {
    String joined(List<Piece> p) => p.map((x) => x.text).join();

    test('marks every occurrence and joins back into the original', () {
      final p = highlight('读写锁和互斥锁都是锁', ['锁']);
      expect(joined(p), '读写锁和互斥锁都是锁');
      expect([for (final x in p) if (x.hit) x.text], ['锁', '锁', '锁']);
      expect(p.every((x) => x.text.isNotEmpty), isTrue);
    });

    test('merges overlapping and touching terms', () {
      expect(highlight('abcdef', ['abc', 'cde']), [const Piece('abcde', hit: true), const Piece('f', hit: false)]);
      expect(highlight('abcd', ['ab', 'cd']), [const Piece('abcd', hit: true)]);
    });

    test('handles a hit at the very start, at the very end, and none at all', () {
      expect(highlight('锁定', ['锁']), [const Piece('锁', hit: true), const Piece('定', hit: false)]);
      expect(highlight('加锁', ['锁']), [const Piece('加', hit: false), const Piece('锁', hit: true)]);
      expect(highlight('加锁', ['x']), [const Piece('加锁', hit: false)]);
      expect(highlight('', ['x']), isEmpty);
      expect(highlight('abc', []), [const Piece('abc', hit: false)]);
    });

    test('matches case and width loosely but returns the original text', () {
      expect(highlight('Use UML 图', ['uml']), [const Piece('Use ', hit: false), const Piece('UML', hit: true), const Piece(' 图', hit: false)]);
      expect(highlight('ＵＭＬ图', ['uml']), [const Piece('ＵＭＬ', hit: true), const Piece('图', hit: false)]);
    });

    test('never reads terms as patterns', () {
      expect(highlight('a.b a+b', ['.', '+']), [
        const Piece('a', hit: false),
        const Piece('.', hit: true),
        const Piece('b a', hit: false),
        const Piece('+', hit: true),
        const Piece('b', hit: false),
      ]);
    });

    test('keeps surrogate pairs whole', () {
      expect(highlight('A😀B', ['😀']), [const Piece('A', hit: false), const Piece('😀', hit: true), const Piece('B', hit: false)]);
    });
  });
}
