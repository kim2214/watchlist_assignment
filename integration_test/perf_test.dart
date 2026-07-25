import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:watchlist_assignment/baseline/naive_watchlist_screen.dart';
import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/ui/watchlist_screen.dart';

/// ============================================================================
/// 재현 가능한 프레임 타임 벤치마크 (before/after 비교의 근거)
///
/// 시나리오는 벽시계가 아니라 feed.pump() 로 결정론적으로 배치를 밀어넣는다.
/// 기본 seed(20260703)이므로 tick 수열이 항상 동일 → 후보 간 공정 비교.
///
/// 실행 (실기기 profile 모드):
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/perf_test.dart \
///     --profile -d [device]
///
/// 결과: build/integration_response_data.json 의 'baseline' 키에
///   average_frame_build_time_millis / 90th_percentile / 99th / worst 등.
/// ============================================================================

const int kBatches = 600; // 60Hz × 10초 분량
const int kScrollEvery = 30; // N배치마다 한 번씩 스크롤
const Offset kScrollDelta = Offset(0, -400);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('baseline: pump 600배치 + 주기적 스크롤 프레임 타임', (tester) async {
    final feed = MarketFeed(); // 기본 seed → 결정론적
    await tester.pumpWidget(
      MaterialApp(home: NaiveWatchlistScreen(feed: feed, autoStart: false)),
    );
    await tester.pumpAndSettle();

    await binding.watchPerformance(() async {
      await _runScenario(tester, feed);
    }, reportKey: 'baseline');

    feed.dispose();
  });

  testWidgets('after: pump 600배치 + 주기적 스크롤 프레임 타임', (tester) async {
    final feed = MarketFeed(); // 동일 seed → baseline과 같은 tick 수열
    await tester.pumpWidget(
      MaterialApp(home: WatchlistScreen(feed: feed, autoStart: false)),
    );
    await tester.pumpAndSettle();

    await binding.watchPerformance(() async {
      await _runScenario(tester, feed);
    }, reportKey: 'after');

    feed.dispose();
  });
}

/// 데이터 갱신(pump) + 스크롤을 섞은 결정론적 시나리오.
Future<void> _runScenario(WidgetTester tester, MarketFeed feed) async {
  // 개선본은 Top-20 가로 리스트도 Scrollable이라 2개가 잡힌다.
  // 세로 목록은 트리상 항상 마지막(.last). baseline은 1개뿐이라 동일하게 동작.
  final list = find.byType(Scrollable).last;
  for (var i = 0; i < kBatches; i++) {
    feed.pump(1); // 배치 1개 방출 (리스너=화면이 이미 붙어 있음)
    await tester.pump(const Duration(milliseconds: 16)); // 한 프레임 렌더
    if (i % kScrollEvery == kScrollEvery - 1) {
      await tester.drag(list, kScrollDelta);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
}
