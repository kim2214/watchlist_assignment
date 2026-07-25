import 'package:flutter/material.dart';

import 'baseline/naive_watchlist_screen.dart';

/// baseline(before) 엔트리포인트.
/// 실행: `flutter run --profile -t lib/main_baseline.dart -d [device]`
void main() {
  runApp(const BaselineApp());
}

class BaselineApp extends StatelessWidget {
  const BaselineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watchlist (baseline)',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const NaiveWatchlistScreen(),
    );
  }
}
