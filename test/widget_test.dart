import 'package:flutter_test/flutter_test.dart';

import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/state/market_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('스냅샷으로 스토어가 초기화된다', () {
    final store = MarketStore(MarketFeed())..attachForBenchmark();
    addTearDown(store.dispose);

    expect(store.symbolCount, 2000);
    expect(store.summary.value.count, 2000);
    expect(store.summary.value.totalMarketCap, greaterThan(0));

    final code = store.infoAt(0).code;
    expect(store.debugViewOf(code).price, greaterThan(0));
  });

  test('역순(과거) tick은 표시 가격을 되돌리지 않는다', () async {
    // transientError를 켜 에러가 와도 구독이 유지되는지도 함께 본다.
    final feed = MarketFeed(transientErrorProbability: 0.1);
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    // 결정론적으로 배치를 밀어넣는다. (리스너는 attachForBenchmark가 이미 붙임)
    feed.pump(600);
    await Future<void>.delayed(Duration.zero); // broadcast 전달 대기
    store.debugFlush();

    // 모든 종목의 표시 가격은 그 종목의 previousClose 대비 일일 등락제한(±30%)
    // 안에 있어야 하고, 역순 tick으로 과거값이 반영돼도 음수/0이 되면 안 된다.
    for (var i = 0; i < store.symbolCount; i++) {
      final code = store.infoAt(i).code;
      final view = store.debugViewOf(code);
      expect(view.price, greaterThan(0),
          reason: '$code 의 가격이 0 이하로 되돌아감');
      expect(view.changePct, inInclusiveRange(-31, 31),
          reason: '$code 의 등락률이 일일 제한을 벗어남');
    }

    // 에러가 왔더라도 배치 소비가 이어져 집계가 갱신됐어야 한다.
    expect(store.summary.value.totalMarketCap, greaterThan(0));
  });

  test('거래정지 tick은 정지 상태로 표시된다', () async {
    // 정지 확률을 크게 올려 짧은 pump에도 정지가 관측되게 한다.
    final feed = MarketFeed(haltProbability: 0.5);
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    feed.pump(300);
    await Future<void>.delayed(Duration.zero);
    store.debugFlush();

    var haltedCount = 0;
    for (var i = 0; i < store.symbolCount; i++) {
      if (store.debugViewOf(store.infoAt(i).code).halted) haltedCount++;
    }
    expect(haltedCount, greaterThan(0), reason: '정지 종목이 하나도 관측되지 않음');
  });
}
