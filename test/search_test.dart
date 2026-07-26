import 'package:flutter_test/flutter_test.dart';

import 'package:watchlist_assignment/search/chosung.dart';
import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/state/market_store.dart';

void main() {
  group('chosungOf', () {
    test('완성형 이름의 초성열을 뽑는다 (과제 예시)', () {
      expect(chosungOf('가온전자'), 'ㄱㅇㅈㅈ');
      expect(chosungOf('나래화학'), 'ㄴㄹㅎㅎ');
    });

    test('비한글은 그대로 통과시킨다', () {
      expect(chosungOf('가A 1'), 'ㄱA 1');
    });
  });

  group('쿼리 분류', () {
    test('초성/숫자 판별', () {
      expect(isChosungQuery('ㄱㅇ'), isTrue);
      expect(isChosungQuery('전자'), isFalse); // 완성형
      expect(isChosungQuery('ㄱ전'), isFalse); // 혼합
      expect(hasDigit('000590'), isTrue);
      expect(hasDigit('전자'), isFalse);
    });
  });

  group('MarketStore 검색', () {
    late MarketStore store;
    setUp(() => store = MarketStore(MarketFeed())..attachForBenchmark());
    tearDown(() => store.dispose());

    List<String> resultNames() =>
        [for (var i = 0; i < store.visibleCount; i++) store.nameAt(i)];

    test('빈 쿼리는 전체(2000)', () {
      store.setQuery('');
      expect(store.visibleCount, 2000);
    });

    test('초성 앞일치: ㄱㅇ → 모두 가온… 으로 시작', () {
      store.setQuery('ㄱㅇ');
      expect(store.visibleCount, greaterThan(0));
      expect(resultNames().every((n) => chosungOf(n).startsWith('ㄱㅇ')), isTrue);
    });

    test('초성 앞일치: ㄴㄹㅎㅎ → 나래화학 (초성이 같은 누리화학도 함께)', () {
      store.setQuery('ㄴㄹㅎㅎ');
      expect(resultNames(), contains('나래화학'));
      // "누리"도 초성이 ㄴㄹ이라 누리화학도 정당하게 매칭된다.
      expect(resultNames().every((n) => chosungOf(n).startsWith('ㄴㄹㅎㅎ')), isTrue);
    });

    test('완성형 부분일치: 전자 → 이름에 "전자" 포함', () {
      store.setQuery('전자');
      expect(store.visibleCount, greaterThan(0));
      expect(resultNames().every((n) => n.contains('전자')), isTrue);
    });

    test('종목코드 부분일치: 000001', () {
      store.setQuery('000001');
      final codes = [for (var i = 0; i < store.visibleCount; i++) store.codeAt(i)];
      expect(codes, contains('000001'));
      expect(codes.every((c) => c.contains('000001')), isTrue);
    });

    test('필터 시 요약 종목 수 = 표시 수', () {
      store.setQuery('ㄱㅇ');
      expect(store.summary.value.count, store.visibleCount);
    });
  });
}
