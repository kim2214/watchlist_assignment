import 'package:flutter_test/flutter_test.dart';

import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/state/market_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('상세: 시/고/저 누적 + 스파크라인 링버퍼 상한', () async {
    final feed = MarketFeed();
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    final code = store.infoAt(0).code;
    store.openDetail(code); // 포커스 지정(스파크라인 기록 시작)

    feed.pump(1000);
    await Future<void>.delayed(Duration.zero); // 스트림 전달 대기

    final d = store.detailOf(code);

    // 고/저 불변식: 고가 ≥ 현재가 ≥ 저가, 고가 ≥ 저가.
    expect(d.high, greaterThanOrEqualTo(d.low));
    expect(d.high, greaterThanOrEqualTo(d.price));
    expect(d.low, lessThanOrEqualTo(d.price));
    expect(d.open, greaterThan(0));

    // 스파크라인은 무한히 커지지 않고 상한(60) 이내.
    expect(d.spark.length, inInclusiveRange(1, 60));
    expect(d.spark.last, d.price); // 마지막 점 = 현재가
  });

  test('상세 종료 후 다시 열면 스파크라인이 초기화된다', () async {
    final feed = MarketFeed();
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    final code = store.infoAt(1).code;
    store.openDetail(code);
    feed.pump(300);
    await Future<void>.delayed(Duration.zero);
    store.closeDetail();

    store.openDetail(code); // 다시 진입
    final d = store.detailOf(code);
    expect(d.spark.length, 1); // 현재가 1점으로 재시작
  });
}
