import 'package:flutter/material.dart';

import 'features/home/home_shell.dart';

class QuizMindApp extends StatelessWidget {
  const QuizMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF2E7D6B),
          brightness: b,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        );
    return MaterialApp(
      title: 'QuizMind',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}
