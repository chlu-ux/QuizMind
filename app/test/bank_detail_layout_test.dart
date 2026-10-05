import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/data/database.dart';
import 'package:quizmind_app/features/home/banks_page.dart';

import 'support.dart';

void main() {
  // A phone-sized window with the system font turned up: every entry of the bank page must be on
  // screen without scrolling (the page once pushed its last row below the fold).
  for (final scale in [1.0, 1.3]) {
    testWidgets('the bank page fits a phone screen with text at ${scale}x', (tester) async {
      tester.view.physicalSize = const Size(1080, 1790); // about 411 x 680 dp: what is left under the status bar, app bar and tab bar
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final db = memoryDb();
      await tester.runAsync(() async {
        await addBank(db, 'b1', '软件设计师（中级）');
        await seedQs(db, n: 3);
      });
      await pumpWith(
        tester,
        db,
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            appBar: AppBar(title: const Text('软件设计师（中级）')),
            body: BankDetail(
              bank: Bank(id: 'b1', title: '软件设计师（中级）', description: '考点精讲讲义，题目由 Claude 手写并经过服务端校验，需人工审核后发布。', questionCount: 3),
              showTitle: false,
            ),
          ),
        ),
      );
      await settleUi(tester);

      final screenBottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      for (final label in ['随机刷题', '只做没做过的', '按模块刷题', '按知识点刷题', '模拟考试', '搜索题目', '错题本', '统计分析']) {
        expect(find.text(label), findsOneWidget, reason: label);
        expect(tester.getBottomLeft(find.text(label)).dy, lessThan(screenBottom), reason: '$label is below the fold');
      }
      expect(tester.takeException(), isNull);
      await tearDownUi(tester, db);
    });
  }
}
