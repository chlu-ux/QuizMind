import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/features/quiz/quiz_media.dart';

void main() {
  Future<void> show(WidgetTester tester, String md, {bool selectable = true}) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: QuizMarkdown(md, selectable: selectable),
              ),
            ),
          ),
        ),
      );

  int formulas() => find.byType(Math).evaluate().length;

  testWidgets(
    'formulas written with dollars or with backslash brackets are drawn',
    (tester) async {
      await show(tester, r'质能方程 $E=mc^2$，也写作 \(a_1+a_2\)。');
      expect(formulas(), 2);
      expect(
        find.textContaining(r'$E'),
        findsNothing,
        reason: 'the markers are not left in the text',
      );
    },
  );

  testWidgets('a formula joins the line it is in', (tester) async {
    await show(tester, r'前面的字 $x^2$ 后面的字');
    expect(formulas(), 1);
    // words, formula, words: one run of text, not three widgets side by side
    expect(tester.widget<Wrap>(find.byType(Wrap)).children, hasLength(1));
  });

  testWidgets(
    'a formula on its own lines is drawn large, however many lines it takes',
    (tester) async {
      await show(
        tester,
        '先看：\n\n\$\$\n\\frac{a}{b} = c\n\$\$\n\n再看\n\n\\[ x_1 + x_2 \\]\n',
      );
      expect(formulas(), 2);
      expect(find.byKey(const ValueKey('math-display')), findsNWidgets(2));
    },
  );

  testWidgets('dollars as money are not formulas', (tester) async {
    await show(tester, r'价格从 $5 涨到 $10，还有 $ 和 $。');
    expect(formulas(), 0);
    expect(find.textContaining(r'$5'), findsOneWidget);
  });

  testWidgets('a formula still being written stays text, code stays code', (
    tester,
  ) async {
    await show(tester, '未写完 \$\$ x^2 ');
    expect(formulas(), 0);
    await show(tester, '代码 `\$a\$ + \$b\$` 与 \n\n```\n\$\$x\$\$\n```');
    expect(formulas(), 0);
  });

  testWidgets(
    'a formula that cannot be parsed shows its source, not an error',
    (tester) async {
      await show(tester, r'坏的 $\frac{1$ 之后');
      expect(tester.takeException(), isNull);
      expect(find.textContaining('frac'), findsOneWidget);
    },
  );

  testWidgets(
    'works in the not-selectable form and inside lists and emphasis',
    (tester) async {
      await show(
        tester,
        '- 第一条 \$a_b * c_d\$ **粗体 \$y\$**\n- 第二条',
        selectable: false,
      );
      expect(formulas(), 2);
      expect(tester.takeException(), isNull);
    },
  );
}
