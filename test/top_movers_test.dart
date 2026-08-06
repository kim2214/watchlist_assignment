import 'package:flutter_test/flutter_test.dart';

import 'package:watchlist_assignment/domain/symbol_view.dart';
import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/state/market_store.dart';

/// Top-20 랭킹의 안전망.
///
/// 랭킹을 SplayTreeSet에서 "Float64List + 20슬롯 선형 선택"(`_topK`)으로 바꾼
/// 변경의 회귀 테스트다. 검증 방식은 **무차별 참조 구현과의 대조**다:
/// 전 종목을 등락률로 완전 정렬해 앞 20개를 뽑은 결과와 store의 결과가
/// 코드·순서·값까지 같아야 한다. 선택 알고리즘의 조기 탈락(`floor`) 최적화가
/// 경계에서 원소를 잘못 떨어뜨리면 여기서 잡힌다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 참조 구현: 전체 정렬 후 상위 20. (등락률 내림차순, 동률은 코드 오름차순)
  List<String> reference(MarketStore store, {List<String>? scope}) {
    final codes = scope ??
        [for (var i = 0; i < store.symbolCount; i++) store.infoAt(i).code];
    final sorted = [...codes]..sort((a, b) {
      final c = store.debugViewOf(b).changePct.compareTo(
        store.debugViewOf(a).changePct,
      );
      return c != 0 ? c : a.compareTo(b);
    });
    return sorted.take(20).toList();
  }

  List<String> actual(MarketStore store) =>
      store.topMovers.value.map((m) => m.code).toList();

  test('초기 스냅샷의 Top-20이 전체 정렬 결과와 일치한다', () {
    final store = MarketStore(MarketFeed())..attachForBenchmark();
    addTearDown(store.dispose);

    expect(store.topMovers.value, hasLength(20));
    expect(actual(store), reference(store));
  });

  test('tick 반영 후에도 Top-20이 전체 정렬 결과와 일치한다', () async {
    final feed = MarketFeed();
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    // 배치를 여러 구간으로 나눠 밀어넣고, 매 구간마다 대조한다.
    // (한 번만 보면 "우연히 맞은" 상태를 통과시킬 수 있다)
    for (var round = 0; round < 5; round++) {
      feed.pump(120);
      await Future<void>.delayed(Duration.zero); // broadcast 전달 대기
      store.debugFlush();

      expect(
        actual(store),
        reference(store),
        reason: 'round $round: Top-20이 참조 정렬과 다르다',
      );
    }
  });

  test('Top-20의 등락률·가격은 표시 중인 행의 값과 어긋나지 않는다', () async {
    final feed = MarketFeed();
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    feed.pump(300);
    await Future<void>.delayed(Duration.zero);
    store.debugFlush();

    // 내림차순이 실제로 유지되는지 + 각 항목의 값이 라이브 상태와 같은지.
    double? prev;
    for (final TopMover m in store.topMovers.value) {
      if (prev != null) expect(m.changePct, lessThanOrEqualTo(prev));
      prev = m.changePct;

      final view = store.debugViewOf(m.code);
      expect(m.changePct, closeTo(view.changePct, 1e-9));
      expect(m.price, view.price);
      expect(m.halted, view.halted);
    }
  });

  test('필터가 걸리면 Top-20도 통과 집합 기준으로 계산된다', () async {
    final feed = MarketFeed();
    final store = MarketStore(feed)..attachForBenchmark();
    addTearDown(store.dispose);

    feed.pump(300);
    await Future<void>.delayed(Duration.zero);
    store.debugFlush();

    store.setQuery('001'); // 종목코드 부분일치 → 통과 집합이 전체보다 작다
    final scope = [
      for (var i = 0; i < store.visibleCount; i++) store.codeAt(i),
    ];
    expect(scope.length, lessThan(store.symbolCount));

    // 통과 집합 안에서만 뽑혔는가 + 그 집합의 정렬 결과와 같은가.
    for (final m in store.topMovers.value) {
      expect(scope, contains(m.code));
    }
    expect(actual(store), reference(store, scope: scope));

    // 필터 해제 시 전체 기준으로 복귀.
    store.setQuery('');
    expect(actual(store), reference(store));
  });

  test('통과 집합이 20개 미만이면 있는 만큼만 돌려준다', () {
    final store = MarketStore(MarketFeed())..attachForBenchmark();
    addTearDown(store.dispose);

    store.setQuery('000001'); // 정확히 1종목
    expect(store.visibleCount, 1);
    expect(store.topMovers.value, hasLength(1));
    expect(store.topMovers.value.single.code, '000001');

    store.setQuery('존재하지않는종목명'); // 0종목
    expect(store.visibleCount, 0);
    expect(store.topMovers.value, isEmpty);
  });
}
