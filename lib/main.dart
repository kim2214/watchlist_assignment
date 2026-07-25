import 'package:flutter/material.dart';

import 'ui/watchlist_screen.dart';

/// 개선본(after) 엔트리포인트.
/// 실행: `flutter run --profile -d [device]`
///
/// baseline(before)과 비교하려면:
///   `flutter run --profile -t lib/main_baseline.dart -d [device]`
void main() {
  runApp(const WatchlistApp());
}

class WatchlistApp extends StatelessWidget {
  const WatchlistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watchlist',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const WatchlistScreen(),
    );
  }
}
