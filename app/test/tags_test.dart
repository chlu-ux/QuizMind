import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/tags.dart';

void main() {
  test('normalizeTag folds width and whitespace', () {
    expect(normalizeTag('  ＵＭＬ   类图 '), 'UML 类图');
  });

  final tags = ['UML', 'UML 辨析', 'UML', 'uml', 'Cache', 'cache', 'OS', 'OSI', '数据流图', '数据流图案例', '图', '图论', '数据库/范式', '数据库'];

  test('without merging, only spelling variants share a label (the most common spelling wins)', () {
    final l = tagLabeler(tags, merge: false);
    expect(l('uml'), 'UML');
    expect(l('Cache'), l('cache'));
    expect(l('UML 辨析'), 'UML 辨析');
    expect(l('数据流图案例'), '数据流图案例');
  });

  test('merging joins a tag to the shorter tag it starts with', () {
    final l = tagLabeler(tags, merge: true);
    expect(l('UML 辨析'), 'UML');
    expect(l('数据流图案例'), '数据流图');
    expect(l('数据库/范式'), '数据库');
  });

  test('never merges on a one-letter prefix or in the middle of a Latin word', () {
    final l = tagLabeler(tags, merge: true);
    expect(l('图论'), '图论');
    expect(l('OSI'), 'OSI');
    expect(l('OS'), 'OS');
  });

  test('leaves unknown tags alone and tolerates empty input', () {
    expect(tagLabeler(const [], merge: true)('随便'), '随便');
    expect(tagLabeler(const ['', '  '], merge: false)(''), '');
  });
}
