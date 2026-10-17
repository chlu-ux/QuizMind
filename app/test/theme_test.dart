import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmind_app/core/settings.dart';
import 'package:quizmind_app/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> stored(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('follows the device until the learner chooses, and remembers the choice', () async {
    final sp = await stored({});
    final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(sp)]);
    addTearDown(c.dispose);
    expect(c.read(themeModeProvider), ThemeMode.system);
    await c.read(themeModeProvider.notifier).set(ThemeMode.light);
    expect(c.read(themeModeProvider), ThemeMode.light);
    expect(sp.getString('theme_mode'), 'light');

    final again = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(sp)]);
    addTearDown(again.dispose);
    expect(again.read(themeModeProvider), ThemeMode.light, reason: 'kept for the next start');
  });

  testWidgets('the 外观 setting switches the app between light and dark', (tester) async {
    final sp = await stored({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(sp)],
        child: Consumer(
          builder: (context, ref, _) => MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            darkTheme: ThemeData(brightness: Brightness.dark),
            themeMode: ref.watch(themeModeProvider),
            home: const Scaffold(body: AppearanceSection()),
          ),
        ),
      ),
    );
    Brightness shown() => Theme.of(tester.element(find.byType(AppearanceSection))).brightness;

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(shown(), Brightness.dark);
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(shown(), Brightness.light);
    expect(sp.getString('theme_mode'), 'light');
  });
}
